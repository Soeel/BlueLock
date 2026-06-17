#Requires -Version 5.1
<#
.SYNOPSIS
    HAD.PingCastle - Wrapper d'execution PingCastle et parsing des resultats XML.
.DESCRIPTION
    Lance PingCastle en mode healthcheck et extrait le score global et par categorie
    pour produire un objet de scoring comparable avant/apres hardening.
#>

function Test-PingCastleAvailable {
    <#
    .SYNOPSIS
        Verifie la presence de PingCastle.exe et retourne sa version si possible.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PingCastlePath)

    if (-not (Test-Path $PingCastlePath)) { return $null }
    try {
        return (Get-Item $PingCastlePath).VersionInfo.ProductVersion
    }
    catch {
        return 'inconnue'
    }
}

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
    .PARAMETER Server
        (Optionnel) DC cible. Par defaut PingCastle interroge le domaine courant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PingCastlePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][ValidateSet('before', 'after')][string]$Label,
        [string]$Server
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
    $arguments = @('--healthcheck', '--no-enum-limit', '--level', 'Full')
    if ($Server) { $arguments += @('--server', $Server) }

    # Horodatage de reference pour ne capturer que le XML genere par CE scan.
    $sentinel = Get-Date

    $proc = Start-Process -FilePath $PingCastlePath -ArgumentList $arguments `
        -WorkingDirectory $OutputDirectory -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Warning "PingCastle s'est termine avec le code $($proc.ExitCode)."
    }

    # Recupere le XML le plus recent genere apres le lancement
    $xml = Get-ChildItem -Path $OutputDirectory -Filter 'ad_hc_*.xml' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $sentinel.AddSeconds(-5) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $xml) {
        # Repli : prend le plus recent meme sans filtre temporel (cas horloge/permissions).
        $xml = Get-ChildItem -Path $OutputDirectory -Filter 'ad_hc_*.xml' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if (-not $xml) {
        throw "Aucun rapport XML PingCastle genere dans $OutputDirectory. Verifiez les droits et la connectivite au domaine."
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
    param([Parameter(Mandatory)][string]$XmlPath)

    if (-not (Test-Path $XmlPath)) {
        throw "Rapport XML introuvable : $XmlPath"
    }

    [xml]$report = Get-Content -Path $XmlPath -Raw
    $hc = $report.HealthcheckData
    if (-not $hc) {
        throw "Format XML PingCastle inattendu (element HealthcheckData absent) : $XmlPath"
    }

    # Conversion robuste en entier (gere les valeurs absentes/non numeriques).
    function ConvertTo-IntOrZero($v) {
        $out = 0
        if ([int]::TryParse([string]$v, [ref]$out)) { return $out }
        return 0
    }

    $scoring = [pscustomobject]@{
        Domain            = [string]$hc.DomainFQDN
        GenerationDate    = [string]$hc.GenerationDate
        EngineVersion     = [string]$hc.EngineVersion
        GlobalScore       = ConvertTo-IntOrZero $hc.GlobalScore
        StaleObjectsScore = ConvertTo-IntOrZero $hc.StaleObjectsScore
        PrivilegedScore   = ConvertTo-IntOrZero $hc.PrivilegiedGroupScore
        TrustScore        = ConvertTo-IntOrZero $hc.TrustScore
        AnomalyScore      = ConvertTo-IntOrZero $hc.AnomalyScore
        MaturityLevel     = ConvertTo-IntOrZero $hc.MaturityLevel
        TriggeredRules    = @()
    }

    if ($hc.RiskRules -and $hc.RiskRules.HealthcheckRiskRule) {
        $scoring.TriggeredRules = foreach ($r in $hc.RiskRules.HealthcheckRiskRule) {
            [pscustomobject]@{
                RiskId    = [string]$r.RiskId
                Category  = [string]$r.Category
                Points    = ConvertTo-IntOrZero $r.Points
                Rationale = [string]$r.Rationale
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

    $beforeIds = @($Before.TriggeredRules.RiskId)
    $afterIds  = @($After.TriggeredRules.RiskId)
    $resolved  = $beforeIds | Where-Object { $_ -and ($_ -notin $afterIds) }
    $new       = $afterIds  | Where-Object { $_ -and ($_ -notin $beforeIds) }

    return [pscustomobject]@{
        ScoreDelta     = $delta
        GlobalImproved = ($After.GlobalScore -lt $Before.GlobalScore)
        ResolvedRules  = @($resolved | Select-Object -Unique)
        NewRules       = @($new | Select-Object -Unique)
    }
}
