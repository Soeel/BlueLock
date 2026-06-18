#Requires -Version 5.1
<#
.SYNOPSIS
    TIER.Model - Moteur d'execution (test -> apply -> verify, rollback) et implementations
    des phases AD du Tiering (OU, groupes, comptes, PSO, groupes d'acces serveurs, deplacement).
.DESCRIPTION
    Meme modele que HAD.Hardening : le moteur appelle les fonctions de phase par leur nom.
    Les fonctions lisent le contexte partage (Get-TierContext) defini par l'orchestrateur.
#>

# Sorties collectees durant la session (exportees par l'orchestrateur).
$script:GeneratedPasswords = New-Object System.Collections.Generic.List[object]
$script:ServerAccessMatrix = New-Object System.Collections.Generic.List[object]

#region Helpers domaine / OU / groupes

function Resolve-TierDomainInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    Import-Module ActiveDirectory -ErrorAction Stop
    $d = Get-ADDomain -ErrorAction Stop
    $n = $Config.naming
    return @{
        DnsRoot           = $d.DNSRoot
        DistinguishedName = $d.DistinguishedName
        NetBIOSName       = $d.NetBIOSName
        DomainSID         = $d.DomainSID.Value
        AdminRootOU       = "OU=$($n.adminRootOu),$($d.DistinguishedName)"
        GroupRootOU       = "OU=$($n.groupRootOu),$($d.DistinguishedName)"
        ServerRootOU      = "OU=$($n.serverRootOu),$($d.DistinguishedName)"
    }
}

function Get-TierAdminGroupName {
    param([Parameter(Mandatory)][string]$Tier)
    $n = (Get-TierContext).Config.naming
    return "$($n.tierAdminGroupPrefix)$Tier$($n.tierAdminGroupSuffix)"
}

function Normalize-TierDN {
    param([AllowNull()][string]$Value, [Parameter(Mandatory)][string]$DomainDN)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $clean = $Value.Trim()
    if ($clean -match "DC=") { $clean = $clean -replace "DC=[^,]+(,DC=[^,]+)*$", $DomainDN }
    return $clean
}

function Test-TierOUExists {
    param([Parameter(Mandatory)][string]$DistinguishedName)
    try { Get-ADOrganizationalUnit -Identity $DistinguishedName -ErrorAction Stop | Out-Null; return $true }
    catch { return $false }
}

function Ensure-TierOU {
    param([Parameter(Mandatory)][string]$DistinguishedName, [bool]$Protect = $false)
    if (Test-TierOUExists $DistinguishedName) { return }

    $parts = $DistinguishedName -split ","
    $dcParts = $parts | Where-Object { $_ -like "DC=*" }
    $ouParts = $parts | Where-Object { $_ -like "OU=*" }
    [array]::Reverse($ouParts)
    $parent = ($dcParts -join ",")

    foreach ($ouPart in $ouParts) {
        $ouName = $ouPart -replace "^OU=", ""
        $currentDn = "OU=$ouName,$parent"
        if (-not (Test-TierOUExists $currentDn)) {
            New-ADOrganizationalUnit -Name $ouName -Path $parent `
                -ProtectedFromAccidentalDeletion $Protect -ErrorAction Stop | Out-Null
        }
        $parent = $currentDn
    }
}

function Ensure-TierGroup {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [string]$Description = ""
    )
    Ensure-TierOU -DistinguishedName $Path
    $existing = Get-ADGroup -LDAPFilter "(sAMAccountName=$Name)" -ErrorAction SilentlyContinue
    if ($existing) { return $existing }
    New-ADGroup -Name $Name -SamAccountName $Name -GroupCategory Security -GroupScope Global `
        -Path $Path -Description $Description -ErrorAction Stop | Out-Null
    return Get-ADGroup -LDAPFilter "(sAMAccountName=$Name)"
}

#endregion

#region Moteur

function Invoke-TieringTask {
    <# .SYNOPSIS Execute une phase : test -> apply (si besoin) -> verify. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][psobject]$Task, [switch]$DryRun)

    $result = [pscustomobject]@{
        TaskId = $Task.id; Name = $Task.name; Category = $Task.category
        Status = 'Unknown'; Message = $null
    }
    try {
        if (-not (Get-Command $Task.applyFunction -ErrorAction SilentlyContinue)) {
            $result.Status = 'Error'; $result.Message = "Fonction d'application introuvable : $($Task.applyFunction)"
            return $result
        }
        $hasTest = [bool](Get-Command $Task.testFunction -ErrorAction SilentlyContinue)
        if ($hasTest -and (& $Task.testFunction)) {
            $result.Status = 'AlreadyCompliant'; $result.Message = 'Deja en place, aucune action.'
            return $result
        }
        if ($DryRun) {
            $result.Status = 'WouldApply'; $result.Message = '[DryRun] La phase serait appliquee.'
            return $result
        }
        if ($PSCmdlet.ShouldProcess($Task.id, 'Apply tiering phase')) {
            & $Task.applyFunction
            $ok = if ($hasTest) { & $Task.testFunction } else { $true }
            $result.Status  = if ($ok) { 'Applied' } else { 'AppliedButNotVerified' }
            $result.Message = if ($ok) { 'Phase appliquee et verifiee.' } else { 'Appliquee mais verification negative (revue manuelle).' }
        }
        else { $result.Status = 'Skipped'; $result.Message = 'Annule par l operateur (ShouldProcess).' }
    }
    catch { $result.Status = 'Error'; $result.Message = $_.Exception.Message }
    return $result
}

function Invoke-TieringRollback {
    <# .SYNOPSIS Annule une phase via sa rollbackFunction (sauf si reversible=false). #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][psobject]$Task)

    $result = [pscustomobject]@{ TaskId = $Task.id; Name = $Task.name; Status = 'Unknown'; Message = $null }
    try {
        if ($Task.reversible -eq $false) {
            $result.Status = 'Skipped - Irreversible'
            $result.Message = 'Phase non reversible (OU/comptes/structure) : annulation manuelle requise.'
            return $result
        }
        if (-not (Get-Command $Task.rollbackFunction -ErrorAction SilentlyContinue)) {
            $result.Status = 'Error'; $result.Message = "Fonction de rollback introuvable : $($Task.rollbackFunction)"
            return $result
        }
        if ($PSCmdlet.ShouldProcess($Task.id, 'Rollback tiering phase')) {
            & $Task.rollbackFunction
            $result.Status = 'RolledBack'; $result.Message = 'Phase annulee.'
        }
    }
    catch { $result.Status = 'Error'; $result.Message = $_.Exception.Message }
    return $result
}

#endregion

#region Phase : OU

function New-TierOUs {
    $ctx = Get-TierContext; $d = $ctx.Domain; $c = $ctx.Config
    $protect = [bool]$c.protectOusFromDeletion
    Ensure-TierOU -DistinguishedName $d.AdminRootOU
    Ensure-TierOU -DistinguishedName $d.GroupRootOU
    Ensure-TierOU -DistinguishedName $d.ServerRootOU
    foreach ($t in $c.tiers) {
        Ensure-TierOU -DistinguishedName "OU=$t,$($d.AdminRootOU)" -Protect $protect
        Ensure-TierOU -DistinguishedName "OU=$t,$($d.ServerRootOU)" -Protect $protect
    }
}
function Test-TierOUs {
    try {
        $ctx = Get-TierContext; $d = $ctx.Domain; $c = $ctx.Config
        foreach ($p in @($d.AdminRootOU, $d.GroupRootOU, $d.ServerRootOU)) {
            if (-not (Test-TierOUExists $p)) { return $false }
        }
        foreach ($t in $c.tiers) {
            if (-not (Test-TierOUExists "OU=$t,$($d.AdminRootOU)")) { return $false }
            if (-not (Test-TierOUExists "OU=$t,$($d.ServerRootOU)")) { return $false }
        }
        return $true
    }
    catch { return $false }
}
function Remove-TierOUs { Write-Warning "Suppression d'OU non automatisee (securite). Supprimer manuellement si vides." }

#endregion

#region Phase : groupes admin par tier

function New-TierAdminGroups {
    $ctx = Get-TierContext; $d = $ctx.Domain; $c = $ctx.Config
    foreach ($t in $c.tiers) {
        Ensure-TierGroup -Name (Get-TierAdminGroupName -Tier $t) -Path $d.GroupRootOU `
            -Description "Comptes d'administration du tier $t" | Out-Null
    }
}
function Test-TierAdminGroups {
    try {
        $c = (Get-TierContext).Config
        foreach ($t in $c.tiers) {
            if (-not (Get-ADGroup -LDAPFilter "(sAMAccountName=$(Get-TierAdminGroupName -Tier $t))" -ErrorAction SilentlyContinue)) { return $false }
        }
        return $true
    }
    catch { return $false }
}
function Remove-TierAdminGroups { Write-Warning "Suppression des groupes de tier non automatisee (securite)." }

#endregion

#region Phase : comptes admin

function Get-TierGeneratedPasswords { return $script:GeneratedPasswords.ToArray() }

function New-TierAdminAccounts {
    $ErrorActionPreference = 'Stop'
    $ctx = Get-TierContext; $d = $ctx.Domain; $c = $ctx.Config
    $script:GeneratedPasswords.Clear()

    foreach ($account in $ctx.Accounts) {
        $nom = Get-TierCsvValue -Row $account -Names @("Nom", "NOM")
        $prenom = Get-TierCsvValue -Row $account -Names @("Prenom", "FirstName")
        $rawSam = Get-TierCsvValue -Row $account -Names @("CompteAdmin", "sAMAccountName", "Login")
        $tier = (Get-TierCsvValue -Row $account -Names @("NiveauTiering", "Tier")).ToUpper()
        if ($tier -notin $c.tiers) { $tier = "T2" }
        if ([string]::IsNullOrWhiteSpace($nom) -and [string]::IsNullOrWhiteSpace($prenom) -and [string]::IsNullOrWhiteSpace($rawSam)) { continue }

        $sam = New-TierAdminSam -Tier $tier -RawSam $rawSam -Nom $nom -Prenom $prenom
        $upn = "$sam@$($d.DnsRoot)"
        $displayName = "$prenom $nom".Trim(); if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $sam }
        $targetOu = "OU=$tier,$($d.AdminRootOU)"
        $group = Get-TierAdminGroupName -Tier $tier
        $isTier0 = ($tier -eq 'T0' -and [bool]$c.markSensitiveTier0)

        $existing = Get-ADUser -LDAPFilter "(sAMAccountName=$sam)" -ErrorAction SilentlyContinue
        if (-not $existing) {
            $plain = New-TierRandomPassword -Length ([int]$c.adminPasswordLength)
            $secure = ConvertTo-SecureString $plain -AsPlainText -Force
            New-ADUser -Name $displayName -GivenName $prenom -Surname $nom -DisplayName $displayName `
                -SamAccountName $sam -UserPrincipalName $upn -Path $targetOu `
                -AccountPassword $secure -Enabled $true -ChangePasswordAtLogon $false `
                -PasswordNeverExpires $false -AccountNotDelegated $isTier0 `
                -Description "Compte d'administration tier $tier" -ErrorAction Stop | Out-Null
            $script:GeneratedPasswords.Add([pscustomobject]@{
                CompteAdmin = $sam; UPN = $upn; DisplayName = $displayName
                NiveauTiering = $tier; MotDePasseInitial = $plain
            })
        }
        else {
            Set-ADUser -Identity $sam -DisplayName $displayName -UserPrincipalName $upn `
                -AccountNotDelegated $isTier0 -Description "Compte d'administration tier $tier" -ErrorAction Stop
        }
        Add-ADGroupMember -Identity $group -Members $sam -ErrorAction Stop
    }
}
function Test-TierAdminAccounts {
    try {
        $ctx = Get-TierContext; $c = $ctx.Config
        foreach ($account in $ctx.Accounts) {
            $nom = Get-TierCsvValue -Row $account -Names @("Nom", "NOM")
            $prenom = Get-TierCsvValue -Row $account -Names @("Prenom", "FirstName")
            $rawSam = Get-TierCsvValue -Row $account -Names @("CompteAdmin", "sAMAccountName", "Login")
            $tier = (Get-TierCsvValue -Row $account -Names @("NiveauTiering", "Tier")).ToUpper()
            if ($tier -notin $c.tiers) { $tier = "T2" }
            if ([string]::IsNullOrWhiteSpace($nom) -and [string]::IsNullOrWhiteSpace($prenom) -and [string]::IsNullOrWhiteSpace($rawSam)) { continue }
            $sam = New-TierAdminSam -Tier $tier -RawSam $rawSam -Nom $nom -Prenom $prenom
            if (-not (Get-ADUser -LDAPFilter "(sAMAccountName=$sam)" -ErrorAction SilentlyContinue)) { return $false }
        }
        return $true
    }
    catch { return $false }
}
function Disable-TierAdminAccounts {
    # Rollback non destructif : on DESACTIVE les comptes (pas de suppression).
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    $ctx = Get-TierContext; $c = $ctx.Config
    foreach ($account in $ctx.Accounts) {
        $nom = Get-TierCsvValue -Row $account -Names @("Nom", "NOM")
        $prenom = Get-TierCsvValue -Row $account -Names @("Prenom", "FirstName")
        $rawSam = Get-TierCsvValue -Row $account -Names @("CompteAdmin", "sAMAccountName", "Login")
        $tier = (Get-TierCsvValue -Row $account -Names @("NiveauTiering", "Tier")).ToUpper()
        if ($tier -notin $c.tiers) { $tier = "T2" }
        $sam = New-TierAdminSam -Tier $tier -RawSam $rawSam -Nom $nom -Prenom $prenom
        if (Get-ADUser -LDAPFilter "(sAMAccountName=$sam)" -ErrorAction SilentlyContinue) {
            Disable-ADAccount -Identity $sam -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region Phase : T0 = administrateurs du domaine

function Add-Tier0ToDomainPrivileged {
    <#
    .SYNOPSIS
        Imbrique GG_T0_Admins dans les groupes privilegies du domaine (Domain Admins, etc.).
    .DESCRIPTION
        Nesting de groupe : GG_T0_Admins devient membre des groupes listes dans
        'tier0PrivilegedGroups'. Tous les comptes admt0X (membres de GG_T0_Admins) heritent
        ainsi des droits administrateur du domaine. Idempotent (skip si deja membre).
        Trace l'ajout dans le state backup pour un rollback precis.
    #>
    $ErrorActionPreference = 'Stop'
    Import-Module ActiveDirectory -ErrorAction Stop
    $ctx = Get-TierContext
    $t0Group = Get-TierAdminGroupName -Tier 'T0'
    if (-not (Get-ADGroup -LDAPFilter "(sAMAccountName=$t0Group)" -ErrorAction SilentlyContinue)) {
        throw "$t0Group introuvable. La phase TIER-GRP-001 doit etre executee avant."
    }
    $t0Sid = (Get-ADGroup -Identity $t0Group).SID.Value
    $privileged = @($ctx.Config.tier0PrivilegedGroups)
    if (-not $privileged) { Write-Warning "Aucun groupe defini dans tier0PrivilegedGroups : phase sans effet."; return }

    foreach ($priv in $privileged) {
        $target = Get-ADGroup -LDAPFilter "(sAMAccountName=$priv)" -ErrorAction SilentlyContinue
        if (-not $target) { Write-Warning "Groupe privilegie absent : '$priv'. Ignore."; continue }
        $alreadyMember = Get-ADGroupMember -Identity $target -ErrorAction SilentlyContinue |
            Where-Object { $_.SID.Value -eq $t0Sid }
        if ($alreadyMember) { Write-Verbose "$t0Group deja membre de '$priv'."; continue }
        Add-ADGroupMember -Identity $target -Members $t0Group -ErrorAction Stop
        Set-TierStateBackup -Component 'Tier0Privileged' -Item $priv -PriorValue 'added'
    }
}

function Test-Tier0DomainPrivileged {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $ctx = Get-TierContext
        $t0Group = Get-TierAdminGroupName -Tier 'T0'
        $t0 = Get-ADGroup -LDAPFilter "(sAMAccountName=$t0Group)" -ErrorAction SilentlyContinue
        if (-not $t0) { return $false }
        $t0Sid = $t0.SID.Value
        $privileged = @($ctx.Config.tier0PrivilegedGroups)
        foreach ($priv in $privileged) {
            $target = Get-ADGroup -LDAPFilter "(sAMAccountName=$priv)" -ErrorAction SilentlyContinue
            if (-not $target) { continue }   # groupe inexistant = on n'echoue pas le test
            $members = @(Get-ADGroupMember -Identity $target -ErrorAction SilentlyContinue)
            if (-not ($members | Where-Object { $_.SID.Value -eq $t0Sid })) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Remove-Tier0FromDomainPrivileged {
    <# .SYNOPSIS Retire UNIQUEMENT GG_T0_Admins des groupes privilegies (ne nettoie pas les autres membres). #>
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    $ctx = Get-TierContext
    $t0Group = Get-TierAdminGroupName -Tier 'T0'
    foreach ($priv in @($ctx.Config.tier0PrivilegedGroups)) {
        if (Get-ADGroup -LDAPFilter "(sAMAccountName=$priv)" -ErrorAction SilentlyContinue) {
            Remove-ADGroupMember -Identity $priv -Members $t0Group -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region Phase : Protected Users (T0)

function Get-TierProtectedUsersGroup {
    # Groupe 'Protected Users' resolu par SID de domaine (-525) : insensible a la langue.
    $d = (Get-TierContext).Domain
    return Get-ADGroup -Identity "$($d.DomainSID)-525" -ErrorAction Stop
}

function Add-Tier0ToProtectedUsers {
    <# .SYNOPSIS Ajoute les comptes membres de GG_T0_Admins au groupe Protected Users. #>
    $ErrorActionPreference = 'Stop'
    Import-Module ActiveDirectory -ErrorAction Stop
    $t0Group = Get-TierAdminGroupName -Tier 'T0'
    if (-not (Get-ADGroup -LDAPFilter "(sAMAccountName=$t0Group)" -ErrorAction SilentlyContinue)) {
        throw "$t0Group introuvable. La phase TIER-GRP-001 doit etre executee avant."
    }
    try { $pu = Get-TierProtectedUsersGroup }
    catch { throw "Groupe 'Protected Users' introuvable (niveau fonctionnel de domaine >= 2012 R2 requis)." }

    $t0Members = @(Get-ADGroupMember -Identity $t0Group -Recursive -ErrorAction SilentlyContinue |
        Where-Object { $_.objectClass -eq 'user' })
    $puMembers = @((Get-ADGroupMember -Identity $pu -ErrorAction SilentlyContinue).SID.Value)
    foreach ($m in $t0Members) {
        if ($puMembers -contains $m.SID.Value) { continue }
        Add-ADGroupMember -Identity $pu -Members $m.SID -ErrorAction Stop
        Set-TierStateBackup -Component 'ProtectedUsers' -Item $m.SamAccountName -PriorValue 'added'
    }
}
function Test-Tier0ProtectedUsers {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $t0Group = Get-TierAdminGroupName -Tier 'T0'
        if (-not (Get-ADGroup -LDAPFilter "(sAMAccountName=$t0Group)" -ErrorAction SilentlyContinue)) { return $false }
        $pu = Get-TierProtectedUsersGroup
        $t0Members = @(Get-ADGroupMember -Identity $t0Group -Recursive -ErrorAction SilentlyContinue |
            Where-Object { $_.objectClass -eq 'user' })
        if ($t0Members.Count -eq 0) { return $true }
        $puMembers = @((Get-ADGroupMember -Identity $pu -ErrorAction SilentlyContinue).SID.Value)
        foreach ($m in $t0Members) { if ($puMembers -notcontains $m.SID.Value) { return $false } }
        return $true
    }
    catch { return $false }
}
function Remove-Tier0FromProtectedUsers {
    # Rollback : retire les comptes T0 actuels de Protected Users (recalcule, sans dependance au state).
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    $t0Group = Get-TierAdminGroupName -Tier 'T0'
    $pu = Get-TierProtectedUsersGroup
    $t0Members = @(Get-ADGroupMember -Identity $t0Group -Recursive -ErrorAction SilentlyContinue |
        Where-Object { $_.objectClass -eq 'user' })
    foreach ($m in $t0Members) {
        Remove-ADGroupMember -Identity $pu -Members $m.SID -Confirm:$false -ErrorAction SilentlyContinue
    }
}

#endregion

#region Phase : PSO

function Set-TierPasswordPolicy {
    Import-Module ActiveDirectory -ErrorAction Stop
    $ctx = Get-TierContext; $c = $ctx.Config; $p = $c.passwordPolicy
    $pso = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($p.name)'" -ErrorAction SilentlyContinue
    if (-not $pso) {
        New-ADFineGrainedPasswordPolicy -Name $p.name -Precedence ([int]$p.precedence) `
            -ComplexityEnabled $true -ReversibleEncryptionEnabled $false `
            -MinPasswordLength ([int]$p.minLength) -PasswordHistoryCount ([int]$p.historyCount) `
            -MaxPasswordAge (New-TimeSpan -Days ([int]$p.maxAgeDays)) `
            -MinPasswordAge (New-TimeSpan -Days ([int]$p.minAgeDays)) `
            -LockoutThreshold ([int]$p.lockoutThreshold) `
            -LockoutDuration (New-TimeSpan -Minutes ([int]$p.lockoutDurationMin)) `
            -LockoutObservationWindow (New-TimeSpan -Minutes ([int]$p.lockoutWindowMin)) `
            -ErrorAction Stop | Out-Null
    }
    foreach ($t in $c.tiers) {
        $g = Get-TierAdminGroupName -Tier $t
        if (Get-ADGroup -LDAPFilter "(sAMAccountName=$g)" -ErrorAction SilentlyContinue) {
            try { Add-ADFineGrainedPasswordPolicySubject -Identity $p.name -Subjects $g -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch "already|existe|deja") { Write-Warning "PSO sur $g : $($_.Exception.Message)" } }
        }
    }
}
function Test-TierPasswordPolicy {
    try {
        $p = (Get-TierContext).Config.passwordPolicy
        return [bool](Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($p.name)'" -ErrorAction SilentlyContinue)
    }
    catch { return $false }
}
function Remove-TierPasswordPolicy {
    Import-Module ActiveDirectory -ErrorAction Stop
    $p = (Get-TierContext).Config.passwordPolicy
    $pso = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($p.name)'" -ErrorAction SilentlyContinue
    if ($pso) { Remove-ADFineGrainedPasswordPolicy -Identity $p.name -Confirm:$false -ErrorAction SilentlyContinue }
}

#endregion

#region Phase : groupes d'acces serveurs (GLA)

function Get-TierServerAccessMatrix { return $script:ServerAccessMatrix.ToArray() }

function New-TierServerAccessGroups {
    $ctx = Get-TierContext; $d = $ctx.Domain; $c = $ctx.Config; $n = $c.naming
    $script:ServerAccessMatrix.Clear()
    foreach ($server in $ctx.Servers) {
        $name = Get-TierCsvValue -Row $server -Names @("NomServeur", "Serveur", "Server")
        $tier = (Get-TierCsvValue -Row $server -Names @("NiveauTiering", "Tier")).ToUpper()
        $role = Get-TierCsvValue -Row $server -Names @("RoleServeur", "Role")
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($tier -notin $c.tiers) { $tier = "T2" }
        $safe = ConvertTo-TierSafeName -Value $name
        $gla = "$($n.serverLocalAdminPrefix)$safe$($n.serverLocalAdminSuffix)"
        $tierGroup = Get-TierAdminGroupName -Tier $tier
        Ensure-TierGroup -Name $gla -Path $d.GroupRootOU -Description "Acces admin local du serveur $name" | Out-Null
        Add-ADGroupMember -Identity $gla -Members $tierGroup -ErrorAction SilentlyContinue
        $script:ServerAccessMatrix.Add([pscustomobject]@{
            NomServeur = $name; NiveauTiering = $tier; RoleServeur = $role
            GroupeLocalAdminAD = $gla; GroupeAdminAutorise = $tierGroup
        })
    }
}
function Test-TierServerAccessGroups {
    try {
        $ctx = Get-TierContext; $c = $ctx.Config; $n = $c.naming
        foreach ($server in $ctx.Servers) {
            $name = Get-TierCsvValue -Row $server -Names @("NomServeur", "Serveur", "Server")
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $gla = "$($n.serverLocalAdminPrefix)$(ConvertTo-TierSafeName -Value $name)$($n.serverLocalAdminSuffix)"
            if (-not (Get-ADGroup -LDAPFilter "(sAMAccountName=$gla)" -ErrorAction SilentlyContinue)) { return $false }
        }
        return $true
    }
    catch { return $false }
}
function Remove-TierServerAccessGroups { Write-Warning "Suppression des groupes GLA non automatisee (securite)." }

#endregion

#region Phase : deplacement des serveurs

function Move-TierServers {
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    $ctx = Get-TierContext; $d = $ctx.Domain; $c = $ctx.Config
    foreach ($server in $ctx.Servers) {
        $name = Get-TierCsvValue -Row $server -Names @("NomServeur", "Serveur", "Server")
        $tier = (Get-TierCsvValue -Row $server -Names @("NiveauTiering", "Tier")).ToUpper()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($tier -notin $c.tiers) { $tier = "T2" }
        $ou = "OU=$tier,$($d.ServerRootOU)"
        Ensure-TierOU -DistinguishedName $ou
        $computer = Get-ADComputer -Identity $name -ErrorAction SilentlyContinue
        if (-not $computer) { Write-Warning "Serveur absent d'AD, deplacement ignore : $name"; continue }
        if ($computer.DistinguishedName -like "*$ou") { continue }
        Move-ADObject -Identity $computer.DistinguishedName -TargetPath $ou -ErrorAction Stop
    }
}
function Test-TierServersPlacement {
    try {
        $ctx = Get-TierContext; $d = $ctx.Domain; $c = $ctx.Config
        foreach ($server in $ctx.Servers) {
            $name = Get-TierCsvValue -Row $server -Names @("NomServeur", "Serveur", "Server")
            $tier = (Get-TierCsvValue -Row $server -Names @("NiveauTiering", "Tier")).ToUpper()
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($tier -notin $c.tiers) { $tier = "T2" }
            $computer = Get-ADComputer -Identity $name -ErrorAction SilentlyContinue
            if (-not $computer) { continue }   # absent = ignore (non bloquant)
            if ($computer.DistinguishedName -notlike "*OU=$tier,$($d.ServerRootOU)") { return $false }
        }
        return $true
    }
    catch { return $false }
}
function Undo-TierServersPlacement { Write-Warning "Deplacement de serveurs non annule automatiquement (securite)." }

#endregion

#region Mise a jour des CSV (option -UpdateInputCsv)

function Update-TierInputCsv {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$AccountsPath,
        [Parameter(Mandatory)][string]$ServersPath
    )
    $ctx = Get-TierContext; $d = $ctx.Domain; $c = $ctx.Config
    $suffix = ".bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item $AccountsPath "$AccountsPath$suffix" -Force
    Copy-Item $ServersPath "$ServersPath$suffix" -Force

    foreach ($a in $ctx.Accounts) {
        $nom = Get-TierCsvValue -Row $a -Names @("Nom", "NOM")
        $prenom = Get-TierCsvValue -Row $a -Names @("Prenom", "FirstName")
        $rawSam = Get-TierCsvValue -Row $a -Names @("CompteAdmin", "sAMAccountName", "Login")
        $tier = (Get-TierCsvValue -Row $a -Names @("NiveauTiering", "Tier")).ToUpper()
        if ($tier -notin $c.tiers) { $tier = "T2" }
        $sam = New-TierAdminSam -Tier $tier -RawSam $rawSam -Nom $nom -Prenom $prenom
        $a.CompteAdmin = $sam
        $a.UPN = "$sam@$($d.DnsRoot)"
        $a.NiveauTiering = $tier
        $a.OUCible = "OU=$tier,$($d.AdminRootOU)"
    }
    foreach ($s in $ctx.Servers) {
        $tier = (Get-TierCsvValue -Row $s -Names @("NiveauTiering", "Tier")).ToUpper()
        if ($tier -notin $c.tiers) { $tier = "T2" }
        $s.NiveauTiering = $tier
        $s.OUCible = "OU=$tier,$($d.ServerRootOU)"
        $s.GroupeAdminAutorise = Get-TierAdminGroupName -Tier $tier
    }
    if ($PSCmdlet.ShouldProcess("$AccountsPath / $ServersPath", "Reecrire les CSV avec le domaine $($d.DnsRoot)")) {
        $ctx.Accounts | Export-Csv -Path $AccountsPath -Delimiter ";" -NoTypeInformation -Encoding UTF8
        $ctx.Servers | Export-Csv -Path $ServersPath -Delimiter ";" -NoTypeInformation -Encoding UTF8
    }
}

#endregion
