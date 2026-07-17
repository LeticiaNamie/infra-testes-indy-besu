variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Região AWS onde os recursos serão provisionados."
}

variable "aws_az" {
  type        = string
  default     = "us-east-1a"
  description = "Availability Zone onde todas as instâncias serão criadas (tráfego intra-AZ via IP privado é gratuito)."
}

variable "instance_type_node1" {
  type        = string
  default     = "c6i.2xlarge"
  description = "Tipo da instância EC2 para o Node-1 (bootnode primário + endpoint RPC do Caliper)."
}

variable "instance_type_besu" {
  type        = string
  default     = "c6i.xlarge"
  description = "Tipo da instância EC2 para os nós Besu 2-6 (validators e bootnode secundário)."
}

variable "instance_type_caliper" {
  type        = string
  default     = "c6i.xlarge"
  description = "Tipo da instância EC2 para o Caliper (1 worker, I/O bound)."
}

variable "node_subnet_cidr" {
  type        = string
  default     = "10.0.1.0/24"
  description = "CIDR da subnet dos nós Besu."
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "CIDR autorizado para SSH (ex: 203.0.113.0/32)."
}

variable "public_key_path" {
  type        = string
  default     = "~/.ssh/besu-key.pub"
  description = "Caminho local para a chave pública SSH usada pelo EC2 key pair."
}

variable "private_key_path" {
  type        = string
  default     = "~/.ssh/besu-key"
  description = "Caminho local para a chave privada SSH usada para acesso via remote-exec."
}

variable "project_name" {
  type        = string
  default     = "besu-distributed"
  description = "Prefixo de nomes dos recursos AWS."
}

variable "node_count" {
  type        = number
  default     = 6
  description = "Número total de nós Besu na rede (todos são validadores; Node-1 e Node-3 também exercem papel de bootnode). Mínimo QBFT: 4."

  validation {
    condition     = var.node_count >= 4 && var.node_count <= 14
    error_message = "node_count deve estar entre 4 e 14 (QBFT requer mínimo 4 validadores)."
  }
}
