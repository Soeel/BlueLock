# Procedures Operatoires

> Responsable : Sophie Garcia (Ingenieur Procedes)
> Derniere mise a jour : 28/01/2025

---

## 1. Index des procedures

| Ref | Procedure | Atelier | Revision |
|-----|-----------|---------|----------|
| PO-RX1-001 | Demarrage ligne Reaction 1 | Reaction 1 | Rev.4 |
| PO-RX1-002 | Arret normal ligne Reaction 1 | Reaction 1 | Rev.3 |
| PO-RX1-003 | Arret d'urgence ligne Reaction 1 | Reaction 1 | Rev.5 |
| PO-RX2-001 | Demarrage ligne Reaction 2 | Reaction 2 | Rev.2 |
| PO-RX2-002 | Chargement reacteur R-201 | Reaction 2 | Rev.3 |
| PO-DI-001 | Demarrage colonne distillation C-301 | Distillation | Rev.2 |
| PO-DI-002 | Changement de production (solvant) | Distillation | Rev.1 |
| PO-ST-001 | Reception et depotage HCl | Stockage | Rev.6 |
| PO-ST-002 | Expedition produits finis | Logistique | Rev.2 |

> Les documents complets sont sur `\\SRV-FILES01\ProductionDocs\Consignes_Operatoires\`

---

## 2. PO-RX1-001 - Demarrage ligne Reaction 1

### 2.1 Prerequis

- [ ] Autorisation de demarrage signee par le chef de quart
- [ ] Consignations levees (voir registre consignations maintenance)
- [ ] Verification ronde pre-demarrage effectuee
- [ ] Utilitaires disponibles : vapeur (4 bar), eau glacee, azote, air instrument

### 2.2 Etapes

| Etape | Action | Verification SCADA | Critere |
|-------|--------|--------------------|---------|
| 1 | Ouvrir vanne alimentation eau glacee XV-102 | Tag `XV102.STS` = OPEN | Visuel terrain |
| 2 | Demarrer agitateur reacteur R-101 | Tag `AG101.RUN` = 1 | Bruit normal, pas de vibration |
| 3 | Mettre en service regulation temperature TIC-101 | Tag `TIC101.MODE` = AUTO | Consigne = 45°C |
| 4 | Ouvrir alimentation matiere premiere FV-101 | Tag `FV101.PV` > 0 | Debit consigne = 250 L/h |
| 5 | Attendre stabilisation (20 min) | Tag `TI101.PV` = 45 +/- 2°C | Stable pendant 5 min |
| 6 | Ouvrir vanne produit fini XV-105 | Tag `XV105.STS` = OPEN | Controle visuel |
| 7 | Demarrer pompe de transfert P-102 | Tag `P102.RUN` = 1 | Pression refoulement > 3 bar |
| 8 | Passer en mode production dans le MES | OF statut = "EnCours" | Via application MES |

### 2.3 Parametres de marche normaux

| Tag SCADA | Description | Min | Consigne | Max | Unite |
|-----------|-------------|-----|----------|-----|-------|
| TI-101 | Temperature reacteur R-101 | 40 | 45 | 55 | °C |
| PI-101 | Pression reacteur R-101 | 0.5 | 1.2 | 2.0 | bar |
| FI-101 | Debit alimentation MP | 200 | 250 | 300 | L/h |
| LI-101 | Niveau reacteur R-101 | 30 | 60 | 85 | % |
| pH-101 | pH reacteur R-101 | 6.5 | 7.2 | 8.0 | - |

### 2.4 Actions en cas d'anomalie

| Anomalie | Cause probable | Action immediate |
|----------|---------------|------------------|
| TI-101 > 55°C | Emballement, defaut refroidissement | Couper alimentation MP, ouvrir eau glacee 100% |
| PI-101 > 2.0 bar | Bouchage event, reaction parasite | Arret alimentation, prevenir chef de quart |
| LI-101 > 85% | Defaut soutirage, pompe HS | Couper alimentation, verifier P-102 |

---

## 3. PO-ST-001 - Reception et depotage HCl

### 3.1 Prerequis securite

- [ ] Permis de depotage signe (HSE + chef de quart)
- [ ] EPI obligatoires : combinaison chimique, masque ARI a portee, gants nitrile, lunettes
- [ ] Douche de securite verifiee (ZS-N01)
- [ ] Manche a air visible (vent favorable)
- [ ] Retention vide et propre

### 3.2 Etapes

| Etape | Action | Responsable |
|-------|--------|-------------|
| 1 | Verifier documents camion (BL, certificat analyse, ADR) | Logistique |
| 2 | Positionner camion sur aire de depotage, caler, couper moteur | Chauffeur |
| 3 | Raccorder flexible et mise a la terre | Operateur + Chauffeur |
| 4 | Ouvrir lentement vanne de pied de bac T-101 | Operateur |
| 5 | Demarrer transfert, surveiller niveau LI-T101 sur SCADA | Operateur |
| 6 | Arreter a LI-T101 = 90% maximum | Operateur |
| 7 | Vidanger flexible, deconnecter, refermer | Operateur |
| 8 | Signer registre depotage, archiver BL | Logistique |

> **ATTENTION** : En cas de fuite, appliquer immediatement la procedure S-01 du POI (voir [POI](/poi-plan-urgence)).

---

*Documents complets et fiches de poste disponibles sur `\\SRV-FILES01\ProductionDocs\Consignes_Operatoires\`*
