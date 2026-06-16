#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Invoke-HardenAD - Orchestrateur de hardening AD avec scoring PingCastle avant/apres.

.DESCRIPTION
    Inspire de l'architecture config-driven du projet HardenAD (LoicVeirman/HardenAD).
    Supporte une structure a plat (tous les fichiers dans le meme dossier) ou en
    sous-dossiers (Configs/ et Modules/).

    Le TIERING est gere par un script SEPARE.

.PARAMETER PingCastlePath
    Chemin vers PingCastle.exe.

.PARAMETER ConfigPath
    Chemin du catalogue de mesures (auto-detecte si absent).

.PARAMETER ExclusionPath
    Chemin du fichier d'exclusions (auto-detecte si absent).

.PARAMETER DryRun
    Simulation : aucune modification appliquee.

.PARAMETER SkipBaselineScan / SkipFinalScan
    Permet de sauter un scan (utile en test).

.EXAMPLE
    .\Invoke-HardenAD.ps1 -PingCastlePath .\PingCastle.exe -DryRun
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

# --- Cherche un fichier a plat ou en sous-dossier ---
function Find-ProjectFile {
    param([string]$FileName, [string]$SubDir)
    $flat = Join-Path $root $FileName
    if (Test-Path $flat) { return (Resolve-Path $flat).Path }
    if ($SubDir) {
        $nested = Join-Path (Join-Path $root $SubDir) $FileName
        if (Test-Path $nested) { return (Resolve-Path $nested).Path }
    }
    return $null
}

# --- Auto-detection des configs ---
if (-not $ConfigPath)    { $ConfigPath    = Find-ProjectFile 'hardening-tasks.json' 'Configs' }
if (-not $ExclusionPath) { $ExclusionPath = Find-ProjectFile 'exclusions.json'      'Configs' }

# --- Repertoires de sortie ---
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir    = Join-Path $root "Outputs\$stamp"
$logDir    = Join-Path $root 'Logs'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$transcript = Join-Path $logDir "harden-$stamp.log"
Start-Transcript -Path $transcript -Force | Out-Null

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

Write-Host "Racine du projet : $root" -ForegroundColor DarkGray

try {
    # --- Chargement des modules par dot-sourcing (plus robuste que Import-Module) ---
    Write-Step 'Initialisation'
    $moduleFiles = @(
        'HAD.PingCastle.psm1',
        'HAD.RiskRegister.psm1',
        'HAD.Hardening.psm1',
        'HAD.Reporting.psm1'
    )
    foreach ($mod in $moduleFiles) {
        $modPath = Find-ProjectFile $mod 'Modules'
        if (-not $modPath) {
            throw "Module introuvable : $mod`nCherche dans :`n  - $root\$mod`n  - $root\Modules\$mod"
        }
        try {
            . $modPath
            Write-Host "  [OK] $mod" -ForegroundColor DarkGray
        }
        catch {
            Write-Host "  [FAIL] $mod : $($_.Exception.Message)" -ForegroundColor Red
            throw "Echec du chargement de $mod. Verifiez la syntaxe du fichier."
        }
    }

    # Verification que les fonctions critiques sont bien chargees
    $requiredFunctions = @('Invoke-PingCastleScan', 'ConvertFrom-PingCastleReport', 'Compare-PingCastleScoring',
                           'Import-ExclusionFile', 'New-RiskRegister',
                           'Invoke-HardeningTask',
                           'New-HardeningReport')
    foreach ($fn in $requiredFunctions) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
            throw "Fonction '$fn' introuvable apres chargement des modules. Un module a probablement echoue silencieusement."
        }
    }
    Write-Host "  Toutes les fonctions critiques OK." -ForegroundColor Green

    # --- Chargement catalogue ---
    if (-not $ConfigPath -or -not (Test-Path $ConfigPath)) {
        throw "Catalogue introuvable (hardening-tasks.json).`nCherche dans : $root et $root\Configs"
    }
    $catalog = (Get-Content $ConfigPath -Raw | ConvertFrom-Json).tasks
    $knownIds = $catalog.id
    Write-Host "$($catalog.Count) mesure(s) chargee(s)." -ForegroundColor Green

    # --- Validation des exclusions ---
    Write-Step 'Validation des exclusions (risques acceptes)'
    if (-not $ExclusionPath -or -not (Test-Path $ExclusionPath)) {
        Write-Host "Aucun fichier d'exclusions trouve. Toutes les mesures seront appliquees." -ForegroundColor Yellow
        $exclusions = @()
    }
    else {
        $exclusions = Import-ExclusionFile -Path $ExclusionPath -KnownMeasureIds $knownIds -Verbose
    }
    $excludedIds = @($exclusions.MeasureId)
    Write-Host "$($excludedIds.Count) mesure(s) exclue(s) avec justification." -ForegroundColor Yellow

    # --- Registre des risques ---
    $riskRegisterPath = Join-Path $outDir 'risk_register.json'
    $riskRegister = New-RiskRegister -Exclusions $exclusions -Catalog $catalog -OutputPath $riskRegisterPath -Verbose

    # --- Scan baseline ---
    $scoreBefore = $null
    if (-not $SkipBaselineScan) {
        Write-Step 'Scan PingCastle baseline (avant)'
        $xmlBefore = Invoke-PingCastleScan -PingCastlePath $PingCastlePath -OutputDirectory $outDir -Label before -Verbose
        $scoreBefore = ConvertFrom-PingCastleReport -XmlPath $xmlBefore
        Write-Host "Score global avant : $($scoreBefore.GlobalScore)" -ForegroundColor Green
    }

    # --- Application des mesures ---
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

    # --- Scan final ---
    $scoreAfter = $null
    if (-not $SkipFinalScan -and -not $DryRun) {
        Write-Step 'Scan PingCastle post-hardening (apres)'
        $xmlAfter = Invoke-PingCastleScan -PingCastlePath $PingCastlePath -OutputDirectory $outDir -Label after -Verbose
        $scoreAfter = ConvertFrom-PingCastleReport -XmlPath $xmlAfter
        Write-Host "Score global apres : $($scoreAfter.GlobalScore)" -ForegroundColor Green
    }

    # --- Rapport ---
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
