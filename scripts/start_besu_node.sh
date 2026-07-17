#!/usr/bin/env bash
# Roda em cada nó via remote-exec.
# Node-1: o repo já existe (gerado em generate_and_distribute_keys.sh); só faz o build e sobe.
# Node-2: clona o repo, baixa JDK/Besu, baixa chaves do S3, faz build e sobe.
set -euo pipefail

LOG_FILE="/home/ubuntu/besu-setup.log"
export PATH="/usr/local/bin:$PATH"
REPO_ROOT="/home/ubuntu/besu-production-docker-distributed"
JDK_TAR="jdk-21.0.6_linux-x64_bin.tar.gz"
JDK_DIR="jdk-21.0.6"
BESU_TAR="besu-24.7.0.tar.gz"

: "${NODE_INDEX:?NODE_INDEX não definido}"
: "${S3_KEYS_BUCKET:?S3_KEYS_BUCKET não definido}"
: "${AWS_REGION:?AWS_REGION não definido}"

# Node-1 e Node-3: bootnodes → docker-compose.bootnode.yaml (RPC em 8545)
# Todos os demais: validators → docker-compose.validator.yaml (RPC em 8546)
if [ "$NODE_INDEX" = "1" ] || [ "$NODE_INDEX" = "3" ]; then
  COMPOSE_FILE="docker-compose.bootnode.yaml"
  RPC_PORT=8545
else
  COMPOSE_FILE="docker-compose.validator.yaml"
  RPC_PORT=8546
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check() {
  if [ $? -ne 0 ]; then log "ERRO: $1"; exit 1; fi
  log "OK: $1"
}

log "=== Iniciando Node-$NODE_INDEX com $COMPOSE_FILE ==="

# Todos os nós exceto Node-1 precisam clonar o repo e baixar chaves do S3
# (Node-1 já tem o repo clonado de generate_and_distribute_keys.sh)
if [ "$NODE_INDEX" != "1" ]; then
  if [ -d "$REPO_ROOT" ]; then rm -rf "$REPO_ROOT"; fi
  git clone https://github.com/LeticiaNamie/besu-production-docker-distributed.git "$REPO_ROOT"
  check "Clone do repositório"

  cd "$REPO_ROOT"

  log "Baixando JDK 21..."
  wget -q "https://download.oracle.com/java/21/archive/$JDK_TAR"
  check "Download do JDK 21"
  tar -xf "$JDK_TAR" && rm -f "$JDK_TAR"
  check "Extração do JDK 21"

  log "Baixando Besu 24.7.0..."
  wget -q "https://github.com/hyperledger/besu/releases/download/24.7.0/$BESU_TAR"
  check "Download do Besu"
  tar -xf "$BESU_TAR" && rm -f "$BESU_TAR"
  check "Extração do Besu"

  # O caminho de dados deve coincidir com o volume mount do compose file:
  # bootnode.yaml → Permissioned-Network/Node-1/data
  # validator.yaml → Permissioned-Network/Node-2/data
  # Como cada nó está em EC2 próprio, Node-3 coloca suas chaves em Node-1/data/
  # e Node-4/5/6 colocam em Node-2/data/ — o que o compose file espera encontrar.
  if [ "$COMPOSE_FILE" = "docker-compose.bootnode.yaml" ]; then
    NODE_DATA="$REPO_ROOT/Permissioned-Network/Node-1/data"
  else
    NODE_DATA="$REPO_ROOT/Permissioned-Network/Node-2/data"
  fi
  mkdir -p "$NODE_DATA"
  check "Criação do diretório de dados ($NODE_DATA)"

  # Baixa chaves e configurações do S3
  log "Baixando chaves e configs do S3..."
  aws s3 cp "s3://$S3_KEYS_BUCKET/node-$NODE_INDEX/key"                "$NODE_DATA/key"                     --region "$AWS_REGION"
  aws s3 cp "s3://$S3_KEYS_BUCKET/node-$NODE_INDEX/key.pub"            "$NODE_DATA/key.pub"                 --region "$AWS_REGION"
  aws s3 cp "s3://$S3_KEYS_BUCKET/shared/genesis.json"                 "$NODE_DATA/genesis.json"            --region "$AWS_REGION"
  aws s3 cp "s3://$S3_KEYS_BUCKET/shared/static-nodes.json"            "$NODE_DATA/static-nodes.json"       --region "$AWS_REGION"
  aws s3 cp "s3://$S3_KEYS_BUCKET/shared/permissions_config.toml"      "$NODE_DATA/permissions_config.toml" --region "$AWS_REGION"
  check "Chaves e configurações baixadas do S3"

  # genesis.json também precisa estar na raiz para referências do compose
  aws s3 cp "s3://$S3_KEYS_BUCKET/shared/genesis.json" "$REPO_ROOT/genesis.json" --region "$AWS_REGION"
  check "genesis.json copiado para raiz do repositório"

  # Validators (2, 4, 5, 6): substitui docker-compose.validator.yaml pela versão
  # patchada do S3 (--bootnodes já aponta para Node-1 e Node-3)
  if [ "$COMPOSE_FILE" = "docker-compose.validator.yaml" ]; then
    aws s3 cp "s3://$S3_KEYS_BUCKET/shared/docker-compose.validator.yaml" "$REPO_ROOT/docker-compose.validator.yaml" --region "$AWS_REGION"
    check "docker-compose.validator.yaml patchado baixado do S3"

    log "Verificando --bootnodes no compose:"
    grep -i "bootnodes" "$REPO_ROOT/docker-compose.validator.yaml" | tee -a "$LOG_FILE"
  fi
fi

cd "$REPO_ROOT"

# Node-1: garante que o WS escute em 0.0.0.0 (necessário para o Caliper em EC2 separada)
# Por padrão o Besu liga o WS em 127.0.0.1 — sem esse flag a porta fica fechada externamente
if [ "$NODE_INDEX" = "1" ] && ! grep -q "rpc-ws-host" "$COMPOSE_FILE"; then
  sed -i '/--rpc-ws-port=8645/a\      --rpc-ws-host=0.0.0.0' "$COMPOSE_FILE"
  log "Adicionado --rpc-ws-host=0.0.0.0 ao $COMPOSE_FILE"
fi

# Corrige --p2p-port para o nó correto (cada nó tem porta única no static-nodes.json)
# Node-1→30303, Node-2→30304, Node-3→30305, Node-4→30306, Node-5→30307, Node-6→30308
P2P_PORT=$((30302 + NODE_INDEX))
sed -i "s/--p2p-port=[0-9]*/--p2p-port=$P2P_PORT/" "$COMPOSE_FILE"
log "p2p-port configurado para $P2P_PORT no Node-$NODE_INDEX"

# Verifica que o compose file correto existe
if [ ! -f "$COMPOSE_FILE" ]; then
  log "ERRO: $COMPOSE_FILE não encontrado em $REPO_ROOT"
  ls -la "$REPO_ROOT" | tee -a "$LOG_FILE"
  exit 1
fi
check "Verificação do arquivo $COMPOSE_FILE"

# Build da imagem Docker (JDK e Besu precisam estar na raiz do repo para o COPY no Dockerfile)
log "Construindo imagem Docker besu-image-local:1.0..."
sudo docker build --no-cache -f Dockerfile -t besu-image-local:1.0 .
check "Build da imagem Docker"

# Sobe o container com o compose correto para este nó
log "Subindo container com $COMPOSE_FILE..."
sudo docker compose -f "$COMPOSE_FILE" up -d
check "docker compose up -d ($COMPOSE_FILE)"

sleep 10
log "Status do container:"
sudo docker compose -f "$COMPOSE_FILE" ps | tee -a "$LOG_FILE"

# Valida que o container não está em Exit/Restarting
COMPOSE_STATUS=$(sudo docker compose -f "$COMPOSE_FILE" ps 2>/dev/null || true)
if echo "$COMPOSE_STATUS" | grep -qE 'Exit|Restarting'; then
  log "ERRO: container em estado problemático"
  sudo docker compose -f "$COMPOSE_FILE" logs --tail=50 | tee -a "$LOG_FILE"
  exit 1
fi
check "Container em execução"

# Polling do RPC para confirmar que o Besu respondeu
log "Aguardando Besu responder em 127.0.0.1:$RPC_PORT..."
for i in $(seq 1 30); do
  sleep 10
  BLOCK=$(curl -s --max-time 5 -X POST \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://127.0.0.1:$RPC_PORT 2>/dev/null | grep -o '"result":"0x[^"]*"' || true)
  if [ -n "$BLOCK" ]; then
    log "Besu respondendo após $((i * 10))s: $BLOCK"
    exit 0
  fi
  log "Tentativa $i/30: aguardando RPC..."
done

log "AVISO: Besu ainda não respondeu no RPC após 5 minutos — verifique os logs do container"
sudo docker compose -f "$COMPOSE_FILE" logs --tail=50 | tee -a "$LOG_FILE"
