<#
.SYNOPSIS
    Deploiement du serveur SRV-FILES-APP (SRV-FILES01) - Serveur de fichiers et application MES.

.DESCRIPTION
    Script de deploiement complet pour le serveur SRV-FILES-APP dans le cadre
    du projet BlueLock (usine chimique ISA-95).

    Actions realisees :
    - Jonction au domaine blue.local
    - Installation du role Serveur de fichiers (SMB)
    - Creation des partages reseau avec permissions NTFS (groupes AD)
    - Installation des prerequis applicatifs (IIS, .NET, SQL Server Express)
    - Deploiement d une application MES factice

    Ce script exclut volontairement la partie ERP/GMAO.

    Prerequis :
    - Windows Server 2016 installe (template-wserv2016)
    - Connectivite reseau vers le DC (DC01 / blue.local)
    - Le script Deploy-AD-Usine.ps1 doit avoir ete execute sur DC01 au prealable
    - Executer ce script en tant qu Administrateur local

.NOTES
    Projet  : BlueLock - Socle de securite industriel
    Contexte: Environnement de test ISA-95 / Usine chimique
    Serveur : SRV-FILES01 (SRV-FILESAPP)
    OS      : Windows Server 2016
    Auteur  : BlueLock Team
    Version : 1.0
#>

# ==============================================================================
# CONFIGURATION GENERALE
# ==============================================================================

$ServerName     = "SRV-FILES01"
$Domain         = "blue.local"
$DomainNetBIOS  = "BLUE"
$DNSIP          = "192.168.1.10"      # IP du DC01 (serveur DNS)
$DomainAdmin    = "$DomainNetBIOS\Administrateur"
$DomainAdminPwd = ConvertTo-SecureString "Usine2025!" -AsPlainText -Force
$DomainCred     = New-Object System.Management.Automation.PSCredential($DomainAdmin, $DomainAdminPwd)

# Compte de service SQL Server
$SvcSqlUser     = "$DomainNetBIOS\svc_sql"
$SvcSqlPwd      = ConvertTo-SecureString "Svc_Blue2025!" -AsPlainText -Force

# Compte de service MES
$SvcMesUser     = "$DomainNetBIOS\svc_mes"
$SvcMesPwd      = ConvertTo-SecureString "Svc_Blue2025!" -AsPlainText -Force

# Repertoire racine des partages
$ShareRoot      = "D:\Partages"
# Repertoire pour les applications
$AppRoot        = "C:\Applications"
# Repertoire pour SQL Server Express
$SQLDataDir     = "D:\SQLData"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DEPLOIEMENT SRV-FILES-APP (SRV-FILES01)"                    -ForegroundColor Cyan
Write-Host "  Serveur de fichiers SMB + Application MES"                   -ForegroundColor Cyan
Write-Host "  Domaine : $Domain"                                           -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# 1. CONFIGURATION RESEAU ET JONCTION AU DOMAINE
# ==============================================================================

Write-Host "[1/7] Configuration reseau et jonction au domaine..." -ForegroundColor Yellow

# --- 1.1 Renommer la machine ---
$CurrentName = $env:COMPUTERNAME
if ($CurrentName -ne $ServerName) {
    Write-Host "  [*] Renommage de la machine : $CurrentName -> $ServerName" -ForegroundColor DarkYellow
    Rename-Computer -NewName $ServerName -Force
    Write-Host "  [+] Machine renommee en $ServerName" -ForegroundColor Green
} else {
    Write-Host "  [=] Nom de machine deja correct : $ServerName" -ForegroundColor DarkGray
}

# --- 1.2 Configurer le DNS pour pointer vers le DC ---
Write-Host "  [*] Configuration DNS vers DC01 ($DNSIP)..." -ForegroundColor DarkYellow
$NetAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
if ($NetAdapter) {
    Set-DnsClientServerAddress -InterfaceIndex $NetAdapter.InterfaceIndex -ServerAddresses $DNSIP
    Write-Host "  [+] DNS configure sur l'interface '$($NetAdapter.Name)' -> $DNSIP" -ForegroundColor Green
} else {
    Write-Host "  [!] Aucune interface reseau active trouvee" -ForegroundColor Red
    exit 1
}

# --- 1.3 Joindre le domaine ---
$InDomain = (Get-WmiObject Win32_ComputerSystem).Domain
if ($InDomain -ne $Domain) {
    Write-Host "  [*] Jonction au domaine $Domain..." -ForegroundColor DarkYellow
    try {
        Add-Computer -DomainName $Domain `
                     -Credential $DomainCred `
                     -OUPath "OU=Serveurs,OU=Ordinateurs,OU=Usine,DC=blue,DC=local" `
                     -Force
        Write-Host "  [+] Jonction au domaine $Domain reussie" -ForegroundColor Green
        Write-Host "  [!] Un redemarrage sera necessaire pour finaliser la jonction" -ForegroundColor Yellow
        $NeedReboot = $true
    } catch {
        Write-Host "  [!] Erreur jonction domaine : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  [!] Verifier la connectivite vers DC01 et les identifiants" -ForegroundColor Red
    }
} else {
    Write-Host "  [=] Deja membre du domaine $Domain" -ForegroundColor DarkGray
}

Write-Host ""

# ==============================================================================
# 2. INSTALLATION DU ROLE SERVEUR DE FICHIERS
# ==============================================================================

Write-Host "[2/7] Installation du role Serveur de fichiers..." -ForegroundColor Yellow

$FileServerFeatures = @(
    "FS-FileServer",            # Role serveur de fichiers de base
    "FS-Resource-Manager"       # Gestionnaire de ressources (quotas, filtrage)
)

foreach ($Feature in $FileServerFeatures) {
    $Installed = Get-WindowsFeature -Name $Feature
    if (-not $Installed.Installed) {
        Install-WindowsFeature -Name $Feature -IncludeManagementTools
        Write-Host "  [+] Role installe : $($Installed.DisplayName) ($Feature)" -ForegroundColor Green
    } else {
        Write-Host "  [=] Role deja installe : $($Installed.DisplayName) ($Feature)" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ==============================================================================
# 3. CREATION DES PARTAGES RESEAU SMB
# ==============================================================================

Write-Host "[3/7] Creation des partages reseau SMB..." -ForegroundColor Yellow

# --- 3.1 Creer le repertoire racine ---
if (-not (Test-Path $ShareRoot)) {
    New-Item -Path $ShareRoot -ItemType Directory -Force | Out-Null
    Write-Host "  [+] Repertoire racine cree : $ShareRoot" -ForegroundColor Green
} else {
    Write-Host "  [=] Repertoire racine existant : $ShareRoot" -ForegroundColor DarkGray
}

# --- 3.2 Definition des partages ---
# Conformement au TODO et aux groupes AD crees par Deploy-AD-Usine.ps1
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
        ROGroup     = $null  # Pas de groupe RO pour ce partage
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

    # --- Configurer les permissions SMB (niveau partage) ---
    # Groupe RW : ChangeAccess (Read + Write au niveau partage, NTFS gere le detail)
    if ($Share.RWGroup) {
        Grant-SmbShareAccess -Name $Share.Name -AccountName $Share.RWGroup -AccessRight Change -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  [+]   SMB Change : $($Share.RWGroup)" -ForegroundColor DarkGreen
    }
    # Groupe RO : ReadAccess
    if ($Share.ROGroup) {
        Grant-SmbShareAccess -Name $Share.Name -AccountName $Share.ROGroup -AccessRight Read -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  [+]   SMB Read   : $($Share.ROGroup)" -ForegroundColor DarkGreen
    }
}

Write-Host ""

# ==============================================================================
# 4. CONFIGURATION DES PERMISSIONS NTFS
# ==============================================================================

Write-Host "[4/7] Configuration des permissions NTFS sur les partages..." -ForegroundColor Yellow

foreach ($Share in $Shares) {
    Write-Host "  [*] Configuration NTFS : $($Share.Name)" -ForegroundColor DarkYellow

    # Recuperer l ACL actuelle
    $Acl = Get-Acl -Path $Share.Path

    # Desactiver l heritage et copier les regles existantes
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
    if ($Share.RWGroup) {
        $RWRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Share.RWGroup, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $Acl.AddAccessRule($RWRule)
        Write-Host "  [+]   NTFS Modify : $($Share.RWGroup)" -ForegroundColor DarkGreen
    }

    # --- Groupe RO : Lecture ---
    if ($Share.ROGroup) {
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

# --- Creer des sous-dossiers representatifs dans chaque partage ---
Write-Host ""
Write-Host "  [*] Creation de l arborescence de documents..." -ForegroundColor DarkYellow

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
    Write-Host "  [+] Arborescence creee pour $ShareName ($($SubFolders[$ShareName].Count) dossiers)" -ForegroundColor Green
}

Write-Host ""

# ==============================================================================
# 5. INSTALLATION DES PREREQUIS APPLICATIFS (IIS + .NET)
# ==============================================================================

Write-Host "[5/7] Installation des prerequis applicatifs (IIS + .NET)..." -ForegroundColor Yellow

# --- 5.1 Installation IIS ---
$IISFeatures = @(
    "Web-Server",                   # IIS Web Server
    "Web-WebServer",                # Services Web
    "Web-Common-Http",              # Fonctionnalites HTTP communes
    "Web-Default-Doc",              # Document par defaut
    "Web-Static-Content",           # Contenu statique
    "Web-Http-Errors",              # Erreurs HTTP
    "Web-Asp-Net45",                # ASP.NET 4.5+
    "Web-Net-Ext45",                # Extensibilite .NET 4.5+
    "Web-ISAPI-Ext",                # Extensions ISAPI
    "Web-ISAPI-Filter",             # Filtres ISAPI
    "Web-Mgmt-Console",             # Console de gestion IIS
    "Web-Mgmt-Tools"                # Outils de gestion
)

foreach ($Feature in $IISFeatures) {
    $Installed = Get-WindowsFeature -Name $Feature
    if (-not $Installed.Installed) {
        Install-WindowsFeature -Name $Feature -IncludeManagementTools -ErrorAction SilentlyContinue
        Write-Host "  [+] IIS Feature : $Feature" -ForegroundColor Green
    } else {
        Write-Host "  [=] IIS Feature deja presente : $Feature" -ForegroundColor DarkGray
    }
}

# --- 5.2 Installation .NET Framework ---
$DotNetFeatures = @(
    "NET-Framework-45-Core",        # .NET Framework 4.5
    "NET-Framework-45-Features",    # Fonctionnalites .NET 4.5
    "NET-WCF-Services45",           # Services WCF
    "NET-WCF-HTTP-Activation45",    # Activation HTTP WCF
    "NET-WCF-TCP-PortSharing45"     # Partage de port TCP WCF
)

foreach ($Feature in $DotNetFeatures) {
    $Installed = Get-WindowsFeature -Name $Feature
    if ($Installed -and -not $Installed.Installed) {
        Install-WindowsFeature -Name $Feature -ErrorAction SilentlyContinue
        Write-Host "  [+] .NET Feature : $Feature" -ForegroundColor Green
    } else {
        Write-Host "  [=] .NET Feature deja presente : $Feature" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ==============================================================================
# 6. INSTALLATION SQL SERVER EXPRESS
# ==============================================================================

Write-Host "[6/7] Installation de SQL Server Express..." -ForegroundColor Yellow

# --- 6.1 Preparer le repertoire de donnees ---
if (-not (Test-Path $SQLDataDir)) {
    New-Item -Path $SQLDataDir -ItemType Directory -Force | Out-Null
    Write-Host "  [+] Repertoire SQL Data cree : $SQLDataDir" -ForegroundColor Green
}

# --- 6.2 Telecharger SQL Server Express 2016 ---
$SQLInstallerDir = "C:\SQLInstall"
$SQLInstallerPath = "$SQLInstallerDir\SQLEXPR_x64.exe"

if (-not (Test-Path $SQLInstallerDir)) {
    New-Item -Path $SQLInstallerDir -ItemType Directory -Force | Out-Null
}

# Verifier si SQL Server est deja installe
$SQLInstalled = Get-Service -Name "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue
if (-not $SQLInstalled) {

    # URL de telechargement SQL Server Express 2016 SP3
    $SQLURL = "https://download.microsoft.com/download/E/F/2/EF23C21D-7860-4F05-88CE-39AA114B014B/SQLEXPR_x64_ENU.exe"

    Write-Host "  [*] Telechargement de SQL Server Express 2016..." -ForegroundColor DarkYellow
    try {
        # Tenter le telechargement (peut echouer selon la connectivite)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $SQLURL -OutFile $SQLInstallerPath -UseBasicParsing -ErrorAction Stop
        Write-Host "  [+] SQL Server Express telecharge" -ForegroundColor Green

        # --- 6.3 Installation silencieuse ---
        Write-Host "  [*] Installation de SQL Server Express (installation silencieuse)..." -ForegroundColor DarkYellow

        $SQLArgs = @(
            "/Q",                                          # Mode silencieux
            "/ACTION=Install",
            "/FEATURES=SQLENGINE",                         # Moteur SQL uniquement
            "/INSTANCENAME=SQLEXPRESS",
            "/SQLSVCACCOUNT=`"$SvcSqlUser`"",
            "/SQLSVCPASSWORD=`"Svc_Blue2025!`"",
            "/SQLSYSADMINACCOUNTS=`"BUILTIN\Administrateurs`"",
            "/SQLUSERDBDIR=`"$SQLDataDir`"",
            "/SQLUSERDBLOGDIR=`"$SQLDataDir\Logs`"",
            "/TCPENABLED=1",                               # Activer TCP/IP
            "/NPENABLED=1",                                # Activer Named Pipes
            "/SECURITYMODE=SQL",                           # Mode mixte (SQL + Windows)
            "/SAPWD=`"BlueMES_SQL2025!`"",                 # Mot de passe SA
            "/IACCEPTSQLSERVERLICENSETERMS",
            "/UPDATEENABLED=False"
        )

        Start-Process -FilePath $SQLInstallerPath -ArgumentList $SQLArgs -Wait -NoNewWindow
        Write-Host "  [+] SQL Server Express installe (Instance: SQLEXPRESS)" -ForegroundColor Green
    } catch {
        Write-Host "  [!] Telechargement SQL Server echoue : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  [!] Installer manuellement SQL Server Express 2016 SP3" -ForegroundColor Red
        Write-Host "  [!] Configurer l instance SQLEXPRESS avec le compte $SvcSqlUser" -ForegroundColor Red
    }
} else {
    Write-Host "  [=] SQL Server Express deja installe" -ForegroundColor DarkGray
}

Write-Host ""

# ==============================================================================
# 7. DEPLOIEMENT APPLICATION MES FACTICE
# ==============================================================================

Write-Host "[7/7] Deploiement de l application MES factice..." -ForegroundColor Yellow

# --- 7.1 Creer la structure applicative ---
$MESRoot = "$AppRoot\MES"
$MESWebRoot = "$MESRoot\WebApp"
$MESDataRoot = "$MESRoot\Data"
$MESLogsRoot = "$MESRoot\Logs"

$MESFolders = @($MESRoot, $MESWebRoot, $MESDataRoot, $MESLogsRoot)
foreach ($Folder in $MESFolders) {
    if (-not (Test-Path $Folder)) {
        New-Item -Path $Folder -ItemType Directory -Force | Out-Null
    }
}
Write-Host "  [+] Structure MES creee : $MESRoot" -ForegroundColor Green

# --- 7.2 Creer la base de donnees MES dans SQL Express ---
$SQLInstance = "$ServerName\SQLEXPRESS"
$SQLCheck = Get-Service -Name "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue
if ($SQLCheck -and $SQLCheck.Status -eq "Running") {
    try {
        # Creer la base MES_Production
        $CreateDBQuery = @"
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'MES_Production')
BEGIN
    CREATE DATABASE [MES_Production]
    ON PRIMARY (
        NAME = N'MES_Production',
        FILENAME = N'$SQLDataDir\MES_Production.mdf',
        SIZE = 100MB,
        FILEGROWTH = 50MB
    )
    LOG ON (
        NAME = N'MES_Production_log',
        FILENAME = N'$SQLDataDir\Logs\MES_Production_log.ldf',
        SIZE = 50MB,
        FILEGROWTH = 25MB
    )
END
"@
        Invoke-Sqlcmd -ServerInstance $SQLInstance -Query $CreateDBQuery -ErrorAction Stop
        Write-Host "  [+] Base de donnees MES_Production creee" -ForegroundColor Green

        # Creer les tables MES de base
        $CreateTablesQuery = @"
USE [MES_Production]

-- Table des ordres de fabrication
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'OrdresFabrication')
CREATE TABLE OrdresFabrication (
    ID              INT IDENTITY(1,1) PRIMARY KEY,
    NumeroOF        NVARCHAR(20) NOT NULL,
    Produit         NVARCHAR(100) NOT NULL,
    QuantitePrevue  DECIMAL(10,2),
    QuantiteRealisee DECIMAL(10,2) DEFAULT 0,
    Unite           NVARCHAR(10) DEFAULT 'kg',
    DateDebut       DATETIME,
    DateFin         DATETIME,
    Statut          NVARCHAR(20) DEFAULT 'Planifie',
    Ligne           NVARCHAR(50),
    Equipe          NVARCHAR(10),
    Operateur       NVARCHAR(50),
    DateCreation    DATETIME DEFAULT GETDATE()
)

-- Table des lots de production
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Lots')
CREATE TABLE Lots (
    ID              INT IDENTITY(1,1) PRIMARY KEY,
    NumeroLot       NVARCHAR(20) NOT NULL,
    OrdreID         INT FOREIGN KEY REFERENCES OrdresFabrication(ID),
    MatieresPremiere NVARCHAR(MAX),
    DateFabrication DATETIME DEFAULT GETDATE(),
    DatePeremption  DATETIME,
    Statut          NVARCHAR(20) DEFAULT 'EnCours',
    Commentaire     NVARCHAR(MAX)
)

-- Table des mesures process (lien avec SCADA/Historian)
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'MesuresProcess')
CREATE TABLE MesuresProcess (
    ID              INT IDENTITY(1,1) PRIMARY KEY,
    TagName         NVARCHAR(50) NOT NULL,
    Valeur          DECIMAL(18,4),
    Unite           NVARCHAR(10),
    Timestamp       DATETIME DEFAULT GETDATE(),
    Qualite         NVARCHAR(10) DEFAULT 'Good',
    Source          NVARCHAR(50) DEFAULT 'SCADA'
)

-- Table des KPI production
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'KPI_Production')
CREATE TABLE KPI_Production (
    ID              INT IDENTITY(1,1) PRIMARY KEY,
    DateCalcul      DATETIME DEFAULT GETDATE(),
    Ligne           NVARCHAR(50),
    TRS             DECIMAL(5,2),
    TauxQualite     DECIMAL(5,2),
    TauxDisponibilite DECIMAL(5,2),
    TauxPerformance DECIMAL(5,2),
    Periode         NVARCHAR(20)
)

-- Table des evenements production
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Evenements')
CREATE TABLE Evenements (
    ID              INT IDENTITY(1,1) PRIMARY KEY,
    Type            NVARCHAR(30) NOT NULL,
    Severite        NVARCHAR(10) DEFAULT 'Info',
    Description     NVARCHAR(MAX),
    Ligne           NVARCHAR(50),
    Operateur       NVARCHAR(50),
    DateEvenement   DATETIME DEFAULT GETDATE(),
    DateResolution  DATETIME,
    Statut          NVARCHAR(20) DEFAULT 'Ouvert'
)
"@
        Invoke-Sqlcmd -ServerInstance $SQLInstance -Query $CreateTablesQuery -ErrorAction Stop
        Write-Host "  [+] Tables MES creees (OF, Lots, Mesures, KPI, Evenements)" -ForegroundColor Green

        # Inserer des donnees de demonstration
        $InsertDataQuery = @"
USE [MES_Production]

-- Ordres de fabrication exemples
INSERT INTO OrdresFabrication (NumeroOF, Produit, QuantitePrevue, QuantiteRealisee, Ligne, Equipe, Statut, DateDebut)
VALUES
('OF-2025-001', 'Acide Chlorhydrique 33%', 5000.00, 4850.00, 'Ligne Reaction 1', 'A', 'Termine', DATEADD(day, -5, GETDATE())),
('OF-2025-002', 'Soude Caustique 50%', 3000.00, 2100.00, 'Ligne Reaction 2', 'B', 'EnCours', DATEADD(day, -1, GETDATE())),
('OF-2025-003', 'Solvant A-401', 1500.00, 0, 'Ligne Distillation', 'C', 'Planifie', DATEADD(day, 2, GETDATE())),
('OF-2025-004', 'Resine Epoxy RE-100', 2000.00, 0, 'Ligne Reaction 1', 'A', 'Planifie', DATEADD(day, 4, GETDATE()))

-- KPI exemples
INSERT INTO KPI_Production (Ligne, TRS, TauxQualite, TauxDisponibilite, TauxPerformance, Periode)
VALUES
('Ligne Reaction 1', 78.50, 98.20, 85.00, 94.10, 'Semaine'),
('Ligne Reaction 2', 72.30, 97.50, 80.00, 92.60, 'Semaine'),
('Ligne Distillation', 81.00, 99.10, 88.00, 93.00, 'Semaine')

-- Evenements exemples
INSERT INTO Evenements (Type, Severite, Description, Ligne, Operateur, Statut)
VALUES
('Arret', 'Warning', 'Arret pour nettoyage reacteur R-101', 'Ligne Reaction 1', 'm.lefebvre', 'Resolu'),
('Alarme', 'Critical', 'Depassement temperature T-201 (>95C)', 'Ligne Reaction 2', 's.garcia', 'Ouvert'),
('Maintenance', 'Info', 'Remplacement joint pompe P-301', 'Ligne Distillation', 'p.dubois', 'Resolu')
"@
        Invoke-Sqlcmd -ServerInstance $SQLInstance -Query $InsertDataQuery -ErrorAction Stop
        Write-Host "  [+] Donnees de demonstration MES inserees" -ForegroundColor Green

        # Creer un login SQL pour le compte de service MES
        $CreateLoginQuery = @"
IF NOT EXISTS (SELECT name FROM sys.server_principals WHERE name = '$SvcMesUser')
BEGIN
    CREATE LOGIN [$SvcMesUser] FROM WINDOWS
END

USE [MES_Production]
IF NOT EXISTS (SELECT name FROM sys.database_principals WHERE name = '$SvcMesUser')
BEGIN
    CREATE USER [$SvcMesUser] FOR LOGIN [$SvcMesUser]
    ALTER ROLE db_datareader ADD MEMBER [$SvcMesUser]
    ALTER ROLE db_datawriter ADD MEMBER [$SvcMesUser]
END
"@
        Invoke-Sqlcmd -ServerInstance $SQLInstance -Query $CreateLoginQuery -ErrorAction Stop
        Write-Host "  [+] Login SQL cree pour $SvcMesUser (db_datareader + db_datawriter)" -ForegroundColor Green

    } catch {
        Write-Host "  [!] Erreur configuration SQL : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  [!] Les tables MES devront etre creees manuellement" -ForegroundColor Red
    }
} else {
    Write-Host "  [!] SQL Server Express non demarre - creation de la base MES reportee" -ForegroundColor Red
}

# --- 7.3 Deployer le site web MES dans IIS ---
Write-Host "  [*] Deploiement du site MES dans IIS..." -ForegroundColor DarkYellow

Import-Module WebAdministration -ErrorAction SilentlyContinue

# Creer la page d accueil MES factice
$MESIndexHTML = @"
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Blue Chemicals - MES Production</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #1a1a2e; color: #eee; }
        .header { background: #16213e; padding: 15px 30px; display: flex; align-items: center; justify-content: space-between; border-bottom: 3px solid #0f3460; }
        .header h1 { color: #00b4d8; font-size: 1.4em; }
        .header .info { color: #888; font-size: 0.85em; }
        .nav { background: #0f3460; padding: 10px 30px; }
        .nav a { color: #00b4d8; text-decoration: none; margin-right: 20px; font-size: 0.95em; }
        .nav a:hover { color: #fff; }
        .container { padding: 20px 30px; }
        .dashboard { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 20px; margin-bottom: 30px; }
        .card { background: #16213e; border-radius: 8px; padding: 20px; border: 1px solid #0f3460; }
        .card h3 { color: #00b4d8; margin-bottom: 15px; font-size: 1em; border-bottom: 1px solid #0f3460; padding-bottom: 8px; }
        .kpi { font-size: 2em; font-weight: bold; color: #0f0; }
        .kpi.warning { color: #ff0; }
        .kpi.critical { color: #f00; }
        .kpi-label { color: #888; font-size: 0.85em; margin-top: 5px; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { padding: 8px 12px; text-align: left; border-bottom: 1px solid #0f3460; font-size: 0.9em; }
        th { color: #00b4d8; background: #0f3460; }
        .status-ok { color: #0f0; }
        .status-run { color: #00b4d8; }
        .status-plan { color: #888; }
        .status-alarm { color: #f00; }
        .footer { text-align: center; padding: 15px; color: #555; font-size: 0.8em; border-top: 1px solid #0f3460; margin-top: 30px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>BLUE CHEMICALS - MES Production</h1>
        <div class="info">SRV-FILES01 | Serveur : MES_Production | ISA-95 Niveau 3</div>
    </div>
    <div class="nav">
        <a href="#">Tableau de bord</a>
        <a href="#">Ordres de fabrication</a>
        <a href="#">Suivi des lots</a>
        <a href="#">KPI Production</a>
        <a href="#">Evenements</a>
    </div>
    <div class="container">
        <div class="dashboard">
            <div class="card">
                <h3>TRS - Ligne Reaction 1</h3>
                <div class="kpi">78.5%</div>
                <div class="kpi-label">Taux de Rendement Synthetique</div>
            </div>
            <div class="card">
                <h3>TRS - Ligne Reaction 2</h3>
                <div class="kpi warning">72.3%</div>
                <div class="kpi-label">Taux de Rendement Synthetique</div>
            </div>
            <div class="card">
                <h3>TRS - Ligne Distillation</h3>
                <div class="kpi">81.0%</div>
                <div class="kpi-label">Taux de Rendement Synthetique</div>
            </div>
            <div class="card">
                <h3>Alarmes actives</h3>
                <div class="kpi critical">1</div>
                <div class="kpi-label">Depassement temperature T-201</div>
            </div>
        </div>

        <div class="card">
            <h3>Ordres de fabrication</h3>
            <table>
                <tr><th>N OF</th><th>Produit</th><th>Quantite</th><th>Ligne</th><th>Equipe</th><th>Statut</th></tr>
                <tr><td>OF-2025-001</td><td>Acide Chlorhydrique 33%</td><td>4850 / 5000 kg</td><td>Reaction 1</td><td>A</td><td class="status-ok">Termine</td></tr>
                <tr><td>OF-2025-002</td><td>Soude Caustique 50%</td><td>2100 / 3000 kg</td><td>Reaction 2</td><td>B</td><td class="status-run">En cours</td></tr>
                <tr><td>OF-2025-003</td><td>Solvant A-401</td><td>0 / 1500 kg</td><td>Distillation</td><td>C</td><td class="status-plan">Planifie</td></tr>
                <tr><td>OF-2025-004</td><td>Resine Epoxy RE-100</td><td>0 / 2000 kg</td><td>Reaction 1</td><td>A</td><td class="status-plan">Planifie</td></tr>
            </table>
        </div>
    </div>
    <div class="footer">
        Blue Chemicals - Systeme MES | Environnement de test BlueLock | ISA-95 Niveau 3 | Acces reserve au personnel autorise
    </div>
</body>
</html>
"@

# Ecrire le fichier HTML
$MESIndexHTML | Out-File -FilePath "$MESWebRoot\index.html" -Encoding UTF8 -Force
Write-Host "  [+] Page MES creee : $MESWebRoot\index.html" -ForegroundColor Green

# --- Configurer le site IIS ---
try {
    # Supprimer le site par defaut si present
    $DefaultSite = Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
    if ($DefaultSite) {
        Stop-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
    }

    # Creer le pool d application MES
    $PoolName = "MES_AppPool"
    if (-not (Test-Path "IIS:\AppPools\$PoolName")) {
        New-WebAppPool -Name $PoolName | Out-Null
        Set-ItemProperty "IIS:\AppPools\$PoolName" -Name processModel.identityType -Value 3  # SpecificUser
        Set-ItemProperty "IIS:\AppPools\$PoolName" -Name processModel.userName -Value $SvcMesUser
        Set-ItemProperty "IIS:\AppPools\$PoolName" -Name processModel.password -Value "Svc_Blue2025!"
        Write-Host "  [+] Pool IIS cree : $PoolName (compte: $SvcMesUser)" -ForegroundColor Green
    }

    # Creer le site web MES
    $SiteName = "MES-Production"
    $ExistingSite = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
    if (-not $ExistingSite) {
        New-Website -Name $SiteName `
                    -PhysicalPath $MESWebRoot `
                    -Port 8080 `
                    -ApplicationPool $PoolName | Out-Null
        Write-Host "  [+] Site IIS cree : $SiteName (port 8080)" -ForegroundColor Green
    } else {
        Write-Host "  [=] Site IIS existant : $SiteName" -ForegroundColor DarkGray
    }

    # Demarrer le site
    Start-Website -Name $SiteName -ErrorAction SilentlyContinue
    Write-Host "  [+] Site MES demarre sur http://$ServerName`:8080" -ForegroundColor Green

} catch {
    Write-Host "  [!] Erreur configuration IIS : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  [!] Le site MES devra etre configure manuellement dans IIS" -ForegroundColor Red
}

Write-Host ""

# ==============================================================================
# REGLES PARE-FEU (ouverture des ports necessaires)
# ==============================================================================

Write-Host "[*] Configuration du pare-feu Windows..." -ForegroundColor Yellow

$FirewallRules = @(
    @{ Name = "SMB - Partages de fichiers";    Port = "445";  Protocol = "TCP" }
    @{ Name = "SQL Server Express";            Port = "1433"; Protocol = "TCP" }
    @{ Name = "MES Web Application (HTTP)";    Port = "8080"; Protocol = "TCP" }
    @{ Name = "NetBIOS Name Service";          Port = "137";  Protocol = "UDP" }
    @{ Name = "NetBIOS Session Service";       Port = "139";  Protocol = "TCP" }
)

foreach ($Rule in $FirewallRules) {
    $Existing = Get-NetFirewallRule -DisplayName $Rule.Name -ErrorAction SilentlyContinue
    if (-not $Existing) {
        New-NetFirewallRule -DisplayName $Rule.Name `
                           -Direction Inbound `
                           -Protocol $Rule.Protocol `
                           -LocalPort $Rule.Port `
                           -Action Allow `
                           -Profile Domain `
                           -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  [+] Regle pare-feu : $($Rule.Name) ($($Rule.Protocol)/$($Rule.Port))" -ForegroundColor Green
    } else {
        Write-Host "  [=] Regle existante : $($Rule.Name)" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ==============================================================================
# TESTS DE VALIDATION
# ==============================================================================

Write-Host "[*] Tests de validation..." -ForegroundColor Yellow

# Test 1 : Verification domaine
$DomainStatus = (Get-WmiObject Win32_ComputerSystem).Domain
if ($DomainStatus -eq $Domain) {
    Write-Host "  [OK] Membre du domaine $Domain" -ForegroundColor Green
} else {
    Write-Host "  [!!] Non membre du domaine (actuel: $DomainStatus)" -ForegroundColor Red
}

# Test 2 : Resolution DNS vers DC01
try {
    $DNSResult = Resolve-DnsName -Name "DC01.$Domain" -ErrorAction Stop
    Write-Host "  [OK] Resolution DNS DC01.$Domain -> $($DNSResult.IPAddress)" -ForegroundColor Green
} catch {
    Write-Host "  [!!] Resolution DNS DC01.$Domain echouee" -ForegroundColor Red
}

# Test 3 : Partages SMB
$ShareCount = (Get-SmbShare | Where-Object { $_.Path -like "$ShareRoot*" }).Count
Write-Host "  [OK] Partages SMB actifs : $ShareCount / $($Shares.Count)" -ForegroundColor $(if ($ShareCount -eq $Shares.Count) { "Green" } else { "Yellow" })

# Test 4 : Services
$Services = @(
    @{ Name = "W3SVC";          Display = "IIS (World Wide Web)" }
    @{ Name = "MSSQL`$SQLEXPRESS"; Display = "SQL Server Express" }
)
foreach ($Svc in $Services) {
    $SvcStatus = Get-Service -Name $Svc.Name -ErrorAction SilentlyContinue
    if ($SvcStatus -and $SvcStatus.Status -eq "Running") {
        Write-Host "  [OK] Service $($Svc.Display) : Running" -ForegroundColor Green
    } else {
        Write-Host "  [!!] Service $($Svc.Display) : $(if ($SvcStatus) { $SvcStatus.Status } else { 'Non installe' })" -ForegroundColor Red
    }
}

# Test 5 : Site MES accessible
try {
    $WebTest = Invoke-WebRequest -Uri "http://localhost:8080" -UseBasicParsing -ErrorAction Stop
    if ($WebTest.StatusCode -eq 200) {
        Write-Host "  [OK] Site MES accessible sur http://localhost:8080" -ForegroundColor Green
    }
} catch {
    Write-Host "  [!!] Site MES non accessible sur le port 8080" -ForegroundColor Red
}

Write-Host ""

# ==============================================================================
# RESUME
# ==============================================================================

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DEPLOIEMENT SRV-FILES-APP TERMINE"                          -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Serveur         : $ServerName" -ForegroundColor White
Write-Host "  Domaine         : $Domain" -ForegroundColor White
Write-Host "  OS              : Windows Server 2016" -ForegroundColor White
Write-Host ""
Write-Host "  --- Partages reseau ---" -ForegroundColor Cyan
foreach ($Share in $Shares) {
    Write-Host "  \\$ServerName\$($Share.Name)" -ForegroundColor White
}
Write-Host ""
Write-Host "  --- Services installes ---" -ForegroundColor Cyan
Write-Host "  File Server     : SMB avec permissions AD (AGDLP)" -ForegroundColor White
Write-Host "  IIS             : Web Server (port 80)" -ForegroundColor White
Write-Host "  .NET Framework  : 4.5+" -ForegroundColor White
Write-Host "  SQL Express     : Instance SQLEXPRESS (port 1433)" -ForegroundColor White
Write-Host "  MES Production  : http://$ServerName`:8080" -ForegroundColor White
Write-Host ""
Write-Host "  --- Comptes de service utilises ---" -ForegroundColor Cyan
Write-Host "  SQL Server      : $SvcSqlUser" -ForegroundColor White
Write-Host "  MES AppPool     : $SvcMesUser" -ForegroundColor White
Write-Host ""
Write-Host "  --- Base de donnees ---" -ForegroundColor Cyan
Write-Host "  Instance        : $ServerName\SQLEXPRESS" -ForegroundColor White
Write-Host "  Base MES        : MES_Production" -ForegroundColor White
Write-Host "  SA Password     : BlueMES_SQL2025!" -ForegroundColor Yellow
Write-Host ""
Write-Host "  /!\ La partie ERP/GMAO n est PAS deployee par ce script." -ForegroundColor Yellow
Write-Host "  /!\ Cet environnement est volontairement NON SECURISE." -ForegroundColor Red
Write-Host "  /!\ Il represente un etat initial avant demarche de securisation." -ForegroundColor Red
Write-Host ""

if ($NeedReboot) {
    Write-Host "  *** REDEMARRAGE NECESSAIRE pour finaliser la jonction au domaine ***" -ForegroundColor Yellow
    Write-Host "  Relancer ce script apres le redemarrage pour completer l installation." -ForegroundColor Yellow
    Write-Host ""
    $Reboot = Read-Host "  Redemarrer maintenant ? (O/N)"
    if ($Reboot -eq "O" -or $Reboot -eq "o") {
        Restart-Computer -Force
    }
}
