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

data "aws_ami" "ubuntu2204" {
  most_recent = true
  owners      = [var.ami_owner]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_security_group" "besu_sg" {
  name        = "besu-dev-sg"
  description = "Allow Besu RPC, WS, P2P and metrics traffic"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Besu HTTP RPC"
    from_port   = 8545
    to_port     = 8545
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Besu WS"
    from_port   = 8546
    to_port     = 8546
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Besu P2P"
    from_port   = 30303
    to_port     = 30303
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Besu metrics"
    from_port   = 9545
    to_port     = 9545
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "besu_node" {
  ami                    = data.aws_ami.ubuntu2204.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.besu_sg.id]
  key_name               = aws_key_pair.besu.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y docker.io
    systemctl enable docker
    systemctl start docker

    docker run -d -p 8545:8545 -p 8546:8546 -p 30303:30303 -p 9545:9545 \
      -v besu-data:/var/lib/besu \
      --name besu-dev \
      hyperledger/besu:latest \
      --network=dev \
      --rpc-http-enabled \
      --rpc-http-host=0.0.0.0 \
      --rpc-http-api=ETH,NET,WEB3,DEBUG,ADMIN \
      --rpc-ws-enabled \
      --rpc-ws-host=0.0.0.0 \
      --rpc-ws-port=8546 \
      --rpc-ws-api=ETH,NET,WEB3,DEBUG,ADMIN \
      --metrics-enabled \
      --metrics-host=0.0.0.0 \
      --metrics-port=9545 || true

    for i in $(seq 1 12); do
      if docker ps --filter "name=besu-dev" --filter "status=running" | grep -q besu-dev; then
        echo "$(date): Besu container started successfully" > /var/log/besu-startup.log
        exit 0
      fi
      sleep 5
    done

    echo "$(date): Besu container failed to start" > /var/log/besu-startup.log
    docker logs besu-dev > /var/log/besu-startup-error.log 2>&1 || true
  EOF

  tags = {
    Name = var.instance_name
  }
}
