# Stress test del ASG de GLPI

Procedimiento para validar manualmente que la política de Target Tracking
del Auto Scaling Group (`asg-glpi-dracs`) dispara correctamente cuando la
CPU media del grupo supera el 60 % sostenido. El objetivo es observar el
ciclo completo de escalado: subida de carga, alarma en estado `ALARM`,
aumento de `DesiredCapacity`, lanzamiento de instancia adicional y
posterior scale-in al cesar la carga.

El runbook está pensado para ejecutarse desde una terminal local con el
AWS CLI configurado contra la cuenta del laboratorio
(`563771271989`).

## 1. Requisitos previos

| Herramienta | Verificación | Instalación |
|---|---|---|
| `aws` CLI v2 | `aws --version` | Ver [AWS CLI docs](https://docs.aws.amazon.com/cli/) |
| Plugin SSM | `session-manager-plugin --version` | `curl https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb -o /tmp/ssmp.deb && sudo dpkg -i /tmp/ssmp.deb` |
| Apache Bench | `ab -V` | `sudo apt-get install -y apache2-utils` |
| Credenciales del lab | `aws sts get-caller-identity` | Refrescar las claves en `~/.aws/credentials` cada vez que se reinicia el laboratorio |

## 2. Comprobaciones previas al test

### 2.1 Estado del Auto Scaling Group

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names asg-glpi-dracs \
  --region us-east-1 \
  --query 'AutoScalingGroups[0].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Instances:Instances[*].[InstanceId,AvailabilityZone,HealthStatus,LifecycleState]}' \
  --output json
```

Se espera `Desired = 2` con las dos instancias en `InService` / `Healthy`,
una por AZ.

### 2.2 Política de escalado

```bash
aws autoscaling describe-policies \
  --auto-scaling-group-name asg-glpi-dracs \
  --region us-east-1 \
  --query 'ScalingPolicies[*].{Name:PolicyName,Type:PolicyType,Target:TargetTrackingConfiguration.TargetValue,Metric:TargetTrackingConfiguration.PredefinedMetricSpecification.PredefinedMetricType}' \
  --output table
```

Se espera una política `TargetTrackingScaling` sobre
`ASGAverageCPUUtilization` con un `Target = 60`.

### 2.3 Endpoint público

```bash
curl -o /dev/null -s -w "code=%{http_code} time=%{time_total}s\n" \
     https://dracs-glpi.duckdns.org/
```

Se espera un código `200` (o `302` de redirección a `/front/central.php`)
y un tiempo de respuesta inferior a 1 s.

## 3. Ejecución del stress test

### 3.1 Terminal A — generador de carga

```bash
ab -t 900 -c 200 -k -r https://dracs-glpi.duckdns.org/
```

Parámetros:

- `-t 900` — duración máxima de 900 s (15 min).
- `-c 200` — 200 conexiones HTTPS concurrentes.
- `-k` — reutiliza la conexión TCP/TLS (HTTP keep-alive). Reduce el
  coste de handshake y se aproxima al patrón de un cliente real.
- `-r` — no aborta el test ante fallos puntuales de socket o TLS.

La carga llega al endpoint público, atraviesa el NLB, termina TLS en el
ALB y se distribuye round-robin entre las instancias del ASG. Por tanto
ambas instancias reciben carga uniformemente, evitando que una sola
sature mientras la otra está ociosa.

### 3.2 Terminal B — métrica de CPU agregada

```bash
watch -n 30 'aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions Name=AutoScalingGroupName,Value=asg-glpi-dracs \
  --start-time $(date -u -d "10 min ago" +%Y-%m-%dT%H:%M:%S) \
  --end-time   $(date -u                 +%Y-%m-%dT%H:%M:%S) \
  --period 60 --statistics Average --region us-east-1 \
  --query "Datapoints | sort_by(@, &Timestamp)[*].[Timestamp,Average]" \
  --output table'
```

La métrica relevante es la **media del grupo**, no la de una sola
instancia, porque la política Target Tracking se calcula sobre el
agregado.

### 3.3 Terminal C — estado del ASG y alarma asociada

```bash
watch -n 30 'echo === ASG ===; \
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names asg-glpi-dracs --region us-east-1 \
  --query "AutoScalingGroups[0].{Desired:DesiredCapacity,Instances:Instances[*].[InstanceId,LifecycleState]}" \
  --output json; \
echo; echo === ALARMA ===; \
aws cloudwatch describe-alarms --region us-east-1 \
  --alarm-name-prefix TargetTracking-asg-glpi-dracs \
  --query "MetricAlarms[*].[AlarmName,StateValue,StateReason]" \
  --output table'
```

Las alarmas asociadas a la política se llaman
`TargetTracking-asg-glpi-dracs-AlarmHigh` y
`TargetTracking-asg-glpi-dracs-AlarmLow`. Las crea AWS automáticamente al
asociar la política al ASG; no aparecen en el código Terraform.

## 4. Resultado esperado

| Tiempo aprox. | Evento |
|---|---|
| 0–2 min | La CPU media del ASG sube progresivamente hacia el 60–80 %. |
| 3–5 min | La alarma `AlarmHigh` pasa de `OK` a `ALARM`. |
| 5–7 min | El ASG aumenta `DesiredCapacity` de 2 a 3. Aparece una instancia en estado `Pending`. |
| 7–10 min | La instancia nueva pasa el health check del ALB y pasa a `InService`. La CPU media baja al estar el tráfico repartido entre 3. |
| Tras detener `ab` | La CPU baja; la alarma `AlarmLow` permanece en `OK` durante el cooldown (~5 min) y después dispara el scale-in. |
| 20–30 min | `DesiredCapacity` vuelve a 2; la instancia adicional se termina. |

## 5. Diagnóstico de problemas frecuentes

### 5.1 Una instancia se marca `Unhealthy` durante el test

Causa más probable: el servidor Apache no responde al health check del
ALB dentro del timeout configurado. Comprobación:

```bash
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name asg-glpi-dracs \
  --region us-east-1 --max-items 5 \
  --query 'Activities[*].[StartTime,StatusCode,Cause]' --output table
```

Si la causa indica `ELB system health check failure`, conviene bajar la
concurrencia a `-c 100` y repetir.

### 5.2 La alarma `AlarmHigh` no llega a `ALARM`

Posibles motivos:

- La carga es demasiado baja para superar el 60 % en media. Aumentar `-c`.
- El test dura menos de 3 min (la alarma necesita 3 datapoints de 1 min).
- Las instancias son `t3.micro` y agotan créditos de CPU (la métrica
  `CPUCreditBalance` permite verificarlo).

### 5.3 El scale-in no se produce tras detener la carga

El ASG aplica un cooldown por defecto de 300 s. Si pasa ese tiempo y
sigue sin escalar hacia abajo, comprobar que `AlarmLow` está en `OK` y
que ninguna otra alarma fuerza el `DesiredCapacity`. Forzar manualmente:

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name asg-glpi-dracs \
  --desired-capacity 2 \
  --honor-cooldown false \
  --region us-east-1
```

## 6. Limpieza tras el test

El test no deja recursos persistentes; basta con detener `ab` y esperar
al scale-in. Si conviene dejar la infraestructura en estado conocido:

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name asg-glpi-dracs \
  --desired-capacity 2 \
  --region us-east-1
```

## 7. Referencias

- Política definida en `glpi_scaling.tf` (recurso
  `aws_autoscaling_policy.cpu_target`).
- ALB y target group definidos en `glpi_scaling.tf`.
- Resumen general del escalado: `INFRAESTRUCTURA.md` § Auto Scaling.
- Operativa de Session Manager: `G2-A-64` / `docs/aws/AWS-RUNBOOK.md`.
