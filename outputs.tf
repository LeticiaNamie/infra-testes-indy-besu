output "node1_public_ip" {
  description = "IP público do Node-1 (bootnode) — IP público Standard/Static."
  value       = azurerm_public_ip.besu_node[0].ip_address
}

output "node_public_ips" {
  description = "IPs públicos de todos os nós."
  value       = azurerm_public_ip.besu_node[*].ip_address
}

output "node_private_ips" {
  description = "IPs privados de todos os nós dentro da VNet."
  value       = azurerm_network_interface.besu_node[*].ip_configuration[0].private_ip_address
}

output "ssh_commands" {
  description = "Comandos SSH para acessar cada nó."
  value = [
    for i in range(var.node_count) :
    "ssh -i ${var.private_key_path} ubuntu@${azurerm_public_ip.besu_node[i].ip_address}  # Node-${i + 1} ${i == 0 || i == 2 ? "bootnode" : "validator"} (${azurerm_network_interface.besu_node[i].ip_configuration[0].private_ip_address})"
  ]
}

output "rpc_url" {
  description = "URL RPC do Node-1 para validação da rede."
  value       = "http://${azurerm_public_ip.besu_node[0].ip_address}:8545"
}

output "log_commands" {
  description = "Comandos para acompanhar os logs de setup em cada nó."
  value = [
    for i in range(var.node_count) :
    "ssh -i ${var.private_key_path} ubuntu@${azurerm_public_ip.besu_node[i].ip_address} 'tail -f /home/ubuntu/besu-setup.log'  # Node-${i + 1}"
  ]
}

output "storage_account_name" {
  description = "Storage account compartilhada: chaves, artefatos de deploy e resultados Caliper."
  value       = azurerm_storage_account.besu_data.name
}

output "storage_container_name" {
  description = "Container dentro da storage account onde tudo é gravado."
  value       = azurerm_storage_container.besu_data.name
}

output "azure_identity_client_id" {
  description = "Client ID da identidade gerenciada compartilhada — usado pelos scripts para 'azcopy login --identity'."
  value       = azurerm_user_assigned_identity.besu_data.client_id
}

output "deploy_artifacts_commands" {
  description = "Comandos para verificar os artefatos do deploy no Node-1 e no Blob Storage."
  value       = <<-EOT
    # Verificar network-info.json (chainId, rpcUrl):
    ssh -i ${var.private_key_path} ubuntu@${azurerm_public_ip.besu_node[0].ip_address} 'cat /home/ubuntu/deploy-artifacts/network-info.json'

    # Verificar endereços dos contratos (journal Ignition):
    ssh -i ${var.private_key_path} ubuntu@${azurerm_public_ip.besu_node[0].ip_address} 'ls /home/ubuntu/deploy-artifacts/deployments/'

    # Verificar artefatos no Blob Storage:
    azcopy list "https://${azurerm_storage_account.besu_data.name}.blob.core.windows.net/${azurerm_storage_container.besu_data.name}/artifacts/"
  EOT
}

output "validation_commands" {
  description = "Comandos para validar a rede após o apply."
  value       = <<-EOT
    # Verificar blockNumber no Node-1:
    curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://${azurerm_public_ip.besu_node[0].ip_address}:8545

    # Verificar peers conectados (deve retornar ${format("0x%x", var.node_count - 1)} com ${var.node_count} nós):
    curl -s -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' http://${azurerm_public_ip.besu_node[0].ip_address}:8545
  EOT
}

output "caliper_public_ip" {
  description = "IP público da instância Caliper."
  value       = azurerm_public_ip.caliper.ip_address
}

output "caliper_ssh_command" {
  description = "Comando SSH para acessar a instância Caliper."
  value       = "ssh -i ${var.private_key_path} ubuntu@${azurerm_public_ip.caliper.ip_address}  # Caliper"
}

output "caliper_log_command" {
  description = "Comando para acompanhar o log de execução do Caliper."
  value       = "ssh -i ${var.private_key_path} ubuntu@${azurerm_public_ip.caliper.ip_address} 'tail -f /home/ubuntu/besu-setup.log'"
}

output "caliper_results_commands" {
  description = "Comandos para verificar os resultados dos testes Caliper no Blob Storage (prefixo caliper-results/)."
  value       = <<-EOT
    # Listar todas as execuções:
    azcopy list "https://${azurerm_storage_account.besu_data.name}.blob.core.windows.net/${azurerm_storage_container.besu_data.name}/caliper-results/"

    # Baixar todos os CSVs de uma execução (substituir <timestamp>):
    azcopy copy "https://${azurerm_storage_account.besu_data.name}.blob.core.windows.net/${azurerm_storage_container.besu_data.name}/caliper-results/<timestamp>/*" ./caliper-results/ --recursive
  EOT
}

output "caliper_b_public_ips" {
  description = "IPs públicos das instâncias Caliper extras (workers remotos, modo distribuído). Lista vazia se node_caliper_count <= 1."
  value       = azurerm_public_ip.caliper_b[*].ip_address
}

output "caliper_b_private_ips" {
  description = "IPs privados das instâncias Caliper extras."
  value       = azurerm_network_interface.caliper_b[*].ip_configuration[0].private_ip_address
}

output "caliper_b_ssh_commands" {
  description = "Comandos SSH para cada instância Caliper extra."
  value = [
    for i in range(length(azurerm_public_ip.caliper_b)) :
    "ssh -i ${var.private_key_path} ubuntu@${azurerm_public_ip.caliper_b[i].ip_address}  # Caliper B-${i + 1} (workers remotos)"
  ]
}

output "caliper_a_private_ip" {
  description = "IP privado da instância Caliper A (manager) — endereço do broker MQTT no modo distribuído."
  value       = azurerm_network_interface.caliper.ip_configuration[0].private_ip_address
}

output "caliper_a_workers" {
  description = "Valor de var.caliper_a_workers usado neste apply (fonte única de verdade pro orquestrador local)."
  value       = var.caliper_a_workers
}

output "caliper_b_workers" {
  description = "Valor de var.caliper_b_workers usado neste apply."
  value       = var.caliper_b_workers
}

output "azure_location" {
  description = "Região Azure usada neste apply."
  value       = var.azure_location
}

output "private_key_path" {
  description = "Caminho da chave privada SSH usada neste apply (var.private_key_path) — lido pelo orquestrador local em vez de assumir um valor padrão."
  value       = var.private_key_path
}

output "caliper_distributed_sweep_command" {
  description = "Com node_caliper_count > 1, o terraform apply já dispara essa varredura sozinho (null_resource.run_distributed_sweep) — este comando é só pra RE-rodar manualmente depois (ex.: outro --functions/--tps-list), lendo os parâmetros de 'terraform output -json'."
  value       = var.node_caliper_count > 1 ? "python3 ${path.module}/scripts/run_distributed_sweep.py" : "N/A - node_caliper_count=1 (a varredura automática de sempre já roda sozinha via terraform apply)"
}
