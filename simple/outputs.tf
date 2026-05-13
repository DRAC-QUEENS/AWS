output "wireguard_ip_publica" {
  description = "IP publica del WireGuard -> actualizar endpoint en OPNsense"
  value       = aws_eip.wireguard.public_ip
}

output "nginx_ip_publica" {
  description = "IP publica del Nginx -> apuntar DuckDNS aqui"
  value       = aws_eip.nginx.public_ip
}

output "glpi_ip_privada" {
  description = "IP privada del GLPI (acceso SSH via WireGuard)"
  value       = aws_instance.glpi.private_ip
}

output "tfstate_bucket" {
  description = "Bucket S3 donde reside el tfstate remoto"
  value       = aws_s3_bucket.tfstate.id
}
