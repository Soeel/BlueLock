#!/bin/bash
# =============================================================================
# 03-trust-root-ca.sh
#
# Installe le certificat Root CA BlueLock comme autorité de confiance
# sur la machine locale (Linux).
# À exécuter sur VM1 (SIEM) et VM2 (Bastion+PKI).
#
# Usage : sudo ./scripts/03-trust-root-ca.sh <chemin/vers/root_ca.crt>
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

if [ $# -lt 1 ]; then
    echo "Usage : sudo $0 <chemin/vers/root_ca.crt>"
    exit 1
fi

ROOT_CERT="$1"

if [ ! -f "$ROOT_CERT" ]; then
    echo -e "${RED}Erreur : fichier introuvable : ${ROOT_CERT}${NC}"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Erreur : ce script doit être exécuté en root (sudo).${NC}"
    exit 1
fi

echo "Installation du Root CA BlueLock..."

# Détecter la distribution
if [ -f /etc/debian_version ]; then
    cp "$ROOT_CERT" /usr/local/share/ca-certificates/bluelock-root-ca.crt
    update-ca-certificates
elif [ -f /etc/redhat-release ]; then
    cp "$ROOT_CERT" /etc/pki/ca-trust/source/anchors/bluelock-root-ca.crt
    update-ca-trust
else
    echo -e "${RED}Distribution non supportée.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Root CA BlueLock installée comme autorité de confiance.${NC}"
echo ""
echo "Vérification :"
echo "  openssl verify -CAfile ${ROOT_CERT} <cert-à-vérifier>.pem"
