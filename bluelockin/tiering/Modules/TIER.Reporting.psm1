#Requires -Version 5.1
<#
.SYNOPSIS
    TIER.Reporting - Rapport HTML et exports (JSON / CSV) du run Tiering.
#>

function New-TieringReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)]$DomainInfo,
        [object[]]$AccessMatrix = @(),
        [Parameter(Mandatory)][string]$OutputPath,
        [switch]$DryRun
    )

    $statusColor = {
        param($s)
        switch -Wildcard ($s) {
            'Applied'                { 'background:#1e7e34;color:#fff' }
            'AlreadyCompliant'       { 'background:#155724;color:#fff' }
            'WouldApply'             { 'background:#856404;color:#fff' }
            'AppliedButNotVerified'  { 'background:#b8860b;color:#fff' }
            'RolledBack'             { 'background:#0c5460;color:#fff' }
            'Skipped*'               { 'background:#6c757d;color:#fff' }
            'Error'                  { 'background:#a71d2a;color:#fff' }
            default                  { 'background:#343a40;color:#fff' }
        }
    }

    $rows = ($Results | ForEach-Object {
        $st = & $statusColor $_.Status
        "<tr><td>$($_.TaskId)</td><td>$($_.Name)</td><td>$($_.Category)</td><td><span style='padding:2px 8px;border-radius:4px;$st'>$($_.Status)</span></td><td>$($_.Message)</td></tr>"
    }) -join "`n"

    $matrixRows = ($AccessMatrix | ForEach-Object {
        "<tr><td>$($_.NomServeur)</td><td>$($_.NiveauTiering)</td><td>$($_.RoleServeur)</td><td>$($_.GroupeLocalAdminAD)</td><td>$($_.GroupeAdminAutorise)</td></tr>"
    }) -join "`n"

    $mode = if ($DryRun) { "<b style='color:#856404'>SIMULATION (DryRun)</b>" } else { "Execution reelle" }
    $applied = @($Results | Where-Object { $_.Status -in @('Applied', 'AlreadyCompliant') }).Count
    $errors = @($Results | Where-Object { $_.Status -eq 'Error' }).Count

    $html = @"
<!DOCTYPE html><html lang='fr'><head><meta charset='utf-8'><title>Rapport Tiering AD - BlueLock</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222;background:#f5f6f8}
h1{color:#0b5394}.card{display:inline-block;background:#fff;border:1px solid #ddd;border-radius:8px;padding:14px 20px;margin:6px}
table{border-collapse:collapse;width:100%;background:#fff;margin-top:10px}
th,td{border:1px solid #ddd;padding:7px 10px;text-align:left;font-size:14px}th{background:#0b5394;color:#fff}
.meta{color:#555;font-size:13px}
</style></head><body>
<h1>Rapport Tiering Active Directory - BlueLock</h1>
<p class='meta'>Domaine : <b>$($DomainInfo.DnsRoot)</b> ($($DomainInfo.DistinguishedName))<br>
Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp; Mode : $mode</p>
<div class='card'><b>$($Results.Count)</b><br>phases</div>
<div class='card'><b>$applied</b><br>OK / deja conforme</div>
<div class='card'><b>$errors</b><br>erreurs</div>
<h2>Phases executees</h2>
<table><tr><th>ID</th><th>Phase</th><th>Categorie</th><th>Statut</th><th>Message</th></tr>
$rows
</table>
<h2>Matrice d'acces serveurs</h2>
<table><tr><th>Serveur</th><th>Tier</th><th>Role</th><th>Groupe admin local (AD)</th><th>Groupe autorise</th></tr>
$matrixRows
</table>
<p class='meta'>Genere par BlueLock - tiering. Modele Tier 0/1/2 avec cloisonnement deny-logon cross-tier.</p>
</body></html>
"@
    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    return $OutputPath
}

function Export-TieringRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)]$DomainInfo,
        [object[]]$Passwords = @(),
        [object[]]$AccessMatrix = @(),
        [Parameter(Mandatory)][string]$OutputFolder,
        [switch]$DryRun
    )
    $summary = [pscustomobject]@{
        Date     = (Get-Date).ToString('o')
        DryRun   = [bool]$DryRun
        Domain   = $DomainInfo.DnsRoot
        DomainDN = $DomainInfo.DistinguishedName
        Phases   = $Results
    }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $OutputFolder 'tiering_run.json') -Encoding UTF8
    $Results | Export-Csv -Path (Join-Path $OutputFolder 'tiering_phases.csv') -Delimiter ';' -NoTypeInformation -Encoding UTF8
    if ($AccessMatrix.Count -gt 0) {
        $AccessMatrix | Export-Csv -Path (Join-Path $OutputFolder 'access_matrix.csv') -Delimiter ';' -NoTypeInformation -Encoding UTF8
    }
    if ($Passwords.Count -gt 0 -and -not $DryRun) {
        # ATTENTION : contient les mots de passe initiaux en clair. Dossier a proteger / supprimer apres remise.
        $Passwords | Export-Csv -Path (Join-Path $OutputFolder 'admin_passwords.csv') -Delimiter ';' -NoTypeInformation -Encoding UTF8
    }
}
