import os
import requests

VAULT_ADDR = os.getenv("VAULT_ADDR", "http://localhost:8200")
VAULT_TOKEN = "root_pki_token_2026"

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CERTS_DIR = os.path.join(BASE_DIR, "vault-agent", "certs")

CRT_PATH = os.path.join(CERTS_DIR, "siem.crt")
KEY_PATH = os.path.join(CERTS_DIR, "siem.key")

def generate_siem_certificates():
    print("--- [AUTOMATISATION PKI - SIEM] Demande de certificats à Vault ---")
    if not os.path.exists(CERTS_DIR):
        os.makedirs(CERTS_DIR, exist_ok=True)

    url = f"{VAULT_ADDR}/v1/pki/issue/bastion-role"
    headers = {"X-Vault-Token": VAULT_TOKEN, "Content-Type": "application/json"}
    data = {"common_name": "siem.blue.local", "ttl": "720h"}

    try:
        response = requests.post(url, headers=headers, json=data)
        if response.status_code != 200:
            print(f"❌ Erreur Vault ({response.status_code}) : {response.text}")
            return False
            
        secret_data = response.json()["data"]
        
        with open(CRT_PATH, "w", encoding="utf-8") as crt_file:
            crt_file.write(secret_data["certificate"] + "\n" + secret_data["issuing_ca"])
        print(f"✓ Certificat sauvegardé : {CRT_PATH}")

        with open(KEY_PATH, "w", encoding="utf-8") as key_file:
            key_file.write(secret_data["private_key"])
        print(f"✓ Clé privée sauvegardée : {KEY_PATH}")
        
        print("✓ [SUCCESS] Le socle de sécurité TLS est prêt pour le SIEM.")
        return True
    except Exception as e:
        print(f"❌ Une erreur est survenue : {e}")
        return False

if __name__ == "__main__":
    generate_siem_certificates()