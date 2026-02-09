#Requires -Modules ActiveDirectory, GroupPolicy
<#
.SYNOPSIS
    Deploiement AD complet pour une usine chimique - Partie Production uniquement.

.DESCRIPTION
    Script de peuplement Active Directory realiste pour un site industriel chimique
    base sur le modele ISA-95 (Purdue). Structure classique sans securisation avancee,
    representatif d un site existant avant toute demarche de durcissement.

    Cree : OUs, Utilisateurs, Groupes, Comptes machines, Comptes de service, GPOs basiques.

    Domaine cible : blue.local (NetBIOS: BLUE)
    A executer sur le DC (DC01) apres promotion du domaine.

.NOTES
    Projet  : BlueLock - Socle de securite industriel
    Contexte: Environnement de test ISA-95 / Usine chimique
    Auteur  : BlueLock Team
    Version : 1.0
#>

# ==============================================================================
# CONFIGURATION GENERALE
# ==============================================================================

$Domain       = "blue.local"
$DomainDN     = "DC=blue,DC=local"
$NetBIOS      = "BLUE"
$DefaultPass  = ConvertTo-SecureString "Usine2025!" -AsPlainText -Force

# Mot de passe commun pour les comptes de service (pratique courante en indus avant securisation)
$SvcPass      = ConvertTo-SecureString "Svc_Blue2025!" -AsPlainText -Force

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DEPLOIEMENT AD - USINE CHIMIQUE BLUE.LOCAL"               -ForegroundColor Cyan
Write-Host "  Modele ISA-95 / Purdue - Partie Production"               -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# 1. CREATION DES UNITES D'ORGANISATION (OUs)
# ==============================================================================

Write-Host "[1/6] Creation des Unites d'Organisation..." -ForegroundColor Yellow

# --- Structure OU ---
# On organise par fonction metier (classique industriel),
# pas par niveau ISA-95 (ce serait un choix de securisation ulterieur).
$OUs = @(
    # --- Racine Usine ---
    @{ Name = "Usine";                  Path = $DomainDN }

    # --- Utilisateurs par service ---
    @{ Name = "Utilisateurs";           Path = "OU=Usine,$DomainDN" }
    @{ Name = "Direction_Production";   Path = "OU=Utilisateurs,OU=Usine,$DomainDN" }
    @{ Name = "Procedes";               Path = "OU=Utilisateurs,OU=Usine,$DomainDN" }
    @{ Name = "Laboratoire";            Path = "OU=Utilisateurs,OU=Usine,$DomainDN" }
    @{ Name = "Maintenance";            Path = "OU=Utilisateurs,OU=Usine,$DomainDN" }
    @{ Name = "HSE";                    Path = "OU=Utilisateurs,OU=Usine,$DomainDN" }
    @{ Name = "Logistique";             Path = "OU=Utilisateurs,OU=Usine,$DomainDN" }
    @{ Name = "Supervision_SCADA";      Path = "OU=Utilisateurs,OU=Usine,$DomainDN" }

    # --- Ordinateurs ---
    @{ Name = "Ordinateurs";            Path = "OU=Usine,$DomainDN" }
    @{ Name = "Postes_Bureau";          Path = "OU=Ordinateurs,OU=Usine,$DomainDN" }
    @{ Name = "Postes_SCADA_HMI";       Path = "OU=Ordinateurs,OU=Usine,$DomainDN" }
    @{ Name = "Postes_Laboratoire";     Path = "OU=Ordinateurs,OU=Usine,$DomainDN" }
    @{ Name = "Postes_Maintenance";     Path = "OU=Ordinateurs,OU=Usine,$DomainDN" }
    @{ Name = "Serveurs";               Path = "OU=Ordinateurs,OU=Usine,$DomainDN" }

    # --- Groupes ---
    @{ Name = "Groupes";                Path = "OU=Usine,$DomainDN" }

    # --- Comptes de service ---
    @{ Name = "Comptes_Service";        Path = "OU=Usine,$DomainDN" }
)

foreach ($OU in $OUs) {
    $OUPath = "OU=$($OU.Name),$($OU.Path)"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$OUPath'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $OU.Name -Path $OU.Path -ProtectedFromAccidentalDeletion $false
        Write-Host "  [+] OU creee : $($OU.Name)" -ForegroundColor Green
    } else {
        Write-Host "  [=] OU existante : $($OU.Name)" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ==============================================================================
# 2. CREATION DES GROUPES DE SECURITE
# ==============================================================================

Write-Host "[2/6] Creation des Groupes..." -ForegroundColor Yellow

$GroupsPath = "OU=Groupes,OU=Usine,$DomainDN"

# Groupes organises par fonction metier - structure plate typique industriel
$Groups = @(
    # --- Groupes par service ---
    @{ Name = "GG_Direction_Production";  Scope = "Global";      Category = "Security";     Desc = "Personnel direction de production" }
    @{ Name = "GG_Operateurs_Procedes";   Scope = "Global";      Category = "Security";     Desc = "Operateurs procedes (reaction, distillation, stockage)" }
    @{ Name = "GG_Chefs_Quart";           Scope = "Global";      Category = "Security";     Desc = "Chefs de quart (superviseurs postes)" }
    @{ Name = "GG_Ingenieurs_Procedes";   Scope = "Global";      Category = "Security";     Desc = "Ingenieurs procedes" }
    @{ Name = "GG_Laboratoire";           Scope = "Global";      Category = "Security";     Desc = "Personnel laboratoire et qualite" }
    @{ Name = "GG_Maintenance";           Scope = "Global";      Category = "Security";     Desc = "Equipe maintenance (meca, instru, elec)" }
    @{ Name = "GG_HSE";                   Scope = "Global";      Category = "Security";     Desc = "Personnel Hygiene Securite Environnement" }
    @{ Name = "GG_Logistique";            Scope = "Global";      Category = "Security";     Desc = "Logistique, magasin, expedition" }
    @{ Name = "GG_SCADA_Supervision";     Scope = "Global";      Category = "Security";     Desc = "Equipe supervision / automatisme / SCADA" }

    # --- Groupes par equipe postee (3x8) ---
    @{ Name = "GG_Equipe_A";             Scope = "Global";      Category = "Security";     Desc = "Equipe postee A (matin)" }
    @{ Name = "GG_Equipe_B";             Scope = "Global";      Category = "Security";     Desc = "Equipe postee B (apres-midi)" }
    @{ Name = "GG_Equipe_C";             Scope = "Global";      Category = "Security";     Desc = "Equipe postee C (nuit)" }

    # --- Groupes d'acces aux partages (domaine local) ---
    @{ Name = "DL_Partage_ProductionDocs_RW";  Scope = "DomainLocal"; Category = "Security"; Desc = "Acces RW au partage ProductionDocs" }
    @{ Name = "DL_Partage_ProductionDocs_RO";  Scope = "DomainLocal"; Category = "Security"; Desc = "Acces RO au partage ProductionDocs" }
    @{ Name = "DL_Partage_QualityDocs_RW";     Scope = "DomainLocal"; Category = "Security"; Desc = "Acces RW au partage QualityDocs" }
    @{ Name = "DL_Partage_QualityDocs_RO";     Scope = "DomainLocal"; Category = "Security"; Desc = "Acces RO au partage QualityDocs" }
    @{ Name = "DL_Partage_EngineeringDocs_RW"; Scope = "DomainLocal"; Category = "Security"; Desc = "Acces RW au partage EngineeringDocs" }
    @{ Name = "DL_Partage_EngineeringDocs_RO"; Scope = "DomainLocal"; Category = "Security"; Desc = "Acces RO au partage EngineeringDocs" }
    @{ Name = "DL_Partage_Maintenance_RW";     Scope = "DomainLocal"; Category = "Security"; Desc = "Acces RW au partage Maintenance" }
    @{ Name = "DL_Partage_Maintenance_RO";     Scope = "DomainLocal"; Category = "Security"; Desc = "Acces RO au partage Maintenance" }
    @{ Name = "DL_Partage_HSE_RW";             Scope = "DomainLocal"; Category = "Security"; Desc = "Acces RW au partage HSE" }
    @{ Name = "DL_Partage_HSE_RO";             Scope = "DomainLocal"; Category = "Security"; Desc = "Acces RO au partage HSE" }
    @{ Name = "DL_Partage_Confidentiel_RW";    Scope = "DomainLocal"; Category = "Security"; Desc = "Acces RW au partage Confidentiel (brevets)" }

    # --- Groupes applicatifs ---
    @{ Name = "GG_Acces_SCADA";          Scope = "Global";      Category = "Security";     Desc = "Acces a l interface SCADA (ScadaBR)" }
    @{ Name = "GG_Acces_MES";            Scope = "Global";      Category = "Security";     Desc = "Acces a l application MES" }
    @{ Name = "GG_Acces_GMAO";           Scope = "Global";      Category = "Security";     Desc = "Acces a la GMAO" }
    @{ Name = "GG_Acces_Historian";       Scope = "Global";      Category = "Security";     Desc = "Acces aux donnees Historian (PI)" }
    @{ Name = "GG_Acces_Portail_Web";    Scope = "Global";      Category = "Security";     Desc = "Acces au portail web interne" }

    # --- Groupe admin local poste (mauvaise pratique classique) ---
    @{ Name = "GG_Admin_Postes_Prod";    Scope = "Global";      Category = "Security";     Desc = "Admins locaux des postes de production" }
)

foreach ($Group in $Groups) {
    if (-not (Get-ADGroup -Filter "Name -eq '$($Group.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $Group.Name `
                    -GroupScope $Group.Scope `
                    -GroupCategory $Group.Category `
                    -Path $GroupsPath `
                    -Description $Group.Desc
        Write-Host "  [+] Groupe cree : $($Group.Name)" -ForegroundColor Green
    } else {
        Write-Host "  [=] Groupe existant : $($Group.Name)" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ==============================================================================
# 3. CREATION DES UTILISATEURS
# ==============================================================================

Write-Host "[3/6] Creation des Utilisateurs..." -ForegroundColor Yellow

# --- Fonction utilitaire pour generer le SamAccountName ---
function Get-SamAccount {
    param([string]$Prenom, [string]$Nom)
    # Format classique industriel : premiere lettre prenom + nom (tout en minuscule)
    $p = ($Prenom.Substring(0,1)).ToLower()
    # Retirer les accents pour le SAM
    $n = $Nom.ToLower()
    $n = $n -replace '[eéèêë]','e' -replace '[aàâä]','a' -replace '[iîï]','i' -replace '[oôö]','o' -replace '[uùûü]','u' -replace '[cç]','c'
    return "$p.$n"
}

# Liste complete des utilisateurs de l'usine (partie production uniquement)
# Format : Prenom, Nom, Titre, OU, Groupes[]
$Users = @(
    # =============================================
    # DIRECTION PRODUCTION
    # =============================================
    @{
        Prenom = "Jean-Pierre"; Nom = "Moreau"
        Titre  = "Directeur de Production"
        Service = "Direction Production"
        OU     = "OU=Direction_Production,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Direction_Production","GG_Acces_MES","GG_Acces_Historian","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RW","DL_Partage_Confidentiel_RW","GG_Admin_Postes_Prod")
    }
    @{
        Prenom = "Nathalie"; Nom = "Duval"
        Titre  = "Responsable Planning Production"
        Service = "Direction Production"
        OU     = "OU=Direction_Production,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Direction_Production","GG_Acces_MES","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RW")
    }
    @{
        Prenom = "Sandrine"; Nom = "Collet"
        Titre  = "Assistante de Production"
        Service = "Direction Production"
        OU     = "OU=Direction_Production,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Direction_Production","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RW","DL_Partage_HSE_RO")
    }

    # =============================================
    # PROCEDES - CHEFS DE QUART (3x8)
    # =============================================
    @{
        Prenom = "Marc"; Nom = "Lefebvre"
        Titre  = "Chef de Quart - Equipe A"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Chefs_Quart","GG_Operateurs_Procedes","GG_Equipe_A",
                   "GG_Acces_SCADA","GG_Acces_MES","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RW")
    }
    @{
        Prenom = "Sebastien"; Nom = "Garcia"
        Titre  = "Chef de Quart - Equipe B"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Chefs_Quart","GG_Operateurs_Procedes","GG_Equipe_B",
                   "GG_Acces_SCADA","GG_Acces_MES","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RW")
    }
    @{
        Prenom = "Karim"; Nom = "Benali"
        Titre  = "Chef de Quart - Equipe C"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Chefs_Quart","GG_Operateurs_Procedes","GG_Equipe_C",
                   "GG_Acces_SCADA","GG_Acces_MES","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RW")
    }

    # =============================================
    # PROCEDES - OPERATEURS TABLEAU (salle de controle)
    # =============================================
    @{
        Prenom = "Thomas"; Nom = "Roux"
        Titre  = "Operateur Tableau - Equipe A"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_A","GG_Acces_SCADA","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Julien"; Nom = "Martin"
        Titre  = "Operateur Tableau - Equipe A"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_A","GG_Acces_SCADA","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Fabrice"; Nom = "Petit"
        Titre  = "Operateur Tableau - Equipe B"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_B","GG_Acces_SCADA","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Yannick"; Nom = "Morel"
        Titre  = "Operateur Tableau - Equipe B"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_B","GG_Acces_SCADA","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Rachid"; Nom = "Amrani"
        Titre  = "Operateur Tableau - Equipe C"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_C","GG_Acces_SCADA","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "David"; Nom = "Lambert"
        Titre  = "Operateur Tableau - Equipe C"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_C","GG_Acces_SCADA","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }

    # =============================================
    # PROCEDES - OPERATEURS EXTERIEURS (terrain)
    # =============================================
    @{
        Prenom = "Philippe"; Nom = "Girard"
        Titre  = "Operateur Exterieur - Equipe A"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_A","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Christophe"; Nom = "Bonnet"
        Titre  = "Operateur Exterieur - Equipe A"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_A","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Stephane"; Nom = "Mercier"
        Titre  = "Operateur Exterieur - Equipe A"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_A","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Bruno"; Nom = "Fournier"
        Titre  = "Operateur Exterieur - Equipe B"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_B","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Nicolas"; Nom = "Andre"
        Titre  = "Operateur Exterieur - Equipe B"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_B","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Alexandre"; Nom = "Leroy"
        Titre  = "Operateur Exterieur - Equipe B"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_B","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Moussa"; Nom = "Diallo"
        Titre  = "Operateur Exterieur - Equipe C"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_C","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Franck"; Nom = "Simon"
        Titre  = "Operateur Exterieur - Equipe C"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_C","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Olivier"; Nom = "Michel"
        Titre  = "Operateur Exterieur - Equipe C"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Operateurs_Procedes","GG_Equipe_C","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }

    # =============================================
    # PROCEDES - INGENIEURS
    # =============================================
    @{
        Prenom = "Claire"; Nom = "Bertrand"
        Titre  = "Ingenieur Procedes"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Ingenieurs_Procedes","GG_Acces_SCADA","GG_Acces_MES","GG_Acces_Historian",
                   "GG_Acces_Portail_Web","DL_Partage_ProductionDocs_RW","DL_Partage_EngineeringDocs_RW",
                   "DL_Partage_QualityDocs_RO")
    }
    @{
        Prenom = "Antoine"; Nom = "Rousseau"
        Titre  = "Ingenieur Procedes"
        Service = "Procedes"
        OU     = "OU=Procedes,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Ingenieurs_Procedes","GG_Acces_SCADA","GG_Acces_MES","GG_Acces_Historian",
                   "GG_Acces_Portail_Web","DL_Partage_ProductionDocs_RW","DL_Partage_EngineeringDocs_RW",
                   "DL_Partage_QualityDocs_RO")
    }

    # =============================================
    # LABORATOIRE / QUALITE
    # =============================================
    @{
        Prenom = "Isabelle"; Nom = "Fontaine"
        Titre  = "Responsable Qualite et Laboratoire"
        Service = "Laboratoire"
        OU     = "OU=Laboratoire,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Laboratoire","GG_Acces_MES","GG_Acces_Historian","GG_Acces_Portail_Web",
                   "DL_Partage_QualityDocs_RW","DL_Partage_ProductionDocs_RO",
                   "DL_Partage_Confidentiel_RW")
    }
    @{
        Prenom = "Sophie"; Nom = "Caron"
        Titre  = "Analyste Laboratoire"
        Service = "Laboratoire"
        OU     = "OU=Laboratoire,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Laboratoire","GG_Acces_Portail_Web",
                   "DL_Partage_QualityDocs_RW","DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Emilie"; Nom = "Perrin"
        Titre  = "Analyste Laboratoire"
        Service = "Laboratoire"
        OU     = "OU=Laboratoire,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Laboratoire","GG_Acces_Portail_Web",
                   "DL_Partage_QualityDocs_RW","DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Lucas"; Nom = "Chevalier"
        Titre  = "Technicien Laboratoire"
        Service = "Laboratoire"
        OU     = "OU=Laboratoire,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Laboratoire","GG_Acces_Portail_Web",
                   "DL_Partage_QualityDocs_RW")
    }

    # =============================================
    # MAINTENANCE
    # =============================================
    @{
        Prenom = "Patrick"; Nom = "Dubois"
        Titre  = "Responsable Maintenance"
        Service = "Maintenance"
        OU     = "OU=Maintenance,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Maintenance","GG_Acces_GMAO","GG_Acces_Historian","GG_Acces_Portail_Web",
                   "DL_Partage_Maintenance_RW","DL_Partage_EngineeringDocs_RO",
                   "DL_Partage_ProductionDocs_RO","GG_Admin_Postes_Prod")
    }
    @{
        Prenom = "Thierry"; Nom = "Laurent"
        Titre  = "Technicien Maintenance Mecanique"
        Service = "Maintenance"
        OU     = "OU=Maintenance,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Maintenance","GG_Acces_GMAO","GG_Acces_Portail_Web",
                   "DL_Partage_Maintenance_RW")
    }
    @{
        Prenom = "Cedric"; Nom = "Henry"
        Titre  = "Technicien Maintenance Mecanique"
        Service = "Maintenance"
        OU     = "OU=Maintenance,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Maintenance","GG_Acces_GMAO","GG_Acces_Portail_Web",
                   "DL_Partage_Maintenance_RW")
    }
    @{
        Prenom = "Vincent"; Nom = "Masson"
        Titre  = "Technicien Instrumentation"
        Service = "Maintenance"
        OU     = "OU=Maintenance,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Maintenance","GG_Acces_GMAO","GG_Acces_SCADA","GG_Acces_Portail_Web",
                   "DL_Partage_Maintenance_RW","DL_Partage_EngineeringDocs_RO")
    }
    @{
        Prenom = "Laurent"; Nom = "Picard"
        Titre  = "Technicien Electricite"
        Service = "Maintenance"
        OU     = "OU=Maintenance,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Maintenance","GG_Acces_GMAO","GG_Acces_Portail_Web",
                   "DL_Partage_Maintenance_RW")
    }
    @{
        Prenom = "Audrey"; Nom = "Rolland"
        Titre  = "Planificateur Maintenance"
        Service = "Maintenance"
        OU     = "OU=Maintenance,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Maintenance","GG_Acces_GMAO","GG_Acces_Portail_Web",
                   "DL_Partage_Maintenance_RW","DL_Partage_ProductionDocs_RO")
    }

    # =============================================
    # HSE (Hygiene Securite Environnement)
    # =============================================
    @{
        Prenom = "Catherine"; Nom = "Legrand"
        Titre  = "Responsable HSE"
        Service = "HSE"
        OU     = "OU=HSE,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_HSE","GG_Acces_Historian","GG_Acces_Portail_Web",
                   "DL_Partage_HSE_RW","DL_Partage_ProductionDocs_RO",
                   "DL_Partage_QualityDocs_RO","DL_Partage_Confidentiel_RW")
    }
    @{
        Prenom = "Maxime"; Nom = "Blanchard"
        Titre  = "Animateur Securite"
        Service = "HSE"
        OU     = "OU=HSE,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_HSE","GG_Acces_Portail_Web",
                   "DL_Partage_HSE_RW","DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Marine"; Nom = "Vasseur"
        Titre  = "Technicien Environnement"
        Service = "HSE"
        OU     = "OU=HSE,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_HSE","GG_Acces_Historian","GG_Acces_Portail_Web",
                   "DL_Partage_HSE_RW")
    }

    # =============================================
    # LOGISTIQUE / EXPEDITION
    # =============================================
    @{
        Prenom = "Frederic"; Nom = "Renard"
        Titre  = "Responsable Logistique"
        Service = "Logistique"
        OU     = "OU=Logistique,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Logistique","GG_Acces_MES","GG_Acces_Portail_Web",
                   "DL_Partage_ProductionDocs_RO")
    }
    @{
        Prenom = "Alain"; Nom = "Brun"
        Titre  = "Magasinier"
        Service = "Logistique"
        OU     = "OU=Logistique,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Logistique","GG_Acces_Portail_Web")
    }
    @{
        Prenom = "Mohamed"; Nom = "Hassan"
        Titre  = "Cariste"
        Service = "Logistique"
        OU     = "OU=Logistique,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_Logistique","GG_Acces_Portail_Web")
    }

    # =============================================
    # SUPERVISION / SCADA / AUTOMATISME
    # =============================================
    @{
        Prenom = "Eric"; Nom = "Marchand"
        Titre  = "Ingenieur Automatisme"
        Service = "Supervision SCADA"
        OU     = "OU=Supervision_SCADA,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_SCADA_Supervision","GG_Acces_SCADA","GG_Acces_Historian","GG_Acces_MES",
                   "GG_Acces_Portail_Web","DL_Partage_EngineeringDocs_RW",
                   "DL_Partage_ProductionDocs_RO","GG_Admin_Postes_Prod")
    }
    @{
        Prenom = "Damien"; Nom = "Faure"
        Titre  = "Technicien SCADA"
        Service = "Supervision SCADA"
        OU     = "OU=Supervision_SCADA,OU=Utilisateurs,OU=Usine,$DomainDN"
        Groups = @("GG_SCADA_Supervision","GG_Acces_SCADA","GG_Acces_Historian",
                   "GG_Acces_Portail_Web","DL_Partage_EngineeringDocs_RW")
    }
    @{
        Prenom = "Jerome"; Nom = "Gauthier"
        Titre  = "Administrateur Systeme Industriel"
        Service = "Supervision SCADA"
        OU     = "OU=Supervision_SCADA,OU=Utilisateurs,OU=Usine,$DomainDN"
        # Admin systeme : acces large (typique d un site non securise)
        Groups = @("GG_SCADA_Supervision","GG_Acces_SCADA","GG_Acces_MES","GG_Acces_GMAO",
                   "GG_Acces_Historian","GG_Acces_Portail_Web","GG_Admin_Postes_Prod",
                   "DL_Partage_EngineeringDocs_RW","DL_Partage_ProductionDocs_RW",
                   "DL_Partage_Maintenance_RO")
    }
)

foreach ($User in $Users) {
    $Sam = Get-SamAccount -Prenom $User.Prenom -Nom $User.Nom
    $UPN = "$Sam@$Domain"
    $DisplayName = "$($User.Prenom) $($User.Nom)"

    if (-not (Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue)) {
        New-ADUser -SamAccountName $Sam `
                   -UserPrincipalName $UPN `
                   -Name $DisplayName `
                   -GivenName $User.Prenom `
                   -Surname $User.Nom `
                   -DisplayName $DisplayName `
                   -Title $User.Titre `
                   -Department $User.Service `
                   -Company "Blue Chemicals" `
                   -Office "Usine - Site Principal" `
                   -Path $User.OU `
                   -AccountPassword $DefaultPass `
                   -Enabled $true `
                   -PasswordNeverExpires $true `
                   -ChangePasswordAtLogon $false

        # Ajout aux groupes
        foreach ($GroupName in $User.Groups) {
            Add-ADGroupMember -Identity $GroupName -Members $Sam -ErrorAction SilentlyContinue
        }

        Write-Host "  [+] Utilisateur cree : $DisplayName ($Sam)" -ForegroundColor Green
    } else {
        Write-Host "  [=] Utilisateur existant : $DisplayName ($Sam)" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ==============================================================================
# 4. COMPTES DE SERVICE
# ==============================================================================

Write-Host "[4/6] Creation des Comptes de Service..." -ForegroundColor Yellow

$SvcPath = "OU=Comptes_Service,OU=Usine,$DomainDN"

# Comptes de service typiques d un SI industriel non securise
# (mots de passe qui n expirent jamais, droits larges - realiste avant securisation)
$ServiceAccounts = @(
    @{
        Sam  = "svc_scada"
        Name = "SVC - SCADA Service"
        Desc = "Compte de service pour le systeme SCADA (ScadaBR)"
        Groups = @("GG_Acces_SCADA","GG_Acces_Historian")
    }
    @{
        Sam  = "svc_historian"
        Name = "SVC - Historian Service"
        Desc = "Compte de service pour l historisation (InfluxDB/PI)"
        Groups = @("GG_Acces_Historian")
    }
    @{
        Sam  = "svc_mes"
        Name = "SVC - MES Application"
        Desc = "Compte de service pour l application MES"
        Groups = @("GG_Acces_MES","GG_Acces_Historian")
    }
    @{
        Sam  = "svc_gmao"
        Name = "SVC - GMAO Service"
        Desc = "Compte de service pour la GMAO (Infor EAM)"
        Groups = @("GG_Acces_GMAO")
    }
    @{
        Sam  = "svc_backup"
        Name = "SVC - Sauvegarde"
        Desc = "Compte de service pour les sauvegardes serveurs"
        Groups = @()
    }
    @{
        Sam  = "svc_sql"
        Name = "SVC - SQL Server"
        Desc = "Compte de service SQL Server (MES/GMAO)"
        Groups = @()
    }
    @{
        Sam  = "svc_web"
        Name = "SVC - Portail Web"
        Desc = "Compte de service pour le portail web interne"
        Groups = @("GG_Acces_Portail_Web")
    }
)

foreach ($Svc in $ServiceAccounts) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($Svc.Sam)'" -ErrorAction SilentlyContinue)) {
        New-ADUser -SamAccountName $Svc.Sam `
                   -UserPrincipalName "$($Svc.Sam)@$Domain" `
                   -Name $Svc.Name `
                   -DisplayName $Svc.Name `
                   -Description $Svc.Desc `
                   -Path $SvcPath `
                   -AccountPassword $SvcPass `
                   -Enabled $true `
                   -PasswordNeverExpires $true `
                   -CannotChangePassword $true `
                   -ChangePasswordAtLogon $false

        foreach ($GroupName in $Svc.Groups) {
            Add-ADGroupMember -Identity $GroupName -Members $Svc.Sam -ErrorAction SilentlyContinue
        }

        Write-Host "  [+] Compte de service cree : $($Svc.Sam)" -ForegroundColor Green
    } else {
        Write-Host "  [=] Compte de service existant : $($Svc.Sam)" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ==============================================================================
# 5. COMPTES MACHINES (ORDINATEURS)
# ==============================================================================

Write-Host "[5/6] Creation des Comptes Machines..." -ForegroundColor Yellow

# --- Machines organisees par zone fonctionnelle ---
$Computers = @(
    # === SERVEURS ===
    # (DC01 existe deja - c est le serveur courant)
    @{ Name = "SRV-FILES01";   OU = "OU=Serveurs,OU=Ordinateurs,OU=Usine,$DomainDN";         Desc = "Serveur de fichiers SMB (Windows Server 2016)" }
    @{ Name = "SRV-APP01";     OU = "OU=Serveurs,OU=Ordinateurs,OU=Usine,$DomainDN";         Desc = "Serveur MES + ERP/GMAO (Windows Server 2012 R2)" }

    # === POSTES SCADA / HMI (salle de controle) ===
    @{ Name = "PC-HMI-REACT01";  OU = "OU=Postes_SCADA_HMI,OU=Ordinateurs,OU=Usine,$DomainDN"; Desc = "IHM Salle de controle - Zone Reaction 1" }
    @{ Name = "PC-HMI-REACT02";  OU = "OU=Postes_SCADA_HMI,OU=Ordinateurs,OU=Usine,$DomainDN"; Desc = "IHM Salle de controle - Zone Reaction 2" }
    @{ Name = "PC-HMI-DIST01";   OU = "OU=Postes_SCADA_HMI,OU=Ordinateurs,OU=Usine,$DomainDN"; Desc = "IHM Salle de controle - Distillation" }
    @{ Name = "PC-HMI-STOCK01";  OU = "OU=Postes_SCADA_HMI,OU=Ordinateurs,OU=Usine,$DomainDN"; Desc = "IHM Salle de controle - Stockage / Bacs" }
    @{ Name = "PC-HMI-UTIL01";   OU = "OU=Postes_SCADA_HMI,OU=Ordinateurs,OU=Usine,$DomainDN"; Desc = "IHM Salle de controle - Utilites (vapeur, eau, air)" }
    @{ Name = "PC-SCADA-ENG01";  OU = "OU=Postes_SCADA_HMI,OU=Ordinateurs,OU=Usine,$DomainDN"; Desc = "Poste ingenierie SCADA / configuration automates" }
    @{ Name = "PC-SCADA-ENG02";  OU = "OU=Postes_SCADA_HMI,OU=Ordinateurs,OU=Usine,$DomainDN"; Desc = "Poste ingenierie SCADA / supervision" }

    # === POSTES LABORATOIRE ===
    @{ Name = "PC-LABO-01";   OU = "OU=Postes_Laboratoire,OU=Ordinateurs,OU=Usine,$DomainDN"; Desc = "Poste labo - Analyses chimiques" }
    @{ Name = "PC-LABO-02";   OU = "OU=Postes_Laboratoire,OU=Ordinateurs,OU=Usine,$DomainDN"; Desc = "Poste labo - Chromatographie / LIMS" }

    # === POSTES MAINTENANCE ===
    @{ Name = "PC-MAINT-01";  OU = "OU=Postes_Maintenance,OU=Ordinateurs,OU=Usine,$DomainDN"; Desc = "Poste maintenance - Bureau technique" }
    @{ Name = "PC-MAINT-02";  OU = "OU=Postes_Maintenance,OU=Ordinateurs,OU=Usine,$DomainDN"; Desc = "Poste maintenance - Atelier instrumentation" }

    # === POSTES BUREAU (direction, HSE, logistique...) ===
    @{ Name = "PC-DIRPROD-01";  OU = "OU=Postes_Bureau,OU=Ordinateurs,OU=Usine,$DomainDN";   Desc = "Poste directeur de production" }
    @{ Name = "PC-PLAN-01";     OU = "OU=Postes_Bureau,OU=Ordinateurs,OU=Usine,$DomainDN";   Desc = "Poste planning production" }
    @{ Name = "PC-HSE-01";      OU = "OU=Postes_Bureau,OU=Ordinateurs,OU=Usine,$DomainDN";   Desc = "Poste HSE" }
    @{ Name = "PC-HSE-02";      OU = "OU=Postes_Bureau,OU=Ordinateurs,OU=Usine,$DomainDN";   Desc = "Poste HSE - Environnement" }
    @{ Name = "PC-EXPED-01";    OU = "OU=Postes_Bureau,OU=Ordinateurs,OU=Usine,$DomainDN";   Desc = "Poste expedition / logistique" }
    @{ Name = "PC-MAGASIN-01";  OU = "OU=Postes_Bureau,OU=Ordinateurs,OU=Usine,$DomainDN";   Desc = "Poste magasin / reception" }
)

foreach ($PC in $Computers) {
    if (-not (Get-ADComputer -Filter "Name -eq '$($PC.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADComputer -Name $PC.Name `
                       -SamAccountName "$($PC.Name)$" `
                       -Path $PC.OU `
                       -Description $PC.Desc `
                       -Enabled $true
        Write-Host "  [+] Machine creee : $($PC.Name)" -ForegroundColor Green
    } else {
        Write-Host "  [=] Machine existante : $($PC.Name)" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ==============================================================================
# 6. GROUP POLICY OBJECTS (GPOs)
# ==============================================================================

Write-Host "[6/6] Creation des GPOs..." -ForegroundColor Yellow

# --- GPO 1 : Politique de mot de passe basique (faible - realiste avant securisation) ---
$GPOName = "Usine - Politique Mots de Passe"
if (-not (Get-GPO -Name $GPOName -ErrorAction SilentlyContinue)) {
    $gpo = New-GPO -Name $GPOName -Comment "Politique de mots de passe usine (basique)"
    # Mot de passe : 8 caracteres min, complexite desactivee, pas d historique
    # => realiste pour un site industriel non securise
    Set-GPRegistryValue -Name $GPOName -Key "HKLM\Software\Policies\Microsoft\Windows\System" `
        -ValueName "AllowDomainPINLogon" -Type DWord -Value 0 2>$null
    $gpo | New-GPLink -Target $DomainDN -LinkEnabled Yes -ErrorAction SilentlyContinue
    Write-Host "  [+] GPO creee : $GPOName" -ForegroundColor Green
} else {
    Write-Host "  [=] GPO existante : $GPOName" -ForegroundColor DarkGray
}

# Configuration de la politique de mot de passe du domaine (via Default Domain Policy)
# En environnement reel non securise : mots de passe faibles et jamais changes
Write-Host "  [*] Configuration politique mot de passe domaine (Default Domain Policy)..." -ForegroundColor DarkYellow
try {
    Set-ADDefaultDomainPasswordPolicy -Identity $Domain `
        -MinPasswordLength 8 `
        -PasswordHistoryCount 0 `
        -MaxPasswordAge "00:00:00" `
        -MinPasswordAge "00:00:00" `
        -ComplexityEnabled $false `
        -LockoutThreshold 0 `
        -ReversibleEncryptionEnabled $false
    Write-Host "  [+] Politique mot de passe : 8 car. min, pas de complexite, pas d'expiration" -ForegroundColor Green
} catch {
    Write-Host "  [!] Erreur configuration politique mdp : $($_.Exception.Message)" -ForegroundColor Red
}

# --- GPO 2 : Lecteur reseau partages production ---
$GPOName = "Usine - Lecteurs Reseau Production"
if (-not (Get-GPO -Name $GPOName -ErrorAction SilentlyContinue)) {
    $gpo = New-GPO -Name $GPOName -Comment "Mappage automatique des lecteurs reseau de production"
    # Preferences de lecteurs reseau (via registre - simplifie)
    # En production reelle : GPP Drive Maps serait utilise via GPMC
    # Ici on documente l intention via le registre
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2" `
        -ValueName "ProductionDocs" -Type String -Value "\\SRV-FILES01\ProductionDocs" 2>$null
    $gpo | New-GPLink -Target "OU=Usine,$DomainDN" -LinkEnabled Yes -ErrorAction SilentlyContinue
    Write-Host "  [+] GPO creee : $GPOName" -ForegroundColor Green
} else {
    Write-Host "  [=] GPO existante : $GPOName" -ForegroundColor DarkGray
}

# --- GPO 3 : Parametres postes SCADA / HMI ---
$GPOName = "Usine - Postes SCADA HMI"
if (-not (Get-GPO -Name $GPOName -ErrorAction SilentlyContinue)) {
    $gpo = New-GPO -Name $GPOName -Comment "Configuration des postes HMI en salle de controle"
    # Ecran de veille desactive (operateurs doivent voir le process en permanence)
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKCU\Control Panel\Desktop" `
        -ValueName "ScreenSaveActive" -Type String -Value "0"
    # Pas de verrouillage automatique (mauvaise pratique mais realiste en salle de controle)
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKCU\Control Panel\Desktop" `
        -ValueName "ScreenSaverIsSecure" -Type String -Value "0"
    # Desactiver Windows Update automatique (contrainte SCADA : pas de redemarrage non planifie)
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" `
        -ValueName "NoAutoUpdate" -Type DWord -Value 1
    $gpo | New-GPLink -Target "OU=Postes_SCADA_HMI,OU=Ordinateurs,OU=Usine,$DomainDN" -LinkEnabled Yes -ErrorAction SilentlyContinue
    Write-Host "  [+] GPO creee : $GPOName" -ForegroundColor Green
} else {
    Write-Host "  [=] GPO existante : $GPOName" -ForegroundColor DarkGray
}

# --- GPO 4 : Pare-feu Windows desactive sur les serveurs (realiste en indus legacy) ---
$GPOName = "Usine - Firewall Serveurs Desactive"
if (-not (Get-GPO -Name $GPOName -ErrorAction SilentlyContinue)) {
    $gpo = New-GPO -Name $GPOName -Comment "Desactivation du pare-feu Windows sur les serveurs (legacy)"
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\DomainProfile" `
        -ValueName "EnableFirewall" -Type DWord -Value 0
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\StandardProfile" `
        -ValueName "EnableFirewall" -Type DWord -Value 0
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\PublicProfile" `
        -ValueName "EnableFirewall" -Type DWord -Value 0
    $gpo | New-GPLink -Target "OU=Serveurs,OU=Ordinateurs,OU=Usine,$DomainDN" -LinkEnabled Yes -ErrorAction SilentlyContinue
    Write-Host "  [+] GPO creee : $GPOName" -ForegroundColor Green
} else {
    Write-Host "  [=] GPO existante : $GPOName" -ForegroundColor DarkGray
}

# --- GPO 5 : Bureau / fond d ecran usine ---
$GPOName = "Usine - Fond Ecran Entreprise"
if (-not (Get-GPO -Name $GPOName -ErrorAction SilentlyContinue)) {
    $gpo = New-GPO -Name $GPOName -Comment "Fond d ecran et branding Blue Chemicals"
    # Message de connexion
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
        -ValueName "legalnoticecaption" -Type String -Value "Blue Chemicals - Site de Production"
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
        -ValueName "legalnoticetext" -Type String -Value "Acces reserve au personnel autorise. Toute utilisation est tracee."
    $gpo | New-GPLink -Target "OU=Usine,$DomainDN" -LinkEnabled Yes -ErrorAction SilentlyContinue
    Write-Host "  [+] GPO creee : $GPOName" -ForegroundColor Green
} else {
    Write-Host "  [=] GPO existante : $GPOName" -ForegroundColor DarkGray
}

# --- GPO 6 : Postes laboratoire - restriction basique ---
$GPOName = "Usine - Postes Laboratoire"
if (-not (Get-GPO -Name $GPOName -ErrorAction SilentlyContinue)) {
    $gpo = New-GPO -Name $GPOName -Comment "Configuration des postes laboratoire"
    # Ecran de veille apres 10 min (le labo n est pas en supervision continue)
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKCU\Control Panel\Desktop" `
        -ValueName "ScreenSaveActive" -Type String -Value "1"
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKCU\Control Panel\Desktop" `
        -ValueName "ScreenSaveTimeOut" -Type String -Value "600"
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKCU\Control Panel\Desktop" `
        -ValueName "ScreenSaverIsSecure" -Type String -Value "1"
    $gpo | New-GPLink -Target "OU=Postes_Laboratoire,OU=Ordinateurs,OU=Usine,$DomainDN" -LinkEnabled Yes -ErrorAction SilentlyContinue
    Write-Host "  [+] GPO creee : $GPOName" -ForegroundColor Green
} else {
    Write-Host "  [=] GPO existante : $GPOName" -ForegroundColor DarkGray
}

Write-Host ""

# ==============================================================================
# IMBRICATION DES GROUPES (AGDLP simplifie)
# ==============================================================================

Write-Host "[*] Imbrication des groupes dans les groupes de partage..." -ForegroundColor Yellow

# ProductionDocs : direction + procedes + ingenieurs en RW, le reste en RO
Add-ADGroupMember -Identity "DL_Partage_ProductionDocs_RO" -Members "GG_Operateurs_Procedes","GG_Maintenance","GG_HSE","GG_Logistique","GG_Laboratoire" -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "DL_Partage_ProductionDocs_RW" -Members "GG_Direction_Production","GG_Chefs_Quart","GG_Ingenieurs_Procedes","GG_SCADA_Supervision" -ErrorAction SilentlyContinue

# QualityDocs : labo en RW, le reste en RO
Add-ADGroupMember -Identity "DL_Partage_QualityDocs_RW" -Members "GG_Laboratoire" -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "DL_Partage_QualityDocs_RO" -Members "GG_Direction_Production","GG_Ingenieurs_Procedes","GG_HSE" -ErrorAction SilentlyContinue

# EngineeringDocs : ingenieurs + SCADA en RW, maintenance en RO
Add-ADGroupMember -Identity "DL_Partage_EngineeringDocs_RW" -Members "GG_Ingenieurs_Procedes","GG_SCADA_Supervision" -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "DL_Partage_EngineeringDocs_RO" -Members "GG_Maintenance","GG_Direction_Production" -ErrorAction SilentlyContinue

# Maintenance : equipe maintenance en RW, supervision + direction en RO
Add-ADGroupMember -Identity "DL_Partage_Maintenance_RW" -Members "GG_Maintenance" -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "DL_Partage_Maintenance_RO" -Members "GG_Direction_Production","GG_SCADA_Supervision" -ErrorAction SilentlyContinue

# HSE : equipe HSE en RW
Add-ADGroupMember -Identity "DL_Partage_HSE_RW" -Members "GG_HSE" -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "DL_Partage_HSE_RO" -Members "GG_Direction_Production","GG_Chefs_Quart" -ErrorAction SilentlyContinue

# Groupes applicatifs - acces large (typique avant securisation)
Add-ADGroupMember -Identity "GG_Acces_SCADA" -Members "GG_Chefs_Quart","GG_SCADA_Supervision","GG_Ingenieurs_Procedes" -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "GG_Acces_MES" -Members "GG_Direction_Production","GG_Chefs_Quart","GG_Ingenieurs_Procedes","GG_Logistique" -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "GG_Acces_GMAO" -Members "GG_Maintenance" -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "GG_Acces_Historian" -Members "GG_SCADA_Supervision","GG_Ingenieurs_Procedes","GG_Laboratoire","GG_HSE" -ErrorAction SilentlyContinue
Add-ADGroupMember -Identity "GG_Acces_Portail_Web" -Members "GG_Direction_Production","GG_Operateurs_Procedes","GG_Chefs_Quart","GG_Ingenieurs_Procedes","GG_Laboratoire","GG_Maintenance","GG_HSE","GG_Logistique","GG_SCADA_Supervision" -ErrorAction SilentlyContinue

Write-Host "  [+] Imbrication des groupes terminee" -ForegroundColor Green

Write-Host ""

# ==============================================================================
# AJOUT DU COMPTE ADMIN SYSTEME AU GROUPE DOMAIN ADMINS
# (pratique courante en site industriel non securise)
# ==============================================================================

Write-Host "[*] Configuration admin..." -ForegroundColor Yellow

# Jerome Gauthier (admin systeme industriel) est aussi Domain Admin
# => Mauvaise pratique typique d un site non securise
$adminSam = Get-SamAccount -Prenom "Jerome" -Nom "Gauthier"
Add-ADGroupMember -Identity "Domain Admins" -Members $adminSam -ErrorAction SilentlyContinue
Write-Host "  [+] $adminSam ajoute au groupe Domain Admins (admin systeme site)" -ForegroundColor Green

# Le directeur de prod est aussi admin local de son poste (classique)
$dirSam = Get-SamAccount -Prenom "Jean-Pierre" -Nom "Moreau"
Add-ADGroupMember -Identity "GG_Admin_Postes_Prod" -Members $dirSam -ErrorAction SilentlyContinue

Write-Host ""

# ==============================================================================
# RESUME
# ==============================================================================

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DEPLOIEMENT TERMINE"                                        -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$OUCount    = (Get-ADOrganizationalUnit -Filter * -SearchBase "OU=Usine,$DomainDN" | Measure-Object).Count
$UserCount  = (Get-ADUser -Filter * -SearchBase "OU=Usine,$DomainDN" | Measure-Object).Count
$GroupCount = (Get-ADGroup -Filter * -SearchBase "OU=Groupes,OU=Usine,$DomainDN" | Measure-Object).Count
$PCCount    = (Get-ADComputer -Filter * -SearchBase "OU=Ordinateurs,OU=Usine,$DomainDN" | Measure-Object).Count
$GPOCount   = (Get-GPO -All | Where-Object { $_.DisplayName -like "Usine*" } | Measure-Object).Count

Write-Host "  Domaine          : $Domain" -ForegroundColor White
Write-Host "  OUs creees       : $OUCount" -ForegroundColor White
Write-Host "  Utilisateurs     : $UserCount (dont comptes de service)" -ForegroundColor White
Write-Host "  Groupes          : $GroupCount" -ForegroundColor White
Write-Host "  Machines         : $PCCount" -ForegroundColor White
Write-Host "  GPOs             : $GPOCount" -ForegroundColor White
Write-Host ""
Write-Host "  Mot de passe utilisateurs : Usine2025!" -ForegroundColor Yellow
Write-Host "  Mot de passe services     : Svc_Blue2025!" -ForegroundColor Yellow
Write-Host ""
Write-Host "  /!\ Cet environnement est volontairement NON SECURISE." -ForegroundColor Red
Write-Host "  /!\ Il represente un etat initial avant demarche de securisation." -ForegroundColor Red
Write-Host ""
