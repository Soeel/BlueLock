## 1. Objectif du document

Ce document décrit l’environnement de test utilisé dans le cadre du projet de déploiement d’un socle de sécurité pour un système d’information industriel.

L’environnement est volontairement représentatif d’un **site industriel existant**, tel qu’il peut être rencontré lors du rachat d’une usine, avant toute démarche de sécurisation.

La description s’appuie sur le **modèle ISA-95 (Purdue Model)**, largement utilisé pour structurer les systèmes industriels.

## 2. Référence au modèle ISA-95

### 2.1 Présentation générale

La norme **ISA-95** (également connue sous le nom de **Purdue Enterprise Reference Architecture – PERA**) est un standard international utilisé pour définir l’architecture fonctionnelle des systèmes industriels.

Son objectif principal est de :
- structurer les systèmes industriels et informatiques,
- clarifier les responsabilités de chaque couche fonctionnelle,
- faciliter l’intégration entre les mondes **OT (Operational Technology)** et **IT (Information Technology)**.

ISA-95 est largement utilisée dans les secteurs industriels fortement réglementés, notamment :
- chimie,
- énergie,
- pharmaceutique,
- agroalimentaire.

### 2.2 Objectifs de la norme ISA-95

La norme ISA-95 vise à répondre à plusieurs problématiques industrielles majeures :
- **Réduction de la complexité** des systèmes industriels
- **Standardisation des échanges** entre niveaux OT et IT
- **Amélioration de l’interopérabilité** entre outils de différents éditeurs
- **Clarification des flux de données** entre production et gestion

Dans le cadre de ce projet, ISA-95 sert de **référentiel d’architecture** pour structurer l’environnement de test.

### 2.3 Description détaillée des niveaux ISA-95

#### Niveau 0 – Processus / Terrain

Ce niveau correspond aux **processus physiques** de l’usine.

Il inclut :
- capteurs (température, pression, débit, pH, conductivité),
- actionneurs (vannes, pompes, moteurs, agitateurs).

Ces éléments interagissent directement avec la matière et les équipements de production.

#### Niveau 1 – Automatisation

Le niveau 1 assure le **pilotage direct du procédé**.

Il comprend :
- automates programmables industriels (PLC / API),
- IHM locales de ligne.

Dans ce projet, ce niveau est **pris en compte de manière conceptuelle**, sans implémentation matérielle ou logicielle directe.

#### Niveau 2 – Supervision / Contrôle

Le niveau 2 permet la **supervision globale du procédé**.

Il regroupe :
- SCADA (Supervisory Control And Data Acquisition),
- DCS (Distributed Control System).

Fonctions principales :
- visualisation temps réel,
- gestion des alarmes,
- contrôle et régulation,
- historisation court terme.

#### Niveau 3 – MES (Manufacturing Execution System)

Le niveau 3 se situe à la frontière de l’OT et de l’IT.

Il assure :
- la gestion opérationnelle de la production,
- le suivi des lots et recettes,
- la traçabilité,
- le calcul des indicateurs de performance (KPI).

#### Niveau 4 – ERP / SI d’entreprise

Le niveau 4 correspond aux systèmes de gestion de l’entreprise.

Il inclut :
- ERP,
- GMAO,
- systèmes de gestion des stocks et des achats.

Ce niveau se concentre sur la **planification et la gestion globale**, et non sur le temps réel.

### 2.4 Intérêt d’ISA-95 pour le projet

L’utilisation du modèle ISA-95 dans ce projet permet :
- d’avoir une **vision claire et structurée** du SI industriel,
- d’identifier précisément les points d’interconnexion entre niveaux,
- de préparer l’introduction progressive des mécanismes de sécurité,
- d’éviter les approches monolithiques ou non adaptées au monde industriel.

## 3. Périmètre et hypothèses

- L’usine dispose déjà de son propre SI local.
- Certaines briques sont anciennes en raison de contraintes éditeurs.
- Les systèmes critiques de production ne peuvent pas être modifiés librement.
- Aucune mesure de sécurité avancée n’est encore en place à ce stade.

L’objectif est de disposer d’un **état initial réaliste**, servant de base à la transformation sécurisée ultérieure.

## 4. Description par niveau ISA-95

### 4.1 Niveau 0 – Processus / Terrain (conceptuel)

Le niveau 0 correspond aux éléments physiques du procédé industriel :
- Capteurs : température, pression, débit, niveau, pH, conductivité
- Actionneurs : vannes, pompes, moteurs, agitateurs, convoyeurs

Ces éléments ne sont pas virtualisés dans l’environnement de test.  
Ils sont considérés comme **existants et opérationnels**.

### 4.2 Niveau 1 – Automatisation (conceptuel)

Le niveau 1 correspond aux équipements d’automatisation industrielle :
- Automates programmables industriels (API / PLC)
- IHM locales de ligne

Dans le cadre de ce projet, **le niveau 1 n’est pas implémenté techniquement**.  
Les logiques de contrôle et les données terrain sont **simulées directement au niveau SCADA**.

### 4.3 Niveau 2 – Supervision / Contrôle

Le niveau 2 assure la supervision et le contrôle des procédés industriels.

**Serveur associé :** `LNX-SCADA01`
- **OS** : Rocky Linux 9
- **Produits représentés** :
  - AVEVA Wonderware
  - Siemens PCS7
  - Honeywell Experion
- **Fonctions** :
  - Simulation et collecte des données process
  - Supervision des procédés
  - Visualisation opérateur
  - Génération d’événements et d’alarmes

Ce niveau constitue la première brique technique réellement implémentée.

### 4.4 Historisation industrielle (transverse niveaux 2–3)

**Serveur associé :** `LNX-HIST01`
- **OS** : RHEL 8.x
- **Produit représenté** : OSIsoft PI System
- **Fonctions** :
  - Stockage long terme des données process
  - Analyse post-production
  - Reporting et audits réglementaires

### 4.5 Niveau 3 – MES (Manufacturing Execution System)

**Serveur associé :** `SRV-APP01`
- **OS** : Windows Server 2012 R2
- **Produits représentés** :
  - AVEVA MES
  - Siemens Opcenter
- **Fonctions** :
  - Ordonnancement de la production
  - Suivi des lots et recettes
  - Traçabilité matières premières / produits finis
  - Calcul des KPI

### 4.6 Niveau 4 – ERP / SI d’entreprise (partiel)

**Serveur associé :** `SRV-APP01`
- **Produits représentés** :
  - ERP local (ex : SAP PM)
  - GMAO (ex : Infor EAM)
- **Fonctions** :
  - Gestion des stocks
  - Maintenance industrielle
  - Interfaces avec le MES

## 5. Services transverses IT

### 5.1 Annuaire et authentification
- Serveur : `DC01`
- OS : Windows Server 2012 R2
- Services : Active Directory, DNS

### 5.2 Serveur de fichiers
- Serveur : `SRV-FILES01`
- OS : Windows Server 2016
- Services : SMB

### 5.3 Portail web interne
- Serveur : `LNX-WEB01`
- OS : Debian 12
- Services : Apache, PHP

## 6. Flux fonctionnels entre les composants

### 6.1 Flux niveau 0 / 1 → niveau 2

| Source                     | Destination           | Type de données              | Mécanisme            | Description                          |
|----------------------------|-----------------------|------------------------------|----------------------|--------------------------------------|
| Processus simulé           | SCADA (LNX-SCADA01)   | Température, pression, débit | Simulation interne   | Génération et supervision des données|

### 6.2 Flux niveau 2 → Historian

| Source              | Destination            | Type de données     | Protocole             | Description              |
|---------------------|------------------------|---------------------|-----------------------|--------------------------|
| SCADA (LNX-SCADA01) | Historian (LNX-HIST01) | Mesures, événements | API / Base de données | Historisation long terme |

### 6.3 Flux niveau 2 → niveau 3

| Source              | Destination        | Type de données    | Protocole             | Description              |
|---------------------|-------------------|--------------------|-----------------------|--------------------------|
| SCADA (LNX-SCADA01) | MES (SRV-APP01)   | Données production | API / Services métier | Transmission production |

### 6.4 Flux Historian → MES

| Source                 | Destination      | Type de données | Protocole  | Description        |
|------------------------|------------------|----------------|------------|--------------------|
| Historian (LNX-HIST01) | MES (SRV-APP01)  | Historique, KPI| API / DB   | Calcul indicateurs |

### 6.5 Flux niveau 3 → niveau 4

| Source          | Destination | Type de données | Protocole       | Description             |
|-----------------|-------------|----------------|-----------------|-------------------------|
| MES (SRV-APP01) | ERP / GMAO  | Ordres, stocks | Services métier | Synchronisation gestion |

### 6.6 Flux IT transverses

| Source        | Destination              | Type de données          | Protocole       | Description            |
|---------------|--------------------------|--------------------------|-----------------|------------------------|
| Utilisateurs  | AD (DC01)                | Authentification         | Kerberos / LDAP | Connexion utilisateurs |
| Serveurs      | AD (DC01)                | Authentification machine | Kerberos        | Intégration domaine    |
| Applications  | Fichiers (SRV-FILES01)   | Données métiers          | SMB             | Accès documents        |
| Utilisateurs  | Portail web (LNX-WEB01)  | Accès web                | HTTP / HTTPS    | Accès outils internes  |

## 7. Synthèse de l’environnement

| Niveau ISA-95 | Composants                | Serveurs                             |
|---------------|---------------------------|--------------------------------------|
| Niveau 0      | Capteurs / actionneurs    | Conceptuel                           |
| Niveau 1      | Automatisation            | Conceptuel                           |
| Niveau 2      | SCADA / DCS               | LNX-SCADA01                          |
| Historian     | Historisation             | LNX-HIST01                           |
| Niveau 3      | MES                       | SRV-APP01                            |
| Niveau 4      | ERP / GMAO                | SRV-APP01 (partiel)                  |
| IT transverse | AD, fichiers, portail web | DC01, SRV-FILES01, LNX-WEB01         |

## 8. Conclusion

Cet environnement de test reproduit fidèlement un système d’information industriel d’usine chimique conforme au modèle ISA-95.

Il constitue une base réaliste et cohérente pour l’introduction progressive d’un socle de sécurité industriel.
