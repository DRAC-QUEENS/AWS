# Outputs: Valores a mostrar tras Terraform apply
# ===============================================
# Terraform "devuelve" estos valores al terminal para que el usuario
# pueda acceder a instancias sin tener que buscar en AWS Console

output "vpc_id" {
  description = "ID de la VPC principal"
  value       = aws_vpc.main.id
  # Uso: Referencia en otros proyectos Terraform, scripts AWS CLI, etc.
}

output "public_subnet_id" {
  description = "ID de la subnet pública (WireGuard + Nginx)"
  value       = aws_subnet.public.id
  # Uso: Crear recursos adicionales en subnet pública
}

output "private_subnet_id" {
  description = "ID de la subnet privada (GLPI)"
  value       = aws_subnet.private.id
  # Uso: Crear recursos adicionales en subnet privada
}

output "wireguard_private_ip" {
  description = "IP privada de WireGuard (dentro VPC)"
  value       = aws_instance.wireguard.private_ip
  # Uso: Debugging, conexiones internas desde otras instancias
}

output "wireguard_eip" {
  description = "IP Elástica pública de WireGuard (acceso internet)"
  value       = aws_eip.wireguard_eip.public_ip
  # Uso: SSH a WireGuard, configurar clientes VPN
  # Ejemplo: ssh -i key.pem ubuntu@<wireguard_eip>
}

output "nginx_private_ip" {
  description = "IP privada de Nginx (dentro VPC)"
  value       = aws_instance.nginx.private_ip
  # Uso: Debugging, referencias internas desde otras instancias
}

output "nginx_eip" {
  description = "IP Elástica pública de Nginx (acceso internet)"
  value       = aws_eip.nginx_eip.public_ip
  # Uso: SSH a Nginx, DNS CNAME para usuarios finales
  # Ejemplo: 
  #   - ssh -i key.pem ubuntu@<nginx_eip>
  #   - Registrar A record en DNS: app.example.com → <nginx_eip>
}

output "glpi_private_ip" {
  description = "IP privada de GLPI (dentro VPC, no accesible desde internet)"
  value       = aws_instance.glpi.private_ip
  # Uso: Configuración Nginx proxy backend, debugging desde VPN
  # Nota: NO es accesible desde internet directamente
}