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

# ============================================================================
# Etapa 3: S3
# ============================================================================

output "s3_bucket_name" {
  description = "Nome do bucket S3 criado para os resultados do Caliper."
  value       = aws_s3_bucket.caliper_results.bucket
}

output "s3_check_command" {
  description = "Comando para verificar se os arquivos foram enviados ao S3."
  value       = "aws s3 ls s3://${aws_s3_bucket.caliper_results.bucket}/ --recursive"
}

# ============================================================================
# Etapa 2: Deploy dos Contratos
# ============================================================================

output "check_network_info_command" {
  description = "Comando para verificar as informações da rede (chainId, RPC URL, etc.) após o deploy dos contratos."
  value       = "ssh -i ~/.ssh/besu-key ubuntu@${aws_eip.besu_ec2.public_ip} 'cat /home/ubuntu/deploy-artifacts/network-info.json'"
}

output "check_deploy_artifacts_command" {
  description = "Comando para listar os artefatos do deploy (journals, ABIs, etc.)."
  value       = "ssh -i ~/.ssh/besu-key ubuntu@${aws_eip.besu_ec2.public_ip} 'ls -lah /home/ubuntu/deploy-artifacts/'"
}

output "deploy_completion_message" {
  description = "Mensagem de conclusão da Etapa 2 com instruções pós-deploy."
  value       = <<-EOT
    ==== Etapa 2: Deploy dos Contratos — Próximos Passos ====
    
    Para verificar se o deploy foi bem-sucedido:
    
    1. Consulte as informações da rede e chainId:
       ssh -i ~/.ssh/besu-key ubuntu@${aws_eip.besu_ec2.public_ip} 'cat /home/ubuntu/deploy-artifacts/network-info.json'
    
    2. Liste os artefatos de deploy:
       ssh -i ~/.ssh/besu-key ubuntu@${aws_eip.besu_ec2.public_ip} 'ls -lah /home/ubuntu/deploy-artifacts/'
    
    3. Verifique o log completo da Etapa 2:
       ssh -i ~/.ssh/besu-key ubuntu@${aws_eip.besu_ec2.public_ip} 'tail -100 /var/log/besu-setup.log'
    
    4. Os contratos foram implantados e seus endereços estão registrados em:
       /home/ubuntu/deploy-artifacts/deployments/
    
    5. Os ABIs compilados estão em:
       /home/ubuntu/contracts-indy-besu/artifacts/
  EOT
}
