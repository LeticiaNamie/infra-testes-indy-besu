# Checklist: portar de AWS para Azure

Espelha o formato de `DISTRIBUTED_PORTING_CHECKLIST.md` (checkbox por
script/trecho), mas para a migração de provedor de cloud, não de topologia.
Itens já implementados nesta branch (`feature/tests-with-azure-distributed-nodes`)
estão marcados; os que restam são de validação com credenciais reais e do
descomissionamento final da AWS. Descartável/arquivável depois que a migração
for concluída e validada — a versão durável fica nas seções "Lições da
migração Azure" e "Mapeamento AWS → Azure" do `CLAUDE.md`.

## 0. Pré-requisitos (Stage 0 — não executados nesta sessão, sem acesso a `az`)

- [ ] `az login` + registrar os resource providers `Microsoft.Compute`,
      `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.ManagedIdentity`,
      `Microsoft.Authorization`.
- [ ] `az vm list-skus --size Standard_F --size Standard_D --all` na região
      candidata + `az network list-usages` (quota de IP público) antes de
      confirmar `azure_location` (default atual em `variables.tf`: `eastus`,
      conservador — trocar para `brazilsouth` se os SKUs/quota permitirem).
- [x] Branch criada a partir de `feature/tests-with-parametric-besu-and-caliper-nodes`.
- [ ] Confirmar que `~/.ssh/besu-key(.pub)` existente é aceito pelo
      `admin_ssh_key` do Azure (deveria — mesmo formato OpenSSH).

## 1. Rede + identidade + storage (`main.tf`)

- [x] Provider `azurerm ~> 4.0` + `features {}` adicionado, coexistindo com `aws ~> 5.0`.
- [x] `azurerm_resource_group`, `azurerm_virtual_network`, `azurerm_subnet`.
- [x] `azurerm_network_security_group` + 7 `azurerm_network_security_rule`
      (SSH/RPC/WebSocket/P2P TCP+UDP/Prometheus/MQTT) — regras P2P e MQTT usam
      o CIDR da subnet como `source_address_prefix` no lugar do `self=true` da AWS.
- [x] `azurerm_subnet_network_security_group_association` (uma só, na subnet).
- [x] `azurerm_storage_account` (nome sem hífen + sufixo hash do subscription_id)
      + `azurerm_storage_container` + `allow_nested_items_to_be_public = false`.
- [x] `azurerm_user_assigned_identity` única (substitui as duas IAM roles
      `besu_node`/`caliper` da AWS) + `azurerm_role_assignment` (Storage Blob
      Data Contributor).
- [ ] Validar com `terraform apply -target=azurerm_resource_group.besu` (cascateia
      as dependências) contra uma subscription real.

## 2. VMs dos nós Besu (`main.tf` + `scripts/node_user_data.sh`)

- [x] `azurerm_public_ip.besu_node[]` (Standard/Static, todo nó — não só o
      Node-1 como era o `aws_eip`), `azurerm_network_interface.besu_node[]`
      (IP privado fixo `10.0.1.10+i`), `azurerm_linux_virtual_machine.besu_node[]`
      (`vm_size_node1`/`vm_size_besu`, disco `StandardSSD_LRS` 50GB, imagem
      Canonical `22_04-lts-gen2`, identidade compartilhada).
- [x] `scripts/node_user_data.sh`: bloco de instalação da AWS CLI v2 →
      instalação do `azcopy` (`aka.ms/downloadazcopy-v10-linux`); variável de
      template `aws_region` removida (não era usada no corpo do script).
- [x] `null_resource.wait_ssh_all_nodes`/`wait_network_ready`: `depends_on` e
      hosts repontados de `aws_eip`/`aws_instance` para `azurerm_public_ip`.
- [ ] Smoke test de 1 nó via `-target` (Stage 2 do plano) com credenciais reais.

## 3. Scripts com upload/download (`aws s3 cp/ls` → `azcopy copy/list`)

Todos seguem o mesmo padrão: guardas de env var
`S3_KEYS_BUCKET`/`AWS_REGION` → `AZURE_STORAGE_ACCOUNT`/`AZURE_STORAGE_CONTAINER`/
`AZURE_IDENTITY_CLIENT_ID`; `azcopy login --identity --identity-client-id=...`
adicionado logo após a definição das funções `log`/`check`; cada `aws s3 cp`
virou `azcopy copy` contra `https://$AZURE_STORAGE_ACCOUNT.blob.core.windows.net/$AZURE_STORAGE_CONTAINER/...`;
cópias recursivas de diretório usam `origem/*` (não só `origem/`) pra não
aninhar o nome do diretório de novo no destino — o `azcopy` teria esse
comportamento diferente do `aws s3 cp --recursive`, que já copia só o conteúdo.

- [x] `scripts/generate_and_distribute_keys.sh` — 8 uploads (chaves por nó + `shared/*`).
- [x] `scripts/start_besu_node.sh` — 7 downloads.
- [x] `scripts/deploy_contracts.sh` — 2 uploads (`network-info.json` + `deployments/*` recursivo).
- [x] `scripts/extract_and_upload_results.sh` — uploads filtrados por `*.csv`
      (`--exclude "*" --include "*.csv"` → `--include-pattern="*.csv"`) + `azcopy list`.
- [x] `scripts/run_caliper_tests.sh` — 4 downloads + delegação (env vars
      repassadas) para `extract_and_upload_results.sh`. **Atualização pós-porting:**
      `scripts/setup_caliper_worker_remote.sh` (mesmo padrão de 4 downloads, usado
      pela instância B) foi fundido neste arquivo — agora é um script único com
      `ROLE=manager` (padrão, instância A) ou `ROLE=worker` (instância B),
      controlando só a cauda (Prometheus + varredura vs. só `launch_workers.sh`).
- [x] `scripts/run_caliper_manager_distributed.sh` — **zero mudanças** (sem
      referência a AWS: só mosquitto + Caliper CLI).
- [x] `scripts/remote_patch_yaml.py` — **zero mudanças** (utilitário puro de regex).
- [x] `scripts/run_distributed_sweep.py` — só renomeação de flags/campos:
      `--s3-bucket`/`--aws-region` → `--storage-account`/`--storage-container`
      + `--identity-client-id` novo; `self.s3_bucket`/`self.aws_region` →
      `self.storage_account`/`self.storage_container`/`self.identity_client_id`;
      leitura de `terraform output` trocada para `storage_account_name`/
      `storage_container_name`/`azure_identity_client_id`; comando final que
      dispara `extract_and_upload_results.sh` via SSH atualizado. Lógica de
      orquestração SSH/MQTT/retry e o modelo "roda só no laptop do operador,
      nunca numa VM" — intactos. **Atualização pós-porting:** ganhou
      `upload_manager_files()` (scp + chmod, ver nota abaixo) e perdeu
      `distributed_path()`/o sufixo `-distributed.yaml` — os 6 YAMLs desse
      nome no `tests-with-caliper` eram idênticos aos originais depois do
      patch de `workers.number`/`tps`/`monitor.include` que já rodava em toda
      rodada, então foram removidos e o sweep passou a usar os
      `BENCHMARK_FILES` originais direto. Também perdeu `load_run_test_local()`
      (que importava, via `importlib`, um clone **local** de
      `tests-with-caliper/run_test_local.py` no laptop do operador) — trocado
      por `fetch_remote_sweep_config()`, que busca `TPS_LIST`/`BENCHMARK_FILES`
      via SSH do `run_test_local.py` já clonado (sempre fresco, do GitHub) na
      própria instância A. Motivo: o clone local podia ficar desatualizado ou
      numa branch diferente do que de fato está deployado, calculando o sweep
      com base em valores errados sem nenhum aviso. Como efeito colateral,
      quem for rodar o sweep manualmente não precisa mais ter o
      `tests-with-caliper` clonado no laptop — só o `infra-testes-indy-besu`
      e acesso SSH à instância A. A lógica de `wait_txpool_drain()` também
      passou a rodar remotamente (`wait_txpool_drain_remote()`), pelo mesmo
      motivo.

## 4. Caliper A/B (`main.tf`)

- [x] `azurerm_public_ip.caliper` + `azurerm_network_interface.caliper` (IP
      privado fixo `10.0.1.30`) + `azurerm_linux_virtual_machine.caliper`
      (`vm_size_caliper`, disco 30GB).
- [x] `azurerm_public_ip.caliper_b[]`/`azurerm_network_interface.caliper_b[]`/
      `azurerm_linux_virtual_machine.caliper_b[]` — mesmo `count` condicional
      da AWS (`node_caliper_count > 1 ? node_caliper_count - 1 : 0`), IPs
      `10.0.1.31+i`.
- [x] `null_resource.wait_ssh_caliper`/`run_caliper_tests`/`wait_ssh_caliper_b`/
      `setup_caliper_b`/`run_distributed_sweep`: hosts, `depends_on` e env vars
      repontados para os recursos Azure. **Atualização pós-porting:**
      `null_resource.upload_caliper_manager_script` foi removido — o upload
      (scp) + `chmod +x` de `run_caliper_manager_distributed.sh` e
      `remote_patch_yaml.py` na instância A passou a ser feito pelo próprio
      `run_distributed_sweep.py` (`upload_manager_files()`), não por um
      `null_resource` dedicado.
- [ ] Rodar com `node_caliper_count=1` (Stage 4) e depois `>1` (Stage 5) contra
      credenciais reais — inclui validar conectividade MQTT entre caliper A e
      B pela regra de NSG CIDR-source (segundo exercício independente dessa
      decisão, em porta diferente do P2P).

## 5. Outputs (`outputs.tf`)

- [x] `node1_public_ip`, `node_public_ips`, `node_private_ips`, `ssh_commands`,
      `rpc_url`, `log_commands`, `validation_commands`: repontados para
      `azurerm_public_ip`/`azurerm_network_interface`.
- [x] `s3_data_bucket` → `storage_account_name` + `storage_container_name`;
      novo `azure_identity_client_id`; `aws_region` → `azure_location`.
- [x] `deploy_artifacts_commands`/`caliper_results_commands`: texto interno
      trocado de `aws s3 ls/cp` para `azcopy list/copy`.
- [x] `caliper_public_ip`, `caliper_ssh_command`, `caliper_log_command`,
      `caliper_a_private_ip`, `caliper_b_public_ips`, `caliper_b_private_ips`,
      `caliper_b_ssh_commands`: repontados para os recursos Azure.

## 6. Stage 6 — descomissionamento AWS (CONCLUÍDA)

O `terraform.tfstate` estava vazio (nada tinha sido aplicado ainda), então não
havia recursos reais na AWS para destruir — a remoção foi só no HCL. A versão
AWS continua intacta e utilizável na branch
`feature/tests-with-parametric-besu-and-caliper-nodes`, então nada foi perdido.

- [x] Provider `aws`, `data.aws_ami`, `data.aws_caller_identity` removidos.
- [x] Todos os `aws_*` removidos (vpc/subnet/igw/route_table+assoc/security_group/
      key_pair/s3_bucket+public_access_block/iam_role+policy+instance_profile ×2/
      instance ×3/eip); `main.tf` reorganizado em ordem lógica (rede → storage →
      identidade → nós Besu → cadeia null_resource → Caliper A → Caliper B).
- [x] Variáveis `aws_region`/`aws_az`/`instance_type_node1`/`instance_type_besu`/
      `instance_type_caliper`/`instance_type_caliper_b` removidas de `variables.tf`.
- [x] `terraform.tfvars` limpo das chaves só-AWS (trocadas pelas `vm_size_*` equivalentes).
- [x] `terraform state list` confirmado com zero entradas (estava vazio antes e depois).
- [x] `terraform init -upgrade` rodado — provider `aws` removido de `.terraform.lock.hcl`.
- [x] `terraform validate` passa; `terraform plan` falha só por falta de credenciais
      Azure (`az` não configurado nesta máquina), sem nenhum erro de configuração.
