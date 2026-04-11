output "instance_id" {
  description = "ID of the created EC2 instance"
  value       = aws_instance.besu_node.id
}

output "public_ip" {
  description = "Public IPv4 address of the EC2 instance"
  value       = aws_instance.besu_node.public_ip
}

output "public_dns" {
  description = "Public DNS name of the EC2 instance"
  value       = aws_instance.besu_node.public_dns
}

output "ssh_user" {
  description = "SSH user for the Ubuntu instance"
  value       = "ubuntu"
}
