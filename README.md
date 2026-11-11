# infra-azure-multi-caliper

Infraestrutura (Terraform) para avaliar o desempenho de contratos de identidade descentralizada (Indy DID) em uma rede **Hyperledger Besu QBFT distribuída em várias VMs**, com testes de carga feitos pelo **Hyperledger Caliper**.

Um único `terraform apply` provisiona as VMs, sobe a rede Besu, implanta os contratos e executa os testes. Os repositórios usados pelas VMs são:

| Papel | Repositório |
|---|---|
| Rede Besu (um nó por VM) | [LeticiaNamie/besu-docker-distributed](https://github.com/LeticiaNamie/besu-docker-distributed) |
| Contratos | [LeticiaNamie/smart-contracts-indy-besu](https://github.com/LeticiaNamie/smart-contracts-indy-besu) |
| Testes de carga (Caliper) | [LeticiaNamie/tests-with-caliper-production](https://github.com/LeticiaNamie/tests-with-caliper-production) |

Todos derivam de repositórios de Jeffson Sousa ([besu-production-docker](https://github.com/jeffsonsousa/besu-production-docker), [contracts-indy-besu](https://github.com/jeffsonsousa/contracts-indy-besu) e [evaluation-contracts-indy-besu](https://github.com/jeffsonsousa/evaluation-contracts-indy-besu)). As diferenças estão no README de cada um.

## Pré-requisitos

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

## Como rodar

### 1. Pré-requisitos da Azure

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

Outras variáveis (em `variables.tf`), todas com valor padrão:

| Variável | Padrão | O que controla |
|---|---|---|
| `node_count` | `6` | Quantidade de nós Besu (de 4 a 14; o QBFT exige no mínimo 4). Todos são validadores; Node-1 e Node-3 também são bootnodes. |
| `node_caliper_count` | `1` | Quantidade de VMs Caliper. |
| `spread_sends` | `false` | `false`: todos os workers enviam ao Node-1. `true`: o worker `i` envia ao nó `i % node_count`, distribuindo as transações entre os nós. |
| `caliper_a_workers` | `10` | Workers locais na VM A (manager). |
| `caliper_b_workers` | `10` | Workers em cada VM Caliper extra (usado só com `node_caliper_count > 1`). |

Qualquer uma pode ser definida no `terraform.tfvars` ou na linha de comando, por exemplo:

```bash
terraform apply -var="node_count=8" -var="node_caliper_count=3" -var="spread_sends=true"
```

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

## Estrutura

| Arquivo | Função |
|---|---|
| `main.tf`, `variables.tf`, `outputs.tf` | Recursos Azure e a ordem das etapas (provisioners) |
| `scripts/node_user_data.sh` | Instala Docker e azcopy em cada VM |
| `scripts/check_zone_capacity.sh` | Sonda, antes do `apply`, se a zona tem capacidade para todas as VMs |
| `scripts/generate_and_distribute_keys.sh` | Gera chaves e genesis, ajusta IPs e envia ao Blob Storage |
| `scripts/start_besu_node.sh` | Sobe o nó Besu (bootnode ou validator) |
| `scripts/deploy_contracts.sh` | Implanta os contratos e salva os endereços |
| `scripts/run_caliper_tests.sh` | Configura o Caliper e roda a varredura |
| `scripts/run_caliper_manager_distributed.sh`, `scripts/run_distributed_sweep.py`, `scripts/remote_patch_yaml.py` | Modo distribuído com MQTT |
| `scripts/extract_and_upload_results.sh` | Extrai os relatórios para CSV e envia ao Blob Storage |
