# Secrets PKI — HashiCorp Vault

Ce dossier contient les credentials générés lors de l'initialisation de Vault.
**Ces fichiers ne sont pas versionnés (.gitignore).**

## `vault-init.json` (généré automatiquement)

Créé par `scripts/01-init-vault.sh`. Contient :
- `unseal_keys_b64` — 5 unseal keys (3 requises pour désceller)
- `root_token` — Token root Vault (accès total)

**Stocker une copie chiffrée hors ligne (support USB chiffré, coffre...).**
Sans ces clés, les données Vault sont définitivement inaccessibles.

## Rotation recommandée après setup

```bash
# Créer un token admin avec TTL limité (remplace le root token pour les opérations courantes)
vault token create -policy=pki-issue -ttl=720h -display-name=pki-admin

# Révoquer le root token une fois les opérations terminées
vault token revoke <root-token>
```
