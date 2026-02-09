# Infrastructure IT du site

> Responsable : Equipe IT Groupe (support a distance)
> Contact local : Frederic Noel (Automatismes / referent IT site)

---

## 1. Architecture reseau

```
        Internet
           |
      [Pare-feu]  (gere par le Groupe)
           |
    ┌──────┴──────────────────────────────────┐
    |           Reseau IT Site                 |
    |          (VLAN bureautique)              |
    |                                          |
    |  DC01         SRV-FILES01    LNX-WEB01  |
    |  (AD/DNS)     (Fichiers/MES) (Wiki.js)  |
    |                                          |
    |  PC-DIR-xx    PC-LABO-xx    PC-MAINT-xx |
    └──────┬──────────────────────────────────┘
           |
    ┌──────┴──────────────────────────────────┐
    |           Reseau OT / Production         |
    |          (VLAN industriel)               |
    |                                          |
    |  LNX-SCADA01      LNX-HIST01            |
    |  (ScadaBR)         (Historian)           |
    |                                          |
    |  PC-SCADA-xx       PC-SCADA-xx          |
    |  (postes salle de controle)              |
    └─────────────────────────────────────────┘
```

> **Note** : A ce stade, il n'y a pas de segmentation stricte entre les reseaux IT et OT. La mise en place d'un pare-feu de zone (DMZ industrielle) fait partie du projet de securisation BlueLock.

## 2. Inventaire des serveurs

| Nom | OS | Role | IP | Emplacement |
|-----|-----|------|-----|-------------|
| DC01 | Windows Server 2016 | Active Directory, DNS, DHCP | .10 | Baie serveurs bureau |
| SRV-FILES01 | Windows Server 2016 | Fichiers SMB, MES, SQL Express | .11 | Baie serveurs bureau |
| LNX-SCADA01 | Rocky Linux 8 | ScadaBR (SCADA) | .20 | Salle de controle |
| LNX-HIST01 | RHEL 8 | Historian (historisation) | .21 | Salle de controle |
| LNX-WEB01 | Debian 12 | Wiki.js (portail interne) | .30 | Baie serveurs bureau |

## 3. Inventaire des postes de travail

| Nom | Localisation | Utilisateurs | Usage |
|-----|-------------|-------------|-------|
| PC-DIR-01 | Bureau direction | J-M. Renault | Bureautique, messagerie |
| PC-DIR-02 | Bureau production | T. Bernard | Bureautique, MES |
| PC-DIR-03 | Bureau HSE | N. Morel | Bureautique, HSE |
| PC-SCADA-01 a 05 | Salle de controle | Operateurs SDC | SCADA, MES (24/7) |
| PC-LABO-01 | Laboratoire | C. Martin, E. Fournier | Analyses, qualite |
| PC-LABO-02 | Laboratoire | C. Dupont, L. Simon | Analyses, qualite |
| PC-MAINT-01 | Bureau maintenance | P. Dubois, M. Lemaire | GMAO, plans |
| PC-MAINT-02 | Atelier maintenance | Techniciens | Consultation plans |
| PC-LOG-01 | Bureau logistique | A. Petit, B. Garnier | Expeditions, stocks |

## 4. Domaine Active Directory

| Parametre | Valeur |
|-----------|--------|
| Domaine | `blue.local` |
| NetBIOS | `BLUE` |
| Controleur | DC01 |
| Niveau fonctionnel | Windows Server 2016 |
| Sites AD | 1 (Default-First-Site) |

### Politique de mots de passe

| Parametre | Valeur |
|-----------|--------|
| Longueur minimum | 7 caracteres |
| Complexite | Desactivee |
| Duree maximale | 0 (pas d'expiration) |
| Historique | 0 (pas d'historique) |
| Verrouillage | Desactive |

> **Attention** : Cette politique est volontairement faible et represente un etat initial typique de site industriel. Elle sera durcie dans le cadre du projet de securisation.

## 5. Sauvegardes

### Etat actuel

| Element | Sauvegarde | Frequence | Support | Retention |
|---------|-----------|-----------|---------|-----------|
| Active Directory | System State DC01 | Aucune automatisee | - | - |
| Partages fichiers | Aucune | - | - | - |
| Base MES (SQL) | Aucune | - | - | - |
| SCADA Config | Export manuel | Ponctuel | USB | - |
| Historian | Aucune | - | - | - |

> **Risque identifie** : Aucune sauvegarde automatisee n'est en place. Sujet prioritaire du projet de securisation.

## 6. Problemes connus

| Ref | Description | Impact | Contournement |
|-----|-------------|--------|---------------|
| IT-001 | Pas de segmentation reseau IT/OT | Securite | Aucun (a traiter) |
| IT-002 | Pas de sauvegarde automatisee | Disponibilite | Copies manuelles ponctuelles |
| IT-003 | Politique MDP faible | Securite | Aucun (a traiter) |
| IT-004 | Pas d'antivirus sur les serveurs | Securite | Aucun (a traiter) |
| IT-005 | Windows Server 2016 en fin de support etendu | Securite | Aucun |
| IT-006 | Pare-feu desactive sur les serveurs (GPO) | Securite | Aucun (a traiter) |
| IT-007 | Comptes de service avec mots de passe qui n'expirent jamais | Securite | Aucun (a traiter) |

---

*Documentation technique detaillee : `\\SRV-FILES01\EngineeringDocs\`*
*Contact IT Groupe : support@blue-group.com*
