# Package Tiering AD auto domaine + GPO

## Objectif
Ce package implemente un modele Tiering AD simple a partir des CSV.
Le script detecte automatiquement le domaine AD via `Get-ADDomain`.

## Fichiers
- `Implement-TieringModelAD.ps1` : script principal
- `Comptes_Admin_Tiering.csv` : comptes admin a creer
- `Serveurs_Tiering.csv` : serveurs a classer par tier
- `Tableau_Tiering_AD_Auto_GPO.xlsx` : version Excel lisible du modele

## Nomenclature des comptes admin
Les comptes sont au format :
- `admt0...` pour les comptes T0
- `admt1...` pour les comptes T1
- `admt2...` pour les comptes T2

Exemple : `admt0hdubois`, `admt1lmartin`, `admt2nrobert`.

## Commandes
Test sans modification :
```powershell
.\Implement-TieringModelAD.ps1 -WhatIf
```

Mettre a jour les CSV avec le vrai domaine detecte :
```powershell
.\Implement-TieringModelAD.ps1 -UpdateInputCsv
```

Execution complete avec deplacement serveurs et droits via GPO :
```powershell
.\Implement-TieringModelAD.ps1 -UpdateInputCsv -MoveServersToOUs -ConfigureGpoLocalAdminRights
```

## Droits via GPO
Le script cree une GPO par tier :
- `GPO_Tiering_T0_Local_Admins`
- `GPO_Tiering_T1_Local_Admins`
- `GPO_Tiering_T2_Local_Admins`

Chaque GPO est liee a l'OU serveur correspondante :
- `OU=T0,OU=Servers,...`
- `OU=T1,OU=Servers,...`
- `OU=T2,OU=Servers,...`

La GPO ajoute le groupe AD du tier dans le groupe Administrators local du serveur via un script de demarrage ordinateur.
Le script utilise le SID local `S-1-5-32-544`, donc il fonctionne sur Windows FR et EN.

## Exports generes
- `exports\MotsDePasse_Comptes_Admin.csv`
- `exports\Matrice_Acces_Serveurs.csv`
- `exports\Domaine_Detecte.csv`

## Notes importantes
- Aucun mot de passe n'est envoye par mail.
- Les mots de passe generes contiennent uniquement des lettres et chiffres.
- Les serveurs doivent exister dans AD pour etre deplaces.
- Lance le script avec un compte ayant les droits de creation OU, groupes, comptes, GPO et deplacement d'objets ordinateurs.
