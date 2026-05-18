# =============================================================================
# ASG Scaling Policies — Target Tracking (CPU)
# =============================================================================
# AWS Academy: no se pueden crear roles IAM propios, pero las políticas de
# Target Tracking sólo necesitan el permiso de servicio del ASG (ya integrado)
# y las métricas predefinidas de EC2 (disponibles sin agente extra).
#
# Política elegida: TargetTrackingScaling sobre ASGAverageCPUUtilization.
# - Scale-out: AWS añade instancias cuando la CPU media supera el target.
# - Scale-in:  AWS elimina instancias cuando la CPU lleva tiempo por debajo.
# AWS crea y gestiona las alarmas CloudWatch internas automáticamente.
# =============================================================================

resource "aws_autoscaling_policy" "glpi_cpu" {
  name                   = "asg-glpi-cpu-tracking"
  autoscaling_group_name = aws_autoscaling_group.glpi.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    # GLPI (PHP + Apache) empieza a degradarse por encima del 65-70% de CPU.
    # 60% deja margen para absorber el pico mientras arranca la nueva instancia
    # (~5 min con el user_data actual: apt + wget GLPI + mount EFS).
    target_value = 60.0

    # Evita scale-in agresivo: no eliminar instancias recién lanzadas
    # antes de que hayan terminado el calentamiento (~10 min en este ASG).
    disable_scale_in = false
  }
}

# =============================================================================
# Alarmas CloudWatch visibles — escalan por peticiones en el ALB
# =============================================================================
# Además del target tracking (automático), estas alarmas complementarias
# permiten reaccionar a picos de tráfico aunque la CPU no suba todavía
# (p.ej. muchas peticiones lentas de BD que bloquean workers sin consumir CPU).
# =============================================================================

# --- Scale-out: demasiadas peticiones por instancia ---
resource "aws_cloudwatch_metric_alarm" "glpi_req_high" {
  alarm_name          = "glpi-alb-requests-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RequestCountPerTarget"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  # >500 req/min por instancia es señal de saturación para GLPI
  threshold           = 500
  alarm_description   = "Scale-out: >500 req/min por instancia GLPI en el ALB"

  dimensions = {
    TargetGroup  = aws_lb_target_group.glpi.arn_suffix
    LoadBalancer = aws_lb.alb.arn_suffix
  }

  alarm_actions = [aws_autoscaling_policy.glpi_req_scaleout.arn]
}

resource "aws_autoscaling_policy" "glpi_req_scaleout" {
  name                   = "asg-glpi-req-scaleout"
  autoscaling_group_name = aws_autoscaling_group.glpi.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 300
}

# --- Scale-in: tráfico bajo sostenido ---
resource "aws_cloudwatch_metric_alarm" "glpi_req_low" {
  alarm_name          = "glpi-alb-requests-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5   # 5 min consecutivos con poco tráfico antes de reducir
  metric_name         = "RequestCountPerTarget"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 50
  alarm_description   = "Scale-in: <50 req/min por instancia durante 5 min"

  dimensions = {
    TargetGroup  = aws_lb_target_group.glpi.arn_suffix
    LoadBalancer = aws_lb.alb.arn_suffix
  }

  alarm_actions = [aws_autoscaling_policy.glpi_req_scalein.arn]
}

resource "aws_autoscaling_policy" "glpi_req_scalein" {
  name                   = "asg-glpi-req-scalein"
  autoscaling_group_name = aws_autoscaling_group.glpi.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
}

# =============================================================================
# Alarma de salud: instancias unhealthy en el ALB
# =============================================================================
# Avisa si hay instancias que el ALB marca como unhealthy. No escala, solo alerta.
# En AWS Academy se puede ver en la consola de CloudWatch.
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "glpi_unhealthy" {
  alarm_name          = "glpi-alb-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Hay instancias GLPI unhealthy en el ALB"

  dimensions = {
    TargetGroup  = aws_lb_target_group.glpi.arn_suffix
    LoadBalancer = aws_lb.alb.arn_suffix
  }
  # Sin alarm_actions: en Academy no hay SNS propio, la alarma es visible en consola
}
