#!/usr/bin/env bash
# Extrai reports HTML pra CSV e sobe pro S3. Chamado por run_caliper_tests.sh
# (varredura automática, SKIP_SWEEP=false) OU pelo orquestrador local
# run_distributed_sweep.py, como último passo depois que todas as rodadas
# distribuídas terminam. Mesma lógica em ambos os caminhos — nenhuma duplicação.
set -euo pipefail

: "${CALIPER_ROOT:?CALIPER_ROOT não definido}"
: "${S3_KEYS_BUCKET:?S3_KEYS_BUCKET não definido}"
: "${AWS_REGION:?AWS_REGION não definido}"
LOG_FILE="${LOG_FILE:-/home/ubuntu/besu-setup.log}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
check() { if [ $? -ne 0 ]; then log "ERRO: $1"; exit 1; fi; log "OK: $1"; }

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
