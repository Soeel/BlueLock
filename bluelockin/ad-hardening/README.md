# Harden-AD-Scoring

Script PowerShell de **durcissement Active Directory** avec **scoring PingCastle avant/après**, inspiré de l'architecture config-driven du projet [HardenAD (LoicVeirman)](https://github.com/LoicVeirman/HardenAD).

## Principe

1. Scan PingCastle **baseline** (avant)
2. Validation des **exclusions justifiées** (risques acceptés) — interrompt si une exclusion n'est pas justifiée
3. Application des mesures **retenues**
4. Scan PingCastle **post-hardening** (après)
5. **Rapport comparatif** HTML + **registre des risques** JSON

## Frontière avec le tiering

Le **tiering est géré par un script séparé** : comptes Tier0/1/2, OU de tiering, groupes d'admin, GPO associées et le CSV de définition des comptes. **Ce script ne touche pas au tiering** et n'utilise pas le CSV.

## Arborescence

```
Harden-AD-Scoring/
├── Invoke-HardenAD.ps1          # Orchestrateur
├── Configs/
│   ├── hardening-tasks.json     # Catalogue déclaratif des mesures
│   └── exclusions.json          # Risques acceptés (pré-rempli, non-interactif)
├── Modules/
│   ├── HAD.PingCastle.psm1      # Wrapper PingCastle + parsing XML
│   ├── HAD.RiskRegister.psm1    # Validation des exclusions justifiées
│   ├── HAD.Hardening.psm1       # Moteur + implémentations apply/rollback/test
│   └── HAD.Reporting.psm1       # Rapport comparatif HTML
├── Logs/                        # Transcripts horodatés
└── Outputs/<timestamp>/         # Rapports XML, registre, report.html
```

## Gestion des exclusions (risque accepté)

Mode **non-interactif** par fichier. Chaque exclusion de `exclusions.json` **doit** comporter :

| Champ | Obligatoire | Règle |
|---|---|---|
| `measureId` | oui | doit exister dans le catalogue |
| `justification` | oui | ≥ 20 caractères |
| `acceptedBy` | oui | responsable validant |
| `acceptedDate` | oui | date valide |
| `reviewDate` | non | date de revue recommandée |

Toute exclusion incomplète **interrompt** le hardening. Le registre final (`risk_register.json`) est horodaté pour preuve d'audit.

## Ajouter une mesure

Ajouter un objet dans `hardening-tasks.json` (id, applyFunction, rollbackFunction, testFunction…) puis implémenter les 3 fonctions dans `HAD.Hardening.psm1`. Le moteur les appelle dynamiquement par nom.

## Utilisation

```powershell
# Simulation (aucune modification)
.\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe -DryRun

# Exécution réelle
.\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe
```

## ⚠️ Avertissements

- **Tester en pré-production d'abord.** LDAP signing, channel binding et NTLM peuvent casser des applications legacy.
- Les implémentations de `HAD.Hardening.psm1` sont des **squelettes** : relire et valider chaque `applyFunction` avant production. `Protect-Delegation` notamment doit être adaptée à votre périmètre.
- Plusieurs mesures gagnent à être déployées par **GPO** plutôt qu'en local sur un seul DC.
- Exécuter sur le PDC, en administrateur du domaine, fichiers débloqués (`Get-ChildItem -Recurse | Unblock-File`).
