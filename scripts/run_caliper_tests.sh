#!/usr/bin/env bash
# Roda na instância Caliper via remote-exec.
# Baixa artefatos do S3, configura e executa os testes Caliper contra o Node-1.
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
: "${NODE_COUNT:?NODE_COUNT não definido}"

NODE1_RPC="http://${NODE1_PRIVATE_IP}:8545"
NODE1_WS="ws://${NODE1_PRIVATE_IP}:8645"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check() {
  if [ $? -ne 0 ]; then log "ERRO: $1"; exit 1; fi
  log "OK: $1"
}

log "===== INICIANDO ETAPA 3 — Testes com Caliper ====="

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
# Passo 3 — Garantir Python 3 instalado
# ============================================================================
if ! command -v python3 &>/dev/null; then
  log "Instalando Python 3..."
  sudo apt-get update -y && sudo apt-get install -y python3 python3-pip
  check "Instalação do Python 3"
else
  log "Python 3 já instalado: $(python3 --version)"
fi

# ============================================================================
# Passo 4 — Instalar Node.js v18 via NodeSource
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
# Passo 5 — Clone do repositório de testes
# ============================================================================
if [ -d "$CLONE_ROOT" ]; then
  rm -rf "$CLONE_ROOT"
fi
git clone https://github.com/LeticiaNamie/tests-with-caliper.git "$CLONE_ROOT"
check "Clone do repositório tests-with-caliper"

[ -f "$CALIPER_ROOT/run_test_local.py" ] || {
  log "ERRO: run_test_local.py não encontrado em $CALIPER_ROOT"
  exit 1
}
[ -d "$CALIPER_ROOT/src" ] || {
  log "ERRO: diretório src/ não encontrado em $CALIPER_ROOT"
  exit 1
}

# ============================================================================
# Passo 5.5 — Patchar campo include do monitor Prometheus nas configs do Caliper
# ============================================================================
# Cada config YAML tem: include: ["node1", "node2", ..., "node6"]
# Substitui pela lista correta para N nós.
log "Patchando include do monitor Prometheus para $NODE_COUNT nós..."
python3 << PYEOF
import os, re, glob

node_count = int(os.environ['NODE_COUNT'])
bench_dir = "$CALIPER_ROOT/benchmarks"

if not os.path.isdir(bench_dir):
    print(f'AVISO: {bench_dir} não encontrado, pulando patch')
    exit(0)

new_list = '[' + ', '.join(f'"node{i}"' for i in range(1, node_count + 1)) + ']'
pattern = re.compile(r'( *include: )\[(?:"node\d+",?\s*)+\]')

patched = 0
for path in glob.glob(bench_dir + '/**/*.yaml', recursive=True):
    text = open(path).read()
    new_text = pattern.sub(lambda m: m.group(1) + new_list, text)
    if new_text != text:
        open(path, 'w').write(new_text)
        print(f'Patchado: {os.path.basename(path)} → {new_list}')
        patched += 1

print(f'{patched} arquivo(s) patchado(s) para {node_count} nós')
PYEOF
check "Patch do include do monitor Prometheus"

# ============================================================================
# Passo 6 — Instalar Caliper CLI v0.5.0
# ============================================================================
log "Instalando Hyperledger Caliper CLI v0.5.0..."
cd "$CALIPER_ROOT"
npm install --only=prod @hyperledger/caliper-cli@0.5.0 2>>"$LOG_FILE"
check "Instalação do Caliper CLI"

# ============================================================================
# Passo 7 — Bind do Caliper com Hyperledger Besu
# ============================================================================
log "Realizando bind do Caliper com Hyperledger Besu..."
cd "$CALIPER_ROOT"
npx caliper bind --caliper-bind-sut besu:latest 2>>"$LOG_FILE"
check "Bind do Caliper com Besu"

# ============================================================================
# Passo 8 — Verificar artefatos do deploy e extrair endereços dos contratos
# ============================================================================
DEPLOYED_ADDRESSES="$DEPLOY_ARTIFACTS_DIR/deployments/chain-${CHAIN_ID}/deployed_addresses.json"
if [ ! -f "$DEPLOYED_ADDRESSES" ]; then
  log "ERRO: deployed_addresses.json não encontrado em $DEPLOYED_ADDRESSES"
  exit 1
fi
log "Artefatos do deploy encontrados"

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
log "CredentialDefinitionRegistry: $CREDENTIAL_DEF_ADDR"
log "SchemaRegistry:               $SCHEMA_ADDR"
log "RevocationRegistry:           $REVOCATION_ADDR"

# ============================================================================
# Passo 9 — Extrair fromAddress e chave privada (dos arquivos baixados do S3)
# ============================================================================
log "Extraindo fromAddress do permissions_config.toml..."
FROM_ADDRESS=$(grep "accounts-allowlist" "$KEY_DIR/permissions_config.toml" | \
  python3 -c "
import sys, json
line = sys.stdin.read().strip()
arr = json.loads(line.split('=', 1)[1].strip())
print(arr[0])
")
check "Extração do fromAddress"
log "fromAddress: $FROM_ADDRESS"

FROM_PRIVATE_KEY=$(cat "$KEY_DIR/key" | tr -d '[:space:]')
log "Chave privada do Node-1 obtida (valor omitido do log por segurança)"

# ============================================================================
# Passo 10 — Configurar networkconfig.json com dados dinâmicos
# ============================================================================
log "Configurando networkconfig.json com dados dinâmicos..."
NETWORK_CONFIG="$CALIPER_ROOT/networks/besu/networkconfig.json"

if [ ! -f "$NETWORK_CONFIG" ]; then
  log "ERRO: networkconfig.json não encontrado em $CALIPER_ROOT/networks/besu/"
  exit 1
fi

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

# Substitui qualquer URL WebSocket local pelo WS do Node-1 distribuído
def fix_ws(obj):
    if "url" in obj and isinstance(obj["url"], str):
        obj["url"] = re.sub(r'ws://(?:127\.0\.0\.1|localhost):\d+', "$NODE1_WS", obj["url"])
walk(config, fix_ws)

# Substitui URLs HTTP RPC locais pelo RPC do Node-1
def fix_rpc(obj):
    if "url" in obj and isinstance(obj["url"], str):
        obj["url"] = re.sub(r'http://(?:127\.0\.0\.1|localhost):\d+', "$NODE1_RPC", obj["url"])
walk(config, fix_rpc)

# chainId dinâmico
def fix_chain(obj):
    if "chainId" in obj:
        obj["chainId"] = $CHAIN_ID
walk(config, fix_chain)

# fromAddress, fromAddressPrivateKey e contractAddress (genérico)
def fix_account(obj):
    if "fromAddress" in obj:
        obj["fromAddress"] = "$FROM_ADDRESS"
    if "fromAddressPrivateKey" in obj:
        obj["fromAddressPrivateKey"] = "$FROM_PRIVATE_KEY"
    if "contractAddress" in obj:
        obj["contractAddress"] = "$INDY_DID_ADDR"
walk(config, fix_account)

# Endereços por nome de contrato
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
grep "$NODE1_PRIVATE_IP" "$NETWORK_CONFIG" >/dev/null || {
  log "AVISO: IP do Node-1 ($NODE1_PRIVATE_IP) não encontrado no networkconfig.json"
}

# ============================================================================
# Passo 10.5 — Instalar e iniciar Prometheus para monitoramento dos nós Besu
# ============================================================================
log "Instalando Prometheus..."
PROM_VERSION="2.48.1"
wget -q "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" \
  -O /tmp/prometheus.tar.gz 2>>"$LOG_FILE"
tar -xzf /tmp/prometheus.tar.gz -C /tmp/
check "Download e extração do Prometheus"

# Gera prometheus.yml dinamicamente para todos os N nós
# Node-1 e Node-3 (bootnodes) usam porta 9545; demais (validators) usam 9546
python3 << PYEOF
import os

node_count = int(os.environ['NODE_COUNT'])

lines = [
    "global:",
    "  scrape_interval: 5s",
    "  evaluation_interval: 5s",
    "",
    "scrape_configs:",
    "  - job_name: besu",
    "    static_configs:",
]

for i in range(1, node_count + 1):
    ip = f"10.0.1.{9 + i}"
    port = 9545 if i in (1, 3) else 9546
    lines.append(f"      - targets: ['{ip}:{port}']")
    lines.append(f"        labels:")
    lines.append(f"          instance: node{i}")

with open('/tmp/prometheus.yml', 'w') as f:
    f.write('\n'.join(lines) + '\n')

print(f"prometheus.yml gerado para {node_count} nós")
PYEOF

log "Iniciando Prometheus em background (porta 9090)..."
/tmp/prometheus-${PROM_VERSION}.linux-amd64/prometheus \
  --config.file=/tmp/prometheus.yml \
  --storage.tsdb.path=/tmp/prometheus-data \
  --web.listen-address=:9090 \
  >> "$LOG_FILE" 2>&1 &

# Aguarda Prometheus aceitar requisições
for i in $(seq 1 12); do
  if curl -s -f http://localhost:9090/-/ready >/dev/null 2>&1; then
    log "Prometheus pronto"
    break
  fi
  log "Aguardando Prometheus... ($i/12)"
  sleep 5
done
curl -s -f http://localhost:9090/-/ready >/dev/null 2>&1
check "Prometheus iniciado na porta 9090"

# Aguarda pelo menos um ciclo de scrape dos dois nós
log "Aguardando primeiro scrape dos nós Besu..."
for i in $(seq 1 12); do
  UP=$(curl -s "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22besu%22%7D" \
    | python3 -c "import sys,json; r=json.load(sys.stdin); print(sum(1 for x in r['data']['result'] if x['value'][1]=='1'))" 2>/dev/null || echo 0)
  if [ "$UP" -eq "$NODE_COUNT" ]; then
    log "Todos os $NODE_COUNT nós Besu respondendo ao Prometheus"
    break
  fi
  log "Aguardando scrape dos nós Besu ($UP/$NODE_COUNT up)... ($i/12)"
  sleep 5
done
[ "$UP" -eq "$NODE_COUNT" ] || log "AVISO: nem todos os nós estão sendo scraped (UP=$UP/$NODE_COUNT). Verifique métricas após o teste."

# ============================================================================
# Passo 11 — Executar os testes com Caliper
# ============================================================================
log "Executando testes com Caliper (run_test_local.py)..."
cd "$CALIPER_ROOT"
# setup_issuer.js usa HTTP_RPC_URL como fallback (padrão 127.0.0.1 não funciona em EC2 separada)
export HTTP_RPC_URL="http://${NODE1_PRIVATE_IP}:8545"
# Roda em background para não bloquear o pipe do SSH
# Workers do Caliper herdavam o pipe e mantinham o tee aberto indefinidamente
python3 run_test_local.py >> "$LOG_FILE" 2>&1

# ============================================================================
# Passo 12 — Extrair resultados para CSV
# ============================================================================
log "Instalando dependências Python para extração de resultados..."
if ! python3 -m pip --version &>/dev/null; then
  sudo apt-get install -y python3-pip 2>>"$LOG_FILE"
  check "Instalação do pip"
fi
python3 -m pip install --quiet pandas beautifulsoup4 lxml 2>>"$LOG_FILE"
check "Instalação de pandas e beautifulsoup4"

log "Extraindo relatório de resultados para CSV..."
cd "$CALIPER_ROOT/src"
python3 extract_report_to_csv.py 2>&1 | tee -a "$LOG_FILE"
check "extract_report_to_csv.py"

log "Extraindo dados de recursos para CSV..."
python3 extract_resource_to_csv.py 2>&1 | tee -a "$LOG_FILE"
check "extract_resource_to_csv.py"

log "Arquivos CSV gerados:"
find "$CALIPER_ROOT" -name "*.csv" | tee -a "$LOG_FILE"

# ============================================================================
# Passo 13 — Upload dos CSVs para S3
# ============================================================================
log "Enviando CSVs para s3://$S3_KEYS_BUCKET/caliper-results/..."
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
S3_PREFIX="s3://$S3_KEYS_BUCKET/caliper-results/$TIMESTAMP"
CSV_COUNT=0

for DIR in "$CALIPER_ROOT/src/"*_resource_metrics_by_tps; do
  if [ -d "$DIR" ]; then
    DIRNAME=$(basename "$DIR")
    aws s3 cp "$DIR/" "${S3_PREFIX}/resource_metrics/${DIRNAME}/" \
      --recursive --exclude "*" --include "*.csv" --region "$AWS_REGION"
    CSV_COUNT=$((CSV_COUNT + $(find "$DIR" -name "*.csv" | wc -l)))
  fi
done

for DIR in "$CALIPER_ROOT/src/reports/"*; do
  if [ -d "$DIR" ]; then
    DIRNAME=$(basename "$DIR")
    aws s3 cp "$DIR/" "${S3_PREFIX}/reports/${DIRNAME}/" \
      --recursive --exclude "*" --include "*.csv" --region "$AWS_REGION"
    CSV_COUNT=$((CSV_COUNT + $(find "$DIR" -name "*.csv" | wc -l)))
  fi
done

log "OK: $CSV_COUNT arquivo(s) CSV enviado(s) para $S3_PREFIX"
aws s3 ls "${S3_PREFIX}/" --recursive --region "$AWS_REGION" | tee -a "$LOG_FILE"
check "Upload dos CSVs para S3"

log "===== ETAPA 3 CONCLUÍDA COM SUCESSO ====="
