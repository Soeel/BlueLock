#!/bin/bash

# Configuration des variables d'accès locales au script
export VAULT_CONTAINER="vault-global"
export VAULT_TOKEN="root_pki_token_2026"

# RE MEDE AUX ERREURS :
# 1. On force la CLI Vault à utiliser le protocole HTTP local
export VAULT_ADDR="http://127.0.0.1:8200"
# 2. Variable pour nettoyer l'affichage Git Bash sous Windows
export MSYS_NO_PATHCONV=1

echo "===================================================="
echo " Initialisation de la PKI Globale (Autorité Racine) "
echo "===================================================="

# Note : On retire le "-it" des commandes docker exec pour éviter le bug de TTY sur Git Bash

# 1. Activation du moteur de secrets PKI
echo "-> Activation du moteur de secrets PKI..."
docker exec -e VAULT_TOKEN=$VAULT_TOKEN -e VAULT_ADDR=$VAULT_ADDR $VAULT_CONTAINER vault secrets enable pki

# Augmentation de la durée de vie max pour la CA racine (ex: 10 ans)
docker exec -e VAULT_TOKEN=$VAULT_TOKEN -e VAULT_ADDR=$VAULT_ADDR $VAULT_CONTAINER vault secrets tune -max-lease-ttl=87600h pki

# 2. Génération du certificat racine (Root CA) pour blue.local
echo "-> Génération de l'Autorité Racine pour blue.local..."
docker exec -e VAULT_TOKEN=$VAULT_TOKEN -e VAULT_ADDR=$VAULT_ADDR $VAULT_CONTAINER vault write -field=certificate pki/root/generate/internal \
    common_name="blue.local Root CA" \
    ttl=87600h > root_ca.crt

echo "✓ Certificat Root CA extrait localement sous le nom 'root_ca.crt'"

# 3. Configuration des points d'accès de la PKI
echo "-> Configuration des URLs de distribution (CRL / Autorité)..."
docker exec -e VAULT_TOKEN=$VAULT_TOKEN -e VAULT_ADDR=$VAULT_ADDR $VAULT_CONTAINER vault write pki/config/urls \
    issuing_certificates="http://vault-global:8200/v1/pki/ca" \
    crl_distribution_points="http://vault-global:8200/v1/pki/crl"

# 4. Création du rôle pour les futurs clients (comme le Bastion)
echo "-> Création du rôle de délivrance 'bastion-role'..."
docker exec -e VAULT_TOKEN=$VAULT_TOKEN -e VAULT_ADDR=$VAULT_ADDR $VAULT_CONTAINER vault write pki/roles/bastion-role \
    allowed_domains="blue.local" \
    allow_subdomains=true \
    max_ttl=720h \
    allow_any_name=false

# 5. Création d'une politique de sécurité restrictive pour le Bastion (via un écho propre sans EOF interactif)
echo "-> Création de la politique ACL pour le Bastion..."
echo 'path "pki/issue/bastion-role" { capabilities = ["update"] }' | docker exec -i -e VAULT_TOKEN=$VAULT_TOKEN -e VAULT_ADDR=$VAULT_ADDR $VAULT_CONTAINER vault policy write bastion-policy -

# 6. Génération du Jeton d'authentification (Token) pour l'Agent Vault du Bastion
echo "===================================================="
echo " CONFIGURATION TERMINEE AVEC SUCCES "
echo "===================================================="
echo "Copie le Token ci-dessous. Il sera utilisé par l'Agent de ton Bastion :"
echo "----------------------------------------------------"
docker exec -e VAULT_TOKEN=$VAULT_TOKEN -e VAULT_ADDR=$VAULT_ADDR $VAULT_CONTAINER vault token create -policy=bastion-policy -field=token
echo ""
echo "----------------------------------------------------"