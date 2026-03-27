#!/bin/bash
# =============================================================================
# 04-issue-cert.sh
#
# Émet un certificat TLS signé par l'Intermediate CA Vault (pki_int/).
#
# Usage :
#   ./scripts/04-issue-cert.sh <service> <dns-principal> [dns-supplémentaires...]
#
# Exemples :
#   ./scripts/04-issue-cert.sh elasticsearch elasticsearch.bluelock.local
#   ./scripts/04-issue-cert.sh kibana kibana.bluelock.local
#   ./scripts/04-issue-cert.sh bastion bastion.bluelock.local
#   ./scripts/04-issue-cert.sh filebeat-dc01 filebeat-dc01.bluelock.local
# =============================================================================
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage : $0 <service> <dns-principal> [dns-supplémentaires...]"
    exit 1
fi

SERVICE="$1"
COMMON_NAME="$2"
shift 2
EXTRA_SANS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_FILE="${PKI_DIR}/secrets/vault-init.json"
CONTAINER="bluelock-vault"
OUTPUT_DIR="${PKI_DIR}/certs/${SERVICE}"
TTL="${CERT_TTL:-8760h}"
ROLE="${CERT_ROLE:-bluelock-services}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${SECRETS_FILE}'))['root_token'])")

# Construire les SANs
ALT_NAMES="$COMMON_NAME"
for san in "${EXTRA_SANS[@]:-}"; do
    [ -n "$san" ] && ALT_NAMES="${ALT_NAMES},${san}"
done

echo -e "${YELLOW}Émission du certificat : ${SERVICE} (${COMMON_NAME})${NC}"

mkdir -p "$OUTPUT_DIR"
chmod 750 "$OUTPUT_DIR"

CERT_OUTPUT=$(docker exec \
    -e VAULT_ADDR=https://127.0.0.1:8200 \
    -e VAULT_CACERT=/vault/certs/vault.crt \
    -e VAULT_TOKEN="$ROOT_TOKEN" \
    "${CONTAINER}" vault write -format=json "pki_int/issue/${ROLE}" \
    common_name="$COMMON_NAME" \
    alt_names="$ALT_NAMES" \
    ttl="$TTL")

echo "$CERT_OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
open('${OUTPUT_DIR}/cert.pem', 'w').write(d['certificate'] + '\n' + d['issuing_ca'])
open('${OUTPUT_DIR}/key.pem', 'w').write(d['private_key'])
open('${OUTPUT_DIR}/chain.pem', 'w').write('\n'.join(d['ca_chain']))
print('Serial   :', d['serial_number'])
print('Expire   :', d['expiration'])
"

chmod 640 "${OUTPUT_DIR}/key.pem"
chmod 644 "${OUTPUT_DIR}/cert.pem"
chmod 644 "${OUTPUT_DIR}/chain.pem"

echo -e "${GREEN}✓ Certificat émis :${NC}"
echo "  ${OUTPUT_DIR}/cert.pem"
echo "  ${OUTPUT_DIR}/key.pem"
echo "  ${OUTPUT_DIR}/chain.pem"
