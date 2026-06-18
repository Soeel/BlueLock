# Tiering AD - BlueLock

Implémentation automatisée du modèle **Tier 0 / Tier 1 / Tier 2** sur Active Directory,
dans la même architecture **config-driven** que la partie `ad-hardening` (catalogue JSON
de phases, moteur `test → apply → verify`, rollback, logging structuré, rapports).

## Principe

Le tiering sépare les niveaux de privilège pour bloquer le **mouvement latéral** : un compte
d'un tier ne doit jamais exposer ses identifiants sur une machine d'un autre tier. Ce socle
crée la structure (OU/groupes/comptes) **et** applique le cloisonnement réel via GPO.

| Tier | Périmètre | Exemples |
|---|---|---|
| **T0** | Plan de contrôle de l'identité | DC, AD, bastion d'administration |
| **T1** | Serveurs métiers / production | fichiers, applicatif MES/ERP, SIEM, SCADA, web |
| **T2** | Postes et utilisateurs | postes de travail |
| **Legacy** | Systèmes obsolètes **isolés** (exemptés) | HMI/stations d'ingénierie sur OS non supporté |

## Arborescence

```
tiering/
├── Invoke-TieringModel.ps1     # Orchestrateur
├── Configs/
│   ├── tiering-config.json     # Modèle (tiers, nommage, PSO, matrice deny-logon)
│   ├── tiering-tasks.json      # Catalogue ORDONNÉ des phases
│   ├── admin-accounts.csv      # Comptes admin à créer
│   └── servers.csv             # Serveurs à classer par tier
├── Modules/
│   ├── TIER.Common.psm1        # Logging, prérequis, contexte, helpers (noms, mdp)
│   ├── TIER.Model.psm1         # Moteur + phases AD (OU, groupes, comptes, PSO, serveurs)
│   ├── TIER.Gpo.psm1           # GPO : admin local (Restricted Groups) + deny-logon
│   └── TIER.Reporting.psm1     # Rapport HTML + exports JSON/CSV
├── Logs/                       # Transcripts + log structuré
└── Outputs/<timestamp>/        # report.html, tiering_run.json, access_matrix.csv, admin_passwords.csv
```

## Phases (catalogue `tiering-tasks.json`)

| ID | Phase | Réversible |
|---|---|---|
| TIER-OU-001 | Crée les OU `Admins`/`Servers`/`Groups` + sous-OU T0/T1/T2 | non |
| TIER-GRP-001 | Crée les groupes `GG_T0/T1/T2_Admins` | non |
| TIER-ACC-001 | Crée les comptes `admtX...` (T0 marqués *non délégables*) | non (rollback = désactive) |
| TIER-T0DOMAIN-001 | Imbrique `GG_T0_Admins` dans les groupes privilégiés du domaine (par défaut *Domain Admins*) | oui |
| TIER-PROTECTED-001 | Ajoute les comptes T0 au groupe **Protected Users** (anti vol d'identifiants) | oui |
| TIER-PSO-001 | PSO admin (14 car., 180 j, historique 24, lockout) | oui |
| TIER-SRVGRP-001 | Groupes d'accès local par serveur (`GLA_<serveur>_Administrators`) | non |
| TIER-MOVE-001 | Déplace les serveurs dans les OU de tier | non |
| TIER-LOCALADMIN-001 | GPO **Restricted Groups** : `GG_TX_Admins` admin local des serveurs du tier | oui |
| TIER-DENYLOGON-001 | GPO **deny-logon cross-tier** (cœur du cloisonnement) | oui |

### Deny-logon (TIER-DENYLOGON-001)

Une GPO par tier interdit l'ouverture de session (locale, RDP, batch, service, réseau) aux
groupes admin des **autres** tiers, et aux utilisateurs du domaine sur T0/T1. C'est ce qui
empêche réellement un compte T0 d'exposer ses identifiants sur un poste T2 (vol mimikatz),
et inversement. Implémenté via `GptTmpl.inf` (User Rights Assignment) écrit en SYSVOL, avec
enregistrement du CSE Security — pas de script de démarrage. Matrice pilotée par
`tiering-config.json → denyLogon`.

## Utilisation

```powershell
# Simulation (aucune modification)
.\Invoke-TieringModel.ps1 -DryRun

# Aligner les CSV sur le domaine réel détecté + nomenclature admtX (crée des .bak)
.\Invoke-TieringModel.ps1 -UpdateInputCsv

# Déploiement complet
.\Invoke-TieringModel.ps1

# Sans déplacer les objets ordinateurs
.\Invoke-TieringModel.ps1 -SkipServerMove

# Rollback (supprime les GPO + PSO ; OU/groupes/comptes conservés)
.\Invoke-TieringModel.ps1 -Rollback
```

| Paramètre | Effet |
|---|---|
| `-DryRun` | Simulation |
| `-Rollback` | Annule les phases réversibles (GPO + PSO) |
| `-UpdateInputCsv` | Réécrit les CSV avec le domaine détecté |
| `-SkipServerMove` | Ne déplace pas les serveurs |

## ⚠️ Points d'attention

- **Admin local** : approche `Restricted Groups __Memberof` (additive, réappliquée). Combinée
  au deny-logon, un admin local résiduel d'un autre tier ne peut de toute façon plus se connecter.
- **Domain Admins** : la phase `TIER-T0DOMAIN-001` ajoute `GG_T0_Admins` comme membre des
  groupes listés dans `tiering-config.json → tier0PrivilegedGroups` (par défaut `Domain Admins`).
  Les comptes `admt0X` deviennent ainsi *administrateurs du domaine* par héritage. Ajouter
  `Enterprise Admins` / `Schema Admins` à la liste si nécessaire (forest root uniquement).
  La phase **ne nettoie pas** les autres membres existants — à faire manuellement après revue.
- **Mots de passe** : `Outputs/<timestamp>/admin_passwords.csv` contient les mots de passe
  initiaux en clair → **à protéger / supprimer après remise**. Le dossier `Outputs/` et les
  `.bak` sont exclus du Git (`.gitignore`).
- **Protected Users (`TIER-PROTECTED-001`)** : protège les comptes T0 (interdit NTLM/DES/RC4,
  la délégation, le cache d'identifiants, TGT limité à 4 h). Requiert un **niveau fonctionnel
  de domaine ≥ 2012 R2**. Vérifier qu'aucun compte T0 ne dépend de NTLM avant d'activer.
- **Tier Legacy** : tier d'**isolation** pour les systèmes obsolètes (HMI, stations
  d'ingénierie sur OS non supporté, fréquents en milieu industriel). Sa GPO deny-logon
  interdit T0/T1/T2 sur les machines Legacy, et interdit les comptes Legacy partout ailleurs :
  les systèmes obsolètes sont mis en quarantaine, administrés uniquement par `GG_Legacy_Admins`.
  Ajouter/retirer ce tier = éditer `tiering-config.json` (`tiers` + `denyLogon`), aucun code.
- **Bastion** : le tiering est le prérequis de l'intégration bastion (origine des connexions T0).
