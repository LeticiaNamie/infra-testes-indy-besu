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

variable "instance_type" {
  type        = string
  default     = "t3.medium"
  description = "Tipo da instância EC2 para os nós Besu."
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
