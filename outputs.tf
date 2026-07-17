output "node1_public_ip" {
  description = "IP público do Node-1 (bootnode) — EIP fixo."
  value       = aws_eip.node1.public_ip
}

output "node_public_ips" {
  description = "IPs públicos de todos os nós (índice 0 = Node-1 com EIP, demais auto-atribuídos)."
  value = concat(
    [aws_eip.node1.public_ip],
    [for i in range(1, var.node_count) : aws_instance.besu_node[i].public_ip]
  )
}

output "node_private_ips" {
  description = "IPs privados de todos os nós dentro da VPC."
  value       = aws_instance.besu_node[*].private_ip
}

output "ssh_commands" {
  description = "Comandos SSH para acessar cada nó."
  value = concat(
    ["ssh -i ${var.private_key_path} ubuntu@${aws_eip.node1.public_ip}  # Node-1 bootnode (${aws_instance.besu_node[0].private_ip})"],
    [for i in range(1, var.node_count) :
      "ssh -i ${var.private_key_path} ubuntu@${aws_instance.besu_node[i].public_ip}  # Node-${i + 1} ${i == 2 ? "bootnode" : "validator"} (${aws_instance.besu_node[i].private_ip})"
    ]
  )
}

output "rpc_url" {
  description = "URL RPC do Node-1 para validação da rede."
  value       = "http://${aws_eip.node1.public_ip}:8545"
}

output "log_commands" {
  description = "Comandos para acompanhar os logs de setup em cada nó."
  value = concat(
    ["ssh -i ${var.private_key_path} ubuntu@${aws_eip.node1.public_ip} 'tail -f /home/ubuntu/besu-setup.log'  # Node-1"],
    [for i in range(1, var.node_count) :
      "ssh -i ${var.private_key_path} ubuntu@${aws_instance.besu_node[i].public_ip} 'tail -f /home/ubuntu/besu-setup.log'  # Node-${i + 1}"
    ]
  )
}

output "s3_data_bucket" {
  description = "Bucket S3 compartilhado: chaves, artefatos de deploy e resultados Caliper."
  value       = aws_s3_bucket.besu_data.bucket
}

output "deploy_artifacts_commands" {
  description = "Comandos para verificar os artefatos do deploy no Node-1 e no S3."
  value       = <<-EOT
    # Verificar network-info.json (chainId, rpcUrl):
    ssh -i ${var.private_key_path} ubuntu@${aws_eip.node1.public_ip} 'cat /home/ubuntu/deploy-artifacts/network-info.json'

    # Verificar endereços dos contratos (journal Ignition):
    ssh -i ${var.private_key_path} ubuntu@${aws_eip.node1.public_ip} 'ls /home/ubuntu/deploy-artifacts/deployments/'

    # Verificar artefatos no S3:
    aws s3 ls s3://${aws_s3_bucket.besu_data.bucket}/artifacts/ --recursive
  EOT
}

output "validation_commands" {
  description = "Comandos para validar a rede após o apply."
  value       = <<-EOT
    # Verificar blockNumber no Node-1:
    curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://${aws_eip.node1.public_ip}:8545

    # Verificar peers conectados (deve retornar ${format("0x%x", var.node_count - 1)} com ${var.node_count} nós):
    curl -s -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' http://${aws_eip.node1.public_ip}:8545
  EOT
}

output "caliper_public_ip" {
  description = "IP público da instância Caliper (muda a cada apply)."
  value       = aws_instance.caliper.public_ip
}

output "caliper_ssh_command" {
  description = "Comando SSH para acessar a instância Caliper."
  value       = "ssh -i ${var.private_key_path} ubuntu@${aws_instance.caliper.public_ip}  # Caliper"
}

output "caliper_log_command" {
  description = "Comando para acompanhar o log de execução do Caliper."
  value       = "ssh -i ${var.private_key_path} ubuntu@${aws_instance.caliper.public_ip} 'tail -f /home/ubuntu/besu-setup.log'"
}

output "caliper_results_commands" {
  description = "Comandos para verificar os resultados dos testes Caliper no S3 (prefixo caliper-results/)."
  value       = <<-EOT
    # Listar todas as execuções:
    aws s3 ls s3://${aws_s3_bucket.besu_data.bucket}/caliper-results/ --recursive

    # Baixar todos os CSVs de uma execução (substituir <timestamp>):
    aws s3 cp s3://${aws_s3_bucket.besu_data.bucket}/caliper-results/<timestamp>/ ./caliper-results/ --recursive
  EOT
}
