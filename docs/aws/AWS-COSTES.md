# Costes AWS — estimación mensual

Este documento estima el coste mensual de las dos versiones de la infraestructura AWS del proyecto DRACS: la arquitectura inicial monolítica (`simple/`) y la arquitectura actual multi-AZ con ASG, RDS y EFS. Los precios corresponden a la región **us-east-1** (N. Virginia) en modalidad **On-Demand** sin reservas, que es la que aplica en el entorno AWS Academy.

> **Nota:** las cifras son estimaciones basadas en precios publicados. El coste real puede variar según el tráfico de red, el uso de los LCUs del ALB/NLB y el tamaño de los datos en EFS. AWS Academy asigna 100 $ de crédito por laboratorio.

# 1. Arquitectura simple (Sprint 2)

---

Tres EC2 en una sola subnet pública, sin balanceadores, sin RDS ni EFS. Todo el estado de GLPI (BD + ficheros) vive en el disco EBS de la instancia GLPI.

| Recurso | Tipo / Tamaño | Precio unitario | Unidades | Coste estimado |
| --- | --- | --- | --- | --- |
| EC2 WireGuard | t3.micro | 0,0104 $/h | 730 h | 7,59 $ |
| EC2 Nginx | t3.micro | 0,0104 $/h | 730 h | 7,59 $ |
| EC2 GLPI | t3.small | 0,0208 $/h | 730 h | 15,18 $ |
| EBS WireGuard | gp3 20 GB | 0,08 $/GB | 20 GB | 1,60 $ |
| EBS Nginx | gp3 20 GB | 0,08 $/GB | 20 GB | 1,60 $ |
| EBS GLPI | gp3 30 GB | 0,08 $/GB | 30 GB | 2,40 $ |
| NAT Gateway (horas) | 1 GW en subnet pública | 0,045 $/h | 730 h | 32,85 $ |
| NAT Gateway (datos) | ~10 GB/mes | 0,045 $/GB | 10 GB | 0,45 $ |
| EIPs (×2 + NAT) | WG + Nginx + NAT | 0,00 $ (adjuntas) | — | 0,00 $ |
| S3 tfstate | < 1 MB | despreciable | — | ~0,01 $ |
| **Total mensual** | | | | **~69,29 $** |

> **Nota:** aunque todas las instancias están en una subnet pública y tienen IP pública propia, se incluyó un NAT Gateway para disponer de un punto de salida centralizado y consistente con el patrón de la arquitectura final. El NAT Gateway es el componente más caro de esta versión, representando el 47 % del total mensual.

![](aws-simple-costes.png){width=900px}
<!-- captura: AWS Console → Billing → Cost Explorer → filtrar por servicio, periodo Sprint 2 -->

# 2. Arquitectura actual — multi-AZ (Sprint 3)

---

Stack completo: ASG + ALB + NLB en capa de red, RDS y EFS como capa de datos persistente, NAT Gateway para que las instancias privadas puedan salir a internet. La mayor parte del sobrecoste respecto a la versión simple proviene del NAT Gateway y de los dos balanceadores.

| Recurso | Tipo / Tamaño | Precio unitario | Unidades | Coste estimado |
| --- | --- | --- | --- | --- |
| EC2 WireGuard | t3.micro | 0,0104 $/h | 730 h | 7,59 $ |
| EC2 Nginx | t3.micro | 0,0104 $/h | 730 h | 7,59 $ |
| EC2 GLPI (ASG, desired=2) | t3.small | 0,0208 $/h | 1460 h | 30,37 $ |
| EBS WireGuard | gp3 30 GB | 0,08 $/GB | 30 GB | 2,40 $ |
| EBS Nginx | gp3 30 GB | 0,08 $/GB | 30 GB | 2,40 $ |
| EBS GLPI | gp3 20 GB | 0,08 $/GB | 20 GB | 1,60 $ |
| RDS MariaDB | db.t3.micro | 0,017 $/h | 730 h | 12,41 $ |
| RDS Storage | gp3 20 GB | 0,115 $/GB | 20 GB | 2,30 $ |
| EFS Standard | ~5 GB (uploads + crypt key) | 0,30 $/GB | 5 GB | 1,50 $ |
| ALB | — | 0,008 $/h | 730 h | 5,84 $ |
| NLB | — | 0,008 $/h | 730 h | 5,84 $ |
| NAT Gateway (horas) | 1 GW | 0,045 $/h | 730 h | 32,85 $ |
| NAT Gateway (datos) | ~10 GB/mes | 0,045 $/GB | 10 GB | 0,45 $ |
| EIPs (×3) | NLB + WG + Nginx | 0,00 $ (adjuntas) | — | 0,00 $ |
| S3 tfstate | < 1 MB | despreciable | — | ~0,05 $ |
| DynamoDB lock | PAY_PER_REQUEST | despreciable | — | ~0,01 $ |
| **Total mensual** | | | | **~113,25 $** |

> **Nota:** desde Sprint 2 el default de `asg_desired` es **2** (una instancia por AZ), que es la cifra reflejada en la tabla. Si se baja a 1 (`-var asg_desired=1`) se ahorran ~15 $/mes. Si se sube a 3 por una punta de carga, se suman otros ~15 $/mes por cada instancia adicional. El NAT Gateway sigue siendo el componente más caro: con `desired=2` representa el 29 % del total mensual aunque el tráfico sea mínimo, por su tarifa fija de horas.

![](aws-nueva-costes.png){width=900px}
<!-- captura: AWS Console → Billing → Cost Explorer → filtrar por servicio, periodo Sprint 3 -->

# 3. Comparativa

---

| Concepto | Arquitectura simple | Arquitectura actual |
| --- | --- | --- |
| Coste mensual estimado | ~69,29 $ | ~113,25 $ |
| Sobrecoste | — | +43,96 $ (+63 %) |
| Alta disponibilidad | No (1 AZ, 1 EC2) | Sí (2 AZs, ASG) |
| Datos persistentes sin la EC2 | No (EBS local) | Sí (RDS + EFS) |
| TLS público (CA válida) | No (autofirmado) | Sí (Let's Encrypt vía ACM) |
| Backups gestionados | No (snapshots manuales) | Sí (RDS, 7 días retención) |
| Escalado | Manual (cambio de tipo) | Automático (ASG min/max) |

El sobrecoste está justificado por las capacidades que añade la arquitectura nueva: si una instancia GLPI muere, el ASG lanza otra en segundos sin perder ni un ticket, porque la BD y los ficheros viven fuera del compute. En la versión simple, la caída de la EC2 GLPI equivale a pérdida de datos hasta el último snapshot EBS manual.

# 4. Alarmas de presupuesto

---

Se han configurado **3 alarmas de CloudWatch** en el laboratorio que notifican por correo (joelsansi4@gmail.com y resto del equipo) cuando el gasto acumulado supera los umbrales:

| Alarma | Umbral | Acción |
| --- | --- | --- |
| Aviso temprano | 25 $ | Notificación — revisar uso |
| Aviso medio | 65 $ | Notificación — considerar reducir `asg_desired` |
| Aviso crítico | 85 $ | Notificación — bajar a desired=0 si el lab no está en uso |

> **Nota:** el crédito de AWS Academy es de 100 $ por laboratorio. Con la arquitectura actual corriendo 24/7 los ~100 $ se consumen en aproximadamente **un mes**. Para laboratorios puntuales conviene bajar el ASG a 0 cuando no se usa (`terraform apply -var asg_desired=0`), lo que elimina el coste de las EC2 GLPI pero mantiene el NAT Gateway corriendo.

# 5. Documentación relacionada

---

* **G2-A-59 — AWS.md** — visión general y decisiones de diseño
* **G2-A-66 — AWS-GLPI.md** — ASG, RDS y EFS (los componentes más costosos de la arquitectura actual)
* **G2-A-62 — AWS-HISTORICO-MONOLITICA.md** — arquitectura previa (la más barata, sin HA)
* **G2-A-64 — AWS-RUNBOOK.md** — cómo bajar el ASG a 0 para ahorrar cuando no se usa
* **G2-A-63 — AWS-TERRAFORM.md** — variables `asg_desired` y `create_ami_backup` que afectan al coste
