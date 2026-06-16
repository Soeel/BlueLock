# Harden-AD-Scoring — Guide d'utilisation

## Prérequis

Avant d'exécuter le script, vérifiez les points suivants :

- **Windows Server** avec le rôle AD DS (contrôleur de domaine), idéalement le PDC.
- **PowerShell 5.1+** en mode administrateur.
- **PingCastle** : téléchargez l'exécutable depuis [pingcastle.com](https://www.pingcastle.com/) et notez le chemin complet vers `PingCastle.exe`.
- Débloquer les fichiers si téléchargés depuis internet :
  ```powershell
  Get-ChildItem -Path .\Harden-AD-Scoring -Recurse | Unblock-File
  ```

---

## Arborescence du projet

```
Harden-AD-Scoring/
├── Invoke-HardenAD.ps1            Orchestrateur principal
├── Configs/
│   ├── hardening-tasks.json       Catalogue des mesures de durcissement
│   └── exclusions.json            Mesures exclues avec justification
├── Modules/
│   ├── HAD.PingCastle.psm1        Scan PingCastle et parsing XML
│   ├── HAD.RiskRegister.psm1      Validation des exclusions
│   ├── HAD.Hardening.psm1         Moteur d'application des mesures
│   └── HAD.Reporting.psm1         Génération du rapport HTML
├── Logs/                          Transcripts d'exécution
└── Outputs/                       Sorties horodatées (rapports, registres)
```

---

## Démarrage rapide

### 1. Lancer une simulation (aucune modification)

```powershell
.\Invoke-HardenAD.ps1 -PingCastlePath "C:\Tools\PingCastle\PingCastle.exe" -DryRun
```

Le mode `-DryRun` parcourt le catalogue, affiche ce qui **serait** appliqué, valide les exclusions, mais ne modifie rien sur le domaine. C'est le premier réflexe à avoir.

### 2. Lancer le hardening complet

```powershell
.\Invoke-HardenAD.ps1 -PingCastlePath "C:\Tools\PingCastle\PingCastle.exe"
```

Le script enchaîne automatiquement : scan PingCastle avant → validation des exclusions → application des mesures → scan PingCastle après → rapport comparatif.

### 3. Sauter un scan PingCastle (tests)

```powershell
# Sauter le scan initial
.\Invoke-HardenAD.ps1 -PingCastlePath "C:\Tools\PingCastle\PingCastle.exe" -SkipBaselineScan

# Sauter le scan final
.\Invoke-HardenAD.ps1 -PingCastlePath "C:\Tools\PingCastle\PingCastle.exe" -SkipFinalScan
```

---

## Gérer les exclusions (risques acceptés)

C'est le mécanisme central : toute mesure peut être désactivée, mais **jamais sans justification formelle**.

### Fichier Configs/exclusions.json

Ouvrez le fichier et ajoutez une entrée par mesure à exclure :

```json
{
  "exclusions": [
    {
      "measureId": "HAD-NTLM-001",
      "justification": "Applications metier legacy (ERP v8) encore dependantes de NTLMv1. Migration planifiee Q3.",
      "acceptedBy": "j.dupont (RSSI)",
      "acceptedDate": "2026-06-15",
      "reviewDate": "2026-09-30"
    }
  ]
}
```

### Règles de validation (appliquées automatiquement)

| Champ           | Obligatoire | Contrainte                                  |
|-----------------|:-----------:|---------------------------------------------|
| measureId       | oui         | Doit correspondre à un ID du catalogue      |
| justification   | oui         | 20 caractères minimum                       |
| acceptedBy      | oui         | Identité du responsable qui valide le risque |
| acceptedDate    | oui         | Date valide (format YYYY-MM-DD)             |
| reviewDate      | non         | Date de revue recommandée                   |

Si une seule exclusion est incomplète ou mal justifiée, **le script s'arrête immédiatement** et affiche l'erreur. Rien n'est modifié sur le domaine.

### Trouver les measureId disponibles

Les identifiants sont listés dans `Configs/hardening-tasks.json`. Mesures actuellement disponibles :

| ID              | Mesure                                          | Sévérité |
|-----------------|------------------------------------------------|----------|
| HAD-SMB-001     | Désactivation SMBv1                            | High     |
| HAD-LDAP-001    | LDAP Signing obligatoire                       | High     |
| HAD-LDAP-002    | LDAP Channel Binding                           | Medium   |
| HAD-SPOOL-001   | Print Spooler désactivé sur les DC             | High     |
| HAD-NTLM-001    | Restriction NTLM (mode audit)                  | Medium   |
| HAD-KRB-001     | Protection contre la délégation non contrainte  | High     |
| HAD-PWD-001     | Rotation des mots de passe machine              | Low      |

---

## Ajouter une nouvelle mesure

### Étape 1 — Déclarer dans le catalogue

Ajoutez un objet dans `Configs/hardening-tasks.json`, section `tasks` :

```json
{
  "id": "HAD-CERT-001",
  "name": "Remove ESC1 vulnerable templates",
  "description": "Supprime les templates de certificats vulnerables a l'attaque ESC1.",
  "category": "Anomalies",
  "pingCastleRule": "A-CertTempVuln",
  "severity": "High",
  "applyFunction": "Remove-ESC1Templates",
  "rollbackFunction": "Restore-ESC1Templates",
  "testFunction": "Test-ESC1Templates",
  "canBeSkipped": true
}
```

### Étape 2 — Implémenter dans le module Hardening

Ouvrez `Modules/HAD.Hardening.psm1` et ajoutez les 3 fonctions :

```powershell
function Remove-ESC1Templates {
    # Votre logique d'application
}
function Restore-ESC1Templates {
    # Votre logique de rollback
}
function Test-ESC1Templates {
    # Retourne $true si la mesure est déjà en place, $false sinon
    return $false
}
```

Le moteur appellera automatiquement ces fonctions par leur nom.

---

## Lire les résultats

Après exécution, les sorties sont dans `Outputs/<timestamp>/` :

| Fichier                | Contenu                                              |
|------------------------|------------------------------------------------------|
| pingcastle_before.xml  | Rapport PingCastle avant hardening                   |
| pingcastle_after.xml   | Rapport PingCastle après hardening                   |
| risk_register.json     | Registre horodaté des risques acceptés (preuve audit)|
| report.html            | Rapport comparatif visuel (ouvrir dans un navigateur)|

Le **rapport HTML** contient trois sections : le delta de score PingCastle (global et par catégorie), la liste des mesures avec leur statut (Applied, Skipped, Error), et le registre complet des risques acceptés avec justifications.

Les **transcripts** PowerShell sont dans `Logs/harden-<timestamp>.log`.

---

## Statuts possibles d'une mesure

| Statut                   | Signification                                         |
|--------------------------|-------------------------------------------------------|
| Applied                  | Mesure appliquée et vérifiée avec succès               |
| AlreadyCompliant         | La mesure était déjà en place, rien à faire            |
| WouldApply               | Mode DryRun : la mesure serait appliquée               |
| AppliedButNotVerified    | Appliquée mais le test de vérification a échoué        |
| Skipped - Risk Accepted  | Exclue via le fichier d'exclusions                     |
| Error                    | Échec de l'application (voir le message détaillé)      |

---

## Bonnes pratiques

- Toujours commencer par un `-DryRun` en environnement de pré-production.
- LDAP signing et channel binding peuvent casser des applications legacy : valider avec les équipes applicatives avant de retirer l'exclusion.
- Archiver le dossier `Outputs/<timestamp>/` complet après chaque exécution : il constitue la preuve d'audit.
- Prévoir une revue périodique des exclusions : les `reviewDate` du registre sont là pour ça.
- Le tiering (comptes, OU, groupes, GPO) est géré par un script séparé : ne pas mélanger les deux périmètres.
