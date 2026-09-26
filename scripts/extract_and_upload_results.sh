#!/usr/bin/env bash
# Extrai reports HTML pra CSV e sobe pro Blob Storage. Chamado por run_caliper_tests.sh
# (varredura automática, SKIP_SWEEP=false) OU pelo orquestrador local
# run_distributed_sweep.py, como último passo depois que todas as rodadas
# distribuídas terminam. Mesma lógica em ambos os caminhos — nenhuma duplicação.
set -euo pipefail

: "${CALIPER_ROOT:?CALIPER_ROOT não definido}"
: "${AZURE_STORAGE_ACCOUNT:?AZURE_STORAGE_ACCOUNT não definido}"
: "${AZURE_STORAGE_CONTAINER:?AZURE_STORAGE_CONTAINER não definido}"
: "${AZURE_IDENTITY_CLIENT_ID:?AZURE_IDENTITY_CLIENT_ID não definido}"
LOG_FILE="${LOG_FILE:-/home/ubuntu/besu-setup.log}"
BLOB_BASE="https://$AZURE_STORAGE_ACCOUNT.blob.core.windows.net/$AZURE_STORAGE_CONTAINER"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
check() { if [ $? -ne 0 ]; then log "ERRO: $1"; exit 1; fi; log "OK: $1"; }

azcopy login --identity --identity-client-id="$AZURE_IDENTITY_CLIENT_ID"
check "Login no azcopy via managed identity"

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

log "Enviando CSVs para $BLOB_BASE/caliper-results/..."
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
BLOB_PREFIX="$BLOB_BASE/caliper-results/$TIMESTAMP"
CSV_COUNT=0

for DIR in "$CALIPER_ROOT/src/"*_resource_metrics_by_tps; do
  if [ -d "$DIR" ]; then
    DIRNAME=$(basename "$DIR")
    # "/*" na origem evita aninhar "${DIRNAME}/" de novo dentro do destino
    # (mesmo raciocínio do deploy_contracts.sh); --include-pattern replica o
    # filtro --exclude "*" --include "*.csv" da AWS CLI.
    azcopy copy "$DIR/*" "${BLOB_PREFIX}/resource_metrics/${DIRNAME}/" \
      --recursive --include-pattern="*.csv"
    CSV_COUNT=$((CSV_COUNT + $(find "$DIR" -name "*.csv" | wc -l)))
  fi
done

for DIR in "$CALIPER_ROOT/src/reports/"*; do
  if [ -d "$DIR" ]; then
    DIRNAME=$(basename "$DIR")
    azcopy copy "$DIR/*" "${BLOB_PREFIX}/reports/${DIRNAME}/" \
      --recursive --include-pattern="*.csv"
    CSV_COUNT=$((CSV_COUNT + $(find "$DIR" -name "*.csv" | wc -l)))
  fi
done

log "OK: $CSV_COUNT arquivo(s) CSV enviado(s) para $BLOB_PREFIX"
azcopy list "${BLOB_PREFIX}/" | tee -a "$LOG_FILE"
check "Upload dos CSVs para o Blob Storage"
