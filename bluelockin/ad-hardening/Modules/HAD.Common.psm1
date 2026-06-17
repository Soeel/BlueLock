#Requires -Version 5.1
<#
.SYNOPSIS
    HAD.Common - Fonctions transverses : logging structure et pre-verifications d'environnement.
.DESCRIPTION
    Centralise le logging (console + fichier) et les controles prealables (admin, role AD,
    module ActiveDirectory, disponibilite de PingCastle). Utilise par l'orchestrateur et les
    autres modules.
#>

# Cible de fichier de log (definie par Initialize-HADLog). $null = console seulement.
$script:LogFile = $null

function Initialize-HADLog {
    <#
    .SYNOPSIS
        Definit le fichier de log vers lequel Write-HADLog ecrit (en plus de la console).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $script:LogFile = $Path
    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Path $Path -Force | Out-Null
    }
}

function Write-HADLog {
    <#
    .SYNOPSIS
        Ecrit un message horodate avec un niveau (INFO/OK/WARN/ERROR/STEP) en console et fichier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'DEBUG')][string]$Level = 'INFO'
    )

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1,-5}] {2}" -f $ts, $Level, $Message

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }

    if ($Level -eq 'STEP') {
        Write-Host ""
        Write-Host ("=== {0} ===" -f $Message) -ForegroundColor $color
    }
    else {
        Write-Host $line -ForegroundColor $color
    }

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }
}

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        Retourne $true si la session courante est elevee (administrateur local).
    #>
    [CmdletBinding()]
    param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsDomainController {
    <#
    .SYNOPSIS
        Retourne $true si la machine est un controleur de domaine (ProductType=2).
    #>
    [CmdletBinding()]
    param()
    try {
        $role = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).ProductType
        return ($role -eq 2)
    }
    catch {
        return $false
    }
}

function Test-HardeningPrerequisites {
    <#
    .SYNOPSIS
        Verifie les prerequis et retourne un objet de diagnostic.
    .PARAMETER PingCastlePath
        Chemin vers PingCastle.exe (optionnel pour le diagnostic).
    .PARAMETER RequireDomainController
        Si present, marque l'absence de role DC comme bloquante.
    #>
    [CmdletBinding()]
    param(
        [string]$PingCastlePath,
        [switch]$RequireDomainController
    )

    $checks = [ordered]@{}

    $checks['IsAdministrator'] = [pscustomobject]@{
        Passed = Test-IsAdministrator
        Detail = 'Session elevee (administrateur) requise pour modifier la configuration.'
        Blocking = $true
    }

    $isDC = Test-IsDomainController
    $checks['IsDomainController'] = [pscustomobject]@{
        Passed = $isDC
        Detail = if ($isDC) { 'Role controleur de domaine detecte.' } else { 'Machine NON controleur de domaine.' }
        Blocking = [bool]$RequireDomainController
    }

    $adModule = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
    $checks['ActiveDirectoryModule'] = [pscustomobject]@{
        Passed = $adModule
        Detail = 'Module ActiveDirectory (RSAT-AD-PowerShell) requis pour certaines mesures (delegation, MAQ).'
        Blocking = $false
    }

    if ($PSBoundParameters.ContainsKey('PingCastlePath') -and $PingCastlePath) {
        $pcOk = Test-Path $PingCastlePath
        $checks['PingCastle'] = [pscustomobject]@{
            Passed = $pcOk
            Detail = if ($pcOk) { "PingCastle trouve : $PingCastlePath" } else { "PingCastle introuvable : $PingCastlePath" }
            Blocking = $false
        }
    }

    $blockingFailures = @($checks.GetEnumerator() | Where-Object { -not $_.Value.Passed -and $_.Value.Blocking })

    return [pscustomobject]@{
        Checks           = $checks
        AllPassed        = -not ($checks.Values | Where-Object { -not $_.Passed })
        BlockingFailures = $blockingFailures.Count
    }
}
