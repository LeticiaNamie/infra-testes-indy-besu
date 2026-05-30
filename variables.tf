variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Região AWS onde os recursos serão provisionados."
}

variable "instance_type" {
  type        = string
  default     = "m6i.2xlarge"
  description = "Tipo da instância EC2."
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "CIDR autorizado para SSH, por exemplo 203.0.113.0/32."
}

variable "public_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa.pub"
  description = "Caminho local para a chave pública SSH usada pelo EC2 key pair."
}

variable "project_name" {
  type        = string
  default     = "besu-etapa1"
  description = "Prefixo de nomes dos recursos AWS e do projeto."
}

variable "private_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa"
  description = "Caminho local para a chave privada SSH usada para acessar a instância EC2."
}

variable "caliper_results_bucket" {
  type        = string
  default     = "tests-with-caliper-results"
  description = "Nome do bucket S3 onde os CSVs de resultados do Caliper serão armazenados."
}
