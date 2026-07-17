#!/usr/bin/env bash
# Roda no Node-1 via remote-exec.
# Gera chaves para todos os nós, constrói enode URLs com IPs fixos e sobe tudo para S3.
set -euo pipefail

LOG_FILE="/home/ubuntu/besu-setup.log"
export PATH="/usr/local/bin:$PATH"
REPO_ROOT="/home/ubuntu/besu-production-docker-distributed"
JDK_TAR="jdk-21.0.6_linux-x64_bin.tar.gz"
JDK_DIR="jdk-21.0.6"
BESU_TAR="besu-24.7.0.tar.gz"
BESU_DIR="besu-24.7.0"
PERMISSIONED_DIR="$REPO_ROOT/Permissioned-Network"

# Variáveis injetadas via env pelo Terraform (remote-exec inline)
: "${S3_KEYS_BUCKET:?S3_KEYS_BUCKET não definido}"
: "${AWS_REGION:?AWS_REGION não definido}"
: "${NODE_COUNT:?NODE_COUNT não definido}"

# IPs privados fixos — 10.0.1.10 + (index-1), ex: Node-1=10.0.1.10, Node-7=10.0.1.16
declare -A NODE_IPS
for i in $(seq 1 $NODE_COUNT); do
  NODE_IPS[$i]="10.0.1.$((9 + i))"
done

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check() {
  if [ $? -ne 0 ]; then log "ERRO: $1"; exit 1; fi
  log "OK: $1"
}

log "=== Gerando e distribuindo chaves para a rede Besu distribuída ($NODE_COUNT nós) ==="

# Clone do repositório adaptado para distribuição
if [ -d "$REPO_ROOT" ]; then rm -rf "$REPO_ROOT"; fi
git clone https://github.com/LeticiaNamie/besu-production-docker-distributed.git "$REPO_ROOT"
check "Clone do repositório LeticiaNamie/besu-production-docker-distributed"

cd "$REPO_ROOT"

# Download e extração do JDK 21 (necessário para o docker build via COPY)
log "Baixando JDK 21..."
wget -q "https://download.oracle.com/java/21/archive/$JDK_TAR"
check "Download do JDK 21"
tar -xf "$JDK_TAR" && rm -f "$JDK_TAR"
check "Extração do JDK 21"

# Download e extração do Besu 24.7.0 (necessário para o docker build via COPY)
log "Baixando Besu 24.7.0..."
wget -q "https://github.com/hyperledger/besu/releases/download/24.7.0/$BESU_TAR"
check "Download do Besu"
tar -xf "$BESU_TAR" && rm -f "$BESU_TAR"
check "Extração do Besu"

export JAVA_HOME="$REPO_ROOT/$JDK_DIR"
export PATH="$JAVA_HOME/bin:$REPO_ROOT/$BESU_DIR/bin:$PATH"

java -version 2>&1 | head -1 | tee -a "$LOG_FILE"
check "Java disponível"

"$REPO_ROOT/$BESU_DIR/bin/besu" --version | grep -q "24.7.0"
check "Besu 24.7.0 disponível"

# Patch do genesis_QBFT.json — substitui o count pelo número correto de nós
log "Patchando genesis_QBFT.json para $NODE_COUNT nós..."
jq ".blockchain.nodes.count = $NODE_COUNT" genesis_QBFT.json > /tmp/genesis_patched.json
mv /tmp/genesis_patched.json genesis_QBFT.json
check "Patch do genesis_QBFT.json (count=$NODE_COUNT)"
log "genesis_QBFT.json patchado: count=$(jq '.blockchain.nodes.count' genesis_QBFT.json)"

# Gera chaves criptográficas e genesis via besu operator
log "Gerando blockchain config..."
"$REPO_ROOT/$BESU_DIR/bin/besu" operator generate-blockchain-config \
  --config-file=genesis_QBFT.json \
  --to=networkFiles \
  --private-key-file-name=key
check "besu operator generate-blockchain-config"

cp "$REPO_ROOT/networkFiles/genesis.json" "$REPO_ROOT/genesis.json"
check "Cópia do genesis.json para raiz"

# Cria estrutura Permissioned-Network (o script do repo já é dinâmico — usa tudo que foi gerado)
if [ -f "$REPO_ROOT/generate-nodes-config.sh" ]; then
  log "Executando generate-nodes-config.sh do repositório..."
  chmod +x "$REPO_ROOT/generate-nodes-config.sh"
  ./generate-nodes-config.sh
  check "generate-nodes-config.sh"
else
  log "generate-nodes-config.sh não encontrado — criando estrutura manualmente"
  KEY_DIRS=("$REPO_ROOT/networkFiles/keys"/*)
  for i in $(seq 1 $NODE_COUNT); do
    NODE_DIR="$PERMISSIONED_DIR/Node-$i/data"
    mkdir -p "$NODE_DIR"
    SRC_DIR="${KEY_DIRS[$((i-1))]}"
    cp "$SRC_DIR/key"     "$NODE_DIR/key"
    cp "$SRC_DIR/key.pub" "$NODE_DIR/key.pub"
    log "Chaves copiadas para Node-$i"
  done
fi

# Valida que os diretórios e chaves existem para todos os N nós
for i in $(seq 1 $NODE_COUNT); do
  if [ ! -f "$PERMISSIONED_DIR/Node-$i/data/key.pub" ]; then
    log "ERRO: key.pub não encontrado em Node-$i/data"
    exit 1
  fi
done
check "Estrutura de diretórios dos $NODE_COUNT nós validada"

# Patch do permissions_config.toml — substitui o IP placeholder pelo IP fixo correto
# de cada nó, identificando cada entrada pela sua pubkey.
PERMISSIONS_TOML="$PERMISSIONED_DIR/permissions_config.toml"

if [ ! -f "$PERMISSIONS_TOML" ]; then
  log "ERRO: $PERMISSIONS_TOML não encontrado — generate-nodes-config.sh deveria tê-lo criado"
  exit 1
fi
check "Verificação do permissions_config.toml gerado pelo repositório"

log "Conteúdo original do permissions_config.toml:"
cat "$PERMISSIONS_TOML" | tee -a "$LOG_FILE"

log "Substituindo IPs placeholder pelos IPs fixos de cada nó (por pubkey)..."
cat > /tmp/patch_permissions.py << 'EOF'
import re, sys

toml_path = sys.argv[1]
# Argumentos: pubkey1 ip1 pubkey2 ip2 ...
args = sys.argv[2:]
replacements = {args[i].lower(): args[i+1] for i in range(0, len(args), 2)}

text = open(toml_path).read()

def replace_ip(match):
    enode = match.group(0)
    pk_match = re.search(r'enode://([0-9a-fA-F]+)@', enode)
    if pk_match and pk_match.group(1).lower() in replacements:
        new_ip = replacements[pk_match.group(1).lower()]
        return re.sub(r'@[^:]+:', f'@{new_ip}:', enode)
    return enode

new_text = re.sub(r'enode://[^\s"\']+', replace_ip, text)
open(toml_path, 'w').write(new_text)
EOF

# Coleta pubkeys dinamicamente para todos os N nós
PUBKEYS=()
for i in $(seq 1 $NODE_COUNT); do
  PUBKEYS+=("$(sed 's/^0x//' "$PERMISSIONED_DIR/Node-$i/data/key.pub" | tr -d '[:space:]')")
done

# Monta argumentos para patch_permissions.py: pubkey1 ip1 pubkey2 ip2 ...
PATCH_ARGS=("$PERMISSIONS_TOML")
for i in $(seq 1 $NODE_COUNT); do
  PATCH_ARGS+=("${PUBKEYS[$((i-1))]}" "${NODE_IPS[$i]}")
done
python3 /tmp/patch_permissions.py "${PATCH_ARGS[@]}"
check "Patch de IPs no permissions_config.toml"

log "permissions_config.toml após patch:"
grep "enode://" "$PERMISSIONS_TOML" | tee -a "$LOG_FILE"

# Extrai enodes do permissions_config.toml patchado para static-nodes.json
# O filtro '@10.0.1.' já cobre todos os N nós (IPs 10.0.1.10 a 10.0.1.N+9)
log "Extraindo enodes do permissions_config.toml patchado para static-nodes.json..."
STATIC_NODES_JSON=$(python3 -c "
import re, json, sys
text = open(sys.argv[1]).read()
items = re.findall(r'enode://[^\s\"\']+', text)
managed = [e for e in items if '@10.0.1.' in e]
print(json.dumps(managed, indent=2))
" "$PERMISSIONS_TOML")
check "Extração dos enodes para static-nodes.json"
log "static-nodes.json: $STATIC_NODES_JSON"

# Extrai enode do Node-1 (10.0.1.10) e Node-3 (10.0.1.12) — sempre os 2 bootnodes
ENODE_NODE1=$(python3 -c "
import re, sys
text = open(sys.argv[1]).read()
items = re.findall(r'enode://[^\s\"\']+', text)
node1 = [e for e in items if '@10.0.1.10:' in e]
if not node1:
    raise SystemExit('ERRO: enode do Node-1 (10.0.1.10) não encontrado no permissions_config.toml')
print(node1[0])
" "$PERMISSIONS_TOML")
check "Extração do enode do Node-1"
log "Node-1 enode (bootnode): $ENODE_NODE1"

ENODE_NODE3=$(python3 -c "
import re, sys
text = open(sys.argv[1]).read()
items = re.findall(r'enode://[^\s\"\']+', text)
node3 = [e for e in items if '@10.0.1.12:' in e]
if not node3:
    raise SystemExit('ERRO: enode do Node-3 (10.0.1.12) não encontrado no permissions_config.toml')
print(node3[0])
" "$PERMISSIONS_TOML")
check "Extração do enode do Node-3"
log "Node-3 enode (bootnode): $ENODE_NODE3"

BOOTNODES="${ENODE_NODE1},${ENODE_NODE3}"
log "Bootnodes para validators: $BOOTNODES"

# Distribui genesis, static-nodes e permissions para todos os N nós
for i in $(seq 1 $NODE_COUNT); do
  NODE_DATA="$PERMISSIONED_DIR/Node-$i/data"
  echo "$STATIC_NODES_JSON" > "$NODE_DATA/static-nodes.json"
  cp "$PERMISSIONS_TOML" "$NODE_DATA/permissions_config.toml"
  cp "$REPO_ROOT/genesis.json" "$NODE_DATA/genesis.json"
  check "Arquivos de configuração distribuídos para Node-$i"
done

# Patch do docker-compose.validator.yaml — substitui --bootnodes pelos enodes de Node-1 e Node-3
VALIDATOR_COMPOSE="$REPO_ROOT/docker-compose.validator.yaml"
if [ ! -f "$VALIDATOR_COMPOSE" ]; then
  log "ERRO: $VALIDATOR_COMPOSE não encontrado"
  exit 1
fi

log "Ajustando --bootnodes em $VALIDATOR_COMPOSE com enodes de Node-1 e Node-3..."
cat > /tmp/adjust_bootnodes.py << 'EOF'
import re, sys
path, bootnodes = sys.argv[1], sys.argv[2]
text = open(path).read()
pattern = re.compile(r'(--bootnodes=)(\S*)')
matches = pattern.findall(text)
print(f"DEBUG: ocorrências de --bootnodes encontradas: {len(matches)}", file=sys.stderr)
if not matches:
    raise SystemExit("ERRO: --bootnodes não encontrado em docker-compose.validator.yaml")
new = pattern.sub(lambda m: m.group(1) + bootnodes, text)
open(path, 'w').write(new)
print(f"DEBUG: bootnodes inseridos: {bootnodes}", file=sys.stderr)
EOF

python3 /tmp/adjust_bootnodes.py "$VALIDATOR_COMPOSE" "$BOOTNODES" 2>> "$LOG_FILE"
check "Substituição do --bootnodes em docker-compose.validator.yaml"

log "Verificando substituição:"
grep -i "bootnodes" "$VALIDATOR_COMPOSE" | tee -a "$LOG_FILE"

# Upload para S3 — chaves por nó + arquivos compartilhados
log "Fazendo upload das chaves e configurações para S3..."
for i in $(seq 1 $NODE_COUNT); do
  NODE_DATA="$PERMISSIONED_DIR/Node-$i/data"
  aws s3 cp "$NODE_DATA/key"     "s3://$S3_KEYS_BUCKET/node-$i/key"     --region "$AWS_REGION"
  aws s3 cp "$NODE_DATA/key.pub" "s3://$S3_KEYS_BUCKET/node-$i/key.pub" --region "$AWS_REGION"
  check "Chaves do Node-$i enviadas para S3"
done

aws s3 cp "$REPO_ROOT/genesis.json"                              "s3://$S3_KEYS_BUCKET/shared/genesis.json"                    --region "$AWS_REGION"
aws s3 cp "$PERMISSIONED_DIR/Node-1/data/static-nodes.json"      "s3://$S3_KEYS_BUCKET/shared/static-nodes.json"              --region "$AWS_REGION"
aws s3 cp "$PERMISSIONS_TOML"                                    "s3://$S3_KEYS_BUCKET/shared/permissions_config.toml"         --region "$AWS_REGION"
aws s3 cp "$VALIDATOR_COMPOSE"                                   "s3://$S3_KEYS_BUCKET/shared/docker-compose.validator.yaml"   --region "$AWS_REGION"
check "Arquivos compartilhados enviados para S3"

log "=== Geração e distribuição de chaves concluída com sucesso ==="
for i in $(seq 1 $NODE_COUNT); do
  IP="${NODE_IPS[$i]}"
  ENODE_NODE=$(python3 -c "
import re, sys
text = open(sys.argv[1]).read()
items = re.findall(r'enode://[^\s\"\']+', text)
node = [e for e in items if '@${IP}:' in e]
print(node[0] if node else '(nao encontrado)')
" "$PERMISSIONS_TOML")
  log "Node-$i enode: $ENODE_NODE"
done
