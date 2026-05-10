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

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}


resource "aws_security_group" "besu" {
  name        = "${var.project_name}-sg"
  description = "Security group for Besu QBFT single-instance network"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH access from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "Besu RPC HTTP"
    from_port   = 8545
    to_port     = 8545
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Besu WebSocket"
    from_port   = 8546
    to_port     = 8546
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Besu P2P TCP"
    from_port   = 30303
    to_port     = 30303
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Besu P2P UDP"
    from_port   = 30303
    to_port     = 30303
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
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

  tags = {
    Name        = "${var.project_name}-sg"
    Environment = "production"
    Project     = var.project_name
  }
}

resource "aws_key_pair" "besu" {
  key_name   = "besu-key"
  public_key = file("~/.ssh/besu-key.pub")
}

resource "aws_instance" "besu" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.besu.id]
  key_name                    = aws_key_pair.besu.key_name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/scripts/user_data.sh", {
    project_name = var.project_name
    aws_region   = var.aws_region
  })

  tags = {
    Name        = "${var.project_name}-instance"
    Environment = "production"
    Project     = var.project_name
  }
}

resource "aws_eip" "besu_ec2" {
  instance = aws_instance.besu.id
  domain   = "vpc"
}

# ============================================================================
# ETAPA 2: Deploy dos Contratos Inteligentes
# ============================================================================

resource "null_resource" "wait_besu_ready" {
  depends_on = [aws_eip.besu_ec2]

  provisioner "local-exec" {
    command = <<-EOT
      echo 'Aguardando porta SSH (22) abrir...'
      for i in $(seq 1 18); do
        if nc -z -w5 ${aws_eip.besu_ec2.public_ip} 22 2>/dev/null; then
          echo "Porta 22 aberta apos $((i * 10))s, aguardando SSH estabilizar..."
          sleep 15
          break
        fi
        echo "Tentativa $i/18: SSH ainda nao disponivel..."
        sleep 10
      done

      echo 'Confirmando SSH aceitando conexoes...'
      for i in $(seq 1 12); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
          -i ${var.private_key_path} ubuntu@${aws_eip.besu_ec2.public_ip} 'echo ok' 2>/dev/null; then
          echo "SSH confirmado apos $((i * 5))s"
          break
        fi
        sleep 5
      done

      echo 'Aguardando Besu responder na porta 8545...'
      for i in $(seq 1 32); do
        sleep 15
        BLOCK=$(curl -s --max-time 5 -X POST \
          --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
          http://${aws_eip.besu_ec2.public_ip}:8545 2>/dev/null | grep -o '"result":"0x[^"]*"' || true)
        if [ -n "$BLOCK" ]; then
          echo "Rede Besu respondendo apos $((i * 15))s: $BLOCK"
          exit 0
        fi
        echo "Tentativa $i/32: Besu ainda nao responde..."
      done
      echo 'Timeout aguardando Besu'
      exit 1
    EOT
  }
}

resource "null_resource" "deploy_contracts" {
  depends_on = [null_resource.wait_besu_ready]

  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -i ${var.private_key_path} ${path.module}/scripts/deploy_contracts.sh ubuntu@${aws_eip.besu_ec2.public_ip}:/tmp/deploy_contracts.sh"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    host        = aws_eip.besu_ec2.public_ip
    agent       = false
  }

  provisioner "remote-exec" {
  inline = [
    "chmod +x /tmp/deploy_contracts.sh",
    "bash /tmp/deploy_contracts.sh"
  ]
}
}
