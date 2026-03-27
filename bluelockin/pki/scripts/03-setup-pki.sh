#!/bin/bash
# =============================================================================
# 03-setup-pki.sh
#
# Configure la PKI deux niveaux dans Vault :
#
#   Mount pki/      → Root CA (TTL 10 ans)
#                     Utilisé uniquement pour signer l'Intermediate CA.
#                     Désactivé ensuite (équivalent "offline").
#
#   Mount pki_int/  → Intermediate CA (TTL 5 ans)
#                     Signe les certificats des services au quotidien.
#
# Crée également les rôles d'émission et les policies d'accès.
#
# Usage : ./scripts/03-setup-pki.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_FILE="${PKI_DIR}/secrets/vault-init.json"
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_CACERT="${PKI_DIR}/certs/vault.crt"
DOMAIN="${VAULT_DOMAIN:-bluelock.local}"
CERTS_DIR="${PKI_DIR}/certs"

export VAULT_ADDR
export VAULT_CACERT

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Authentification ───────────────────────────────────────────────────────────
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${SECRETS_FILE}'))['root_token'])")
export VAULT_TOKEN="$ROOT_TOKEN"

echo -e "${YELLOW}=== Configuration PKI BlueLock ===${NC}"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 1. ROOT CA (mount pki/)
# ──────────────────────────────────────────────────────────────────────────────
echo "1/5 — Activation du mount Root CA (pki/)..."
vault secrets enable -path=pki pki 2>/dev/null || echo "  (déjà activé)"
vault secrets tune -max-lease-ttl=87600h pki  # 10 ans

echo "2/5 — Génération du Root CA..."
ROOT_CERT_OUTPUT=$(vault write -format=json pki/root/generate/internal \
    common_name="BlueLock Root CA" \
    organization="BlueLock" \
    country="FR" \
    ttl=87600h \
    key_type=rsa \
    key_bits=4096)

# Exporter le certificat Root CA
echo "$ROOT_CERT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['certificate'])" \
    > "${CERTS_DIR}/root_ca.crt"
echo -e "${GREEN}  ✓ Root CA généré → ${CERTS_DIR}/root_ca.crt${NC}"

# Configurer les URLs CRL et OCSP du Root CA
vault write pki/config/urls \
    issuing_certificates="${VAULT_ADDR}/v1/pki/ca" \
    crl_distribution_points="${VAULT_ADDR}/v1/pki/crl"

# ──────────────────────────────────────────────────────────────────────────────
# 2. INTERMEDIATE CA (mount pki_int/)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "3/5 — Activation du mount Intermediate CA (pki_int/)..."
vault secrets enable -path=pki_int pki 2>/dev/null || echo "  (déjà activé)"
vault secrets tune -max-lease-ttl=43800h pki_int  # 5 ans

echo "4/5 — Génération et signature de l'Intermediate CA..."
INT_CSR=$(vault write -format=json pki_int/intermediate/generate/internal \
    common_name="BlueLock Intermediate CA" \
    organization="BlueLock" \
    country="FR" \
    key_type=rsa \
    key_bits=4096 \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['csr'])")

# Signer le CSR avec le Root CA
INT_CERT=$(vault write -format=json pki/root/sign-intermediate \
    csr="$INT_CSR" \
    common_name="BlueLock Intermediate CA" \
    ttl=43800h \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['certificate'])")

# Injecter le certificat signé dans pki_int
vault write pki_int/intermediate/set-signed certificate="$INT_CERT"

# Configurer les URLs CRL de l'Intermediate CA
vault write pki_int/config/urls \
    issuing_certificates="${VAULT_ADDR}/v1/pki_int/ca" \
    crl_distribution_points="${VAULT_ADDR}/v1/pki_int/crl" \
    ocsp_servers="${VAULT_ADDR}/v1/pki_int/ocsp"

echo -e "${GREEN}  ✓ Intermediate CA configuré.${NC}"

# ──────────────────────────────────────────────────────────────────────────────
# 3. RÔLES D'ÉMISSION
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "5/5 — Création des rôles d'émission..."

# Rôle pour les services internes (SIEM, bastion, agents)
vault write pki_int/roles/bluelock-services \
    allowed_domains="${DOMAIN}" \
    allow_subdomains=true \
    allow_ip_sans=true \
    max_ttl=8760h \
    key_type=rsa \
    key_bits=2048 \
    require_cn=true

# Rôle pour les agents de collecte (Filebeat/Winlogbeat) — client auth
vault write pki_int/roles/bluelock-agents \
    allowed_domains="${DOMAIN}" \
    allow_subdomains=true \
    client_flag=true \
    server_flag=false \
    max_ttl=8760h \
    key_type=rsa \
    key_bits=2048

echo -e "${GREEN}  ✓ Rôles créés : bluelock-services, bluelock-agents${NC}"

# ──────────────────────────────────────────────────────────────────────────────
# 4. POLICIES D'ACCÈS
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "Création des policies Vault..."

# Policy : émettre des certificats serveur
vault policy write pki-issue - <<'POLICY'
path "pki_int/issue/bluelock-services" {
  capabilities = ["create", "update"]
}
path "pki_int/sign/bluelock-services" {
  capabilities = ["create", "update"]
}
path "pki_int/issue/bluelock-agents" {
  capabilities = ["create", "update"]
}
path "pki_int/crl/rotate" {
  capabilities = ["create", "update"]
}
path "pki_int/tidy" {
  capabilities = ["create", "update"]
}
POLICY

echo -e "${GREEN}  ✓ Policy 'pki-issue' créée.${NC}"

# ──────────────────────────────────────────────────────────────────────────────
# 5. DÉSACTIVATION DU ROOT CA (mise hors ligne)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Le Root CA (mount pki/) peut être mis hors ligne.${NC}"
echo "Il n'est plus nécessaire pour les émissions quotidiennes."
read -r -p "Désactiver le mount Root CA maintenant ? [o/N] " confirm
if [[ "$confirm" == "o" || "$confirm" == "O" ]]; then
    vault secrets disable pki
    echo -e "${GREEN}✓ Root CA désactivé (hors ligne). Réactiver uniquement pour renouveler l'Intermediate CA.${NC}"
fi

echo ""
echo -e "${GREEN}=== PKI BlueLock configurée ===${NC}"
echo ""
echo "Root CA exporté      : ${CERTS_DIR}/root_ca.crt"
echo "Vault UI             : ${VAULT_ADDR}/ui"
echo ""
echo "Prochaines étapes :"
echo "  → Distribuer ${CERTS_DIR}/root_ca.crt sur VM1 : scripts/05-trust-root-ca.sh"
echo "  → Émettre les certificats des services       : scripts/04-issue-cert.sh"
