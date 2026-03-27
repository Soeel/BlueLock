#!/bin/bash
# =============================================================================
# 01-init-vault.sh
#
# Initialise HashiCorp Vault :
#   - Initialise le cluster Raft (génère les unseal keys + root token)
#   - Descelle Vault (unseal)
#   - Active l'audit log
#   - Sauvegarde les credentials dans secrets/vault-init.json
#
# Usage : ./scripts/01-init-vault.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_FILE="${PKI_DIR}/secrets/vault-init.json"
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_CACERT="${PKI_DIR}/certs/vault.crt"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

export VAULT_ADDR
export VAULT_CACERT

echo -e "${YELLOW}=== Initialisation de HashiCorp Vault ===${NC}"
echo ""

# ── Vérifier que Vault tourne ─────────────────────────────────────────────────
echo "Attente du démarrage de Vault..."
for i in $(seq 1 30); do
    if vault status -format=json 2>/dev/null | grep -q '"initialized"'; then
        break
    fi
    sleep 2
done

# ── Vérifier si déjà initialisé ───────────────────────────────────────────────
INITIALIZED=$(vault status -format=json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['initialized'])" 2>/dev/null || echo "false")

if [ "$INITIALIZED" = "True" ]; then
    echo -e "${YELLOW}Vault déjà initialisé.${NC}"
    echo "Pour déseller (unseal) Vault, utiliser : scripts/02-unseal-vault.sh"
    exit 0
fi

# ── Initialisation ─────────────────────────────────────────────────────────────
echo "Initialisation en cours (5 unseal keys, seuil 3)..."
INIT_OUTPUT=$(vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json)

# Sauvegarder les credentials
mkdir -p "${PKI_DIR}/secrets"
chmod 700 "${PKI_DIR}/secrets"
echo "$INIT_OUTPUT" > "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

echo -e "${GREEN}✓ Vault initialisé.${NC}"
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  CRITIQUE : Sauvegarder ${SECRETS_FILE}${NC}"
echo -e "${RED}║  Ce fichier contient les 5 unseal keys et le root token.    ║${NC}"
echo -e "${RED}║  Sans ces clés, les données Vault sont irrécupérables.      ║${NC}"
echo -e "${RED}║  Stocker sur support chiffré hors ligne.                    ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Unseal (3 clés sur 5 requises) ────────────────────────────────────────────
echo "Déscellement de Vault (unseal)..."
for i in 1 2 3; do
    KEY=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][${i}-1])")
    vault operator unseal "$KEY" > /dev/null
done

echo -e "${GREEN}✓ Vault déscellé.${NC}"

# ── Connexion avec le root token ───────────────────────────────────────────────
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")
vault login "$ROOT_TOKEN" > /dev/null

# ── Activation de l'audit log ─────────────────────────────────────────────────
echo "Activation de l'audit log..."
vault audit enable file file_path=/vault/logs/audit.log 2>/dev/null || true

echo -e "${GREEN}✓ Audit log activé : /vault/logs/audit.log${NC}"
echo ""
echo "Prochaine étape : scripts/02-setup-pki.sh"
