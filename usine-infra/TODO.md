
## 1) Objectif
Mettre en place un environnement de test représentatif d’un système industriel afin de :
- déployer les briques OT et IT principales
- valider les flux fonctionnels entre systèmes

## 2) Domaine Active Directory

- Domaine : blue.local
- NetBIOS : BLUE

Contrôleur de domaine :
- DC01

## 3) Machines à déployer (VMs)

### 3.1 Windows

1) DC01  
- OS : Windows Server 2012 R2  
- Rôle : Active Directory + DNS  

2) SRV-FILES01  
- OS : Windows Server 2016  
- Rôle : Serveur de fichiers (SMB)  

3) SRV-APP01  
- OS : Windows Server 2012 R2  
- Rôle : Serveur applicatif (MES + ERP/GMAO – simulation)

### 3.2 Linux


5) LNX-SCADA01  
- OS : Rocky Linux 9  
- Rôle : SCADA / Supervision  

6) LNX-HIST01  
- OS : RHEL 8.x ou Rocky 8  
- Rôle : Historian (stockage des données process)

7) LNX-WEB01  
- OS : Debian 12  
- Rôle : Portail web interne

## 4) Env AD
Trouvé un script pas trop exigeant pour déploiment de utilisateurs, groupes ...
Et déployer des vulns

## 5) Partages réseau

Serveur : SRV-FILES01

| Partage         | Usage                     |
| --------------- | ------------------------- |
| ProductionDocs  | Documentation production  |
| QualityDocs     | Procédures qualité        |
| EngineeringDocs | Études et docs techniques |
| Confidentiel    | Brevets et Contrats       |

## 6) Logiciels à installer

### DC01
- AD DS
- DNS
- Création du domaine usine.local
- Création des comptes et groupes

### SRV-FILES01
- Rôle File Server
- Partages SMB

### SRV-APP01
- Joindre le domaine
- Installer prérequis applicatifs :
  - IIS / .NET (si besoin)
  - SQL Server Express (optionnel)
- Déployer une application factice (MES / ERP local)

### LNX-SCADA01
- Installer un outil SCADA (ScadaBR / Mango Automation)
- Configurer la collecte depuis LNX-PLC01
- Créer des tags process simples

### LNX-HIST01
- Installer InfluxDB ou TimescaleDB
- Stocker les mesures issues du SCADA
- Vérifier l’enregistrement temporel

### LNX-WEB01
- Installer Apache + PHP
- Déployer un portail interne simple :
  - documentation
  - liens vers SCADA / MES

## 7) Tests de validation

- Résolution DNS entre toutes les machines
- Connexion AD
- Accès aux partages SMB
- Lecture des valeurs PLC depuis SCADA
- Enregistrement des données dans l’Historian
- Accès web au portail interne