#!/bin/bash
apt update -y
apt upgrade -y
apt install -y wireguard curl net-tools
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf