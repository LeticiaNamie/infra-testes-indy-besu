# Prompt para IA — Terraform: Rede Besu Distribuída com 6 Instâncias EC2

## Contexto do projeto

Este projeto é parte de um TCC de avaliação de desempenho de contratos inteligentes Indy sobre uma rede Hyperledger Besu QBFT. A branch `feature/tests-with-one-node-v2` já contém uma implementação funcional e testada do pipeline completo em **uma única instância EC2**, onde os 6 nós Besu rodavam como containers Docker em `docker-compose` na mesma máquina.

O objetivo agora é evoluir para um **ambiente distribuído real**: cada um dos 6 nós Besu roda em sua própria instância EC2, comunicando-se via rede privada AWS (VPC), mantendo a mesma lógica de consenso QBFT permissionado.

---

## O que já foi feito na branch `feature/tests-with-one-node-v2`

O pipeline original funciona em **3 etapas**, todas orquestradas por um único `terraform apply`:

### Etapa 1 — Rede Besu (user_data na EC2)
- Provisiona **1 instância EC2** (`m5.2xlarge`) com Ubuntu 22.04
- O `user_data.sh` (executado como root no boot) faz:
  - Instala Docker e docker-compose-plugin
  - Clona `jeffsonsousa/besu-production-docker` (branch `develop`)
  - Baixa JDK 21 e Besu 24.7.0 na raiz do repositório (exigido pelas diretivas `COPY` do `Dockerfile`)
  - Executa `besu operator generate-blockchain-config --config-file=genesis_QBFT.json --to=networkFiles --private-key-file-name=key` para gerar chaves e genesis
  - Obtém o IP privado da EC2 via `169.254.169.254/latest/meta-data/local-ipv4`
  - Substitui o IP em `permissions_config.toml` e `static-nodes.json` de todos os 6 nós
  - Corrige o `docker-compose.yaml`: insere bootnodes (Node-1 e Node-3) e corrige tag `besu-image-local:2.0` → `1.0`
  - Faz `docker build` da imagem `besu-image-local:1.0`
  - Executa `docker compose up -d` com **os 6 containers na mesma máquina**
- Um `null_resource.wait_besu_ready` com `local-exec` faz polling de SSH e do endpoint RPC `http://<IP>:8545` antes de avançar

### Etapa 2 — Deploy dos contratos inteligentes (remote-exec via SSH)
- `null_resource.deploy_contracts` executa `scripts/deploy_contracts.sh` via SSH na instância
- O script:
  - Instala Node.js 18
  - Clona `jeffsonsousa/contracts-indy-besu`
  - Obtém `chainId` dinamicamente da rede Besu (`eth_chainId`)
  - Lê a chave privada do Node-1 em `/home/ubuntu/besu-production-docker/Permissioned-Network/Node-1/data/key`
  - Gera `hardhat.config.ts` dinamicamente com `chainId` e chave privada
  - Compila e faz deploy via `npx hardhat ignition deploy ./ignition/modules/DeployAndInitializeContracts.ts --network local`
  - Salva artefatos em `/home/ubuntu/deploy-artifacts/` (inclui `network-info.json` com `chainId` e `deployed_addresses.json` com endereços dos 4 contratos: `IndyDidRegistry`, `CredentialDefinitionRegistry`, `SchemaRegistry`, `RevocationRegistry`)

### Etapa 3 — Testes com Caliper + upload S3 (remote-exec via SSH)
- `null_resource.run_caliper_tests` executa `scripts/run_caliper_tests.sh` via SSH
- O script:
  - Lê artefatos da Etapa 2 (`network-info.json`, `deployed_addresses.json`)
  - Clona `LeticiaNamie/tests-with-caliper` (workspace Caliper em `evaluation-contracts-indy-besu/`)
  - Instala `@hyperledger/caliper-cli@0.5.0` e faz `bind` com `besu:latest`
  - Configura `networkconfig.json` dinamicamente (chainId, endereços dos contratos, fromAddress, chave privada, porta WebSocket 8546→8645)
  - Executa `python3 run_test_local.py`
  - Gera CSVs com `extract_report_to_csv.py` e `extract_resource_to_csv.py`
  - Faz upload dos CSVs para S3 via `aws s3 cp` usando o instance profile IAM da EC2
- O bucket S3 é nomeado `tests-with-caliper-results-<account-id>`, criado pelo próprio Terraform com IAM role de `s3:PutObject`

### Cadeia de dependências Terraform atual
```
aws_eip → null_resource.wait_besu_ready → null_resource.deploy_contracts → null_resource.run_caliper_tests
```

### Lições aprendidas (importante para a nova implementação)
- **Nunca usar `user_data` para operações longas** (npm install, compilação): o cloud-init tem timeout interno que mata o processo. Usar `remote-exec` para tudo após o boot básico.
- **`chainId` é dinâmico**: gerado pelo `besu operator generate-blockchain-config`, muda a cada nova rede. Nunca hardcodar.
- **`null_resource` não suporta bloco `timeouts`** — ignorar essa configuração se aparecer.
- **Porta WebSocket do Besu está em 8645**, não 8546 (a configuração do repositório usa 8645).
- **Chave privada do Node-1** não tem prefixo `0x` no arquivo — adicionar dinamicamente quando necessário.
- **Permissão Docker socket** para o Caliper: o usuário `ubuntu` precisa estar no grupo `docker`; o script usa `exec sg docker "$0"` para re-executar com o grupo ativo sem novo login.
- **`echo "y" |`** antes do `npx hardhat ignition deploy` para evitar prompt interativo em sessão SSH sem TTY.

---

## O que será feito agora — Rede Distribuída

### Objetivo

Reproduzir o mesmo pipeline (Etapas 1, 2 e 3) em um ambiente onde **cada um dos 6 nós Besu roda em sua própria instância EC2**, comunicando-se via IP privado dentro da mesma VPC e AZ. O Caliper continuará conectando ao RPC de um dos nós (Node-1).

### Decisões de arquitetura

1. **IPs privados pré-fixados para os nós**: como os enodes Besu precisam dos IPs antes da geração das chaves, os IPs privados dos 6 nós são fixados no Terraform via argumento `private_ip` no `aws_instance`. Exemplo: `10.0.1.10` a `10.0.1.15` dentro de uma subnet `/24`. Isso elimina a necessidade de alocar EIPs antecipadamente só para gerar enodes.

2. **Mesma AZ para todos os nós**: todas as 6 instâncias ficam na mesma Availability Zone (ex: `us-east-1a`) para que o tráfego P2P entre elas seja gratuito (tráfego intra-AZ com IP privado não tem custo na AWS).

3. **EIPs somente onde necessário**: apenas Node-1 (ou o nó que serve como RPC para o Caliper) precisa de EIP para acesso externo (Caliper e operador). Os demais nós podem ter apenas IP público auto-atribuído para SSH de manutenção, ou acesso via Node-1 como bastion.

4. **Geração de chaves centralizada no Node-1**: após todas as 6 instâncias subirem (com Docker instalado mas sem Besu rodando), um `null_resource` faz SSH no Node-1, instala Besu, gera as chaves de todos os 6 nós com os IPs privados já conhecidos, e distribui as chaves para os demais nós via S3 (cada nó baixa sua própria chave no `user_data` ou via `remote-exec`).

5. **Cada instância roda apenas 1 container Besu**: em vez do `docker compose up -d` com 6 services, cada instância roda apenas o container correspondente ao seu nó.

6. **Etapas 2 e 3 permanecem iguais**: o deploy dos contratos e os testes com Caliper continuam operando no Node-1 (ou na instância com EIP), usando o mesmo `scripts/deploy_contracts.sh` e `scripts/run_caliper_tests.sh` da branch anterior com adaptações mínimas.

---

## Infraestrutura AWS a criar

### Rede (VPC)

Criar uma VPC dedicada (não usar a default) com:
- CIDR: `10.0.0.0/16`
- 1 subnet pública no CIDR `10.0.1.0/24`, fixada na AZ `us-east-1a` (ou variável `aws_az`)
- Internet Gateway + Route Table associada à subnet

### Instâncias EC2 para os nós Besu

```hcl
resource "aws_instance" "besu_node" {
  count = 6

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.besu.id
  vpc_security_group_ids      = [aws_security_group.besu_nodes.id]
  key_name                    = aws_key_pair.besu.key_name
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.besu_s3_profile.name
  private_ip                  = "10.0.1.${10 + count.index}"  # 10.0.1.10 … 10.0.1.15

  user_data = templatefile("${path.module}/scripts/node_user_data.sh", {
    node_index = count.index + 1  # 1 a 6
    aws_region = var.aws_region
    s3_keys_bucket = aws_s3_bucket.besu_keys.bucket
  })

  tags = {
    Name    = "${var.project_name}-node-${count.index + 1}"
    Project = var.project_name
    NodeIndex = tostring(count.index + 1)
  }
}
```

Os IPs privados fixos (`10.0.1.10` a `10.0.1.15`) são usados na geração dos enodes no passo de bootstrap.

### Elastic IP (somente para Node-1)

```hcl
resource "aws_eip" "node1" {
  instance = aws_instance.besu_node[0].id
  domain   = "vpc"
}
```

### Security Groups

**`besu_nodes`** — para as 6 instâncias de nó:
- Entrada porta 22 (SSH) de `var.allowed_ssh_cidr`
- Entrada porta 8545 (RPC HTTP) de `0.0.0.0/0`
- Entrada porta 8546 e 8645 (WebSocket) de `0.0.0.0/0`
- Entrada portas 30303 TCP e UDP — restrito ao próprio security group (apenas entre os nós)
- Entrada porta 9545 (Prometheus) de `0.0.0.0/0`
- Saída total liberada

### Bucket S3 para distribuição de chaves

```hcl
resource "aws_s3_bucket" "besu_keys" {
  bucket = "${var.project_name}-keys-${data.aws_caller_identity.current.account_id}"
  force_destroy = true  # removido junto com o terraform destroy
}
```

Política IAM nos nós: `s3:GetObject` neste bucket + `s3:PutObject` no bucket de resultados do Caliper.

### Bucket S3 para resultados do Caliper

Igual à branch anterior: `tests-with-caliper-results-<account-id>`.

---

## Scripts a criar

### `scripts/node_user_data.sh` — executado em cada uma das 6 instâncias no boot

Recebe via `templatefile`: `node_index`, `aws_region`, `s3_keys_bucket`.

Ações:
1. Instala Docker (igual à branch anterior) e AWS CLI
2. Adiciona `ubuntu` ao grupo `docker`
3. **Aguarda o arquivo de chaves estar disponível no S3** (loop de polling `aws s3 ls s3://<bucket>/node-<index>/key`), pois a geração ocorre no Node-1 após o boot
4. Baixa os arquivos do nó do S3:
   - `s3://<bucket>/node-<index>/key` → `/home/ubuntu/node-data/key`
   - `s3://<bucket>/node-<index>/key.pub` → `/home/ubuntu/node-data/key.pub`
   - `s3://<bucket>/shared/genesis.json` → `/home/ubuntu/node-data/genesis.json`
   - `s3://<bucket>/shared/static-nodes.json` → `/home/ubuntu/node-data/static-nodes.json`
   - `s3://<bucket>/shared/permissions_config.toml` → `/home/ubuntu/node-data/permissions_config.toml`
5. Sinaliza que está pronto (cria arquivo `/home/ubuntu/.node-ready`)

> **Não iniciar o Besu aqui.** O Besu será iniciado por `remote-exec` após todas as chaves serem distribuídas, para garantir que todos os nós sobem com configuração consistente.

### `scripts/generate_and_distribute_keys.sh` — executado no Node-1 via remote-exec

Ações:
1. Instala Besu 24.7.0 e JDK 21 (igual ao `user_data.sh` da branch anterior)
2. Clona `jeffsonsousa/besu-production-docker` (branch `develop`)
3. Executa `besu operator generate-blockchain-config` usando os IPs privados pré-conhecidos (`10.0.1.10` a `10.0.1.15`) no `genesis_QBFT.json
4. Gera `static-nodes.json` com os 6 enodes usando os IPs privados
5. Faz o patch do `permissions_config.toml` com os IPs privados reais
6. Faz upload para o S3:
   - Chaves de cada nó: `s3://<bucket>/node-<1-6>/key` e `key.pub`
   - Arquivos compartilhados: `s3://<bucket>/shared/genesis.json`, `static-nodes.json`, `permissions_config.toml`

### `scripts/start_besu_node.sh` — executado em cada nó via remote-exec

Recebe como argumento: `NODE_INDEX` (1 a 6).

Ações:
1. Verifica que `/home/ubuntu/node-data/key` existe (baixado pelo `user_data.sh`)
2. Clona `jeffsonsousa/besu-production-docker` se não existir
3. Baixa JDK 21 e Besu 24.7.0 na raiz (necessário para o `docker build`)
4. Constrói a imagem `besu-image-local:1.0`
5. Inicia o container Docker do nó correspondente:
   ```bash
   docker run -d \
     --name besu-node-${NODE_INDEX} \
     --restart unless-stopped \
     -p 30303:30303/tcp -p 30303:30303/udp \
     -p 8545:8545 -p 8546:8546 -p 8645:8645 -p 9545:9545 \
     -v /home/ubuntu/node-data:/opt/besu/data \
     besu-image-local:1.0 \
     --data-path=/opt/besu/data \
     --genesis-file=/opt/besu/data/genesis.json \
     --node-private-key-file=/opt/besu/data/key \
     --static-nodes-file=/opt/besu/data/static-nodes.json \
     --permissions-nodes-config-file=/opt/besu/data/permissions_config.toml \
     --rpc-http-enabled --rpc-http-host=0.0.0.0 --rpc-http-port=8545 \
     --rpc-ws-enabled --rpc-ws-host=0.0.0.0 --rpc-ws-port=8645 \
     --p2p-host=10.0.1.${9 + NODE_INDEX} \
     --p2p-port=30303 \
     --metrics-enabled --metrics-host=0.0.0.0 --metrics-port=9545
   ```
6. Aguarda o Besu responder em `http://127.0.0.1:8545` (polling, igual ao `wait_besu_ready` da branch anterior)

---

## Cadeia de dependências Terraform

```
aws_subnet + aws_s3_bucket.besu_keys
  → aws_instance.besu_node[0..5]  (user_data instala Docker, aguarda chaves no S3)
  → aws_eip.node1
  → null_resource.wait_ssh_all_nodes  (local-exec: aguarda SSH nos 6 nós)
  → null_resource.generate_and_distribute_keys  (remote-exec no Node-1: gera e sobe chaves para S3)
  → null_resource.start_all_nodes  (remote-exec em cada nó: inicia container Besu)
  → null_resource.wait_network_ready  (local-exec: polling RPC do Node-1)
  → null_resource.deploy_contracts  (remote-exec no Node-1: igual à branch anterior)
  → null_resource.run_caliper_tests  (remote-exec no Node-1: igual à branch anterior)
```

---

## Variáveis

Manter todas as variáveis existentes na branch `feature/tests-with-one-node-v2` e adicionar:

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `aws_az` | string | `"us-east-1a"` | AZ onde todas as instâncias serão criadas |
| `node_subnet_cidr` | string | `"10.0.1.0/24"` | CIDR da subnet dos nós |
| `node_private_ip_base` | number | `10` | Último octeto do primeiro nó (Node-1 = 10.0.1.10) |

---

## Outputs

Manter todos os outputs da branch anterior e adicionar:

```hcl
output "node_private_ips" {
  value = aws_instance.besu_node[*].private_ip
}

output "node1_public_ip" {
  value = aws_eip.node1.public_ip
}

output "ssh_commands" {
  value = [for i, inst in aws_instance.besu_node : 
    "ssh -i ~/.ssh/besu-key ubuntu@${inst.public_ip}  # Node-${i+1} (${inst.private_ip})"]
}
```

---

## Estrutura de arquivos esperada

```
main.tf
variables.tf
outputs.tf
terraform.tfvars
scripts/
├── node_user_data.sh              # boot das 6 instâncias (instala Docker, baixa chaves do S3)
├── generate_and_distribute_keys.sh  # roda no Node-1: gera chaves e sobe para S3
├── start_besu_node.sh             # roda em cada nó: build da imagem e start do container
├── deploy_contracts.sh            # igual à branch anterior (sem modificação)
└── run_caliper_tests.sh           # igual à branch anterior, ajustando RPC URL se necessário
```

---

## Critério de sucesso

O `terraform apply` foi bem-sucedido se:

```bash
# Todos os 6 nós respondem ao RPC
for IP in 10.0.1.10 10.0.1.11 10.0.1.12 10.0.1.13 10.0.1.14 10.0.1.15; do
  echo -n "Node $IP: "
  curl -s --max-time 5 -X POST \
    --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
    http://<EIP_NODE1>:8545 | jq -r '.result'
done
```

E o Node-1 reportar 5 peers (`0x5`), indicando que todos os 6 nós estão conectados entre si.

O resultado final do Caliper deve aparecer no S3:
```bash
aws s3 ls s3://tests-with-caliper-results-<account-id>/ --recursive
```
