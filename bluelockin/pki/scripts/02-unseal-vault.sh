#!/bin/bash
# =============================================================================
# 02-unseal-vault.sh
#
# Déscelle Vault après un redémarrage du container.
# Utilise les unseal keys sauvegardées dans secrets/vault-init.json.
#
# Usage : ./scripts/02-unseal-vault.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_FILE="${PKI_DIR}/secrets/vault-init.json"
CONTAINER="bluelock-vault"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [ ! -f "$SECRETS_FILE" ]; then
    echo -e "${RED}Erreur : ${SECRETS_FILE} introuvable.${NC}"
    echo "Vault a-t-il été initialisé ? (scripts/01-init-vault.sh)"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo -e "${RED}Erreur : le container '${CONTAINER}' n'est pas démarré.${NC}"
    exit 1
fi

STATUS_JSON=$(docker exec \
    -e VAULT_ADDR=https://127.0.0.1:8200 \
    -e VAULT_CACERT=/vault/certs/vault.crt \
    "${CONTAINER}" vault status -format=json 2>/dev/null || true)
SEALED=$(echo "$STATUS_JSON" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed','true'))" 2>/dev/null || echo "true")

if [ "$SEALED" = "False" ] || [ "$SEALED" = "false" ]; then
    echo -e "${GREEN}Vault est déjà déscellé.${NC}"
    exit 0
fi

echo -e "${YELLOW}Déscellement de Vault...${NC}"
for i in 1 2 3; do
    KEY=$(python3 -c "import json; print(json.load(open('${SECRETS_FILE}'))['unseal_keys_b64'][${i}-1])")
    docker exec \
        -e VAULT_ADDR=https://127.0.0.1:8200 \
        -e VAULT_CACERT=/vault/certs/vault.crt \
        "${CONTAINER}" vault operator unseal "$KEY" > /dev/null
done

echo -e "${GREEN}✓ Vault déscellé.${NC}"
