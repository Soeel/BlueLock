# =============================================================================
# Vault Server Configuration — BlueLock PKI
# =============================================================================

# Interface Web (accessible sur https://<VM2-IP>:8200/ui)
ui = true

# ── Stockage ──────────────────────────────────────────────────────────────────
# Raft : stockage intégré hautement disponible, pas de dépendance externe
storage "raft" {
  path    = "/vault/data"
  node_id = "bluelock-vault-1"
}

# ── Listener TLS ──────────────────────────────────────────────────────────────
# Certificat bootstrap auto-signé généré par scripts/00-bootstrap-tls.sh
# Remplacer par un cert signé par la PKI Vault une fois celle-ci configurée
listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/certs/vault.crt"
  tls_key_file  = "/vault/certs/vault.key"

  # Désactiver TLS 1.0 et 1.1
  tls_min_version = "tls12"

  # Logging des requêtes dans vault-logs/
  telemetry {
    unauthenticated_metrics_access = false
  }
}

# ── Adresses du cluster ────────────────────────────────────────────────────────
api_addr     = "https://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"

# ── Logs d'audit ──────────────────────────────────────────────────────────────
# Activé via scripts/01-init-vault.sh après initialisation
# vault audit enable file file_path=/vault/logs/audit.log

# ── Télémétrie ────────────────────────────────────────────────────────────────
telemetry {
  disable_hostname = true
}
