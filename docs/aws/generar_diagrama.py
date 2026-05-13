#!/usr/bin/env python3
"""
Genera el diagrama de arquitectura AWS de DRACS.
Output: docs/aws/aws-arquitectura.png

Requiere:
  sudo apt install -y graphviz
  python3 -m pip install diagrams
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EC2, AutoScaling
from diagrams.aws.database import RDS, Dynamodb
from diagrams.aws.network import (
    ALB,
    NLB,
    InternetGateway,
    NATGateway,
)
from diagrams.aws.storage import S3, EFS
from diagrams.generic.network import Firewall
from diagrams.onprem.client import Users

GRAPH_ATTRS = {
    "fontsize": "13",
    "bgcolor": "white",
    "pad": "0.5",
    "splines": "ortho",
    "nodesep": "0.6",
    "ranksep": "0.8",
}

with Diagram(
    "DRACS — Arquitectura AWS",
    filename="docs/aws/aws-arquitectura",
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=GRAPH_ATTRS,
):
    internet = Users("Internet\ndracs-glpi.duckdns.org")
    onprem   = Firewall("OPNsense on-prem\n192.168.x.x")

    with Cluster("AWS — VPC vpc-dracs (10.0.0.0/16)"):

        igw = InternetGateway("IGW")
        nat = NATGateway("NAT GW")

        with Cluster("Subnets públicas"):
            wg    = EC2("WireGuard EC2\n10.0.1.10\nEIP 34.204.119.208")
            nginx = EC2("Nginx EC2\n10.0.1.20\nEIP 34.205.176.217")

        nlb = NLB("NLB\nEIP 50.19.112.122\nTCP 80/443")
        alb = ALB("ALB\nHTTP→HTTPS redirect\nTLS ACM (Let's Encrypt)")

        with Cluster("Subnets privadas — multi-AZ"):
            with Cluster("us-east-1a  10.0.2.x"):
                glpi_a = EC2("GLPI ASG\nt3.small\nUbuntu 24.04")
            with Cluster("us-east-1b  10.0.4.x"):
                glpi_b = EC2("GLPI ASG\nt3.small\nUbuntu 24.04")
            asg = AutoScaling("ASG asg-glpi-dracs\nmin=0 / max=3")

        with Cluster("Capa de datos"):
            rds = RDS("RDS MariaDB 10.11\nrds-glpi-dracs\ndb.t3.micro")
            efs = EFS("EFS\nfs-0e3a12b50ac2f89b3\n/files + glpicrypt.key")

        with Cluster("State remoto"):
            s3    = S3("S3\ndracs-tfstate-*\ndracs-backups-*")
            dyndb = Dynamodb("DynamoDB\ndracs-tfstate-lock")

    # Flujo internet
    internet >> nlb >> alb
    alb >> glpi_a
    alb >> glpi_b

    # Flujo VPN / on-prem
    onprem >> Edge(label="WireGuard\n10.8.0.0/24") >> wg
    nginx   >> Edge(label="proxy_pass ALB") >> alb

    # Instancias → datos
    glpi_a >> rds
    glpi_b >> rds
    glpi_a >> efs
    glpi_b >> efs

    # ASG gestiona instancias (lógico)
    asg - Edge(style="dashed") - glpi_a
    asg - Edge(style="dashed") - glpi_b

    # Salida privadas → internet via NAT
    glpi_a >> Edge(style="dotted", label="egress") >> nat >> igw

    # State
    s3 - dyndb
