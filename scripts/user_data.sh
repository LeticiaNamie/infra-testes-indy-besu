#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/besu-setup.log"
REPO_ROOT="/home/ubuntu/besu-production-docker"
JDK_TAR="jdk-21.0.6_linux-x64_bin.tar.gz"
JDK_DIR="jdk-21.0.6"
BESU_TAR="besu-24.7.0.tar.gz"
BESU_DIR="besu-24.7.0"
PERMISSIONED_NETWORK_DIR="$REPO_ROOT/Permissioned-Network"
PERMISSIONS_FILE="$PERMISSIONED_NETWORK_DIR/permissions_config.toml"
GENESIS_FILE="$REPO_ROOT/genesis.json"
NETWORK_FILES_DIR="$REPO_ROOT/networkFiles"
DOCKER_COMPOSE_FILE="$REPO_ROOT/docker-compose.yaml"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" /dev/console
}

check() {
  if [ $? -ne 0 ]; then
    log "ERRO: $1"
    exit 1
  else
    log "OK: $1"
  fi
}

log "Iniciando setup do ${project_name}"

export DEBIAN_FRONTEND=noninteractive
log "Atualizando o sistema e instalando dependências básicas"
apt-get update -y && apt-get install -y git curl wget tar jq ca-certificates gnupg
check "Instalação de dependências básicas"

log "Instalando Docker via repositório oficial"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
check "Instalação do Docker e docker compose plugin"

log "Habilitando e iniciando o Docker"
systemctl enable docker && systemctl start docker
check "Docker iniciado"

docker --version
check "docker --version"
docker compose version
check "docker compose version"

if [ -d "$REPO_ROOT" ]; then
  log "Removendo instalação anterior de $REPO_ROOT"
  rm -rf "$REPO_ROOT"
fi

log "Clonando o repositório besu-production-docker"
git clone -b develop https://github.com/jeffsonsousa/besu-production-docker.git "$REPO_ROOT"
check "Clone do repositório"

cd "$REPO_ROOT"
check "Mudança para o diretório do repositório"

if [ ! -f "$REPO_ROOT/Dockerfile" ]; then
  log "ERRO: Dockerfile não encontrado em $REPO_ROOT"
  exit 1
fi
check "Verificação do Dockerfile"

log "Baixando e extraindo Java JDK 21"
cd "$REPO_ROOT"
wget -q https://download.oracle.com/java/21/archive/jdk-21.0.6_linux-x64_bin.tar.gz
check "Download do JDK"
tar -xvf "$JDK_TAR"
check "Extração do JDK"
rm -f "$JDK_TAR"
check "Remoção do arquivo tar do JDK"

log "Baixando e extraindo Besu v24.7.0"
wget -q https://github.com/hyperledger/besu/releases/download/24.7.0/$BESU_TAR
check "Download do Besu"
tar -xvf "$BESU_TAR"
check "Extração do Besu"
rm -f "$BESU_TAR"
check "Remoção do arquivo tar do Besu"

log "Verificando instalações locais de JDK e Besu"
export JAVA_HOME="$REPO_ROOT/$JDK_DIR"
export PATH="$JAVA_HOME/bin:$REPO_ROOT/$BESU_DIR/bin:$PATH"

java -version
check "java -version"

besu --version | grep -q "24.7.0"
check "besu --version"

log "Gerando configuração de blockchain e chaves da rede"
"$REPO_ROOT/$BESU_DIR/bin/besu" operator generate-blockchain-config \
  --config-file=genesis_QBFT.json \
  --to=networkFiles \
  --private-key-file-name=key
check "Geração de blockchain config"

cp "$REPO_ROOT/networkFiles/genesis.json" "$GENESIS_FILE"
check "Cópia do genesis.json para a raiz do repositório"

chmod +x "$REPO_ROOT/generate-nodes-config.sh"
./generate-nodes-config.sh
check "Execução do generate-nodes-config.sh"

if [ ! -f "$PERMISSIONS_FILE" ]; then
  log "ERRO: permissions_config.toml não encontrado"
  exit 1
fi
check "Verificação do arquivo permissions_config.toml"

# --- NOVO: substituição dinâmica do IP da EC2 ---
log "Obtendo IP privado da instância EC2"
EC2_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
check "Obtenção do IP da EC2"
log "IP da EC2: $EC2_IP"

log "Substituindo IP nos arquivos de configuração"
sed -i "s|192\.168\.[0-9]*\.[0-9]*|$EC2_IP|g" "$PERMISSIONS_FILE"
check "Substituição do IP no permissions_config.toml"

log "Verificando substituição no permissions_config.toml"
grep "enode://" "$PERMISSIONS_FILE" >> "$LOG_FILE" 2>&1
# -------------------------------------------------

# Copiar genesis.json para Permissioned-Network se não existir
if [ ! -f "$PERMISSIONED_NETWORK_DIR/genesis.json" ]; then
  cp "$GENESIS_FILE" "$PERMISSIONED_NETWORK_DIR/"
  check "Cópia do genesis.json para Permissioned-Network"
fi

log "Verificando estrutura de diretórios para os 6 nós"

if [ ! -d "$PERMISSIONED_NETWORK_DIR" ]; then
  log "ERRO: Diretório $PERMISSIONED_NETWORK_DIR não encontrado"
  exit 1
fi

if [ ! -f "$PERMISSIONED_NETWORK_DIR/genesis.json" ]; then
  log "ERRO: genesis.json não encontrado em $PERMISSIONED_NETWORK_DIR"
  exit 1
fi

if [ ! -f "$PERMISSIONED_NETWORK_DIR/permissions_config.toml" ]; then
  log "ERRO: permissions_config.toml não encontrado em $PERMISSIONED_NETWORK_DIR"
  exit 1
fi

for i in $(seq 1 6); do
  if [ ! -d "$PERMISSIONED_NETWORK_DIR/Node-$i" ]; then
    log "ERRO: Pasta Node-$i não encontrada em $PERMISSIONED_NETWORK_DIR"
    exit 1
  fi

  if [ ! -d "$PERMISSIONED_NETWORK_DIR/Node-$i/data" ]; then
    log "ERRO: Pasta data não encontrada em Node-$i"
    exit 1
  fi

  if [ ! -f "$PERMISSIONED_NETWORK_DIR/Node-$i/data/key" ]; then
    log "ERRO: key não encontrado em Node-$i/data"
    exit 1
  fi

  if [ ! -f "$PERMISSIONED_NETWORK_DIR/Node-$i/data/key.pub" ]; then
    log "ERRO: key.pub não encontrado em Node-$i/data"
    exit 1
  fi

  if [ ! -f "$PERMISSIONED_NETWORK_DIR/Node-$i/data/permissions_config.toml" ]; then
    log "ERRO: permissions_config.toml não encontrado em Node-$i/data"
    exit 1
  fi

  log "Substituindo IP no permissions_config.toml de Node-$i"
  sed -i "s|192\.168\.[0-9]*\.[0-9]*|$EC2_IP|g" "$PERMISSIONED_NETWORK_DIR/Node-$i/data/permissions_config.toml"
  check "Substituição do IP em Node-$i/data/permissions_config.toml"
done

check "Verificação da estrutura de diretórios dos nós"

log "Gerando static-nodes.json para cada nó"
STATIC_NODES=$(python3 -c '
import json, re, sys
text = open(sys.argv[1]).read()
m = re.search(r"nodes-allowlist\s*=\s*\[([^\]]*)\]", text, re.S)
if not m:
    raise SystemExit("nodes-allowlist não encontrado")
items = re.findall(r"enode://[^\s\"]+", m.group(1))
if not items:
    raise SystemExit("Nenhum enode encontrado")
print(json.dumps(items))
' "$PERMISSIONS_FILE")
check "Extração do array nodes-allowlist"
log "Static nodes extraídos: $STATIC_NODES"

for i in $(seq 1 6); do
  DEST_DIR="$PERMISSIONED_NETWORK_DIR/Node-$i/data"
  echo "$STATIC_NODES" > "$DEST_DIR/static-nodes.json"
  check "Criação de static-nodes.json em Node-$i"
done

BOOTNODES=$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
print("DEBUG: Conteúdo do arquivo:", file=sys.stderr)
print(repr(text), file=sys.stderr)
m = re.search(r"nodes-allowlist\s*=\s*\[([^\]]*)\]", text, re.S)
if not m:
    raise SystemExit("nodes-allowlist não encontrado")
items = re.findall(r"enode://[^\s\"]+", m.group(1))
print(f"DEBUG: Items encontrados ({len(items)}): {items}", file=sys.stderr)
if len(items) < 3:
    raise SystemExit(f"Esperado pelo menos 3 enodes, encontrados {len(items)}")
print(",".join([items[0], items[2]]))
' "$PERMISSIONS_FILE" 2>> "$LOG_FILE")
check "Extração dos bootnodes para node1 e node3"
log "Bootnodes extraídos: $BOOTNODES"

log "Ajustando bootnodes no docker-compose.yaml"

cat > /tmp/adjust_bootnodes.py << 'EOF'
import re, sys
path = sys.argv[1]
bootnodes = sys.argv[2]
text = open(path).read()
pattern = re.compile(r'(--bootnodes=)(\S*)')
matches = pattern.findall(text)
print(f"DEBUG: Ocorrências de --bootnodes encontradas: {len(matches)}", file=sys.stderr)
if not matches:
    raise SystemExit("ERRO: --bootnodes não encontrado no docker-compose.yaml")
new = pattern.sub(lambda m: m.group(1) + bootnodes, text)
open(path, 'w').write(new)
print(f"DEBUG: bootnodes substituídos em {len(matches)} ocorrência(s)", file=sys.stderr)
print(f"DEBUG: valor inserido: {bootnodes}", file=sys.stderr)
EOF

python3 /tmp/adjust_bootnodes.py "$DOCKER_COMPOSE_FILE" "$BOOTNODES" 2>> "$LOG_FILE"
check "Substituição dos bootnodes"

log "Verificando substituição no docker-compose.yaml"
grep -i "bootnodes" "$DOCKER_COMPOSE_FILE" >> "$LOG_FILE" 2>&1
check "Verificação do grep bootnodes"

sed -i 's|besu-image-local:2\.0|besu-image-local:1.0|g' "$DOCKER_COMPOSE_FILE"
check "Correção da tag besu-image-local:2.0 para 1.0"

log "Construindo a imagem Docker local besu-image-local:1.0"
docker build --no-cache -f Dockerfile -t besu-image-local:1.0 .
check "Build da imagem Docker"

log "Subindo os containers com docker compose"
docker compose up -d
check "docker compose up -d"

sleep 15
log "Verificando status dos containers"
COMPOSE_STATUS=$(docker compose ps || true)
echo "$COMPOSE_STATUS" | tee -a "$LOG_FILE"
if echo "$COMPOSE_STATUS" | grep -E 'Exit|Restarting' >/dev/null 2>&1; then
  log "ERRO: Containers com status problemático"
  docker compose ps
  exit 1
fi
check "Containers em execução"
