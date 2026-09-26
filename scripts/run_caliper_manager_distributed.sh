#!/usr/bin/env bash
# Chamado automaticamente por run_distributed_sweep.py (via SSH, um round por vez),
# que por sua vez é disparado pelo terraform apply quando node_caliper_count > 1
# (null_resource.run_distributed_sweep em main.tf). O próprio run_distributed_sweep.py
# envia este arquivo (scp) e dá chmod +x antes do primeiro round. Pressupõe que
# run_caliper_tests.sh já rodou nessa instância (repo clonado, networkconfig.json
# já patchado com endereços/contratos reais).
#
# Sobe um broker MQTT local, lança a fatia de workers locais desta instância, e roda
# o manager em modo distribuído (--caliper-worker-remote), esperando também os workers
# remotos da instância B — lançados por run_distributed_sweep.py
# (launch_remote_workers(), via SSH) rodando launch_workers.sh lá, apontando pro IP
# privado desta instância.
#
# Uso:
#   ./run_caliper_manager_distributed.sh [NUM_WORKERS_LOCAIS] [BENCHMARK_FILE]
set -euo pipefail

CALIPER_ROOT="/home/ubuntu/tests-with-caliper/evaluation-contracts-indy-besu"
LOG_FILE="/home/ubuntu/besu-setup.log"

NUM_WORKERS_LOCAIS="${1:-16}"
BENCHMARK_FILE="${2:-benchmarks/scenario/IndyDidRegistry/config-createDid.yaml}"
FUNCTION_NAME="${3:-createDid}"
TPS="${4:-3500}"
BROKER_ADDRESS="mqtt://127.0.0.1:1883"
REPORT_DIR="$CALIPER_ROOT/src/reports/$FUNCTION_NAME"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check() {
  if [ $? -ne 0 ]; then log "ERRO: $1"; exit 1; fi
  log "OK: $1"
}

[ -d "$CALIPER_ROOT" ] || { log "ERRO: $CALIPER_ROOT não existe — rode run_caliper_tests.sh primeiro"; exit 1; }

log "===== Manager distribuído: broker MQTT + $NUM_WORKERS_LOCAIS workers locais + manager remoto ====="

# ============================================================================
# Passo 1 — Instalar e configurar o broker MQTT (mosquitto)
# ============================================================================
if ! command -v mosquitto &>/dev/null; then
  log "Instalando mosquitto..."
  sudo apt-get update -y && sudo apt-get install -y mosquitto mosquitto-clients
  check "Instalação do mosquitto"
else
  log "mosquitto já instalado"
fi

# Listener explícito em todas as interfaces (default do pacote Ubuntu já costuma
# ser 0.0.0.0:1883, mas deixamos explícito) + allow_anonymous, já que o Security
# Group já restringe a porta 1883 só ao próprio SG (self=true, ver main.tf).
sudo tee /etc/mosquitto/conf.d/caliper.conf > /dev/null <<'EOF'
listener 1883 0.0.0.0
allow_anonymous true
EOF
sudo systemctl enable mosquitto >>"$LOG_FILE" 2>&1
sudo systemctl restart mosquitto
sleep 2
sudo systemctl is-active --quiet mosquitto
check "mosquitto rodando na porta 1883"

# ============================================================================
# Passo 2 — Lançar a fatia local de workers em background
# ============================================================================
log "Lançando $NUM_WORKERS_LOCAIS workers locais, conectando em $BROKER_ADDRESS..."
cd "$CALIPER_ROOT"
rm -f /home/ubuntu/worker-local-*.log
LOCAL_WORKER_PIDS=()
for i in $(seq 1 "$NUM_WORKERS_LOCAIS"); do
  npx caliper launch worker \
    --caliper-workspace ./ \
    --caliper-benchconfig "$BENCHMARK_FILE" \
    --caliper-networkconfig networks/besu/networkconfig.json \
    --caliper-worker-communication-method mqtt \
    --caliper-worker-communication-address "$BROKER_ADDRESS" \
    > "/home/ubuntu/worker-local-${i}.log" 2>&1 &
  LOCAL_WORKER_PIDS+=($!)
done
log "Workers locais lançados (PIDs: ${LOCAL_WORKER_PIDS[*]})"
log "Aguardando os workers remotos da instância B (lançados por run_distributed_sweep.py)..."

# ============================================================================
# Passo 3 — Rodar o manager em modo distribuído (bloqueia até o round terminar)
# ============================================================================
log "Iniciando manager em modo distribuído — aguardando todos os workers (locais + remotos) se conectarem..."
# pipefail já está ativo desde o "set -euo pipefail" do topo do script, então
# MANAGER_EXIT abaixo já reflete o exit code do "npx caliper", não do "tee" —
# só precisamos desligar temporariamente o "-e" pra um manager que falhe não
# derrubar o script antes da gente conseguir tratar o relatório/limpeza.
set +e
# 1800s: precisa de folga confortável acima do transactionBlockTimeout configurado em
# networkconfig.json (hoje 700 blocos, ~700s nominal a 1 bloco/s — dimensionado pra
# 14 nodes/7000 TPS, onde o backlog de fila leva bem mais tempo pra drenar que a 6 nodes)
# — visto na prática que um round inteiro com Succ alto pode ser morto aqui antes da
# última tx travada estourar seu próprio timeout individual, perdendo o relatório
# inteiro. Se transactionBlockTimeout mudar, revisar esse valor (e o SSH_TIMEOUT_ROUND
# correspondente em run_distributed_sweep.py) junto.
timeout 1800 npx caliper launch manager \
  --caliper-workspace ./ \
  --caliper-benchconfig "$BENCHMARK_FILE" \
  --caliper-networkconfig networks/besu/networkconfig.json \
  --caliper-flow-skip-install \
  --caliper-worker-remote \
  --caliper-worker-communication-method mqtt \
  --caliper-worker-communication-address "$BROKER_ADDRESS" \
  2>&1 | tee -a "$LOG_FILE"
MANAGER_EXIT=$?
set -e

# ============================================================================
# Passo 4 — Limpeza e relatório
# ============================================================================
log "Encerrando workers locais remanescentes..."
for pid in "${LOCAL_WORKER_PIDS[@]}"; do
  kill "$pid" 2>/dev/null || true
done
pkill -f 'caliper launch worker' 2>/dev/null || true

# Ground truth de sucesso/falha é a validade do relatório (mesmo critério de
# run_test_local.py), não o exit code do manager — um manager que retorna 0 mas
# sem transações reportadas ainda conta como falha pro orquestrador.
REPORT_VALID=0
if [ -f "$CALIPER_ROOT/report.html" ] && grep -q '<td>' "$CALIPER_ROOT/report.html"; then
  REPORT_VALID=1
fi

if [ "$REPORT_VALID" -eq 1 ]; then
  mkdir -p "$REPORT_DIR"
  TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
  REPORT_PATH="$REPORT_DIR/${FUNCTION_NAME}_report_${TPS}_${TIMESTAMP}.html"
  mv "$CALIPER_ROOT/report.html" "$REPORT_PATH"
  log "Relatório válido salvo em $REPORT_PATH"
else
  [ -f "$CALIPER_ROOT/report.html" ] && rm -f "$CALIPER_ROOT/report.html"
  log "ERRO: sem relatório válido para $FUNCTION_NAME @ ${TPS}TPS (manager exit=$MANAGER_EXIT)"
fi

log "===== Manager distribuído concluído (round=$FUNCTION_NAME tps=$TPS) ====="

# Exit code sinaliza sucesso/falha pro orquestrador local decidir se faz retry.
[ "$REPORT_VALID" -eq 1 ] && exit 0 || exit 1
