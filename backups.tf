# =============================================================================
# Backups: politicas de backup nativas AWS
# =============================================================================

# ---------- EFS BACKUP POLICY (snapshots nativos AWS) ----------

# Activa el AWS Backup default plan en el EFS de GLPI.
# Snapshots diarios automaticos, retencion 35 dias, sin codigo custom.
resource "aws_efs_backup_policy" "glpi" {
  file_system_id = aws_efs_file_system.glpi.id

  backup_policy {
    status = "ENABLED"
  }
}
