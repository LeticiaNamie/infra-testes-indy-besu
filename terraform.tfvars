# TROQUE pelo SEU IP público no formato CIDR (ex.: curl -s ifconfig.me -> "203.0.113.7/32").
# Este valor libera o SSH (porta 22) nas VMs; não deixe o IP de outra pessoa nem "0.0.0.0/0".
allowed_ssh_cidr = "SEU_IP_PUBLICO/32"
private_key_path = "~/.ssh/besu-key"
public_key_path  = "~/.ssh/besu-key.pub"
instance_type_node1   = "c6i.2xlarge"
instance_type_besu    = "c6i.xlarge"
instance_type_caliper = "c6i.xlarge"
project_name     = "besu-distributed"
