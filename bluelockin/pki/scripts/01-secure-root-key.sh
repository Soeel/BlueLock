#!/bin/bash
# =============================================================================
# 01-secure-root-key.sh
#
# À exécuter UNE SEULE FOIS après le premier démarrage de la PKI.
# Extrait la clé Root CA du container et la met hors ligne.
#
# Usage : ./scripts/01-secure-root-key.sh [dossier_backup]
# =============================================================================
set -euo pipefail

CONTAINER="bluelock-pki"
BACKUP_DIR="${1:-./root-ca-offline}"

# Couleurs
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${YELLOW}=== Sécurisation de la Root CA ===${NC}"
echo ""

# Vérifier que le container tourne
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo -e "${RED}Erreur : le container ${CONTAINER} n'est pas en cours d'exécution.${NC}"
    echo "Démarrer la PKI avec : docker compose up -d"
    exit 1
fi

# Attendre que la PKI soit initialisée
echo "Attente de l'initialisation de la PKI..."
until docker exec "$CONTAINER" test -f /home/step/certs/root_ca.crt 2>/dev/null; do
    sleep 2
done

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# Extraire root cert + root key chiffrée
echo "Extraction de la Root CA..."
docker cp "${CONTAINER}:/home/step/certs/root_ca.crt" "${BACKUP_DIR}/root_ca.crt"
docker cp "${CONTAINER}:/home/step/secrets/root_ca_key" "${BACKUP_DIR}/root_ca_key.enc"
docker cp "${CONTAINER}:/home/step/certs/intermediate_ca.crt" "${BACKUP_DIR}/intermediate_ca.crt"

chmod 600 "${BACKUP_DIR}/root_ca_key.enc"

echo ""
echo -e "${GREEN}✓ Root CA extraite dans : ${BACKUP_DIR}/${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT — Ce dossier contient la clé racine de toute la PKI.${NC}"
echo "  → Copier sur un support chiffré hors ligne (USB, coffre...)"
echo "  → Ne JAMAIS laisser ce dossier sur un système connecté"
echo ""

read -r -p "Supprimer la clé Root CA du container ? [o/N] " confirm
if [[ "$confirm" == "o" || "$confirm" == "O" ]]; then
    docker exec "$CONTAINER" sh -c "rm -f /home/step/secrets/root_ca_key"
    echo -e "${GREEN}✓ Clé Root CA supprimée du container. Root CA hors ligne.${NC}"
else
    echo -e "${YELLOW}⚠ Clé Root CA conservée dans le container (moins sécurisé).${NC}"
fi

echo ""
echo "Prochaine étape : distribuer le certificat Root CA sur toutes les VMs."
echo "  → Copier ${BACKUP_DIR}/root_ca.crt sur VM1 (SIEM)"
echo "  → Exécuter scripts/03-trust-root-ca.sh sur chaque machine cible"
