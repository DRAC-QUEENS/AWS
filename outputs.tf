output "wireguard_ip_publica" {
  value = aws_eip.wireguard.public_ip
}

output "nginx_ip_publica" {
  value = aws_eip.nginx.public_ip
}

output "glpi_ip_privada" {
  value = aws_instance.glpi.private_ip
}

output "tfstate_bucket" {
  description = "Bucket S3 donde reside el tfstate remoto"
  value       = aws_s3_bucket.tfstate.id
}

output "backups_bucket" {
  description = "Bucket S3 para volcados de aplicacion (DB dumps, configs)"
  value       = aws_s3_bucket.backups.id
}
