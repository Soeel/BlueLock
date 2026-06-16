import os
import json
import requests

# 1. Configuration des paramètres (Industrialisables via variables d'environnement)
VAULT_ADDR = os.getenv("VAULT_ADDR", "http://10.30.0.152:8200")
VAULT_TOKEN = "root_pki_token_2026"

# CORRECTION : Forçage du chemin au format Linux natif pour s'aligner avec Docker
# On part du dossier du script, on remonte d'un cran, puis on descend proprement
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CERTS_DIR = os.path.join(BASE_DIR, "vault-agent", "certs")

CRT_PATH = os.path.join(CERTS_DIR, "bastion.crt")
KEY_PATH = os.path.join(CERTS_DIR, "bastion.key")

def generate_bastion_certificates():
    print("--- [AUTOMATISATION PKI] Demande de certificats à Vault ---")
    
    # Sécurité : Création de la vraie structure imbriquée si elle n'existe pas
    if not os.path.exists(CERTS_DIR):
        os.makedirs(CERTS_DIR, exist_ok=True)

    # Préparation de la requête API pour Vault
    url = f"{VAULT_ADDR}/v1/pki/issue/bastion-role"
    headers = {
        "X-Vault-Token": VAULT_TOKEN,
        "Content-Type": "application/json"
    }
    data = {
        "common_name": "bastion.blue.local",
        "ttl": "720h"
    }

    try:
        # Envoi de la demande au moteur PKI
        response = requests.post(url, headers=headers, json=data)
        
        if response.status_code != 200:
            print(f"❌ Erreur Vault ({response.status_code}) : {response.text}")
            return False
            
        secret_data = response.json()["data"]
        
        # Extraction et écriture du Certificat (Cert + CA chain)
        certificate = secret_data["certificate"]
        issuing_ca = secret_data["issuing_ca"]
        with open(CRT_PATH, "w", encoding="utf-8") as crt_file:
            crt_file.write(certificate + "\n" + issuing_ca)
        print(f"✓ Certificat sauvegardé : {CRT_PATH}")

        # Extraction et écriture de la Clé Privée
        private_key = secret_data["private_key"]
        with open(KEY_PATH, "w", encoding="utf-8") as key_file:
            key_file.write(private_key)
        print(f"✓ Clé privée sauvegardée : {KEY_PATH}")
        
        print("✓ [SUCCESS] Le socle de sécurité TLS est prêt pour le Bastion.")
        return True

    except Exception as e:
        print(f"❌ Une erreur est survenue lors de la communication avec Vault : {e}")
        return False

if __name__ == "__main__":
    generate_bastion_certificates()