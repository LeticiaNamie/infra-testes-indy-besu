# CLAUDE.md

Este projeto Terraform provisiona uma rede Hyperledger Besu QBFT distribuída,
onde cada nó Besu roda em sua própria instância (1 container por máquina),
mais instância(s) dedicada(s) para os testes de benchmark com Caliper.

## Branch atual: feature/tests-with-azure-distributed-nodes — infraestrutura em Azure

Esta branch migrou a infraestrutura de AWS para Azure (motivo: troca de
provedor de cloud para a pesquisa). Os recursos `aws_*` foram removidos do
HCL — a versão AWS continua disponível, intacta, na branch
`feature/tests-with-parametric-besu-and-caliper-nodes`, caso seja preciso
rodar testes nela de novo. **Status: código completo, ainda não testado com
credenciais Azure reais** — ver `PORTING_CHECKLIST_AZURE.md` para o
detalhamento script-a-script e o checklist de validação.

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

terraform destroy -auto-approve        # remove todos os recursos Azure
```

Pré-requisito Azure (só uma vez, por máquina do operador): `az login` +
registrar os resource providers `Microsoft.Compute`, `Microsoft.Network`,
`Microsoft.Storage`, `Microsoft.ManagedIdentity`, `Microsoft.Authorization`.
Isso não faz parte do ciclo normal de apply/destroy, é setup de ambiente —
equivalente a configurar credenciais AWS uma vez.

## Variável node_count

| Valor | Nós | Bootnodes | Validators | Tolerância Byzantine |
|---|---|---|---|---|
| 6 (default) | 6 | Node-1, Node-3 | Node-2,4,5,6 | f=1 (quórum 4) |
| 7 | 7 | Node-1, Node-3 | Node-2,4,5,6,7 | f=2 (quórum 5) |
| 14 | 14 | Node-1, Node-3 | Node-2,4,5,6..14 | f=4 (quórum 10) |

Validação: `node_count` deve estar entre 4 e 14.

## Arquitetura e fluxo do terraform apply

Mesma topologia lógica da versão AWS anterior (branch
`feature/tests-with-parametric-besu-and-caliper-nodes`) — uma VNet única, uma
subnet única, um NSG único, mesmos papéis de nó, mesmo esquema de IP fixo.
Cada nome/descrição de etapa do `null_resource` abaixo é **byte-a-byte igual**
ao da versão AWS — prova de que a orquestração em si não mudou na migração, só
os recursos de nuvem por trás de cada `host`/env var.

```
azurerm_resource_group + azurerm_virtual_network + azurerm_storage_account
  → azurerm_linux_virtual_machine.besu_node[0..N-1]   (custom_data: instala Docker + azcopy)
      IPs privados fixos: 10.0.1.10 (Node-1) … 10.0.1.(9+N) (Node-N)
      IP público Standard/Static em CADA nó (azurerm_public_ip.besu_node[*])
  → null_resource.wait_ssh_all_nodes    (local-exec: polling SSH nos N nós)
  → null_resource.generate_and_distribute_keys  (remote-exec no Node-1)
      • clona o repo, instala JDK 21 + Besu 24.7.0
      • patcha genesis_QBFT.json com jq (count = NODE_COUNT)
      • besu operator generate-blockchain-config → networkFiles/
      • generate-nodes-config.sh → Permissioned-Network/Node-1..N/data/
      • patch IPs no permissions_config.toml (por pubkey)
      • gera static-nodes.json e patcha --bootnodes no docker-compose.validator.yaml
      • azcopy login --identity + upload para o Blob Storage: node-1/..node-N/, shared/
  → null_resource.start_node1   (remote-exec Node-1 — bootnode)
  → null_resource.start_node3   (remote-exec Node-3 — bootnode, paralelo com Node-1)
  → null_resource.start_validators[0..M-1]   (remote-exec validators em paralelo, após bootnodes)
      • clona repo, instala JDK + Besu
      • azcopy login --identity + baixa chaves do Blob Storage
      • build da imagem besu-image-local:1.0
      • docker compose up -d
  → null_resource.wait_network_ready    (local-exec: polling RPC — aguarda N-1 peers)
  → null_resource.deploy_contracts      (remote-exec Node-1 — Hardhat Ignition)
  → null_resource.run_caliper_tests     (remote-exec instância Caliper)
      • Prometheus gerado dinamicamente para N nós
      • testes executados e CSVs enviados para o Blob Storage
  → [opcional, node_caliper_count > 1] Caliper B[0..K-1] via MQTT, orquestrado
    do laptop do operador por scripts/run_distributed_sweep.py
```

## Lições de branches anteriores (AWS — mantidas por histórico)

- `user_data`/`custom_data` só faz setup básico (Docker + CLI de storage) — operações longas vão em `remote-exec`
- `chainId` é dinâmico; nunca hardcodar
- `null_resource` não suporta bloco `timeouts` — não usar
- JDK e Besu precisam estar na raiz do repo clonado antes do `docker build` (exigido pelas diretivas `COPY` do Dockerfile)
- `sudo docker` é usado nos scripts remote-exec (roda como ubuntu, não root)
- `null_resource` com `count` não aceita referências a outros recursos com `count` em `depends_on` — usar o recurso sem índice (depende de todas as instâncias). **Continua valendo no Azure** — é limitação do Terraform, não do provider.

## Lições da migração Azure (novas, desta branch)

- **RBAC leva tempo pra propagar**: depois do `azurerm_role_assignment` ser criado, a identidade gerenciada pode não conseguir acessar o Storage por alguns minutos. Se `azcopy login --identity` falhar logo após um apply, tente de novo antes de assumir erro de configuração.
- **`azcopy login` roda em CADA script**, não uma vez no boot — os scripts rodam via SSH como `ubuntu`, não como root, então um login cacheado no `custom_data` (que roda como root) não seria visto pela sessão SSH.
- **Nome de storage account não aceita hífen** e precisa ser globalmente único — por isso o nome é `lower(replace(project_name,"-",""))` + sufixo hex do subscription_id, não `project_name` direto.
- **NSG não tem "self=true"** como o Security Group da AWS — as regras de P2P/MQTT usam o CIDR da subnet como `source_address_prefix`, o que dá o mesmo resultado porque só há uma subnet e ela é exclusiva desta rede.
- **Standard SKU de IP público exige `allocation_method = "Static"`** — por isso toda instância (não só o Node-1, como era o `aws_eip` na AWS) tem um `azurerm_public_ip` Static dedicado.
- **Imagem precisa ser gen2** (`22_04-lts-gen2`) para ser compatível com as famílias de VM usadas (`Falsv6`/`Dsv7`), e ambas também precisam de suporte a NVMe na imagem (imagens populares como a Canonical usada aqui já suportam).
- **NIC e IP público são recursos próprios** no Azure (ao contrário da AWS, que agrupa tudo em `aws_instance`) — qualquer mudança de rede em uma VM Azure normalmente mexe em 2-3 recursos (NIC, IP público, VM), não só um.
- **Fsv2 está com crescimento de capacidade bloqueado pela Microsoft** desde jul/2026 (migração de hardware) — pedido de aumento de cota pra Fsv2 (e outras séries antigas: F, D, Ds, Dv2, Dsv2, Av2, B, Bs, G, Gs, Ls, Lsv2) simplesmente não é aprovado, não importa o quanto se tente ou espere. Cotas já aprovadas antes continuam funcionando; só pedidos novos são bloqueados. Não é bug de permissão nem de sincronização de conta — é decisão de capacidade da própria Microsoft.
- **Cuidado com qual "sucessor" escolher**: os sucessores mais divulgados do Fsv2 (`Fasv6`/`Fasv7`/`Famsv6`/`Famsv7`) têm de 2x a 4x mais RAM por vCPU — usar eles quebraria a paridade com a linha de base AWS. A variante certa é a linha "low-memory" (`Fals*`), que mantém a mesma razão 2GB/vCPU do Fsv2. Ressalva: sem Hyper-Threading (vCPU = núcleo físico inteiro) nessas gerações, então cada vCPU é um pouco mais forte que no Fsv2/AWS original — inevitável, mas os números de vCPU/RAM alocados continuam idênticos.
- **Cota de vCPU é por família específica, não só total regional** — mesmo com "Total Regional vCPUs" alto, uma família especifica pode estar em 0 (ou em "alta demanda") e bloquear tudo daquela família independentemente do total. Checar `az vm list-usage --location <região>` filtrando pela família exata antes de aplicar.
- **"Alta demanda" é diferente de "crescimento bloqueado"**: tanto `Dsv5` (Caliper) quanto `Falsv6` (nós Besu, sucessor do Fsv2) bateram na mensagem "está em alta demanda em East US — selecione solucionar problemas" ao pedir cota. Isso é desbalanço temporário de oferta/demanda por região/família — diferente do bloqueio permanente do Fsv2. Pro Caliper funcionou subir mais uma geração (`Dsv5→Dsv7`, confirmado via `az vm list-skus` sem nenhuma restrição nas 3 zonas de eastus). Pro nós Besu, a geração seguinte (`Falsv7`) **nem aparece no catálogo do East US** (ausência total no `list-skus`, não é só restrição — bate com a busca vazia no portal) — então ficamos no `Falsv6` mesmo, cujo bloqueio "alta demanda" precisa mesmo do chamado de suporte pra liberar (não tem SKU alternativa com o mesmo ratio disponível na região agora).
- **A restrição de "alta demanda" é por subscription, igual em TODAS as zonas** — checado via `az vm list-skus`: `Standard_F8als_v6` tem `NotAvailableForSubscription` nas zonas 1, 2 e 3 ao mesmo tempo. Ou seja, trocar de zona não contorna esse tipo de bloqueio (diferente de uma falta de capacidade pontual, que costuma ser por zona) — só a aprovação do pedido de acesso resolve.
- **`azure_availability_zone` é uma variável só, compartilhada por TODOS os recursos zonais** (IP público e VM de cada nó Besu, Caliper A, Caliper B) — fixá-la garante que o cluster inteiro cai na mesma zona, sem exceção, pelo simples fato de todo recurso zonal referenciar essa mesma variável. Equivalente ao que a AWS garantia de graça (lá a AZ era fixada uma vez na subnet, e subnets na AWS são zonais por natureza — no Azure a subnet é regional, cobre todas as zonas, por isso a zona precisa ser setada em cada recurso individualmente).
- **Subscription Free Trial tem cota de vCPU muito baixa** (4 no total, algumas famílias com 0) — só sobe de verdade depois do upgrade pra Pay-As-You-Go (portal → Cost Management + Billing → Subscriptions → Upgrade, exige cartão). Mesmo depois do upgrade, pedidos de aumento de cota podem aparecer como "não elegível" nas primeiras horas (reavaliação de risco da conta nova) — nesse caso, abrir um chamado manual de suporte (Ajuda + Suporte → Service and subscription limits) funciona mesmo quando o self-service não deixa.

## Tamanhos de VM (paridade com a linha de base original em AWS)

| Papel | Variável | SKU Azure (vCPU/RAM) | Equivalente AWS de origem |
|---|---|---|---|
| Node-1 | `vm_size_node1` | `Standard_F8als_v6` (8/16GB) | c6i.2xlarge (8/16GB) |
| Nodes 2..N | `vm_size_besu` | `Standard_F4als_v6` (4/8GB) | c6i.xlarge (4/8GB) |
| Caliper A/B | `vm_size_caliper` / `vm_size_caliper_b` | `Standard_D16s_v7` (16/64GB) | m6i.4xlarge (16/64GB) |

Paridade por vCPU:RAM, não por rótulo de família Azure — não usar `Esv5`
("memory optimized" no Azure, mas 16/128GB, dobraria a RAM da linha de base)
nem `Fasv6`/`Fasv7` (4GB/vCPU em vez de 2GB/vCPU).

## Arquivos de script

| Script | Onde roda | O que faz |
|---|---|---|
| `scripts/node_user_data.sh` | boot de cada VM (root, via `custom_data`) | Instala Docker + azcopy |
| `scripts/generate_and_distribute_keys.sh` | Node-1 via remote-exec | Patcha genesis, gera chaves, sobe para o Blob Storage |
| `scripts/start_besu_node.sh` | cada nó via remote-exec | Baixa chaves do Blob Storage, build da imagem + start compose |
| `scripts/deploy_contracts.sh` | Node-1 via remote-exec | Deploy dos contratos via Hardhat Ignition, sobe artefatos pro Blob Storage |
| `scripts/run_caliper_tests.sh` | instância Caliper via remote-exec — instância A com ROLE=manager (padrão), instâncias B com ROLE=worker | Baixa artefatos do Blob Storage, faz bind/config do Caliper; ROLE=manager sobe Prometheus e executa os testes (ou só setup_issuer.js se SKIP_SWEEP=true); ROLE=worker só deixa pronto o launch_workers.sh |
| `scripts/extract_and_upload_results.sh` | instância Caliper (chamado por run_caliper_tests.sh ou pelo sweep) | Extrai CSVs e sobe pro Blob Storage |
| `scripts/run_caliper_manager_distributed.sh` | instância Caliper A, enviado (scp) e chamado por run_distributed_sweep.py | Broker MQTT + manager distribuído — sem mudanças na migração |
| `scripts/run_distributed_sweep.py` | laptop do operador (nunca numa VM) | Orquestra a varredura distribuída via SSH |
| `scripts/remote_patch_yaml.py` | instância Caliper A, via SSH | Patch de campo YAML — sem mudanças na migração |

## Variáveis importantes (terraform.tfvars)

| Variável | Valor padrão | Descrição |
|---|---|---|
| `node_count` | `6` | Número total de nós (4–14) |
| `allowed_ssh_cidr` | — | IP/CIDR autorizado para SSH |
| `private_key_path` | `~/.ssh/besu-key` | Chave SSH para remote-exec |
| `azure_location` | `eastus` (revisar na Stage 0 — ver `PORTING_CHECKLIST_AZURE.md`) | Região Azure |
| `vm_size_node1` | `Standard_F8s_v2` | SKU do Node-1 (bootnode + RPC endpoint) |
| `vm_size_besu` | `Standard_F4s_v2` | SKU dos demais nós |
| `vm_size_caliper` / `vm_size_caliper_b` | `Standard_D16s_v5` | SKU das instâncias Caliper |

## Caminhos relevantes nas instâncias

| Caminho | Finalidade |
|---|---|
| `/home/ubuntu/besu-setup.log` | Log unificado de todos os passos |
| `/home/ubuntu/besu-production-docker-distributed/` | Repo clonado |
| `/home/ubuntu/besu-production-docker-distributed/Permissioned-Network/Node-X/data/` | Chaves e configs do nó X |
| `/home/ubuntu/deploy-artifacts/` | Artefatos do deploy (endereços dos contratos) |

## Validação pendente (credenciais Azure reais)

O `terraform.tfstate` está vazio (nada foi aplicado ainda) e o lado Azure
nunca rodou de verdade. Antes de confiar no cluster:

1. Configure `az login` + registre os resource providers (Stage 0 do checklist).
2. `terraform plan`/`apply` e valide de ponta a ponta com os outputs
   `validation_commands`, `deploy_artifacts_commands`, `caliper_results_commands`.

Ver `PORTING_CHECKLIST_AZURE.md` para o detalhamento completo por script/etapa.
