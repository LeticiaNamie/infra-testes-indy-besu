# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## O que este projeto faz

Este é um projeto Terraform que automatiza testes de desempenho end-to-end de contratos inteligentes no Hyperledger Besu. Um único `terraform apply` provisiona uma instância EC2 na AWS e executa o pipeline completo em três etapas sequenciais:

1. **Etapa 1** — Provisiona a instância EC2 e sobe uma rede Besu QBFT permissionada com 6 nós via Docker Compose, configurada dinamicamente com o IP privado da própria instância.
2. **Etapa 2** — Faz o deploy dos contratos inteligentes do Indy DID Registry (IndyDidRegistry, CredentialDefinitionRegistry, SchemaRegistry, RevocationRegistry) via Hardhat Ignition usando a chave privada do Node-1.
3. **Etapa 3** — Executa os testes de benchmark com o Hyperledger Caliper, extrai relatórios CSV e faz upload para um bucket S3.

## Comandos

### Ciclo de vida do Terraform

```bash
# Primeira vez: inicializar providers
terraform init

# Visualizar mudanças
terraform plan

# Provisionar tudo (executa as três etapas; leva ~15–25 minutos)
terraform apply

# Destruir todos os recursos AWS
terraform destroy
```

### Acesso SSH (após o apply)

```bash
# Obter IP da instância e comando SSH dos outputs
terraform output ssh_command
terraform output rpc_url

# Acompanhar o log de setup em tempo real
ssh -i ~/.ssh/besu-key ubuntu@<IP> 'tail -f /var/log/besu-setup.log'

# Verificar informações da rede e endereços dos contratos (após Etapa 2)
ssh -i ~/.ssh/besu-key ubuntu@<IP> 'cat /home/ubuntu/deploy-artifacts/network-info.json'
ssh -i ~/.ssh/besu-key ubuntu@<IP> 'ls /home/ubuntu/deploy-artifacts/deployments/'

# Verificar CSVs do Caliper no S3 (após Etapa 3)
aws s3 ls s3://$(terraform output -raw s3_bucket_name)/ --recursive
```

### Validar a rede Besu manualmente

```bash
curl -X POST \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://<EIP>:8545
```

## Arquitetura

### Cadeia de dependências do Terraform

```
aws_eip → null_resource.wait_besu_ready → null_resource.deploy_contracts → null_resource.run_caliper_tests
```

O recurso `wait_besu_ready` faz polling do SSH e depois do endpoint RPC do Besu antes de prosseguir — é o mecanismo que serializa Etapa 1 → Etapa 2 → Etapa 3 sem nenhuma intervenção manual.

### Setup da EC2 (scripts/user_data.sh)

Executado como root no primeiro boot. Ações principais, em ordem:
- Instala Docker, clona `jeffsonsousa/besu-production-docker` (branch `develop`)
- Baixa JDK 21 e Besu 24.7.0 na raiz do repositório (exigido pelas diretivas `COPY` do `Dockerfile`)
- Executa `besu operator generate-blockchain-config` para gerar as chaves dos nós e o genesis
- Reescreve `permissions_config.toml` e `static-nodes.json` nos 6 diretórios `Node-X/data/` com o IP privado real da EC2 (obtido do metadata em `169.254.169.254`)
- Corrige o `docker-compose.yaml`: insere os enodes dos bootnodes (Node-1 e Node-3) e corrige a tag `besu-image-local:2.0` → `1.0`
- Constrói a imagem Docker local e executa `docker compose up -d`

### Deploy dos contratos (scripts/deploy_contracts.sh)

Executado na instância EC2 via `remote-exec`. Ações principais:
- Instala Node.js 18, clona `jeffsonsousa/contracts-indy-besu`
- Obtém o `chainId` dinamicamente da rede Besu em execução e lê a chave privada do Node-1 para gerar o `hardhat.config.ts`
- Compila e faz o deploy via `npx hardhat ignition deploy ./ignition/modules/DeployAndInitializeContracts.ts --network local`
- Salva `network-info.json` e copia o journal do Ignition para `/home/ubuntu/deploy-artifacts/`

### Execução dos testes com Caliper (scripts/run_caliper_tests.sh)

Executado na instância EC2 via `remote-exec`. Ações principais:
- Clona `LeticiaNamie/tests-with-caliper` (workspace do Caliper em `evaluation-contracts-indy-besu/`)
- Instala `@hyperledger/caliper-cli@0.5.0` e faz o bind com `besu:latest`
- Atualiza `networkconfig.json` com os endereços dos contratos deployados, chainId, fromAddress e chave privada dos artefatos da Etapa 2; também corrige a porta WebSocket (8546 → 8645)
- Executa `python3 run_test_local.py`, depois `extract_report_to_csv.py` e `extract_resource_to_csv.py`
- Faz upload de todos os CSVs para o S3 sob um prefixo com timestamp

### Infraestrutura AWS necessária

- Instância EC2 (`m5.2xlarge` conforme `terraform.tfvars`)
- Elastic IP (IP público fixo)
- Security Group: portas 22 (SSH, restrita), 8545/8546 (RPC/WS), 30303 (P2P), 9545 (Prometheus)
- Bucket S3 nomeado `tests-with-caliper-results-<account-id>` com role IAM/instance profile concedendo `s3:PutObject`
- Key pair SSH usando `~/.ssh/besu-key.pub` — esta chave deve existir localmente antes do `terraform apply`

### Variáveis

Definidas em `terraform.tfvars` (não versionado com segredos). A única variável obrigatória sem valor padrão é `allowed_ssh_cidr`. Variáveis principais:

| Variável | Padrão | Descrição |
|---|---|---|
| `allowed_ssh_cidr` | — | Restringe o SSH a um IP/CIDR específico |
| `private_key_path` | `~/.ssh/id_rsa` | Caminho da chave SSH privada para o `remote-exec` |
| `instance_type` | `m6i.2xlarge` | Tipo da instância EC2 |
| `project_name` | `besu-etapa1` | Prefixo para os nomes dos recursos AWS |

### Caminhos importantes na instância EC2

| Caminho | Finalidade |
|---|---|
| `/var/log/besu-setup.log` | Log unificado das três etapas |
| `/home/ubuntu/besu-production-docker/` | Repositório Docker do Besu (rede QBFT com 6 nós) |
| `/home/ubuntu/besu-production-docker/Permissioned-Network/Node-1/data/key` | Chave privada do Node-1 (usada no deploy e no Caliper) |
| `/home/ubuntu/contracts-indy-besu/` | Projeto Hardhat com os contratos Indy |
| `/home/ubuntu/deploy-artifacts/` | Journal do Ignition + `network-info.json` |
| `/home/ubuntu/tests-with-caliper/evaluation-contracts-indy-besu/` | Workspace do Caliper |