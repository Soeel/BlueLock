#!/bin/bash
# =============================================================================
# 02-init-db.sh
#
# Génère les scripts SQL d'initialisation de la base Guacamole
# en utilisant l'image officielle guacamole/guacamole.
#
# Ces scripts créent les tables, les rôles et un compte admin par défaut
# (admin / guacadmin) que vous devrez changer à la première connexion.
#
# Usage : ./scripts/02-init-db.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASTION_DIR="$(dirname "$SCRIPT_DIR")"
INITDB_DIR="${BASTION_DIR}/initdb"
GUACAMOLE_VERSION=$(grep GUACAMOLE_VERSION "${BASTION_DIR}/.env" | cut -d= -f2)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Génération des scripts SQL Guacamole ===${NC}"

mkdir -p "$INITDB_DIR"

docker run --rm \
    "guacamole/guacamole:${GUACAMOLE_VERSION}" \
    /opt/guacamole/bin/initdb.sh --postgresql \
    > "${INITDB_DIR}/01-initdb.sql"

echo -e "${GREEN}✓ Script SQL généré : ${INITDB_DIR}/01-initdb.sql${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT : Le compte admin par défaut est admin / guacadmin${NC}"
echo "Changer le mot de passe à la première connexion sur https://bastion.bluelock.local"
echo ""
echo "Démarrer la stack : docker compose up -d"
