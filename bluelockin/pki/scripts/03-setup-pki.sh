#!/bin/bash
# =============================================================================
# 03-setup-pki.sh
#
# Configure la PKI deux niveaux dans Vault via docker exec :
#
#   Mount pki/      → Root CA (TTL 10 ans)
#   Mount pki_int/  → Intermediate CA (TTL 5 ans, signe les services)
#
# Usage : ./scripts/03-setup-pki.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_FILE="${PKI_DIR}/secrets/vault-init.json"
CONTAINER="bluelock-vault"
DOMAIN="${VAULT_DOMAIN:-bluelock.local}"
VAULT_HOST_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Wrapper : exécute une commande vault dans le container avec auth
vault_exec() {
    ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${SECRETS_FILE}'))['root_token'])")
    docker exec \
        -e VAULT_ADDR=https://127.0.0.1:8200 \
        -e VAULT_CACERT=/vault/certs/vault.crt \
        -e VAULT_TOKEN="$ROOT_TOKEN" \
        "${CONTAINER}" vault "$@"
}

if [ ! -f "$SECRETS_FILE" ]; then
    echo "Erreur : ${SECRETS_FILE} introuvable. Lancer 01-init-vault.sh d'abord."
    exit 1
fi

echo -e "${YELLOW}=== Configuration PKI BlueLock ===${NC}"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 1. ROOT CA
# ──────────────────────────────────────────────────────────────────────────────
echo "1/5 — Activation du mount Root CA (pki/)..."
vault_exec secrets enable -path=pki pki 2>/dev/null || echo "  (déjà activé)"
vault_exec secrets tune -max-lease-ttl=87600h pki

echo "2/5 — Génération du Root CA..."
ROOT_CERT=$(vault_exec write -format=json pki/root/generate/internal \
    common_name="BlueLock Root CA" \
    organization="BlueLock" \
    country="FR" \
    ttl=87600h \
    key_type=rsa \
    key_bits=4096 \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['certificate'])")

echo "$ROOT_CERT" > "${PKI_DIR}/certs/root_ca.crt"
echo -e "${GREEN}  ✓ Root CA → ${PKI_DIR}/certs/root_ca.crt${NC}"

vault_exec write pki/config/urls \
    issuing_certificates="https://127.0.0.1:8200/v1/pki/ca" \
    crl_distribution_points="https://127.0.0.1:8200/v1/pki/crl"

# ──────────────────────────────────────────────────────────────────────────────
# 2. INTERMEDIATE CA
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "3/5 — Activation du mount Intermediate CA (pki_int/)..."
vault_exec secrets enable -path=pki_int pki 2>/dev/null || echo "  (déjà activé)"
vault_exec secrets tune -max-lease-ttl=43800h pki_int

echo "4/5 — Génération et signature de l'Intermediate CA..."
INT_CSR=$(vault_exec write -format=json pki_int/intermediate/generate/internal \
    common_name="BlueLock Intermediate CA" \
    organization="BlueLock" \
    country="FR" \
    key_type=rsa \
    key_bits=4096 \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['csr'])")

INT_CERT=$(vault_exec write -format=json pki/root/sign-intermediate \
    csr="$INT_CSR" \
    common_name="BlueLock Intermediate CA" \
    ttl=43800h \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['certificate'])")

vault_exec write pki_int/intermediate/set-signed certificate="$INT_CERT"

vault_exec write pki_int/config/urls \
    issuing_certificates="https://127.0.0.1:8200/v1/pki_int/ca" \
    crl_distribution_points="https://127.0.0.1:8200/v1/pki_int/crl" \
    ocsp_servers="https://127.0.0.1:8200/v1/pki_int/ocsp"

echo -e "${GREEN}  ✓ Intermediate CA configuré.${NC}"

# ──────────────────────────────────────────────────────────────────────────────
# 3. RÔLES D'ÉMISSION
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "5/5 — Création des rôles d'émission..."

vault_exec write pki_int/roles/bluelock-services \
    allowed_domains="${DOMAIN}" \
    allow_subdomains=true \
    allow_ip_sans=true \
    max_ttl=8760h \
    key_type=rsa \
    key_bits=2048 \
    require_cn=true

vault_exec write pki_int/roles/bluelock-agents \
    allowed_domains="${DOMAIN}" \
    allow_subdomains=true \
    client_flag=true \
    server_flag=false \
    max_ttl=8760h \
    key_type=rsa \
    key_bits=2048

echo -e "${GREEN}  ✓ Rôles : bluelock-services, bluelock-agents${NC}"

# ──────────────────────────────────────────────────────────────────────────────
# 4. POLICY D'ÉMISSION
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "Création de la policy pki-issue..."
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${SECRETS_FILE}'))['root_token'])")
docker exec -i \
    -e VAULT_ADDR=https://127.0.0.1:8200 \
    -e VAULT_CACERT=/vault/certs/vault.crt \
    -e VAULT_TOKEN="$ROOT_TOKEN" \
    "${CONTAINER}" vault policy write pki-issue - <<'POLICY'
path "pki_int/issue/bluelock-services" {
  capabilities = ["create", "update"]
}
path "pki_int/issue/bluelock-agents" {
  capabilities = ["create", "update"]
}
path "pki_int/sign/bluelock-services" {
  capabilities = ["create", "update"]
}
POLICY
echo -e "${GREEN}  ✓ Policy 'pki-issue' créée.${NC}"

# ──────────────────────────────────────────────────────────────────────────────
# 5. DÉSACTIVATION ROOT CA (mise hors ligne)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Le Root CA (mount pki/) peut être mis hors ligne.${NC}"
read -r -p "Désactiver le mount Root CA maintenant ? [o/N] " confirm
if [[ "$confirm" == "o" || "$confirm" == "O" ]]; then
    vault_exec secrets disable pki
    echo -e "${GREEN}✓ Root CA désactivé (hors ligne).${NC}"
fi

echo ""
echo -e "${GREEN}=== PKI BlueLock configurée ===${NC}"
echo ""
echo "Root CA          : ${PKI_DIR}/certs/root_ca.crt"
echo "Vault UI         : https://$(hostname -I | awk '{print $1}'):8200/ui"
echo ""
echo "Émettre un cert  : scripts/04-issue-cert.sh <service> <dns>"
