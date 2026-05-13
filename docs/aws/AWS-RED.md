# Red AWS

La capa de red es la base sobre la que se monta todo lo demás. Se ha diseñado una VPC propia con segmentación en subnets pública/privada en dos AZs, un solo NAT Gateway compartido por las privadas (compromiso entre coste y resiliencia) y rutas estáticas hacia las redes on-prem que pasan por la ENI del gateway WireGuard.

# 1. VPC

---

Se ha creado una VPC dedicada (`vpc-dracs`) con CIDR `10.0.0.0/16` para no mezclar nada con la VPC default de la cuenta y tener espacio amplio para crecer.

| Atributo | Valor |
| --- | --- |
| Name | `vpc-dracs` |
| CIDR | `10.0.0.0/16` |
| `enable_dns_hostnames` | `true` (los recursos AWS resuelven DNS interno) |

![](aws-vpc.png){width=900px}
<!-- captura: AWS Console → VPC → Your VPCs → vpc-dracs → Resource map -->

# 2. Subnets

---

Se han creado cuatro subnets, repartiendo en dos AZs para permitir alta disponibilidad de los recursos multi-AZ (ALB, ASG, RDS, EFS).

| Subnet | CIDR | AZ | Tipo | Uso |
| --- | --- | --- | --- | --- |
| `subnet-publica-a-dracs` | `10.0.1.0/24` | `us-east-1a` | Pública | WireGuard EC2 (10.0.1.10), Nginx EC2 (10.0.1.20), NLB, ALB |
| `subnet-publica-b-dracs` | `10.0.3.0/24` | `us-east-1b` | Pública | ALB (segunda AZ) |
| `subnet-privada-a-dracs` | `10.0.2.0/24` | `us-east-1a` | Privada | ASG GLPI (AZ a), mount target EFS, subnet group RDS |
| `subnet-privada-b-dracs` | `10.0.4.0/24` | `us-east-1b` | Privada | ASG GLPI (AZ b), mount target EFS, subnet group RDS |

Las subnets públicas tienen `map_public_ip_on_launch = true` para que cualquier EC2 que se lance dentro reciba IP pública automáticamente.

> **Nota:** ASG, ALB y RDS están registrados en las dos AZs. EFS tiene mount targets en ambas privadas para que cada instancia GLPI monte el de su misma zona y se ahorre el coste de tráfico cross-AZ.

# 3. Internet Gateway y NAT Gateway

---

El Internet Gateway (`igw-dracs`) está adjunto a la VPC y proporciona conectividad bidireccional para las subnets públicas (las EC2 con IP pública pueden recibir tráfico de internet y salir).

Para las subnets privadas se ha desplegado un único **NAT Gateway** en la pública-a (us-east-1a), con una EIP propia. Las instancias GLPI del ASG necesitan salida a internet para descargar Apache, PHP, GLPI tarball, paquetes apt y comunicarse con ACM/SSM. Las dos privadas comparten el mismo NAT.

> **Nota:** poner un único NAT en una AZ es un compromiso intencional. Si se cae us-east-1a, las instancias del ASG en us-east-1b pierden conectividad de salida. La alternativa (un NAT por AZ) duplicaría el coste. Para el alcance del proyecto se asume el compromiso.

# 4. Route Tables

---

Se han definido dos route tables, una para cada tipo de subnet, y se asocian a las subnets correspondientes.

| Route table | Asociadas | Rutas |
| --- | --- | --- |
| `rt-publica-dracs` | publica-a, publica-b | `10.0.0.0/16` → local (implícita); `0.0.0.0/0` → `igw-dracs` |
| `rt-privada-dracs` | privada-a, privada-b | `10.0.0.0/16` → local; `0.0.0.0/0` → `nat-dracs` |

Además, en **ambas** route tables se inyectan rutas hacia las redes on-prem, todas apuntando a la **ENI del gateway WireGuard** (`aws_instance.wireguard.primary_network_interface_id`). Es lo que permite que cualquier recurso de la VPC, sea público o privado, sepa que el tráfico hacia `192.168.x.x` tiene que pasar por esa ENI y no salir por internet.

![](aws-routes.png){width=900px}
<!-- captura: AWS Console → VPC → Route Tables → rt-privada-dracs → Routes tab -->

# 5. Rutas hacia on-prem

---

Las rutas estáticas hacia las redes on-prem se generan con un `for_each` sobre una lista local de CIDRs, evitando duplicar bloques en Terraform:

```hcl
locals {
  onprem_cidrs = ["192.168.1.0/24", "192.168.10.0/24", "192.168.20.0/24"]
}

resource "aws_route" "onprem_public" {
  for_each               = toset(local.onprem_cidrs)
  route_table_id         = aws_route_table.publica.id
  destination_cidr_block = each.value
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}

resource "aws_route" "onprem_private" {
  for_each               = toset(local.onprem_cidrs)
  route_table_id         = aws_route_table.privada.id
  destination_cidr_block = each.value
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}
```

Esto cubre todas las VLANs on-prem que tienen que ser alcanzables desde AWS (gestión 192.168.1.0/24, servidores 192.168.10.0/24, clientes 192.168.20.0/24).

**Flujo completo de un paquete del ASG hacia el DC on-prem:**

1. Instancia GLPI (en `10.0.4.218`, privada-b) hace `tcp/389` hacia `192.168.10.10`.
2. La route table `rt-privada-dracs` matchea `192.168.10.0/24` → ENI del WireGuard EC2.
3. El paquete sale por la ENI hacia el WG EC2 (que tiene `source_dest_check = false` y puede aceptar tráfico no destinado a él).
4. El WG EC2 lo enruta a `wg0` (interfaz WireGuard), lo encapsula y lo manda al peer de OPNsense via UDP/51820.
5. OPNsense lo desencapsula, comprueba sus reglas pf, y lo entrega al DC.

> **Nota:** para que la respuesta vuelva, OPNsense necesita tener en su peer de WireGuard el AllowedIPs cubriendo `10.0.0.0/16` (o las subnets privadas) y una ruta estática hacia esa red por su gateway WireGuard. Ver el sub-artículo `G2-A-53` de OPNsense.

# 6. Documentación relacionada

---

* **AWS.md** — visión general y decisiones de diseño
* **AWS-VPN.md** — cómo está montado el gateway WireGuard hacia el que apuntan las rutas on-prem
* **AWS-SEGURIDAD.md** — Security Groups que se aplican sobre estas subnets
