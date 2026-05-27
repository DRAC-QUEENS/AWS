# AWS — Política de Backups DRACS

Política simple, todo nativo AWS, sin Lambda ni código custom.

---

## Resumen rápido

| Recurso | Backup | Retención | Coste/mes |
|---------|--------|-----------|-----------|
| **RDS** (BD GLPI) | Snapshots automáticos diarios | 30 días | $0 (incluido) |
| **EFS** (archivos GLPI) | Snapshots AWS Backup nativos | 35 días | ~$0.05/GB |

**Coste total estimado:** <$0.30/mes.

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

AWS RDS hace snapshots automáticos cada noche durante la ventana de backup (default 03:00-04:00 UTC) y los retiene 30 días.

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
# Sustituye <EFS_ID> por el ID real (terraform output efs_id)
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

Estos snapshots **manuales** no expiran automáticamente. Bórralos cuando ya no los necesites:
```bash
aws rds delete-db-snapshot --db-snapshot-identifier "$SNAPSHOT_ID"
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

---

## Riesgos conocidos

1. **`aws_efs_backup_policy` puede fallar en AWS Academy** si `AWSBackupDefaultServiceRole` no existe. Si el `terraform apply` falla con error de IAM en este recurso, comentar el recurso en `backups.tf`. EFS quedaría sin backup automático.

2. **`skip_final_snapshot = true` en RDS** (`glpi_scaling.tf`): si se destruye la instancia RDS con `terraform destroy`, **NO se guarda snapshot final**. Deliberado para laboratorio, pero **muy peligroso en producción**.

---

## Referencias cruzadas

- Configuración RDS: [glpi_scaling.tf](../../glpi_scaling.tf)
- EFS backup policy: [backups.tf](../../backups.tf)
- Costes globales: [AWS-COSTES.md](AWS-COSTES.md)
- Runbook operativo: [AWS-RUNBOOK.md](AWS-RUNBOOK.md)
