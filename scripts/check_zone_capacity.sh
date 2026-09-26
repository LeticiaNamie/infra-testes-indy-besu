#!/usr/bin/env bash
# Sonda, ANTES do terraform apply, se uma zona tem capacidade física para
# alocar de uma vez TODAS as VMs que o cluster real vai pedir — não só 1 de
# cada SKU. Capacidade "por instância" e "por lote" são coisas diferentes na
# Azure: ela pode aceitar 1 F4als_v6 e recusar a 5ª pedida no mesmo minuto
# (foi exatamente isso que aconteceu no apply real, que sobe os N nós em
# paralelo). Não existe API somente-leitura pra isso (az vm list-skus só
# mostra restrição de política/assinatura, não capacidade em tempo real) — a
# única forma confiável é tentar alocar de verdade e ver se a Azure aceita.
#
# O script cria, EM PARALELO (como o terraform apply faz), a mesma
# quantidade de VMs mínimas por SKU que o cluster real usaria, num resource
# group descartável, e apaga tudo no final (VMs + resource group).
#
# Custo: poucos centavos — VMs mínimas (sem IP público, disco pequeno) que
# ficam no ar só o tempo da criação até o delete (billing por segundo). É um
# snapshot do momento — capacidade pode mudar até você rodar o apply de
# verdade, então rode isso logo antes do apply real, não horas antes.
#
# Uso: ./scripts/check_zone_capacity.sh [zona1,zona2,...] [node_count] [node_caliper_count] [location]
# Ex.:  ./scripts/check_zone_capacity.sh 1,2,3 6 2 eastus

set -euo pipefail

IFS=',' read -ra ZONES <<< "${1:-1,2,3}"
NODE_COUNT="${2:-6}"
CALIPER_COUNT="${3:-2}"
LOCATION="${4:-eastus}"

VM_SIZE_NODE1="${VM_SIZE_NODE1:-Standard_F8als_v6}"
VM_SIZE_BESU="${VM_SIZE_BESU:-Standard_F4als_v6}"
VM_SIZE_CALIPER="${VM_SIZE_CALIPER:-Standard_D16s_v7}"
VM_SIZE_CALIPER_B="${VM_SIZE_CALIPER_B:-Standard_D16s_v7}"

RG="besu-capacity-probe-rg"
VNET="probe-vnet"
SUBNET="probe-subnet"
SSH_PUB_KEY="${SSH_PUB_KEY:-$HOME/.ssh/besu-key.pub}"
IMAGE="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"

if [ ! -f "$SSH_PUB_KEY" ]; then
  echo "ERRO: chave pública não encontrada em $SSH_PUB_KEY (ajuste SSH_PUB_KEY=... se necessário)" >&2
  exit 1
fi
if [ "$NODE_COUNT" -lt 1 ] || [ "$CALIPER_COUNT" -lt 1 ]; then
  echo "ERRO: node_count e node_caliper_count precisam ser >= 1" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() {
  echo ""
  echo "Removendo resource group de sondagem ($RG)... (pode rodar em background)"
  az group delete --name "$RG" --yes --no-wait -o none 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

if [ "$(az group exists --name "$RG")" = "true" ]; then
  echo "Resource group $RG ainda existe (provavelmente sendo removido por uma execução anterior) — aguardando..."
  while [ "$(az group exists --name "$RG")" = "true" ]; do
    sleep 15
  done
  echo "Removido. Prosseguindo."
fi

echo "Criando resource group + rede de sondagem em $LOCATION..."
az group create --name "$RG" --location "$LOCATION" -o none
az network vnet create \
  --resource-group "$RG" --name "$VNET" --location "$LOCATION" \
  --address-prefix 10.99.0.0/16 \
  --subnet-name "$SUBNET" --subnet-prefix 10.99.0.0/24 -o none

# Monta a lista "nome-da-vm|sku" com a MESMA composição do cluster real:
# 1x node1 + (node_count-1)x besu + 1x caliper A + (caliper_count-1)x caliper B
build_vm_list() {
  local zone="$1"
  echo "probe-node1-z${zone}|${VM_SIZE_NODE1}"
  for i in $(seq 2 "$NODE_COUNT"); do
    echo "probe-node${i}-z${zone}|${VM_SIZE_BESU}"
  done
  echo "probe-caliper-a-z${zone}|${VM_SIZE_CALIPER}"
  for i in $(seq 2 "$CALIPER_COUNT"); do
    echo "probe-caliper-b${i}-z${zone}|${VM_SIZE_CALIPER_B}"
  done
}

declare -A ZONE_VERDICT
declare -A ZONE_DETAIL

for zone in "${ZONES[@]}"; do
  echo ""
  echo "=== Zona $zone: disparando $((NODE_COUNT + CALIPER_COUNT)) VMs em paralelo ==="
  mapfile -t vm_list < <(build_vm_list "$zone")
  pids=()
  for entry in "${vm_list[@]}"; do
    vmname="${entry%%|*}"
    sku="${entry##*|}"
    (
      az vm create \
        --resource-group "$RG" \
        --name "$vmname" \
        --image "$IMAGE" \
        --size "$sku" \
        --zone "$zone" \
        --location "$LOCATION" \
        --vnet-name "$VNET" \
        --subnet "$SUBNET" \
        --admin-username ubuntu \
        --ssh-key-values "$SSH_PUB_KEY" \
        --public-ip-address "" \
        --nsg "" \
        --os-disk-size-gb 30 \
        -o none 2>"$WORKDIR/${vmname}.err" \
        && echo "OK" > "$WORKDIR/${vmname}.result" \
        || echo "FAIL" > "$WORKDIR/${vmname}.result"
    ) &
    pids+=($!)
  done
  echo "Aguardando as ${#pids[@]} tentativas de alocação..."
  wait "${pids[@]}"

  ok=0
  fail=0
  detail=""
  for entry in "${vm_list[@]}"; do
    vmname="${entry%%|*}"
    sku="${entry##*|}"
    if [ "$(cat "$WORKDIR/${vmname}.result")" = "OK" ]; then
      ok=$((ok + 1))
      az vm delete --resource-group "$RG" --name "$vmname" --yes --no-wait -o none
    else
      fail=$((fail + 1))
      if grep -qiE "SkuNotAvailable|OverconstrainedAllocationRequest|AllocationFailed|Capacity Restrictions" "$WORKDIR/${vmname}.err"; then
        detail="${detail}  - $vmname ($sku): sem capacidade\n"
      else
        detail="${detail}  - $vmname ($sku): $(tail -1 "$WORKDIR/${vmname}.err" | cut -c1-80)\n"
      fi
    fi
  done

  total=${#vm_list[@]}
  if [ "$fail" -eq 0 ]; then
    ZONE_VERDICT["$zone"]="SUFICIENTE ($ok/$total)"
  else
    ZONE_VERDICT["$zone"]="INSUFICIENTE ($ok/$total couberam)"
  fi
  ZONE_DETAIL["$zone"]="$detail"
done

echo ""
echo "=== Resultado (capacidade em $LOCATION para $NODE_COUNT nós Besu + $CALIPER_COUNT Caliper, agora) ==="
for zone in "${ZONES[@]}"; do
  echo "Zona $zone: ${ZONE_VERDICT[$zone]}"
  if [ -n "${ZONE_DETAIL[$zone]}" ]; then
    printf "%b" "${ZONE_DETAIL[$zone]}"
  fi
done
echo ""
echo "Use no terraform.tfvars a primeira zona marcada SUFICIENTE (azure_availability_zone)."
