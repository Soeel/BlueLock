pid_file = "./vault-agent.pid"

# 1. Point de contact avec votre PKI globale
vault {
  address = "http://host.docker.internal:8200"
}

# 2. Cache obligatoire pour valider la configuration de l'Agent
cache {
  use_auto_auth_token = true
}

# 3. Récupération du Certificat TLS
template {
  source      = "/vault-agent/templates/bastion.crt.tpl"
  destination = "/vault-agent/certs/bastion.crt"
}

# 4. Récupération de la Clé Privée TLS
template {
  source      = "/vault-agent/templates/bastion.key.tpl"
  destination = "/vault-agent/certs/bastion.key"
}