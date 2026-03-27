# =============================================================================
# Vault Agent — SIEM BlueLock (VM1)
#
# Se connecte à Vault sur VM2, s'authentifie via AppRole,
# et maintient à jour les certificats TLS pour Elasticsearch et Kibana.
# Les certs sont renouvelés automatiquement avant expiration.
# =============================================================================

vault {
  address = "https://VAULT_VM2_IP:8200"   # Remplacé par 01-setup-agent.sh
  ca_cert = "/vault/certs/root_ca.crt"
  retry {
    num_retries = 10
  }
}

# ── Authentification AppRole ───────────────────────────────────────────────────
auto_auth {
  method "approle" {
    config = {
      role_id_file_path             = "/vault/auth/role_id"
      secret_id_file_path           = "/vault/auth/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/tmp/vault-token"
    }
  }
}

# ── Root CA → volume siem-certs ───────────────────────────────────────────────
template {
  contents    = "{{ file \"/vault/certs/root_ca.crt\" }}"
  destination = "/certs/root_ca.crt"
  perms       = 0644
}

# ── Elasticsearch : certificat + chaîne ───────────────────────────────────────
template {
  contents = <<EOT
{{- with pkiCert "pki_int/issue/bluelock-services" "common_name=elasticsearch.bluelock.local" "ttl=720h" -}}
{{ .Cert }}
{{ .CA }}
{{- end }}
EOT
  destination = "/certs/elasticsearch/cert.pem"
  perms       = 0644
}

# ── Elasticsearch : clé privée ────────────────────────────────────────────────
template {
  contents = <<EOT
{{- with pkiCert "pki_int/issue/bluelock-services" "common_name=elasticsearch.bluelock.local" "ttl=720h" -}}
{{ .Key }}
{{- end }}
EOT
  destination = "/certs/elasticsearch/key.pem"
  perms       = 0640
}

# ── Kibana : certificat + chaîne ──────────────────────────────────────────────
template {
  contents = <<EOT
{{- with pkiCert "pki_int/issue/bluelock-services" "common_name=kibana.bluelock.local" "ttl=720h" -}}
{{ .Cert }}
{{ .CA }}
{{- end }}
EOT
  destination = "/certs/kibana/cert.pem"
  perms       = 0644
}

# ── Kibana : clé privée ───────────────────────────────────────────────────────
template {
  contents = <<EOT
{{- with pkiCert "pki_int/issue/bluelock-services" "common_name=kibana.bluelock.local" "ttl=720h" -}}
{{ .Key }}
{{- end }}
EOT
  destination = "/certs/kibana/key.pem"
  perms       = 0640
}
