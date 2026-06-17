<#
.SYNOPSIS
    Implementation d'un modele Tiering Active Directory avec detection automatique du domaine.

.DESCRIPTION
    - Detecte automatiquement le domaine AD avec Get-ADDomain.
    - Met a jour les CSV d'entree avec le domaine detecte si -UpdateInputCsv est utilise.
    - Cree les OU Admins, Groups, Servers puis T0/T1/T2.
    - Cree uniquement des comptes admin avec nomenclature admt0..., admt1..., admt2...
    - Genere les mots de passe dans le script et les exporte en CSV.
    - Cree les groupes admin GG_T0_Admins, GG_T1_Admins, GG_T2_Admins.
    - Deplace les objets ordinateurs serveurs dans les OU Servers/T0, Servers/T1, Servers/T2 si -MoveServersToOUs est utilise.
    - Configure des GPO par tier pour ajouter le groupe admin du tier dans le groupe Administrators local si -ConfigureGpoLocalAdminRights est utilise.
    - Aucun envoi mail.

.EXEMPLES
    .\Implement-TieringModelAD.ps1 -WhatIf
    .\Implement-TieringModelAD.ps1 -UpdateInputCsv
    .\Implement-TieringModelAD.ps1 -MoveServersToOUs -ConfigureGpoLocalAdminRights
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$AccountsCsv = ".\Comptes_Admin_Tiering.csv",
    [string]$ServersCsv = ".\Serveurs_Tiering.csv",
    [string]$OutputFolder = ".\exports",

    [string]$AdminRootOuName = "Admins",
    [string]$GroupRootOuName = "Groups",
    [string]$ServerRootOuName = "Servers",

    [int]$PasswordLength = 20,
    [int]$AdminPasswordExpirationDays = 180,

    [switch]$UpdateInputCsv,
    [switch]$MoveServersToOUs,
    [switch]$ConfigureGpoLocalAdminRights
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Cyan
}

function Ensure-Module {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Module PowerShell manquant: $Name"
    }

    Import-Module $Name -ErrorAction Stop
}

function Get-CsvValue {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Row.PSObject.Properties.Name -contains $name) {
            $value = $Row.PSObject.Properties[$name].Value
            if ($null -eq $value) { return "" }
            return ([string]$value).Trim()
        }
    }

    return ""
}

function Set-CsvValue {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Value
    )

    if ($Row.PSObject.Properties.Name -contains $Name) {
        $Row.$Name = $Value
    }
    else {
        $Row | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Remove-TextAccent {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder

    foreach ($char in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }

    return $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function ConvertTo-SafeName {
    param([AllowNull()][string]$Value)

    $valueNoAccent = Remove-TextAccent -Text $Value
    $safe = $valueNoAccent.ToUpper() -replace "[^A-Z0-9]", "_"
    $safe = $safe -replace "_+", "_"
    $safe = $safe.Trim("_")

    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "UNKNOWN"
    }

    return $safe
}

function ConvertTo-SafeBaseSam {
    param([AllowNull()][string]$Value)

    $valueNoAccent = Remove-TextAccent -Text $Value
    $safe = $valueNoAccent.ToLower() -replace "[^a-z0-9]", ""

    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "unknown"
    }

    return $safe
}

function New-AdminSamAccountName {
    param(
        [Parameter(Mandatory = $true)][string]$Tier,
        [AllowNull()][string]$RawSam,
        [AllowNull()][string]$Nom,
        [AllowNull()][string]$Prenom
    )

    $tierLower = $Tier.ToLower()
    $prefix = "adm$tierLower"

    if (-not [string]::IsNullOrWhiteSpace($RawSam)) {
        $cleanRaw = ConvertTo-SafeBaseSam -Value $RawSam
        $cleanRaw = $cleanRaw -replace "^adm", ""
        $cleanRaw = $cleanRaw -replace "^t[012]", ""
        $base = $cleanRaw
    }
    else {
        $firstLetter = "x"
        if (-not [string]::IsNullOrWhiteSpace($Prenom)) {
            $firstLetter = $Prenom.Substring(0, [Math]::Min(1, $Prenom.Length))
        }
        $base = ConvertTo-SafeBaseSam -Value "$firstLetter$Nom"
    }

    $sam = "$prefix$base"

    if ($sam.Length -gt 20) {
        $sam = $sam.Substring(0, 20)
    }

    return $sam
}

function Resolve-DomainInfo {
    $domain = Get-ADDomain -ErrorAction Stop

    return [pscustomobject]@{
        DnsRoot = $domain.DNSRoot
        DistinguishedName = $domain.DistinguishedName
        NetBIOSName = $domain.NetBIOSName
        AdminRootOU = "OU=$AdminRootOuName,$($domain.DistinguishedName)"
        GroupRootOU = "OU=$GroupRootOuName,$($domain.DistinguishedName)"
        ServerRootOU = "OU=$ServerRootOuName,$($domain.DistinguishedName)"
    }
}

function Normalize-DistinguishedNameDomain {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][string]$DomainDN
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $clean = $Value.Trim()

    if ($clean -match "DC=") {
        $clean = $clean -replace "DC=[^,]+(,DC=[^,]+)*$", $DomainDN
    }

    return $clean
}

function Ensure-OU {
    param([Parameter(Mandatory = $true)][string]$DistinguishedName)

    try {
        Get-ADOrganizationalUnit -Identity $DistinguishedName -ErrorAction Stop | Out-Null
        return
    }
    catch {
        # OU missing, creation below
    }

    $parts = $DistinguishedName -split ","
    $dcParts = $parts | Where-Object { $_ -like "DC=*" }
    $ouParts = $parts | Where-Object { $_ -like "OU=*" }

    [array]::Reverse($ouParts)
    $parent = ($dcParts -join ",")

    foreach ($ouPart in $ouParts) {
        $ouName = $ouPart -replace "^OU=", ""
        $currentDn = "OU=$ouName,$parent"

        try {
            Get-ADOrganizationalUnit -Identity $currentDn -ErrorAction Stop | Out-Null
        }
        catch {
            if ($PSCmdlet.ShouldProcess($currentDn, "Create OU")) {
                New-ADOrganizationalUnit `
                    -Name $ouName `
                    -Path $parent `
                    -ProtectedFromAccidentalDeletion $false `
                    -ErrorAction Stop | Out-Null
            }
        }

        $parent = $currentDn
    }
}

function Ensure-ADGroup {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Description = ""
    )

    Ensure-OU -DistinguishedName $Path

    $existingGroup = Get-ADGroup -LDAPFilter "(sAMAccountName=$Name)" -ErrorAction SilentlyContinue
    if ($existingGroup) {
        return $existingGroup
    }

    if ($PSCmdlet.ShouldProcess($Name, "Create AD group")) {
        New-ADGroup `
            -Name $Name `
            -SamAccountName $Name `
            -GroupCategory Security `
            -GroupScope Global `
            -Path $Path `
            -Description $Description `
            -ErrorAction Stop | Out-Null
    }

    return Get-ADGroup -LDAPFilter "(sAMAccountName=$Name)"
}

function New-RandomPassword {
    param([int]$Length = 20)

    if ($Length -lt 14) {
        $Length = 14
    }

    $lower = "abcdefghjkmnpqrstuvwxyz"
    $upper = "ABCDEFGHJKMNPQRSTUVWXYZ"
    $digits = "23456789"
    $allChars = ($lower + $upper + $digits).ToCharArray()

    $chars = New-Object System.Collections.Generic.List[char]
    $chars.Add($lower[(Get-Random -Maximum $lower.Length)])
    $chars.Add($upper[(Get-Random -Maximum $upper.Length)])
    $chars.Add($digits[(Get-Random -Maximum $digits.Length)])

    while ($chars.Count -lt $Length) {
        $chars.Add($allChars[(Get-Random -Maximum $allChars.Length)])
    }

    return (-join ($chars | Sort-Object { Get-Random }))
}

function Ensure-AdminPasswordPolicy {
    param(
        [string[]]$AdminGroupNames,
        [int]$ExpirationDays,
        [string]$PolicyName = "PSO_Admin_Tiering_180J"
    )

    $pso = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$PolicyName'" -ErrorAction SilentlyContinue

    if (-not $pso) {
        if ($PSCmdlet.ShouldProcess($PolicyName, "Create password policy")) {
            New-ADFineGrainedPasswordPolicy `
                -Name $PolicyName `
                -Precedence 10 `
                -ComplexityEnabled $true `
                -ReversibleEncryptionEnabled $false `
                -MinPasswordLength 14 `
                -PasswordHistoryCount 24 `
                -MaxPasswordAge (New-TimeSpan -Days $ExpirationDays) `
                -MinPasswordAge (New-TimeSpan -Days 1) `
                -LockoutThreshold 5 `
                -LockoutDuration (New-TimeSpan -Minutes 15) `
                -LockoutObservationWindow (New-TimeSpan -Minutes 15) `
                -ErrorAction Stop | Out-Null
        }
    }

    foreach ($groupName in $AdminGroupNames) {
        $group = Get-ADGroup -Identity $groupName -ErrorAction SilentlyContinue

        if ($group) {
            try {
                if ($PSCmdlet.ShouldProcess($groupName, "Apply password policy")) {
                    Add-ADFineGrainedPasswordPolicySubject `
                        -Identity $PolicyName `
                        -Subjects $groupName `
                        -ErrorAction Stop
                }
            }
            catch {
                if ($_.Exception.Message -notmatch "already|existe|deja") {
                    Write-Warning "Impossible appliquer la PSO sur $groupName : $($_.Exception.Message)"
                }
            }
        }
    }
}

function Update-InputCsvFiles {
    param(
        [Parameter(Mandatory = $true)][array]$Accounts,
        [Parameter(Mandatory = $true)][array]$Servers,
        [Parameter(Mandatory = $true)][string]$AccountsPath,
        [Parameter(Mandatory = $true)][string]$ServersPath,
        [Parameter(Mandatory = $true)]$DomainInfo
    )

    $backupSuffix = ".bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    Copy-Item -Path $AccountsPath -Destination "$AccountsPath$backupSuffix" -Force
    Copy-Item -Path $ServersPath -Destination "$ServersPath$backupSuffix" -Force

    foreach ($account in $Accounts) {
        $nom = Get-CsvValue -Row $account -Names @("Nom", "NOM")
        $prenom = Get-CsvValue -Row $account -Names @("Prenom", "FirstName")
        $rawSam = Get-CsvValue -Row $account -Names @("CompteAdmin", "sAMAccountName", "Login", "SamAccountName")
        $tier = (Get-CsvValue -Row $account -Names @("NiveauTiering", "Niveau Tiering", "Tier")).ToUpper()

        if ([string]::IsNullOrWhiteSpace($tier) -or $tier -notin @("T0", "T1", "T2")) {
            $tier = "T2"
        }

        $sam = New-AdminSamAccountName -Tier $tier -RawSam $rawSam -Nom $nom -Prenom $prenom
        $upn = "$sam@$($DomainInfo.DnsRoot)"
        $ou = "OU=$tier,$($DomainInfo.AdminRootOU)"

        Set-CsvValue -Row $account -Name "CompteAdmin" -Value $sam
        Set-CsvValue -Row $account -Name "UPN" -Value $upn
        Set-CsvValue -Row $account -Name "NiveauTiering" -Value $tier
        Set-CsvValue -Row $account -Name "OUCible" -Value $ou
    }

    foreach ($server in $Servers) {
        $tier = (Get-CsvValue -Row $server -Names @("NiveauTiering", "Niveau Tiering", "Tier")).ToUpper()

        if ([string]::IsNullOrWhiteSpace($tier) -or $tier -notin @("T0", "T1", "T2")) {
            $tier = "T2"
        }

        $serverOu = "OU=$tier,$($DomainInfo.ServerRootOU)"
        $tierAdminGroup = "GG_${tier}_Admins"

        Set-CsvValue -Row $server -Name "NiveauTiering" -Value $tier
        Set-CsvValue -Row $server -Name "OUCible" -Value $serverOu
        Set-CsvValue -Row $server -Name "GroupeAdminAutorise" -Value $tierAdminGroup
    }

    $Accounts | Export-Csv -Path $AccountsPath -Delimiter ";" -NoTypeInformation -Encoding UTF8
    $Servers | Export-Csv -Path $ServersPath -Delimiter ";" -NoTypeInformation -Encoding UTF8

    Write-Host "CSV mis a jour avec le domaine $($DomainInfo.DnsRoot). Backups crees avec suffixe $backupSuffix" -ForegroundColor Yellow
}

function Move-ServersToTierOUs {
    param(
        [Parameter(Mandatory = $true)][array]$Servers,
        [Parameter(Mandatory = $true)]$DomainInfo
    )

    foreach ($server in $Servers) {
        $serverName = Get-CsvValue -Row $server -Names @("NomServeur", "Nom serveur", "Serveur", "Server")
        $tier = (Get-CsvValue -Row $server -Names @("NiveauTiering", "Niveau Tiering", "Tier")).ToUpper()
        $serverOu = Get-CsvValue -Row $server -Names @("OUCible", "OU cible", "OU")

        if ([string]::IsNullOrWhiteSpace($serverName)) { continue }
        if ([string]::IsNullOrWhiteSpace($tier) -or $tier -notin @("T0", "T1", "T2")) { $tier = "T2" }
        if ([string]::IsNullOrWhiteSpace($serverOu)) { $serverOu = "OU=$tier,$($DomainInfo.ServerRootOU)" }
        $serverOu = Normalize-DistinguishedNameDomain -Value $serverOu -DomainDN $DomainInfo.DistinguishedName

        Ensure-OU -DistinguishedName $serverOu

        $computer = Get-ADComputer -Identity $serverName -ErrorAction SilentlyContinue
        if (-not $computer) {
            Write-Warning "Serveur introuvable dans AD, deplacement ignore: $serverName"
            continue
        }

        if ($computer.DistinguishedName -like "*$serverOu") {
            Write-Host "Serveur deja dans la bonne OU: $serverName" -ForegroundColor Yellow
            continue
        }

        if ($PSCmdlet.ShouldProcess($serverName, "Move computer object to $serverOu")) {
            Move-ADObject `
                -Identity $computer.DistinguishedName `
                -TargetPath $serverOu `
                -ErrorAction Stop
        }
    }
}

function Set-GpoLocalAdminRights {
    param(
        [Parameter(Mandatory = $true)]$DomainInfo
    )

    Ensure-Module -Name GroupPolicy

    foreach ($tier in @("T0", "T1", "T2")) {
        $gpoName = "GPO_Tiering_${tier}_Local_Admins"
        $targetOu = "OU=$tier,$($DomainInfo.ServerRootOU)"
        $tierAdminGroup = "GG_${tier}_Admins"
        $domainGroup = "$($DomainInfo.NetBIOSName)\$tierAdminGroup"

        Ensure-OU -DistinguishedName $targetOu

        $existingGpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
        if (-not $existingGpo) {
            if ($PSCmdlet.ShouldProcess($gpoName, "Create GPO")) {
                $existingGpo = New-GPO `
                    -Name $gpoName `
                    -Comment "Ajoute $domainGroup dans le groupe Administrators local des serveurs $tier" `
                    -ErrorAction Stop
            }
        }
        else {
            $existingGpo = Get-GPO -Name $gpoName -ErrorAction Stop
        }

        try {
            if ($PSCmdlet.ShouldProcess($targetOu, "Link GPO $gpoName")) {
                New-GPLink `
                    -Name $gpoName `
                    -Target $targetOu `
                    -LinkEnabled Yes `
                    -ErrorAction Stop | Out-Null
            }
        }
        catch {
            if ($_.Exception.Message -notmatch "already|existe|deja") {
                Write-Warning "Lien GPO non cree sur $targetOu : $($_.Exception.Message)"
            }
        }

        # Script de demarrage ordinateur: ajoute le groupe du tier dans le groupe Administrators local.
        # Utilisation du SID S-1-5-32-544 pour fonctionner sur OS FR/EN.
        $scriptsFolder = "\\$($DomainInfo.DnsRoot)\SYSVOL\$($DomainInfo.DnsRoot)\Policies\{$($existingGpo.Id)}\Machine\Scripts\Startup"
        if ($PSCmdlet.ShouldProcess($scriptsFolder, "Create startup script for local admin rights")) {
            New-Item -ItemType Directory -Path $scriptsFolder -Force | Out-Null

            $cmdName = "Add-TieringLocalAdmin-$tier.cmd"
            $cmdPath = Join-Path $scriptsFolder $cmdName
            $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ""`$g=([System.Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]; net localgroup `"`$g`" `"$domainGroup`" /add"""
            Set-Content -Path $cmdPath -Value $command -Encoding ASCII

            $scriptsIni = Join-Path $scriptsFolder "scripts.ini"
            $iniContent = @(
                "[Startup]",
                "0CmdLine=$cmdName",
                "0Parameters="
            )
            Set-Content -Path $scriptsIni -Value $iniContent -Encoding ASCII
        }

        # Valeur registre simple pour forcer une modification cote computer du GPO.
        if ($PSCmdlet.ShouldProcess($gpoName, "Update GPO computer settings marker")) {
            Set-GPRegistryValue `
                -Name $gpoName `
                -Key "HKLM\Software\TieringModel" `
                -ValueName "Tier" `
                -Type String `
                -Value $tier `
                -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

Ensure-Module -Name ActiveDirectory

Write-Step "Detection du domaine AD"
$DomainInfo = Resolve-DomainInfo

Write-Host "Domaine detecte : $($DomainInfo.DnsRoot)" -ForegroundColor Green
Write-Host "DN domaine       : $($DomainInfo.DistinguishedName)" -ForegroundColor Green
Write-Host "OU admins        : $($DomainInfo.AdminRootOU)" -ForegroundColor Green
Write-Host "OU groupes       : $($DomainInfo.GroupRootOU)" -ForegroundColor Green
Write-Host "OU serveurs      : $($DomainInfo.ServerRootOU)" -ForegroundColor Green

if (-not (Test-Path $AccountsCsv)) { throw "Fichier introuvable: $AccountsCsv" }
if (-not (Test-Path $ServersCsv)) { throw "Fichier introuvable: $ServersCsv" }

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

Write-Step "Import des fichiers CSV"
$accounts = Import-Csv -Path $AccountsCsv -Delimiter ";"
$servers = Import-Csv -Path $ServersCsv -Delimiter ";"

if ($UpdateInputCsv) {
    Write-Step "Mise a jour des CSV avec le domaine detecte et la nomenclature admin"
    Update-InputCsvFiles `
        -Accounts $accounts `
        -Servers $servers `
        -AccountsPath $AccountsCsv `
        -ServersPath $ServersCsv `
        -DomainInfo $DomainInfo

    $accounts = Import-Csv -Path $AccountsCsv -Delimiter ";"
    $servers = Import-Csv -Path $ServersCsv -Delimiter ";"
}

Write-Step "Creation des OU principales"
Ensure-OU -DistinguishedName $DomainInfo.AdminRootOU
Ensure-OU -DistinguishedName $DomainInfo.GroupRootOU
Ensure-OU -DistinguishedName $DomainInfo.ServerRootOU

foreach ($tier in @("T0", "T1", "T2")) {
    Ensure-OU -DistinguishedName "OU=$tier,$($DomainInfo.AdminRootOU)"
    Ensure-OU -DistinguishedName "OU=$tier,$($DomainInfo.ServerRootOU)"
}

Write-Step "Creation des groupes admin par tier"
$adminTierGroupNames = @()

foreach ($tier in @("T0", "T1", "T2")) {
    $tierAdminGroup = "GG_${tier}_Admins"
    Ensure-ADGroup `
        -Name $tierAdminGroup `
        -Path $DomainInfo.GroupRootOU `
        -Description "Admin accounts for tier $tier" | Out-Null

    $adminTierGroupNames += $tierAdminGroup
}

Write-Step "Creation des groupes d'acces serveurs"
$serverAccessMatrix = @()

foreach ($server in $servers) {
    $serverName = Get-CsvValue -Row $server -Names @("NomServeur", "Nom serveur", "Serveur", "Server")
    $tier = (Get-CsvValue -Row $server -Names @("NiveauTiering", "Niveau Tiering", "Tier")).ToUpper()
    $serverRole = Get-CsvValue -Row $server -Names @("RoleServeur", "Role serveur", "Role")
    $serverOu = Get-CsvValue -Row $server -Names @("OUCible", "OU cible", "OU")

    if ([string]::IsNullOrWhiteSpace($serverName)) { continue }
    if ([string]::IsNullOrWhiteSpace($tier) -or $tier -notin @("T0", "T1", "T2")) { $tier = "T2" }
    if ([string]::IsNullOrWhiteSpace($serverOu)) { $serverOu = "OU=$tier,$($DomainInfo.ServerRootOU)" }
    $serverOu = Normalize-DistinguishedNameDomain -Value $serverOu -DomainDN $DomainInfo.DistinguishedName

    Ensure-OU -DistinguishedName $serverOu

    $safeServerName = ConvertTo-SafeName -Value $serverName
    $localAdminGroup = "GLA_${safeServerName}_Administrators"
    $tierAdminGroup = "GG_${tier}_Admins"

    Ensure-ADGroup `
        -Name $localAdminGroup `
        -Path $DomainInfo.GroupRootOU `
        -Description "Local admin access group for server $serverName" | Out-Null

    if ($PSCmdlet.ShouldProcess("$tierAdminGroup to $localAdminGroup", "Add group member")) {
        Add-ADGroupMember `
            -Identity $localAdminGroup `
            -Members $tierAdminGroup `
            -ErrorAction SilentlyContinue
    }

    $serverAccessMatrix += [pscustomobject]@{
        NomServeur = $serverName
        NiveauTiering = $tier
        RoleServeur = $serverRole
        OUCibleServeur = $serverOu
        GroupeLocalAdminAD = $localAdminGroup
        GroupeAdminAutorise = $tierAdminGroup
    }
}

if ($MoveServersToOUs) {
    Write-Step "Deplacement des serveurs dans les OU Servers/T0, Servers/T1, Servers/T2"
    Move-ServersToTierOUs -Servers $servers -DomainInfo $DomainInfo
}

Write-Step "Creation des comptes admin"
$generatedPasswords = @()

foreach ($account in $accounts) {
    $nom = Get-CsvValue -Row $account -Names @("Nom", "NOM")
    $prenom = Get-CsvValue -Row $account -Names @("Prenom", "FirstName")
    $rawSam = Get-CsvValue -Row $account -Names @("CompteAdmin", "sAMAccountName", "Login", "SamAccountName")
    $tier = (Get-CsvValue -Row $account -Names @("NiveauTiering", "Niveau Tiering", "Tier")).ToUpper()
    $equipe = Get-CsvValue -Row $account -Names @("Equipe", "Team")
    $service = Get-CsvValue -Row $account -Names @("Service")
    $fonction = Get-CsvValue -Row $account -Names @("Fonction", "Poste")
    $manager = Get-CsvValue -Row $account -Names @("Manager")

    if ([string]::IsNullOrWhiteSpace($tier) -or $tier -notin @("T0", "T1", "T2")) { $tier = "T2" }

    if ([string]::IsNullOrWhiteSpace($nom) -and [string]::IsNullOrWhiteSpace($prenom) -and [string]::IsNullOrWhiteSpace($rawSam)) {
        Write-Warning "Ligne ignoree: compte admin vide"
        continue
    }

    $sam = New-AdminSamAccountName -Tier $tier -RawSam $rawSam -Nom $nom -Prenom $prenom
    $upn = "$sam@$($DomainInfo.DnsRoot)"
    $displayName = "$prenom $nom".Trim()
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $sam }

    $targetOu = "OU=$tier,$($DomainInfo.AdminRootOU)"
    $groupName = "GG_${tier}_Admins"

    $plainPassword = New-RandomPassword -Length $PasswordLength
    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force

    $existingUser = Get-ADUser -LDAPFilter "(sAMAccountName=$sam)" -ErrorAction SilentlyContinue

    if (-not $existingUser) {
        if ($PSCmdlet.ShouldProcess($sam, "Create AD admin account")) {
            New-ADUser `
                -Name $displayName `
                -GivenName $prenom `
                -Surname $nom `
                -DisplayName $displayName `
                -SamAccountName $sam `
                -UserPrincipalName $upn `
                -EmailAddress $upn `
                -Path $targetOu `
                -AccountPassword $securePassword `
                -Enabled $true `
                -ChangePasswordAtLogon $false `
                -PasswordNeverExpires $false `
                -Description "Admin account tier $tier" `
                -ErrorAction Stop | Out-Null
        }
    }
    else {
        Write-Host "Compte existant: $sam" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($sam, "Update AD admin account")) {
            Set-ADUser `
                -Identity $sam `
                -DisplayName $displayName `
                -EmailAddress $upn `
                -UserPrincipalName $upn `
                -Description "Admin account tier $tier" `
                -ErrorAction Stop
        }
    }

    if ($PSCmdlet.ShouldProcess("$sam to $groupName", "Add admin account to tier group")) {
        Add-ADGroupMember `
            -Identity $groupName `
            -Members $sam `
            -ErrorAction SilentlyContinue
    }

    $generatedPasswords += [pscustomobject]@{
        CompteAdmin = $sam
        UPN = $upn
        Nom = $nom
        Prenom = $prenom
        DisplayName = $displayName
        Equipe = $equipe
        Service = $service
        Fonction = $fonction
        Manager = $manager
        NiveauTiering = $tier
        MotDePasseInitial = $plainPassword
        ExpirationMotDePasseJours = $AdminPasswordExpirationDays
    }
}

Write-Step "Application de la politique mot de passe admin"
Ensure-AdminPasswordPolicy -AdminGroupNames $adminTierGroupNames -ExpirationDays $AdminPasswordExpirationDays

if ($ConfigureGpoLocalAdminRights) {
    Write-Step "Configuration des droits administrateurs locaux via GPO"
    Set-GpoLocalAdminRights -DomainInfo $DomainInfo
}

Write-Step "Export des resultats"
$passwordFile = Join-Path $OutputFolder "MotsDePasse_Comptes_Admin.csv"
$matrixFile = Join-Path $OutputFolder "Matrice_Acces_Serveurs.csv"
$domainFile = Join-Path $OutputFolder "Domaine_Detecte.csv"

$generatedPasswords | Export-Csv -Path $passwordFile -Delimiter ";" -NoTypeInformation -Encoding UTF8
$serverAccessMatrix | Export-Csv -Path $matrixFile -Delimiter ";" -NoTypeInformation -Encoding UTF8
$DomainInfo | Export-Csv -Path $domainFile -Delimiter ";" -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Termine." -ForegroundColor Green
Write-Host "Domaine utilise: $($DomainInfo.DnsRoot)" -ForegroundColor Green
Write-Host "Dossier export: $OutputFolder" -ForegroundColor Green
Write-Host "Fichier mots de passe: $passwordFile" -ForegroundColor Yellow
Write-Host "Fichier matrice serveurs: $matrixFile" -ForegroundColor Yellow
Write-Host "Fichier domaine detecte: $domainFile" -ForegroundColor Yellow
Write-Host ""
Write-Host "Commandes utiles:" -ForegroundColor Yellow
Write-Host "gpupdate /force"
Write-Host "gpresult /r /scope computer"
