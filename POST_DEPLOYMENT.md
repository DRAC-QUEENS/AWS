# Post-Deployment Manual Steps

Pasos manuales necesarios después de `terraform apply`. Seguir en orden.

---

## 1. Activar backend remoto S3

Solo necesario la primera vez (o si se destruye y recrea la infraestructura).

```bash
# Ver el nombre del bucket creado
terraform output tfstate_bucket

# Editar provider.tf: descomentar el bloque backend "s3" y sustituir <ACCOUNT_ID>
# Ejemplo de lo que quedará:
#   backend "s3" {
#     bucket         = "dracs-tfstate-123456789012"
#     key            = "infra/terraform.tfstate"
#     region         = "us-east-1"
#     encrypt        = true
#     dynamodb_table = "dracs-tfstate-lock"
#   }

# Migrar el state local al bucket
terraform init -migrate-state
```

---

## 2. Apuntar DuckDNS a la IP fija del NLB

```bash
terraform output nlb_eip   # obtener la IP fija
```

1. Ir a https://www.duckdns.org
2. Seleccionar el dominio del proyecto (ej. `dracs.duckdns.org`)
3. Actualizar la IP con el valor de `nlb_eip`
4. Verificar: `curl -I http://dracs.duckdns.org/glpi/` (esperar ~3-5 min al ASG)

---

## 3. Actualizar OPNsense — Endpoint WireGuard

El EIP de WireGuard cambia con cada despliegue/cuenta nueva.

```bash
terraform output wireguard_ip_publica   # nueva IP pública de WireGuard
```

En OPNsense:
- VPN → WireGuard → Peers → editar el peer de AWS
- Cambiar **Endpoint** a `<wireguard_ip_publica>:51820`
- Guardar y aplicar cambios
- Verificar túnel: `ping 10.8.0.1` desde OPNsense (o desde un nodo Proxmox)

---

## 4. Verificar GLPI operativo

El ASG tarda entre 3 y 8 minutos en arrancar la instancia, instalar GLPI y pasar el health check del ALB.

```bash
# Ver el DNS del ALB para debugging directo
terraform output alb_dns

# Comprobar que el ALB responde (puede tardar unos minutos)
curl -I http://$(terraform output -raw alb_dns)/glpi/

# Si DuckDNS ya apunta:
curl -I http://dracs.duckdns.org/glpi/
```

Si el health check no pasa en 10 minutos:
```bash
# En AWS Console → EC2 → Auto Scaling Groups → asg-glpi-dracs → Instance management
# Seleccionar la instancia → Connect (Session Manager o SSH via WireGuard)
tail -f /var/log/cloud-init-output.log
```

---

## 5. Configuración inicial GLPI (web)

Acceder a `http://dracs.duckdns.org/glpi/` (o via ALB DNS):

1. **Login inicial**: usuario `glpi`, contraseña `glpi`
2. **Cambiar contraseña admin**:
   - Icono de usuario (esquina superior derecha) → Mi cuenta → Cambiar contraseña
   - Usar una contraseña fuerte
3. **Configurar la URL base**:
   - Configuración → General → General setup
   - **URL de la aplicación**: `http://dracs.duckdns.org/glpi` (o la IP del NLB si no usas DuckDNS)
   - Esto es importante para que los enlaces generados sean correctos
4. **Eliminar el archivo de instalación** (GLPI 10.x lo hace automáticamente, pero verificar):
   - Si existe: `rm /var/www/html/glpi/install/install.php`

---

## 6. Verificar acceso desde la red on-prem (via WireGuard)

Desde un nodo Proxmox o la máquina con el cliente WireGuard activo:

```bash
# Nginx en 10.0.1.20 debe proxear al ALB
curl -I http://10.0.1.20/glpi/

# Si Nginx responde 502, verificar que el proxy_pass apunta al ALB correcto:
# En la instancia Nginx:
#   grep proxy_pass /etc/nginx/sites-enabled/glpi
```

Si Nginx se creó antes que el ALB (en caso de recreación parcial), re-aplicar:
```bash
terraform apply -replace=aws_instance.nginx
```

---

## 7. Verificar RDS y EFS

```bash
terraform output rds_endpoint   # endpoint de conexión
terraform output efs_id         # ID del filesystem

# Desde una instancia GLPI del ASG (via SSH o Session Manager):
# Comprobar que EFS está montado
mount | grep efs

# Comprobar conexión a RDS
mysql -h $(terraform output -raw rds_endpoint) -u glpi -p glpi -e "SHOW TABLES;" 2>/dev/null | wc -l
# Debe devolver el número de tablas (>50 si GLPI está instalado)
```

---

## 8. (Opcional) HTTPS en ALB — pendiente de certificado ACM

Para habilitar HTTPS se necesita un dominio verificable en ACM (Route53 o CNAME en DuckDNS):

```bash
# En el roadmap: una vez el dominio esté verificado en ACM
# 1. Crear certificado en ACM para el dominio DuckDNS
# 2. Añadir listener HTTPS:443 en el ALB apuntando al mismo target group
# 3. Añadir listener TCP:443 en el NLB delegando al ALB
# 4. Redirigir HTTP → HTTPS en el listener 80 del ALB
```

---

## Referencia rápida de outputs

```bash
terraform output nlb_eip              # IP fija → DuckDNS
terraform output alb_dns              # DNS ALB (debugging)
terraform output rds_endpoint         # MariaDB endpoint
terraform output efs_id               # EFS filesystem ID
terraform output wireguard_ip_publica # EIP WireGuard → OPNsense peer
terraform output nginx_ip_publica     # EIP Nginx
terraform output tfstate_bucket       # Bucket S3 del tfstate
```
