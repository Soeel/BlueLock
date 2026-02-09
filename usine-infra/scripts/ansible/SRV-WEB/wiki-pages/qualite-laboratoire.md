# Qualite et Laboratoire

> Responsable : Dr. Claire Martin (Responsable Laboratoire)
> Equipe : 4 personnes (2 techniciens analyse, 1 ingenieur qualite, 1 responsable)

---

## 1. Missions du laboratoire

- Controle qualite des matieres premieres a reception
- Suivi en cours de fabrication (analyses process)
- Liberation des lots produits finis
- Gestion des non-conformites
- Suivi metrologique des instruments de mesure
- Gestion des echantillotheques (conservation 2 ans)

## 2. Plan de controle - Produits

### 2.1 Acide Chlorhydrique 33%

| Analyse | Methode | Specification | Frequence | Delai resultat |
|---------|---------|---------------|-----------|----------------|
| Concentration HCl | Titrage NaOH 1N | 32.0 - 34.0 % | Chaque lot | 30 min |
| Densite | Densimetre | 1.159 - 1.163 | Chaque lot | 5 min |
| Fer total | Spectro. absorption atomique | < 5 ppm | Chaque lot | 2h |
| Residus d'evaporation | Gravimetrie | < 50 ppm | 1x/semaine | 4h |
| Aspect visuel | Visuel | Limpide, incolore | Chaque lot | Immediat |

### 2.2 Soude Caustique 50%

| Analyse | Methode | Specification | Frequence | Delai resultat |
|---------|---------|---------------|-----------|----------------|
| Concentration NaOH | Titrage HCl 1N | 49.0 - 51.0 % | Chaque lot | 30 min |
| Carbonate de sodium | Titrage BaCl2 | < 0.5 % | Chaque lot | 1h |
| Chlorure de sodium | Argentimetrie | < 200 ppm | 1x/semaine | 1h |
| Densite | Densimetre | 1.525 - 1.530 | Chaque lot | 5 min |

### 2.3 Solvant A-401

| Analyse | Methode | Specification | Frequence | Delai resultat |
|---------|---------|---------------|-----------|----------------|
| Point eclair | Pensky-Martens (vase clos) | > 23°C | Chaque lot | 45 min |
| Teneur en eau | Karl Fischer | < 0.1 % | Chaque lot | 20 min |
| Indice de refraction | Refractometre | 1.495 - 1.500 | Chaque lot | 5 min |
| Purete GC | Chromatographie gaz | > 99.5 % | Chaque lot | 1h30 |

## 3. Equipements du laboratoire

| Equipement | Marque/Modele | Ref interne | Etalonnage |
|-----------|--------------|-------------|------------|
| Balance analytique | Mettler Toledo XPE205 | BAL-001 | Annuel (COFRAC) |
| pH-metre | Metrohm 914 | pH-001 | Mensuel (interne) |
| Spectro. absorption atomique | Agilent 240 FS AA | SAA-001 | Annuel (COFRAC) |
| Chromatographe gaz | Shimadzu GC-2014 | GC-001 | Annuel (COFRAC) |
| Karl Fischer | Metrohm 870 Titrino | KF-001 | Semestriel (interne) |
| Densimetre | Anton Paar DMA 4500 | DEN-001 | Annuel (COFRAC) |
| Refractometre | Bellingham + Stanley RFM340 | REF-001 | Annuel (COFRAC) |
| Etuve | Memmert UF110 | ETU-001 | Annuel (interne) |

## 4. Gestion des non-conformites

### 4.1 Procedure

```
Detection (labo, production, client)
    |
    v
Ouverture fiche NC (numero NC-AAAA-XXX)
    |
    v
Analyse causes (5 pourquoi / Ishikawa)
    |
    v
Actions immediates (quarantaine lot, tri)
    |
    v
Actions correctives
    |
    v
Verification efficacite (30 jours)
    |
    v
Cloture NC
```

### 4.2 Non-conformites en cours

| Ref | Date | Produit | Description | Statut |
|-----|------|---------|-------------|--------|
| NC-2025-003 | 28/01/2025 | HCl 33% | Fer total = 7 ppm (spec < 5 ppm) lot L250128 | Action corrective |
| NC-2025-002 | 15/01/2025 | Solvant A-401 | Teneur eau = 0.15% (spec < 0.1%) lot L250115 | Verification efficacite |
| NC-2025-001 | 06/01/2025 | NaOH 50% | Concentration = 48.8% (spec > 49%) lot L250106 | Cloture |

## 5. Echantillonnage

### 5.1 Points de prelevement

| Point | Localisation | Produit | Frequence | Responsable |
|-------|-------------|---------|-----------|-------------|
| PREL-RX1 | Vanne echantillonnage R-101 | Melange reactionnel | Toutes les 2h en production | Operateur |
| PREL-PF1 | Sortie pompe P-102 | Produit fini RX1 | Chaque lot avant stockage | Operateur |
| PREL-T101 | Vanne pied bac T-101 | HCl 33% | A chaque reception | Logistique |
| PREL-DIST | Sortie colonne C-301 | Distillat | Toutes les 4h en production | Operateur |
| PREL-EAU | Rejet station traitement | Eau usee | Quotidien | HSE |

### 5.2 Consignes de prelevement

- Porter les EPI adaptes au produit (voir FDS)
- Utiliser les flacons pre-etiquetes (armoire sas labo)
- Remplir le bon de prelevement (date, heure, operateur, OF)
- Acheminer au labo dans les 15 minutes
- Temperature de conservation : ambiante sauf indication contraire

---

*Procedures qualite completes : `\\SRV-FILES01\QualityDocs\`*
*Certificats d'analyse : `\\SRV-FILES01\QualityDocs\Certificats_Conformite\`*
