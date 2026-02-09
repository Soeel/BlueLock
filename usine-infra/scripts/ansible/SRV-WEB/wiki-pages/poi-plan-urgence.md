# POI - Plan d'Organisation Interne

> **Classification : Document reglementaire**
> Derniere revision : 12/01/2025 | Prochaine revision : 12/01/2026
> Responsable : Nathalie Morel (HSE)

---

## 1. Objet

Le present Plan d'Organisation Interne (POI) definit l'organisation et les moyens mis en oeuvre par le site de **Blue Chemicals - Saint-Flour** en cas d'accident majeur au sens de la directive Seveso.

Le site est classe **Seveso seuil bas** en raison des quantites de produits chimiques stockees.

## 2. Scenarios d'accident majeur identifies

| Ref | Scenario | Zone | Produit | Consequence |
|-----|----------|------|---------|-------------|
| S-01 | Fuite HCl sur bac de stockage T-101 | Zone Stockage Nord | Acide Chlorhydrique 33% | Nuage toxique |
| S-02 | Emballement thermique reacteur R-201 | Atelier Reaction 2 | Soude Caustique + additifs | Surpression / projection |
| S-03 | Incendie zone solvants | Magasin Solvants | Solvant A-401, Toluene | Incendie / BLEVE |
| S-04 | Deversement accidentel en retention | Zone Chargement | Divers | Pollution sol / eau |

## 3. Alerte et declenchement

### 3.1 Niveaux d'alerte

| Niveau | Denomination | Declencheur | Action |
|--------|-------------|-------------|--------|
| 1 | **Vigilance** | Detection gaz / anomalie SCADA | Information chef de quart |
| 2 | **Pre-alerte** | Confirmation terrain | Activation cellule de crise |
| 3 | **Alerte POI** | Accident avere | Declenchement complet du POI |
| 4 | **Alerte PPI** | Risque hors site | Appel Prefet / SDIS |

### 3.2 Chaine d'alerte

```
Detection (SCADA / operateur terrain)
    |
    v
Chef de quart (Poste 5100 - 24/7)
    |
    +---> Directeur de site (J-M. Renault - 5001)
    +---> Responsable HSE (N. Morel - 5040)
    +---> Pompiers internes (Poste 5060)
    |
    v (si niveau 3+)
Cellule de crise (Salle de reunion direction)
    |
    v (si niveau 4)
SDIS 15 (Cantal) : 18 / 112
Prefecture Cantal : 04.71.46.23.00
```

## 4. Points de rassemblement

| Zone | Point de rassemblement | Responsable comptage |
|------|----------------------|----------------------|
| Ateliers Reaction | Parking visiteurs (PR-1) | Chef d'equipe Procedes |
| Laboratoire | Pelouse entree principale (PR-2) | Responsable Labo |
| Bureaux / Direction | Parking visiteurs (PR-1) | Assistante direction |
| Maintenance | Entree logistique (PR-3) | Chef maintenance |
| Zone Stockage | Parking visiteurs (PR-1) | Chef de quart |

## 5. Moyens d'intervention internes

- 2 RIA (Robinets d'Incendie Armes) par atelier
- 1 canon a mousse mobile (zone solvants)
- 4 douches de securite / rince-oeil
- Extincteurs CO2 et poudre (voir plans affiches)
- Retention bac T-101 : 35 m3 (110% capacite)
- Rideau d'eau automatique zone stockage HCl

## 6. Consignes par scenario

### S-01 : Fuite HCl (nuage toxique)

1. Declencher alarme zone (bouton rouge borne ZS-N01)
2. Couper l'alimentation du bac T-101 depuis SCADA (vanne XV-101)
3. Activer le rideau d'eau
4. Evacuer dans le sens oppose au vent (voir manche a air)
5. Confiner les batiments fermes (ordre chef de quart)
6. Appeler les secours si niveau 3+

### S-03 : Incendie zone solvants

1. Declencher alarme incendie (bouton rouge)
2. **NE PAS utiliser d'eau** - Utiliser extincteurs CO2 ou mousse uniquement
3. Couper la ventilation du magasin solvants (commande locale ou SCADA)
4. Evacuer le personnel vers PR-3
5. Informer le chef de quart

## 7. Exercices et formations

| Exercice | Frequence | Dernier | Prochain |
|----------|-----------|---------|----------|
| Evacuation generale | Annuel | 15/01/2025 | 01/2026 |
| Exercice POI complet | Annuel | 20/09/2024 | 09/2025 |
| Formation equipier incendie | Semestriel | 10/11/2024 | 05/2025 |
| Exercice confine (HCl) | Annuel | 15/01/2025 | 01/2026 |

---

*Ce document est affiche dans chaque atelier et disponible sur `\\SRV-FILES01\HSE\POI_Plan_Urgence`*
