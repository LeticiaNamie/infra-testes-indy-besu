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
# Security Group — mesmo SG para os 2 nós; P2P liberado apenas entre eles
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

  # RPC HTTP: 8545 (Node-1), 8546 (Node-2)
  ingress {
    description = "RPC HTTP"
    from_port   = 8545
    to_port     = 8546
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # WebSocket: 8645 (Node-1), 8646 (Node-2)
  ingress {
    description = "WebSocket"
    from_port   = 8645
    to_port     = 8646
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # P2P apenas entre instâncias do mesmo SG (tráfego intra-nós via VPC).
  # Range 30303-30308 cobre as portas que o repositório atribui a cada nó
  # (Node-1=30303, Node-2=30304, ..., Node-6=30308).
  ingress {
    description = "P2P TCP entre nos"
    from_port   = 30303
    to_port     = 30308
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "P2P UDP entre nos"
    from_port   = 30303
    to_port     = 30308
    protocol    = "udp"
    self        = true
  }

  ingress {
    description = "Prometheus metrics"
    from_port   = 9545
    to_port     = 9545
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

resource "aws_s3_bucket" "besu_keys" {
  bucket        = "${var.project_name}-keys-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "${var.project_name}-keys" }
}

resource "aws_s3_bucket_public_access_block" "besu_keys" {
  bucket                  = aws_s3_bucket.besu_keys.id
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
        aws_s3_bucket.besu_keys.arn,
        "${aws_s3_bucket.besu_keys.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "besu_node" {
  name = "${var.project_name}-node-profile"
  role = aws_iam_role.besu_node.name
}

# ============================================================================
# EC2 — 2 instâncias com IPs privados fixos
#   index 0 → Node-1 (bootnode)  → 10.0.1.10
#   index 1 → Node-2 (validator) → 10.0.1.11
# ============================================================================

resource "aws_instance" "besu_node" {
  count = 2

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.besu.id
  vpc_security_group_ids      = [aws_security_group.besu_nodes.id]
  key_name                    = aws_key_pair.besu.key_name
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.besu_node.name
  private_ip                  = "10.0.1.${10 + count.index}"

  user_data = templatefile("${path.module}/scripts/node_user_data.sh", {
    node_index = count.index + 1
    aws_region = var.aws_region
  })

  tags = {
    Name      = "${var.project_name}-node-${count.index + 1}"
    Project   = var.project_name
    NodeIndex = tostring(count.index + 1)
    NodeRole  = count.index == 0 ? "bootnode" : "validator"
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

# 1. Aguarda SSH disponível nos 2 nós antes de prosseguir
resource "null_resource" "wait_ssh_all_nodes" {
  depends_on = [aws_eip.node1, aws_instance.besu_node]

  provisioner "local-exec" {
    command = <<-EOT
      SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ${var.private_key_path}"

      wait_node() {
        local label=$1 host=$2
        echo "Aguardando SSH no $label ($host)..."
        for i in $(seq 1 36); do
          if ssh $SSH_OPTS ubuntu@$host 'echo ok' 2>/dev/null; then
            echo "SSH $label ok após $((i * 10))s"
            break
          fi
          echo "Tentativa $i/36: aguardando SSH $label..."
          sleep 10
        done

        echo "Aguardando user_data concluir no $label (arquivo .node-ready)..."
        for i in $(seq 1 36); do
          if ssh $SSH_OPTS ubuntu@$host 'test -f /home/ubuntu/.node-ready' 2>/dev/null; then
            echo "user_data $label concluído após $((i * 10))s"
            return 0
          fi
          echo "Tentativa $i/36: user_data ainda em execução no $label..."
          sleep 10
        done
        echo "ERRO: timeout aguardando user_data no $label"
        exit 1
      }

      wait_node "Node-1" "${aws_eip.node1.public_ip}"
      wait_node "Node-2" "${aws_instance.besu_node[1].public_ip}"
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
      "S3_KEYS_BUCKET=${aws_s3_bucket.besu_keys.bucket} AWS_REGION=${var.aws_region} bash /tmp/generate_and_distribute_keys.sh",
    ]
  }
}

# 3a. Inicia Node-1 (bootnode) — usa o repo já clonado no passo anterior
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
      "NODE_INDEX=1 S3_KEYS_BUCKET=${aws_s3_bucket.besu_keys.bucket} AWS_REGION=${var.aws_region} bash /tmp/start_besu_node.sh",
    ]
  }
}

# 3b. Inicia Node-2 (validator) — clona repo e baixa chaves do S3
resource "null_resource" "start_node2" {
  depends_on = [null_resource.generate_and_distribute_keys]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = aws_instance.besu_node[1].public_ip
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/start_besu_node.sh"
    destination = "/tmp/start_besu_node.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/start_besu_node.sh",
      "NODE_INDEX=2 S3_KEYS_BUCKET=${aws_s3_bucket.besu_keys.bucket} AWS_REGION=${var.aws_region} bash /tmp/start_besu_node.sh",
    ]
  }
}

# 4. Aguarda a rede Besu estar operacional (polling RPC no Node-1)
resource "null_resource" "wait_network_ready" {
  depends_on = [null_resource.start_node1, null_resource.start_node2]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Aguardando Besu responder na porta 8545 do Node-1..."
      for i in $(seq 1 40); do
        sleep 15
        RESULT=$(curl -s --max-time 5 -X POST \
          --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
          http://${aws_eip.node1.public_ip}:8545 2>/dev/null || true)
        PEERS=$(echo "$RESULT" | grep -o '"result":"0x[^"]*"' | grep -o '0x[0-9a-f]*' || true)
        if [ -n "$PEERS" ]; then
          echo "Rede respondendo após $((i * 15))s — peers: $PEERS"
          exit 0
        fi
        echo "Tentativa $i/40: Besu ainda não responde..."
      done
      echo "Timeout aguardando a rede Besu"
      exit 1
    EOT
  }
}
