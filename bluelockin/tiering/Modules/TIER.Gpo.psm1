#Requires -Version 5.1
<#
.SYNOPSIS
    TIER.Gpo - Phases GPO du Tiering : admin local par tier (Restricted Groups) et
    cloisonnement des connexions (deny-logon cross-tier).
.DESCRIPTION
    Les "User Rights Assignment" (deny logon) et les "Restricted Groups" ne sont PAS des
    valeurs de registre : ils vivent dans GptTmpl.inf cote SYSVOL. Ce module ecrit ce
    fichier, enregistre le CSE Security dans gPCMachineExtensionNames, et force un bump de
    version de la GPO (valeur registre marqueur) pour que les clients reappliquent.
    Meme technique que l'audit.csv de la partie ad-hardening.
#>

# CSE Security ({827D...}) + outil d'edition ({803E...}). Doivent figurer dans
# gPCMachineExtensionNames pour que le client applique GptTmpl.inf.
$script:SecCseGuid  = '{827D319E-6EAC-11D2-A4EA-00C04F79F83A}'
$script:SecToolGuid = '{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}'

function Get-TierGroupSid {
    param([Parameter(Mandatory)][string]$Name)
    Import-Module ActiveDirectory -ErrorAction Stop
    return (Get-ADGroup -Identity $Name -ErrorAction Stop).SID.Value
}

function New-TierGpo {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [string]$Comment = 'Genere par BlueLock tiering.')
    Import-Module GroupPolicy -ErrorAction Stop
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if (-not $gpo -and $PSCmdlet.ShouldProcess($Name, 'Create GPO')) {
        $gpo = New-GPO -Name $Name -Comment $Comment -ErrorAction Stop
    }
    return $gpo
}

function Add-TierGpoLink {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GpoName, [Parameter(Mandatory)][string]$Target)
    Import-Module GroupPolicy -ErrorAction Stop
    $inh = Get-GPInheritance -Target $Target -ErrorAction SilentlyContinue
    if (-not ($inh.GpoLinks | Where-Object { $_.DisplayName -eq $GpoName })) {
        New-GPLink -Name $GpoName -Target $Target -LinkEnabled Yes -ErrorAction Stop | Out-Null
    }
}

function Register-TierSecurityCSE {
    <# .SYNOPSIS Ajoute le CSE Security a gPCMachineExtensionNames (blocs tries alphabetiquement). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GpoName)
    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module GroupPolicy -ErrorAction Stop
    $gpo = Get-GPO -Name $GpoName -ErrorAction Stop
    $domainDn = (Get-ADDomain).DistinguishedName
    $gpcDn = "CN={$($gpo.Id.Guid)},CN=Policies,CN=System,$domainDn"
    $cur = (Get-ADObject -Identity $gpcDn -Properties gPCMachineExtensionNames).gPCMachineExtensionNames
    if (-not $cur) { $cur = '' }
    if ($cur -match [regex]::Escape($script:SecCseGuid)) { return }
    $blocks = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($cur, '\[[^\]]+\]')) { $blocks.Add($m.Value) }
    $blocks.Add("[$script:SecCseGuid$script:SecToolGuid]")
    $new = -join ($blocks | Sort-Object)
    Set-ADObject -Identity $gpcDn -Replace @{ gPCMachineExtensionNames = $new } -ErrorAction Stop
}

function Get-TierGptTmplPath {
    param([Parameter(Mandatory)][string]$GpoName)
    Import-Module GroupPolicy -ErrorAction Stop
    Import-Module ActiveDirectory -ErrorAction Stop
    $gpo = Get-GPO -Name $GpoName -ErrorAction Stop
    $dom = (Get-ADDomain).DNSRoot
    return "\\$dom\SYSVOL\$dom\Policies\{$($gpo.Id.Guid)}\Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf"
}

function Set-TierGpoSecurityTemplate {
    <#
    .SYNOPSIS
        Ecrit GptTmpl.inf (sections [Privilege Rights] et/ou [Group Membership]), enregistre
        le CSE Security, et force un bump de version via une valeur registre marqueur.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [hashtable]$PrivilegeRights,
        [hashtable]$GroupMembership,
        [string]$Marker = 'Tiering'
    )
    Import-Module GroupPolicy -ErrorAction Stop

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[Unicode]'); $lines.Add('Unicode=yes')
    $lines.Add('[Version]'); $lines.Add('signature="$CHICAGO$"'); $lines.Add('Revision=1')
    if ($PrivilegeRights -and $PrivilegeRights.Count -gt 0) {
        $lines.Add('[Privilege Rights]')
        foreach ($k in $PrivilegeRights.Keys) { $lines.Add("$k = $($PrivilegeRights[$k])") }
    }
    if ($GroupMembership -and $GroupMembership.Count -gt 0) {
        $lines.Add('[Group Membership]')
        foreach ($k in $GroupMembership.Keys) { $lines.Add("$k = $($GroupMembership[$k])") }
    }

    $path = Get-TierGptTmplPath -GpoName $GpoName
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # GptTmpl.inf est traditionnellement en Unicode (UTF-16LE).
    Set-Content -LiteralPath $path -Value $lines -Encoding Unicode

    Register-TierSecurityCSE -GpoName $GpoName
    # Valeur registre marqueur : force l'increment de version de la GPO (reapplication client).
    Set-GPRegistryValue -Name $GpoName -Key 'HKLM\Software\BlueLock\Tiering' `
        -ValueName $Marker -Type String -Value (Get-Date -Format 'o') -ErrorAction SilentlyContinue | Out-Null
}

function Read-TierGptTmpl {
    param([Parameter(Mandatory)][string]$GpoName)
    try {
        $path = Get-TierGptTmplPath -GpoName $GpoName
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        return (Get-Content -LiteralPath $path -Raw)
    }
    catch { return $null }
}

function Remove-TierGpo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Import-Module GroupPolicy -ErrorAction Stop
    if (Get-GPO -Name $Name -ErrorAction SilentlyContinue) {
        Remove-GPO -Name $Name -ErrorAction Stop | Out-Null
    }
}

#region Phase : admin local par tier (Restricted Groups)

function Set-TierLocalAdminGpo {
    $ctx = Get-TierContext; $d = $ctx.Domain; $c = $ctx.Config
    foreach ($t in $c.tiers) {
        $gpoName = "GPO_Tiering_${t}_LocalAdmins"
        $ou = "OU=$t,$($d.ServerRootOU)"
        Ensure-TierOU -DistinguishedName $ou
        New-TierGpo -Name $gpoName -Comment "Admin local : GG_${t}_Admins membre des Administrateurs locaux ($t)" | Out-Null
        $sid = Get-TierGroupSid -Name (Get-TierAdminGroupName -Tier $t)
        # __Memberof = le groupe de tier devient membre des Administrateurs locaux (S-1-5-32-544).
        # Approche additive et reappliquee (vs startup script de l'ancienne version).
        $gm = @{}
        $gm["*${sid}__Memberof"] = '*S-1-5-32-544'
        $gm["*${sid}__Members"] = ''
        Set-TierGpoSecurityTemplate -GpoName $gpoName -GroupMembership $gm -Marker "LocalAdmin_$t"
        Add-TierGpoLink -GpoName $gpoName -Target $ou
    }
}
function Test-TierLocalAdminGpo {
    try {
        $c = (Get-TierContext).Config
        foreach ($t in $c.tiers) {
            $inf = Read-TierGptTmpl -GpoName "GPO_Tiering_${t}_LocalAdmins"
            if (-not $inf) { return $false }
            $sid = Get-TierGroupSid -Name (Get-TierAdminGroupName -Tier $t)
            if ($inf -notmatch [regex]::Escape($sid)) { return $false }
            if ($inf -notmatch 'S-1-5-32-544') { return $false }
        }
        return $true
    }
    catch { return $false }
}
function Remove-TierLocalAdminGpo {
    $c = (Get-TierContext).Config
    foreach ($t in $c.tiers) { Remove-TierGpo -Name "GPO_Tiering_${t}_LocalAdmins" }
}

#endregion

#region Phase : deny-logon cross-tier

function Set-TierDenyLogonGpo {
    $ctx = Get-TierContext; $d = $ctx.Domain; $c = $ctx.Config
    foreach ($t in $c.tiers) {
        $gpoName = "GPO_Tiering_${t}_DenyLogon"
        $ou = "OU=$t,$($d.ServerRootOU)"
        Ensure-TierOU -DistinguishedName $ou
        New-TierGpo -Name $gpoName -Comment "Cloisonnement : interdit aux autres tiers d'ouvrir une session sur $t" | Out-Null

        $denyCfg = $c.denyLogon.$t
        $denySids = @()
        foreach ($dt in $denyCfg.denyTiers) { $denySids += "*$(Get-TierGroupSid -Name (Get-TierAdminGroupName -Tier $dt))" }
        $domainUsersSid = "*$($d.DomainSID)-513"

        $interactive = @($denySids)
        $rdp = @($denySids)
        if ($denyCfg.denyDomainUsers) { $interactive += $domainUsersSid; $rdp += $domainUsersSid }

        $pr = @{
            'SeDenyInteractiveLogonRight'       = ($interactive -join ',')
            'SeDenyRemoteInteractiveLogonRight' = ($rdp -join ',')
            'SeDenyBatchLogonRight'             = ($denySids -join ',')
            'SeDenyServiceLogonRight'           = ($denySids -join ',')
            'SeDenyNetworkLogonRight'           = ($denySids -join ',')
        }
        Set-TierGpoSecurityTemplate -GpoName $gpoName -PrivilegeRights $pr -Marker "DenyLogon_$t"
        Add-TierGpoLink -GpoName $gpoName -Target $ou
    }
}
function Test-TierDenyLogonGpo {
    try {
        $ctx = Get-TierContext; $c = $ctx.Config
        foreach ($t in $c.tiers) {
            $inf = Read-TierGptTmpl -GpoName "GPO_Tiering_${t}_DenyLogon"
            if (-not $inf) { return $false }
            if ($inf -notmatch 'SeDenyInteractiveLogonRight') { return $false }
            foreach ($dt in $c.denyLogon.$t.denyTiers) {
                $sid = Get-TierGroupSid -Name (Get-TierAdminGroupName -Tier $dt)
                if ($inf -notmatch [regex]::Escape($sid)) { return $false }
            }
        }
        return $true
    }
    catch { return $false }
}
function Remove-TierDenyLogonGpo {
    $c = (Get-TierContext).Config
    foreach ($t in $c.tiers) { Remove-TierGpo -Name "GPO_Tiering_${t}_DenyLogon" }
}

#endregion
