#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Invoke-HardenAD - Orchestrateur de hardening AD avec scoring PingCastle avant/apres.

.DESCRIPTION
    Inspire de l'architecture config-driven du projet HardenAD (LoicVeirman/HardenAD).
    Enchaine : scan PingCastle baseline -> validation des exclusions justifiees
    (risques acceptes) -> application des mesures retenues -> scan PingCastle post ->
    rapport comparatif + registre des risques.

    Le TIERING (comptes Tier0/1/2, OU, groupes, GPO, CSV) est gere par un script
    SEPARE et n'est PAS traite ici.

    Les exclusions sont fournies via un FICHIER pre-rempli (mode non-interactif).
    Toute exclusion non justifiee interrompt l'execution.

.PARAMETER PingCastlePath
    Chemin vers PingCastle.exe.

.PARAMETER ConfigPath
    Chemin du catalogue de mesures (defaut : Configs\hardening-tasks.json).

.PARAMETER ExclusionPath
    Chemin du fichier d'exclusions (defaut : Configs\exclusions.json).

.PARAMETER DryRun
    Simulation : aucune modification appliquee (les scans PingCastle restent identiques).

.PARAMETER SkipBaselineScan / SkipFinalScan
    Permet de sauter un scan (utile en test).

.EXAMPLE
    .\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe -DryRun

.EXAMPLE
    .\Invoke-HardenAD.ps1 -PingCastlePath C:\PingCastle\PingCastle.exe
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PingCastlePath,
    [string]$ConfigPath,
    [string]$ExclusionPath,
    [switch]$DryRun,
    [switch]$SkipBaselineScan,
    [switch]$SkipFinalScan
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# Defauts
if (-not $ConfigPath)    { $ConfigPath    = Join-Path $root 'Configs\hardening-tasks.json' }
if (-not $ExclusionPath) { $ExclusionPath = Join-Path $root 'Configs\exclusions.json' }

# Repertoires de sortie horodates
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir    = Join-Path $root "Outputs\$stamp"
$logDir    = Join-Path $root 'Logs'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$transcript = Join-Path $logDir "harden-$stamp.log"
Start-Transcript -Path $transcript -Force | Out-Null

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

try {
    # Import des modules
    Write-Step 'Initialisation'
    Import-Module (Join-Path $root 'Modules\HAD.PingCastle.psm1')   -Force
    Import-Module (Join-Path $root 'Modules\HAD.RiskRegister.psm1') -Force
    Import-Module (Join-Path $root 'Modules\HAD.Hardening.psm1')    -Force
    Import-Module (Join-Path $root 'Modules\HAD.Reporting.psm1')    -Force

    # Chargement catalogue
    if (-not (Test-Path $ConfigPath)) { throw "Catalogue introuvable : $ConfigPath" }
    $catalog = (Get-Content $ConfigPath -Raw | ConvertFrom-Json).tasks
    $knownIds = $catalog.id
    Write-Host "$($catalog.Count) mesure(s) chargee(s)." -ForegroundColor Green

    # Validation des exclusions justifiees (interrompt si non justifie)
    Write-Step 'Validation des exclusions (risques acceptes)'
    $exclusions = Import-ExclusionFile -Path $ExclusionPath -KnownMeasureIds $knownIds -Verbose
    $excludedIds = @($exclusions.MeasureId)
    Write-Host "$($excludedIds.Count) mesure(s) exclue(s) avec justification." -ForegroundColor Yellow

    # Registre des risques
    $riskRegisterPath = Join-Path $outDir 'risk_register.json'
    $riskRegister = New-RiskRegister -Exclusions $exclusions -Catalog $catalog -OutputPath $riskRegisterPath -Verbose

    # Scan baseline
    $scoreBefore = $null
    if (-not $SkipBaselineScan) {
        Write-Step 'Scan PingCastle baseline (avant)'
        $xmlBefore = Invoke-PingCastleScan -PingCastlePath $PingCastlePath -OutputDirectory $outDir -Label before -Verbose
        $scoreBefore = ConvertFrom-PingCastleReport -XmlPath $xmlBefore
        Write-Host "Score global avant : $($scoreBefore.GlobalScore)" -ForegroundColor Green
    }

    # Application des mesures retenues
    Write-Step 'Application des mesures'
    $appliedResults = New-Object System.Collections.Generic.List[psobject]
    foreach ($task in $catalog) {
        if ($task.id -in $excludedIds) {
            $appliedResults.Add([pscustomobject]@{
                MeasureId = $task.id; Name = $task.name
                Status = 'Skipped - Risk Accepted'; Message = 'Exclue via registre des risques.'
            })
            Write-Host " [SKIP] $($task.id) - $($task.name)" -ForegroundColor Yellow
            continue
        }
        $r = Invoke-HardeningTask -Task $task -DryRun:$DryRun
        $appliedResults.Add($r)
        $color = switch ($r.Status) { 'Applied' { 'Green' } 'Error' { 'Red' } default { 'Gray' } }
        Write-Host " [$($r.Status)] $($task.id) - $($task.name)" -ForegroundColor $color
    }

    # Scan final
    $scoreAfter = $null
    if (-not $SkipFinalScan -and -not $DryRun) {
        Write-Step 'Scan PingCastle post-hardening (apres)'
        $xmlAfter = Invoke-PingCastleScan -PingCastlePath $PingCastlePath -OutputDirectory $outDir -Label after -Verbose
        $scoreAfter = ConvertFrom-PingCastleReport -XmlPath $xmlAfter
        Write-Host "Score global apres : $($scoreAfter.GlobalScore)" -ForegroundColor Green
    }

    # Rapport comparatif
    if ($scoreBefore -and $scoreAfter) {
        Write-Step 'Generation du rapport comparatif'
        $comparison = Compare-PingCastleScoring -Before $scoreBefore -After $scoreAfter
        $reportPath = Join-Path $outDir 'report.html'
        New-HardeningReport -ScoreBefore $scoreBefore -ScoreAfter $scoreAfter `
            -Comparison $comparison -AppliedResults $appliedResults.ToArray() `
            -RiskRegister $riskRegister -OutputPath $reportPath -Verbose
        Write-Host "`nRapport : $reportPath" -ForegroundColor Cyan
    }
    else {
        Write-Host "`nRapport comparatif non genere (scan(s) saute(s) ou DryRun)." -ForegroundColor Yellow
    }

    Write-Host "`nTermine. Sorties dans : $outDir" -ForegroundColor Green
}
catch {
    Write-Host "`nERREUR : $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    Stop-Transcript | Out-Null
}
