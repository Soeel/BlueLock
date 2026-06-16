import os

# On remonte d'un cran pour placer le .env à côté du docker-compose.yml
env_path = os.path.abspath(os.path.join(os.getcwd(), "../../.env"))

def create_env():
    content = """
# CONFIGURATION BASTION DIGISEC
DB_PASSWORD=SafePassword123
POSTGRES_USER=guac_user
POSTGRES_DB=guacamole_db

# CONFIGURATION AD (Pour le Tiering)
AD_IP=192.168.1.10
"""
    with open(env_path, "w") as f:
        f.write(content.strip())
    print(f"✓ Fichier .env créé ici : {env_path}")

if __name__ == "__main__":
    create_env()