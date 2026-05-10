#!/bin/bash
set -e

LOG_FILE="/var/log/besu-setup.log"
sudo chmod a+w "$LOG_FILE"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | sudo tee -a "$LOG_FILE"
}

check() {
  if [ $? -ne 0 ]; then
    log "ERRO: $1"
    exit 1
  else
    log "OK: $1"
  fi
}

log "===== INICIANDO ETAPA 2 —  Deploy dos Contratos Inteligentes ====="

# ============================================================================
# Passo 1: Verificar que a rede Besu está ativa
# ============================================================================
log "Verificando se a rede Besu está ativa"
for attempt in {1..30}; do
  BLOCK=$(curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545 | jq -r '.result')
  if [ -z "$BLOCK" ] || [ "$BLOCK" = "null" ]; then
    if [ $attempt -eq 30 ]; then
      log "ERRO: Rede Besu não está produzindo blocos após 30 tentativas. Execute a Etapa 1 primeiro."
      exit 1
    fi
    log "Tentativa $attempt: Aguardando rede Besu ficar ativa..."
    sleep 10
  else
    log "Rede Besu ativa — bloco atual: $BLOCK"
    break
  fi
done

# ============================================================================
# Passo 2: Instalação do Node.js v18
# ============================================================================
log "Instalando Node.js v18 via NodeSource"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
check "Instalação do Node.js v18"

log "Node.js version: $(node --version)"
log "npm version: $(npm --version)"

# ============================================================================
# Passo 3: Clone do repositório dos contratos
# ============================================================================
CONTRACTS_ROOT="/home/ubuntu/contracts-indy-besu"

if [ -d "$CONTRACTS_ROOT" ]; then
  log "Removendo clone anterior de $CONTRACTS_ROOT"
  rm -rf "$CONTRACTS_ROOT"
fi

log "Clonando repositório contracts-indy-besu"
git clone https://github.com/jeffsonsousa/contracts-indy-besu.git "$CONTRACTS_ROOT"
check "Clone do repositório"

if [ ! -f "$CONTRACTS_ROOT/hardhat.config.ts" ]; then
  log "ERRO: Arquivo hardhat.config.ts não encontrado em $CONTRACTS_ROOT"
  exit 1
fi
log "Repositório clonado com sucesso"

# ============================================================================
# Passo 4: Obter chainId dinamicamente
# ============================================================================
log "Obtendo chainId da rede Besu"
CHAIN_ID_HEX=$(curl -s -X POST \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://127.0.0.1:8545 | jq -r '.result')

if [ -z "$CHAIN_ID_HEX" ] || [ "$CHAIN_ID_HEX" = "null" ]; then
  log "ERRO: Não foi possível obter o chainId"
  exit 1
fi

# Converter hex para decimal
CHAIN_ID=$(python3 -c "print(int('$CHAIN_ID_HEX', 16))")
log "chainId obtido: $CHAIN_ID_HEX (hex) = $CHAIN_ID (decimal)"

# ============================================================================
# Passo 5: Obter chave privada do Node-1
# ============================================================================
log "Obtendo chave privada do Node-1"
KEY_FILE="/home/ubuntu/besu-production-docker/Permissioned-Network/Node-1/data/key"

if [ ! -f "$KEY_FILE" ]; then
  log "ERRO: Arquivo de chave privada não encontrado em $KEY_FILE"
  exit 1
fi

PRIVATE_KEY="$(cat $KEY_FILE | tr -d '[:space:]')"
log "Chave privada do Node-1 obtida com sucesso (não será exibida por segurança)"

# ============================================================================
# Passo 6: Gerar o hardhat.config.ts com valores dinâmicos
# ============================================================================
log "Gerando hardhat.config.ts com chainId e chave privada dinâmicos"
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
check "Geração do hardhat.config.ts"

log "Validando hardhat.config.ts"
CHAIN_ID_IN_CONFIG=$(grep -oP 'chainId: \K\d+' "$CONTRACTS_ROOT/hardhat.config.ts")
if [ "$CHAIN_ID_IN_CONFIG" != "$CHAIN_ID" ]; then
  log "ERRO: chainId no hardhat.config.ts não corresponde ao valor obtido"
  exit 1
fi
log "chainId $_IN_CONFIG correspondente: $CHAIN_ID_IN_CONFIG"

# ============================================================================
# Passo 7: Instalar dependências npm
# ============================================================================
log "Instalando dependências npm"
cd "$CONTRACTS_ROOT"
npm install
check "npm install"

if [ ! -d "$CONTRACTS_ROOT/node_modules" ]; then
  log "ERRO: Pasta node_modules não foi criada após npm install"
  exit 1
fi
log "Dependências npm instaladas com sucesso"

# ============================================================================
# Passo 8: Compilar os contratos
# ============================================================================
log "Compilando contratos com Hardhat"
npx hardhat compile
check "npx hardhat compile"

if [ ! -d "$CONTRACTS_ROOT/artifacts" ]; then
  log "ERRO: Pasta artifacts não foi criada após npm compile"
  exit 1
fi
log "Contratos compilados com sucesso"

# ============================================================================
# Passo 9: Deploy dos contratos via Hardhat Ignition
# ============================================================================
log "Fazendo deploy dos contratos via Hardhat Ignition"
DEPLOY_OUTPUT=$(echo "y" | npx hardhat ignition deploy \
  ./ignition/modules/DeployAndInitializeContracts.ts \
  --network local 2>&1) || {
  log "ERRO: Deploy dos contratos falhou"
  echo "$DEPLOY_OUTPUT" >> "$LOG_FILE"
  exit 1
}

echo "$DEPLOY_OUTPUT" >> "$LOG_FILE"
log "Deploy dos contratos executado"

# ============================================================================
# Passo 10: Registrar endereços dos contratos implantados
# ============================================================================
log "Endereços dos contratos implantados:"
echo "$DEPLOY_OUTPUT" | grep -E "0x[a-fA-F0-9]{40}" >> "$LOG_FILE" 2>&1 || {
  log "AVISO: Nenhum endereço de contrato encontrado no output. Verificando journal de deployment..."
}

# ============================================================================
# Passo 11: Salvar artefatos do deploy
# ============================================================================
log "Salvando artefatos do deploy"
DEPLOY_ARTIFACTS_DIR="/home/ubuntu/deploy-artifacts"
mkdir -p "$DEPLOY_ARTIFACTS_DIR"

# Copiar journal do Ignition com endereços e estado do deploy
if [ -d "$CONTRACTS_ROOT/ignition/deployments" ]; then
  cp -r "$CONTRACTS_ROOT/ignition/deployments/" "$DEPLOY_ARTIFACTS_DIR/" 2>/dev/null || {
    log "AVISO: Pasta ignition/deployments não encontrada ou não pôde ser copiada"
  }
fi

# Salvar chainId e informações da rede em arquivo JSON para referência
cat > "$DEPLOY_ARTIFACTS_DIR/network-info.json" << JSON
{
  "chainId": $CHAIN_ID,
  "chainIdHex": "$CHAIN_ID_HEX",
  "rpcUrl": "http://127.0.0.1:8545",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
check "Criação do network-info.json"

log "Artefatos salvos em $DEPLOY_ARTIFACTS_DIR"
log "===== ETAPA 2 CONCLUÍDA COM SUCESSO ====="
