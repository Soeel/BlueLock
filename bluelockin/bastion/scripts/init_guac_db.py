import subprocess
import os

# Configuration des chemins [cite: 28]
INIT_DIR = "../init"
SQL_FILE = os.path.join(INIT_DIR, "initdb.sql")

def generate_guacamole_schema():
    """Génère le schéma SQL initial via l'image Docker de Guacamole."""
    print("--- Génération du schéma SQL Guacamole ---")
    
    # Création du dossier init s'il n'existe pas
    if not os.path.exists(INIT_DIR):
        os.makedirs(INIT_DIR)
        print(f"Dossier {INIT_DIR} créé.")

    try:
        # Commande pour extraire le script d'initialisation de l'image Docker
        # Cela garantit que le schéma correspond exactement à la version de l'image
        command = [
            "docker", "run", "--rm", 
            "guacamole/guacamole", 
            "/opt/guacamole/bin/initdb.sh", "--postgresql"
        ]
        
        print("Extraction du schéma depuis le conteneur...")
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        
        # Écriture du fichier SQL
        with open(SQL_FILE, "w") as f:
            f.write(result.stdout)
            
        print(f"✓ Succès : Schéma généré dans {SQL_FILE}")
        
    except subprocess.CalledProcessError as e:
        print(f"Erreur lors de la génération : {e.stderr}")
    except Exception as e:
        print(f"Une erreur est survenue : {e}")

if __name__ == "__main__":
    generate_guacamole_schema()