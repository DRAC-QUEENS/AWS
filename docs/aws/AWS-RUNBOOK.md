# Runbook AWS

Este documento recoge los procedimientos operativos recurrentes sobre la infraestructura AWS y el troubleshooting de los problemas concretos encontrados durante el despliegue y la migración. Está pensado para consultarse cuando hace falta hacer una operación de mantenimiento o cuando algo falla, no para leerlo de principio a fin.

# 1. Conectar a una instancia (SSM Session Manager)

---

La forma estándar de obtener shell en cualquier instancia es **SSM Session Manager**, sin SSH ni VPN. Requiere que la instancia tenga `LabInstanceProfile` adjunto (el ASG ya lo lleva por defecto desde el Launch Template).

```bash
# Listar instancias y su ID
aws ec2 describe-instances --region us-east-1 \
  --query 'Reservations[*].Instances[*].{Name:Tags[?Key==`Name`]|[0].Value,Id:InstanceId}' \
  --output table

# Conectar
aws ssm start-session --region us-east-1 --target i-XXXXXXXX
```

Para la instancia del ASG (ID dinámico):

```bash
GLPI=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names asg-glpi-dracs \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target $GLPI
```

> **Nota:** si el comando dice `TargetNotConnected`, la instancia es nueva y SSM agent aún no ha registrado, o le falta el IAM profile. Esperar ~30s tras el boot, o ver el punto siguiente.

# 2. SSM no llega a una instancia recién modificada

---

Si se adjunta `LabInstanceProfile` a una instancia **ya corriendo**, el SSM agent no toma las credenciales nuevas hasta que se reinicia.

**Solución más rápida:**

```bash
aws ec2 reboot-instances --instance-ids i-XXXXXXXX
# Esperar ~30s, comprobar:
aws ssm describe-instance-information \
  --filters Key=InstanceIds,Values=i-XXXXXXXX \
  --query 'InstanceInformationList[0].PingStatus'
# Debe devolver "Online"
```

Para el ASG es más limpio terminar la instancia y dejar que el grupo lance una nueva (que arrancará ya con el IAM profile del Launch Template).

# 3. Reemplazar la instancia del ASG (para coger user_data nuevo)

---

Las modificaciones del `user_data` solo aplican a **nuevas** instancias. Cambiar el Launch Template no toca las que ya están corriendo. Para forzar el reemplazo:

```bash
# 1. Aplicar el cambio en Terraform (esto crea una nueva versión del LT)
terraform apply -auto-approve

# 2. Identificar la instancia actual y terminarla
GLPI=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names asg-glpi-dracs \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ec2 terminate-instances --instance-ids $GLPI

# 3. El ASG detectará que falta una instancia y lanzará otra con la versión latest del LT
# Esperar ~3-5 min hasta que esté healthy en el target group del ALB
```

> **Nota:** durante ese rato GLPI no estará accesible. Si no se puede permitir downtime, subir `asg_desired` a 2 antes (con `-var asg_desired=2`), esperar a la segunda esté healthy, terminar la vieja y volver a bajar a 1.

# 4. Cambiar `desired_capacity` del ASG

---

```bash
# Bajar a 0 para mantenimiento (apagar GLPI sin destruir nada)
terraform apply -auto-approve -var asg_desired=0

# Subir a 1 (volver a producción)
terraform apply -auto-approve -var asg_desired=1

# Escalar temporalmente a 2 o 3
terraform apply -auto-approve -var asg_desired=2
```

# 5. Renovar el certificado TLS

---

Cert Let's Encrypt para `dracs-glpi.duckdns.org`, dura **90 días**, renovación manual cada ~80 días.

**Procedimiento detallado**: [AWS-CERTIFICADO.md §4](AWS-CERTIFICADO.md#4-renovaci%C3%B3n-cada-90-d%C3%ADas)

Resumen rápido del flujo:
1. SSM a una instancia del ASG (el `user_data` ya restaura `/etc/letsencrypt` desde EFS)
2. `sudo /opt/cb/bin/certbot renew --cert-name dracs-glpi`
3. `aws acm import-certificate --certificate-arn <ARN-existente> ...` (reimportar sobre el mismo ARN, no crear nuevo)
4. `sudo cp -a /etc/letsencrypt/. /mnt/efs/letsencrypt/` (persistir para la próxima instancia del ASG)

No hace falta `terraform apply` — el ARN no cambia, AWS rota el contenido del cert en el ALB automáticamente.

# 6. Troubleshooting

---

## 6.1 Tras login, GLPI redirige a `/glpi` y da 404

Dos causas posibles:

**a) `url_base` en la BD apunta al path antiguo (legacy `/glpi`).** El `user_data` lo arregla en cada arranque, pero si se ha re-importado un dump puede volver a aparecer.

```bash
mysql -h "$(aws rds describe-db-instances --db-instance-identifier rds-glpi-dracs \
            --query 'DBInstances[0].Endpoint.Address' --output text)" \
  -u glpi -p<pass> glpi -e "
  UPDATE glpi_configs SET value = 'https://dracs-glpi.duckdns.org'
    WHERE name = 'url_base';
  UPDATE glpi_configs SET value = 'https://dracs-glpi.duckdns.org/apirest.php/'
    WHERE name = 'url_base_api';
"
cd /var/www/html/glpi && php bin/console cache:clear --no-interaction
```

**b) Navegador con caché del path antiguo.** Aunque el `url_base` esté correcto, navegadores que visitaron antes la URL `/glpi` pueden tener cacheado un redirect 301 que les lleva ahí. El VirtualHost de Apache trae una `RewriteRule` para devolver un 301 al path raíz:

```apache
RewriteEngine On
RewriteRule ^/glpi/?(.*)$ /$1 [R=301,L]
```

Esta regla se aplica en cada arranque del ASG. Si una instancia ya en ejecución no la tiene (por ejemplo, porque el `user_data` se cambió después de lanzarla), se puede aplicar en caliente vía SSM sin esperar al instance refresh (ver sección 7).

## 6.2 GLPI carga sin estilos (CSS roto)

Apache está con `DocumentRoot=/var/www/html/glpi/public` (modo "moderno"), pero GLPI 10.0.x hardcodea `public/lib/...` en las URLs de assets. Volver al modo legacy:

En `user_data/glpi_asg.sh.tpl`:

```apache
<VirtualHost *:80>
    DocumentRoot /var/www/html/glpi
    <Directory /var/www/html/glpi>
        AllowOverride All
        Require all granted
    </Directory>
    ...
</VirtualHost>
```

Aplicar Terraform y reemplazar la instancia (punto 3).

## 6.3 Auth LDAP falla (ICMP llega al DC pero TCP no)

Probable causa: **Windows Firewall** del DC tiene reglas inbound que limitan el origen a una subnet vieja, y la nueva subnet del ASG (10.0.4.x) no está cubierta.

**Diagnóstico desde la instancia GLPI:**

```bash
ping -c 2 192.168.10.10                                              # debería pasar
(timeout 2 bash -c "</dev/tcp/192.168.10.10/389") && echo OPEN || echo CLOSED
```

Si ICMP OK pero LDAP CLOSED → Windows Firewall. Ampliar el scope de las reglas inbound del DC (`wf.msc` → reglas LDAP/Kerberos/SMB → Scope → Remote IP addresses → añadir `10.0.0.0/16`).

## 6.4 AMI cifrada no se puede compartir (`InvalidParameter`)

```
An error occurred (InvalidParameter): Snapshots encrypted with the AWS Managed CMK can't be shared
```

La AMI está cifrada con la KMS key gestionada por AWS (`aws/ebs`). Hay que **re-cifrar** el snapshot con una CMK propia:

```bash
# 1. Crear CMK con key policy que autorice al account ID destino
# 2. Copiar el snapshot especificando la CMK
aws ec2 copy-snapshot --region us-east-1 \
  --source-snapshot-id <orig-snap-id> --source-region us-east-1 \
  --encrypted --kms-key-id alias/dracs-glpi-share-key

# 3. Registrar una nueva AMI a partir del snapshot re-cifrado
# 4. Compartir esta nueva AMI con --launch-permission Add=[{UserId=<destino>}]
```

## 6.5 OPNsense ve handshake pero AWS no recibe nada

Causa más probable: **OPNsense apunta al EIP de la cuenta vieja**. Al migrar de cuenta, el EIP del WG EC2 cambia.

**Diagnóstico:**

```bash
# Desde AWS (vía SSM al WG EC2)
sudo wg show wg0 dump
# Si para el peer ves: endpoint=(none) y handshake=0 → no llega nada
```

**Fix:** en OPNsense, VPN → WireGuard → Peers → editar el peer "AWS" → poner el Endpoint correcto (`<nuevo-EIP>:51820`) y aplicar.

## 6.6 La VPN está arriba pero Nginx no puede pingear 10.8.0.2

El IP del wg0 (`10.8.0.2`) sólo existe dentro de la EC2 WireGuard. Para que otra EC2 de la VPC pueda alcanzarla habría que añadir una ruta en la VPC `10.8.0.0/24 → ENI del WG`. **No se ha hecho** porque no afecta a la funcionalidad — los servicios on-prem se alcanzan por sus IPs reales (`192.168.x.x`), no por la dirección del túnel.

## 6.7 GLPI dice "Falta el archivo de claves glpicrypt.key"

La instancia del ASG no encontró `/var/www/html/glpi/files/_meta/config/glpicrypt.key` en EFS y el `user_data` no la restauró. Sin esa clave GLPI no descifra contraseñas guardadas y `db:update` aborta.

**Fix:** lanzar un migrator EC2 puntual desde la AMI custom de GLPI vieja que copie la clave a EFS:

```bash
# user_data del migrator
mkdir -p /mnt/efs && mount -t nfs4 -o nfsvers=4.1 \
  fs-XXX.efs.us-east-1.amazonaws.com:/ /mnt/efs
rsync -av /var/www/html/glpi/config/ /mnt/efs/_meta/config/
shutdown -h now
```

Luego reemplazar la instancia ASG (punto 3) para que el `user_data` la coja.

# 7. Parchear una instancia del ASG sin reemplazarla (SSM)

---

Cuando hace falta aplicar un cambio en una instancia ya en ejecución sin esperar a un instance refresh (porque la sustitución implica downtime o porque la launch template todavía no está actualizada en AWS), se puede usar `aws ssm send-command` para ejecutar el cambio directamente:

```bash
GLPI=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names asg-glpi-dracs \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

CONFIG_B64=$(cat << 'HEREDOC' | base64 -w0
<VirtualHost *:80>
    DocumentRoot /var/www/html/glpi

    RewriteEngine On
    RewriteRule ^/glpi/?(.*)$ /$1 [R=301,L]

    <Directory /var/www/html/glpi>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
HEREDOC
)

aws ssm send-command \
  --instance-ids "$GLPI" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[
     \"echo $CONFIG_B64 | base64 -d > /etc/apache2/sites-available/glpi.conf\",
     \"apache2ctl configtest && systemctl reload apache2\"
   ]}"
```

> **Nota sobre quoting:** pasar contenido multilínea con caracteres especiales (`$1`, comillas) a través del array `commands` de SSM es propenso a bugs. La técnica recomendada es codificar el contenido en base64 localmente y decodificarlo en el comando, como en el ejemplo.

Este parche dura hasta que se reemplace la instancia. Si se quiere persistir el cambio para futuras instancias hay que aplicarlo también en `user_data/glpi_asg.sh.tpl` y hacer `terraform apply` para que la launch template lo recoja.

# 8. Documentación relacionada

---

* **G2-A-59 — AWS.md** — visión general y problemas encontrados (resumen ejecutivo)
* **G2-A-66 — AWS-GLPI.md** — detalle de `user_data` idempotente y migrator
* **G2-A-67 — AWS-BALANCEO.md** — detalle de listeners ALB/NLB
* **AWS-CERTIFICADO.md** — detalle completo del certificado TLS
* **G2-A-60 — AWS-VPN.md** — gateway WireGuard
* **G2-A-61 — AWS-SEGURIDAD.md** — KMS, SGs y secretos
* **G2-A-63 — AWS-TERRAFORM.md** — procedimiento completo de migración entre cuentas
