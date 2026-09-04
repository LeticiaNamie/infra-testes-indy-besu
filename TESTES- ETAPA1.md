# Prompt para IA — Geração do Terraform: Etapa 1 — Rede Besu QBFT em EC2 t3.medium

## Contexto do projeto

Preciso de um Terraform completo para provisionar uma instância EC2 `t3.medium` na AWS e executar automaticamente, via `user_data`, todos os passos necessários para subir uma rede Hyperledger Besu com 6 nós em consenso QBFT, usando Docker Compose, exatamente como se eu tivesse feito manualmente seguindo o README do repositório abaixo — incluindo os ajustes que precisei fazer na minha máquina local.

**Repositório base:** https://github.com/jeffsonsousa/besu-production-docker/tree/develop
**Branch:** `develop`

---

## Objetivo final

Ao final da execução do `terraform apply`, a instância EC2 deve:

1. Ter clonado o repositório `besu-production-docker` (branch `develop`)
2. Ter baixado e extraído Java JDK 21 e Besu v24.7.0 dentro da pasta do repositório
3. Ter gerado as chaves criptográficas e os arquivos de configuração da rede (genesis, permissions_config.toml, etc.)
4. Ter construído a imagem Docker local `besu-image-local:1.0`
5. Ter ajustado o `docker-compose.yaml` com os bootnodes corretos (node1 e node3)
6. Ter garantido a existência do arquivo `static-nodes.json` em todos os 6 nós
7. Ter executado `docker compose up -d` com os 6 containers rodando
8. Expor o resultado de uma chamada de validação RPC ao final (número do bloco atual)

---

## Infraestrutura AWS (Terraform)

Gere os seguintes recursos:

- **Provider:** `aws`, região configurável via variável (padrão: `us-east-1`)
- **VPC** com uma subnet pública e Internet Gateway
- **Security Group** liberando:
  - Porta 22 (SSH) — acesso restrito ao IP do operador via variável `allowed_ssh_cidr`
  - Porta 8545 (RPC HTTP) — acesso aberto (0.0.0.0/0) para validação externa
  - Porta 8546 (WebSocket) — acesso aberto
  - Portas 30303 UDP e TCP (P2P Besu) — acesso aberto
  - Porta 9545 (Prometheus metrics) — acesso aberto
  - Todo tráfego de saída liberado
- **Key Pair:** usar chave pública fornecida via variável `public_key_path`
- **EC2:** tipo `t3.medium`, AMI Ubuntu 22.04 LTS (buscar a AMI mais recente da região via `data "aws_ami"`)
- **Elastic IP** associado à instância para IP fixo
- **Output:** exibir o IP público da instância após o apply

---

## Script user_data — Passos detalhados

O `user_data` deve ser um script Bash executado como root no boot da instância. Cada etapa deve ser registrada em log com timestamp em `/var/log/besu-setup.log` e também emitir para o console do sistema (`/dev/console`). Use o padrão abaixo para cada passo:

```bash
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/besu-setup.log /dev/console
}
check() {
  if [ $? -ne 0 ]; then
    log "ERRO: $1"
    exit 1
  else
    log "OK: $1"
  fi
}
```

### Passo 1 — Atualização do sistema e instalação de dependências básicas

```bash
apt-get update -y && apt-get install -y git curl wget tar jq docker.io docker-compose-plugin
systemctl enable docker && systemctl start docker
```

Validação: `docker --version` e `docker compose version` devem retornar sem erro.

---

### Passo 2 — Clone do repositório

```bash
cd /home/ubuntu
git clone -b develop https://github.com/jeffsonsousa/besu-production-docker.git
cd besu-production-docker
```

Validação: verificar se a pasta `besu-production-docker` existe e contém o arquivo `Dockerfile`.

---

### Passo 3 — Download e extração do Java JDK 21

Conforme o README do repositório:

```bash
wget https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.tar.gz
tar -xvf jdk-21_linux-x64_bin.tar.gz
rm jdk-21_linux-x64_bin.tar.gz
export JAVA_HOME=$(pwd)/jdk-21.0.6
export PATH=$JAVA_HOME/bin:$PATH
```

> **Importante:** O Dockerfile do repositório copia `jdk-21.0.6/` a partir da raiz do projeto com `COPY jdk-21.0.6 /opt/jdk`. Portanto o diretório `jdk-21.0.6/` DEVE existir na raiz do repositório clonado antes do `docker build`.

Validação: `java -version` deve retornar sem erro.

---

### Passo 4 — Download e extração do Besu v24.7.0

Conforme o README do repositório:

```bash
wget https://github.com/hyperledger/besu/releases/download/24.7.0/besu-24.7.0.tar.gz
tar -xvf besu-24.7.0.tar.gz
rm besu-24.7.0.tar.gz
export PATH=$(pwd)/besu-24.7.0/bin:$PATH
```

> **Importante:** O Dockerfile copia `besu-24.7.0/` com `COPY besu-24.7.0 /opt/besu`. Portanto o diretório `besu-24.7.0/` DEVE existir na raiz do repositório clonado antes do `docker build`.

Validação: `besu --version` deve retornar `24.7.0`.

---

### Passo 5 — Geração das chaves e configuração da rede

Conforme o README:

```bash
besu operator generate-blockchain-config \
  --config-file=genesis_QBFT.json \
  --to=networkFiles \
  --private-key-file-name=key

cp networkFiles/genesis.json ./

chmod +x generate-nodes-config.sh
./generate-nodes-config.sh
```

Validação:
- O arquivo `genesis.json` deve existir na raiz do repositório
- O arquivo `permissions_config.toml` deve existir na raiz (gerado pelo script)
- O arquivo `permissions_config.toml` deve conter o array `nodes-allowlist` com 6 entradas no formato `enode://<public-key>@<ip>:<porta>`

---

### Passo 6 — Verificação da estrutura de diretórios dos nós

Verifique se a estrutura conforme descrita no README para 6 nós já foi criada:

```
Permissioned-Network/
├── genesis.json
├── permissions_config.toml
├── Node-1/data/   → key, key.pub, permissions_config.toml
├── Node-2/data/   → key, key.pub, permissions_config.toml
├── Node-3/data/   → key, key.pub, permissions_config.toml
├── Node-4/data/   → key, key.pub, permissions_config.toml
├── Node-5/data/   → key, key.pub, permissions_config.toml
└── Node-6/data/   → key, key.pub, permissions_config.toml
```

O script verifica se:
- O arquivo `genesis.json` está presente na raiz (cópia automática se não existir)
- O arquivo `permissions_config.toml` está presente na raiz
- O diretório `Permissioned-Network/` existe
- As 6 pastas `Node-1` a `Node-6` existem
- Cada pasta `Node-X/data/` existe e contém `key`, `key.pub` e `permissions_config.toml`

> **Nota:** Esta estrutura deve ter sido criada pelo script `generate-nodes-config.sh` executado no Passo 5. O script copia automaticamente o `genesis.json` para `Permissioned-Network/` se ele não existir.

Validação: O script confirma que todos os arquivos e pastas necessários estão presentes. Se algum estiver faltando, o script falha com erro.

---

### Passo 7 — Criação do arquivo `static-nodes.json` em cada nó

O arquivo `static-nodes.json` é necessário para que os nós se descubram. Ele deve conter **exatamente o array de enodes** que está no `nodes-allowlist` do `permissions_config.toml`, porém **apenas os valores do array, sem o título `nodes-allowlist`**, no formato JSON:

```json
[
  "enode://<public-key-1>@<ip-1>:30303",
  "enode://<public-key-2>@<ip-2>:30303",
  ...
  "enode://<public-key-6>@<ip-6>:30303"
]
```

O script deve:
1. Ler o `permissions_config.toml`
2. Extrair apenas as linhas que compõem o array `nodes-allowlist` (as strings entre `[` e `]`)
3. Formatar como JSON array válido
4. Escrever esse arquivo como `static-nodes.json` dentro de **cada um dos 6 diretórios** `Permissioned-Network/Node-X/data/`

> **Caminho esperado (exemplo para Node-1):** `./Permissioned-Network/Node-1/data/static-nodes.json`

Validação: `cat Permissioned-Network/Node-1/data/static-nodes.json` deve exibir um JSON array com 6 strings de enode.

---

### Passo 8 — Ajuste dos bootnodes no `docker-compose.yaml`

O `docker-compose.yaml` do repositório já vem com placeholders para os bootnodes. Você deve substituí-los com os valores reais de **node1 e node3**, que são o **primeiro e o terceiro item** do array `nodes-allowlist` do `permissions_config.toml`.

O script deve:
1. Extrair o enode do node1 (1º item do array `nodes-allowlist`)
2. Extrair o enode do node3 (3º item do array `nodes-allowlist`)
3. Substituir no `docker-compose.yaml` a configuração de bootnodes de todos os serviços (ou apenas onde estiver parametrizado) para usar esses dois enodes

Use `sed` ou Python para fazer a substituição de forma segura. Garanta que o formato de múltiplos bootnodes no argumento `--bootnodes` seja separado por vírgula sem espaços:

```
--bootnodes=enode://<key1>@<ip1>:30303,enode://<key3>@<ip3>:30303
```

Validação: `grep -i bootnode docker-compose.yaml` deve mostrar os dois enodes corretos.

---

### Passo 9 — Correção da tag no docker-compose e build da imagem Docker

#### 9.1 — Corrigir a tag do node1 no docker-compose.yaml

O `docker-compose.yaml` do repositório original define `node1` com `image: besu-image-local:2.0` — uma tag diferente dos demais nós, que já usam `besu-image-local:1.0`. Isso causa erro ao subir os containers pois a imagem `2.0` não existe e não é construída.

O script deve corrigir isso **antes do build**, substituindo a tag `2.0` do node1 pela `1.0`:

```bash
sed -i 's|besu-image-local:2\.0|besu-image-local:1.0|g' docker-compose.yaml
```

Validação: `grep "besu-image-local" docker-compose.yaml` não deve retornar nenhuma ocorrência de `2.0`. Todas as referências de imagem no compose devem ser `besu-image-local:1.0`.

#### 9.2 — Build da imagem

Com o compose corrigido, construir a imagem com a tag `1.0`:

```bash
docker build --no-cache -f Dockerfile -t besu-image-local:1.0 .
```

Validação: `docker images | grep besu-image-local` deve retornar a imagem com tag `1.0`.

---

### Passo 10 — Subir os containers

```bash
docker compose up -d
```

Aguardar 15 segundos para os containers iniciarem, então validar:

```bash
sleep 15
docker compose ps
```

Validação: todos os 6 containers devem aparecer com status `Up` ou `running`. Se algum aparecer como `Exit` ou `Restarting`, registrar o log do container problemático (`docker logs <container>`) e encerrar o script com erro.

---

### Passo 11 — Validação da rede via RPC

```bash
sleep 10
BLOCK=$(curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545 | jq -r '.result')
log "Número do bloco atual: $BLOCK"

PEERS=$(curl -s -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' http://127.0.0.1:8545 | jq -r '.result')
log "Contagem de peers: $PEERS"
```

Validação: `$BLOCK` deve ser um valor hexadecimal diferente de `null` (indica que a rede está produzindo blocos). `$PEERS` deve ser maior que `0x0`.

Se `$BLOCK` for `null`, registrar erro e encerrar com exit code 1.

---

## Observações e restrições importantes

1. **Todo o script deve rodar como root** (o `user_data` do EC2 já executa como root).
2. **Os paths** devem ser absolutos ou relativos a `/home/ubuntu/besu-production-docker/` — nunca assuma que o diretório corrente é o certo; use `cd` explícito antes de cada grupo de comandos.
3. **O log `/var/log/besu-setup.log`** deve ser acessível via SSH para auditoria posterior com `tail -f /var/log/besu-setup.log`.
4. **Variáveis de ambiente** (`JAVA_HOME`, `PATH`) definidas durante o user_data são locais ao script; use caminhos absolutos nos comandos subsequentes (`/home/ubuntu/besu-production-docker/besu-24.7.0/bin/besu`) em vez de depender do `PATH` exportado.
5. **O `docker-compose.yaml`** deve ser modificado antes do `docker build` e antes do `docker compose up`, nunca depois.
6. **Não use `sudo`** dentro do user_data — o script já roda como root.
7. **O Terraform deve usar `templatefile()`** para injetar variáveis no script bash (ex: região, IP) se necessário.
8. **O output do Terraform** deve incluir:
   - IP público da instância (Elastic IP)
   - Comando SSH para acesso: `ssh -i <chave> ubuntu@<ip>`
   - Comando para acompanhar o log: `ssh -i <chave> ubuntu@<ip> 'tail -f /var/log/besu-setup.log'`
   - URL de validação RPC: `http://<ip>:8545`

---

## Estrutura de arquivos Terraform esperada

```
main.tf           # Provider, VPC, SG, EC2, EIP
variables.tf      # Variáveis: região, CIDR SSH, path da chave pública
outputs.tf        # IP, SSH command, log command, RPC URL
scripts/
└── user_data.sh  # Script completo de setup (referenciado via templatefile)
```

---

## Variáveis Terraform

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `aws_region` | string | `"us-east-1"` | Região AWS |
| `instance_type` | string | `"t3.medium"` | Tipo da instância EC2 |
| `allowed_ssh_cidr` | string | — | CIDR do IP permitido para SSH (ex: `"203.0.113.0/32"`) |
| `public_key_path` | string | `"~/.ssh/id_rsa.pub"` | Caminho da chave pública SSH local |
| `project_name` | string | `"besu-etapa1"` | Prefixo de nomes dos recursos AWS |

---

## Critério de sucesso

O `terraform apply` foi bem-sucedido se, após aguardar aproximadamente 5-10 minutos do final do apply:

```bash
curl -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://<EIP>:8545
```

Retornar um JSON com `"result"` contendo um número hexadecimal maior que `"0x0"`, indicando que a rede está produzindo blocos.