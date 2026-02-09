# Documentation SCADA / Supervision

> Responsable : Equipe Supervision SCADA
> Serveur : LNX-SCADA01 (Rocky Linux 8 - ScadaBR)
> Acces : [http://LNX-SCADA01:8080/ScadaBR](http://LNX-SCADA01:8080/ScadaBR)

---

## 1. Architecture de supervision

```
     Niveau 0-1 (Terrain)              Niveau 2 (Supervision)
  ┌─────────────────────┐          ┌──────────────────────────┐
  │  Capteurs/Actionneurs│          │     LNX-SCADA01          │
  │  (simules)           │ -------> │     ScadaBR              │
  │  T, P, F, L, pH     │          │     Port 8080            │
  └─────────────────────┘          └────────────┬─────────────┘
                                                │
                                   ┌────────────v─────────────┐
                                   │     LNX-HIST01           │
                                   │     Historian            │
                                   │     (historisation)       │
                                   └──────────────────────────┘
```

## 2. Liste des synoptiques

| Synoptique | Zone | Tags principaux |
|------------|------|-----------------|
| VUE-GENERAL | Vue d'ensemble site | Tous les ateliers |
| VUE-RX1 | Ligne Reaction 1 | TI-101, PI-101, FI-101, LI-101, pH-101 |
| VUE-RX2 | Ligne Reaction 2 | TI-201, PI-201, FI-201, LI-201 |
| VUE-DIST | Colonne Distillation | TI-301, PI-301, FI-301, LI-301 |
| VUE-STOCK | Zone Stockage | LI-T101, LI-T201, TI-T101 |
| VUE-UTIL | Utilitaires | PI-VAP, TI-EG, PI-N2, PI-AIR |
| VUE-ALARM | Tableau d'alarmes | Toutes les alarmes actives |

## 3. Liste des tags process

### 3.1 Ligne Reaction 1

| Tag | Description | Type | Unite | Plage | Alarme H | Alarme HH |
|-----|-------------|------|-------|-------|----------|-----------|
| TI-101 | Temperature reacteur R-101 | AI | °C | 0-100 | 55 | 65 |
| PI-101 | Pression reacteur R-101 | AI | bar | 0-5 | 2.0 | 2.5 |
| FI-101 | Debit alimentation MP | AI | L/h | 0-500 | 300 | 350 |
| LI-101 | Niveau reacteur R-101 | AI | % | 0-100 | 85 | 95 |
| pH-101 | pH reacteur R-101 | AI | - | 0-14 | 8.5 | 9.5 |
| XV-101 | Vanne alimentation bac HCl | DO | - | 0/1 | - | - |
| XV-102 | Vanne eau glacee R-101 | DO | - | 0/1 | - | - |
| XV-105 | Vanne produit fini R-101 | DO | - | 0/1 | - | - |
| AG-101 | Agitateur reacteur R-101 | DO | - | 0/1 | - | - |
| P-102 | Pompe transfert produit fini | DO | - | 0/1 | - | - |
| TIC-101 | Regulateur temperature R-101 | CTRL | °C | 0-100 | - | - |

### 3.2 Ligne Reaction 2

| Tag | Description | Type | Unite | Plage | Alarme H | Alarme HH |
|-----|-------------|------|-------|-------|----------|-----------|
| TI-201 | Temperature reacteur R-201 | AI | °C | 0-150 | 95 | 110 |
| PI-201 | Pression reacteur R-201 | AI | bar | 0-6 | 3.0 | 4.0 |
| FI-201 | Debit alimentation NaOH | AI | L/h | 0-400 | 250 | 300 |
| LI-201 | Niveau reacteur R-201 | AI | % | 0-100 | 85 | 95 |

### 3.3 Colonne Distillation

| Tag | Description | Type | Unite | Plage | Alarme H | Alarme HH |
|-----|-------------|------|-------|-------|----------|-----------|
| TI-301 | Temperature tete colonne C-301 | AI | °C | 0-200 | 120 | 140 |
| TI-302 | Temperature pied colonne C-301 | AI | °C | 0-250 | 180 | 200 |
| PI-301 | Pression colonne C-301 | AI | mbar | 0-2000 | 800 | 1000 |
| FI-301 | Debit reflux | AI | L/h | 0-300 | - | - |
| LI-301 | Niveau ballon reflux | AI | % | 0-100 | 80 | 90 |

### 3.4 Stockage

| Tag | Description | Type | Unite | Plage | Alarme H | Alarme HH |
|-----|-------------|------|-------|-------|----------|-----------|
| LI-T101 | Niveau bac HCl T-101 | AI | % | 0-100 | 90 | 95 |
| TI-T101 | Temperature bac HCl T-101 | AI | °C | 0-50 | 35 | 40 |
| LI-T201 | Niveau bac NaOH T-201 | AI | % | 0-100 | 90 | 95 |

## 4. Gestion des alarmes

### 4.1 Priorites

| Priorite | Couleur | Acquittement | Delai reaction | Exemple |
|----------|---------|-------------|----------------|---------|
| **Critique (HH)** | Rouge clignotant | Obligatoire | < 1 min | TI-201 > 110°C (emballement) |
| **Haute (H)** | Rouge fixe | Obligatoire | < 5 min | LI-101 > 85% (debordement) |
| **Moyenne** | Orange | Optionnel | < 15 min | Defaut pompe secondaire |
| **Basse** | Jaune | Optionnel | < 1h | Ecart consigne faible |

### 4.2 Procedure d'acquittement

1. Identifier l'alarme sur le synoptique ou le tableau VUE-ALARM
2. Verifier le terrain (ronde ou camera si disponible)
3. Appliquer la procedure operatoire correspondante
4. Acquitter l'alarme dans ScadaBR
5. Consigner dans le cahier de quart

## 5. Comptes d'acces SCADA

| Profil | Login | Droits |
|--------|-------|--------|
| Operateur | Compte AD personnel | Visualisation + acquittement alarmes |
| Superviseur | Compte AD personnel | Visualisation + modification consignes |
| Administrateur SCADA | svc_scada | Configuration systeme (reserve IT/SCADA) |

> **Rappel** : L'acces SCADA est reserve aux operateurs habilites. Toute modification de consigne doit etre validee par le chef de quart.

---

*Documentation technique complete : `\\SRV-FILES01\EngineeringDocs\Schemas_PID\`*
