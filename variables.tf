variable "azure_location" {
  type        = string
  default     = "eastus"
  description = "Região Azure onde os recursos serão provisionados. Default conservador (ampla disponibilidade de SKUs Fsv2/Dsv5). Antes do primeiro apply, rodar 'az vm list-skus --location <região> --size Standard_F --size Standard_D --all' — se brazilsouth (mais realista em latência para um benchmark operado do Brasil) tiver os SKUs e quota necessários, trocar para lá."
}

variable "azure_availability_zone" {
  type        = string
  default     = "1"
  description = "Availability Zone fixa (compartilhada por TODOS os recursos zonais — nós Besu, Caliper A e B) para manter todo o cluster junto e evitar a cobrança de tráfego entre zonas + variação de latência entre nós (mesmo raciocínio do var.aws_az original, só que lá era garantido de graça pela subnet ser zonal na AWS). Checado via 'az vm list-skus': Dsv7 (Caliper) está disponível sem restrição nas 3 zonas de eastus; Falsv6 (nós Besu) está bloqueado nas 3 zonas igualmente por 'alta demanda' pra essa subscription — a zona escolhida aqui não resolve isso, só o pedido de acesso aprovado resolve. Zona 1 é arbitrária enquanto isso."
}

# --- Tamanhos de VM Azure (paridade de vCPU:RAM com a linha de base usada nos
#     testes originais em AWS — c6i.2xlarge/c6i.xlarge/m6i.4xlarge — pra manter
#     o benchmark comparável) ---

variable "vm_size_node1" {
  type        = string
  default     = "Standard_F8als_v6"
  description = "SKU Azure para o Node-1 (bootnode primário + endpoint RPC do Caliper). 8 vCPU / 16GB, equivalente ao c6i.2xlarge. Fsv2 (Standard_F8s_v2) está com crescimento de capacidade restrito pela Microsoft desde jul/2026 (migração de hardware) — novos pedidos de cota não são aprovados. Falsv7 (geração seguinte, mesmo ratio 2GB/vCPU) não aparece no catálogo do East US ainda (confirmado via 'az vm list-skus' — nem restrição, ausência total), então ficamos no Falsv6 mesmo, que está 'em alta demanda' mas pelo menos existe na região (cota sendo solicitada). Fasv6/Fasv7/Famsv6/Famsv7 (sucessores mais divulgados) têm 4-8GB/vCPU e quebrariam a paridade. Única diferença real do Falsv6 pro Fsv2: sem Hyper-Threading (vCPU = núcleo físico inteiro), então cada vCPU é um pouco mais forte que no Fsv2 original."
}

variable "vm_size_besu" {
  type        = string
  default     = "Standard_F4als_v6"
  description = "SKU Azure para os nós Besu 2..N (validators e bootnode secundário). 4 vCPU / 8GB, equivalente ao c6i.xlarge. Ver nota de vm_size_node1 sobre a migração de Fsv2 para Falsv6."
}

variable "vm_size_caliper" {
  type        = string
  default     = "Standard_D16s_v7"
  description = "SKU Azure para o Caliper A (manager). 16 vCPU / 64GB, equivalente ao m6i.4xlarge — não usar a família Esv5 (16 vCPU / 128GB), que dobraria a RAM em relação à linha de base e quebraria a comparabilidade do benchmark. Dsv5 (Standard_D16s_v5) está com 'alta demanda' em East US bloqueando novos pedidos de cota; Dsv7 é o sucessor Intel direto com o MESMO ratio 4GB/vCPU (lançado ago/2026, então ainda com pouca adoção e provavelmente cota mais fácil de conseguir)."
}

variable "vm_size_caliper_b" {
  type        = string
  default     = "Standard_D16s_v7"
  description = "SKU Azure para as instâncias Caliper B extras (só workers remotos, sem manager/Prometheus). Mesmo raciocínio de vm_size_caliper."
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
  description = "Caminho local para a chave pública SSH usada pelas VMs (admin_ssh_key)."
}

variable "private_key_path" {
  type        = string
  default     = "~/.ssh/besu-key"
  description = "Caminho local para a chave privada SSH usada para acesso via remote-exec."
}

variable "project_name" {
  type        = string
  default     = "besu-distributed"
  description = "Prefixo de nomes dos recursos Azure."
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

variable "node_caliper_count" {
  type        = number
  default     = 1
  description = "Número total de instâncias do Caliper (mesmo padrão de node_count pros nós Besu). 1 (padrão) = só a instância A, rodando a varredura automática de sempre (run_test_local.py), sem MQTT — comportamento inalterado. >1 = instância A vira manager (SKIP_SWEEP=true, varredura automática desligada) + (node_caliper_count - 1) instâncias extras rodando só workers remotos via MQTT, orquestradas do laptop do operador por scripts/run_distributed_sweep.py (não pelo terraform apply)."

  validation {
    condition     = var.node_caliper_count >= 1
    error_message = "node_caliper_count deve ser >= 1."
  }
}

variable "caliper_a_workers" {
  type        = number
  default     = 10
  description = "Quantidade de workers locais lançados na instância A (manager). Some com caliper_b_workers para o total do workers.number no YAML do round distribuído."
}

variable "caliper_b_workers" {
  type        = number
  default     = 10
  description = "Quantidade de workers remotos lançados em CADA instância extra, conectados via MQTT ao manager da instância A. Ignorado se node_caliper_count <= 1."
}
