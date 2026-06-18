#Requires -Version 5.1
<#
.SYNOPSIS
    TIER.Common - Fonctions transverses du Tiering : logging structure, pre-verifications,
    contexte partage entre modules, sauvegarde d'etat et helpers (noms, mots de passe).
.DESCRIPTION
    Memes conventions que la partie ad-hardening (HAD.Common). Le contexte (config, CSV,
    domaine) est stocke ici et lu par tous les modules via Get-TierContext, ce qui permet
    au moteur d'appeler les fonctions de phase par leur nom (sans argument).
#>

$script:LogFile     = $null
$script:TierContext = $null
$script:StateBackup = New-Object System.Collections.Generic.List[object]

#region Logging

function Initialize-TierLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $script:LogFile = $Path
    if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
}

function Write-TierLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'DEBUG')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1,-5}] {2}" -f $ts, $Level, $Message
    $color = switch ($Level) {
        'OK'    { 'Green' }  'WARN'  { 'Yellow' } 'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }   'DEBUG' { 'DarkGray' } default { 'Gray' }
    }
    if ($Level -eq 'STEP') {
        Write-Host ""
        Write-Host ("=== {0} ===" -f $Message) -ForegroundColor $color
    }
    else { Write-Host $line -ForegroundColor $color }
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
}

#endregion

#region Contexte partage

function Set-TierContext {
    <# .SYNOPSIS Enregistre le contexte (config, comptes, serveurs, domaine, sorties). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $script:TierContext = $Context
}

function Get-TierContext {
    <# .SYNOPSIS Retourne le contexte courant. Leve si non initialise. #>
    [CmdletBinding()] param()
    if ($null -eq $script:TierContext) { throw "Contexte Tiering non initialise (Set-TierContext)." }
    return $script:TierContext
}

#endregion

#region Sauvegarde d'etat (pour rollback)

function Set-TierStateBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Item,
        $PriorValue
    )
    $script:StateBackup.Add([pscustomobject]@{
        Component  = $Component
        Item       = $Item
        PriorValue = $PriorValue
        Timestamp  = (Get-Date).ToString('o')
    })
}

function Get-TierStateBackup {
    [CmdletBinding()] param()
    return $script:StateBackup.ToArray()
}

#endregion

#region Pre-verifications

function Test-IsAdministrator {
    [CmdletBinding()] param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-TieringPrerequisites {
    <# .SYNOPSIS Verifie admin, module AD, module GroupPolicy. Retourne un objet diagnostic. #>
    [CmdletBinding()]
    param([switch]$RequireGroupPolicy)

    $checks = [ordered]@{}
    $checks['IsAdministrator'] = [pscustomobject]@{
        Passed = Test-IsAdministrator
        Detail = 'Session elevee (administrateur du domaine) requise.'
        Blocking = $true
    }
    $adOk = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
    $checks['ActiveDirectoryModule'] = [pscustomobject]@{
        Passed = $adOk
        Detail = 'Module ActiveDirectory (RSAT-AD-PowerShell) requis.'
        Blocking = $true
    }
    $gpOk = [bool](Get-Module -ListAvailable -Name GroupPolicy)
    $checks['GroupPolicyModule'] = [pscustomobject]@{
        Passed = $gpOk
        Detail = 'Module GroupPolicy requis pour les phases GPO (local admin, deny-logon).'
        Blocking = [bool]$RequireGroupPolicy
    }

    $blocking = @($checks.GetEnumerator() | Where-Object { -not $_.Value.Passed -and $_.Value.Blocking })
    return [pscustomobject]@{
        Checks           = $checks
        AllPassed        = -not ($checks.Values | Where-Object { -not $_.Passed })
        BlockingFailures = $blocking.Count
    }
}

#endregion

#region Helpers de nommage et mots de passe

function Remove-TierTextAccent {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }
    return $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function ConvertTo-TierSafeName {
    param([AllowNull()][string]$Value)
    $v = Remove-TierTextAccent -Text $Value
    $safe = ($v.ToUpper() -replace "[^A-Z0-9]", "_") -replace "_+", "_"
    $safe = $safe.Trim("_")
    if ([string]::IsNullOrWhiteSpace($safe)) { return "UNKNOWN" }
    return $safe
}

function ConvertTo-TierSafeBaseSam {
    param([AllowNull()][string]$Value)
    $v = Remove-TierTextAccent -Text $Value
    $safe = $v.ToLower() -replace "[^a-z0-9]", ""
    if ([string]::IsNullOrWhiteSpace($safe)) { return "unknown" }
    return $safe
}

function New-TierAdminSam {
    <# .SYNOPSIS Construit un sAMAccountName admtX... (<= 20 caracteres). #>
    param(
        [Parameter(Mandatory)][string]$Tier,
        [AllowNull()][string]$RawSam,
        [AllowNull()][string]$Nom,
        [AllowNull()][string]$Prenom
    )
    $prefix = "adm$($Tier.ToLower())"
    if (-not [string]::IsNullOrWhiteSpace($RawSam)) {
        $base = ConvertTo-TierSafeBaseSam -Value $RawSam
        $base = $base -replace "^adm", "" -replace "^t[012]", ""
    }
    else {
        $firstLetter = if (-not [string]::IsNullOrWhiteSpace($Prenom)) { $Prenom.Substring(0, 1) } else { "x" }
        $base = ConvertTo-TierSafeBaseSam -Value "$firstLetter$Nom"
    }
    $sam = "$prefix$base"
    if ($sam.Length -gt 20) { $sam = $sam.Substring(0, 20) }
    return $sam
}

function New-TierRandomPassword {
    param([int]$Length = 20)
    if ($Length -lt 14) { $Length = 14 }
    $lower = 'abcdefghjkmnpqrstuvwxyz'; $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $digits = '23456789'; $special = '!@#$%^&*()-_=+'
    $all = "$lower$upper$digits$special"
    $chars = New-Object System.Collections.Generic.List[char]
    $chars.Add($lower[(Get-Random -Maximum $lower.Length)])
    $chars.Add($upper[(Get-Random -Maximum $upper.Length)])
    $chars.Add($digits[(Get-Random -Maximum $digits.Length)])
    $chars.Add($special[(Get-Random -Maximum $special.Length)])
    while ($chars.Count -lt $Length) { $chars.Add($all[(Get-Random -Maximum $all.Length)]) }
    return (-join ($chars | Sort-Object { Get-Random }))
}

function Get-TierCsvValue {
    <# .SYNOPSIS Lit une valeur de ligne CSV en tolerant plusieurs noms de colonnes. #>
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string[]]$Names
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

#endregion
