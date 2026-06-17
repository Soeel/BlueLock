#Requires -Version 5.1
<#
.SYNOPSIS
    HAD.Reporting - Genere les rapports de hardening : HTML comparatif, JSON et CSV.
#>

function New-HardeningReport {
    <#
    .SYNOPSIS
        Genere le rapport HTML comparatif avant/apres.
    #>
    [CmdletBinding()]
    param(
        [psobject]$ScoreBefore,
        [psobject]$ScoreAfter,
        [psobject]$Comparison,
        [Parameter(Mandatory)][psobject[]]$AppliedResults,
        [Parameter(Mandatory)][psobject]$RiskRegister,
        [Parameter(Mandatory)][string]$OutputPath,
        [switch]$DryRun
    )

    $css = @'
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1e2327;background:#fafafa}
h1{border-bottom:3px solid #0a6;padding-bottom:6px}
h2{margin-top:32px;color:#0a6}
table{border-collapse:collapse;width:100%;margin:12px 0;background:#fff}
th,td{border:1px solid #ddd;padding:8px 10px;text-align:left;font-size:14px;vertical-align:top}
th{background:#0a6;color:#fff}
.up{color:#c00;font-weight:bold}.down{color:#0a6;font-weight:bold}.same{color:#888}
.risk{background:#fff7e6}.expired{background:#ffe6e6}
.badge{padding:2px 8px;border-radius:4px;color:#fff;font-size:12px}
.High{background:#c0392b}.Medium{background:#e67e22}.Low{background:#27ae60}
.ok{color:#0a6;font-weight:bold}.err{color:#c00;font-weight:bold}.skip{color:#e67e22}.warn{color:#b8860b}
.summary{display:flex;gap:16px;flex-wrap:wrap;margin:16px 0}
.card{background:#fff;border:1px solid #ddd;border-radius:8px;padding:16px 20px;min-width:140px}
.card .num{font-size:28px;font-weight:bold}
.banner{padding:10px 14px;border-radius:6px;margin:12px 0;font-weight:bold}
.banner.dry{background:#fff3cd;border:1px solid #ffe69c}
.banner.good{background:#d1e7dd;border:1px solid #a3cfbb}
</style>
'@

    # Bandeau mode
    $banner = if ($DryRun) {
        "<div class='banner dry'>MODE SIMULATION (DryRun) - aucune modification n'a ete appliquee.</div>"
    } elseif ($Comparison -and $Comparison.GlobalImproved) {
        "<div class='banner good'>Score global PingCastle ameliore apres hardening.</div>"
    } else { '' }

    # Cartes de synthese
    $applied   = @($AppliedResults | Where-Object { $_.Status -eq 'Applied' }).Count
    $compliant = @($AppliedResults | Where-Object { $_.Status -eq 'AlreadyCompliant' }).Count
    $errors    = @($AppliedResults | Where-Object { $_.Status -eq 'Error' -or $_.Status -eq 'AppliedButNotVerified' }).Count
    $cards = @"
<div class='summary'>
<div class='card'><div>Mesures appliquees</div><div class='num ok'>$applied</div></div>
<div class='card'><div>Deja conformes</div><div class='num'>$compliant</div></div>
<div class='card'><div>Risques acceptes</div><div class='num skip'>$($RiskRegister.TotalAccepted)</div></div>
<div class='card'><div>Erreurs / a revoir</div><div class='num err'>$errors</div></div>
</div>
"@

    # Section scores (peut etre absente en DryRun)
    $scoreSection = ''
    if ($ScoreBefore -and $ScoreAfter -and $Comparison) {
        $scoreRows = foreach ($k in $Comparison.ScoreDelta.Keys) {
            $d = $Comparison.ScoreDelta[$k]
            $cls = if ($d.Delta -lt 0) { 'down' } elseif ($d.Delta -gt 0) { 'up' } else { 'same' }
            $sign = if ($d.Delta -gt 0) { "+$($d.Delta)" } else { "$($d.Delta)" }
            "<tr><td>$k</td><td>$($d.Before)</td><td>$($d.After)</td><td class='$cls'>$sign</td></tr>"
        }
        $resolved = if ($Comparison.ResolvedRules.Count) { ($Comparison.ResolvedRules -join ', ') } else { '(aucune)' }
        $newOnes  = if ($Comparison.NewRules.Count)      { ($Comparison.NewRules -join ', ') }      else { '(aucune)' }
        $scoreSection = @"
<h2>1. Score PingCastle (avant / apres)</h2>
<p>Echelle PingCastle : <b>plus le score est bas, mieux c'est</b>.</p>
<table><tr><th>Categorie</th><th>Avant</th><th>Apres</th><th>Delta</th></tr>
$($scoreRows -join "`n")
</table>
<p><b>Regles resolues :</b> $resolved</p>
<p><b>Nouvelles regles apparues :</b> $newOnes</p>
"@
    }
    else {
        $scoreSection = "<h2>1. Score PingCastle</h2><p class='warn'>Comparatif non disponible (scan(s) saute(s) ou mode DryRun).</p>"
    }

    $appliedRows = foreach ($r in $AppliedResults) {
        $cls = switch ($r.Status) {
            'Applied'           { 'ok' }
            'AlreadyCompliant'  { 'ok' }
            'Error'             { 'err' }
            'AppliedButNotVerified' { 'warn' }
            default             { 'skip' }
        }
        $sev = if ($r.Severity) { "<span class='badge $($r.Severity)'>$($r.Severity)</span>" } else { '' }
        "<tr><td>$($r.MeasureId)</td><td>$($r.Name)</td><td>$sev</td><td class='$cls'>$($r.Status)</td><td>$($r.Message)</td></tr>"
    }

    $riskRows = foreach ($e in $RiskRegister.AcceptedRisks) {
        $rowCls = if ($e.ReviewExpired) { 'expired' } else { 'risk' }
        $rev = if ($e.ReviewExpired) { "$($e.ReviewDate) <b class='err'>(DEPASSEE)</b>" } else { $e.ReviewDate }
        "<tr class='$rowCls'><td>$($e.MeasureId)</td><td>$($e.MeasureName)</td><td><span class='badge $($e.Severity)'>$($e.Severity)</span></td><td>$($e.Justification)</td><td>$($e.AcceptedBy)</td><td>$($e.AcceptedDate)</td><td>$rev</td></tr>"
    }

    $domain = if ($ScoreAfter) { $ScoreAfter.Domain } elseif ($ScoreBefore) { $ScoreBefore.Domain } else { $RiskRegister.Hostname }

    $html = @"
<!DOCTYPE html><html lang='fr'><head><meta charset='utf-8'>$css<title>Rapport Hardening AD</title></head><body>
<h1>Rapport de Hardening Active Directory</h1>
<p><b>Domaine :</b> $domain &nbsp;|&nbsp; <b>Operateur :</b> $($RiskRegister.Operator) &nbsp;|&nbsp; <b>Genere le :</b> $($RiskRegister.GeneratedAt)</p>
$banner
$cards
$scoreSection

<h2>2. Mesures de hardening</h2>
<table><tr><th>ID</th><th>Mesure</th><th>Severite</th><th>Statut</th><th>Detail</th></tr>
$($appliedRows -join "`n")
</table>

<h2>3. Registre des risques acceptes ($($RiskRegister.TotalAccepted))</h2>
<table><tr><th>ID</th><th>Mesure</th><th>Severite</th><th>Justification</th><th>Accepte par</th><th>Date</th><th>Revue</th></tr>
$($riskRows -join "`n")
</table>

<p style='margin-top:32px;color:#888;font-size:12px'>Rappel : le tiering (comptes Tier0/1/2, OU, groupes, GPO de tiering) est gere par un script separe et n'est pas couvert par ce rapport.</p>
</body></html>
"@

    $html | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Verbose "Rapport HTML genere : $OutputPath"
    return $OutputPath
}

function Export-HardeningRun {
    <#
    .SYNOPSIS
        Exporte un resume machine-readable du run en JSON et la liste des mesures en CSV.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject[]]$AppliedResults,
        [Parameter(Mandatory)][psobject]$RiskRegister,
        [psobject]$ScoreBefore,
        [psobject]$ScoreAfter,
        [psobject]$Comparison,
        [Parameter(Mandatory)][string]$JsonPath,
        [Parameter(Mandatory)][string]$CsvPath,
        [switch]$DryRun
    )

    $summary = [pscustomobject]@{
        GeneratedAt   = (Get-Date).ToString('o')
        Operator      = $RiskRegister.Operator
        Hostname      = $RiskRegister.Hostname
        DryRun        = [bool]$DryRun
        ScoreBefore   = $ScoreBefore
        ScoreAfter    = $ScoreAfter
        Comparison    = $Comparison
        Measures      = $AppliedResults
        AcceptedRisks = $RiskRegister.AcceptedRisks
        Counts        = [pscustomobject]@{
            Applied          = @($AppliedResults | Where-Object { $_.Status -eq 'Applied' }).Count
            AlreadyCompliant = @($AppliedResults | Where-Object { $_.Status -eq 'AlreadyCompliant' }).Count
            Errors           = @($AppliedResults | Where-Object { $_.Status -eq 'Error' }).Count
            AcceptedRisks    = $RiskRegister.TotalAccepted
        }
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $JsonPath -Encoding UTF8
    $AppliedResults |
        Select-Object MeasureId, Name, Category, Severity, Status, RebootRequired, Message |
        Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

    Write-Verbose "Export JSON : $JsonPath ; CSV : $CsvPath"
    return $summary
}
