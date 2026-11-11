# infra-testes-indy-besu

Infraestrutura (Terraform) para avaliar o desempenho de contratos de identidade descentralizada (Indy DID) em uma rede **Hyperledger Besu QBFT distribuída em várias VMs**, com testes de carga feitos pelo **Hyperledger Caliper**.

Um único `terraform apply` provisiona as VMs, sobe a rede Besu, implanta os contratos e executa os testes. Os repositórios usados pelas VMs são:

| Papel | Repositório |
|---|---|
| Rede Besu (um nó por VM) | [LeticiaNamie/besu-docker-distributed](https://github.com/LeticiaNamie/besu-docker-distributed) |
| Contratos | [LeticiaNamie/smart-contracts-indy-besu](https://github.com/LeticiaNamie/smart-contracts-indy-besu) |
| Testes de carga (Caliper) | [LeticiaNamie/tests-with-caliper-production](https://github.com/LeticiaNamie/tests-with-caliper-production) |

Todos derivam de repositórios de Jeffson Sousa ([besu-production-docker](https://github.com/jeffsonsousa/besu-production-docker), [contracts-indy-besu](https://github.com/jeffsonsousa/contracts-indy-besu) e [evaluation-contracts-indy-besu](https://github.com/jeffsonsousa/evaluation-contracts-indy-besu)). As diferenças estão no README de cada um.

## Branches

Cada branch tem a infraestrutura de um cenário. O README é o mesmo nas duas.

| Branch | Nuvem | O que faz |
|---|---|---|
| `feature/tests-with-azure-distributed-nodes` | Azure | Rede com `node_count` nós. Uma ou várias VMs Caliper (`node_caliper_count`), com varredura distribuída via MQTT. Resultados no Blob Storage. |
| `feature/tests-with-distributed-parametric-node-count` | AWS | Rede com `node_count` nós (4 a 14) e **uma** VM Caliper. Resultados no S3. |

## Pré-requisitos (nas duas branches)

- [Terraform](https://developer.hashicorp.com/terraform/install) 1.3 ou mais novo
- Python 3 e cliente `ssh`/`scp` na máquina de onde você roda o Terraform
- Um par de chaves SSH, por padrão em `~/.ssh/besu-key` (privada) e `~/.ssh/besu-key.pub` (pública):
  ```bash
  ssh-keygen -t rsa -b 4096 -f ~/.ssh/besu-key -N ""
  ```
- Seu IP público, para liberar o SSH nas VMs:
  ```bash
  curl -s ifconfig.me
  ```
- Os três repositórios da tabela acima acessíveis publicamente, porque as VMs fazem `git clone` neles.

> [!IMPORTANT]
> Em `terraform.tfvars`, `allowed_ssh_cidr` está com o valor `SEU_IP_PUBLICO/32`. **Troque pelo seu IP**, por exemplo `"203.0.113.7/32"`. Sem isso o Terraform não consegue acessar as VMs por SSH.

## Como rodar: `feature/tests-with-azure-distributed-nodes` (Azure)

### 1. Pré-requisitos adicionais

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) autenticada na assinatura que será usada:
  ```bash
  az login
  az account set --subscription <ID_DA_ASSINATURA>
  ```
- Cota de vCPU na região para as famílias usadas. Os padrões são `Standard_F8als_v6` (Node-1), `Standard_F4als_v6` (demais nós Besu) e `Standard_D16s_v7` (Caliper). Se a sua assinatura não tiver cota ou disponibilidade, troque os tamanhos em `terraform.tfvars`. O script `scripts/check_zone_capacity.sh` ajuda a checar a capacidade da zona.

### 2. Configurar `terraform.tfvars`

```hcl
allowed_ssh_cidr   = "SEU_IP_PUBLICO/32"   # seu IP
private_key_path   = "~/.ssh/besu-key"
public_key_path    = "~/.ssh/besu-key.pub"
azure_location     = "westus3"
azure_availability_zone = "1"
vm_size_node1      = "Standard_F8als_v6"
vm_size_besu       = "Standard_F4als_v6"
vm_size_caliper    = "Standard_D16s_v7"
node_caliper_count = 1                     # veja o passo 3
```

Outras variáveis (em `variables.tf`): `node_count` (4 a 14, padrão 6), `spread_sends`, `caliper_a_workers` e `caliper_b_workers`.

### 3. Escolher o modo de teste

| `node_caliper_count` | Modo |
|---|---|
| `1` | A VM do Caliper roda sozinha a varredura (`run_test_local.py`), extrai os CSVs e envia ao Blob Storage. |
| `> 1` | A VM A vira manager (sem varredura local) e as demais VMs rodam só workers, ligados por MQTT. O `terraform apply` chama `scripts/run_distributed_sweep.py`, que roda cada rodada e baixa os CSVs para `caliper-results/<timestamp>/` neste repositório. |

Com `spread_sends = true`, os workers distribuem o envio entre todos os nós Besu. Com `false`, todos enviam ao Node-1.

### 4. Subir

```bash
terraform init
terraform plan
terraform apply
```

O `apply` demora: ele espera as VMs ficarem acessíveis, gera as chaves, sobe os bootnodes (Node-1 e Node-3) e os validators, confere que a rede responde, implanta os contratos e roda os testes. Para acompanhar:

```bash
terraform output caliper_log_command    # imprime o comando de tail do log
terraform output validation_commands    # eth_blockNumber e net_peerCount
```

### 5. Resultados

- **Um Caliper** (`node_caliper_count = 1`): os CSVs ficam no Blob Storage e na VM. Não há cópia automática para o seu computador; baixe com o comando de `terraform output caliper_results_commands`:
  ```bash
  azcopy copy "https://<conta>.blob.core.windows.net/<container>/caliper-results/<timestamp>/*" ./caliper-results/ --recursive
  ```
- **Vários Caliper**: a cópia local é feita sozinha em `caliper-results/<timestamp>/`. Para repetir a varredura depois do `apply` (outra função ou outro TPS):
  ```bash
  python3 scripts/run_distributed_sweep.py
  python3 scripts/run_distributed_sweep.py --functions createDid --tps-list 3000 --max-retries 1
  python3 scripts/run_distributed_sweep.py --dry-run
  ```
  Esse script lê os parâmetros de `terraform output -json`, então só funciona depois que o `apply` terminou.

Os parâmetros da varredura (`BENCHMARK_FILES`, `TPS_LIST` e `REPETITIONS`) ficam em `run_test_local.py`, no repositório `tests-with-caliper-production`.

### 6. Destruir

```bash
terraform destroy
```

## Como rodar: `feature/tests-with-distributed-parametric-node-count` (AWS)

### 1. Pré-requisitos adicionais

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) com credenciais válidas (`aws configure` ou variáveis `AWS_*`), com permissão para criar VPC, EC2, S3 e IAM.

### 2. Configurar `terraform.tfvars`

```hcl
allowed_ssh_cidr      = "SEU_IP_PUBLICO/32"   # seu IP
private_key_path      = "~/.ssh/besu-key"
public_key_path       = "~/.ssh/besu-key.pub"
instance_type_node1   = "c6i.2xlarge"
instance_type_besu    = "c6i.xlarge"
instance_type_caliper = "c6i.xlarge"
node_count            = 6                      # de 4 a 14 (QBFT exige no mínimo 4)
```

Região e zona padrão: `us-east-1` e `us-east-1a` (`aws_region` e `aws_az` em `variables.tf`).

### 3. Subir

```bash
terraform init
terraform plan
terraform apply
```

O `apply` provisiona as instâncias, sobe os `node_count` nós Besu (Node-1 e Node-3 são bootnodes), implanta os contratos e roda, na VM do Caliper, a varredura `run_test_local.py`, seguida da extração dos CSVs para o S3.

```bash
terraform output caliper_log_command    # acompanhar o log do Caliper
terraform output validation_commands    # eth_blockNumber e net_peerCount
```

### 4. Resultados

Os CSVs vão para o bucket S3 (`terraform output s3_data_bucket`), no prefixo `caliper-results/<timestamp>/`:

```bash
aws s3 ls s3://<bucket>/caliper-results/ --recursive
aws s3 cp s3://<bucket>/caliper-results/<timestamp>/ ./caliper-results/ --recursive
```

### 5. Destruir

```bash
terraform destroy
```

## Estrutura

| Arquivo | Função |
|---|---|
| `main.tf`, `variables.tf`, `outputs.tf` | Recursos de nuvem e a ordem das etapas (provisioners) |
| `scripts/node_user_data.sh` | Instala Docker (e azcopy, na Azure) em cada VM |
| `scripts/generate_and_distribute_keys.sh` | Gera chaves e genesis, ajusta IPs e distribui pelo armazenamento de objetos |
| `scripts/start_besu_node.sh` | Sobe o nó Besu (bootnode ou validator) |
| `scripts/deploy_contracts.sh` | Implanta os contratos e salva os endereços |
| `scripts/run_caliper_tests.sh` | Configura o Caliper e roda a varredura |
| `scripts/run_caliper_manager_distributed.sh`, `scripts/run_distributed_sweep.py`, `scripts/remote_patch_yaml.py` | Modo distribuído com MQTT (só na branch Azure) |
