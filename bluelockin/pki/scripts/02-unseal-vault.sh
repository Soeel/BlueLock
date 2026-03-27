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
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_CACERT="${PKI_DIR}/certs/vault.crt"

export VAULT_ADDR
export VAULT_CACERT

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ ! -f "$SECRETS_FILE" ]; then
    echo "Erreur : ${SECRETS_FILE} introuvable."
    echo "Vault a-t-il été initialisé ? (scripts/01-init-vault.sh)"
    exit 1
fi

SEALED=$(vault status -format=json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])" 2>/dev/null || echo "true")

if [ "$SEALED" = "False" ]; then
    echo -e "${GREEN}Vault est déjà déscellé.${NC}"
    exit 0
fi

echo -e "${YELLOW}Déscellement de Vault...${NC}"
for i in 1 2 3; do
    KEY=$(python3 -c "import sys,json; d=json.load(open('${SECRETS_FILE}')); print(d['unseal_keys_b64'][${i}-1])")
    vault operator unseal "$KEY" > /dev/null
done

echo -e "${GREEN}✓ Vault déscellé.${NC}"
