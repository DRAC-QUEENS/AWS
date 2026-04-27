# AMI Backup y Migración entre Cuentas AWS

## Descripción General

El archivo `backups.tf` contiene la configuración Terraform para crear AMIs (Amazon Machine Images) de las tres instancias principales:
- **WireGuard**: VPN Gateway (10.0.1.10)
- **Nginx**: Reverse Proxy (10.0.1.20)
- **GLPI**: Inventory Server (10.0.2.10) - **CRÍTICA**

Las AMIs capturan toda la configuración, paquetes y datos de la instancia, permitiendo reproducir el entorno exacto en otra cuenta AWS.

---

## Creación de AMIs

### Opción 1: Crear todas las AMIs

```bash
cd /home/jsa5214/AWS

# Crear backup de todas las instancias
terraform apply -var create_ami_backup=true

# Confirmar con "yes" cuando pregunte
```

Este proceso tardará **5-10 minutos** (sin reiniciar las instancias: `no_reboot=true`).

### Opción 2: Crear solo GLPI (recomendado para backups periódicos)

Edita `backups.tf` temporalmente, comenta las AMIs de WireGuard y Nginx, y ejecuta:

```bash
terraform apply -var create_ami_backup=true
```

### Ver las AMIs creadas

```bash
# En AWS Console
aws ec2 describe-images --owners self --query 'Images[*].[Name,ImageId,CreationDate]' --output table

# O directamente:
aws ec2 describe-images --owners self --filters "Name=tag:Description,Values=*backup*"
```

---

## Uso Normal (sin crear AMIs)

El comportamiento por defecto es **no crear AMIs** en cada `terraform apply`:

```bash
# Esto NO crea nuevas AMIs
terraform apply

# Esto SÍ crea nuevas AMIs
terraform apply -var create_ami_backup=true
```

---

## Migración a otra Cuenta AWS

### Paso 1: Obtener AMI IDs en cuenta origen

```bash
# Ejecutar en cuenta ORIGEN
terraform apply -var create_ami_backup=true

# Ver los IDs de las AMIs creadas:
terraform output ami_wireguard_id
terraform output ami_nginx_id
terraform output ami_glpi_id

# Ejemplo:
# ami-0abc1234567890def (WireGuard)
# ami-0ghi5678901234jkl (Nginx)
# ami-0mno9012345678pqr (GLPI)
```

### Paso 2: Copiar AMIs a cuenta destino

**En cuenta ORIGEN**, haz las AMIs públicas (temporalmente):

```bash
# WireGuard
aws ec2 modify-image-attribute --image-id ami-0abc1234567890def \
  --launch-permission Add=[{Group=all}]

# Nginx
aws ec2 modify-image-attribute --image-id ami-0ghi5678901234jkl \
  --launch-permission Add=[{Group=all}]

# GLPI
aws ec2 modify-image-attribute --image-id ami-0mno9012345678pqr \
  --launch-permission Add=[{Group=all}]
```

**En cuenta DESTINO**, copia las AMIs:

```bash
# Cambiar credenciales AWS a la cuenta destino
# export AWS_ACCESS_KEY_ID=...
# export AWS_SECRET_ACCESS_KEY=...

# Copiar AMIs
aws ec2 copy-image --source-region us-east-1 \
  --source-image-id ami-0abc1234567890def \
  --name wireguard-gateway-migrated

aws ec2 copy-image --source-region us-east-1 \
  --source-image-id ami-0ghi5678901234jkl \
  --name nginx-proxy-migrated

aws ec2 copy-image --source-region us-east-1 \
  --source-image-id ami-0mno9012345678pqr \
  --name glpi-server-migrated

# Esperar a que terminen (5-10 minutos)
# Ver progreso:
aws ec2 describe-images --owners self --query 'Images[*].[Name,State]'
```

### Paso 3: Actualizar Terraform en cuenta destino

En la cuenta destino, actualiza `instances.tf` para usar las nuevas AMIs:

```hcl
resource "aws_instance" "wireguard" {
  ami = "ami-0abc1234567890def"  # Nueva AMI de destino
  # ... resto igual
}

resource "aws_instance" "nginx" {
  ami = "ami-0ghi5678901234jkl"  # Nueva AMI de destino
  # ... resto igual
}

resource "aws_instance" "glpi" {
  ami = "ami-0mno9012345678pqr"  # Nueva AMI de destino
  # ... resto igual
}
```

Luego:

```bash
terraform apply
```

### Paso 4: Hacer privadas nuevamente las AMIs de origen

**En cuenta ORIGEN**, revierte las AMIs a privadas:

```bash
aws ec2 modify-image-attribute --image-id ami-0abc1234567890def \
  --launch-permission Remove=[{Group=all}]

aws ec2 modify-image-attribute --image-id ami-0ghi5678901234jkl \
  --launch-permission Remove=[{Group=all}]

aws ec2 modify-image-attribute --image-id ami-0mno9012345678pqr \
  --launch-permission Remove=[{Group=all}]
```

---

## Limpieza de AMIs antiguas

Las AMIs ocupan espacio en S3 y generan costos. Para eliminar AMIs viejas:

```bash
# Listar AMIs con fechas
aws ec2 describe-images --owners self --query 'Images[*].[Name,CreationDate,ImageId]' --output table | sort

# Deregistrar una AMI (no se puede eliminar directamente)
aws ec2 deregister-image --image-id ami-0abc1234567890def

# También eliminar los snapshots EBS asociados:
aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[*].[SnapshotId,StartTime]' | grep "ami-0abc1234567890def"
aws ec2 delete-snapshot --snapshot-id snap-xxxxxxxx
```

---

## Recomendaciones

| Instancia | Frecuencia | Motivo |
|-----------|-----------|--------|
| WireGuard | Mensual | Config estable, cambios raros |
| Nginx | Mensual | Config estable, cambios raros |
| **GLPI** | **Semanal** | Datos críticos, cambios frecuentes |

## Automatización futura

Puedes agregar un cron job en tu máquina local:

```bash
# Cada domingo a las 2 AM, crear backup de GLPI
0 2 * * 0 cd /home/jsa5214/AWS && terraform apply -var create_ami_backup=true -auto-approve
```

O usar AWS Backup (servicio nativo de AWS) para automatizar esto sin Terraform.

---

## Notas importantes

- ⏱️ `no_reboot = true`: No reinicia las instancias durante la creación de AMI
- 🔒 Las AMIs son privadas por defecto (solo tu cuenta)
- 💾 Cada AMI se almacena en snapshots EBS (genera costos)
- 🌍 Las AMIs son regionales (copiar entre regiones requiere pasos adicionales)
