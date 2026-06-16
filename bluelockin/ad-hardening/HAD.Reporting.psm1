#Requires -Version 5.1
<#
.SYNOPSIS
    HAD.Reporting - Genere le rapport comparatif final (HTML) avant/apres hardening.
#>

function New-HardeningReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$ScoreBefore,
        [Parameter(Mandatory)][psobject]$ScoreAfter,
        [Parameter(Mandatory)][psobject]$Comparison,
        [Parameter(Mandatory)][psobject[]]$AppliedResults,
        [Parameter(Mandatory)][psobject]$RiskRegister,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $css = @'
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1e2327;background:#fafafa}
h1{border-bottom:3px solid #0a6;padding-bottom:6px}
h2{margin-top:32px;color:#0a6}
table{border-collapse:collapse;width:100%;margin:12px 0;background:#fff}
th,td{border:1px solid #ddd;padding:8px 10px;text-align:left;font-size:14px}
th{background:#0a6;color:#fff}
.up{color:#c00;font-weight:bold}.down{color:#0a6;font-weight:bold}.same{color:#888}
.risk{background:#fff7e6}
.badge{padding:2px 8px;border-radius:4px;color:#fff;font-size:12px}
.High{background:#c0392b}.Medium{background:#e67e22}.Low{background:#27ae60}
.ok{color:#0a6}.err{color:#c00}.skip{color:#e67e22}
</style>
'@

    $scoreRows = foreach ($k in $Comparison.ScoreDelta.Keys) {
        $d = $Comparison.ScoreDelta[$k]
        $cls = if ($d.Delta -lt 0) { 'down' } elseif ($d.Delta -gt 0) { 'up' } else { 'same' }
        $sign = if ($d.Delta -gt 0) { "+$($d.Delta)" } else { "$($d.Delta)" }
        "<tr><td>$k</td><td>$($d.Before)</td><td>$($d.After)</td><td class='$cls'>$sign</td></tr>"
    }

    $appliedRows = foreach ($r in $AppliedResults) {
        $cls = switch ($r.Status) {
            'Applied' { 'ok' }; 'AlreadyCompliant' { 'ok' }
            'Error' { 'err' }; default { 'skip' }
        }
        "<tr><td>$($r.MeasureId)</td><td>$($r.Name)</td><td class='$cls'>$($r.Status)</td><td>$($r.Message)</td></tr>"
    }

    $riskRows = foreach ($e in $RiskRegister.AcceptedRisks) {
        "<tr class='risk'><td>$($e.MeasureId)</td><td>$($e.MeasureName)</td><td><span class='badge $($e.Severity)'>$($e.Severity)</span></td><td>$($e.Justification)</td><td>$($e.AcceptedBy)</td><td>$($e.AcceptedDate)</td><td>$($e.ReviewDate)</td></tr>"
    }

    $resolved = ($Comparison.ResolvedRules -join ', ')
    $newOnes  = ($Comparison.NewRules -join ', ')

    $html = @"
<!DOCTYPE html><html lang='fr'><head><meta charset='utf-8'>$css<title>Rapport Hardening AD</title></head><body>
<h1>Rapport de Hardening Active Directory</h1>
<p><b>Domaine :</b> $($ScoreAfter.Domain) &nbsp;|&nbsp; <b>Operateur :</b> $($RiskRegister.Operator) &nbsp;|&nbsp; <b>Genere le :</b> $($RiskRegister.GeneratedAt)</p>

<h2>1. Score PingCastle (avant / apres)</h2>
<table><tr><th>Categorie</th><th>Avant</th><th>Apres</th><th>Delta</th></tr>
$($scoreRows -join "`n")
</table>
<p><b>Regles resolues :</b> $resolved</p>
<p><b>Nouvelles regles apparues :</b> $newOnes</p>

<h2>2. Mesures appliquees</h2>
<table><tr><th>ID</th><th>Mesure</th><th>Statut</th><th>Detail</th></tr>
$($appliedRows -join "`n")
</table>

<h2>3. Registre des risques acceptes ($($RiskRegister.TotalAccepted))</h2>
<table><tr><th>ID</th><th>Mesure</th><th>Severite</th><th>Justification</th><th>Accepte par</th><th>Date</th><th>Revue</th></tr>
$($riskRows -join "`n")
</table>
</body></html>
"@

    $html | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Verbose "Rapport HTML genere : $OutputPath"
    return $OutputPath
}

