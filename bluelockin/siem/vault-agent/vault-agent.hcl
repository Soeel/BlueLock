exit_after_auth = true
pid_file        = "/tmp/vault-agent.pid"

vault {
  address = "http://bluelock-pki:8200"
}

# --- TEMPLATES CONFIGURATION ---

# 1. Génération du Certificat + Chaîne CA
template {
  contents     = <<EOH
{{- with secret "pki/issue/bastion-role" "common_name=siem.blue.local" "ttl=720h" -}}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{- end -}}
EOH
  destination  = "/etc/nginx/certs/siem.crt"
}

# 2. Génération de la Clé Privée
template {
  contents     = <<EOH
{{- with secret "pki/issue/bastion-role" "common_name=siem.blue.local" "ttl=720h" -}}
{{ .Data.private_key }}
{{- end -}}
EOH
  destination  = "/etc/nginx/certs/siem.key"
}