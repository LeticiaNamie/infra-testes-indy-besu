# Prompt para IA — Geração do Terraform: Etapa 2 — Deploy dos Contratos Inteligentes

## Contexto do projeto

Esta é a **Etapa 2** de um experimento de avaliação de desempenho de contratos inteligentes em uma rede Hyperledger Besu QBFT. A Etapa 1 já provisionou uma instância EC2 `t3.medium` com a rede Besu rodando em 6 containers Docker. Esta etapa deve ser executada **na mesma instância**, sem recriar a infraestrutura.

**Repositório dos contratos:** https://github.com/jeffsonsousa/contracts-indy-besu
**Rede Besu já disponível em:** `http://127.0.0.1:8545`

---

## Objetivo final

Ao final da execução, a instância EC2 deve ter:

1. Clonado o repositório `contracts-indy-besu`
2. Instalado Node.js v18 e dependências npm
3. Obtido dinamicamente o `chainId` da rede Besu local
4. Obtido dinamicamente a chave privada do Node-1 da rede Besu
5. Gerado o `hardhat.config.ts` com os valores corretos
6. Compilado os contratos com Hardhat
7. Feito o deploy dos contratos via Hardhat Ignition
8. Registrado os endereços dos contratos implantados no log

---

## Infraestrutura AWS (Terraform)

**Não criar nova instância e não usar `user_data`.** O `user_data` da Etapa 1 já atingiu o limite de tempo do cloud-init durante os sleeps de validação — o mesmo problema ocorreria aqui. Use exclusivamente `remote-exec` via `null_resource` com conexão SSH.

O `null_resource` deve ter um `depends_on` explícito na instância EC2 da Etapa 1, e um `local-exec` de espera antes de conectar — pois a rede Besu pode ainda estar inicializando quando o `terraform apply` termina:

```hcl
resource "null_resource" "wait_besu_ready" {
  depends_on = [aws_instance.besu]  # ou aws_eip.besu

  provisioner "local-exec" {
    command = "echo 'Aguardando rede Besu estabilizar...' && sleep 120"
  }
}

resource "null_resource" "deploy_contracts" {
  depends_on = [null_resource.wait_besu_ready]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = aws_eip.besu.public_ip  # ou variável com o IP da instância existente
  }

  provisioner "remote-exec" {
    script = "${path.module}/scripts/deploy_contracts.sh"
  }

  timeouts {
    create = "20m"
  }
}
```

O `local-exec` de 120 segundos roda **na máquina local** antes de tentar o SSH — garantindo que o `user_data` da Etapa 1 já terminou e os containers Besu já estão de pé antes de iniciar o deploy.

Adicione as variáveis:

| Variável | Tipo | Descrição |
|---|---|---|
| `private_key_path` | string | Caminho local para a chave privada SSH (ex: `~/.ssh/id_rsa`) |
| `instance_public_ip` | string | IP público da instância da Etapa 1 (se não estiver no mesmo state) |

---

## Script `deploy_contracts.sh` — Passos detalhados

O script deve ser executado como usuário `ubuntu` (via SSH, não como root). Use o mesmo padrão de log da Etapa 1:

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
```

> **Atenção:** como o script roda via SSH como `ubuntu` (não root), use `sudo` quando necessário para instalações de sistema. Para operações dentro de `/home/ubuntu/`, não é necessário.

---

### Passo 1 — Verificar que a rede Besu está ativa

Antes de qualquer coisa, confirmar que a rede da Etapa 1 está respondendo:

```bash
log "Verificando se a rede Besu está ativa"
BLOCK=$(curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545 | jq -r '.result')
if [ -z "$BLOCK" ] || [ "$BLOCK" = "null" ] || [ "$BLOCK" = "0x0" ]; then
  log "ERRO: Rede Besu não está produzindo blocos. Execute a Etapa 1 primeiro."
  exit 1
fi
log "Rede Besu ativa — bloco atual: $BLOCK"
```

---

### Passo 2 — Instalação do Node.js v18

Instalar via repositório oficial NodeSource (não usar o Node.js do apt padrão do Ubuntu, que é desatualizado):

```bash
log "Instalando Node.js v18 via NodeSource"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
```

Validação:
```bash
node --version   # deve retornar v18.x.x
npm --version    # deve retornar 9.x.x ou superior
```

---

### Passo 3 — Clone do repositório dos contratos

```bash
CONTRACTS_ROOT="/home/ubuntu/contracts-indy-besu"

if [ -d "$CONTRACTS_ROOT" ]; then
  log "Removendo clone anterior de $CONTRACTS_ROOT"
  rm -rf "$CONTRACTS_ROOT"
fi

log "Clonando repositório contracts-indy-besu"
git clone https://github.com/jeffsonsousa/contracts-indy-besu.git "$CONTRACTS_ROOT"
```

Validação: verificar que o arquivo `hardhat.config.ts` existe em `$CONTRACTS_ROOT`.

---

### Passo 4 — Obter chainId dinamicamente

O `chainId` é gerado junto com as chaves da rede Besu e é único por instância — nunca hardcode esse valor:

```bash
log "Obtendo chainId da rede Besu"
CHAIN_ID_HEX=$(curl -s -X POST \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://127.0.0.1:8545 | jq -r '.result')

if [ -z "$CHAIN_ID_HEX" ] || [ "$CHAIN_ID_HEX" = "null" ]; then
  log "ERRO: Não foi possível obter o chainId"
  exit 1
fi

# Converter hex para decimal
CHAIN_ID=$(python3 -c "print(int('$CHAIN_ID_HEX', 16))")
log "chainId obtido: $CHAIN_ID_HEX (hex) = $CHAIN_ID (decimal)"
```

---

### Passo 5 — Obter chave privada do Node-1

A chave privada do primeiro nó está em:
`/home/ubuntu/besu-production-docker/Permissioned-Network/Node-1/data/key`

Esse arquivo contém apenas a chave privada em formato hex (sem prefixo `0x`). O Hardhat requer o prefixo `0x`:

```bash
log "Obtendo chave privada do Node-1"
KEY_FILE="/home/ubuntu/besu-production-docker/Permissioned-Network/Node-1/data/key"

if [ ! -f "$KEY_FILE" ]; then
  log "ERRO: Arquivo de chave privada não encontrado em $KEY_FILE"
  exit 1
fi

PRIVATE_KEY="0x$(cat $KEY_FILE)"
log "Chave privada do Node-1 obtida com sucesso"
```

> **Segurança:** não logar o valor da chave privada em nenhuma circunstância.

---

### Passo 6 — Gerar o `hardhat.config.ts` com valores dinâmicos

Substituir o arquivo original com os valores corretos obtidos nos passos anteriores:

```bash
log "Gerando hardhat.config.ts com chainId e chave privada dinâmicos"
cat > "$CONTRACTS_ROOT/hardhat.config.ts" << HARDHAT
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const config: HardhatUserConfig = {
  solidity: "0.8.24",
  networks: {
    local: {
      url: "http://127.0.0.1:8545",
      chainId: $CHAIN_ID,
      accounts: ["$PRIVATE_KEY"]
    }
  }
};

export default config;
HARDHAT
check "Geração do hardhat.config.ts"
```

Validação: `grep "chainId" "$CONTRACTS_ROOT/hardhat.config.ts"` deve retornar o valor decimal correto.

---

### Passo 7 — Instalar dependências npm

```bash
cd "$CONTRACTS_ROOT"
log "Instalando dependências npm"
npm install
check "npm install"
```

Validação: pasta `node_modules/` deve existir após o install.

---

### Passo 8 — Compilar os contratos

```bash
log "Compilando contratos com Hardhat"
npx hardhat compile
check "npx hardhat compile"
```

Validação: pasta `artifacts/` deve existir e conter os ABIs compilados.

---

### Passo 9 — Deploy dos contratos via Hardhat Ignition

```bash
log "Fazendo deploy dos contratos via Hardhat Ignition"
DEPLOY_OUTPUT=$(echo "y" | npx hardhat ignition deploy \
  ./ignition/modules/DeployAndInitializeContracts.ts \
  --network local 2>&1)

echo "$DEPLOY_OUTPUT" | tee -a "$LOG_FILE"
check "Deploy dos contratos"
```

Validação: a saída do deploy deve conter endereços de contratos no formato `0x...`. Extraia e logue os endereços:

```bash
log "Endereços dos contratos implantados:"
echo "$DEPLOY_OUTPUT" | grep -E "0x[a-fA-F0-9]{40}" | tee -a "$LOG_FILE"
```

---

### Passo 10 — Salvar artefatos do deploy

Salvar os endereços e ABIs para uso posterior na Etapa 3 (testes com Caliper):

```bash
log "Salvando artefatos do deploy"
DEPLOY_ARTIFACTS_DIR="/home/ubuntu/deploy-artifacts"
mkdir -p "$DEPLOY_ARTIFACTS_DIR"

# Copiar journal do Ignition com endereços e estado do deploy
cp -r "$CONTRACTS_ROOT/ignition/deployments/" "$DEPLOY_ARTIFACTS_DIR/" 2>/dev/null || true
check "Cópia dos artefatos do deploy"

# Salvar chainId e endereços em arquivo JSON para referência
cat > "$DEPLOY_ARTIFACTS_DIR/network-info.json" << JSON
{
  "chainId": $CHAIN_ID,
  "chainIdHex": "$CHAIN_ID_HEX",
  "rpcUrl": "http://127.0.0.1:8545",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
check "Criação do network-info.json"

log "Artefatos salvos em $DEPLOY_ARTIFACTS_DIR"
log "Deploy da Etapa 2 concluído com sucesso"
```

---

## Observações importantes

1. **Ordem de execução:** este script deve rodar **após** a Etapa 1 estar completa e a rede Besu produzindo blocos. O Passo 1 valida isso.

2. **O arquivo `key` do Node-1** não tem prefixo `0x` — o script adiciona dinamicamente no Passo 5.

3. **O `chainId` muda a cada nova instância** porque é gerado pelo `besu operator generate-blockchain-config` com base no `genesis_QBFT.json`. Nunca hardcode.

4. **O Hardhat Ignition** pede confirmação interativa ao rodar sem TTY (execução via SSH/script). Use `echo "y" |` para responder automaticamente — **não use `--confirm`**, pois essa flag não suprime o prompt em todas as versões:
   ```bash
   DEPLOY_OUTPUT=$(echo "y" | npx hardhat ignition deploy ./ignition/modules/DeployAndInitializeContracts.ts --network local 2>&1)
   ```

5. **Não usar `user_data` para esta etapa:** o cloud-init da AWS tem um timeout interno que mata processos longos — qualquer `sleep` ou operação demorada (como `npm install`) causa falha silenciosa do script. O `remote-exec` via SSH não tem essa limitação.

6. **Timeout do remote-exec:** o `npm install` e o `npx hardhat compile` podem demorar 2-5 minutos. O timeout de `20m` já está configurado no `null_resource` da seção de infraestrutura e cobre com folga.

---

## Critério de sucesso

O deploy foi bem-sucedido se:

```bash
ls /home/ubuntu/deploy-artifacts/deployments/
```

Retornar os arquivos de deployment do Ignition, e:

```bash
cat /home/ubuntu/deploy-artifacts/network-info.json
```

Retornar um JSON válido com o `chainId` correto.