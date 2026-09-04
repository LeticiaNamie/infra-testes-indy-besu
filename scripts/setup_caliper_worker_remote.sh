#!/usr/bin/env bash
# Roda na instância Caliper B via remote-exec (automático, parte do terraform apply).
# Faz só o setup necessário pra essa instância conseguir rodar "caliper launch worker"
# apontando pro manager remoto (instância A) — clona o repo, instala o Caliper CLI,
# faz o bind e patcha o networkconfig.json com os dados reais do deploy (mesmos passos
# 1-10 do run_caliper_tests.sh, sem Prometheus/monitor nem o loop de testes, que são
# responsabilidade só da instância A/manager).
#
# Ao final, deixa pronto o launch_workers.sh pra você disparar manualmente os workers
# remotos apontando pro broker MQTT da instância A.
set -euo pipefail

LOG_FILE="/home/ubuntu/besu-setup.log"
export PATH="/usr/local/bin:$PATH"

CLONE_ROOT="/home/ubuntu/tests-with-caliper"
CALIPER_ROOT="$CLONE_ROOT/evaluation-contracts-indy-besu"
DEPLOY_ARTIFACTS_DIR="/home/ubuntu/deploy-artifacts"
KEY_DIR="/home/ubuntu/besu-keys"

: "${S3_KEYS_BUCKET:?S3_KEYS_BUCKET não definido}"
: "${AWS_REGION:?AWS_REGION não definido}"
: "${NODE1_PRIVATE_IP:?NODE1_PRIVATE_IP não definido}"

NODE1_RPC="http://${NODE1_PRIVATE_IP}:8545"
NODE1_WS="ws://${NODE1_PRIVATE_IP}:8645"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check() {
  if [ $? -ne 0 ]; then log "ERRO: $1"; exit 1; fi
  log "OK: $1"
}

log "===== Setup Caliper B (workers remotos) ====="

# ============================================================================
# Passo 1 — Baixar artefatos do deploy do S3
# ============================================================================
log "Baixando artefatos do deploy do S3..."
mkdir -p "$DEPLOY_ARTIFACTS_DIR" "$KEY_DIR"

aws s3 cp "s3://$S3_KEYS_BUCKET/artifacts/network-info.json" \
  "$DEPLOY_ARTIFACTS_DIR/network-info.json" --region "$AWS_REGION"
check "Download de network-info.json do S3"

CHAIN_ID=$(jq -r '.chainId' "$DEPLOY_ARTIFACTS_DIR/network-info.json")
if [ -z "$CHAIN_ID" ] || [ "$CHAIN_ID" = "null" ]; then
  log "ERRO: chainId não encontrado em network-info.json"
  exit 1
fi
log "chainId: $CHAIN_ID"

aws s3 cp "s3://$S3_KEYS_BUCKET/artifacts/deployments/" \
  "$DEPLOY_ARTIFACTS_DIR/deployments/" --recursive --region "$AWS_REGION"
check "Download dos deployments do S3"

# ============================================================================
# Passo 1.5 — Baixar chave privada do Node-1 e permissions_config do S3
# ============================================================================
aws s3 cp "s3://$S3_KEYS_BUCKET/node-1/key" "$KEY_DIR/key" --region "$AWS_REGION"
check "Download da chave privada do Node-1 do S3"
chmod 600 "$KEY_DIR/key"

aws s3 cp "s3://$S3_KEYS_BUCKET/shared/permissions_config.toml" \
  "$KEY_DIR/permissions_config.toml" --region "$AWS_REGION"
check "Download do permissions_config.toml do S3"

# ============================================================================
# Passo 2 — Verificar que a rede Besu está ativa (via IP privado do Node-1)
# ============================================================================
log "Verificando se a rede Besu está ativa em $NODE1_RPC..."
BLOCK=$(curl -s --max-time 5 -X POST \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  "$NODE1_RPC" | jq -r '.result' || true)
if [ -z "$BLOCK" ] || [ "$BLOCK" = "null" ]; then
  log "ERRO: Rede Besu não está respondendo em $NODE1_RPC"
  exit 1
fi
log "Rede Besu ativa — bloco atual: $BLOCK"

# ============================================================================
# Passo 3 — Instalar Node.js v18 via NodeSource
# ============================================================================
if ! command -v node &>/dev/null; then
  log "Instalando Node.js v18 via NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - 2>>"$LOG_FILE"
  sudo apt-get install -y nodejs
  check "Node.js v18 instalado"
else
  log "Node.js já instalado: $(node --version)"
fi
log "node: $(node --version)  npm: $(npm --version)"

# ============================================================================
# Passo 4 — Clone do repositório de testes
# ============================================================================
if [ -d "$CLONE_ROOT" ]; then
  rm -rf "$CLONE_ROOT"
fi
git clone https://github.com/LeticiaNamie/tests-with-caliper.git "$CLONE_ROOT"
check "Clone do repositório tests-with-caliper"

# ============================================================================
# Passo 5 — Instalar Caliper CLI v0.5.0
# ============================================================================
log "Instalando Hyperledger Caliper CLI v0.5.0..."
cd "$CALIPER_ROOT"
# Sem passar o nome do pacote (já fixado em package.json) — passar o nome faz o
# npm pular os lifecycle scripts do projeto raiz (postinstall/patch-package), que
# é como o bugfix de transactionConfirmationBlocks/transactionBlockTimeout do
# ethereum-connector.js é reaplicado depois de cada clone fresco.
npm install --only=prod 2>>"$LOG_FILE"
check "Instalação do Caliper CLI"

# ============================================================================
# Passo 6 — Bind do Caliper com Hyperledger Besu
# ============================================================================
log "Realizando bind do Caliper com Hyperledger Besu..."
npx caliper bind --caliper-bind-sut besu:latest 2>>"$LOG_FILE"
check "Bind do Caliper com Besu"

# ============================================================================
# Passo 7 — Extrair endereços dos contratos
# ============================================================================
DEPLOYED_ADDRESSES="$DEPLOY_ARTIFACTS_DIR/deployments/chain-${CHAIN_ID}/deployed_addresses.json"
if [ ! -f "$DEPLOYED_ADDRESSES" ]; then
  log "ERRO: deployed_addresses.json não encontrado em $DEPLOYED_ADDRESSES"
  exit 1
fi

INDY_DID_ADDR=$(jq -r '."DeployAll#IndyDidRegistry"' "$DEPLOYED_ADDRESSES")
CREDENTIAL_DEF_ADDR=$(jq -r '."DeployAll#CredentialDefinitionRegistry"' "$DEPLOYED_ADDRESSES")
SCHEMA_ADDR=$(jq -r '."DeployAll#SchemaRegistry"' "$DEPLOYED_ADDRESSES")
REVOCATION_ADDR=$(jq -r '."DeployAll#RevocationRegistry"' "$DEPLOYED_ADDRESSES")

for VAR_NAME in INDY_DID_ADDR CREDENTIAL_DEF_ADDR SCHEMA_ADDR REVOCATION_ADDR; do
  VAL="${!VAR_NAME}"
  if [ -z "$VAL" ] || [ "$VAL" = "null" ]; then
    log "ERRO: endereço $VAR_NAME não encontrado em $DEPLOYED_ADDRESSES"
    exit 1
  fi
done
log "IndyDidRegistry:              $INDY_DID_ADDR"

# ============================================================================
# Passo 8 — Extrair fromAddress e chave privada
# ============================================================================
FROM_ADDRESS=$(grep "accounts-allowlist" "$KEY_DIR/permissions_config.toml" | \
  python3 -c "
import sys, json
line = sys.stdin.read().strip()
arr = json.loads(line.split('=', 1)[1].strip())
print(arr[0])
")
check "Extração do fromAddress"

FROM_PRIVATE_KEY=$(cat "$KEY_DIR/key" | tr -d '[:space:]')

# ============================================================================
# Passo 9 — Configurar networkconfig.json com dados dinâmicos (igual instância A)
# ============================================================================
log "Configurando networkconfig.json com dados dinâmicos..."
NETWORK_CONFIG="$CALIPER_ROOT/networks/besu/networkconfig.json"

python3 << PYEOF
import json, re

with open("$NETWORK_CONFIG", "r") as f:
    config = json.load(f)

def walk(obj, fn):
    if isinstance(obj, dict):
        fn(obj)
        for v in obj.values():
            walk(v, fn)
    elif isinstance(obj, list):
        for item in obj:
            walk(item, fn)

def fix_ws(obj):
    if "url" in obj and isinstance(obj["url"], str):
        obj["url"] = re.sub(r'ws://(?:127\.0\.0\.1|localhost):\d+', "$NODE1_WS", obj["url"])
walk(config, fix_ws)

def fix_rpc(obj):
    if "url" in obj and isinstance(obj["url"], str):
        obj["url"] = re.sub(r'http://(?:127\.0\.0\.1|localhost):\d+', "$NODE1_RPC", obj["url"])
walk(config, fix_rpc)

def fix_chain(obj):
    if "chainId" in obj:
        obj["chainId"] = $CHAIN_ID
walk(config, fix_chain)

def fix_account(obj):
    if "fromAddress" in obj:
        obj["fromAddress"] = "$FROM_ADDRESS"
    if "fromAddressPrivateKey" in obj:
        obj["fromAddressPrivateKey"] = "$FROM_PRIVATE_KEY"
    if "contractAddress" in obj:
        obj["contractAddress"] = "$INDY_DID_ADDR"
walk(config, fix_account)

contract_map = {
    "IndyDidRegistry":              "$INDY_DID_ADDR",
    "CredentialDefinitionRegistry": "$CREDENTIAL_DEF_ADDR",
    "SchemaRegistry":               "$SCHEMA_ADDR",
    "RevocationRegistry":           "$REVOCATION_ADDR",
}
def fix_contracts(obj):
    for name, addr in contract_map.items():
        if name in obj and isinstance(obj[name], dict) and "address" in obj[name]:
            obj[name]["address"] = addr
walk(config, fix_contracts)

with open("$NETWORK_CONFIG", "w") as f:
    json.dump(config, f, indent=2)

print("networkconfig.json atualizado com sucesso")
PYEOF
check "Configuração do networkconfig.json"

python3 -c "import json; json.load(open('$NETWORK_CONFIG')); print('JSON válido')"
check "Validação do networkconfig.json"

# ============================================================================
# Passo 10 — Deixar pronto o script pra lançar os workers remotos manualmente
# ============================================================================
cat > "$CALIPER_ROOT/launch_workers.sh" <<'EOF'
#!/usr/bin/env bash
# Uso: ./launch_workers.sh <IP_PRIVADO_DO_MANAGER> [NUM_WORKERS] [BENCHMARK_FILE]
set -euo pipefail
MANAGER_IP="${1:?informe o IP privado da instância A (manager), ex.: 10.0.1.30}"
NUM_WORKERS="${2:-16}"
BENCHMARK_FILE="${3:-benchmarks/scenario/IndyDidRegistry/config-createDid-distributed.yaml}"
BROKER_ADDRESS="mqtt://${MANAGER_IP}:1883"

cd "$(dirname "$0")"
rm -f /home/ubuntu/worker-remote-*.log
echo "Lançando $NUM_WORKERS workers, conectando em $BROKER_ADDRESS ..."
for i in $(seq 1 "$NUM_WORKERS"); do
  npx caliper launch worker \
    --caliper-workspace ./ \
    --caliper-benchconfig "$BENCHMARK_FILE" \
    --caliper-networkconfig networks/besu/networkconfig.json \
    --caliper-worker-communication-method mqtt \
    --caliper-worker-communication-address "$BROKER_ADDRESS" \
    > "/home/ubuntu/worker-remote-${i}.log" 2>&1 &
done
echo "Workers lançados. Acompanhe os logs em /home/ubuntu/worker-remote-*.log"
echo "Aguardando o round terminar (Ctrl+C não interrompe os workers em background)..."
wait
EOF
chmod +x "$CALIPER_ROOT/launch_workers.sh"
check "launch_workers.sh criado em $CALIPER_ROOT"

log "===== Setup Caliper B concluído — rode ./launch_workers.sh <IP-da-instancia-A> quando o manager estiver pronto ====="
