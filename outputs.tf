output "public_ip" {
  description = "Endereço IP público atribuído à instância EC2."
  value       = aws_eip.besu_ec2.public_ip
}

output "ssh_command" {
  description = "Comando SSH sugerido para acessar a instância."
  value       = "ssh -i ~/.ssh/besu-key ubuntu@${aws_eip.besu_ec2.public_ip}"
}

output "log_command" {
  description = "Comando sugerido para acompanhar o log de instalação."
  value       = "ssh -i ~/.ssh/besu-key ubuntu@${aws_eip.besu_ec2.public_ip} 'tail -f /var/log/besu-setup.log'"
}

output "rpc_url" {
  description = "URL RPC pública para validação da rede Besu."
  value       = "http://${aws_eip.besu_ec2.public_ip}:8545"
}
