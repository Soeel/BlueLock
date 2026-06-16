import os
import json
import requests

# 1. Configuration des paramètres (Industrialisables via variables d'environnement)
VAULT_ADDR = os.getenv("VAULT_ADDR", "http://localhost:8200")
# Ici, remplace par le jeton généré par ta PKI globale
VAULT_TOKEN = "root_pki_token_2026"

CERTS_DIR = os.path.abspath(os.path.join(os.getcwd(), "../vault-agent/certs"))
CRT_PATH = os.path.join(CERTS_DIR, "bastion.crt")
KEY_PATH = os.path.join(CERTS_DIR, "bastion.key")

def generate_bastion_certificates():
    print("--- [AUTOMATISATION PKI] Demande de certificats à Vault ---")
    
    # Sécurité : Création du dossier de destination s'il n'existe pas
    if not os.path.exists(CERTS_DIR):
        os.makedirs(CERTS_DIR)

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
        with open(CRT_PATH, "w") as crt_file:
            crt_file.write(certificate + "\n" + issuing_ca)
        print(f"✓ Certificat sauvegardé : {CRT_PATH}")

        # Extraction et écriture de la Clé Privée
        private_key = secret_data["private_key"]
        with open(KEY_PATH, "w") as key_file:
            key_file.write(private_key)
        print(f"✓ Clé privée sauvegardée : {KEY_PATH}")
        
        print("✓ [SUCCESS] Le socle de sécurité TLS est prêt pour le Bastion.")
        return True

    except Exception as e:
        print(f"❌ Une erreur est survenue lors de la communication avec Vault : {e}")
        return False

if __name__ == "__main__":
    generate_bastion_certificates()