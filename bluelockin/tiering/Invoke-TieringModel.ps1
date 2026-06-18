#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Invoke-TieringModel - Orchestrateur d'implementation du modele Tiering AD (T0/T1/T2).

.DESCRIPTION
    Architecture config-driven identique a la partie ad-hardening :
      1. Pre-verifications (admin, modules AD/GroupPolicy)
      2. Detection du domaine + chargement config/CSV -> contexte partage
      3. (option) Mise a jour des CSV avec le domaine detecte et la nomenclature
      4. Execution ORDONNEE des phases du catalogue (test -> apply -> verify)
      5. Rapports : HTML + JSON + CSV (matrice d'acces, mots de passe initiaux)

    Phases : OU, groupes admin, comptes admin, PSO, groupes d'acces serveurs, deplacement
    serveurs, GPO admin local (Restricted Groups), GPO deny-logon cross-tier.

.PARAMETER DryRun
    Simulation : aucune modification.

.PARAMETER Rollback
    Annule les phases reversibles (PSO + GPO). Les OU/groupes/comptes ne sont PAS supprimes
    automatiquement (Skipped - Irreversible).

.PARAMETER UpdateInputCsv
    Reecrit les CSV d'entree avec le domaine detecte et la nomenclature admtX (backup .bak).

.PARAMETER SkipServerMove
    Ne deplace pas les objets ordinateurs (phase TIER-MOVE-001).

.EXAMPLE
    .\Invoke-TieringModel.ps1 -DryRun
.EXAMPLE
    .\Invoke-TieringModel.ps1 -UpdateInputCsv
.EXAMPLE
    .\Invoke-TieringModel.ps1
.EXAMPLE
    .\Invoke-TieringModel.ps1 -Rollback
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$TasksPath,
    [string]$AccountsCsv,
    [string]$ServersCsv,
    [switch]$DryRun,
    [switch]$Rollback,
    [switch]$UpdateInputCsv,
    [switch]$SkipServerMove
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Find-TierFile {
    param([string]$FileName, [string]$SubDir)
    if ($SubDir) {
        $nested = Join-Path (Join-Path $root $SubDir) $FileName
        if (Test-Path $nested) { return (Resolve-Path $nested).Path }
    }
    $flat = Join-Path $root $FileName
    if (Test-Path $flat) { return (Resolve-Path $flat).Path }
    return $null
}

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $root "Outputs\$stamp"
$logDir = Join-Path $root 'Logs'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$transcript = Join-Path $logDir "tiering-$stamp.log"
Start-Transcript -Path $transcript -Force | Out-Null

try {
    Write-Host "`n=== Initialisation ===" -ForegroundColor Cyan
    foreach ($mod in @('TIER.Common.psm1', 'TIER.Model.psm1', 'TIER.Gpo.psm1', 'TIER.Reporting.psm1')) {
        $modPath = Find-TierFile $mod 'Modules'
        if (-not $modPath) { throw "Module introuvable : $mod" }
        Import-Module $modPath -Force -DisableNameChecking -Global -ErrorAction Stop
        Write-Host "  [OK] $mod" -ForegroundColor DarkGray
    }

    $required = @(
        'Write-TierLog', 'Test-TieringPrerequisites', 'Set-TierContext', 'Resolve-TierDomainInfo',
        'Invoke-TieringTask', 'Invoke-TieringRollback', 'Set-TierDenyLogonGpo', 'New-TieringReport'
    )
    foreach ($fn in $required) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw "Fonction manquante apres chargement : $fn" }
    }

    Initialize-TierLog -Path (Join-Path $logDir "tiering-$stamp.struct.log")

    # --- Pre-verifications ---
    Write-TierLog 'Pre-verifications' -Level STEP
    $pre = Test-TieringPrerequisites -RequireGroupPolicy
    foreach ($name in $pre.Checks.Keys) {
        $c = $pre.Checks[$name]
        $lvl = if ($c.Passed) { 'OK' } elseif ($c.Blocking) { 'ERROR' } else { 'WARN' }
        Write-TierLog ("{0} : {1}" -f $name, $c.Detail) -Level $lvl
    }
    if ($pre.BlockingFailures -gt 0) { throw "Pre-verifications bloquantes en echec ($($pre.BlockingFailures))." }

    # --- Configs ---
    if (-not $ConfigPath)   { $ConfigPath   = Find-TierFile 'tiering-config.json' 'Configs' }
    if (-not $TasksPath)    { $TasksPath    = Find-TierFile 'tiering-tasks.json'  'Configs' }
    if (-not $AccountsCsv)  { $AccountsCsv  = Find-TierFile 'admin-accounts.csv'  'Configs' }
    if (-not $ServersCsv)   { $ServersCsv   = Find-TierFile 'servers.csv'         'Configs' }
    foreach ($f in @($ConfigPath, $TasksPath, $AccountsCsv, $ServersCsv)) {
        if (-not $f -or -not (Test-Path $f)) { throw "Fichier de configuration introuvable (config/tasks/CSV)." }
    }

    $config   = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $catalog  = @((Get-Content $TasksPath -Raw | ConvertFrom-Json).tasks)
    $accounts = @(Import-Csv -Path $AccountsCsv -Delimiter ';')
    $servers  = @(Import-Csv -Path $ServersCsv -Delimiter ';')

    Write-TierLog 'Detection du domaine' -Level STEP
    $domainInfo = Resolve-TierDomainInfo -Config $config
    Write-TierLog "Domaine : $($domainInfo.DnsRoot) ($($domainInfo.DistinguishedName))" -Level OK
    Write-TierLog "OU Admins=$($domainInfo.AdminRootOU) | Servers=$($domainInfo.ServerRootOU) | Groups=$($domainInfo.GroupRootOU)" -Level INFO

    Set-TierContext -Context @{
        Config = $config; Accounts = $accounts; Servers = $servers
        Domain = $domainInfo; OutputFolder = $outDir
    }

    if ($UpdateInputCsv) {
        Write-TierLog 'Mise a jour des CSV (domaine + nomenclature)' -Level STEP
        Update-TierInputCsv -AccountsPath $AccountsCsv -ServersPath $ServersCsv
        # Recharge apres reecriture.
        $accounts = @(Import-Csv -Path $AccountsCsv -Delimiter ';')
        $servers  = @(Import-Csv -Path $ServersCsv -Delimiter ';')
        Set-TierContext -Context @{
            Config = $config; Accounts = $accounts; Servers = $servers
            Domain = $domainInfo; OutputFolder = $outDir
        }
    }

    # --- Filtrage SkipServerMove ---
    if ($SkipServerMove) { $catalog = @($catalog | Where-Object { $_.id -ne 'TIER-MOVE-001' }) }

    Write-TierLog "$($catalog.Count) phase(s) chargee(s)." -Level OK

    # =====================================================================
    # ROLLBACK : annule les phases reversibles (PSO, GPO). Les phases
    # marquees reversible=false (OU/groupes/comptes) sont conservees.
    # =====================================================================
    if ($Rollback) {
        Write-TierLog 'MODE ROLLBACK' -Level STEP
        $rollbackResults = foreach ($task in $catalog) {
            $r = Invoke-TieringRollback -Task $task
            $lvl = switch ($r.Status) { 'RolledBack' { 'OK' } 'Error' { 'ERROR' } default { 'WARN' } }
            Write-TierLog ("[{0}] {1} - {2}" -f $r.Status, $task.id, $task.name) -Level $lvl
            $r
        }
        $rollbackResults | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $outDir 'rollback_results.json') -Encoding UTF8
        Write-TierLog "Rollback termine. Sorties : $outDir" -Level OK
        return
    }

    # --- Execution des phases ---
    Write-TierLog 'Execution des phases de tiering' -Level STEP
    $results = New-Object System.Collections.Generic.List[psobject]
    foreach ($task in $catalog) {
        $r = Invoke-TieringTask -Task $task -DryRun:$DryRun
        $results.Add($r)
        $lvl = switch ($r.Status) {
            'Applied' { 'OK' } 'AlreadyCompliant' { 'OK' } 'Error' { 'ERROR' }
            'AppliedButNotVerified' { 'WARN' } default { 'INFO' }
        }
        Write-TierLog ("[{0}] {1} - {2}" -f $r.Status, $task.id, $task.name) -Level $lvl
    }

    # --- Exports + rapport ---
    Write-TierLog 'Generation des rapports' -Level STEP
    $passwords = Get-TierGeneratedPasswords
    $matrix    = Get-TierServerAccessMatrix

    Export-TieringRun -Results $results.ToArray() -DomainInfo $domainInfo `
        -Passwords $passwords -AccessMatrix $matrix -OutputFolder $outDir -DryRun:$DryRun | Out-Null

    $reportPath = Join-Path $outDir 'report.html'
    New-TieringReport -Results $results.ToArray() -DomainInfo $domainInfo `
        -AccessMatrix $matrix -OutputPath $reportPath -DryRun:$DryRun | Out-Null

    if ($passwords.Count -gt 0 -and -not $DryRun) {
        Write-TierLog "Mots de passe initiaux exportes (A PROTEGER) : $(Join-Path $outDir 'admin_passwords.csv')" -Level WARN
    }
    Write-TierLog "Rapport : $reportPath" -Level OK
    Write-TierLog "Termine. Sorties dans : $outDir" -Level OK
    Write-Host "`nCommandes utiles : gpupdate /force ; gpresult /r /scope computer" -ForegroundColor DarkGray
}
catch {
    Write-Host "`nERREUR : $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    Stop-Transcript | Out-Null
}
