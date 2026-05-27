output "wireguard_ip_publica" {
  value = aws_eip.wireguard.public_ip
}

output "nlb_eip" {
  description = "IP fija del NLB -> apuntar DuckDNS aqui"
  value       = aws_eip.nlb.public_ip
}

output "alb_dns" {
  description = "DNS del ALB (acceso directo o debugging)"
  value       = aws_lb.alb.dns_name
}

output "rds_endpoint" {
  description = "Endpoint de conexion RDS MariaDB"
  value       = aws_db_instance.glpi.address
}

output "efs_id" {
  description = "ID del EFS compartido del GLPI"
  value       = aws_efs_file_system.glpi.id
}

output "tfstate_bucket" {
  description = "Bucket S3 donde reside el tfstate remoto"
  value       = aws_s3_bucket.tfstate.id
}
