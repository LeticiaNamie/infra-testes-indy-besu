# infra-aws-distributed-validators

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

### 1. Pré-requisitos da AWS

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
| `main.tf`, `variables.tf`, `outputs.tf` | Recursos AWS e a ordem das etapas (provisioners) |
| `scripts/node_user_data.sh` | Instala Docker em cada instância |
| `scripts/generate_and_distribute_keys.sh` | Gera chaves e genesis, ajusta IPs e envia ao S3 |
| `scripts/start_besu_node.sh` | Sobe o nó Besu (bootnode ou validator) |
| `scripts/deploy_contracts.sh` | Implanta os contratos e salva os endereços |
| `scripts/run_caliper_tests.sh` | Configura o Caliper, roda a varredura e envia os CSVs ao S3 |
