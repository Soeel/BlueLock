#!/bin/bash
# =============================================================================
# 00-bootstrap-tls.sh
#
# Génère un certificat TLS auto-signé pour le démarrage initial de Vault.
# Ce certificat bootstrap permet à Vault de démarrer en HTTPS avant que
# la PKI interne soit configurée.
#
# À exécuter UNE SEULE FOIS avant le premier 'docker compose up'.
#
# Usage : ./scripts/00-bootstrap-tls.sh [CN/SAN de la VM2]
# Exemple : ./scripts/00-bootstrap-tls.sh vault.bluelock.local
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$(dirname "$SCRIPT_DIR")/certs"
CN="${1:-vault.bluelock.local}"
VM2_IP="${VAULT_VM_IP:-127.0.0.1}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Génération du certificat TLS bootstrap Vault ===${NC}"

if ! command -v openssl &>/dev/null; then
    echo "Erreur : openssl non installé."
    exit 1
fi

if [ -f "${CERTS_DIR}/vault.crt" ]; then
    echo -e "${YELLOW}Certificat bootstrap déjà existant. Supprimer ${CERTS_DIR}/vault.crt pour régénérer.${NC}"
    exit 0
fi

mkdir -p "$CERTS_DIR"

# Fichier de configuration SAN
cat > /tmp/vault-openssl.cnf <<EOF
[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
O  = BlueLock
CN = ${CN}

[v3_req]
subjectAltName = @alt_names
keyUsage       = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${CN}
DNS.2 = localhost
DNS.3 = vault
IP.1  = 127.0.0.1
IP.2  = ${VM2_IP}
EOF

openssl req -x509 \
    -newkey rsa:4096 \
    -days 825 \
    -nodes \
    -keyout "${CERTS_DIR}/vault.key" \
    -out    "${CERTS_DIR}/vault.crt" \
    -config /tmp/vault-openssl.cnf

chmod 600 "${CERTS_DIR}/vault.key"
chmod 644 "${CERTS_DIR}/vault.crt"
rm -f /tmp/vault-openssl.cnf

echo -e "${GREEN}✓ Certificat bootstrap généré :${NC}"
echo "  ${CERTS_DIR}/vault.crt"
echo "  ${CERTS_DIR}/vault.key"
echo ""
echo "Lancer Vault : docker compose up -d"
echo "Puis         : scripts/01-init-vault.sh"
