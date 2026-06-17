#Requires -Version 5.1
<#
.SYNOPSIS
    HAD.RiskRegister - Validation des exclusions justifiees (risques acceptes) et generation du registre.
.DESCRIPTION
    Une exclusion = une mesure que l'organisation choisit de NE PAS appliquer, avec une
    justification formelle (qui, quand, pourquoi). Le fichier est valide strictement :
    toute exclusion incomplete arrete le traitement. Les dates de revue depassees sont
    signalees (ou bloquantes en mode -StrictReview).
#>

function Import-ExclusionFile {
    <#
    .SYNOPSIS
        Charge et valide le fichier d'exclusions. Retourne la liste des exclusions valides.
    .PARAMETER Path
        Chemin du fichier exclusions.json.
    .PARAMETER KnownMeasureIds
        Identifiants de mesures connus du catalogue (pour valider les references).
    .PARAMETER SkippableIds
        Identifiants de mesures marquees canBeSkipped=true. Une exclusion ciblant une
        mesure non listee ici est rejetee.
    .PARAMETER StrictReview
        Si present, une exclusion dont reviewDate est depassee provoque une erreur.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$KnownMeasureIds,
        [string[]]$SkippableIds,
        [switch]$StrictReview
    )

    $MinJustLen = 20
    $RequiredFields = @('measureId', 'justification', 'acceptedBy', 'acceptedDate')

    if (-not (Test-Path $Path)) {
        Write-Verbose "Aucun fichier d'exclusions ($Path). Toutes les mesures seront appliquees."
        return @()
    }

    try {
        $data = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Fichier d'exclusions illisible (JSON invalide) : $($_.Exception.Message)"
    }

    if (-not $data.exclusions) { return @() }

    $errors = @()
    $validated = @()
    $today = Get-Date

    foreach ($ex in $data.exclusions) {
        $ctx = if ($ex.measureId) { $ex.measureId } else { '(measureId manquant)' }

        # 1. Champs obligatoires
        foreach ($field in $RequiredFields) {
            if ([string]::IsNullOrWhiteSpace([string]$ex.$field)) {
                $errors += "[$ctx] Champ obligatoire manquant ou vide : $field"
            }
        }

        # 2. Justification suffisamment etayee
        if ($ex.justification -and $ex.justification.Trim().Length -lt $MinJustLen) {
            $errors += "[$ctx] Justification trop courte (min $MinJustLen caracteres)."
        }

        # 3. acceptedDate au format date valide
        $parsedAccepted = [datetime]::MinValue
        if ($ex.acceptedDate -and -not [datetime]::TryParse([string]$ex.acceptedDate, [ref]$parsedAccepted)) {
            $errors += "[$ctx] acceptedDate invalide (format attendu yyyy-MM-dd) : $($ex.acceptedDate)"
        }

        # 4. measureId existe dans le catalogue
        $known = $ex.measureId -and ($KnownMeasureIds -contains $ex.measureId)
        if ($ex.measureId -and -not $known) {
            $errors += "[$ctx] measureId inconnu : ne correspond a aucune mesure du catalogue."
        }

        # 5. La mesure doit etre exclubale (canBeSkipped)
        if ($known -and $PSBoundParameters.ContainsKey('SkippableIds') -and ($SkippableIds -notcontains $ex.measureId)) {
            $errors += "[$ctx] Cette mesure est marquee non-exclubale (canBeSkipped=false) et ne peut etre acceptee comme risque."
        }

        # 6. reviewDate depassee -> avertissement ou erreur (StrictReview)
        $reviewExpired = $false
        if ($ex.reviewDate) {
            $parsedReview = [datetime]::MinValue
            if ([datetime]::TryParse([string]$ex.reviewDate, [ref]$parsedReview)) {
                if ($parsedReview -lt $today) {
                    $reviewExpired = $true
                    $msg = "[$ctx] Date de revue depassee ($($ex.reviewDate)) : le risque accepte doit etre re-evalue."
                    if ($StrictReview) { $errors += $msg }
                    else { Write-Warning $msg }
                }
            }
            else {
                $errors += "[$ctx] reviewDate invalide (format attendu yyyy-MM-dd) : $($ex.reviewDate)"
            }
        }

        if ($known) {
            $validated += [pscustomobject]@{
                MeasureId     = $ex.measureId
                Justification = $ex.justification
                AcceptedBy    = $ex.acceptedBy
                AcceptedDate  = $ex.acceptedDate
                ReviewDate    = $ex.reviewDate
                ReviewExpired = $reviewExpired
            }
        }
    }

    if ($errors.Count -gt 0) {
        throw ("Validation des exclusions echouee :`n - " + ($errors -join "`n - "))
    }

    Write-Verbose "$($validated.Count) exclusion(s) validee(s)."
    return $validated
}

function New-RiskRegister {
    <#
    .SYNOPSIS
        Construit le registre des risques acceptes et l'ecrit en JSON.
    #>
    [CmdletBinding()]
    param(
        [psobject[]]$Exclusions,
        [Parameter(Mandatory)][psobject[]]$Catalog,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $entries = foreach ($ex in $Exclusions) {
        $measure = $Catalog | Where-Object { $_.id -eq $ex.MeasureId } | Select-Object -First 1
        [pscustomobject]@{
            MeasureId     = $ex.MeasureId
            MeasureName   = $measure.name
            Category      = $measure.category
            Severity      = $measure.severity
            Status        = 'Skipped - Risk Accepted'
            Justification = $ex.Justification
            AcceptedBy    = $ex.AcceptedBy
            AcceptedDate  = $ex.AcceptedDate
            ReviewDate    = $ex.ReviewDate
            ReviewExpired = [bool]$ex.ReviewExpired
        }
    }
    $entries = @($entries)

    $register = [pscustomobject]@{
        GeneratedAt   = (Get-Date).ToString('o')
        Operator      = "$env:USERDOMAIN\$env:USERNAME"
        Hostname      = $env:COMPUTERNAME
        AcceptedRisks = $entries
        TotalAccepted = $entries.Count
        ExpiredCount  = @($entries | Where-Object { $_.ReviewExpired }).Count
    }

    $register | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Verbose "Registre des risques ecrit : $OutputPath"
    return $register
}
