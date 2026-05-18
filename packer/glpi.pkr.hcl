packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  default = "us-east-1"
}

variable "glpi_version" {
  default = "10.0.18"
}

source "amazon-ebs" "glpi" {
  region        = var.region
  instance_type = "t3.small"
  ssh_username  = "ubuntu"
  ami_name      = "glpi-base-${var.glpi_version}-{{timestamp}}"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name    = "glpi-base"
    Version = var.glpi_version
    Builder = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.glpi"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "DEBIAN_FRONTEND=noninteractive sudo apt-get install -y apache2 nfs-common mariadb-client php php-mysql php-curl php-gd php-intl php-ldap php-mbstring php-xml php-xmlrpc php-zip php-bz2 php-imap php-apcu",
      "sudo a2enmod rewrite",

      # Descargar y extraer GLPI
      "cd /tmp && sudo wget -q --timeout=60 --tries=3 https://github.com/glpi-project/glpi/releases/download/${var.glpi_version}/glpi-${var.glpi_version}.tgz",
      "sudo tar -xzf /tmp/glpi-${var.glpi_version}.tgz -C /var/www/html/",
      "sudo chown -R www-data:www-data /var/www/html/glpi",
      "sudo chmod -R 755 /var/www/html/glpi",
      "sudo rm -f /tmp/glpi-${var.glpi_version}.tgz",

      # VirtualHost Apache
      "echo '<VirtualHost *:80>\n    DocumentRoot /var/www/html/glpi\n    <Directory /var/www/html/glpi>\n        Options FollowSymLinks\n        AllowOverride All\n        Require all granted\n    </Directory>\n    ErrorLog /var/log/apache2/glpi_error.log\n    CustomLog /var/log/apache2/glpi_access.log combined\n</VirtualHost>' | sudo tee /etc/apache2/sites-available/glpi.conf",
      "sudo a2ensite glpi.conf",
      "sudo a2dissite 000-default.conf",
      "sudo apache2ctl configtest",

      # No arrancar Apache en el AMI; cloud-init lo arranca tras configurar la BD
      "sudo systemctl disable apache2",
      "sudo apt-get clean"
    ]
  }
}
