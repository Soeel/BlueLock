# Intégration Tiering & Bastion — Conception

> Branche `claude/bastion-int-tiering`. Document de conception pour l'intégration du bastion
> d'administration (Apache Guacamole) avec le modèle de Tiering AD déjà déployé.
> Répond à l'exigence du cahier des charges : *« Mise en place d'un bastion, avec intégration
> de l'architecture mise en place avec le Tiering pour assurer le cloisonnement des connexions au SI ».*

## 1. Principe directeur

Le bastion est le **point d'entrée unique** d'administration. Chaque administrateur s'authentifie
avec son **compte de tier AD** (`admt0x` / `admt1x` / `admt2x`), ne voit et n'accède **qu'aux
serveurs de son propre tier**, et toutes les sessions sont journalisées puis envoyées au SIEM.

```
                          ┌─────────── SRV-BASTION (Tier 0) ───────────┐
  admt0x ──┐              │  nginx TLS → Guacamole ── guacd            │
  admt1x ──┼─► HTTPS ────►│  authn : LDAPS → DC   │  (RDP / SSH / VNC) │──► serveurs
  admt2x ──┘   (+ TOTP)   │  authz : groupe AD=tier│                   │    par tier
                          └────────────────────────┴──────────────────┘
   GG_T0_Admins ─► groupe de connexions « Tier 0 » uniquement
   GG_T1_Admins ─► « Tier 1 »   |   GG_T2_Admins ─► « Tier 2 »   |   GG_Legacy_Admins ─► « Legacy »
```

Double barrière de cloisonnement :
- **Identité** : deny-logon AD (déjà en place via le tiering) — un `admt2` ne peut pas ouvrir de session sur un serveur T1.
- **Réseau** : les cibles n'acceptent RDP/SSH **que depuis le bastion**.
- **Applicatif** : Guacamole ne présente à l'admin que les connexions de son tier.

## 2. Décisions de conception (validées)

| Sujet | Décision |
|---|---|
| Provisioning des connexions | **Python + API REST Guacamole** (idempotent, rejouable, source = `servers.csv`) |
| Identifiants vers les cibles | **Aucun secret stocké** : saisie à la connexion / SSO Kerberos (NLA) |
| MFA | **TOTP pour tous** (`guacamole-auth-totp`) |
| Langages | Python (sync + API) et PowerShell (côté AD) — conforme au sujet |

## 3. Les 6 axes

### Axe 1 — Authentification AD (LDAPS)
- Extension `guacamole-auth-ldap`, chiffrement **LDAPS (636)** vers le DC (consomme le cert DC via la PKI).
- Bind via un **compte de service dédié** `svc-guac-ldap` (lecture seule, **non** compte de tier).
- Plus de comptes locaux Guacamole hormis **un compte break-glass** (MDP fort, hors AD, pour le cas où l'AD est indisponible).

### Axe 2 — Cloisonnement par tier (cœur)
- Modèle **hybride** Guacamole : *identité* par LDAP, *autorisations* en base PostgreSQL.
- Un **connection group par tier** : `Tier 0`, `Tier 1`, `Tier 2`, `Legacy`.
- Permission de lecture accordée au seul **user group** correspondant (mappé sur le groupe AD `GG_TX_Admins`).

### Axe 3 — Connexions générées depuis le tiering
- Script **`Sync-BastionFromTiering`** (Python) : lit `bluelockin/tiering/Configs/servers.csv`,
  crée via l'API REST les groupes de connexions, les connexions RDP (Windows) / SSH (Linux),
  et les permissions par groupe AD.
- **Source unique de vérité = le CSV du tiering.** Ajouter un serveur au tiering = il apparaît dans le bastion, dans le bon tier.

### Axe 4 — Cloisonnement réseau
- RDP (3389) / SSH (22) autorisés **uniquement depuis l'IP du bastion** : GPO Windows Firewall (cibles Windows) + firewalld/iptables (cibles Linux).
- Le bastion `SRV-BASTION` est en **Tier 0** (déjà classé ainsi dans `servers.csv`) : seuls les `GG_T0_Admins` l'administrent.

### Axe 5 — Sécurité du bastion
- **TLS** via la PKI (remplacer le certificat auto-signé actuel).
- **MFA TOTP** pour tous.
- **Secrets** sortis du `docker-compose.yml` vers `.env` / Vault (actuellement `SafePassword123` en clair).
- **Nettoyage du dépôt** : retrait du `terraform.tfstate`, du provider `.exe` (18 Mo) et des certs commités ; ajout d'un `.gitignore`.

### Axe 6 — Journalisation → SIEM
- Historique des sessions (`guacamole_connection_history` : utilisateur, cible, début, durée) + logs applicatifs.
- Export vers le SIEM (Filebeat sur les logs Docker json-file).
- Alertes cibles : connexion T0 hors horaires, échecs d'authentification répétés, tentative d'accès cross-tier.

## 4. Mapping concret Tiering → Guacamole

| Tier | Groupe AD (user group Guacamole) | Connection group | Cibles (exemples `servers.csv`) |
|---|---|---|---|
| T0 | `GG_T0_Admins` | `Tier 0` | SRV-DC01 (RDP), SRV-BASTION |
| T1 | `GG_T1_Admins` | `Tier 1` | SRV-FILESAPP (RDP), SRV-WEB (SSH), SRV-SIEM (SSH), SRV-SCADABR (SSH) |
| T2 | `GG_T2_Admins` | `Tier 2` | POSTE-001/002 (RDP) |
| Legacy | `GG_Legacy_Admins` | `Legacy` | SRV-HMI-LEGACY |

Protocole déduit du rôle/OS (Windows → RDP, Linux → SSH), surchageable par une colonne optionnelle du CSV.

## 5. Prérequis

- Tiering déjà déployé (OU/groupes/comptes/GPO) — fait.
- Compte de service AD `svc-guac-ldap` (lecture annuaire).
- Certificat LDAPS exploitable sur le DC + cert serveur du bastion (PKI).
- Extensions Guacamole : `guacamole-auth-ldap`, `guacamole-auth-totp` (montées dans l'image/volume).

## 6. Livrables prévus (implémentation)

1. `bastion/config/guacamole.properties` + variables LDAP/TOTP + extensions dans `docker-compose.yml`.
2. `bastion/scripts/sync_bastion_from_tiering.py` — provisioning via API REST (la pièce maîtresse).
3. Règles pare-feu « RDP/SSH depuis le bastion uniquement » (phase tiering ou hardening).
4. Hygiène dépôt : `.env(.example)`, `.gitignore`, retrait des artefacts commités.
5. Documentation d'exploitation (ajout d'une cible/d'un tier) + schéma de flux (DAT).

## 7. Limites connues

- L'environnement de build ne dispose pas d'AD/Guacamole : tout sera validé statiquement puis
  testé sur la maquette (DC `blue.local` + conteneur bastion).
- Le SSO Kerberos via Guacamole (RDP) suppose une configuration NLA correcte des cibles ; à défaut,
  saisie des identifiants de tier à la connexion (aucun secret stocké).
