#Requires -Version 5.1
<#
.SYNOPSIS
    HAD.PingCastle - Wrapper d'execution PingCastle et parsing des resultats XML.
.DESCRIPTION
    Lance PingCastle en mode healthcheck et extrait le score global et par categorie
    pour produire un objet de scoring comparable avant/apres hardening.
#>

function Invoke-PingCastleScan {
    <#
    .SYNOPSIS
        Execute un healthcheck PingCastle et retourne le chemin du rapport XML genere.
    .PARAMETER PingCastlePath
        Chemin complet vers PingCastle.exe.
    .PARAMETER OutputDirectory
        Repertoire ou deposer les rapports.
    .PARAMETER Label
        Etiquette pour nommer le rapport (ex : 'before' ou 'after').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PingCastlePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][ValidateSet('before', 'after')][string]$Label
    )

    if (-not (Test-Path $PingCastlePath)) {
        throw "PingCastle introuvable : $PingCastlePath"
    }
    if (-not (Test-Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    Write-Verbose "Lancement PingCastle healthcheck ($Label)..."

    # PingCastle genere ad_hc_<domain>.xml dans son repertoire de travail.
    # On l'execute depuis OutputDirectory pour recuperer le XML facilement.
    $pcDir = Split-Path $PingCastlePath -Parent
    $arguments = @('--healthcheck', '--no-enum-limit', '--level', 'Full')

    Push-Location $OutputDirectory
    try {
        $proc = Start-Process -FilePath $PingCastlePath -ArgumentList $arguments `
            -WorkingDirectory $OutputDirectory -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Warning "PingCastle s'est termine avec le code $($proc.ExitCode)."
        }
    }
    finally {
        Pop-Location
    }

    # Recupere le XML le plus recent genere par PingCastle
    $xml = Get-ChildItem -Path $OutputDirectory -Filter 'ad_hc_*.xml' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $xml) {
        throw "Aucun rapport XML PingCastle genere dans $OutputDirectory."
    }

    $target = Join-Path $OutputDirectory "pingcastle_$Label.xml"
    Copy-Item $xml.FullName $target -Force
    Write-Verbose "Rapport copie vers $target"
    return $target
}

function ConvertFrom-PingCastleReport {
    <#
    .SYNOPSIS
        Parse un rapport XML PingCastle et retourne un objet de scoring structure.
    .PARAMETER XmlPath
        Chemin du rapport XML PingCastle (ad_hc_*.xml).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$XmlPath
    )

    if (-not (Test-Path $XmlPath)) {
        throw "Rapport XML introuvable : $XmlPath"
    }

    [xml]$report = Get-Content -Path $XmlPath -Raw

    $hc = $report.HealthcheckData

    # Score global et scores par categorie (echelle PingCastle : plus c'est bas, mieux c'est)
    $scoring = [pscustomobject]@{
        Domain               = $hc.DomainFQDN
        GenerationDate       = $hc.GenerationDate
        GlobalScore          = [int]$hc.GlobalScore
        StaleObjectsScore    = [int]$hc.StaleObjectsScore
        PrivilegedScore      = [int]$hc.PrivilegiedGroupScore
        TrustScore           = [int]$hc.TrustScore
        AnomalyScore         = [int]$hc.AnomalyScore
        TriggeredRules       = @()
    }

    # Liste des regles declenchees (RiskRules)
    if ($hc.RiskRules -and $hc.RiskRules.HealthcheckRiskRule) {
        $scoring.TriggeredRules = foreach ($r in $hc.RiskRules.HealthcheckRiskRule) {
            [pscustomobject]@{
                RiskId   = $r.RiskId
                Category = $r.Category
                Points   = [int]$r.Points
                Rationale = $r.Rationale
            }
        }
    }

    return $scoring
}

function Compare-PingCastleScoring {
    <#
    .SYNOPSIS
        Compare deux objets de scoring (before/after) et retourne le differentiel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Before,
        [Parameter(Mandatory)][psobject]$After
    )

    $fields = 'GlobalScore', 'StaleObjectsScore', 'PrivilegedScore', 'TrustScore', 'AnomalyScore'
    $delta = [ordered]@{}
    foreach ($f in $fields) {
        $delta[$f] = [pscustomobject]@{
            Before = $Before.$f
            After  = $After.$f
            Delta  = $After.$f - $Before.$f
        }
    }

    # Regles resolues (presentes avant, absentes apres)
    $beforeIds = $Before.TriggeredRules.RiskId
    $afterIds  = $After.TriggeredRules.RiskId
    $resolved  = $beforeIds | Where-Object { $_ -notin $afterIds }
    $new       = $afterIds  | Where-Object { $_ -notin $beforeIds }

    return [pscustomobject]@{
        ScoreDelta    = $delta
        ResolvedRules = @($resolved)
        NewRules      = @($new)
    }
}

Export-ModuleMember -Function Invoke-PingCastleScan, ConvertFrom-PingCastleReport, Compare-PingCastleScoring
