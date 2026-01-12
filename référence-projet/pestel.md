# Analyse PESTEL

## 1. Objectif de l’analyse

Cette analyse PESTEL a pour objectif de situer le projet dans son environnement global
et d’identifier les contraintes externes qui influencent les choix techniques,
organisationnels et méthodologiques.
Elle permet de justifier les orientations retenues pour la conception du socle de sécurité,
en particulier dans un contexte de sites industriels nouvellement acquis et isolés.

## 2. Analyse par facteur

### 2.1 Politique

Les sites industriels concernés sont rachetés par un groupe de grande taille(à revoir probblement si ils rachètent une serie d'usine),
ce qui implique des enjeux de gouvernance, de standardisation et de maîtrise des risques.
Ces sites restent toutefois isolés du reste du système d’information du groupe,
notamment pour des raisons de sécurité et d’organisation.

Dans ce contexte, les enjeux portent principalement sur la capacité du groupe
à déployer rapidement un niveau de sécurité homogène,
sans dépendre fortement des spécificités locales.

**Impacts sur le projet**
- Conception d’un socle de sécurité standardisable et réplicable
- Possibilité de déploiement autonome sur des sites isolés
- Limitation des dépendances à des infrastructures centrales du groupe


### 2.2 Économique

Le projet s’inscrit dans une logique de solution minimale,
destinée à fournir un premier niveau de sécurité sur des sites nouvellement acquis.
Les investissements doivent donc rester maîtrisés,
notamment dans un contexte de multiplication des sites industriels.

L’enjeu économique n’est pas la performance maximale,
mais la capacité à sécuriser rapidement et à coût raisonnable
des environnements hétérogènes.

**Impacts sur le projet**
- Orientation vers un socle fonctionnel minimal mais cohérent
- Priorisation des mécanismes essentiels de sécurité
- Choix de solutions permettant une duplication à faible coût


### 2.3 Sociétal

Les équipes présentes sur les sites industriels sont décrites comme neutres vis-à-vis de la cybersécurité,
sans expertise particulière dans ce domaine.
Leur priorité reste avant tout la continuité de la production
et la stabilité des systèmes.

Dans ce contexte, l’acceptation de la solution repose fortement
sur sa simplicité d’usage et sur la qualité de la documentation fournie.

**Impacts sur le projet**
- Importance accordée à la documentation et aux guides d’exploitation
- Limitation des actions manuelles complexes pour les équipes locales
- Mise en place de mécanismes compréhensibles et traçables


### 2.4 Technologique

Les sites industriels peuvent reposer sur des environnements très variés,
allant de systèmes relativement récents à des infrastructures legacy.
Les contraintes liées aux logiciels industriels,
souvent dépendants d’anciens systèmes d’exploitation,
limitent fortement les possibilités de modernisation.

Le projet part donc du principe que l’environnement à sécuriser
est potentiellement ancien et contraint.

**Impacts sur le projet**
- Choix d’une approche compatible avec des environnements legacy
- Refus des solutions nécessitant des mises à jour lourdes ou intrusives
- Conception d’un socle adaptable à des niveaux de maturité différents


### 2.5 Environnemental / Opérationnel

Dans un contexte industriel, un incident de sécurité peut avoir
des conséquences directes sur la production,
avec des impacts économiques et opérationnels importants.
Toute action de sécurité susceptible de perturber les systèmes industriels
doit donc être évitée.

L’enjeu principal est d’améliorer la visibilité et la détection,
sans introduire de risques supplémentaires pour l’exploitation.

**Impacts sur le projet**
- Priorité donnée à la supervision et à la détection
- Absence de mécanismes de blocage automatique sur les systèmes industriels
- Approche progressive de la sécurisation, sans rupture opérationnelle


### 2.6 Légal

Les sites industriels du secteur chimique sont soumis
à des exigences réglementaires spécifiques,
notamment en tant qu’infrastructures critiques ou assimilées.
À cela s’ajoutent des cadres généraux applicables à tous les systèmes,
tels que la protection des données personnelles.

L’enjeu n’est pas de couvrir l’intégralité des exigences réglementaires,
mais de démontrer leur prise en compte dans la conception du socle de sécurité.

**Impacts sur le projet**
- Intégration des principes de conformité dès la conception
- Mise en place de mécanismes de traçabilité et de journalisation
- Alignement avec les règles applicables aux OIV
  et aux normes du secteur industriel, ainsi qu’avec le RGPD

## 3. Synthèse PESTEL

L’analyse PESTEL met en évidence un contexte industriel contraint,
marqué par l’isolement des sites, la présence d’environnements legacy
et des exigences fortes en matière de continuité de production et de conformité.
Ces éléments justifient une approche pragmatique,
centrée sur un socle de sécurité minimal, non intrusif et standardisable,
adapté à des sites industriels nouvellement acquis.
