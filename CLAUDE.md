# CLAUDE.md

Este projeto Terraform provisiona uma rede Hyperledger Besu QBFT distribuída na AWS,
onde cada nó Besu roda em sua própria instância EC2 (1 container por máquina).

## Branch atual: feature/tests-with-parametric-besu-and-caliper-nodes

O número de validadores é controlado pela variável `node_count` — sem edição manual de arquivos.
Node-1 e Node-3 sempre exercem papel de bootnode além de validador.

**Para rodar com N validadores:**
```bash
terraform apply -var="node_count=7"   # 7 nós
terraform destroy -auto-approve
terraform apply -var="node_count=8"   # 8 nós
# ... até 14
```

## Comandos

```bash
# Primeira vez
terraform init

terraform plan -var="node_count=7"
terraform apply -var="node_count=7"   # ~15–20 minutos

terraform destroy -auto-approve        # remove TODOS os recursos AWS
```

## Variável node_count

| Valor | Nós | Bootnodes | Validators | Tolerância Byzantine |
|---|---|---|---|---|
| 6 (default) | 6 | Node-1, Node-3 | Node-2,4,5,6 | f=1 (quórum 4) |
| 7 | 7 | Node-1, Node-3 | Node-2,4,5,6,7 | f=2 (quórum 5) |
| 14 | 14 | Node-1, Node-3 | Node-2,4,5,6..14 | f=4 (quórum 10) |

Validação: `node_count` deve estar entre 4 e 14.

## Arquitetura e fluxo do terraform apply

```
aws_vpc + aws_subnet + aws_s3_bucket
  → aws_instance.besu_node[0..N-1]   (user_data: instala Docker + AWS CLI)
      IPs privados fixos: 10.0.1.10 (Node-1) … 10.0.1.(9+N) (Node-N)
  → aws_eip.node1   (IP elástico apenas no Node-1)
  → null_resource.wait_ssh_all_nodes    (local-exec: polling SSH nos N nós)
  → null_resource.generate_and_distribute_keys  (remote-exec no Node-1)
      • clona o repo, instala JDK 21 + Besu 24.7.0
      • patcha genesis_QBFT.json com jq (count = NODE_COUNT)
      • besu operator generate-blockchain-config → networkFiles/
      • generate-nodes-config.sh → Permissioned-Network/Node-1..N/data/
      • patch IPs no permissions_config.toml (por pubkey)
      • gera static-nodes.json e patcha --bootnodes no docker-compose.validator.yaml
      • upload para S3: node-1/..node-N/, shared/
  → null_resource.start_node1   (remote-exec Node-1 — bootnode)
  → null_resource.start_node3   (remote-exec Node-3 — bootnode, paralelo com Node-1)
  → null_resource.start_validators[0..M-1]   (remote-exec validators em paralelo, após bootnodes)
      • clona repo, instala JDK + Besu
      • baixa chaves do S3
      • build da imagem besu-image-local:1.0
      • docker compose up -d
  → null_resource.wait_network_ready    (local-exec: polling RPC — aguarda N-1 peers)
  → null_resource.deploy_contracts      (remote-exec Node-1 — Hardhat Ignition)
  → null_resource.run_caliper_tests     (remote-exec instância Caliper)
      • Prometheus gerado dinamicamente para N nós
      • testes executados e CSVs enviados para S3
```

## Lições de branches anteriores (mantidas aqui)

- `user_data` só faz setup básico (Docker + AWS CLI) — operações longas vão em `remote-exec`
- `chainId` é dinâmico; nunca hardcodar
- `null_resource` não suporta bloco `timeouts` — não usar
- JDK e Besu precisam estar na raiz do repo clonado antes do `docker build` (exigido pelas diretivas `COPY` do Dockerfile)
- `sudo docker` é usado nos scripts remote-exec (roda como ubuntu, não root)
- `null_resource` com `count` não aceita referências a outros recursos com `count` em `depends_on` — usar o recurso sem índice (depende de todas as instâncias)

## Arquivos de script

| Script | Onde roda | O que faz |
|---|---|---|
| `scripts/node_user_data.sh` | boot de cada EC2 (root) | Instala Docker + AWS CLI |
| `scripts/generate_and_distribute_keys.sh` | Node-1 via remote-exec | Patcha genesis, gera chaves, sobe para S3 |
| `scripts/start_besu_node.sh` | cada nó via remote-exec | Build da imagem + start compose |
| `scripts/deploy_contracts.sh` | Node-1 via remote-exec | Deploy dos contratos via Hardhat Ignition |
| `scripts/run_caliper_tests.sh` | instância Caliper via remote-exec | Executa testes e envia CSVs para S3 |

## Variáveis importantes (terraform.tfvars)

| Variável | Valor padrão | Descrição |
|---|---|---|
| `node_count` | `6` | Número total de nós (4–14) |
| `allowed_ssh_cidr` | — | IP/CIDR autorizado para SSH |
| `private_key_path` | `~/.ssh/besu-key` | Chave SSH para remote-exec |
| `instance_type_node1` | `c6i.2xlarge` | Tipo EC2 do Node-1 (bootnode + RPC endpoint) |
| `instance_type_besu` | `c6i.xlarge` | Tipo EC2 dos demais nós |
| `instance_type_caliper` | `m6i.4xlarge` | Tipo EC2 da instância Caliper (16 vCPUs, memory-optimized — CPU/RAM já mostraram folga em c6i.2xlarge, esse upgrade descarta recurso do cliente antes de investigar rede/RPC do Node-1) |
| `aws_az` | `us-east-1a` | AZ única para todos os nós |

## Caminhos relevantes nas instâncias

| Caminho | Finalidade |
|---|---|
| `/home/ubuntu/besu-setup.log` | Log unificado de todos os passos |
| `/home/ubuntu/besu-production-docker-distributed/` | Repo clonado |
| `/home/ubuntu/besu-production-docker-distributed/Permissioned-Network/Node-X/data/` | Chaves e configs do nó X |
| `/home/ubuntu/deploy-artifacts/` | Artefatos do deploy (endereços dos contratos) |
