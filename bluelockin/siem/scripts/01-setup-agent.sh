#!/bin/bash
# =============================================================================
# 01-setup-agent.sh
#
# Configure les credentials du Vault Agent sur VM1.
# À exécuter après 05-create-siem-approle.sh sur VM2.
#
# Usage : ./scripts/01-setup-agent.sh <role_id> <secret_id> <vault_vm2_ip>
# =============================================================================
set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage : $0 <role_id> <secret_id> <vault_vm2_ip>"
    echo ""
    echo "Ces valeurs sont générées par : (sur VM2)"
    echo "  bluelockin/pki/scripts/05-create-siem-approle.sh"
    exit 1
fi

ROLE_ID="$1"
SECRET_ID="$2"
VAULT_IP="$3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIEM_DIR="$(dirname "$SCRIPT_DIR")"
AUTH_DIR="${SIEM_DIR}/vault-agent/auth"
AGENT_HCL="${SIEM_DIR}/vault-agent/vault-agent.hcl"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Vérifier que root_ca.crt est bien présent
if [ ! -f "${SIEM_DIR}/vault-agent/certs/root_ca.crt" ]; then
    echo -e "${RED}Erreur : root_ca.crt manquant.${NC}"
    echo "Copier depuis VM2 :"
    echo "  scp root@${VAULT_IP}:<pki_dir>/certs/root_ca.crt ${SIEM_DIR}/vault-agent/certs/"
    exit 1
fi

# Enregistrer role_id et secret_id
mkdir -p "$AUTH_DIR"
chmod 700 "$AUTH_DIR"
echo -n "$ROLE_ID"   > "${AUTH_DIR}/role_id"
echo -n "$SECRET_ID" > "${AUTH_DIR}/secret_id"
chmod 600 "${AUTH_DIR}/role_id" "${AUTH_DIR}/secret_id"

# Injecter l'IP de Vault dans la config
sed -i "s|VAULT_VM2_IP|${VAULT_IP}|g" "$AGENT_HCL"

echo -e "${GREEN}✓ Vault Agent configuré.${NC}"
echo ""
echo "Démarrer le SIEM : docker compose up -d"
