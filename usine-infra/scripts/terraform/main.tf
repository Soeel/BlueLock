terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.14"
    }
  }
}

provider "proxmox" {
  pm_api_url          = "https://192.168.1.24:8006/api2/json"
  pm_api_token_id     = "Basile@pve!blue-lock"
  pm_api_token_secret = "9bb137da-4002-4df9-89a4-6dcba23925bf"
  pm_tls_insecure     = true
}

locals {
  # Configuration des VM selon vos besoins
  vms = {
    "SRV-DC1" = {
      template = "template-wserv2016"
      memory   = 4096
      cores    = 2
      disk     = "40G"
    },
    "SRV-FILESAPP" = {
      template = "template-wserv2016"
      memory   = 4096
      cores    = 2
      disk     = "40G" # Correspond aux 40 Go demandés 
    },
    "SRV-SCADABR" = {
      template = "template-rocky8"
      memory   = 2048
      cores    = 2
      disk     = "32G"
    },
    "SRV-WEB" = {
      template = "template-debian12"
      memory   = 2048
      cores    = 1
      disk     = "20G"
    }
  }
}

resource "proxmox_vm_qemu" "infrastructure" {
  for_each    = local.vms
  name        = each.key
  target_node = "pve" # Remplacez par le nom de votre nœud (souvent 'pve')
  clone       = each.value.template
  full_clone  = true # Important pour l'industrialisation [cite: 38]

  cores   = each.value.cores
  memory  = each.value.memory
  agent   = 1 # Requis pour récupérer l'IP et l'état de la VM

  disk {
    size    = each.value.disk
    type    = "scsi"
    storage = "local-lvm" # Modifiez selon votre stockage Proxmox
  }

  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Optionnel : définit l'ordre de démarrage
  boot = "order=scsi0"
}
