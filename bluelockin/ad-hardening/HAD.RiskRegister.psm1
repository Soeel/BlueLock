#Requires -Version 5.1
<#
.SYNOPSIS
    HAD.RiskRegister - Validation des exclusions justifiees (risques acceptes).
.DESCRIPTION
    Mode non-interactif : charge un fichier d'exclusions pre-rempli, valide que chaque
    exclusion comporte les champs obligatoires, et produit le registre des risques
    accepte horodate pour preuve d'audit. Aucune exclusion non justifiee n'est toleree.
#>

$script:MinJustificationLength = 20
$script:RequiredFields = @('measureId', 'justification', 'acceptedBy', 'acceptedDate')

function Import-ExclusionFile {
    <#
    .SYNOPSIS
        Charge et VALIDE le fichier d'exclusions. Leve une exception si une exclusion
        est incomplete ou mal justifiee. Le but : impossible de desactiver une mesure
        sans justification formelle.
    .PARAMETER Path
        Chemin du fichier exclusions.json.
    .PARAMETER KnownMeasureIds
        Liste des IDs de mesures valides (issus du catalogue) pour detecter les fautes de frappe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$KnownMeasureIds
    )

    if (-not (Test-Path $Path)) {
        Write-Verbose "Aucun fichier d'exclusions ($Path). Toutes les mesures seront appliquees."
        return @()
    }

    try {
        $data = Get-Content -Path $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Fichier d'exclusions illisible (JSON invalide) : $($_.Exception.Message)"
    }

    if (-not $data.exclusions) { return @() }

    $errors = New-Object System.Collections.Generic.List[string]
    $validated = New-Object System.Collections.Generic.List[psobject]

    foreach ($ex in $data.exclusions) {
        $ctx = if ($ex.measureId) { $ex.measureId } else { '(measureId manquant)' }

        # 1. Champs obligatoires
        foreach ($field in $script:RequiredFields) {
            if ([string]::IsNullOrWhiteSpace($ex.$field)) {
                $errors.Add("[$ctx] Champ obligatoire manquant ou vide : '$field'.")
            }
        }

        # 2. Justification suffisamment etayee
        if (-not [string]::IsNullOrWhiteSpace($ex.justification) -and
            $ex.justification.Trim().Length -lt $script:MinJustificationLength) {
            $errors.Add("[$ctx] Justification trop courte (min $script:MinJustificationLength caracteres).")
        }

        # 3. measureId existe reellement dans le catalogue
        if ($ex.measureId -and $ex.measureId -notin $KnownMeasureIds) {
            $errors.Add("[$ctx] measureId inconnu : ne correspond a aucune mesure du catalogue.")
        }

        # 4. Date valide
        if ($ex.acceptedDate) {
            [datetime]$parsed = [datetime]::MinValue
            if (-not [datetime]::TryParse($ex.acceptedDate, [ref]$parsed)) {
                $errors.Add("[$ctx] acceptedDate n'est pas une date valide : '$($ex.acceptedDate)'.")
            }
        }

        if ($errors.Count -eq 0 -or $ex.measureId -in $KnownMeasureIds) {
            $validated.Add([pscustomobject]@{
                MeasureId     = $ex.measureId
                Justification = $ex.justification
                AcceptedBy    = $ex.acceptedBy
                AcceptedDate  = $ex.acceptedDate
                ReviewDate    = $ex.reviewDate
            })
        }
    }

    if ($errors.Count -gt 0) {
        $msg = "Validation des exclusions echouee. Le hardening est interrompu pour eviter une desactivation non justifiee :`n - " +
               ($errors -join "`n - ")
        throw $msg
    }

    Write-Verbose "$($validated.Count) exclusion(s) validee(s)."
    return $validated.ToArray()
}

function New-RiskRegister {
    <#
    .SYNOPSIS
        Produit le registre des risques accepte final, horodate, pour archivage/audit.
    .PARAMETER Exclusions
        Exclusions validees (issues de Import-ExclusionFile).
    .PARAMETER Catalog
        Catalogue complet (pour enrichir avec severite/categorie de chaque mesure).
    .PARAMETER OutputPath
        Chemin de sortie du registre JSON.
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
        }
    }

    $register = [pscustomobject]@{
        GeneratedAt    = (Get-Date).ToString('o')
        Operator       = "$env:USERDOMAIN\$env:USERNAME"
        Hostname       = $env:COMPUTERNAME
        AcceptedRisks  = @($entries)
        TotalAccepted  = @($entries).Count
    }

    $register | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Verbose "Registre des risques ecrit : $OutputPath"
    return $register
}

