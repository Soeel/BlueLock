<#
.SYNOPSIS
    Creation des dossiers et partages SMB sur le serveur de fichiers SRV-FILES01.

.DESCRIPTION
    Script dedie a la creation de l arborescence de dossiers et des partages SMB
    sur un serveur de fichiers ou le role est deja installe.

    Actions realisees :
    - Creation des dossiers racine pour chaque partage
    - Creation des partages SMB avec permissions de partage
    - Configuration des ACL NTFS (groupes AD - modele AGDLP)
    - Creation des sous-dossiers metier dans chaque partage

    Prerequis :
    - Le role Serveur de fichiers (FS-FileServer) doit etre installe
    - La machine doit etre jointe au domaine blue.local
    - Le script Deploy-AD-Usine.ps1 doit avoir ete execute sur DC01 au prealable
      (pour que les groupes AD existent)
    - Executer ce script en tant qu Administrateur

.NOTES
    Projet  : BlueLock - Socle de securite industriel
    Contexte: Environnement de test ISA-95 / Usine chimique
    Serveur : SRV-FILES01 (SRV-FILESAPP)
    OS      : Windows Server 2016
    Auteur  : BlueLock Team
    Version : 1.0
#>

# ==============================================================================
# CONFIGURATION
# ==============================================================================

$ServerName     = $env:COMPUTERNAME
$DomainNetBIOS  = "BLUE"
$ShareRoot      = "D:\Partages"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  CREATION DES DOSSIERS ET PARTAGES SMB"                      -ForegroundColor Cyan
Write-Host "  Serveur : $ServerName | Domaine : $DomainNetBIOS"           -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# VERIFICATION DES PREREQUIS
# ==============================================================================

Write-Host "[0/4] Verification des prerequis..." -ForegroundColor Yellow

# Verifier que le role File Server est installe
$FSRole = Get-WindowsFeature -Name FS-FileServer
if (-not $FSRole.Installed) {
    Write-Host "  [!] Le role Serveur de fichiers n est pas installe." -ForegroundColor Red
    Write-Host "  [!] Installez-le avec : Install-WindowsFeature FS-FileServer -IncludeManagementTools" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Role Serveur de fichiers installe" -ForegroundColor Green

# Verifier la jonction au domaine
$CurrentDomain = (Get-WmiObject Win32_ComputerSystem).Domain
if ($CurrentDomain -notlike "*blue*") {
    Write-Host "  [!] La machine n est pas jointe au domaine blue.local (actuel: $CurrentDomain)" -ForegroundColor Red
    Write-Host "  [!] Les permissions AD ne pourront pas etre appliquees." -ForegroundColor Yellow
    $NoDomain = $true
} else {
    Write-Host "  [OK] Membre du domaine $CurrentDomain" -ForegroundColor Green
}

Write-Host ""

# ==============================================================================
# 1. CREATION DU REPERTOIRE RACINE
# ==============================================================================

Write-Host "[1/4] Creation du repertoire racine des partages..." -ForegroundColor Yellow

if (-not (Test-Path $ShareRoot)) {
    New-Item -Path $ShareRoot -ItemType Directory -Force | Out-Null
    Write-Host "  [+] Repertoire racine cree : $ShareRoot" -ForegroundColor Green
} else {
    Write-Host "  [=] Repertoire racine existant : $ShareRoot" -ForegroundColor DarkGray
}

Write-Host ""

# ==============================================================================
# 2. CREATION DES PARTAGES SMB
# ==============================================================================

Write-Host "[2/4] Creation des dossiers et partages SMB..." -ForegroundColor Yellow

# Definition des partages conformement au TODO.md et au script AD
$Shares = @(
    @{
        Name        = "ProductionDocs"
        Path        = "$ShareRoot\ProductionDocs"
        Description = "Documentation production - procedures, consignes, rapports"
        RWGroup     = "$DomainNetBIOS\DL_Partage_ProductionDocs_RW"
        ROGroup     = "$DomainNetBIOS\DL_Partage_ProductionDocs_RO"
    }
    @{
        Name        = "QualityDocs"
        Path        = "$ShareRoot\QualityDocs"
        Description = "Procedures qualite - analyses, certificats, protocoles"
        RWGroup     = "$DomainNetBIOS\DL_Partage_QualityDocs_RW"
        ROGroup     = "$DomainNetBIOS\DL_Partage_QualityDocs_RO"
    }
    @{
        Name        = "EngineeringDocs"
        Path        = "$ShareRoot\EngineeringDocs"
        Description = "Etudes et documents techniques - schemas, plans, specifications"
        RWGroup     = "$DomainNetBIOS\DL_Partage_EngineeringDocs_RW"
        ROGroup     = "$DomainNetBIOS\DL_Partage_EngineeringDocs_RO"
    }
    @{
        Name        = "Confidentiel"
        Path        = "$ShareRoot\Confidentiel"
        Description = "Documents confidentiels - brevets, contrats, donnees sensibles"
        RWGroup     = "$DomainNetBIOS\DL_Partage_Confidentiel_RW"
        ROGroup     = $null  # Pas de groupe RO - acces restreint
    }
    @{
        Name        = "Maintenance"
        Path        = "$ShareRoot\Maintenance"
        Description = "Documentation maintenance - gammes, historiques interventions"
        RWGroup     = "$DomainNetBIOS\DL_Partage_Maintenance_RW"
        ROGroup     = "$DomainNetBIOS\DL_Partage_Maintenance_RO"
    }
    @{
        Name        = "HSE"
        Path        = "$ShareRoot\HSE"
        Description = "Documents HSE - fiches securite, audits environnement, POI"
        RWGroup     = "$DomainNetBIOS\DL_Partage_HSE_RW"
        ROGroup     = "$DomainNetBIOS\DL_Partage_HSE_RO"
    }
)

foreach ($Share in $Shares) {
    # --- Creer le dossier ---
    if (-not (Test-Path $Share.Path)) {
        New-Item -Path $Share.Path -ItemType Directory -Force | Out-Null
        Write-Host "  [+] Dossier cree : $($Share.Path)" -ForegroundColor Green
    } else {
        Write-Host "  [=] Dossier existant : $($Share.Path)" -ForegroundColor DarkGray
    }

    # --- Creer le partage SMB ---
    $Existing = Get-SmbShare -Name $Share.Name -ErrorAction SilentlyContinue
    if (-not $Existing) {
        New-SmbShare -Name $Share.Name `
                     -Path $Share.Path `
                     -Description $Share.Description `
                     -FullAccess "BUILTIN\Administrateurs" `
                     -NoAccess "Everyone"
        Write-Host "  [+] Partage SMB cree : \\$ServerName\$($Share.Name)" -ForegroundColor Green
    } else {
        Write-Host "  [=] Partage existant : \\$ServerName\$($Share.Name)" -ForegroundColor DarkGray
    }

    # --- Permissions SMB (niveau partage) ---
    if (-not $NoDomain) {
        if ($Share.RWGroup) {
            Grant-SmbShareAccess -Name $Share.Name -AccountName $Share.RWGroup -AccessRight Change -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  [+]   SMB Change : $($Share.RWGroup)" -ForegroundColor DarkGreen
        }
        if ($Share.ROGroup) {
            Grant-SmbShareAccess -Name $Share.Name -AccountName $Share.ROGroup -AccessRight Read -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  [+]   SMB Read   : $($Share.ROGroup)" -ForegroundColor DarkGreen
        }
    }
}

Write-Host ""

# ==============================================================================
# 3. CONFIGURATION DES PERMISSIONS NTFS
# ==============================================================================

Write-Host "[3/4] Configuration des permissions NTFS..." -ForegroundColor Yellow

foreach ($Share in $Shares) {
    Write-Host "  [*] NTFS : $($Share.Name)" -ForegroundColor DarkYellow

    # Recuperer l ACL actuelle
    $Acl = Get-Acl -Path $Share.Path

    # Desactiver l heritage et supprimer les regles heritees
    $Acl.SetAccessRuleProtection($true, $false)

    # --- Administrateurs : Controle total ---
    $AdminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrateurs", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $Acl.AddAccessRule($AdminRule)

    # --- SYSTEM : Controle total ---
    $SystemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $Acl.AddAccessRule($SystemRule)

    # --- Groupe RW : Modification ---
    if (-not $NoDomain -and $Share.RWGroup) {
        $RWRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Share.RWGroup, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $Acl.AddAccessRule($RWRule)
        Write-Host "  [+]   NTFS Modify : $($Share.RWGroup)" -ForegroundColor DarkGreen
    }

    # --- Groupe RO : Lecture seule ---
    if (-not $NoDomain -and $Share.ROGroup) {
        $RORule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Share.ROGroup, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $Acl.AddAccessRule($RORule)
        Write-Host "  [+]   NTFS Read   : $($Share.ROGroup)" -ForegroundColor DarkGreen
    }

    # Appliquer l ACL
    Set-Acl -Path $Share.Path -AclObject $Acl
    Write-Host "  [+] NTFS appliquees sur $($Share.Path)" -ForegroundColor Green
}

Write-Host ""

# ==============================================================================
# 4. CREATION DE L ARBORESCENCE DE SOUS-DOSSIERS
# ==============================================================================

Write-Host "[4/4] Creation de l arborescence de sous-dossiers..." -ForegroundColor Yellow

$SubFolders = @{
    "ProductionDocs" = @(
        "Consignes_Operatoires",
        "Rapports_Production",
        "Fiches_Lot",
        "Procedures_Demarrage_Arret",
        "Astreintes"
    )
    "QualityDocs" = @(
        "Protocoles_Analyse",
        "Certificats_Conformite",
        "Non_Conformites",
        "Audits_Qualite",
        "Specifications_Produits"
    )
    "EngineeringDocs" = @(
        "Schemas_PID",
        "Plans_Implantation",
        "Specifications_Equipements",
        "Notes_Calcul",
        "Projets_Modification"
    )
    "Confidentiel" = @(
        "Brevets",
        "Contrats_Fournisseurs",
        "Donnees_Strategiques"
    )
    "Maintenance" = @(
        "Gammes_Maintenance",
        "Historique_Interventions",
        "Plans_Preventif",
        "Pieces_Rechange",
        "Documentation_Constructeur"
    )
    "HSE" = @(
        "Fiches_Donnees_Securite",
        "POI_Plan_Urgence",
        "Audits_Environnement",
        "Accidents_Incidents",
        "Formation_Securite"
    )
}

foreach ($ShareName in $SubFolders.Keys) {
    foreach ($Folder in $SubFolders[$ShareName]) {
        $FullPath = "$ShareRoot\$ShareName\$Folder"
        if (-not (Test-Path $FullPath)) {
            New-Item -Path $FullPath -ItemType Directory -Force | Out-Null
        }
    }
    Write-Host "  [+] $ShareName : $($SubFolders[$ShareName].Count) sous-dossiers crees" -ForegroundColor Green
}

Write-Host ""

# ==============================================================================
# RESUME
# ==============================================================================

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  CREATION DES PARTAGES TERMINEE"                             -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Serveur : $ServerName" -ForegroundColor White
Write-Host "  Racine  : $ShareRoot" -ForegroundColor White
Write-Host ""
Write-Host "  --- Partages crees ---" -ForegroundColor Cyan

foreach ($Share in $Shares) {
    $SubCount = if ($SubFolders[$Share.Name]) { $SubFolders[$Share.Name].Count } else { 0 }
    Write-Host "  \\$ServerName\$($Share.Name)  ($SubCount sous-dossiers)" -ForegroundColor White
    if ($Share.RWGroup) {
        Write-Host "    RW : $($Share.RWGroup)" -ForegroundColor DarkGreen
    }
    if ($Share.ROGroup) {
        Write-Host "    RO : $($Share.ROGroup)" -ForegroundColor DarkGreen
    }
}

Write-Host ""
Write-Host "  --- Arborescence ---" -ForegroundColor Cyan
foreach ($ShareName in $SubFolders.Keys | Sort-Object) {
    Write-Host "  $ShareName\" -ForegroundColor White
    foreach ($Folder in $SubFolders[$ShareName]) {
        Write-Host "    +-- $Folder\" -ForegroundColor DarkGray
    }
}

Write-Host ""
if ($NoDomain) {
    Write-Host "  /!\ Les permissions AD n ont pas ete appliquees (machine hors domaine)." -ForegroundColor Yellow
    Write-Host "  /!\ Rejoignez le domaine puis relancez ce script." -ForegroundColor Yellow
    Write-Host ""
}
Write-Host "  Prochaine etape : verifier l acces depuis un poste client" -ForegroundColor White
Write-Host "    net use P: \\$ServerName\ProductionDocs" -ForegroundColor DarkGray
Write-Host ""
