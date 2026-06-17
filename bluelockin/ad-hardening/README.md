# Harden-AD-Scoring

Outil PowerShell de **durcissement Active Directory** avec **scoring PingCastle avant/après**, inspiré de l'architecture config-driven du projet [HardenAD (LoicVeirman)](https://github.com/LoicVeirman/HardenAD).

## Principe

1. **Pré-vérifications** : session admin, rôle contrôleur de domaine, module `ActiveDirectory`, présence de PingCastle.
2. Scan PingCastle **baseline** (avant).
3. Validation des **exclusions justifiées** (risques acceptés) — interrompt si une exclusion n'est pas justifiée.
4. Application des mesures **retenues** (`test → apply → verify`, idempotent).
5. **Sauvegarde** automatique des valeurs de registre modifiées (restauration possible).
6. Scan PingCastle **post-hardening** (après).
7. **Rapports** : HTML comparatif + JSON (machine-readable) + CSV, et **registre des risques** JSON.

## Frontière avec le tiering

Le **tiering est géré par un script séparé** exécuté **avant** : comptes Tier0/1/2, OU de tiering, groupes d'admin, GPO associées et le CSV de définition des comptes. **Cet outil ne touche pas au tiering** et n'utilise pas le CSV.

## Arborescence

```
ad-hardening/
├── Invoke-HardenAD.ps1          # Orchestrateur
├── Configs/
│   ├── hardening-tasks.json     # Catalogue déclaratif des mesures
│   └── exclusions.json          # Risques acceptés (pré-rempli, non-interactif)
├── Modules/
│   ├── HAD.Common.psm1          # Logging structuré + pré-vérifications
│   ├── HAD.PingCastle.psm1      # Wrapper PingCastle + parsing XML
│   ├── HAD.RiskRegister.psm1    # Validation des exclusions justifiées
│   ├── HAD.Hardening.psm1       # Moteur + backup registre + implémentations apply/rollback/test
│   ├── HAD.Gpo.psm1             # Backend de déploiement par GPO (-DeployVia Gpo)
│   ├── HAD.Laps.psm1            # Déploiement de Windows LAPS (-EnableLaps)
│   └── HAD.Reporting.psm1       # Rapports HTML / JSON / CSV
├── Logs/                        # Transcript + log structuré horodatés
└── Outputs/<timestamp>/         # XML PingCastle, report.html, run_summary.json, measures.csv, registry_backup.json, gpo_backup.json, laps_deployment.json
```

> Les modules sont chargés via `Import-Module` (et **non** par dot-sourcing : dot-sourcer un `.psm1` peut ne rien publier sans lever d'erreur).

## Catalogue de mesures

| ID | Mesure | Sévérité |
|---|---|---|
| HAD-SMB-001 | Désactiver SMBv1 | High |
| HAD-LDAP-001 | Imposer la signature LDAP | High |
| HAD-LDAP-002 | Activer LDAP Channel Binding | Medium |
| HAD-SPOOL-001 | Désactiver le Print Spooler (DC) | High |
| HAD-WDIGEST-001 | Désactiver WDigest | High |
| HAD-LSASS-001 | Protection LSASS (RunAsPPL) | High |
| HAD-LMHASH-001 | Interdire le stockage des hash LM | Medium |
| HAD-ANON-001 | Restreindre l'énumération anonyme | Medium |
| HAD-NTLM-001 | Restreindre NTLM (audit) | Medium |
| HAD-MAQ-001 | ms-DS-MachineAccountQuota = 0 | Medium |
| HAD-KRB-001 | Auditer les délégations non contraintes | High |
| HAD-PWD-001 | Rotation des mots de passe machine | Low |
| HAD-WEBCLIENT-001 | Désactiver WebClient (WebDAV) sur les DC | Medium |
| HAD-RECYCLEBIN-001 | Activer la Corbeille AD (irréversible) | Medium |
| HAD-PWDLEN-001 | Longueur min. de mot de passe ≥ 12 | Medium |
| HAD-DSHEUR-001 | Interdire le LDAP anonyme (dsHeuristics) | Medium |
| HAD-PREWIN2000-001 | Nettoyer Pre-Windows 2000 Compatible Access | Medium |
| HAD-REVERSIBLE-001 | Désactiver le chiffrement réversible des mots de passe | High |
| HAD-LMAUTH-001 | Forcer NTLMv2 (`LmCompatibilityLevel=5`) | Medium |
| HAD-PREAUTH-001 | Réactiver la pré-auth Kerberos (anti AS-REP roasting) | High |
| HAD-DES-001 | Auditer les comptes en chiffrement DES | Medium |
| HAD-PSLOG-001 | Journalisation PowerShell (ScriptBlock + Module) — *GPO sur tous les serveurs* | Medium |
| HAD-AUDIT-001 | Stratégie d'audit avancée (logs de sécurité) — *GPO sur tous les serveurs* | Medium |
| HAD-PWDCOMPLEX-001 | Activer la complexité de mot de passe du domaine | Medium |
| HAD-PROTECTED-001 | Comptes privilégiés (adminCount=1 réels) → Protected Users | High |
| HAD-PWDAUDIT-001 | Auditer la politique et les mots de passe faibles du domaine | Medium |
| HAD-HONEYPOT-001 | Déployer un compte honeypot (leurre de détection) | Medium |

> Les `pingCastleRule` du catalogue (ex. `A-MinPwdLen`, `P-RecycleBin`, `A-DC-WebClient`) correspondent aux règles évaluées par PingCastle : leur correction se reflète dans le **delta de score avant/après**. Certaines mesures (WebClient absent, dsHeuristics par défaut) ressortiront `AlreadyCompliant` selon l'état initial du domaine.

## Gestion des exclusions (risque accepté)

Mode **non-interactif** par fichier. Chaque exclusion de `Configs/exclusions.json` **doit** comporter :

| Champ | Obligatoire | Règle |
|---|---|---|
| `measureId` | oui | doit exister dans le catalogue **et** être `canBeSkipped` |
| `justification` | oui | ≥ 20 caractères |
| `acceptedBy` | oui | responsable validant |
| `acceptedDate` | oui | date valide (`yyyy-MM-dd`) |
| `reviewDate` | non | date de revue — **si dépassée**, avertissement (ou erreur avec `-StrictReview`) |

Toute exclusion incomplète **interrompt** le hardening. Le registre final (`risk_register.json`) est horodaté pour preuve d'audit et signale les revues expirées.

## Ajouter une mesure

Ajouter un objet dans `Configs/hardening-tasks.json` (`id`, `applyFunction`, `rollbackFunction`, `testFunction`, `severity`, `rebootRequired`…) puis implémenter les 3 fonctions dans `Modules/HAD.Hardening.psm1`. Le moteur les appelle dynamiquement par nom. Pour les modifications de registre, utiliser `Set-HADRegistryValue` afin de bénéficier de la sauvegarde automatique.

## Utilisation

```powershell
# Simulation (aucune modification)
.\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe -DryRun

# Exécution réelle (sur un DC)
.\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe -RequireDomainController

# Annuler les mesures (restaure les valeurs sûres)
.\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe -Rollback

# Déploiement par GPO (s'applique à TOUS les DC, persistant)
.\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe -DeployVia Gpo

# Rollback GPO = suppression de la GPO (délier + supprimer)
.\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe -DeployVia Gpo -Rollback

# Exclusion dont la revue est dépassée = erreur bloquante
.\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe -StrictReview
```

| Paramètre | Effet |
|---|---|
| `-DryRun` | Simulation, aucune modification |
| `-Rollback` | Annule (local : `rollbackFunction` + `registry_backup.json` ; GPO : supprime la GPO) |
| `-DeployVia` | `Local` (défaut) ou `Gpo` : déploie les mesures registre dans une GPO dédiée |
| `-GpoName` | Nom de la GPO en mode `Gpo` (défaut `BlueLock - AD Hardening`) |
| `-GpoTarget` | DN de l'OU/domaine à lier (défaut : OU *Domain Controllers*) |
| `-StrictReview` | Revue d'exclusion dépassée → erreur |
| `-RequireDomainController` | Absence de rôle DC → erreur |
| `-Server` | DC ciblé par PingCastle |
| `-SkipBaselineScan` / `-SkipFinalScan` | Sauter un scan |

### Mode GPO (`-DeployVia Gpo`)

En mode `Local` (défaut), les mesures de type registre modifient le registre **local** d'un seul DC. En mode `Gpo`, elles sont écrites dans une **GPO dédiée** liée à l'OU des contrôleurs de domaine : le réglage s'applique alors à **tous les DC** et **persiste** (rafraîchissement GPO).

- 9 mesures registre sont déployables par GPO (LDAP signing/channel binding, WDigest, LSASS PPL, NoLMHash, énumération anonyme, NTLM, mot de passe machine, NTLMv2).
- Les mesures **niveau domaine/forêt/service** (MAQ, délégation, corbeille, chiffrement réversible, longueur de mot de passe, services Spooler/WebClient…) restent en **application directe** — elles n'ont pas leur place dans une GPO de serveur.
- Le **rollback GPO** supprime **toutes** les GPO créées par l'outil (et leurs liens) sans jamais toucher au registre local des machines. Le journal des opérations est sauvegardé dans `gpo_backup.json`.
- Prérequis : module **GroupPolicy** (RSAT-GPMC, présent sur un DC).

**Deux GPO sont créées** selon la portée nécessaire :
- `BlueLock - AD Hardening` — liée à *OU Domain Controllers*, pour les mesures spécifiques aux DC (LDAP signing, channel binding, WDigest, LSASS PPL, NoLMHash, énumération anonyme, NTLM, mot de passe machine, NTLMv2).
- `BlueLock - Audit & Logging` — liée à la **racine du domaine**, pour les mesures qui doivent collecter des logs sur **tous les serveurs** : journalisation PowerShell (HAD-PSLOG-001) et stratégie d'audit avancée (HAD-AUDIT-001).

Pour la stratégie d'audit avancée en mode GPO, l'outil écrit `audit.csv` dans le SYSVOL de la GPO et enregistre le CSE *Audit Settings* (`{F3CCC681-…}`) dans `gPCMachineExtensionNames` afin que les clients l'appliquent. À vérifier dans GPMC après le déploiement (onglet *Settings* de la GPO).

### Windows LAPS (`-EnableLaps`)

Windows LAPS (natif, sans agent) fait tourner et sauvegarde dans AD le mot de passe de l'**administrateur local** de chaque machine — ce qui supprime sa réutilisation entre machines (mouvement latéral). Étape **opt-in**, distincte du catalogue :

```powershell
# Déploiement complet (schéma + permissions + GPO) sur une OU de machines
.\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe `
    -EnableLaps -ConfirmSchemaExtension `
    -LapsComputersOU "OU=Servers,DC=corp,DC=local"

# Simulation
.\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe -DryRun `
    -EnableLaps -LapsComputersOU "OU=Servers,DC=corp,DC=local"

# Rollback LAPS = suppression de la GPO LAPS (schéma conservé, irréversible)
.\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe -EnableLaps -Rollback
```

Étapes : (1) prérequis cmdlets LAPS → (2) **extension de schéma** `Update-LapsADSchema` — **IRRÉVERSIBLE**, forêt entière, *Schema Admins* requis, **tentée uniquement avec `-ConfirmSchemaExtension`** → (3) `Set-LapsADComputerSelfPermission` sur l'OU → (4) GPO LAPS (sauvegarde vers AD, longueur 20 / âge 30 j / complexité 4 par défaut).

| Paramètre | Effet |
|---|---|
| `-EnableLaps` | Active l'étape LAPS |
| `-ConfirmSchemaExtension` | Autorise l'extension **irréversible** du schéma |
| `-LapsComputersOU` | DN de l'OU des machines (obligatoire) |
| `-LapsGpoName` | Nom de la GPO LAPS (défaut `BlueLock - Windows LAPS`) |
| `-LapsPasswordLength` / `-LapsPasswordAgeDays` / `-LapsPasswordComplexity` | Réglages du mot de passe (20 / 30 / 4) |

Le détail des étapes est tracé dans `laps_deployment.json`. Prérequis : Windows LAPS (Windows récent patché post-avril 2023) + module **GroupPolicy**. Le chiffrement du mot de passe dans AD requiert un niveau fonctionnel ≥ 2016.

## ⚠️ Avertissements

- **Tester en pré-production d'abord.** LDAP signing, channel binding, NTLM et LSASS PPL peuvent casser des applications/pilotes legacy.
- `Protect-Delegation` modifie les comptes des groupes privilégiés (`AccountNotDelegated`) : valider le périmètre. Un `-Rollback` est disponible.
- **`HAD-PROTECTED-001` est à fort impact** : l'appartenance à *Protected Users* désactive NTLM/DES/RC4 et la délégation, et limite le TGT à 4 h pour ses membres. La mesure n'ajoute que les comptes `adminCount=1` **réellement** membres d'un groupe privilégié, mais vérifier qu'aucun compte de service legacy n'en dépend (rollback précis via `state_backup.json`).
- **`HAD-HONEYPOT-001` n'a de valeur qu'avec une alerte SIEM** sur les événements `4769`/`4768` ciblant le compte leurre (`SVC-BackupLegacy`). Sans supervision, le leurre ne détecte rien.
- Pour un déploiement pérenne sur **tous les DC**, préférer `-DeployVia Gpo` (voir ci-dessus) plutôt que l'application locale sur un seul DC. En mode local, la sauvegarde `registry_backup.json` permet une restauration manuelle exacte (`Restore-HADRegistryBackup`).
- Exécuter sur le PDC, en administrateur du domaine, fichiers débloqués (`Get-ChildItem -Recurse | Unblock-File`).
