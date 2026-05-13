# Seguridad

La seguridad de la infraestructura se monta sobre tres capas: **Security Groups** que controlan tráfico de red entre componentes, **IAM** (limitado al rol `LabRole` propio de AWS Academy) para que las EC2 puedan llamar a servicios AWS sin credenciales en disco, y **KMS** con una CMK propia para poder compartir AMIs cifradas entre cuentas. Los secretos (claves WireGuard, contraseña RDS, token DuckDNS) viven en `terraform.tfvars` que está gitignored.

# 1. Security Groups

---

Se han definido seis Security Groups que aplican el principio de mínimo acceso: cada capa solo acepta tráfico de la capa inmediatamente anterior. Internet llega al NLB, el NLB hablará con el ALB, el ALB hablará con GLPI y GLPI hablará con RDS/EFS.

| SG | Ingress | Egress |
| --- | --- | --- |
| `wireguard-dracs` | UDP:51820 desde 0.0.0.0/0 (handshake VPN); TCP:22 desde 10.8.0.0/24 (admin via VPN); todo desde 10.0.0.0/16 (forwarding intra-VPC) | Todo |
| `nginx-dracs` | TCP:80/443 desde 0.0.0.0/0; TCP:22 desde 10.8.0.0/24 (admin via VPN) | Todo |
| `alb-glpi-dracs` | TCP:80 y TCP:443 desde 0.0.0.0/0; TCP:80 desde `nginx-dracs` SG | Todo |
| `glpi-dracs` | TCP:80 desde `alb-glpi-dracs` SG; todo desde 10.8.0.0/24, 192.168.1.0/24, 192.168.10.0/24, 192.168.20.0/24 (admin VPN + on-prem) | Todo |
| `rds-glpi-dracs` | TCP:3306 sólo desde `glpi-dracs` SG | Todo |
| `efs-glpi-dracs` | NFS:2049 sólo desde `glpi-dracs` SG | Todo |

![](aws-security-groups.png){width=900px}
<!-- captura: AWS Console → VPC → Security Groups → filtrado por vpc-dracs -->

**Quién acepta tráfico de quién:**

```
Internet
  │
  ▼
NLB ────────────────────────────────── (sin SG, capa 4)
  │
  ▼
ALB  [alb-glpi-dracs]
  ├── Acepta: 80/443 desde 0.0.0.0/0 (internet)
  └── Acepta: 80 desde nginx-dracs SG (tráfico interno via Nginx)
  │
  ▼
GLPI ASG  [glpi-dracs]
  ├── Acepta: 80 desde alb-glpi-dracs SG
  ├── Acepta: todo desde 10.8.0.0/24 (VPN)
  ├── Acepta: todo desde 192.168.x.x (on-prem)
  └── Acepta: todo desde nginx-dracs SG (proxy-jump SSH)
  │
  ├──────────────────────────────────┐
  ▼                                  ▼
RDS  [rds-glpi-dracs]             EFS  [efs-glpi-dracs]
  └── 3306 desde glpi-dracs SG       └── 2049 desde glpi-dracs SG
```

**Lo que esto garantiza:**

- Desde internet nadie puede conectarse directamente a GLPI, RDS o EFS — solo al NLB.
- Solo el ALB puede mandar HTTP a las instancias del ASG.
- Solo el ASG puede conectarse a RDS y EFS.
- El acceso administrativo (SSH, debug) solo es posible desde la VPN o desde on-prem.

> **Nota:** las reglas de "todo desde on-prem" en `glpi-dracs` son intencionalmente amplias para facilitar el debugging desde la red interna. En un entorno productivo real se restringirían a puertos específicos (80, 22).

# 2. IAM

---

AWS Academy no permite crear roles propios. Las EC2 que necesitan permisos AWS usan el `LabInstanceProfile` que viene preexistente:

- **Rol asociado:** `LabRole`
- **Permisos relevantes para nosotros:**
  - SSM Session Manager (`ssm:*` limitado) — habilita shell sin SSH
  - ACM Import (`acm:ImportCertificate`) — para subir el cert TLS renovado
  - EC2 metadata read — base para todo
  - CloudWatch Logs (no usado, pero disponible)

El Launch Template del ASG declara este profile y por eso las instancias GLPI son alcanzables por SSM y pueden subir certs:

```hcl
iam_instance_profile {
  name = "LabInstanceProfile"
}
```

El WG y el Nginx también pueden recibir el profile adjuntándolo en caliente desde la consola/CLI, aunque no es estrictamente necesario para su función (las usamos para SSM durante el debugging puntual del túnel).

> **Nota:** al adjuntar `LabInstanceProfile` a una instancia que ya está corriendo, el agente SSM tarda en tomar las nuevas credenciales (cache de IMDS). Es más rápido sustituir la instancia (en el caso del ASG, terminate y deja que arranque una nueva con el profile desde el principio).

# 3. KMS

---

Para poder compartir AMIs cifradas con otra cuenta (proceso de migración) hizo falta una **CMK (Customer-Managed Key)** propia. La key gestionada por AWS (`aws/ebs`, alias por defecto para snapshots EBS) **no se puede compartir entre cuentas**, da error `InvalidParameter: Snapshots encrypted with the AWS Managed CMK can't be shared`.

| Atributo | Valor |
| --- | --- |
| Alias | `alias/dracs-glpi-share-key` |
| Manager | `CUSTOMER` (CMK, no AWS managed) |
| Estado | `Enabled` |
| Usos | Cifrar snapshots EBS al copiar AMIs entre cuentas |

**Key policy** — además del statement por defecto que permite todo a la cuenta propietaria, se ha añadido un statement que autoriza explícitamente a la cuenta destino a usar la clave:

```json
{
  "Sid": "Allow use of the key",
  "Effect": "Allow",
  "Principal": { "AWS": ["arn:aws:iam::<CUENTA_DESTINO>:root"] },
  "Action": [
    "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
    "kms:GenerateDataKey*", "kms:DescribeKey"
  ],
  "Resource": "*"
}
```

Y otro statement equivalente con la acción `kms:CreateGrant` (condicionada a `kms:GrantIsForAWSResource = true`) para que la cuenta destino pueda crear grants implícitos al lanzar EC2 desde las AMIs compartidas.

# 4. Secretos

---

La política de gestión de secretos es **simple**: nada en el repo, todo en `terraform.tfvars` (gitignored) o en variables de entorno `TF_VAR_*`.

| Secreto | Variable | Almacenamiento |
| --- | --- | --- |
| Contraseña RDS GLPI | `glpi_db_password` | `terraform.tfvars` (`sensitive=true`) |
| Clave privada WG AWS | `wg_aws_private_key` | `terraform.tfvars` (`sensitive=true`) |
| Clave pública WG OPNsense | `wg_opnsense_public_key` | `terraform.tfvars` (`sensitive=true`) |
| Preshared key WG | `wg_preshared_key` | `terraform.tfvars` (`sensitive=true`) |
| Token DuckDNS | (no en Terraform) | Sólo se usa en certbot, vive en `/etc/certbot/duckdns.ini` (chmod 600) |
| Credenciales AWS | (no en Terraform) | `~/.aws/credentials` perfil `dracs-new` |

El `.gitignore` cubre:
- `*.tfvars`
- `terraform.tfstate*`
- `.terraform/`
- `*.pem`

> **Nota:** el `terraform.tfstate` puede contener secretos en texto plano (ej. contraseña de RDS). Por eso se mueve a backend remoto S3 cuanto antes y se evita commitearlo. El backend remoto cifra el state con SSE-S3.

# 5. Capa de cifrado interna de GLPI

---

Aparte de la seguridad de red, GLPI tiene su propia capa de cifrado a nivel de aplicación: **`glpicrypt.key`** es una clave simétrica con la que cifra las contraseñas que se guardan en BD (contraseña LDAP del DC, contraseña de SMTP, etc.).

- Generada por GLPI en su primera instalación.
- Es **única por instalación** y necesaria para descifrar lo que esa instalación cifró.
- En esta arquitectura se custodia en EFS (`_meta/config/glpicrypt.key`) para que sobreviva al ASG, y el `user_data` la restaura a `/var/www/html/glpi/config/` en cada nueva instancia.

Si esta clave se pierde, las contraseñas almacenadas pasan a ser irrecuperables y `db:update` puede negarse a continuar con un error tipo *"Falta el archivo de claves /var/www/html/glpi/config/glpicrypt.key"*.

# 6. Documentación relacionada

---

* **AWS.md** — visión general
* **AWS-RED.md** — subnets y rutas (los SGs actúan sobre ENIs de estas subnets)
* **AWS-VPN.md** — uso del SG `wireguard-dracs` y `nginx-dracs`
* **AWS-BALANCEO.md** — uso del SG `alb-glpi-dracs`
* **AWS-GLPI.md** — uso de los SGs `glpi-dracs`, `rds-glpi-dracs`, `efs-glpi-dracs` y custodia de `glpicrypt.key`
* **AWS-TERRAFORM.md** — tfvars y backend remoto
