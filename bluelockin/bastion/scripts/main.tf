# bluelockin/bastion/scripts/main.tf

terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0.0"
    }
  }
}

provider "docker" {}

resource "docker_container" "bastion_test" {
  name  = "bastion-guacamole-dev"
  image = "debian:12"
  start = true
  command = ["tail", "-f", "/dev/null"]

  # Automatisation demandée par le projet DIGISEC [cite: 4, 26]
# Automatisation compatible Windows PowerShell
  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = "New-Item -Path '../vault-agent/auth', '../vault-agent/certs' -ItemType Directory -Force"
  }
}