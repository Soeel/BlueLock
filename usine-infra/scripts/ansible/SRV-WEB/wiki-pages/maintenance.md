# Maintenance Industrielle

> Responsable : Philippe Dubois (Chef Maintenance)
> Equipe : 6 techniciens (mecanique, electricite, instrumentation)

---

## 1. Organisation de la maintenance

### 1.1 Types de maintenance

| Type | Description | Frequence | Outil |
|------|-------------|-----------|-------|
| Preventive systematique | Gammes planifiees (graissage, controle, remplacement) | Selon plan | Plan preventif Excel |
| Preventive conditionnelle | Basee sur les mesures (vibrations, temperature) | Selon seuils SCADA | Tags SCADA + historique |
| Corrective | Depannage sur panne | Sur evenement | Demande d'intervention |
| Reglementaire | Controles periodiques obligatoires | Annuel / 2 ans | Organismes agrees |

### 1.2 Circuit d'une demande d'intervention

```
Demandeur (operateur, chef de quart)
    |
    v
Demande d'Intervention (DI) sur papier ou mail
    |
    v
Chef maintenance (priorisation)
    |
    +--> Urgence : intervention immediate
    +--> Normal  : planification semaine suivante
    +--> Arret   : integration planning arret technique
    |
    v
Technicien assigne
    |
    v
Intervention (avec permis de travail si necessaire)
    |
    v
Compte-rendu + cloture DI
    |
    v
Archivage -> \\SRV-FILES01\Maintenance\Historique_Interventions\
```

## 2. Inventaire des equipements critiques

| Repere | Equipement | Atelier | Criticite | Freq. preventif |
|--------|-----------|---------|-----------|-----------------|
| R-101 | Reacteur agite 5 m3 | Reaction 1 | A (critique) | Mensuel |
| R-201 | Reacteur double enveloppe 3 m3 | Reaction 2 | A (critique) | Mensuel |
| C-301 | Colonne distillation 20 plateaux | Distillation | A (critique) | Trimestriel |
| P-101 | Pompe centrifuge alimentation HCl | Reaction 1 | B (important) | Trimestriel |
| P-102 | Pompe centrifuge transfert PF | Reaction 1 | B (important) | Trimestriel |
| P-201 | Pompe doseuse NaOH | Reaction 2 | B (important) | Mensuel |
| P-301 | Pompe reflux distillation | Distillation | A (critique) | Mensuel |
| AG-101 | Agitateur reacteur R-101 | Reaction 1 | A (critique) | Semestriel |
| T-101 | Bac stockage HCl 30 m3 | Stockage | A (critique) | Annuel (arret) |
| T-201 | Bac stockage NaOH 20 m3 | Stockage | B (important) | Annuel (arret) |
| ECH-101 | Echangeur thermique R-101 | Reaction 1 | B (important) | Semestriel |

## 3. Plan de maintenance preventive - Extrait

### 3.1 Gamme mensuelle - Reacteur R-101

| Operation | Duree | Outillage | Pieces de rechange |
|-----------|-------|-----------|-------------------|
| Controle visuel cuve et agitateur | 15 min | Lampe, miroir | - |
| Verification etancheite presse-etoupe agitateur | 10 min | - | Joint presse-etoupe (stock) |
| Graissage palier agitateur | 10 min | Pompe a graisse | Graisse XM2 (stock) |
| Controle vibrations moteur agitateur | 15 min | Vibrometre portable | - |
| Verification soupape de securite PSV-101 | 10 min | - | - |
| Controle visuel tuyauteries et vannes | 20 min | - | - |

**Consignations necessaires** : Arret agitateur, isolement electrique coffret AG-101

### 3.2 Gamme trimestrielle - Pompe P-101

| Operation | Duree | Outillage | Pieces de rechange |
|-----------|-------|-----------|-------------------|
| Controle alignement moteur/pompe | 30 min | Comparateur, regle | - |
| Remplacement garniture mecanique | 1h | Cle a griffe, extracteur | Garniture ref. GM-P101 |
| Controle vibrations | 15 min | Vibrometre | - |
| Verification pression aspiration/refoulement | 10 min | Manometre etalon | - |
| Nettoyage filtre aspiration | 20 min | - | Joint filtre (stock) |

**Consignations necessaires** : Isolement vannes + electrique + vidange ligne

## 4. Controles reglementaires

| Equipement | Reglementation | Organisme | Frequence | Dernier | Prochain |
|-----------|---------------|-----------|-----------|---------|----------|
| Reacteurs R-101, R-201 | DESP / AM 20/11/2017 | APAVE | 2 ans (inspection) | 03/2024 | 03/2026 |
| Bac T-101 (HCl) | DESP + ICPE | APAVE | Annuel | 09/2024 | 09/2025 |
| Soupapes PSV | DESP | APAVE | Annuel (retarage) | 09/2024 | 09/2025 |
| Installations electriques | Art. R4226-14 CT | DEKRA | Annuel | 06/2024 | 06/2025 |
| Ponts roulants | AM 01/03/2004 | SOCOTEC | 12 mois | 11/2024 | 11/2025 |
| Extincteurs | Art. R4227-39 CT | Prestataire agr. | Annuel | 01/2025 | 01/2026 |
| Detections gaz | ATEX | DEKRA | Annuel | 10/2024 | 10/2025 |

## 5. Permis de travail

Tout travail de maintenance dans les zones de production necessite un permis :

| Type de permis | Conditions | Valideur |
|---------------|------------|----------|
| Permis general | Travaux standards hors zone ATEX | Chef maintenance |
| Permis feu | Soudure, meulage, travaux par points chauds | HSE + Chef de quart |
| Permis de penetration | Entree en espace confine (reacteur, bac) | HSE + Chef de quart + Detection gaz |
| Permis de fouille | Travaux en tranchee | HSE |

> Formulaires sur `\\SRV-FILES01\Maintenance\Gammes_Maintenance\Permis_Travail\`

---

*Historique des interventions : `\\SRV-FILES01\Maintenance\Historique_Interventions\`*
*Plans de maintenance : `\\SRV-FILES01\Maintenance\Plans_Preventif\`*
