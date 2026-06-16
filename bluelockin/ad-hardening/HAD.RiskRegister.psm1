<#
.SYNOPSIS
    HAD.RiskRegister - Validation des exclusions justifiees (risques acceptes).
#>

function Import-ExclusionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$KnownMeasureIds
    )

    $MinJustLen = 20
    $RequiredFields = @('measureId', 'justification', 'acceptedBy', 'acceptedDate')

    if (-not (Test-Path $Path)) {
        Write-Verbose "Aucun fichier d exclusions ($Path). Toutes les mesures seront appliquees."
        return @()
    }

    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        $data = $raw | ConvertFrom-Json
    }
    catch {
        throw "Fichier d exclusions illisible (JSON invalide) : $($_.Exception.Message)"
    }

    if (-not $data.exclusions) { return @() }

    $errors = @()
    $validated = @()

    foreach ($ex in $data.exclusions) {
        if ($ex.measureId) { $ctx = $ex.measureId } else { $ctx = '(measureId manquant)' }

        # 1. Champs obligatoires
        foreach ($field in $RequiredFields) {
            $val = $ex.$field
            if (-not $val -or [string]::IsNullOrWhiteSpace($val)) {
                $errors += "[$ctx] Champ obligatoire manquant ou vide : $field"
            }
        }

        # 2. Justification suffisamment etayee
        if ($ex.justification -and $ex.justification.Trim().Length -lt $MinJustLen) {
            $errors += "[$ctx] Justification trop courte (min $MinJustLen caracteres)."
        }

        # 3. measureId existe dans le catalogue
        if ($ex.measureId -and ($KnownMeasureIds -notcontains $ex.measureId)) {
            $errors += "[$ctx] measureId inconnu : ne correspond a aucune mesure du catalogue."
        }

        # 4. Ajout a la liste validee (si pas d erreur pour cette entree)
        if ($ex.measureId -and ($KnownMeasureIds -contains $ex.measureId)) {
            $obj = New-Object PSObject -Property @{
                MeasureId     = $ex.measureId
                Justification = $ex.justification
                AcceptedBy    = $ex.acceptedBy
                AcceptedDate  = $ex.acceptedDate
                ReviewDate    = $ex.reviewDate
            }
            $validated += $obj
        }
    }

    if ($errors.Count -gt 0) {
        $msg = "Validation des exclusions echouee :`n - " + ($errors -join "`n - ")
        throw $msg
    }

    Write-Verbose "$($validated.Count) exclusion(s) validee(s)."
    return $validated
}

function New-RiskRegister {
    [CmdletBinding()]
    param(
        [psobject[]]$Exclusions,
        [Parameter(Mandatory)][psobject[]]$Catalog,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $entries = @()
    foreach ($ex in $Exclusions) {
        $measure = $Catalog | Where-Object { $_.id -eq $ex.MeasureId } | Select-Object -First 1
        $entry = New-Object PSObject -Property @{
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
        $entries += $entry
    }

    $register = New-Object PSObject -Property @{
        GeneratedAt    = (Get-Date).ToString('o')
        Operator       = "$env:USERDOMAIN\$env:USERNAME"
        Hostname       = $env:COMPUTERNAME
        AcceptedRisks  = $entries
        TotalAccepted  = $entries.Count
    }

    $register | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Verbose "Registre des risques ecrit : $OutputPath"
    return $register
}
