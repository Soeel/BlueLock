#!/bin/bash
# =============================================================================
# 04-export-root-cert.sh
#
# Exporte le certificat Root CA depuis le container PKI vers ./certs/root_ca.crt
# Nécessaire pour les scripts d'émission et la distribution aux autres VMs.
#
# Usage : ./scripts/04-export-root-cert.sh
# =============================================================================
set -euo pipefail

CONTAINER="bluelock-pki"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT="${PKI_DIR}/certs/root_ca.crt"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo -e "${RED}Erreur : container ${CONTAINER} non démarré.${NC}"
    exit 1
fi

mkdir -p "${PKI_DIR}/certs"
docker cp "${CONTAINER}:/home/step/certs/root_ca.crt" "$OUTPUT"

echo -e "${GREEN}✓ Root CA exportée : ${OUTPUT}${NC}"
echo ""
echo "Transférer ce fichier sur VM1 (SIEM) :"
echo "  scp ${OUTPUT} user@<IP-VM1>:/tmp/bluelock-root-ca.crt"
echo "  ssh user@<IP-VM1> 'sudo /path/to/03-trust-root-ca.sh /tmp/bluelock-root-ca.crt'"
