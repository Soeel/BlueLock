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
CONTAINER="bluelock-vault"
# Vault écoute en loopback dans le container, on y accède via docker exec
VAULT_EXEC="docker exec ${CONTAINER} vault"
VAULT_ENV="-e VAULT_ADDR=https://127.0.0.1:8200 -e VAULT_CACERT=/vault/certs/vault.crt"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}=== Initialisation de HashiCorp Vault ===${NC}"
echo ""

# ── Vérifier que le container tourne ─────────────────────────────────────────
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo -e "${RED}Erreur : le container '${CONTAINER}' n'est pas démarré.${NC}"
    echo "Lancer : docker compose up -d"
    exit 1
fi

# ── Attendre que Vault réponde ────────────────────────────────────────────────
# vault status exit code 2 = sealed (normal), 1 = erreur, 0 = ok
# On capture dans une variable avec || true pour éviter l'échec du pipeline
echo "Attente du démarrage de Vault..."
for i in $(seq 1 30); do
    STATUS=$(docker exec \
        -e VAULT_ADDR=https://127.0.0.1:8200 \
        -e VAULT_CACERT=/vault/certs/vault.crt \
        "${CONTAINER}" vault status 2>&1 || true)
    if echo "$STATUS" | grep -q "Initialized"; then
        break
    fi
    echo "  (tentative ${i}/30)..."
    sleep 3
done

# ── Vérifier si déjà initialisé ───────────────────────────────────────────────
STATUS_JSON=$(docker exec \
    -e VAULT_ADDR=https://127.0.0.1:8200 \
    -e VAULT_CACERT=/vault/certs/vault.crt \
    "${CONTAINER}" vault status -format=json 2>/dev/null || true)
INITIALIZED=$(echo "$STATUS_JSON" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('initialized','false'))" 2>/dev/null || echo "false")

if [ "$INITIALIZED" = "True" ] || [ "$INITIALIZED" = "true" ]; then
    echo -e "${YELLOW}Vault déjà initialisé.${NC}"
    echo "Pour désceller après redémarrage : scripts/02-unseal-vault.sh"
    exit 0
fi

# ── Initialisation ─────────────────────────────────────────────────────────────
echo "Initialisation (5 unseal keys, seuil 3)..."
INIT_OUTPUT=$(docker exec \
    -e VAULT_ADDR=https://127.0.0.1:8200 \
    -e VAULT_CACERT=/vault/certs/vault.crt \
    "${CONTAINER}" vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json)

# Sauvegarder les credentials sur l'hôte
mkdir -p "${PKI_DIR}/secrets"
chmod 700 "${PKI_DIR}/secrets"
echo "$INIT_OUTPUT" > "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

echo -e "${GREEN}✓ Vault initialisé.${NC}"
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  CRITIQUE : Sauvegarder ${SECRETS_FILE}  ${NC}"
echo -e "${RED}║  Ce fichier contient les 5 unseal keys et le root token.    ║${NC}"
echo -e "${RED}║  Sans ces clés, les données Vault sont irrécupérables.      ║${NC}"
echo -e "${RED}║  Stocker sur support chiffré hors ligne.                    ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Unseal (3 clés sur 5 requises) ────────────────────────────────────────────
echo "Déscellement de Vault (unseal)..."
for i in 1 2 3; do
    KEY=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][${i}-1])")
    docker exec \
        -e VAULT_ADDR=https://127.0.0.1:8200 \
        -e VAULT_CACERT=/vault/certs/vault.crt \
        "${CONTAINER}" vault operator unseal "$KEY" > /dev/null
done
echo -e "${GREEN}✓ Vault déscellé.${NC}"

# ── Activation de l'audit log ─────────────────────────────────────────────────
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")
docker exec \
    -e VAULT_ADDR=https://127.0.0.1:8200 \
    -e VAULT_CACERT=/vault/certs/vault.crt \
    -e VAULT_TOKEN="$ROOT_TOKEN" \
    "${CONTAINER}" vault audit enable file file_path=/vault/logs/audit.log 2>/dev/null || true

echo -e "${GREEN}✓ Audit log activé.${NC}"
echo ""
echo "Prochaine étape : scripts/03-setup-pki.sh"
