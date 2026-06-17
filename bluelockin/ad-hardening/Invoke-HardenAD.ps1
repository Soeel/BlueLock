#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Invoke-HardenAD - Orchestrateur de hardening AD avec scoring PingCastle avant/apres.

.DESCRIPTION
    Inspire de l'architecture config-driven du projet HardenAD (LoicVeirman/HardenAD).
    Pipeline :
      1. Pre-verifications (admin, role DC, module AD, PingCastle)
      2. Scan PingCastle baseline (avant)
      3. Validation des exclusions justifiees (risques acceptes)
      4. Application des mesures retenues (test -> apply -> verify)
      5. Scan PingCastle post-hardening (apres)
      6. Rapports : HTML comparatif + JSON + CSV, registre des risques, sauvegarde registre

    Le TIERING (comptes Tier0/1/2, OU, groupes, GPO de tiering) est gere par un script
    SEPARE execute AVANT et n'est PAS traite ici.

.PARAMETER PingCastlePath
    Chemin vers PingCastle.exe.

.PARAMETER ConfigPath
    Catalogue de mesures (auto-detecte : Configs\hardening-tasks.json ou a plat).

.PARAMETER ExclusionPath
    Fichier d'exclusions (auto-detecte : Configs\exclusions.json ou a plat).

.PARAMETER Server
    DC cible pour PingCastle (par defaut : domaine courant).

.PARAMETER DeployVia
    'Local' (defaut) : les mesures de type registre modifient le registre LOCAL de la machine.
    'Gpo'            : ces mesures sont deployees dans une GPO dediee, liee a l'OU des
                       controleurs de domaine (ou -GpoTarget). Elles s'appliquent alors a
                       TOUS les DC et persistent. Les mesures niveau domaine/foret/service
                       (MAQ, delegation, corbeille, services...) restent appliquees en direct.

.PARAMETER GpoName
    Nom de la GPO de hardening en mode -DeployVia Gpo (defaut : 'BlueLock - AD Hardening').

.PARAMETER GpoTarget
    DN de l'OU/domaine auquel lier la GPO (defaut : OU des controleurs de domaine).

.PARAMETER EnableLaps
    Deploie Windows LAPS (etape dediee) : permissions + GPO LAPS sur -LapsComputersOU.
    L'extension de schema (IRREVERSIBLE) n'est tentee qu'avec -ConfirmSchemaExtension.

.PARAMETER ConfirmSchemaExtension
    Autorise l'extension IRREVERSIBLE du schema AD pour Windows LAPS (Schema Admins).

.PARAMETER LapsComputersOU
    DN de l'OU des machines a gerer par LAPS (obligatoire avec -EnableLaps).

.PARAMETER LapsGpoName
    Nom de la GPO LAPS (defaut : 'BlueLock - Windows LAPS').

.PARAMETER LapsPasswordLength / LapsPasswordAgeDays / LapsPasswordComplexity
    Parametres du mot de passe LAPS (defauts : 20 caracteres, 30 jours, complexite 4).

.PARAMETER DryRun
    Simulation : aucune modification appliquee.

.PARAMETER Rollback
    Annule UNIQUEMENT les mesures reellement appliquees lors d'un run precedent
    (restauration exacte des valeurs de registre depuis registry_backup.json).

.PARAMETER RestoreFrom
    Dossier de run a annuler (ex : Outputs\20260616-110719). Par defaut, le dernier
    run disposant d'un run_summary.json est utilise automatiquement.

.PARAMETER StrictReview
    Une exclusion dont la date de revue est depassee devient bloquante (erreur).

.PARAMETER RequireDomainController
    Rend bloquante l'absence de role controleur de domaine.

.PARAMETER SkipBaselineScan / SkipFinalScan
    Permet de sauter un scan PingCastle (utile en test).

.EXAMPLE
    .\Invoke-HardenAD.ps1 -PingCastlePath .\PingCastle.exe -DryRun

.EXAMPLE
    .\Invoke-HardenAD.ps1 -PingCastlePath .\PingCastle.exe -RequireDomainController

.EXAMPLE
    .\Invoke-HardenAD.ps1 -PingCastlePath .\PingCastle.exe -Rollback

.EXAMPLE
    .\Invoke-HardenAD.ps1 -PingCastlePath .\PingCastle.exe -DeployVia Gpo

.EXAMPLE
    .\Invoke-HardenAD.ps1 -PingCastlePath .\PingCastle.exe -DeployVia Gpo -Rollback
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PingCastlePath,
    [string]$ConfigPath,
    [string]$ExclusionPath,
    [string]$Server,
    [ValidateSet('Local', 'Gpo')][string]$DeployVia = 'Local',
    [string]$GpoName = 'BlueLock - AD Hardening',
    [string]$GpoTarget,
    [switch]$EnableLaps,
    [switch]$ConfirmSchemaExtension,
    [string]$LapsComputersOU,
    [string]$LapsGpoName = 'BlueLock - Windows LAPS',
    [int]$LapsPasswordLength = 20,
    [int]$LapsPasswordAgeDays = 30,
    [ValidateRange(1, 4)][int]$LapsPasswordComplexity = 4,
    [switch]$DryRun,
    [switch]$Rollback,
    [string]$RestoreFrom,
    [switch]$StrictReview,
    [switch]$RequireDomainController,
    [switch]$SkipBaselineScan,
    [switch]$SkipFinalScan
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# --- Cherche un fichier a plat ou en sous-dossier ---
function Find-ProjectFile {
    param([string]$FileName, [string]$SubDir)
    if ($SubDir) {
        $nested = Join-Path (Join-Path $root $SubDir) $FileName
        if (Test-Path $nested) { return (Resolve-Path $nested).Path }
    }
    $flat = Join-Path $root $FileName
    if (Test-Path $flat) { return (Resolve-Path $flat).Path }
    return $null
}

# --- Repertoires de sortie ---
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $root "Outputs\$stamp"
$logDir = Join-Path $root 'Logs'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$transcript    = Join-Path $logDir "harden-$stamp.log"
$structuredLog = Join-Path $logDir "harden-$stamp.struct.log"
Start-Transcript -Path $transcript -Force | Out-Null

Write-Host "Racine du projet : $root" -ForegroundColor DarkGray

try {
    # --- Chargement des modules via Import-Module ---
    # On utilise Import-Module et NON le dot-sourcing : dot-sourcer un .psm1 peut n'avoir
    # aucun effet visible (pas d'exception) sans publier les fonctions. Import-Module est
    # fiable et, sans Export-ModuleMember, exporte automatiquement toutes les fonctions.
    Write-Host "`n=== Initialisation ===" -ForegroundColor Cyan
    $moduleFiles = @(
        'HAD.Common.psm1',
        'HAD.PingCastle.psm1',
        'HAD.RiskRegister.psm1',
        'HAD.Hardening.psm1',
        'HAD.Gpo.psm1',
        'HAD.Laps.psm1',
        'HAD.Reporting.psm1'
    )
    foreach ($mod in $moduleFiles) {
        $modPath = Find-ProjectFile $mod 'Modules'
        if (-not $modPath) {
            throw "Module introuvable : $mod`nCherche dans :`n  - $root\Modules\$mod`n  - $root\$mod"
        }
        try {
            Import-Module $modPath -Force -DisableNameChecking -Global -ErrorAction Stop
            Write-Host "  [OK] $mod" -ForegroundColor DarkGray
        }
        catch {
            Write-Host "  [FAIL] $mod : $($_.Exception.Message)" -ForegroundColor Red
            throw "Echec du chargement de $mod. Verifiez la syntaxe du fichier."
        }
    }

    $requiredFunctions = @(
        'Write-HADLog', 'Test-HardeningPrerequisites',
        'Invoke-PingCastleScan', 'ConvertFrom-PingCastleReport', 'Compare-PingCastleScoring',
        'Import-ExclusionFile', 'New-RiskRegister',
        'Invoke-HardeningTask', 'Invoke-HardeningRollback', 'Get-HADRegistryBackup',
        'Set-HADGpoMeasure', 'Get-HADGpoBackup', 'Remove-HADHardeningGpo',
        'Enable-HADLaps', 'Remove-HADLapsGpo',
        'New-HardeningReport', 'Export-HardeningRun'
    )
    foreach ($fn in $requiredFunctions) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
            throw "Fonction '$fn' introuvable apres chargement des modules. Un module a probablement echoue silencieusement."
        }
    }

    # Active le logging fichier structure des modules (fichier distinct du transcript,
    # qui est garde ouvert par Start-Transcript).
    Initialize-HADLog -Path $structuredLog

    # --- Pre-verifications ---
    Write-HADLog 'Pre-verifications environnement' -Level STEP
    $pre = Test-HardeningPrerequisites -PingCastlePath $PingCastlePath -RequireDomainController:$RequireDomainController
    foreach ($name in $pre.Checks.Keys) {
        $c = $pre.Checks[$name]
        $lvl = if ($c.Passed) { 'OK' } elseif ($c.Blocking) { 'ERROR' } else { 'WARN' }
        Write-HADLog ("{0} : {1}" -f $name, $c.Detail) -Level $lvl
    }
    if ($pre.BlockingFailures -gt 0) {
        throw "Pre-verifications bloquantes en echec ($($pre.BlockingFailures)). Corrigez avant de continuer."
    }

    # --- Auto-detection des configs ---
    if (-not $ConfigPath)    { $ConfigPath    = Find-ProjectFile 'hardening-tasks.json' 'Configs' }
    if (-not $ExclusionPath) { $ExclusionPath = Find-ProjectFile 'exclusions.json'      'Configs' }
    if (-not $ConfigPath -or -not (Test-Path $ConfigPath)) {
        throw "Catalogue introuvable (hardening-tasks.json). Cherche dans : $root\Configs et $root"
    }

    $catalog  = @((Get-Content $ConfigPath -Raw | ConvertFrom-Json).tasks)
    $knownIds = @($catalog.id)
    $skipIds  = @(($catalog | Where-Object { $_.canBeSkipped }).id)
    Write-HADLog "$($catalog.Count) mesure(s) chargee(s) depuis le catalogue." -Level OK

    # --- Mode de deploiement ---
    if ($DeployVia -eq 'Gpo') {
        if (-not $Rollback -and -not $GpoTarget) {
            try { $GpoTarget = Get-HADDomainControllersOU }
            catch { throw "Mode GPO : impossible de resoudre l'OU des controleurs de domaine. Precisez -GpoTarget. ($($_.Exception.Message))" }
        }
        $gpoCount = @($catalog | Where-Object { $_.gpo }).Count
        $targetTxt = if ($GpoTarget) { " -> $GpoTarget" } else { '' }
        Write-HADLog "Mode de deploiement : GPO '$GpoName'$targetTxt. $gpoCount mesure(s) deployable(s) par GPO; les autres restent en application directe." -Level INFO
        # Mesures qui ciblent une GPO distincte (audit/PSLOG -> 'BlueLock - Audit & Logging').
        $altGpos = @($catalog | Where-Object { $_.gpo -and $_.gpo.gpoName -and $_.gpo.gpoName -ne $GpoName } |
                     Group-Object { $_.gpo.gpoName })
        foreach ($g in $altGpos) {
            $tgt = ($g.Group[0].gpo.target); if ($tgt -eq '@DomainRoot') { $tgt = '<racine du domaine>' }
            Write-HADLog "  + GPO '$($g.Name)' (liee a $tgt) : $($g.Count) mesure(s) [$(($g.Group.id) -join ', ')]" -Level INFO
        }
    }
    else {
        Write-HADLog 'Mode de deploiement : registre LOCAL.' -Level INFO
    }

    # Validation precoce LAPS (echec rapide avant les scans).
    if ($EnableLaps -and -not $Rollback -and -not $LapsComputersOU) {
        throw "LAPS : precisez -LapsComputersOU (DN de l'OU des machines a gerer)."
    }

    # --- Validation des exclusions (risques acceptes) ---
    Write-HADLog 'Validation des exclusions (risques acceptes)' -Level STEP
    if (-not $ExclusionPath -or -not (Test-Path $ExclusionPath)) {
        Write-HADLog "Aucun fichier d'exclusions. Toutes les mesures seront traitees." -Level WARN
        $exclusions = @()
    }
    else {
        $exclusions = @(Import-ExclusionFile -Path $ExclusionPath -KnownMeasureIds $knownIds -SkippableIds $skipIds -StrictReview:$StrictReview)
    }
    $excludedIds = @($exclusions.MeasureId)
    $exclLevel = if ($excludedIds.Count) { 'WARN' } else { 'OK' }
    Write-HADLog "$($excludedIds.Count) mesure(s) exclue(s) avec justification." -Level $exclLevel

    $riskRegisterPath = Join-Path $outDir 'risk_register.json'
    $riskRegister = New-RiskRegister -Exclusions $exclusions -Catalog $catalog -OutputPath $riskRegisterPath

    # =====================================================================
    # MODE ROLLBACK : annule UNIQUEMENT ce qui a ete reellement applique lors
    # d'un run precedent, puis sort. On ne touche pas aux mesures qui etaient
    # deja conformes avant le hardening (ex : ne PAS reactiver SMBv1).
    # =====================================================================
    if ($Rollback) {
        Write-HADLog 'MODE ROLLBACK - annulation ciblee' -Level STEP

        # Rollback LAPS : suppression de la GPO LAPS. Le schema etendu et les permissions
        # ne sont PAS annules (le schema est irreversible). Operation distincte : on sort.
        if ($EnableLaps) {
            Write-HADLog "Rollback LAPS : suppression de la GPO '$LapsGpoName'. Schema et permissions conserves (schema irreversible)." -Level WARN
            Remove-HADLapsGpo -GpoName $LapsGpoName
            Write-HADLog "GPO LAPS '$LapsGpoName' supprimee si elle existait." -Level OK
            return
        }

        # Rollback GPO : on supprime simplement la GPO (delie + supprime). Restauration
        # propre, sans toucher au registre local. On ne rejoue PAS les rollbackFunction
        # locales (elles ecriraient dans le registre de la machine).
        if ($DeployVia -eq 'Gpo') {
            # Collecte toutes les GPO referencees par le catalogue (defaut + per-measure
            # gpo.gpoName), pour gerer les mesures qui visent une GPO distincte (audit,
            # PSLOG -> 'BlueLock - Audit & Logging' liee a la racine du domaine).
            $gpoNames = New-Object System.Collections.Generic.HashSet[string]
            [void]$gpoNames.Add($GpoName)
            foreach ($t in $catalog) {
                if ($t.gpo -and $t.gpo.gpoName) { [void]$gpoNames.Add($t.gpo.gpoName) }
            }
            Write-HADLog "Rollback GPO : suppression de $($gpoNames.Count) GPO(s)." -Level INFO
            foreach ($g in $gpoNames) {
                Remove-HADHardeningGpo -Name $g
                Write-HADLog "GPO '$g' supprimee si elle existait (liens inclus)." -Level OK
            }
            return
        }

        # 1. Localiser le run a annuler : -RestoreFrom, sinon dernier run avec run_summary.json.
        $sourceDir = $null
        if ($RestoreFrom) {
            $sourceDir = if (Test-Path (Join-Path $RestoreFrom 'run_summary.json')) { (Resolve-Path $RestoreFrom).Path }
                         elseif (Test-Path $RestoreFrom) { Split-Path (Resolve-Path $RestoreFrom).Path -Parent }
                         else { $null }
            if (-not $sourceDir) { throw "Aucun run_summary.json trouve sous -RestoreFrom : $RestoreFrom" }
        }
        else {
            $outRoot = Join-Path $root 'Outputs'
            if (Test-Path $outRoot) {
                $sourceDir = Get-ChildItem -Path $outRoot -Directory |
                    Where-Object { $_.FullName -ne $outDir -and (Test-Path (Join-Path $_.FullName 'run_summary.json')) } |
                    Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }
            }
        }

        $rollbackResults = New-Object System.Collections.Generic.List[psobject]

        if ($sourceDir) {
            Write-HADLog "Run cible : $sourceDir" -Level INFO
            $summary    = Get-Content (Join-Path $sourceDir 'run_summary.json') -Raw | ConvertFrom-Json
            $appliedIds = @($summary.Measures | Where-Object { $_.Status -eq 'Applied' } | ForEach-Object { $_.MeasureId })
            Write-HADLog "$($appliedIds.Count) mesure(s) reellement appliquee(s) a annuler." -Level INFO

            # 1b. Recharger les etats AD sauvegardes pour que les rollback bases sur l'etat
            #     (pre-auth, Protected Users) fonctionnent dans ce run distinct.
            $stateBackupFile = Join-Path $sourceDir 'state_backup.json'
            if (Test-Path $stateBackupFile) {
                $sb = @(Get-Content $stateBackupFile -Raw | ConvertFrom-Json)
                if ($sb.Count -gt 0) {
                    Import-HADStateBackup -Backup $sb
                    Write-HADLog "Etats AD recharges pour rollback ($($sb.Count) entree(s))." -Level INFO
                }
            }

            # 2. Annuler les mesures appliquees (les fonctions registre seront ecrasees
            #    juste apres par la restauration exacte).
            foreach ($task in $catalog) {
                if ($task.id -notin $appliedIds -or $task.id -in $excludedIds) { continue }
                $r = Invoke-HardeningRollback -Task $task
                $rollbackResults.Add($r)
                $lvl = switch ($r.Status) { 'RolledBack' { 'OK' } 'Error' { 'ERROR' } default { 'WARN' } }
                Write-HADLog ("[{0}] {1} - {2}" -f $r.Status, $task.id, $task.name) -Level $lvl
            }

            # 3. Restauration EXACTE des valeurs de registre sauvegardees lors du run cible.
            $regBackupFile = Join-Path $sourceDir 'registry_backup.json'
            if (Test-Path $regBackupFile) {
                $backup = @(Get-Content $regBackupFile -Raw | ConvertFrom-Json)
                Restore-HADRegistryBackup -Backup $backup
                Write-HADLog "Valeurs de registre restaurees a l'identique ($($backup.Count) entree(s))." -Level OK
            }
        }
        else {
            # Aucun run precedent identifie : repli sur un rollback large (valeurs sures par defaut).
            Write-HADLog "Aucun run precedent trouve. Repli : rollback de toutes les mesures non exclues (valeurs par defaut)." -Level WARN
            foreach ($task in $catalog) {
                if ($task.id -in $excludedIds) { continue }
                $r = Invoke-HardeningRollback -Task $task
                $rollbackResults.Add($r)
                $lvl = switch ($r.Status) { 'RolledBack' { 'OK' } 'Error' { 'ERROR' } default { 'WARN' } }
                Write-HADLog ("[{0}] {1} - {2}" -f $r.Status, $task.id, $task.name) -Level $lvl
            }
        }

        $rbPath = Join-Path $outDir 'rollback_results.json'
        $rollbackResults.ToArray() | ConvertTo-Json -Depth 6 | Set-Content -Path $rbPath -Encoding UTF8
        Write-HADLog "Rollback termine. Resultats : $rbPath" -Level OK
        return
    }

    # --- Scan baseline ---
    $scoreBefore = $null
    if (-not $SkipBaselineScan) {
        Write-HADLog 'Scan PingCastle baseline (avant)' -Level STEP
        $xmlBefore = Invoke-PingCastleScan -PingCastlePath $PingCastlePath -OutputDirectory $outDir -Label before -Server $Server
        $scoreBefore = ConvertFrom-PingCastleReport -XmlPath $xmlBefore
        Write-HADLog "Score global avant : $($scoreBefore.GlobalScore)" -Level OK
    }
    else {
        Write-HADLog 'Scan baseline saute (-SkipBaselineScan).' -Level WARN
    }

    # --- Application des mesures ---
    Write-HADLog 'Application des mesures' -Level STEP
    $appliedResults = New-Object System.Collections.Generic.List[psobject]
    foreach ($task in $catalog) {
        if ($task.id -in $excludedIds) {
            $appliedResults.Add([pscustomobject]@{
                MeasureId = $task.id; Name = $task.name; Category = $task.category
                Severity = $task.severity; Status = 'Skipped - Risk Accepted'
                Message = 'Exclue via registre des risques.'; RebootRequired = $false
            })
            Write-HADLog ("[SKIP] {0} - {1}" -f $task.id, $task.name) -Level WARN
            continue
        }
        $r = Invoke-HardeningTask -Task $task -DryRun:$DryRun -DeployVia $DeployVia -GpoName $GpoName -GpoTarget $GpoTarget
        $appliedResults.Add($r)
        $lvl = switch ($r.Status) { 'Applied' { 'OK' } 'AlreadyCompliant' { 'OK' } 'Error' { 'ERROR' } 'AppliedButNotVerified' { 'WARN' } default { 'INFO' } }
        $via = if ($r.DeployedVia -eq 'Gpo') { ' (GPO)' } else { '' }
        Write-HADLog ("[{0}] {1} - {2}{3}" -f $r.Status, $task.id, $task.name, $via) -Level $lvl
    }

    # --- Sauvegarde des valeurs de registre modifiees ---
    $regBackup = Get-HADRegistryBackup
    if ($regBackup.Count -gt 0) {
        $regBackupPath = Join-Path $outDir 'registry_backup.json'
        $regBackup | ConvertTo-Json -Depth 6 | Set-Content -Path $regBackupPath -Encoding UTF8
        Write-HADLog "Sauvegarde registre : $regBackupPath ($($regBackup.Count) valeur(s))." -Level OK
    }

    # --- Deploiement Windows LAPS (etape dediee, opt-in) ---
    if ($EnableLaps) {
        Write-HADLog 'Deploiement Windows LAPS' -Level STEP
        $lapsSteps = @(Enable-HADLaps -ComputersOU $LapsComputersOU -GpoName $LapsGpoName `
                -ConfirmSchemaExtension:$ConfirmSchemaExtension `
                -PasswordLength $LapsPasswordLength -PasswordAgeDays $LapsPasswordAgeDays `
                -PasswordComplexity $LapsPasswordComplexity -DryRun:$DryRun)
        foreach ($s in $lapsSteps) {
            $lvl = switch ($s.Status) {
                'Applied'               { 'OK' }
                'AlreadyCompliant'      { 'OK' }
                'Error'                 { 'ERROR' }
                'Blocked'               { 'WARN' }
                'AppliedButNotVerified' { 'WARN' }
                default                 { 'INFO' }
            }
            Write-HADLog ("LAPS [{0}] {1} - {2}" -f $s.Status, $s.Stage, $s.Message) -Level $lvl
        }
        $lapsPath = Join-Path $outDir 'laps_deployment.json'
        $lapsSteps | ConvertTo-Json -Depth 6 | Set-Content -Path $lapsPath -Encoding UTF8
        Write-HADLog "Journal LAPS : $lapsPath" -Level OK
    }

    # --- Sauvegarde du journal des operations GPO (mode -DeployVia Gpo ou LAPS) ---
    if ($DeployVia -eq 'Gpo' -or $EnableLaps) {
        $gpoBackup = Get-HADGpoBackup
        if ($gpoBackup.Count -gt 0) {
            $gpoBackupPath = Join-Path $outDir 'gpo_backup.json'
            $gpoBackup | ConvertTo-Json -Depth 6 | Set-Content -Path $gpoBackupPath -Encoding UTF8
            Write-HADLog "Journal GPO : $gpoBackupPath ($($gpoBackup.Count) operation(s))." -Level OK
        }
    }

    # --- Sauvegarde des etats AD modifies (politiques, attributs annuaire) ---
    $stateBackup = Get-HADStateBackup
    if ($stateBackup.Count -gt 0) {
        $stateBackupPath = Join-Path $outDir 'state_backup.json'
        $stateBackup | ConvertTo-Json -Depth 6 | Set-Content -Path $stateBackupPath -Encoding UTF8
        Write-HADLog "Sauvegarde etat AD : $stateBackupPath ($($stateBackup.Count) entree(s))." -Level OK
    }

    # --- Reboot requis ? ---
    $rebootNeeded = @($appliedResults | Where-Object { $_.Status -eq 'Applied' -and $_.RebootRequired })
    if ($rebootNeeded.Count -gt 0) {
        Write-HADLog "Redemarrage requis pour : $(( $rebootNeeded.MeasureId ) -join ', ')" -Level WARN
    }

    # --- Scan final ---
    $scoreAfter = $null
    if (-not $SkipFinalScan -and -not $DryRun) {
        Write-HADLog 'Scan PingCastle post-hardening (apres)' -Level STEP
        $xmlAfter = Invoke-PingCastleScan -PingCastlePath $PingCastlePath -OutputDirectory $outDir -Label after -Server $Server
        $scoreAfter = ConvertFrom-PingCastleReport -XmlPath $xmlAfter
        Write-HADLog "Score global apres : $($scoreAfter.GlobalScore)" -Level OK
    }

    # --- Comparatif + rapports ---
    $comparison = $null
    if ($scoreBefore -and $scoreAfter) {
        $comparison = Compare-PingCastleScoring -Before $scoreBefore -After $scoreAfter
    }

    Write-HADLog 'Generation des rapports' -Level STEP
    $reportPath = Join-Path $outDir 'report.html'
    New-HardeningReport -ScoreBefore $scoreBefore -ScoreAfter $scoreAfter -Comparison $comparison `
        -AppliedResults $appliedResults.ToArray() -RiskRegister $riskRegister `
        -OutputPath $reportPath -DryRun:$DryRun | Out-Null

    Export-HardeningRun -AppliedResults $appliedResults.ToArray() -RiskRegister $riskRegister `
        -ScoreBefore $scoreBefore -ScoreAfter $scoreAfter -Comparison $comparison `
        -JsonPath (Join-Path $outDir 'run_summary.json') -CsvPath (Join-Path $outDir 'measures.csv') `
        -DryRun:$DryRun | Out-Null

    Write-HADLog "Rapport HTML : $reportPath" -Level OK
    Write-HADLog "Termine. Sorties dans : $outDir" -Level OK
}
catch {
    Write-Host "`nERREUR : $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    Stop-Transcript | Out-Null
}
