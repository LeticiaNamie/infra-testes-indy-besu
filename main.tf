terraform {
  required_version = ">= 1.3.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

# ============================================================================
# Resource group + rede — VNet dedicada com subnet única e IPs privados fixos
# para os nós (mesma topologia lógica da versão AWS: uma rede isolada, uma
# subnet, um NSG compartilhado por todas as instâncias).
# ============================================================================

resource "azurerm_resource_group" "besu" {
  name     = "${var.project_name}-rg"
  location = var.azure_location
}

resource "azurerm_virtual_network" "besu" {
  name                = "${var.project_name}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.besu.location
  resource_group_name = azurerm_resource_group.besu.name
}

resource "azurerm_subnet" "besu" {
  name                 = "${var.project_name}-subnet"
  resource_group_name  = azurerm_resource_group.besu.name
  virtual_network_name = azurerm_virtual_network.besu.name
  address_prefixes     = [var.node_subnet_cidr]
}

# ============================================================================
# Security Group — mesmo NSG para todos os nós; P2P/MQTT liberados apenas
# entre eles. Sem equivalente a "self=true" no Azure: como só há uma subnet e
# ela é usada exclusivamente por esta rede, usar o CIDR da subnet como origem
# dá o mesmo resultado.
# ============================================================================

resource "azurerm_network_security_group" "besu_nodes" {
  name                = "${var.project_name}-nodes-nsg"
  location            = azurerm_resource_group.besu.location
  resource_group_name = azurerm_resource_group.besu.name
}

resource "azurerm_network_security_rule" "ssh" {
  name                        = "SSH"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.allowed_ssh_cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.besu.name
  network_security_group_name = azurerm_network_security_group.besu_nodes.name
}

# RPC HTTP: 8545 (bootnode.yaml) e 8546 (validator.yaml) — mesmas portas em todas as VMs
resource "azurerm_network_security_rule" "rpc_http" {
  name                        = "RPC-HTTP"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8545-8546"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.besu.name
  network_security_group_name = azurerm_network_security_group.besu_nodes.name
}

# WebSocket: 8645 (bootnode.yaml) e 8646 (validator.yaml)
resource "azurerm_network_security_rule" "websocket" {
  name                        = "WebSocket"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8645-8646"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.besu.name
  network_security_group_name = azurerm_network_security_group.besu_nodes.name
}

# P2P apenas entre instâncias desta rede (tráfego intra-nós via VNet).
# Range 30303-30302+N cobre as portas de cada nó (Node-i usa porta 30302+i).
resource "azurerm_network_security_rule" "p2p_tcp" {
  name                        = "P2P-TCP-entre-nos"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "30303-${30302 + var.node_count}"
  source_address_prefix       = var.node_subnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.besu.name
  network_security_group_name = azurerm_network_security_group.besu_nodes.name
}

resource "azurerm_network_security_rule" "p2p_udp" {
  name                        = "P2P-UDP-entre-nos"
  priority                    = 140
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "30303-${30302 + var.node_count}"
  source_address_prefix       = var.node_subnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.besu.name
  network_security_group_name = azurerm_network_security_group.besu_nodes.name
}

resource "azurerm_network_security_rule" "prometheus" {
  name                        = "Prometheus-metrics"
  priority                    = 150
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "9545-9546"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.besu.name
  network_security_group_name = azurerm_network_security_group.besu_nodes.name
}

# MQTT — broker do modo distribuído do Caliper (manager na instância A, workers remotos na B).
# Restrito às instâncias desta rede, não precisa expor pra fora da VNet.
resource "azurerm_network_security_rule" "mqtt" {
  name                        = "MQTT-Caliper-distribuido"
  priority                    = 160
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "1883"
  source_address_prefix       = var.node_subnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.besu.name
  network_security_group_name = azurerm_network_security_group.besu_nodes.name
}

resource "azurerm_subnet_network_security_group_association" "besu" {
  subnet_id                 = azurerm_subnet.besu.id
  network_security_group_id = azurerm_network_security_group.besu_nodes.id
}

# ============================================================================
# Storage — conta + container para distribuição de chaves e resultados entre os nós
# ============================================================================

# Nome de storage account não aceita hífen e precisa ser globalmente único —
# transformação determinística do project_name + sufixo curto da subscription,
# sem depender do provider "random".
resource "azurerm_storage_account" "besu_data" {
  name                            = "${lower(replace(var.project_name, "-", ""))}${substr(sha1(data.azurerm_client_config.current.subscription_id), 0, 8)}"
  resource_group_name             = azurerm_resource_group.besu.name
  location                        = azurerm_resource_group.besu.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_container" "besu_data" {
  name                  = "${var.project_name}-data"
  storage_account_id    = azurerm_storage_account.besu_data.id
  container_access_type = "private"
}

# ============================================================================
# Identidade gerenciada — usada por todas as VMs (nós Besu + Caliper A/B) para
# acessar o Storage sem credenciais explícitas (via "azcopy login --identity").
# Uma identidade só, compartilhada, já que todos os papéis precisam das mesmas
# permissões no mesmo container.
# ============================================================================

resource "azurerm_user_assigned_identity" "besu_data" {
  name                = "${var.project_name}-data-identity"
  resource_group_name = azurerm_resource_group.besu.name
  location            = azurerm_resource_group.besu.location
}

resource "azurerm_role_assignment" "besu_data_blob_contributor" {
  scope                = azurerm_storage_account.besu_data.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.besu_data.principal_id
}

# ============================================================================
# VMs — var.node_count instâncias com IPs privados fixos
#   index 0 → Node-1 (bootnode)  → 10.0.1.10
#   index 1 → Node-2 (validator) → 10.0.1.11
#   index 2 → Node-3 (bootnode)  → 10.0.1.12
#   index 3 → Node-4 (validator) → 10.0.1.13
#   ...
#   index N-1 → Node-N (validator) → 10.0.1.(10+N-1)
# ============================================================================

locals {
  # Usuário SSH fixo — todo script assume "ubuntu@"/"/home/ubuntu/..." como
  # constante; não expor como variável.
  admin_username = "ubuntu"

  # Node-1 (index 0) e Node-3 (index 2) são bootnodes; demais são validators
  node_roles = [
    for i in range(var.node_count) :
    (i == 0 || i == 2) ? "bootnode" : "validator"
  ]

  # Índices (0-based) dos nós que são apenas validators (exceto 0 e 2)
  validator_indices = [for i in range(var.node_count) : i if i != 0 && i != 2]

  # Peer count esperado em hex para wait_network_ready
  peers_expected_hex = format("0x%x", var.node_count - 1)
}

# Toda instância recebe IP público Standard+Static (o Azure não tem "IP
# público efêmero automático" — cada um precisa de um azurerm_public_ip
# próprio; Standard SKU exige alocação Static de qualquer forma).
resource "azurerm_public_ip" "besu_node" {
  count               = var.node_count
  name                = "${var.project_name}-node-${count.index + 1}-pip"
  resource_group_name = azurerm_resource_group.besu.name
  location            = azurerm_resource_group.besu.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.azure_availability_zone == null ? null : [var.azure_availability_zone]
}

resource "azurerm_network_interface" "besu_node" {
  count               = var.node_count
  name                = "${var.project_name}-node-${count.index + 1}-nic"
  resource_group_name = azurerm_resource_group.besu.name
  location            = azurerm_resource_group.besu.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.besu.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.${10 + count.index}"
    public_ip_address_id          = azurerm_public_ip.besu_node[count.index].id
  }
}

resource "azurerm_linux_virtual_machine" "besu_node" {
  count               = var.node_count
  name                = "${var.project_name}-node-${count.index + 1}"
  resource_group_name = azurerm_resource_group.besu.name
  location            = azurerm_resource_group.besu.location
  size                = count.index == 0 ? var.vm_size_node1 : var.vm_size_besu
  admin_username      = local.admin_username
  zone                = var.azure_availability_zone
  network_interface_ids = [
    azurerm_network_interface.besu_node[count.index].id,
  ]

  admin_ssh_key {
    username   = local.admin_username
    public_key = file(var.public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 50
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.besu_data.id]
  }

  custom_data = base64encode(templatefile("${path.module}/scripts/node_user_data.sh", {
    node_index = count.index + 1
  }))

  tags = {
    Name      = "${var.project_name}-node-${count.index + 1}"
    Project   = var.project_name
    NodeIndex = tostring(count.index + 1)
    NodeRole  = local.node_roles[count.index]
  }
}

# ============================================================================
# null_resource: cadeia de setup distribuído
# ============================================================================

# 1. Aguarda SSH disponível nos N nós antes de prosseguir
resource "null_resource" "wait_ssh_all_nodes" {
  depends_on = [azurerm_public_ip.besu_node, azurerm_linux_virtual_machine.besu_node]

  provisioner "local-exec" {
    command = <<-EOT
      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -i ${var.private_key_path}"

      wait_node() {
        local label=$1 host=$2 ssh_ok=0
        echo "Aguardando SSH no $label ($host)..."
        for i in $(seq 1 60); do
          if ssh $SSH_OPTS ubuntu@$host 'echo ok' 2>/dev/null; then
            echo "SSH $label ok após $((i * 10))s"
            ssh_ok=1
            break
          fi
          echo "Tentativa $i/60: aguardando SSH $label..."
          sleep 10
        done

        if [ "$ssh_ok" -eq 0 ]; then
          echo "ERRO: timeout aguardando SSH no $label"
          exit 1
        fi

        echo "Aguardando user_data concluir no $label (arquivo .node-ready)..."
        for i in $(seq 1 60); do
          if ssh $SSH_OPTS ubuntu@$host 'test -f /home/ubuntu/.node-ready' 2>/dev/null; then
            echo "user_data $label concluído após $((i * 10))s"
            return 0
          fi
          if ssh $SSH_OPTS ubuntu@$host 'grep -q "ERRO:" /var/log/besu-setup.log' 2>/dev/null; then
            echo "ERRO: user_data falhou no $label — veja /var/log/besu-setup.log"
            exit 1
          fi
          echo "Tentativa $i/60: user_data ainda em execução no $label..."
          sleep 10
        done
        echo "ERRO: timeout aguardando user_data no $label"
        exit 1
      }

      wait_node "Node-1" "${azurerm_public_ip.besu_node[0].ip_address}"
      %{~for i in range(1, var.node_count)~}
      wait_node "Node-${i + 1}" "${azurerm_public_ip.besu_node[i].ip_address}"
      %{~endfor~}
    EOT
  }
}

# 2. Gera chaves no Node-1 e distribui para o Blob Storage
resource "null_resource" "generate_and_distribute_keys" {
  depends_on = [null_resource.wait_ssh_all_nodes]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = azurerm_public_ip.besu_node[0].ip_address
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/generate_and_distribute_keys.sh"
    destination = "/tmp/generate_and_distribute_keys.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/generate_and_distribute_keys.sh",
      # Contas de worker do Caliper a permissionar (accounts-allowlist) — cobre o
      # total real de workers do modo distribuído (manager + extras), com piso de
      # 32 preservando o comportamento de sempre pro modo single-instance/pequeno.
      "NODE_COUNT=${var.node_count} AZURE_STORAGE_ACCOUNT=${azurerm_storage_account.besu_data.name} AZURE_STORAGE_CONTAINER=${azurerm_storage_container.besu_data.name} AZURE_IDENTITY_CLIENT_ID=${azurerm_user_assigned_identity.besu_data.client_id} TOTAL_CALIPER_WORKERS=${max(32, var.caliper_a_workers + (var.node_caliper_count > 1 ? (var.node_caliper_count - 1) * var.caliper_b_workers : 0))} bash /tmp/generate_and_distribute_keys.sh",
    ]
  }
}

# 3a. Inicia Node-1 (bootnode)
resource "null_resource" "start_node1" {
  depends_on = [null_resource.generate_and_distribute_keys]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = azurerm_public_ip.besu_node[0].ip_address
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/start_besu_node.sh"
    destination = "/tmp/start_besu_node.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/start_besu_node.sh",
      "NODE_INDEX=1 AZURE_STORAGE_ACCOUNT=${azurerm_storage_account.besu_data.name} AZURE_STORAGE_CONTAINER=${azurerm_storage_container.besu_data.name} AZURE_IDENTITY_CLIENT_ID=${azurerm_user_assigned_identity.besu_data.client_id} bash /tmp/start_besu_node.sh",
    ]
  }
}

# 3b. Inicia Node-3 (bootnode) — paralelo com Node-1; validators só sobem após ambos os bootnodes
resource "null_resource" "start_node3" {
  depends_on = [null_resource.generate_and_distribute_keys]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = azurerm_public_ip.besu_node[2].ip_address
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/start_besu_node.sh"
    destination = "/tmp/start_besu_node.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/start_besu_node.sh",
      "NODE_INDEX=3 AZURE_STORAGE_ACCOUNT=${azurerm_storage_account.besu_data.name} AZURE_STORAGE_CONTAINER=${azurerm_storage_container.besu_data.name} AZURE_IDENTITY_CLIENT_ID=${azurerm_user_assigned_identity.besu_data.client_id} bash /tmp/start_besu_node.sh",
    ]
  }
}

# 3c. Inicia validators (todos os nós exceto Node-1 e Node-3) em paralelo, após ambos os bootnodes
resource "null_resource" "start_validators" {
  count      = length(local.validator_indices)
  depends_on = [null_resource.start_node1, null_resource.start_node3]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = azurerm_public_ip.besu_node[local.validator_indices[count.index]].ip_address
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/start_besu_node.sh"
    destination = "/tmp/start_besu_node.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/start_besu_node.sh",
      "NODE_INDEX=${local.validator_indices[count.index] + 1} AZURE_STORAGE_ACCOUNT=${azurerm_storage_account.besu_data.name} AZURE_STORAGE_CONTAINER=${azurerm_storage_container.besu_data.name} AZURE_IDENTITY_CLIENT_ID=${azurerm_user_assigned_identity.besu_data.client_id} bash /tmp/start_besu_node.sh",
    ]
  }
}

# 4. Aguarda a rede Besu estar operacional: RPC respondendo e com N-1 peers conectados
resource "null_resource" "wait_network_ready" {
  depends_on = [
    null_resource.start_node1,
    null_resource.start_node3,
    null_resource.start_validators,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Aguardando Node-1 ter ${var.node_count - 1} peers conectados (net_peerCount = ${local.peers_expected_hex})..."
      for i in $(seq 1 60); do
        sleep 15
        RESULT=$(curl -s --max-time 5 -X POST \
          --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
          http://${azurerm_public_ip.besu_node[0].ip_address}:8545 2>/dev/null || true)
        PEERS=$(echo "$RESULT" | grep -o '"result":"0x[^"]*"' | grep -o '0x[0-9a-f]*' || true)
        if [ -n "$PEERS" ] && [ "$PEERS" = "${local.peers_expected_hex}" ]; then
          echo "Rede com ${var.node_count} peers após $((i * 15))s — peerCount: $PEERS"
          exit 0
        fi
        echo "Tentativa $i/60: peers=$PEERS (aguardando ${local.peers_expected_hex})..."
      done
      echo "Timeout aguardando ${var.node_count - 1} peers na rede Besu"
      exit 1
    EOT
  }
}

# 5. Deploy dos contratos inteligentes no Node-1 (após rede com peers confirmados)
resource "null_resource" "deploy_contracts" {
  depends_on = [null_resource.wait_network_ready]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = azurerm_public_ip.besu_node[0].ip_address
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/deploy_contracts.sh"
    destination = "/tmp/deploy_contracts.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/deploy_contracts.sh",
      "AZURE_STORAGE_ACCOUNT=${azurerm_storage_account.besu_data.name} AZURE_STORAGE_CONTAINER=${azurerm_storage_container.besu_data.name} AZURE_IDENTITY_CLIENT_ID=${azurerm_user_assigned_identity.besu_data.client_id} bash /tmp/deploy_contracts.sh",
    ]
  }
}

# ============================================================================
# Etapa 3 — Testes com Caliper em instância dedicada
# ============================================================================

# VM dedicada para o Caliper — mesma VNet, acessa Node-1 via IP privado.
# IP 10.0.1.30 fica fora do range dos nós (máximo Node-14 = 10.0.1.23).
resource "azurerm_public_ip" "caliper" {
  name                = "${var.project_name}-caliper-pip"
  resource_group_name = azurerm_resource_group.besu.name
  location            = azurerm_resource_group.besu.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.azure_availability_zone == null ? null : [var.azure_availability_zone]
}

resource "azurerm_network_interface" "caliper" {
  name                = "${var.project_name}-caliper-nic"
  resource_group_name = azurerm_resource_group.besu.name
  location            = azurerm_resource_group.besu.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.besu.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.30"
    public_ip_address_id          = azurerm_public_ip.caliper.id
  }
}

resource "azurerm_linux_virtual_machine" "caliper" {
  name                  = "${var.project_name}-caliper"
  resource_group_name   = azurerm_resource_group.besu.name
  location              = azurerm_resource_group.besu.location
  size                  = var.vm_size_caliper
  admin_username        = local.admin_username
  zone                  = var.azure_availability_zone
  network_interface_ids = [azurerm_network_interface.caliper.id]

  admin_ssh_key {
    username   = local.admin_username
    public_key = file(var.public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.besu_data.id]
  }

  custom_data = base64encode(templatefile("${path.module}/scripts/node_user_data.sh", {
    node_index = "caliper"
  }))

  tags = {
    Name    = "${var.project_name}-caliper"
    Project = var.project_name
    Role    = "caliper"
  }
}

# 6. Aguarda SSH + user_data na instância Caliper (em paralelo com o setup do Besu)
resource "null_resource" "wait_ssh_caliper" {
  depends_on = [azurerm_linux_virtual_machine.caliper]

  provisioner "local-exec" {
    command = <<-EOT
      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -i ${var.private_key_path}"
      HOST="${azurerm_public_ip.caliper.ip_address}"

      echo "Aguardando SSH na instância Caliper ($HOST)..."
      ssh_ok=0
      for i in $(seq 1 60); do
        if ssh $SSH_OPTS ubuntu@$HOST 'echo ok' 2>/dev/null; then
          echo "SSH Caliper ok após $((i * 10))s"
          ssh_ok=1
          break
        fi
        echo "Tentativa $i/60: aguardando SSH Caliper..."
        sleep 10
      done

      if [ "$ssh_ok" -eq 0 ]; then
        echo "ERRO: timeout aguardando SSH no Caliper"
        exit 1
      fi

      echo "Aguardando user_data concluir na instância Caliper..."
      for i in $(seq 1 60); do
        if ssh $SSH_OPTS ubuntu@$HOST 'test -f /home/ubuntu/.node-ready' 2>/dev/null; then
          echo "user_data Caliper concluído após $((i * 10))s"
          exit 0
        fi
        if ssh $SSH_OPTS ubuntu@$HOST 'grep -q "ERRO:" /var/log/besu-setup.log' 2>/dev/null; then
          echo "ERRO: user_data falhou no Caliper — veja /var/log/besu-setup.log"
          exit 1
        fi
        echo "Tentativa $i/60: user_data ainda em execução no Caliper..."
        sleep 10
      done
      echo "ERRO: timeout aguardando user_data no Caliper"
      exit 1
    EOT
  }
}

# 7. Executa os testes com Caliper após deploy dos contratos E instância Caliper pronta
resource "null_resource" "run_caliper_tests" {
  depends_on = [null_resource.deploy_contracts, null_resource.wait_ssh_caliper]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = azurerm_public_ip.caliper.ip_address
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/run_caliper_tests.sh"
    destination = "/tmp/run_caliper_tests.sh"
  }

  # Sempre presente na instância A, independente de SKIP_SWEEP — usado tanto pela
  # varredura automática (chamado por run_caliper_tests.sh) quanto, no modo
  # distribuído, pelo passo final do orquestrador local (run_distributed_sweep.py).
  provisioner "file" {
    source      = "${path.module}/scripts/extract_and_upload_results.sh"
    destination = "/tmp/extract_and_upload_results.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/run_caliper_tests.sh /tmp/extract_and_upload_results.sh",
      "NODE_COUNT=${var.node_count} AZURE_STORAGE_ACCOUNT=${azurerm_storage_account.besu_data.name} AZURE_STORAGE_CONTAINER=${azurerm_storage_container.besu_data.name} AZURE_IDENTITY_CLIENT_ID=${azurerm_user_assigned_identity.besu_data.client_id} NODE1_PRIVATE_IP=10.0.1.10 SKIP_SWEEP=${var.node_caliper_count > 1 ? "true" : "false"} bash /tmp/run_caliper_tests.sh",
    ]
  }
}

# ============================================================================
# Etapa 4 (opcional) — N instâncias extras do Caliper, modo distribuído (MQTT)
# ============================================================================
# Um único manager (instância A, já provisionada acima) coordena workers rodando
# tanto localmente quanto nas instâncias extras, conectados via broker MQTT —
# sincronização de round e relatório combinado nativos do Caliper, sem precisar de
# barreira feita à mão nem de somar relatórios separados. Desligado por padrão
# (node_caliper_count=1). Varredura completa orquestrada do laptop do operador via
# scripts/run_distributed_sweep.py, que também envia (via scp) e dá chmod +x no
# run_caliper_manager_distributed.sh e no remote_patch_yaml.py na instância A antes
# de rodar o primeiro round — não precisa de null_resource dedicado pra isso.

# VMs dedicadas às instâncias Caliper extras — só workers remotos, sem
# manager/Prometheus. IPs 10.0.1.31, 10.0.1.32, ..., logo após o 10.0.1.30 da A.
resource "azurerm_public_ip" "caliper_b" {
  count               = var.node_caliper_count > 1 ? var.node_caliper_count - 1 : 0
  name                = "${var.project_name}-caliper-b-${count.index + 1}-pip"
  resource_group_name = azurerm_resource_group.besu.name
  location            = azurerm_resource_group.besu.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.azure_availability_zone == null ? null : [var.azure_availability_zone]
}

resource "azurerm_network_interface" "caliper_b" {
  count               = var.node_caliper_count > 1 ? var.node_caliper_count - 1 : 0
  name                = "${var.project_name}-caliper-b-${count.index + 1}-nic"
  resource_group_name = azurerm_resource_group.besu.name
  location            = azurerm_resource_group.besu.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.besu.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.${31 + count.index}"
    public_ip_address_id          = azurerm_public_ip.caliper_b[count.index].id
  }
}

resource "azurerm_linux_virtual_machine" "caliper_b" {
  count                 = var.node_caliper_count > 1 ? var.node_caliper_count - 1 : 0
  name                  = "${var.project_name}-caliper-b-${count.index + 1}"
  resource_group_name   = azurerm_resource_group.besu.name
  location              = azurerm_resource_group.besu.location
  size                  = var.vm_size_caliper_b
  admin_username        = local.admin_username
  zone                  = var.azure_availability_zone
  network_interface_ids = [azurerm_network_interface.caliper_b[count.index].id]

  admin_ssh_key {
    username   = local.admin_username
    public_key = file(var.public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.besu_data.id]
  }

  custom_data = base64encode(templatefile("${path.module}/scripts/node_user_data.sh", {
    node_index = "caliper-b-${count.index + 1}"
  }))

  tags = {
    Name    = "${var.project_name}-caliper-b-${count.index + 1}"
    Project = var.project_name
    Role    = "caliper-b"
  }
}

# 8. Aguarda SSH + user_data em cada instância Caliper extra
resource "null_resource" "wait_ssh_caliper_b" {
  count      = var.node_caliper_count > 1 ? var.node_caliper_count - 1 : 0
  depends_on = [azurerm_linux_virtual_machine.caliper_b]

  provisioner "local-exec" {
    command = <<-EOT
      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -i ${var.private_key_path}"
      HOST="${azurerm_public_ip.caliper_b[count.index].ip_address}"

      echo "Aguardando SSH na instância Caliper B-${count.index + 1} ($HOST)..."
      ssh_ok=0
      for i in $(seq 1 60); do
        if ssh $SSH_OPTS ubuntu@$HOST 'echo ok' 2>/dev/null; then
          echo "SSH Caliper B-${count.index + 1} ok após $((i * 10))s"
          ssh_ok=1
          break
        fi
        echo "Tentativa $i/60: aguardando SSH Caliper B-${count.index + 1}..."
        sleep 10
      done

      if [ "$ssh_ok" -eq 0 ]; then
        echo "ERRO: timeout aguardando SSH no Caliper B-${count.index + 1}"
        exit 1
      fi

      echo "Aguardando user_data concluir na instância Caliper B-${count.index + 1}..."
      for i in $(seq 1 60); do
        if ssh $SSH_OPTS ubuntu@$HOST 'test -f /home/ubuntu/.node-ready' 2>/dev/null; then
          echo "user_data Caliper B-${count.index + 1} concluído após $((i * 10))s"
          exit 0
        fi
        if ssh $SSH_OPTS ubuntu@$HOST 'grep -q "ERRO:" /var/log/besu-setup.log' 2>/dev/null; then
          echo "ERRO: user_data falhou no Caliper B-${count.index + 1} — veja /var/log/besu-setup.log"
          exit 1
        fi
        echo "Tentativa $i/60: user_data ainda em execução no Caliper B-${count.index + 1}..."
        sleep 10
      done
      echo "ERRO: timeout aguardando user_data no Caliper B-${count.index + 1}"
      exit 1
    EOT
  }
}

# 9. Setup de cada instância Caliper extra — mesmo script da instância A
#     (run_caliper_tests.sh), com ROLE=worker: clona o repo, instala o Caliper CLI,
#     patcha o networkconfig.json (sempre mirando o Node-1) e deixa pronto o
#     launch_workers.sh (não dispara os workers automaticamente — isso é feito pelo
#     orquestrador local, run_distributed_sweep.py).
resource "null_resource" "setup_caliper_b" {
  count      = var.node_caliper_count > 1 ? var.node_caliper_count - 1 : 0
  depends_on = [null_resource.deploy_contracts, null_resource.wait_ssh_caliper_b]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = azurerm_public_ip.caliper_b[count.index].ip_address
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/run_caliper_tests.sh"
    destination = "/tmp/run_caliper_tests.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/run_caliper_tests.sh",
      "ROLE=worker AZURE_STORAGE_ACCOUNT=${azurerm_storage_account.besu_data.name} AZURE_STORAGE_CONTAINER=${azurerm_storage_container.besu_data.name} AZURE_IDENTITY_CLIENT_ID=${azurerm_user_assigned_identity.besu_data.client_id} NODE1_PRIVATE_IP=10.0.1.10 bash /tmp/run_caliper_tests.sh",
    ]
  }
}

# 10. Roda a varredura distribuída completa automaticamente, como último passo do
#     apply — do laptop do operador (local-exec), nunca de dentro de uma VM, então
#     a chave privada nunca é copiada pra lá. Bloqueia o "terraform apply" até
#     todos os rounds terminarem e os CSVs subirem pro Blob Storage (mesmo
#     comportamento que o caminho single-instance já tem hoje com run_test_local.py).
#     Os valores são passados direto por flag (não via "terraform output"), porque
#     rodar "terraform output" a partir de um local-exec do MESMO apply em
#     andamento travaria no lock do state que o processo pai já está segurando.
#     O próprio script envia (scp) e dá chmod +x no run_caliper_manager_distributed.sh
#     e no remote_patch_yaml.py na instância A antes do primeiro round.
resource "null_resource" "run_distributed_sweep" {
  count      = var.node_caliper_count > 1 ? 1 : 0
  depends_on = [null_resource.run_caliper_tests, null_resource.setup_caliper_b]

  provisioner "local-exec" {
    command = <<-EOT
      python3 ${path.module}/scripts/run_distributed_sweep.py \
        --instance-a-host ${azurerm_public_ip.caliper.ip_address} \
        --instance-a-private-ip ${azurerm_network_interface.caliper.ip_configuration[0].private_ip_address} \
        --extra-hosts ${join(" ", azurerm_public_ip.caliper_b[*].ip_address)} \
        --caliper-a-workers ${var.caliper_a_workers} \
        --caliper-b-workers ${var.caliper_b_workers} \
        --storage-account ${azurerm_storage_account.besu_data.name} \
        --storage-container ${azurerm_storage_container.besu_data.name} \
        --identity-client-id ${azurerm_user_assigned_identity.besu_data.client_id} \
        --rpc-url http://${azurerm_public_ip.besu_node[0].ip_address}:8545 \
        --private-key-path ${var.private_key_path}
    EOT
  }
}
