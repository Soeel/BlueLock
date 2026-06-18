#!/usr/bin/env python3
"""
sync_bastion_from_tiering.py
============================================================================
Synchronise Apache Guacamole avec le modele de Tiering AD.

Source unique de verite : le CSV serveurs du tiering
(bluelockin/tiering/Configs/servers.csv). Le script, via l'API REST Guacamole :

  1. cree un GROUPE DE CONNEXIONS par tier   (Tier 0 / Tier 1 / Tier 2 / Legacy)
  2. cree une CONNEXION (RDP Windows / SSH Linux) par serveur, dans le groupe de son tier
  3. cree un USER GROUP nomme comme le groupe AD du tier (GG_TX_Admins)
  4. accorde a ce user group la permission READ sur le groupe de connexions du tier
     et sur ses connexions

=> Un admin authentifie en LDAP, membre de GG_T1_Admins, ne voit que les connexions
   "Tier 1". Aucun mot de passe cible n'est stocke : les identifiants saisis au bastion
   sont transmis a la cible via les jetons ${GUAC_USERNAME} / ${GUAC_PASSWORD} (SSO).

Idempotent : relancable sans creer de doublons (recherche par nom avant creation).

Conforme au sujet : Python uniquement, aucune dependance hors `requests`.

Usage :
    python sync_bastion_from_tiering.py \
        --url https://bastion.blue.local --user guacadmin \
        --servers ../../tiering/Configs/servers.csv \
        --dns-domain blue.local --netbios BLUE

Les valeurs peuvent aussi venir de variables d'environnement (voir .env.example) :
    GUAC_API_URL, GUAC_ADMIN_USER, GUAC_ADMIN_PASSWORD, TIERING_SERVERS_CSV
"""

import argparse
import csv
import getpass
import os
import sys
import urllib.parse

try:
    import requests
except ImportError:
    sys.exit("Le module 'requests' est requis : pip install requests")


# --- Heuristique de protocole : Linux -> SSH, sinon RDP -----------------------
SSH_HINTS = ("linux", "scada", "rocky", "debian", "ubuntu", "web", "siem",
             "ssh", "nginx", "apache", "bastion")


def guess_protocol(name, role, explicit):
    if explicit:
        return explicit.strip().lower()
    blob = f"{name} {role}".lower()
    return "ssh" if any(h in blob for h in SSH_HINTS) else "rdp"


def tier_group_name(tier):
    """T0/T1/T2 -> 'Tier 0/1/2' ; tout autre code (Legacy) inchange."""
    t = tier.upper()
    if t in ("T0", "T1", "T2"):
        return f"Tier {t[1]}"
    return tier


class GuacClient:
    def __init__(self, base_url, verify=True):
        self.base = base_url.rstrip("/") + "/guacamole/api"
        self.s = requests.Session()
        self.s.verify = verify
        self.token = None
        self.ds = None

    def login(self, user, password):
        r = self.s.post(f"{self.base}/tokens",
                        data={"username": user, "password": password})
        r.raise_for_status()
        body = r.json()
        self.token = body["authToken"]
        # Les objets (connexions/groupes/permissions) vivent dans la source "postgresql".
        self.ds = "postgresql"
        if "postgresql" not in body.get("availableDataSources", ["postgresql"]):
            self.ds = body.get("dataSource", "postgresql")
        return self

    def _url(self, path):
        sep = "&" if "?" in path else "?"
        return f"{self.base}/session/data/{self.ds}{path}{sep}token={urllib.parse.quote(self.token)}"

    def _get(self, path):
        r = self.s.get(self._url(path))
        r.raise_for_status()
        return r.json()

    def _post(self, path, payload):
        r = self.s.post(self._url(path), json=payload)
        r.raise_for_status()
        return r.json() if r.text else {}

    def _patch(self, path, payload):
        r = self.s.patch(self._url(path), json=payload)
        r.raise_for_status()

    # --- Groupes de connexions ---
    def ensure_connection_group(self, name, parent="ROOT"):
        groups = self._get("/connectionGroups")
        for gid, g in groups.items():
            if g.get("name") == name and g.get("parentIdentifier") == parent:
                return gid
        created = self._post("/connectionGroups", {
            "parentIdentifier": parent,
            "name": name,
            "type": "ORGANIZATIONAL",
            "attributes": {},
        })
        print(f"  [+] groupe de connexions cree : {name}")
        return created["identifier"]

    # --- Connexions ---
    def ensure_connection(self, name, parent_id, protocol, params):
        conns = self._get("/connections")
        for cid, c in conns.items():
            if c.get("name") == name and c.get("parentIdentifier") == parent_id:
                return cid
        created = self._post("/connections", {
            "parentIdentifier": parent_id,
            "name": name,
            "protocol": protocol,
            "parameters": params,
            "attributes": {},
        })
        print(f"  [+] connexion creee : {name} ({protocol})")
        return created["identifier"]

    # --- User groups (mappes sur les groupes AD) ---
    def ensure_user_group(self, name):
        groups = self._get("/userGroups")
        if name in groups:
            return name
        self._post("/userGroups", {"identifier": name, "attributes": {"disabled": ""}})
        print(f"  [+] user group cree (mappe AD) : {name}")
        return name

    def grant_read(self, user_group, connection_group_id, connection_ids):
        ops = [{"op": "add",
                "path": f"/connectionGroupPermissions/{connection_group_id}",
                "value": "READ"}]
        for cid in connection_ids:
            ops.append({"op": "add",
                        "path": f"/connectionPermissions/{cid}",
                        "value": "READ"})
        self._patch(f"/userGroups/{urllib.parse.quote(user_group)}/permissions", ops)


def rdp_params(hostname, netbios):
    # Pas de secret stocke : on transmet les identifiants de session (compte de tier).
    return {
        "hostname": hostname, "port": "3389",
        "username": "${GUAC_USERNAME}", "password": "${GUAC_PASSWORD}",
        "domain": netbios, "security": "any", "ignore-cert": "true",
        "resize-method": "display-update",
    }


def ssh_params(hostname):
    return {
        "hostname": hostname, "port": "22",
        "username": "${GUAC_USERNAME}", "password": "${GUAC_PASSWORD}",
    }


def main():
    ap = argparse.ArgumentParser(description="Synchronise Guacamole depuis le tiering (servers.csv).")
    ap.add_argument("--url", default=os.environ.get("GUAC_API_URL"))
    ap.add_argument("--user", default=os.environ.get("GUAC_ADMIN_USER", "guacadmin"))
    ap.add_argument("--password", default=os.environ.get("GUAC_ADMIN_PASSWORD"))
    ap.add_argument("--servers", default=os.environ.get("TIERING_SERVERS_CSV",
                    "../../tiering/Configs/servers.csv"))
    ap.add_argument("--dns-domain", default=os.environ.get("DNS_DOMAIN", ""),
                    help="Suffixe DNS ajoute au nom (ex: blue.local).")
    ap.add_argument("--netbios", default=os.environ.get("DOMAIN_NETBIOS", ""),
                    help="Domaine NetBIOS pour le RDP (ex: BLUE).")
    ap.add_argument("--insecure", action="store_true", help="Ne pas verifier le certificat TLS (lab).")
    ap.add_argument("--dry-run", action="store_true", help="Affiche sans rien creer.")
    args = ap.parse_args()

    if not args.url:
        ap.error("--url (ou GUAC_API_URL) requis.")

    if not os.path.isfile(args.servers):
        sys.exit(f"CSV serveurs introuvable : {args.servers}")

    with open(args.servers, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f, delimiter=";"))

    # Regroupe les serveurs par tier.
    tiers = {}
    for row in rows:
        name = (row.get("NomServeur") or "").strip()
        tier = (row.get("NiveauTiering") or "").strip().upper()
        if not name or not tier:
            continue
        tiers.setdefault(tier, []).append(row)

    if args.dry_run:
        print("[DryRun] Aucune modification. Plan de synchronisation :")
        for tier, servers in sorted(tiers.items()):
            grp = (servers[0].get("GroupeAdminAutorise") or f"GG_{tier}_Admins").strip()
            print(f"  {tier_group_name(tier)}  <-  user group {grp}")
            for s in servers:
                nm = s["NomServeur"].strip()
                proto = guess_protocol(nm, s.get("RoleServeur", ""), s.get("Protocole"))
                print(f"      - {nm} ({proto})")
        return

    password = args.password or getpass.getpass(f"Mot de passe Guacamole pour {args.user} : ")

    verify = not args.insecure
    if args.insecure:
        requests.packages.urllib3.disable_warnings()  # type: ignore

    guac = GuacClient(args.url, verify=verify).login(args.user, password)
    print(f"Connecte a Guacamole ({args.url}), data source = {guac.ds}")

    for tier, servers in sorted(tiers.items()):
        group_label = tier_group_name(tier)
        ad_group = (servers[0].get("GroupeAdminAutorise") or f"GG_{tier}_Admins").strip()
        print(f"\n== {group_label} (user group AD : {ad_group}) ==")

        cg_id = guac.ensure_connection_group(group_label)
        guac.ensure_user_group(ad_group)

        conn_ids = []
        for s in servers:
            name = s["NomServeur"].strip()
            role = s.get("RoleServeur", "")
            proto = guess_protocol(name, role, s.get("Protocole"))
            hostname = f"{name}.{args.dns_domain}" if args.dns_domain else name
            params = rdp_params(hostname, args.netbios) if proto == "rdp" else ssh_params(hostname)
            conn_ids.append(guac.ensure_connection(name, cg_id, proto, params))

        guac.grant_read(ad_group, cg_id, conn_ids)
        print(f"  [=] {ad_group} -> READ sur '{group_label}' ({len(conn_ids)} connexion(s))")

    print("\nSynchronisation terminee.")


if __name__ == "__main__":
    main()
