output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "wireguard_private_ip" {
  value = aws_instance.wireguard.private_ip
}

output "wireguard_public_ip" {
  value = aws_eip.wireguard_eip.public_ip
}

output "nginx_private_ip" {
  value = aws_instance.nginx.private_ip
}

output "nginx_public_ip" {
  value = aws_instance.nginx.public_ip
}

output "glpi_private_ip" {
  value = aws_instance.glpi.private_ip
}