#!/bin/bash
# =============================================================================
# 05-create-siem-approle.sh
#
# Crée un AppRole Vault dédié au SIEM (VM1).
# Vault Agent sur VM1 l'utilisera pour s'authentifier et récupérer
# automatiquement les certificats TLS pour Elasticsearch et Kibana.
#
# Usage : ./scripts/05-create-siem-approle.sh
# Sortie : role_id et secret_id à copier sur VM1
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_FILE="${PKI_DIR}/secrets/vault-init.json"
CONTAINER="bluelock-vault"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${SECRETS_FILE}'))['root_token'])")

vault_exec() {
    docker exec \
        -e VAULT_ADDR=https://127.0.0.1:8200 \
        -e VAULT_CACERT=/vault/certs/vault.crt \
        -e VAULT_TOKEN="$ROOT_TOKEN" \
        "${CONTAINER}" vault "$@"
}

echo -e "${YELLOW}=== Création de l'AppRole SIEM ===${NC}"

# Activer AppRole si pas déjà fait
vault_exec auth enable approle 2>/dev/null || echo "  (AppRole déjà activé)"

# Créer le rôle siem avec la policy pki-issue
vault_exec write auth/approle/role/siem \
    token_policies="pki-issue" \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=0 \
    secret_id_num_uses=0

# Récupérer le role_id
ROLE_ID=$(vault_exec read -format=json auth/approle/role/siem/role-id \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['role_id'])")

# Générer un secret_id
SECRET_ID=$(vault_exec write -format=json -f auth/approle/role/siem/secret-id \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['secret_id'])")

echo ""
echo -e "${GREEN}✓ AppRole SIEM créé.${NC}"
echo ""
echo "══════════════════════════════════════════════════════"
echo " À copier sur VM1 pour configurer le Vault Agent SIEM"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  ROLE_ID   : ${ROLE_ID}"
echo "  SECRET_ID : ${SECRET_ID}"
echo ""
echo "Sur VM1 (dans bluelockin/siem/) :"
echo "  ./scripts/01-setup-agent.sh ${ROLE_ID} ${SECRET_ID}"
echo ""
echo "Ne pas oublier de copier aussi le Root CA :"
echo "  scp ${PKI_DIR}/certs/root_ca.crt root@VM1:/opt/bluelock/siem/vault-agent/certs/"
