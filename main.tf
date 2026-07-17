terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

# ============================================================================
# VPC dedicada com subnet pública e IPs privados fixos para os nós
# ============================================================================

resource "aws_vpc" "besu" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_subnet" "besu" {
  vpc_id                  = aws_vpc.besu.id
  cidr_block              = var.node_subnet_cidr
  availability_zone       = var.aws_az
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-subnet" }
}

resource "aws_internet_gateway" "besu" {
  vpc_id = aws_vpc.besu.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_route_table" "besu" {
  vpc_id = aws_vpc.besu.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.besu.id
  }
  tags = { Name = "${var.project_name}-rt" }
}

resource "aws_route_table_association" "besu" {
  subnet_id      = aws_subnet.besu.id
  route_table_id = aws_route_table.besu.id
}

# ============================================================================
# Security Group — mesmo SG para todos os nós; P2P liberado apenas entre eles
# ============================================================================

resource "aws_security_group" "besu_nodes" {
  name        = "${var.project_name}-nodes-sg"
  description = "Security group for distributed Besu nodes"
  vpc_id      = aws_vpc.besu.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # RPC HTTP: 8545 (bootnode.yaml) e 8546 (validator.yaml) — mesmas portas em todos os EC2
  ingress {
    description = "RPC HTTP"
    from_port   = 8545
    to_port     = 8546
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # WebSocket: 8645 (bootnode.yaml) e 8646 (validator.yaml)
  ingress {
    description = "WebSocket"
    from_port   = 8645
    to_port     = 8646
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # P2P apenas entre instâncias do mesmo SG (tráfego intra-nós via VPC).
  # Range 30303-30302+N cobre as portas de cada nó (Node-i usa porta 30302+i).
  ingress {
    description = "P2P TCP entre nos"
    from_port   = 30303
    to_port     = 30302 + var.node_count
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "P2P UDP entre nos"
    from_port   = 30303
    to_port     = 30302 + var.node_count
    protocol    = "udp"
    self        = true
  }

  ingress {
    description = "Prometheus metrics"
    from_port   = 9545
    to_port     = 9546
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-nodes-sg" }
}

# ============================================================================
# Key Pair SSH
# ============================================================================

resource "aws_key_pair" "besu" {
  key_name   = "${var.project_name}-key"
  public_key = file(var.public_key_path)
}

# ============================================================================
# S3 — bucket para distribuição de chaves entre os nós
# ============================================================================

resource "aws_s3_bucket" "besu_data" {
  bucket        = "${var.project_name}-data-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "${var.project_name}-data" }
}

resource "aws_s3_bucket_public_access_block" "besu_data" {
  bucket                  = aws_s3_bucket.besu_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================================
# IAM — instance profile para os nós acessarem o S3
# ============================================================================

resource "aws_iam_role" "besu_node" {
  name = "${var.project_name}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "besu_node_s3" {
  name = "${var.project_name}-node-s3-policy"
  role = aws_iam_role.besu_node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.besu_data.arn,
        "${aws_s3_bucket.besu_data.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "besu_node" {
  name = "${var.project_name}-node-profile"
  role = aws_iam_role.besu_node.name
}

# ============================================================================
# EC2 — var.node_count instâncias com IPs privados fixos
#   index 0 → Node-1 (bootnode)  → 10.0.1.10
#   index 1 → Node-2 (validator) → 10.0.1.11
#   index 2 → Node-3 (bootnode)  → 10.0.1.12
#   index 3 → Node-4 (validator) → 10.0.1.13
#   ...
#   index N-1 → Node-N (validator) → 10.0.1.(10+N-1)
# ============================================================================

locals {
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

resource "aws_instance" "besu_node" {
  count = var.node_count

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = count.index == 0 ? var.instance_type_node1 : var.instance_type_besu
  subnet_id                   = aws_subnet.besu.id
  vpc_security_group_ids      = [aws_security_group.besu_nodes.id]
  key_name                    = aws_key_pair.besu.key_name
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.besu_node.name
  private_ip                  = "10.0.1.${10 + count.index}"

  root_block_device {
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/scripts/node_user_data.sh", {
    node_index = count.index + 1
    aws_region = var.aws_region
  })

  tags = {
    Name      = "${var.project_name}-node-${count.index + 1}"
    Project   = var.project_name
    NodeIndex = tostring(count.index + 1)
    NodeRole  = local.node_roles[count.index]
  }
}

# EIP apenas no Node-1 — é o bootnode e o ponto de acesso externo
resource "aws_eip" "node1" {
  instance   = aws_instance.besu_node[0].id
  domain     = "vpc"
  depends_on = [aws_internet_gateway.besu]
}

# ============================================================================
# null_resource: cadeia de setup distribuído
# ============================================================================

# 1. Aguarda SSH disponível nos N nós antes de prosseguir
resource "null_resource" "wait_ssh_all_nodes" {
  depends_on = [aws_eip.node1, aws_instance.besu_node]

  provisioner "local-exec" {
    command = <<-EOT
      SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ${var.private_key_path}"

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

      wait_node "Node-1" "${aws_eip.node1.public_ip}"
      %{~ for i in range(1, var.node_count) ~}
      wait_node "Node-${i + 1}" "${aws_instance.besu_node[i].public_ip}"
      %{~ endfor ~}
    EOT
  }
}

# 2. Gera chaves no Node-1 e distribui para o S3
resource "null_resource" "generate_and_distribute_keys" {
  depends_on = [null_resource.wait_ssh_all_nodes]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = aws_eip.node1.public_ip
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/generate_and_distribute_keys.sh"
    destination = "/tmp/generate_and_distribute_keys.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/generate_and_distribute_keys.sh",
      "NODE_COUNT=${var.node_count} S3_KEYS_BUCKET=${aws_s3_bucket.besu_data.bucket} AWS_REGION=${var.aws_region} bash /tmp/generate_and_distribute_keys.sh",
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
    host        = aws_eip.node1.public_ip
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/start_besu_node.sh"
    destination = "/tmp/start_besu_node.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/start_besu_node.sh",
      "NODE_INDEX=1 S3_KEYS_BUCKET=${aws_s3_bucket.besu_data.bucket} AWS_REGION=${var.aws_region} bash /tmp/start_besu_node.sh",
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
    host        = aws_instance.besu_node[2].public_ip
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/start_besu_node.sh"
    destination = "/tmp/start_besu_node.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/start_besu_node.sh",
      "NODE_INDEX=3 S3_KEYS_BUCKET=${aws_s3_bucket.besu_data.bucket} AWS_REGION=${var.aws_region} bash /tmp/start_besu_node.sh",
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
    host        = aws_instance.besu_node[local.validator_indices[count.index]].public_ip
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/start_besu_node.sh"
    destination = "/tmp/start_besu_node.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/start_besu_node.sh",
      "NODE_INDEX=${local.validator_indices[count.index] + 1} S3_KEYS_BUCKET=${aws_s3_bucket.besu_data.bucket} AWS_REGION=${var.aws_region} bash /tmp/start_besu_node.sh",
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
          http://${aws_eip.node1.public_ip}:8545 2>/dev/null || true)
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
    host        = aws_eip.node1.public_ip
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/deploy_contracts.sh"
    destination = "/tmp/deploy_contracts.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/deploy_contracts.sh",
      "S3_KEYS_BUCKET=${aws_s3_bucket.besu_data.bucket} AWS_REGION=${var.aws_region} bash /tmp/deploy_contracts.sh",
    ]
  }
}

# ============================================================================
# Etapa 3 — Testes com Caliper em instância dedicada
# ============================================================================

# IAM role dedicada para a instância Caliper
# Leitura e escrita no mesmo bucket besu-keys — prefixo caliper-results/ para os CSVs
resource "aws_iam_role" "caliper" {
  name = "${var.project_name}-caliper-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "caliper_s3" {
  name = "${var.project_name}-caliper-s3-policy"
  role = aws_iam_role.caliper.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.besu_data.arn,
        "${aws_s3_bucket.besu_data.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "caliper" {
  name = "${var.project_name}-caliper-profile"
  role = aws_iam_role.caliper.name
}

# EC2 dedicada para o Caliper — mesma VPC, acessa Node-1 via IP privado
# IP 10.0.1.30 fica fora do range dos nós (máximo Node-14 = 10.0.1.23)
resource "aws_instance" "caliper" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type_caliper
  subnet_id                   = aws_subnet.besu.id
  vpc_security_group_ids      = [aws_security_group.besu_nodes.id]
  key_name                    = aws_key_pair.besu.key_name
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.caliper.name
  private_ip                  = "10.0.1.30"

  root_block_device {
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/scripts/node_user_data.sh", {
    node_index = "caliper"
    aws_region = var.aws_region
  })

  tags = {
    Name    = "${var.project_name}-caliper"
    Project = var.project_name
    Role    = "caliper"
  }
}

# 6. Aguarda SSH + user_data na instância Caliper (em paralelo com o setup do Besu)
resource "null_resource" "wait_ssh_caliper" {
  depends_on = [aws_instance.caliper]

  provisioner "local-exec" {
    command = <<-EOT
      SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ${var.private_key_path}"
      HOST="${aws_instance.caliper.public_ip}"

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
    host        = aws_instance.caliper.public_ip
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/run_caliper_tests.sh"
    destination = "/tmp/run_caliper_tests.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/run_caliper_tests.sh",
      "NODE_COUNT=${var.node_count} S3_KEYS_BUCKET=${aws_s3_bucket.besu_data.bucket} AWS_REGION=${var.aws_region} NODE1_PRIVATE_IP=10.0.1.10 bash /tmp/run_caliper_tests.sh",
    ]
  }
}
