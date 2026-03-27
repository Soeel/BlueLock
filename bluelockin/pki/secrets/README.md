# Secrets PKI

Ce dossier contient les mots de passe de la PKI BlueLock.
**Ces fichiers ne sont pas versionnés (.gitignore).**

## Fichiers à créer manuellement

### `ca_password.txt`
Mot de passe de chiffrement des clés Root CA et Intermediate CA.
Utilisé au démarrage du container step-ca.

```bash
echo "VotreMotDePasseCA" > ca_password.txt
chmod 600 ca_password.txt
```

### `provisioner_password.txt`
Mot de passe du provisioner JWK (utilisé pour émettre des certificats).

```bash
echo "VotreMotDePasseProvisioner" > provisioner_password.txt
chmod 600 provisioner_password.txt
```

> **Important** : Utiliser des mots de passe forts (min. 20 caractères).
> Stocker une copie chiffrée hors ligne avec la Root CA.
