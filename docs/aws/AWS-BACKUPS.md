# AWS — Política de Backups DRACS

Política simple, todo nativo AWS, sin Lambda ni código custom.

---

## Resumen rápido

| Recurso | Backup | Retención | Coste/mes |
|---------|--------|-----------|-----------|
| **RDS** (BD GLPI) | Snapshots automáticos diarios | 30 días | $0 (incluido) |
| **EFS** (archivos GLPI) | Snapshots AWS Backup nativos | 35 días | ~$0.05/GB |
| **S3 bucket** (`dracs-backups-*`) | Bajo demanda (dumps manuales) | 30d → Glacier, 365d → expira | ~$0.03/GB |

**Coste total estimado:** <$0.30/mes (≈ 0.4% del coste total DRACS).

---

## ¿Qué se backupea y qué NO?

### ✅ Sí se backupea
- **BD MariaDB en RDS**: usuarios, tickets, configuraciones, integraciones LDAP/SMTP
- **Archivos EFS**: documentos adjuntos a tickets, `glpicrypt.key`, configuración de certbot

### ❌ No se backupea (deliberadamente)
- **SO de las instancias ASG**: es efímero, lo regenera Packer AMI + `user_data` en cada arranque
- **Estado de Terraform**: vive en S3 con versionado (`s3://dracs-tfstate-${account_id}/`) — esto es otro mecanismo, no parte de esta política
- **Logs de CloudWatch**: tienen retención propia, no se replican

---

## Configuración (dónde vive en Terraform)

### 1. RDS — retención de snapshots
**Archivo:** `glpi_scaling.tf`

```hcl
resource "aws_db_instance" "glpi" {
  # ...
  backup_retention_period = 30
}
```

AWS RDS hace snapshots automáticos cada noche durante la ventana de backup (configurable, default 03:00-04:00 UTC) y los retiene 30 días.

### 2. EFS — backup policy nativa
**Archivo:** `backups.tf`

```hcl
resource "aws_efs_backup_policy" "glpi" {
  file_system_id = aws_efs_file_system.glpi.id
  backup_policy {
    status = "ENABLED"
  }
}
```

Activa el **AWS Backup default plan** que toma snapshots diarios y los retiene 35 días en el vault `Default`.

### 3. S3 — bucket para dumps manuales
**Archivo:** `backups.tf`

```hcl
resource "aws_s3_bucket" "backups" {
  bucket = "dracs-backups-${data.aws_caller_identity.current.account_id}"
}
```

Lifecycle: 30d → Glacier, 365d → expira. **No se llena automáticamente** — es un destino para dumps manuales.

---

## Cómo verificar que los backups funcionan

### RDS
```bash
# Ver retención configurada
aws rds describe-db-instances \
  --db-instance-identifier rds-glpi-dracs \
  --query 'DBInstances[0].BackupRetentionPeriod'
# Esperado: 30

# Listar snapshots automáticos disponibles
aws rds describe-db-snapshots \
  --db-instance-identifier rds-glpi-dracs \
  --snapshot-type automated \
  --query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime,Status]' \
  --output table
```

### EFS
```bash
# Sustituye <EFS_ID> por el ID real (terraform output o aws efs describe-file-systems)
aws efs describe-backup-policy --file-system-id <EFS_ID>
# Esperado: BackupPolicy.Status = "ENABLED"

# Ver recovery points generados (esperar 24h tras activar)
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name Default \
  --query 'RecoveryPoints[?contains(ResourceArn, `<EFS_ID>`)]'
```

---

## Procedimientos manuales

### Snapshot manual de RDS (antes de cambios grandes)

Recomendado antes de:
- `glpi-cli db:update` tras subir versión de GLPI
- Migraciones de cuenta AWS
- Cambios en `aws_db_instance` que puedan implicar replace

```bash
SNAPSHOT_ID="rds-glpi-pre-$(date +%Y%m%d-%H%M)"
aws rds create-db-snapshot \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --db-instance-identifier rds-glpi-dracs

# Esperar a que termine
aws rds wait db-snapshot-completed --db-snapshot-identifier "$SNAPSHOT_ID"
```

Estos snapshots **manuales** no expiran automáticamente (a diferencia de los automated). Bórralos cuando ya no los necesites:
```bash
aws rds delete-db-snapshot --db-snapshot-identifier "$SNAPSHOT_ID"
```

### Dump SQL portable a S3 (para protección de larga duración)

Útil si quieres un backup que sobreviva más de 30 días, o que sea portable fuera de AWS:

```bash
ACC_ID=$(aws sts get-caller-identity --query Account --output text)
DATE=$(date +%F)

mysqldump \
  -h $(terraform output -raw rds_endpoint) \
  -u glpi \
  -p"$GLPI_DB_PASSWORD" \
  --single-transaction \
  --routines \
  glpi \
  | gzip \
  | aws s3 cp - "s3://dracs-backups-${ACC_ID}/manual/glpi-${DATE}.sql.gz"
```

El bucket tiene lifecycle automático: 30d → Glacier, 365d → expira.

### Snapshot manual de EFS

```bash
aws backup start-backup-job \
  --backup-vault-name Default \
  --resource-arn "arn:aws:elasticfilesystem:eu-west-1:${ACC_ID}:file-system/<EFS_ID>" \
  --iam-role-arn "arn:aws:iam::${ACC_ID}:role/service-role/AWSBackupDefaultServiceRole"
```

---

## Restauración

### RDS desde snapshot
```bash
# Listar snapshots disponibles
aws rds describe-db-snapshots --db-instance-identifier rds-glpi-dracs

# Restaurar a una NUEVA instancia (AWS no permite sobrescribir la existente)
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier rds-glpi-dracs-restored \
  --db-snapshot-identifier <snapshot-id>
```

Una vez verificada la BD restaurada:
1. Apuntar GLPI a la nueva instancia (cambiar `rds_endpoint` o renombrar)
2. Borrar la instancia corrupta original

### EFS desde recovery point
Vía consola AWS Backup → Vault `Default` → seleccionar recovery point → Restore.

Restaura a un EFS nuevo. Luego copiar archivos al EFS original (o cambiar mount targets).

### Restaurar desde dump SQL en S3
```bash
aws s3 cp s3://dracs-backups-${ACC_ID}/manual/glpi-2026-05-24.sql.gz - \
  | gunzip \
  | mysql -h <RDS_ENDPOINT> -u glpi -p glpi
```

---

## Riesgos conocidos

1. **`aws_efs_backup_policy` puede fallar en AWS Academy** si `AWSBackupDefaultServiceRole` no existe. Si el `terraform apply` falla con error de IAM en este recurso:
   - Comentar el recurso en `backups.tf`
   - EFS queda sin backup automático
   - Mitigación: dumps manuales periódicos del EFS (tar + S3)

2. **`skip_final_snapshot = true` en RDS** (`glpi_scaling.tf` línea 55): si se destruye la instancia RDS con `terraform destroy`, **NO se guarda snapshot final**. Esto es deliberado para laboratorio, pero **muy peligroso en producción**.

3. **Bucket S3 versionado**: las versiones antiguas también cuentan para el coste. Borrar versiones obsoletas manualmente si el bucket crece mucho.

---

## Costes detallados

| Concepto | Coste unitario | Estimación DRACS |
|----------|----------------|------------------|
| RDS automated backups | Gratis hasta el tamaño de la BD | $0 |
| EFS backup (AWS Backup) | $0.05/GB-mes warm storage | ~$0.25/mes (5GB) |
| S3 Standard (dumps manuales) | $0.023/GB-mes | ~$0.03/mes |
| S3 Glacier (tras 30d) | $0.004/GB-mes | <$0.01/mes |
| **TOTAL** | | **<$0.30/mes** |

---

## Referencias cruzadas

- Bucket S3 y lifecycle: [backups.tf](../../backups.tf)
- Configuración RDS: [glpi_scaling.tf](../../glpi_scaling.tf) línea ~53
- Costes globales: [AWS-COSTES.md](AWS-COSTES.md)
- Runbook operativo: [AWS-RUNBOOK.md](AWS-RUNBOOK.md)
