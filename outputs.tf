output "node1_public_ip" {
  description = "IP público do Node-1 (bootnode) — EIP fixo."
  value       = aws_eip.node1.public_ip
}

output "node2_public_ip" {
  description = "IP público do Node-2 (validator) — auto-atribuído, muda a cada apply."
  value       = aws_instance.besu_node[1].public_ip
}

output "node_private_ips" {
  description = "IPs privados dos 2 nós dentro da VPC."
  value       = aws_instance.besu_node[*].private_ip
}

output "ssh_commands" {
  description = "Comandos SSH para acessar cada nó."
  value = [
    "ssh -i ${var.private_key_path} ubuntu@${aws_eip.node1.public_ip}  # Node-1 bootnode (${aws_instance.besu_node[0].private_ip})",
    "ssh -i ${var.private_key_path} ubuntu@${aws_instance.besu_node[1].public_ip}  # Node-2 validator (${aws_instance.besu_node[1].private_ip})",
  ]
}

output "rpc_url" {
  description = "URL RPC do Node-1 para validação da rede."
  value       = "http://${aws_eip.node1.public_ip}:8545"
}

output "log_commands" {
  description = "Comandos para acompanhar os logs de setup em cada nó."
  value = [
    "ssh -i ${var.private_key_path} ubuntu@${aws_eip.node1.public_ip} 'tail -f /home/ubuntu/besu-setup.log'  # Node-1",
    "ssh -i ${var.private_key_path} ubuntu@${aws_instance.besu_node[1].public_ip} 'tail -f /home/ubuntu/besu-setup.log'  # Node-2",
  ]
}

output "s3_keys_bucket" {
  description = "Bucket S3 usado para distribuição de chaves entre os nós."
  value       = aws_s3_bucket.besu_keys.bucket
}

output "validation_commands" {
  description = "Comandos para validar a rede após o apply."
  value       = <<-EOT
    # Verificar blockNumber no Node-1:
    curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://${aws_eip.node1.public_ip}:8545

    # Verificar peers conectados (deve retornar 0x1 com 2 nós):
    curl -s -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' http://${aws_eip.node1.public_ip}:8545
  EOT
}
