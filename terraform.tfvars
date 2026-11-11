# TROQUE pelo SEU IP público no formato CIDR (ex.: curl -s ifconfig.me -> "203.0.113.7/32").
# Este valor libera o SSH (porta 22) nas VMs; não deixe o IP de outra pessoa nem "0.0.0.0/0".
allowed_ssh_cidr = "SEU_IP_PUBLICO/32"
private_key_path = "~/.ssh/besu-key"
public_key_path  = "~/.ssh/besu-key.pub"
azure_location   = "westus3"
azure_availability_zone = "1"
vm_size_node1    = "Standard_F8als_v6"
vm_size_besu     = "Standard_F4als_v6"
vm_size_caliper  = "Standard_D16s_v7"
project_name     = "besu-distributed"
node_caliper_count = 2
