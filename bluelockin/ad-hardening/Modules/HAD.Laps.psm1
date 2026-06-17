#Requires -Version 5.1
<#
.SYNOPSIS
    HAD.Laps - Deploiement de Windows LAPS (natif), pilote par GPO.
.DESCRIPTION
    Windows LAPS (integre aux versions recentes de Windows, sans agent a installer)
    fait tourner et sauvegarde dans AD le mot de passe de l'administrateur LOCAL de
    chaque machine. Cela supprime la reutilisation de mot de passe admin local entre
    machines (mouvement lateral), un risque que PingCastle penalise.

    Le deploiement se fait en 4 etapes, dont une IRREVERSIBLE :
      1. Prerequis : cmdlets Windows LAPS presentes.
      2. Extension de schema (Update-LapsADSchema) - forest-wide, UNIQUE, IRREVERSIBLE,
         requiert Schema Admins. N'est tentee QUE si -ConfirmSchemaExtension est fourni.
      3. Permissions : Set-LapsADComputerSelfPermission sur l'OU des machines (chaque
         machine ecrit son propre mot de passe).
      4. GPO LAPS : BackupDirectory=AD + longueur/age/complexite, liee a l'OU.

    Reutilise le backend GPO (module HAD.Gpo) pour la creation/lien de GPO. Le rollback
    supprime la GPO LAPS ; le schema etendu n'est jamais annule (impossible).
#>

# Cle de strategie Windows LAPS (cote ordinateur).
$script:LapsPolicyKey = 'HKLM\Software\Microsoft\Policies\LAPS'

function Test-HADLapsModule {
    <# .SYNOPSIS Retourne $true si les cmdlets Windows LAPS sont disponibles. #>
    [CmdletBinding()] param()
    return [bool](Get-Command -Name 'Update-LapsADSchema' -ErrorAction SilentlyContinue)
}

function Test-HADLapsSchema {
    <# .SYNOPSIS Retourne $true si le schema AD a ete etendu pour Windows LAPS. #>
    [CmdletBinding()] param()
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $schemaNC = (Get-ADRootDSE -ErrorAction Stop).schemaNamingContext
        $attr = Get-ADObject -SearchBase $schemaNC -LDAPFilter '(lDAPDisplayName=msLAPS-PasswordExpirationTime)' -ErrorAction Stop
        return ($null -ne $attr)
    }
    catch { return $false }
}

function Get-HADLapsReadiness {
    <# .SYNOPSIS Diagnostic de preparation LAPS (module + schema). #>
    [CmdletBinding()] param()
    $module = Test-HADLapsModule
    return [pscustomobject]@{
        LapsModuleAvailable = $module
        SchemaExtended      = if ($module) { Test-HADLapsSchema } else { $false }
    }
}

function Invoke-HADLapsSchemaUpdate {
    <# .SYNOPSIS Etend le schema AD pour Windows LAPS (IRREVERSIBLE, Schema Admins). #>
    [CmdletBinding(SupportsShouldProcess)] param()
    Import-Module LAPS -ErrorAction Stop
    if ($PSCmdlet.ShouldProcess('Schema AD (foret)', 'Update-LapsADSchema')) {
        Update-LapsADSchema -Confirm:$false -ErrorAction Stop | Out-Null
    }
}

function Set-HADLapsPermission {
    <# .SYNOPSIS Accorde aux machines de l'OU le droit d'ecrire leur mot de passe LAPS. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ComputersOU)
    Import-Module LAPS -ErrorAction Stop
    if ($PSCmdlet.ShouldProcess($ComputersOU, 'Set-LapsADComputerSelfPermission')) {
        Set-LapsADComputerSelfPermission -Identity $ComputersOU -ErrorAction Stop | Out-Null
    }
}

function Set-HADLapsGpo {
    <# .SYNOPSIS Cree/configure la GPO LAPS (sauvegarde vers AD) et la lie a l'OU. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)][string]$Target,
        [int]$PasswordLength = 20,
        [int]$PasswordAgeDays = 30,
        [int]$PasswordComplexity = 4,
        [int]$EncryptionEnabled = 1
    )
    New-HADHardeningGpo -Name $GpoName | Out-Null
    # 2 = Active Directory (1 = Azure AD, 0 = desactive).
    Set-HADGpoRegistryValue -GpoName $GpoName -Key $script:LapsPolicyKey -ValueName 'BackupDirectory' -Type DWord -Value 2
    Set-HADGpoRegistryValue -GpoName $GpoName -Key $script:LapsPolicyKey -ValueName 'PasswordLength' -Type DWord -Value $PasswordLength
    Set-HADGpoRegistryValue -GpoName $GpoName -Key $script:LapsPolicyKey -ValueName 'PasswordAgeDays' -Type DWord -Value $PasswordAgeDays
    # 4 = majuscules + minuscules + chiffres + caracteres speciaux.
    Set-HADGpoRegistryValue -GpoName $GpoName -Key $script:LapsPolicyKey -ValueName 'PasswordComplexity' -Type DWord -Value $PasswordComplexity
    # Chiffrement du mot de passe dans AD (requiert DFL >= 2016).
    Set-HADGpoRegistryValue -GpoName $GpoName -Key $script:LapsPolicyKey -ValueName 'ADPasswordEncryptionEnabled' -Type DWord -Value $EncryptionEnabled
    Add-HADGpoLink -GpoName $GpoName -Target $Target
}

function Test-HADLapsGpo {
    <# .SYNOPSIS Retourne $true si la GPO LAPS sauvegarde bien vers AD (BackupDirectory=2). #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$GpoName)
    return (Test-HADGpoRegistryValue -GpoName $GpoName -Key $script:LapsPolicyKey -ValueName 'BackupDirectory' -Value 2)
}

function Enable-HADLaps {
    <#
    .SYNOPSIS
        Orchestre le deploiement Windows LAPS et retourne un journal d'etapes.
    .PARAMETER ConfirmSchemaExtension
        Autorise l'extension de schema (IRREVERSIBLE). Sans ce switch, l'etape schema
        est BLOQUEE si le schema n'est pas deja etendu.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ComputersOU,
        [string]$GpoName = 'BlueLock - Windows LAPS',
        [switch]$ConfirmSchemaExtension,
        [int]$PasswordLength = 20,
        [int]$PasswordAgeDays = 30,
        [int]$PasswordComplexity = 4,
        [int]$EncryptionEnabled = 1,
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[psobject]
    function Add-Step {
        param([string]$Stage, [string]$Status, [string]$Message)
        $steps.Add([pscustomobject]@{ Stage = $Stage; Status = $Status; Message = $Message })
    }

    # 1. Prerequis
    if (-not (Test-HADLapsModule)) {
        Add-Step 'Module' 'Error' 'Cmdlets Windows LAPS introuvables. Requiert un Windows recent et patche (post avril 2023).'
        return $steps.ToArray()
    }
    Add-Step 'Module' 'OK' 'Cmdlets Windows LAPS disponibles.'

    # 2. Schema (IRREVERSIBLE)
    if (Test-HADLapsSchema) {
        Add-Step 'Schema' 'AlreadyCompliant' 'Schema deja etendu pour Windows LAPS.'
    }
    elseif (-not $ConfirmSchemaExtension) {
        Add-Step 'Schema' 'Blocked' "Schema non etendu. Operation IRREVERSIBLE forest-wide : relancez avec -ConfirmSchemaExtension (Schema Admins requis)."
        return $steps.ToArray()
    }
    elseif ($DryRun) {
        Add-Step 'Schema' 'WouldApply' '[DryRun] Update-LapsADSchema serait execute.'
    }
    else {
        try { Invoke-HADLapsSchemaUpdate; Add-Step 'Schema' 'Applied' 'Schema etendu (Update-LapsADSchema).' }
        catch { Add-Step 'Schema' 'Error' $_.Exception.Message; return $steps.ToArray() }
    }

    # 3. Permissions (self-permission des machines de l'OU)
    if ($DryRun) {
        Add-Step 'Permission' 'WouldApply' "[DryRun] Set-LapsADComputerSelfPermission sur $ComputersOU."
    }
    else {
        try { Set-HADLapsPermission -ComputersOU $ComputersOU; Add-Step 'Permission' 'Applied' "Self-permission accordee sur $ComputersOU." }
        catch { Add-Step 'Permission' 'Error' $_.Exception.Message; return $steps.ToArray() }
    }

    # 4. GPO LAPS
    if ($DryRun) {
        Add-Step 'Gpo' 'WouldApply' "[DryRun] GPO '$GpoName' (sauvegarde vers AD) liee a $ComputersOU."
    }
    else {
        try {
            Set-HADLapsGpo -GpoName $GpoName -Target $ComputersOU -PasswordLength $PasswordLength `
                -PasswordAgeDays $PasswordAgeDays -PasswordComplexity $PasswordComplexity -EncryptionEnabled $EncryptionEnabled
            $ok = Test-HADLapsGpo -GpoName $GpoName
            Add-Step 'Gpo' $(if ($ok) { 'Applied' } else { 'AppliedButNotVerified' }) "GPO '$GpoName' configuree et liee a $ComputersOU."
        }
        catch { Add-Step 'Gpo' 'Error' $_.Exception.Message }
    }

    return $steps.ToArray()
}

function Remove-HADLapsGpo {
    <# .SYNOPSIS Rollback LAPS : supprime la GPO LAPS (le schema reste, irreversible). #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$GpoName = 'BlueLock - Windows LAPS')
    Remove-HADHardeningGpo -Name $GpoName
}
