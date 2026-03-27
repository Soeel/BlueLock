#!/bin/bash
# =============================================================================
# 02-issue-cert.sh
#
# Émet un certificat TLS signé par la PKI BlueLock pour un service donné.
# Utilise le provisioner JWK (mot de passe interactif ou via fichier).
#
# Usage :
#   ./scripts/02-issue-cert.sh <service> <dns-principal> [dns-supplémentaires...]
#
# Exemples :
#   ./scripts/02-issue-cert.sh elasticsearch elasticsearch.bluelock.local
#   ./scripts/02-issue-cert.sh kibana kibana.bluelock.local
#   ./scripts/02-issue-cert.sh bastion bastion.bluelock.local
#   ./scripts/02-issue-cert.sh filebeat-dc01 filebeat-dc01.bluelock.local
# =============================================================================
set -euo pipefail

# ── Arguments ──────────────────────────────────────────────────────────────────
if [ $# -lt 2 ]; then
    echo "Usage : $0 <service> <dns-principal> [dns-supplémentaires...]"
    exit 1
fi

SERVICE="$1"
PRINCIPAL="$2"
shift 2
EXTRA_SANS=("$@")

# ── Configuration ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="$(dirname "$SCRIPT_DIR")"
CA_URL="${CA_URL:-https://localhost:9000}"
ROOT_CERT="${PKI_DIR}/certs/root_ca.crt"
PROVISIONER="${CA_PROVISIONER_NAME:-admin@bluelock.local}"
PASSWORD_FILE="${PKI_DIR}/secrets/provisioner_password.txt"
OUTPUT_DIR="${PKI_DIR}/certs/${SERVICE}"
VALIDITY="${CERT_VALIDITY:-8760h}"  # 1 an par défaut

# Couleurs
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── Vérifications ──────────────────────────────────────────────────────────────
if [ ! -f "$ROOT_CERT" ]; then
    echo -e "${RED}Erreur : certificat root introuvable : ${ROOT_CERT}${NC}"
    echo "Exécuter d'abord : scripts/01-secure-root-key.sh"
    exit 1
fi

if ! command -v step &>/dev/null; then
    echo -e "${RED}Erreur : CLI 'step' non installé.${NC}"
    echo "  → apt install step-cli  (Debian/Ubuntu)"
    echo "  → brew install step     (macOS)"
    echo "  → Ou utiliser via Docker : docker exec bluelock-pki step ..."
    exit 1
fi

# ── Création du dossier de sortie ──────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
chmod 750 "$OUTPUT_DIR"

# ── Construction des SANs ──────────────────────────────────────────────────────
SAN_ARGS=()
for san in "${EXTRA_SANS[@]}"; do
    SAN_ARGS+=("--san" "$san")
done

echo -e "${YELLOW}=== Émission du certificat : ${SERVICE} ===${NC}"
echo "  DNS principal : ${PRINCIPAL}"
[ ${#EXTRA_SANS[@]} -gt 0 ] && echo "  SANs supplémentaires : ${EXTRA_SANS[*]}"
echo "  Durée de validité : ${VALIDITY}"
echo "  Sortie : ${OUTPUT_DIR}/"
echo ""

# ── Émission du certificat ─────────────────────────────────────────────────────
STEP_ARGS=(
    "ca" "certificate"
    "$PRINCIPAL"
    "${OUTPUT_DIR}/cert.pem"
    "${OUTPUT_DIR}/key.pem"
    "--ca-url" "$CA_URL"
    "--root" "$ROOT_CERT"
    "--provisioner" "$PROVISIONER"
    "--not-after" "$VALIDITY"
    "--force"
    "${SAN_ARGS[@]}"
)

# Utiliser un fichier de mot de passe si disponible, sinon interactif
if [ -f "$PASSWORD_FILE" ]; then
    STEP_ARGS+=("--provisioner-password-file" "$PASSWORD_FILE")
fi

step "${STEP_ARGS[@]}"

chmod 640 "${OUTPUT_DIR}/key.pem"
chmod 644 "${OUTPUT_DIR}/cert.pem"

echo ""
echo -e "${GREEN}✓ Certificat émis avec succès${NC}"
echo "  Certificat : ${OUTPUT_DIR}/cert.pem"
echo "  Clé privée : ${OUTPUT_DIR}/key.pem"
echo ""
echo "Pour renouveler automatiquement :"
echo "  step ca renew ${OUTPUT_DIR}/cert.pem ${OUTPUT_DIR}/key.pem --daemon"
