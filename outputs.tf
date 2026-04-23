output "wireguard_ip_publica" {
  value = aws_eip.wireguard.public_ip
}

output "nginx_ip_publica" {
  value = aws_eip.nginx.public_ip
}

output "glpi_ip_privada" {
  value = aws_instance.glpi.private_ip
}
