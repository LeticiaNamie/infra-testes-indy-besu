#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/besu-setup.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" /dev/console
}

check() {
  if [ $? -ne 0 ]; then
    log "ERRO: $1"
    exit 1
  fi
  log "OK: $1"
}

log "=== Iniciando bootstrap do Node-${node_index} ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get install -y git curl wget tar jq ca-certificates gnupg unzip
check "Instalação de dependências básicas"

log "Instalando Docker via repositório oficial"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
check "Docker instalado"

systemctl enable docker && systemctl start docker
check "Docker iniciado"

usermod -aG docker ubuntu
check "ubuntu adicionado ao grupo docker"

log "Instalando AWS CLI v2"
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/awscli
/tmp/awscli/aws/install
rm -rf /tmp/awscliv2.zip /tmp/awscli
check "AWS CLI instalado"

log "=== Bootstrap do Node-${node_index} concluído — Docker e AWS CLI prontos ==="
touch /home/ubuntu/.node-ready
chown ubuntu:ubuntu /home/ubuntu/.node-ready
