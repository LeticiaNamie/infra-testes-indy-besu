#!/bin/bash
set -euo pipefail

# ============================================================================
# Etapa 3 — Passos 1 a 11: Setup do Caliper, configuração e execução dos testes
# Executado como ubuntu via SSH (remote-exec).
# ============================================================================

LOG_FILE="/var/log/besu-setup.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check() {
  if [ $? -ne 0 ]; then
    log "ERRO: $1"
    exit 1
  else
    log "OK: $1"
  fi
}

CLONE_ROOT="/home/ubuntu/tests-with-caliper"
CALIPER_ROOT="$CLONE_ROOT/evaluation-contracts-indy-besu"
DEPLOY_ARTIFACTS_DIR="/home/ubuntu/deploy-artifacts"
BESU_ROOT="/home/ubuntu/besu-production-docker"

log "======== Etapa 3 — Início (passos 1-11) ========"

# ============================================================================
# Garantir permissão de acesso ao Docker socket
# O Caliper monitora containers via /var/run/docker.sock. Se ubuntu não estiver
# no grupo docker, o monitoramento falha com EACCES. O usermod não tem efeito
# na sessão atual, então o script se re-executa via sg para que o grupo docker
# esteja ativo sem precisar de novo login.
# ============================================================================
if ! id -nG "$USER" | grep -qw docker; then
  log "Adicionando $USER ao grupo docker e re-executando com permissões corretas"
  sudo usermod -aG docker "$USER"
  check "Adição de $USER ao grupo docker"
  exec sg docker "$0"
fi
log "OK: $USER pertence ao grupo docker"

# ============================================================================
# Passo 1 — Verificar artefatos da Etapa 2
# ============================================================================
log "[Passo 1] Verificando artefatos do deploy da Etapa 2"

NETWORK_INFO="$DEPLOY_ARTIFACTS_DIR/network-info.json"
if [ ! -f "$NETWORK_INFO" ]; then
  log "ERRO: Arquivo $NETWORK_INFO não encontrado. Execute a Etapa 2 primeiro."
  exit 1
fi

CHAIN_ID=$(jq -r '.chainId' "$NETWORK_INFO")
if [ -z "$CHAIN_ID" ] || [ "$CHAIN_ID" = "null" ]; then
  log "ERRO: Não foi possível obter o chainId de $NETWORK_INFO"
  exit 1
fi
log "chainId da Etapa 2: $CHAIN_ID"

DEPLOYED_ADDRESSES="$DEPLOY_ARTIFACTS_DIR/deployments/chain-${CHAIN_ID}/deployed_addresses.json"
if [ ! -f "$DEPLOYED_ADDRESSES" ]; then
  log "ERRO: Arquivo de endereços não encontrado em $DEPLOYED_ADDRESSES"
  exit 1
fi
log "OK: Artefatos da Etapa 2 encontrados"

# ============================================================================
# Passo 2 — Verificar que a rede Besu está ativa
# ============================================================================
log "[Passo 2] Verificando se a rede Besu está ativa"

BLOCK=$(curl -s -X POST \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://127.0.0.1:8545 | jq -r '.result')

if [ -z "$BLOCK" ] || [ "$BLOCK" = "null" ]; then
  log "ERRO: Rede Besu não está respondendo em http://127.0.0.1:8545. Verifique a Etapa 1."
  exit 1
fi
log "OK: Rede Besu ativa — bloco atual: $BLOCK"

# ============================================================================
# Passo 3 — Garantir Python 3 instalado
# ============================================================================
log "[Passo 3] Verificando instalação do Python 3"

if ! command -v python3 &> /dev/null; then
  log "Python 3 não encontrado. Instalando..."
  sudo apt-get update -y && sudo apt-get install -y python3 python3-pip
  check "Instalação do Python 3"
else
  log "OK: Python 3 já instalado: $(python3 --version)"
fi

# ============================================================================
# Passo 4 — Clone do repositório de testes
# ============================================================================
log "[Passo 4] Clonando repositório tests-with-caliper"

if [ -d "$CLONE_ROOT" ]; then
  log "Removendo clone anterior em $CLONE_ROOT"
  rm -rf "$CLONE_ROOT"
fi

git clone https://github.com/LeticiaNamie/tests-with-caliper.git "$CLONE_ROOT"
check "Clone do repositório tests-with-caliper"

if [ ! -f "$CALIPER_ROOT/run_test_local.py" ]; then
  log "ERRO: run_test_local.py não encontrado no repositório clonado"
  exit 1
fi
if [ ! -d "$CALIPER_ROOT/src" ]; then
  log "ERRO: diretório src/ não encontrado no repositório clonado"
  exit 1
fi
log "OK: Repositório clonado e estrutura validada"

# ============================================================================
# Passo 5 — Instalar o Caliper CLI
# ============================================================================
log "[Passo 5] Instalando Hyperledger Caliper CLI v0.5.0"

cd "$CALIPER_ROOT"
npm install --only=prod @hyperledger/caliper-cli@0.5.0
check "Instalação do Caliper CLI"

CALIPER_VERSION=$(./node_modules/.bin/caliper --version 2>/dev/null || true)
log "OK: Caliper instalado — versão: $CALIPER_VERSION"

# ============================================================================
# Passo 6 — Bind do Caliper com Hyperledger Besu
# ============================================================================
log "[Passo 6] Realizando bind do Caliper com Hyperledger Besu"

cd "$CALIPER_ROOT"
npx caliper bind --caliper-bind-sut besu:latest
check "Bind do Caliper com Besu"
log "OK: Bind concluído"

# ============================================================================
# Passo 7 — Extrair endereços dos contratos deployados na Etapa 2
# ============================================================================
log "[Passo 7] Extraindo endereços dos contratos de $DEPLOYED_ADDRESSES"

INDY_DID_ADDR=$(jq -r '."DeployAll#IndyDidRegistry"' "$DEPLOYED_ADDRESSES")
CREDENTIAL_DEF_ADDR=$(jq -r '."DeployAll#CredentialDefinitionRegistry"' "$DEPLOYED_ADDRESSES")
SCHEMA_ADDR=$(jq -r '."DeployAll#SchemaRegistry"' "$DEPLOYED_ADDRESSES")
REVOCATION_ADDR=$(jq -r '."DeployAll#RevocationRegistry"' "$DEPLOYED_ADDRESSES")

for VAR_NAME in INDY_DID_ADDR CREDENTIAL_DEF_ADDR SCHEMA_ADDR REVOCATION_ADDR; do
  VAL="${!VAR_NAME}"
  if [ -z "$VAL" ] || [ "$VAL" = "null" ]; then
    log "ERRO: Endereço $VAR_NAME não encontrado em $DEPLOYED_ADDRESSES"
    exit 1
  fi
done

log "IndyDidRegistry:              $INDY_DID_ADDR"
log "CredentialDefinitionRegistry: $CREDENTIAL_DEF_ADDR"
log "SchemaRegistry:               $SCHEMA_ADDR"
log "RevocationRegistry:           $REVOCATION_ADDR"
log "OK: Endereços dos contratos extraídos"

# ============================================================================
# Passo 8 — Extrair fromAddress e chave privada do Node-1
# ============================================================================
log "[Passo 8] Extraindo fromAddress e chave privada"

PERMISSIONS_FILE="$BESU_ROOT/Permissioned-Network/permissions_config.toml"
if [ ! -f "$PERMISSIONS_FILE" ]; then
  log "ERRO: Arquivo $PERMISSIONS_FILE não encontrado"
  exit 1
fi

FROM_ADDRESS=$(grep "accounts-allowlist" "$PERMISSIONS_FILE" | \
  python3 -c "
import sys, json
line = sys.stdin.read().strip()
arr = json.loads(line.split('=', 1)[1].strip())
print(arr[0])
")
check "Extração do fromAddress"
log "fromAddress: $FROM_ADDRESS"

KEY_FILE="$BESU_ROOT/Permissioned-Network/Node-1/data/key"
if [ ! -f "$KEY_FILE" ]; then
  log "ERRO: Arquivo de chave privada não encontrado em $KEY_FILE"
  exit 1
fi
FROM_PRIVATE_KEY=$(cat "$KEY_FILE")
log "OK: Chave privada do Node-1 obtida (valor não logado por segurança)"

# ============================================================================
# Passo 9 — Configurar o networkconfig.json
# ============================================================================
log "[Passo 9] Configurando networkconfig.json"

NETWORK_CONFIG="$CALIPER_ROOT/networks/besu/networkconfig.json"
if [ ! -f "$NETWORK_CONFIG" ]; then
  log "ERRO: Arquivo networkconfig.json não encontrado em $CALIPER_ROOT"
  exit 1
fi

log "Backup do networkconfig.json original em ${NETWORK_CONFIG}.bak"
cp "$NETWORK_CONFIG" "${NETWORK_CONFIG}.bak"

python3 << PYEOF
import json

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

# Fix porta WebSocket: 8546 → 8645
def fix_ws(obj):
    if "url" in obj and isinstance(obj["url"], str):
        obj["url"] = obj["url"].replace("ws://127.0.0.1:8546", "ws://127.0.0.1:8645")
walk(config, fix_ws)

# Fix chainId
def fix_chain(obj):
    if "chainId" in obj:
        obj["chainId"] = $CHAIN_ID
walk(config, fix_chain)

# Fix fromAddress, fromAddressPrivateKey e contractAddress (IndyDidRegistry é o contrato principal)
def fix_account(obj):
    if "fromAddress" in obj:
        obj["fromAddress"] = "$FROM_ADDRESS"
    if "fromAddressPrivateKey" in obj:
        obj["fromAddressPrivateKey"] = "$FROM_PRIVATE_KEY"
    if "contractAddress" in obj:
        obj["contractAddress"] = "$INDY_DID_ADDR"
walk(config, fix_account)

# Fix endereços dos contratos por nome
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

# Validação: JSON válido e porta correta aplicada
python3 -c "import json; c = json.load(open('$NETWORK_CONFIG')); print('JSON válido')"
check "Validação do networkconfig.json (JSON parsing)"

if grep -q "8645" "$NETWORK_CONFIG"; then
  log "OK: Porta WebSocket 8645 confirmada no networkconfig.json"
else
  log "AVISO: Porta 8645 não encontrada no networkconfig.json — verifique se o campo 'url' ws existe no arquivo"
fi

# ============================================================================
# Passo 10 — Executar os testes com Caliper
# ============================================================================
log "[Passo 10] Executando testes com Caliper (run_test_local.py)"

cd "$CALIPER_ROOT"
python3 run_test_local.py 2>&1 | tee -a "$LOG_FILE"
check "Execução dos testes com Caliper"

# ============================================================================
# Passo 11 — Extrair resultados para CSV
# ============================================================================
log "[Passo 11] Extraindo resultados para CSV"

log "Instalando dependências Python para extração de resultados"
pip3 install --quiet pandas beautifulsoup4 lxml
check "Instalação de pandas e beautifulsoup4"

cd "$CALIPER_ROOT/src"
python3 extract_report_to_csv.py 2>&1 | tee -a "$LOG_FILE"
check "extract_report_to_csv.py"

python3 extract_resource_to_csv.py 2>&1 | tee -a "$LOG_FILE"
check "extract_resource_to_csv.py"

log "Arquivos CSV gerados:"
find "$CALIPER_ROOT" -name "*.csv" | tee -a "$LOG_FILE"

log "======== Etapa 3 — Concluída com sucesso (passos 1-11) ========"