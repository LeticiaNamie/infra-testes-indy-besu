# Prompt para IA — Terraform: Rede Besu Distribuída com 6 Instâncias EC2

## Contexto do projeto

Este projeto é parte de um TCC de avaliação de desempenho de contratos inteligentes Indy sobre uma rede Hyperledger Besu QBFT. A branch `feature/tests-with-one-node-v2` contém uma implementação funcional e testada do pipeline completo em **uma única instância EC2**, onde os 6 nós Besu rodavam como containers Docker em `docker-compose` na mesma máquina.

O objetivo é evoluir para um **ambiente distribuído real**: cada nó Besu roda em sua própria instância EC2, comunicando-se via rede privada AWS (VPC), mantendo a mesma lógica de consenso QBFT permissionado.

---

## Estado atual da branch `feature/tests-with-distributed-nodes`

### Etapas 1, 2 e 3 — IMPLEMENTADAS

**Etapa 1 — Rede Besu distribuída (2 nós):**

- 2 instâncias EC2 `t3.medium` com IPs privados fixos: `10.0.1.10` (Node-1/bootnode) e `10.0.1.11` (Node-2/validator)
- Repositório clonado: `LeticiaNamie/besu-production-docker-distributed`
- Node-1 roda `docker-compose.bootnode.yaml`; Node-2 roda `docker-compose.validator.yaml`
- Chaves geradas no Node-1 e distribuídas ao Node-2 via S3
- `user_data` só instala Docker + AWS CLI; todo o trabalho pesado vai em `remote-exec`

**Etapa 2 — Deploy dos contratos inteligentes:**

- Roda no Node-1 via `remote-exec` após `wait_network_ready` confirmar ≥ 1 peer
- Instala Node.js 18, clona `jeffsonsousa/contracts-indy-besu`
- Obtém `chainId` dinamicamente (`eth_chainId`)
- Lê chave privada do Node-1 em `Permissioned-Network/Node-1/data/key` (sem prefixo `0x`)
- Deploy via `npx hardhat ignition deploy`
- Salva artefatos localmente em `/home/ubuntu/deploy-artifacts/`
- **Faz upload dos artefatos para S3** em `s3://<besu-keys-bucket>/artifacts/`

**Etapa 3 — Testes com Caliper em instância dedicada:**

- EC2 separada (`aws_instance.caliper`) na mesma VPC — acessa Node-1 via IP privado `10.0.1.10`
- IAM role própria: leitura do bucket `besu-keys` + escrita no bucket `tests-with-caliper-results-<account-id>`
- `wait_ssh_caliper` roda em **paralelo** com o setup do Besu (a EC2 Caliper já pode bootar enquanto os nós sobem)
- `run_caliper_tests` espera tanto pelo `deploy_contracts` quanto pelo `wait_ssh_caliper`
- Script baixa artefatos e chave privada do S3 antes de executar os testes
- WebSocket URL: `ws://10.0.1.10:8645` (Node-1 privado)
- CSVs enviados para `s3://tests-with-caliper-results-<account-id>/<timestamp>/`

### Cadeia de dependências atual

```
aws_vpc + aws_subnet + aws_s3_bucket.besu_keys + aws_s3_bucket.caliper_results
  → aws_instance.besu_node[0,1]       (user_data: Docker + AWS CLI)
  → aws_instance.caliper              (user_data: Docker + AWS CLI)  ← em paralelo
  → aws_eip.node1
  → null_resource.wait_ssh_all_nodes   (polling SSH + .node-ready nos 2 nós Besu)
  → null_resource.wait_ssh_caliper     (polling SSH + .node-ready no Caliper)  ← em paralelo
  → null_resource.generate_and_distribute_keys  (Node-1: gera chaves, sobe para S3)
  → null_resource.start_node1 + start_node2     (paralelo: build + docker compose up)
  → null_resource.wait_network_ready   (polling net_peerCount >= 0x1 no Node-1)
  → null_resource.deploy_contracts     (Node-1: deploy Hardhat Ignition + upload S3)
  → null_resource.run_caliper_tests    (Caliper: baixa S3, configura, executa, sobe CSVs)
```

### Arquivos de script

| Script | Onde roda | O que faz |
|---|---|---|
| `scripts/node_user_data.sh` | boot de cada EC2 (root) | Instala Docker + AWS CLI, cria `.node-ready` |
| `scripts/generate_and_distribute_keys.sh` | Node-1 via remote-exec | Gera chaves, patcha IPs e portas, sobe para S3 |
| `scripts/start_besu_node.sh` | cada nó via remote-exec | Build da imagem + start compose correto |
| `scripts/deploy_contracts.sh` | Node-1 via remote-exec | Deploy Hardhat Ignition + upload artefatos S3 |
| `scripts/run_caliper_tests.sh` | Caliper EC2 via remote-exec | Baixa S3, configura Caliper, executa testes, sobe CSVs |

### Lições aprendidas (críticas para a implementação)

- `user_data` só faz setup básico — operações longas vão em `remote-exec`
- `wait_ssh_all_nodes` verifica SSH E o arquivo `.node-ready` (garante que user_data terminou antes de prosseguir)
- `chainId` é dinâmico; nunca hardcodar
- `null_resource` não suporta bloco `timeouts`
- JDK e Besu precisam estar na raiz do repo antes do `docker build` (exigido pelo `COPY` do Dockerfile)
- `sudo docker` nos scripts remote-exec (roda como ubuntu, não root)
- `PATH="/usr/local/bin:$PATH"` necessário nos scripts remote-exec (AWS CLI fica em `/usr/local/bin`)
- Cada nó do repositório usa **porta P2P diferente** (Node-1: 30303, Node-2: 30304) — `static-nodes.json` deve ser derivado do `permissions_config.toml` patchado, não construído com porta hardcodada
- `permissions_config.toml`: patch por pubkey (não substituição global de IP), pois cada nó tem IP diferente
- `docker-compose.validator.yaml` é patchado no Node-1 e distribuído via S3 para o Node-2 (que clona o repo original sem o patch)
- Chave privada do Node-1 no arquivo `key` não tem prefixo `0x` — **não adicionar prefixo** (branch anterior confirmou que funciona sem ele)
- `echo "y" |` antes do `npx hardhat ignition deploy` para evitar prompt interativo via SSH
- `LOG_FILE` nos scripts remote-exec deve ser em `/home/ubuntu/` (ubuntu não escreve em `/var/log/`)
- Caliper em EC2 separada usa IP privado do Node-1 (`10.0.1.10`) para RPC e WebSocket — **nunca `127.0.0.1`**
- Artefatos do deploy (network-info.json, deployments/) e chave privada do Node-1 chegam ao Caliper via S3

---

## Decisões de arquitetura (distribuído)

1. **IPs privados fixos**: `10.0.1.10` (Node-1) e `10.0.1.11` (Node-2) — conhecidos antes da geração das chaves
2. **Mesma AZ**: tráfego P2P intra-AZ com IP privado é gratuito na AWS
3. **EIP só no Node-1**: ponto de acesso externo para SSH do operador, RPC do Caliper e upload S3
4. **S3 como canal de distribuição**: chaves, configs, artefatos de deploy e resultados CSV trafegam pelos buckets
5. **Portas por nó** (do repositório original): Node-1 usa 30303/8545/8645; Node-2 usa 30304/8546/8646
6. **Caliper em EC2 separada**: não interfere com os nós Besu; acessa Node-1 via IP privado `10.0.1.10:8645` (WS) e `10.0.1.10:8545` (RPC)
7. **EC2 Caliper inicializa em paralelo** com os nós Besu — `wait_ssh_caliper` corre junto com o setup da rede, só `run_caliper_tests` precisa de tudo pronto

---

## Variáveis (terraform.tfvars)

| Variável | Valor | Descrição |
|---|---|---|
| `allowed_ssh_cidr` | IP/32 do operador | CIDR para SSH |
| `private_key_path` | `~/.ssh/besu-key` | Chave SSH para remote-exec |
| `public_key_path` | `~/.ssh/besu-key.pub` | Chave pública para key pair AWS |
| `instance_type` | `t3.medium` | Tipo EC2 (só Besu por enquanto) |
| `aws_az` | `us-east-1a` | AZ única para todos os nós |
| `project_name` | `besu-distributed` | Prefixo dos recursos AWS |
