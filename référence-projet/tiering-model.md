Bien sûr 👌 voici une version **courte et propre** :

---

## Modèle de Tiering (Tier 0 / Tier 1 / Tier 2)

Afin de sécuriser l’infrastructure, un **modèle de tiering** est mis en place pour **séparer les niveaux de privilèges** et limiter les risques de compromission et de mouvements latéraux.

### **Tier 0 – Critique (Identity / Control Plane)**

Le **Tier 0** regroupe les composants les plus sensibles, qui permettent de **contrôler l’ensemble du SI**.
Exemples : **Domain Controllers, Active Directory, DNS, comptes Domain Admins**.
➡️ Accès très restreint : uniquement comptes admin dédiés, administration depuis postes sécurisés/bastion.

### **Tier 1 – Serveurs critiques (Production)**

Le **Tier 1** correspond aux **serveurs métiers et services essentiels** (applications, bases de données, serveurs de fichiers critiques, etc.).
➡️ Les admins Tier 1 gèrent uniquement ces serveurs, sans accès aux composants Tier 0.

### **Tier 2 – Postes et utilisateurs (User Plane)**

Le **Tier 2** regroupe les **postes de travail et comptes utilisateurs**, qui sont les plus exposés aux attaques (phishing, malware).
➡️ Aucun accès d’administration serveur ou domaine, uniquement l’usage standard.

📌 **Principe clé :** un tier inférieur ne doit jamais administrer un tier supérieur (**Tier 2 → Tier 1/0 interdit**, **Tier 1 → Tier 0 interdit**).
