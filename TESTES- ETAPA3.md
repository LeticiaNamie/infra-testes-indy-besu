# Prompt para IA — Geração do Terraform: Etapa 3 — Execução dos Testes com Caliper

## Contexto do projeto

Esta é a **Etapa 3** de um experimento de avaliação de desempenho de contratos inteligentes em uma rede Hyperledger Besu QBFT. As etapas anteriores já:

- **Etapa 1:** Provisionou uma instância EC2 `t3.medium` com a rede Besu rodando em 6 containers Docker
- **Etapa 2:** Fez o deploy dos contratos inteligentes (IndyDidRegistry, CredentialDefinitionRegistry, SchemaRegistry, RevocationRegistry) na rede Besu local e salvou os artefatos em `/home/ubuntu/deploy-artifacts/`

Esta etapa deve ser executada **na mesma instância EC2**, sem recriar a infraestrutura. O objetivo é executar os testes de carga com o Hyperledger Caliper, processar os resultados e enviá-los para um bucket S3.

**Repositório dos testes:** https://github.com/LeticiaNamie/tests-with-caliper.git
**Artefatos do deploy (Etapa 2):** `/home/ubuntu/deploy-artifacts/`

---

## Objetivo final

Ao final da execução, a instância EC2 deve ter:

1. Clonado o repositório `tests-with-caliper`
2. Instalado o Hyperledger Caliper CLI v0.5.0
3. Feito o bind do Caliper com o Hyperledger Besu
4. Configurado dinamicamente o `networkconfig.json` com os dados reais da rede e dos contratos deployados na Etapa 2
5. Executado os testes com `python3 run_test_local.py`
6. Processado os resultados com `python3 extract_report_to_csv.py` e `python3 extract_resource_to_csv.py`
7. Enviado os CSVs gerados para o bucket S3 `tests-with-caliper-results`

---

## Infraestrutura AWS (Terraform)

**Não criar nova instância e não usar `user_data`.** Use o mesmo padrão da Etapa 2: `null_resource` com `remote-exec` via SSH.

O Terraform desta etapa deve criar os seguintes recursos adicionais:

### Bucket S3 para os resultados

```hcl
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "caliper_results" {
  bucket = "${var.caliper_results_bucket}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "${var.caliper_results_bucket}-${data.aws_caller_identity.current.account_id}"
    Project = var.project_name
  }
}

resource "aws_s3_bucket_ownership_controls" "caliper_results" {
  bucket = aws_s3_bucket.caliper_results.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}
```

### IAM Role para acesso da EC2 ao S3

```hcl
resource "aws_iam_role" "besu_s3_access" {
  name = "${var.project_name}-s3-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "besu_s3_write" {
  name = "${var.project_name}-s3-write-policy"
  role = aws_iam_role.besu_s3_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:PutObjectAcl"]
      Resource = "${aws_s3_bucket.caliper_results.arn}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "besu_s3_profile" {
  name = "${var.project_name}-s3-instance-profile"
  role = aws_iam_role.besu_s3_access.name
}
```

> **Atenção:** Se a instância EC2 da Etapa 1 não foi criada com `iam_instance_profile`, adicione ao recurso `aws_instance.besu` o campo:
> ```hcl
> iam_instance_profile = aws_iam_instance_profile.besu_s3_profile.name
> ```
> O Terraform consegue atualizar o instance profile de uma EC2 existente sem recriá-la (update in-place). Se o recurso `aws_instance.besu` não estiver no mesmo state, use em vez disso:
> ```hcl
> resource "null_resource" "attach_iam_profile" {
>   provisioner "local-exec" {
>     command = "aws ec2 associate-iam-instance-profile --instance-id ${data.aws_instance.besu.id} --iam-instance-profile Name=${aws_iam_instance_profile.besu_s3_profile.name} --region ${var.aws_region}"
>   }
>   depends_on = [aws_iam_instance_profile.besu_s3_profile]
> }
> ```

### null_resource para execução dos testes

```hcl
resource "null_resource" "run_caliper_tests" {
  depends_on = [null_resource.deploy_contracts, aws_iam_instance_profile.besu_s3_profile]

  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -i ${var.private_key_path} ${path.module}/scripts/run_caliper_tests.sh ubuntu@${aws_eip.besu_ec2.public_ip}:/tmp/run_caliper_tests.sh"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = aws_eip.besu_ec2.public_ip
    agent       = false
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/run_caliper_tests.sh",
      "bash /tmp/run_caliper_tests.sh"
    ]
  }
}
```

> **Nota:** `null_resource` não suporta bloco `timeouts`. O timeout do SSH é controlado pela variável de ambiente `TF_CLI_ARGS` ou configuração de provider. Para testes longos, execute o script manualmente via SSH se o timeout do Terraform for um problema.

Adicione a variável:

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `caliper_results_bucket` | string | `"tests-with-caliper-results"` | Nome do bucket S3 de destino |

---

## Script `run_caliper_tests.sh` — Passos detalhados

O script deve ser executado como usuário `ubuntu` (via SSH, não como root). Use o mesmo padrão de log das etapas anteriores:

```bash
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
```

---

### Passo 1 — Verificar artefatos da Etapa 2

Antes de tudo, confirmar que a Etapa 2 foi executada com sucesso e que os artefatos necessários estão disponíveis:

```bash
log "Verificando artefatos do deploy da Etapa 2"

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
log "Artefatos da Etapa 2 encontrados com sucesso"
```

---

### Passo 2 — Verificar que a rede Besu está ativa

```bash
log "Verificando se a rede Besu está ativa"
BLOCK=$(curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545 | jq -r '.result')
if [ -z "$BLOCK" ] || [ "$BLOCK" = "null" ]; then
  log "ERRO: Rede Besu não está respondendo. Verifique a Etapa 1."
  exit 1
fi
log "Rede Besu ativa — bloco atual: $BLOCK"
```

---

### Passo 3 — Garantir Python 3 instalado

```bash
log "Verificando instalação do Python 3"
if ! command -v python3 &> /dev/null; then
  log "Instalando Python 3"
  sudo apt-get update -y && sudo apt-get install -y python3 python3-pip
  check "Instalação do Python 3"
else
  log "Python 3 já instalado: $(python3 --version)"
fi
```

---

### Passo 3.5 — Garantir permissão de acesso ao Docker socket

O Caliper monitora os containers Besu via `/var/run/docker.sock` para coletar métricas de CPU, memória e rede. Se o usuário `ubuntu` não estiver no grupo `docker`, o monitoramento falha com `EACCES /var/run/docker.sock` e as métricas de recursos ficam `undefined` no relatório.

O `usermod` não tem efeito na sessão atual — por isso o script se re-executa via `sg docker` para que o grupo esteja ativo sem precisar de novo login SSH:

```bash
if ! id -nG "$USER" | grep -qw docker; then
  log "Adicionando $USER ao grupo docker e re-executando com permissões corretas"
  sudo usermod -aG docker "$USER"
  check "Adição de $USER ao grupo docker"
  exec sg docker "$0"
fi
log "OK: $USER pertence ao grupo docker"
```

> **Por que o re-exec funciona:** `exec sg docker "$0"` substitui o processo atual por uma nova execução do próprio script dentro do contexto do grupo `docker`. Na segunda execução, o `id -nG` já retorna `docker` e o bloco é pulado, continuando normalmente.

---

### Passo 4 — Clone do repositório de testes

O repositório tem a estrutura `tests-with-caliper/evaluation-contracts-indy-besu/`, onde `evaluation-contracts-indy-besu/` é o diretório de trabalho do Caliper (`CALIPER_ROOT`). Por isso o clone é feito em `CLONE_ROOT` e o script opera a partir de `CALIPER_ROOT`.

```bash
if [ -d "$CLONE_ROOT" ]; then
  log "Removendo clone anterior de $CLONE_ROOT"
  rm -rf "$CLONE_ROOT"
fi

log "Clonando repositório tests-with-caliper"
git clone https://github.com/LeticiaNamie/tests-with-caliper.git "$CLONE_ROOT"
check "Clone do repositório tests-with-caliper"
```

Validação: verificar que o arquivo `run_test_local.py` e o diretório `src/` existem dentro de `CALIPER_ROOT`.

```bash
[ -f "$CALIPER_ROOT/run_test_local.py" ] || { log "ERRO: run_test_local.py não encontrado no repositório"; exit 1; }
[ -d "$CALIPER_ROOT/src" ] || { log "ERRO: diretório src/ não encontrado no repositório"; exit 1; }
```

---

### Passo 5 — Instalar o Caliper CLI

```bash
log "Instalando Hyperledger Caliper CLI v0.5.0"
cd "$CALIPER_ROOT"
npm install --only=prod @hyperledger/caliper-cli@0.5.0
check "Instalação do Caliper CLI"
```

Validação: `./node_modules/.bin/caliper --version` deve retornar `0.5.0`.

---

### Passo 6 — Bind do Caliper com Hyperledger Besu

```bash
log "Realizando bind do Caliper com Hyperledger Besu"
cd "$CALIPER_ROOT"
npx caliper bind --caliper-bind-sut besu:latest
check "Bind do Caliper com Besu"
```

Validação: o comando deve completar sem erro. O bind instala os adaptadores necessários para comunicação com o Besu.

---

### Passo 7 — Extrair endereços dos contratos deployados na Etapa 2

Ler os endereços dos quatro contratos do arquivo `deployed_addresses.json` gerado pelo Hardhat Ignition:

```bash
log "Extraindo endereços dos contratos da Etapa 2"

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
```

---

### Passo 8 — Extrair fromAddress e chave privada do Node-1

```bash
log "Extraindo fromAddress do permissions_config.toml"
PERMISSIONS_FILE="$BESU_ROOT/permissions_config.toml"

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

log "Extraindo chave privada do Node-1"
KEY_FILE="$BESU_ROOT/Permissioned-Network/Node-1/data/key"
if [ ! -f "$KEY_FILE" ]; then
  log "ERRO: Arquivo de chave privada não encontrado em $KEY_FILE"
  exit 1
fi
FROM_PRIVATE_KEY=$(cat "$KEY_FILE")
log "Chave privada do Node-1 obtida com sucesso"
```

> **Segurança:** o valor de `FROM_PRIVATE_KEY` nunca deve ser logado em nenhuma circunstância.

---

### Passo 9 — Configurar o networkconfig.json

Usar Python para modificar o `networkconfig.json` com todos os valores dinâmicos extraídos:

- Corrigir a URL do WebSocket de `ws://127.0.0.1:8546` para `ws://127.0.0.1:8645`
- Substituir o `chainId` pelo valor real da rede
- Substituir `"contractAddress"` / `"fromAddress"` / `"fromAddressPrivateKey"` pelos valores corretos
- Substituir os endereços de `IndyDidRegistry`, `CredentialDefinitionRegistry`, `SchemaRegistry` e `RevocationRegistry` pelos deployados na Etapa 2

```bash
log "Configurando networkconfig.json com dados dinâmicos"
NETWORK_CONFIG="$CALIPER_ROOT/networks/besu/networkconfig.json"

if [ ! -f "$NETWORK_CONFIG" ]; then
  log "ERRO: Arquivo networkconfig.json não encontrado em $CALIPER_ROOT/networks/besu/"
  exit 1
fi

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

# Fix porta WebSocket (8546 → 8645)
def fix_ws(obj):
    if "url" in obj and isinstance(obj["url"], str):
        obj["url"] = obj["url"].replace("ws://127.0.0.1:8546", "ws://127.0.0.1:8645")
walk(config, fix_ws)

# Fix chainId
def fix_chain(obj):
    if "chainId" in obj:
        obj["chainId"] = $CHAIN_ID
walk(config, fix_chain)

# Fix fromAddress e fromAddressPrivateKey
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
```

Validação: confirmar que o JSON resultante é válido e contém a porta correta:

```bash
python3 -c "import json; c = json.load(open('$NETWORK_CONFIG')); print('JSON válido')"
check "Validação do networkconfig.json"
grep "8645" "$NETWORK_CONFIG" > /dev/null || { log "AVISO: porta 8645 não encontrada no networkconfig.json"; }
```

---

### Passo 10 — Executar os testes com Caliper

```bash
log "Executando testes com Caliper (run_test_local.py)"
cd "$CALIPER_ROOT"
python3 run_test_local.py 2>&1 | tee -a "$LOG_FILE"
check "Execução dos testes com Caliper"
```

> **Atenção:** dependendo da carga de testes configurada, este passo pode levar vários minutos. O timeout de `30m` no `null_resource` foi definido para cobrir cenários de testes longos.

---

### Passo 11 — Extrair resultados para CSV

Os scripts Python usam `pandas`, `beautifulsoup4`, `lxml`, `os` e `re` — instalar antes de executar:

```bash
log "Instalando dependências Python para extração de resultados"
pip3 install --quiet pandas beautifulsoup4 lxml
check "Instalação de pandas e beautifulsoup4"

log "Extraindo relatório de resultados para CSV"
cd "$CALIPER_ROOT/src"
python3 extract_report_to_csv.py 2>&1 | tee -a "$LOG_FILE"
check "extract_report_to_csv.py"

log "Extraindo dados de recursos para CSV"
python3 extract_resource_to_csv.py 2>&1 | tee -a "$LOG_FILE"
check "extract_resource_to_csv.py"

log "Arquivos CSV gerados:"
find "$CALIPER_ROOT" -name "*.csv" | tee -a "$LOG_FILE"
```

Os CSVs são gerados em dois locais dentro de `$CALIPER_ROOT/src/`:
- `*_resource_metrics_by_tps/` — um diretório por função testada, com métricas de CPU/memória/rede por TPS
- `reports/*/` — um diretório por função testada, com métricas de latência/throughput

---

### Passo 12 — Upload dos CSVs para o S3

A região é obtida do metadata da instância (sem hardcode) e os CSVs são enviados com prefixo de timestamp para não sobrescrever execuções anteriores:

```bash
log "Enviando CSVs para o bucket S3: tests-with-caliper-results"

AWS_REGION=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/placement/region || true)
if [ -z "$AWS_REGION" ]; then
  AWS_REGION="us-east-1"
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
S3_BUCKET="tests-with-caliper-results-${ACCOUNT_ID}"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
S3_PREFIX="s3://${S3_BUCKET}/${TIMESTAMP}"

CSV_COUNT=0

# CSVs de métricas de recursos (um diretório por função)
for DIR in "$CALIPER_ROOT/src/"*_resource_metrics_by_tps; do
  if [ -d "$DIR" ]; then
    DIRNAME=$(basename "$DIR")
    aws s3 cp "$DIR/" "${S3_PREFIX}/resource_metrics/${DIRNAME}/" \
      --recursive --exclude "*" --include "*.csv" --region "$AWS_REGION"
    CSV_COUNT=$((CSV_COUNT + $(find "$DIR" -name "*.csv" | wc -l)))
  fi
done

# CSVs de relatórios de transação (um diretório por função)
for DIR in "$CALIPER_ROOT/src/reports/"*; do
  if [ -d "$DIR" ]; then
    DIRNAME=$(basename "$DIR")
    aws s3 cp "$DIR/" "${S3_PREFIX}/reports/${DIRNAME}/" \
      --recursive --exclude "*" --include "*.csv" --region "$AWS_REGION"
    CSV_COUNT=$((CSV_COUNT + $(find "$DIR" -name "*.csv" | wc -l)))
  fi
done

log "OK: $CSV_COUNT arquivo(s) CSV enviado(s) para $S3_PREFIX"

# Verificação final
aws s3 ls "${S3_PREFIX}/" --recursive --region "$AWS_REGION" | tee -a "$LOG_FILE"
check "Upload dos CSVs para S3"
```

> **Pré-requisito de permissão S3:** A instância EC2 usa o `iam_instance_profile` associado no `aws_instance.besu`. O `aws s3 cp` usa as credenciais do instance profile automaticamente — sem variáveis de ambiente nem arquivos de credenciais. O `null_resource.run_caliper_tests` declara `depends_on = [aws_iam_instance_profile.besu_s3_profile]` para garantir que o profile exista antes da execução.

---

## Observações importantes

1. **Permissão Docker (Passo 3.5):** O usuário `ubuntu` precisa estar no grupo `docker` para o Caliper monitorar os containers. O script detecta isso automaticamente, executa `sudo usermod -aG docker ubuntu` e se re-executa com `exec sg docker "$0"` — sem precisar de novo login SSH. Sem essa correção, as métricas de recursos (CPU, memória, rede) ficam `undefined` no relatório HTML, embora as métricas de transação (latência, TPS) não sejam afetadas.

2. **Dependência da Etapa 2:** O Passo 1 valida explicitamente a existência de `network-info.json` e `deployed_addresses.json` antes de prosseguir. Se a Etapa 2 não foi concluída, o script falha com mensagem clara.

3. **Porta WebSocket 8645:** O `networkconfig.json` do repositório usa a porta `8546`, mas a rede Besu configurada na Etapa 1 expõe WebSocket na porta `8645`. O script corrige isso dinamicamente no Passo 9 sem modificar o arquivo-fonte do repositório.

4. **Endereços dos contratos são dinâmicos:** Lidos do `deployed_addresses.json` gerado pelo Hardhat Ignition na Etapa 2. Os valores são únicos por execução — nunca devem ser hardcoded.

5. **chainId é dinâmico:** Gerado na Etapa 1 pelo `besu operator generate-blockchain-config` e registrado no `network-info.json` da Etapa 2. Difere a cada nova rede Besu provisionada.

6. **Segurança da chave privada:** O valor de `FROM_PRIVATE_KEY` é injetado diretamente no `networkconfig.json` via Python, nunca passando pelo log.

7. **Organização dos resultados no S3:** Os arquivos são enviados com prefixo de timestamp (`YYYYMMDDTHHMMSSz/`) para organizar múltiplas execuções no mesmo bucket sem sobrescrever resultados anteriores.

8. **`${aws_region}` no script:** Substituir pela variável Terraform correspondente usando `templatefile()`, ou hardcodar a região se ela for fixa.

---

## Estrutura de arquivos Terraform esperada (adições à Etapa 2)

```
main.tf           # Adicionar: aws_s3_bucket, aws_iam_role, aws_iam_instance_profile, null_resources
variables.tf      # Adicionar: caliper_results_bucket
outputs.tf        # Adicionar: URL do S3 com os resultados
scripts/
└── run_caliper_tests.sh  # Script desta etapa
```

---

## Critério de sucesso

A Etapa 3 foi bem-sucedida se o comando abaixo (executado localmente com credenciais AWS) retornar ao menos dois arquivos `.csv`:

```bash
aws s3 ls s3://tests-with-caliper-results/ --recursive
```

E o log na instância confirmar a conclusão:

```bash
ssh -i <chave> ubuntu@<ip> "grep 'Etapa 3 concluída com sucesso' /var/log/besu-setup.log"
```
