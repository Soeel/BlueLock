#!/bin/bash
# =============================================================================
# 01-copy-certs.sh
#
# Copie les certificats émis par la PKI Vault vers le dossier du bastion.
# À exécuter après ../pki/scripts/04-issue-cert.sh bastion bastion.bluelock.local
#
# Usage : ./scripts/01-copy-certs.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASTION_DIR="$(dirname "$SCRIPT_DIR")"
PKI_CERTS="${BASTION_DIR}/../pki/certs/bastion"
DEST="${BASTION_DIR}/certs"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

if [ ! -d "$PKI_CERTS" ]; then
    echo -e "${RED}Erreur : certificats bastion introuvables dans ${PKI_CERTS}${NC}"
    echo "Émettre le cert d'abord :"
    echo "  ../pki/scripts/04-issue-cert.sh bastion bastion.bluelock.local"
    exit 1
fi

mkdir -p "$DEST"
cp "${PKI_CERTS}/cert.pem" "${DEST}/cert.pem"
cp "${PKI_CERTS}/key.pem"  "${DEST}/key.pem"
chmod 644 "${DEST}/cert.pem"
chmod 640 "${DEST}/key.pem"

echo -e "${GREEN}✓ Certificats copiés vers ${DEST}${NC}"
echo "Prochaine étape : scripts/02-init-db.sh"
