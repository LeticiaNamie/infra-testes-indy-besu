#!/usr/bin/env bash
# Roda no Node-1 via remote-exec.
# Faz deploy dos contratos Indy na rede Besu já em execução.
set -euo pipefail

LOG_FILE="/home/ubuntu/besu-setup.log"
export PATH="/usr/local/bin:$PATH"

CONTRACTS_ROOT="/home/ubuntu/contracts-indy-besu"
KEY_FILE="/home/ubuntu/besu-production-docker-distributed/Permissioned-Network/Node-1/data/key"
DEPLOY_ARTIFACTS_DIR="/home/ubuntu/deploy-artifacts"

: "${S3_KEYS_BUCKET:?S3_KEYS_BUCKET não definido}"
: "${AWS_REGION:?AWS_REGION não definido}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check() {
  if [ $? -ne 0 ]; then log "ERRO: $1"; exit 1; fi
  log "OK: $1"
}

log "===== INICIANDO ETAPA 2 — Deploy dos Contratos Inteligentes ====="

# ============================================================================
# Passo 1 — Confirma que a rede está produzindo blocos
# ============================================================================
log "Verificando se o RPC do Besu está respondendo..."
for i in $(seq 1 20); do
  BLOCK=$(curl -s --max-time 5 -X POST \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://127.0.0.1:8545 2>/dev/null | jq -r '.result' || true)
  if [ -n "$BLOCK" ] && [ "$BLOCK" != "null" ]; then
    log "RPC respondendo — bloco atual: $BLOCK"
    break
  fi
  if [ "$i" = "20" ]; then
    log "ERRO: RPC do Besu não responde após 3 minutos"
    exit 1
  fi
  log "Tentativa $i/20: aguardando RPC..."
  sleep 10
done

# ============================================================================
# Passo 2 — Instalação do Node.js v18
# ============================================================================
log "Instalando Node.js v18 via NodeSource..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - 2>> "$LOG_FILE"
sudo apt-get install -y nodejs
check "Node.js v18 instalado"
log "node: $(node --version)  npm: $(npm --version)"

# ============================================================================
# Passo 3 — Clone do repositório dos contratos
# ============================================================================
if [ -d "$CONTRACTS_ROOT" ]; then
  rm -rf "$CONTRACTS_ROOT"
fi
git clone https://github.com/jeffsonsousa/contracts-indy-besu.git "$CONTRACTS_ROOT"
check "Clone do repositório contracts-indy-besu"

# ============================================================================
# Passo 4 — chainId dinâmico
# ============================================================================
log "Obtendo chainId da rede Besu..."
CHAIN_ID_HEX=$(curl -s --max-time 5 -X POST \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://127.0.0.1:8545 | jq -r '.result')

if [ -z "$CHAIN_ID_HEX" ] || [ "$CHAIN_ID_HEX" = "null" ]; then
  log "ERRO: não foi possível obter chainId"
  exit 1
fi

CHAIN_ID=$(python3 -c "print(int('$CHAIN_ID_HEX', 16))")
log "chainId: $CHAIN_ID_HEX (hex) = $CHAIN_ID (decimal)"

# ============================================================================
# Passo 5 — Chave privada do Node-1
# ============================================================================
if [ ! -f "$KEY_FILE" ]; then
  log "ERRO: chave privada não encontrada em $KEY_FILE"
  exit 1
fi
PRIVATE_KEY="$(cat "$KEY_FILE" | tr -d '[:space:]')"
log "Chave privada do Node-1 obtida (valor omitido do log por segurança)"

# ============================================================================
# Passo 6 — hardhat.config.ts com valores dinâmicos
# ============================================================================
log "Gerando hardhat.config.ts..."
cat > "$CONTRACTS_ROOT/hardhat.config.ts" << HARDHAT
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const config: HardhatUserConfig = {
  solidity: "0.8.24",
  networks: {
    local: {
      url: "http://127.0.0.1:8545",
      chainId: $CHAIN_ID,
      accounts: ["$PRIVATE_KEY"]
    }
  }
};

export default config;
HARDHAT
check "hardhat.config.ts gerado"

# ============================================================================
# Passo 7 — npm install
# ============================================================================
cd "$CONTRACTS_ROOT"
log "Instalando dependências npm..."
npm install 2>> "$LOG_FILE"
check "npm install"

# ============================================================================
# Passo 8 — Compilar contratos
# ============================================================================
log "Compilando contratos com Hardhat..."
npx hardhat compile 2>> "$LOG_FILE"
check "npx hardhat compile"

# ============================================================================
# Passo 9 — Deploy via Hardhat Ignition
# ============================================================================
log "Fazendo deploy via Hardhat Ignition..."
DEPLOY_OUTPUT=$(echo "y" | npx hardhat ignition deploy \
  ./ignition/modules/DeployAndInitializeContracts.ts \
  --network local 2>&1) || {
  log "ERRO: deploy falhou"
  echo "$DEPLOY_OUTPUT" | tee -a "$LOG_FILE"
  exit 1
}
echo "$DEPLOY_OUTPUT" | tee -a "$LOG_FILE"
check "Deploy dos contratos"

log "Endereços implantados:"
echo "$DEPLOY_OUTPUT" | grep -E "0x[a-fA-F0-9]{40}" | tee -a "$LOG_FILE" || true

# ============================================================================
# Passo 10 — Salvar artefatos localmente
# ============================================================================
mkdir -p "$DEPLOY_ARTIFACTS_DIR"

if [ -d "$CONTRACTS_ROOT/ignition/deployments" ]; then
  cp -r "$CONTRACTS_ROOT/ignition/deployments/" "$DEPLOY_ARTIFACTS_DIR/"
  check "Cópia do journal Ignition para deploy-artifacts"
else
  log "AVISO: ignition/deployments não encontrado"
fi

cat > "$DEPLOY_ARTIFACTS_DIR/network-info.json" << JSON
{
  "chainId": $CHAIN_ID,
  "chainIdHex": "$CHAIN_ID_HEX",
  "rpcUrl": "http://127.0.0.1:8545",
  "rpcWsUrl": "ws://127.0.0.1:8645",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
check "network-info.json criado"

# ============================================================================
# Passo 11 — Upload dos artefatos para S3
# ============================================================================
log "Fazendo upload dos artefatos para S3..."
aws s3 cp "$DEPLOY_ARTIFACTS_DIR/network-info.json" \
  "s3://$S3_KEYS_BUCKET/artifacts/network-info.json" \
  --region "$AWS_REGION"
check "network-info.json enviado para S3"

if [ -d "$DEPLOY_ARTIFACTS_DIR/deployments" ]; then
  aws s3 cp "$DEPLOY_ARTIFACTS_DIR/deployments/" \
    "s3://$S3_KEYS_BUCKET/artifacts/deployments/" \
    --recursive \
    --region "$AWS_REGION"
  check "journal Ignition enviado para S3"
fi

log "Artefatos disponíveis em s3://$S3_KEYS_BUCKET/artifacts/"
log "===== ETAPA 2 CONCLUÍDA COM SUCESSO ====="
