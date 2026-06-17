#Requires -Version 5.1
<#
.SYNOPSIS
    HAD.Gpo - Backend de deploiement par GPO (alternative au registre local).
.DESCRIPTION
    Au lieu de modifier le registre LOCAL d'un seul controleur de domaine, ce backend
    deploie les mesures de hardening de type "valeur de registre" dans une GPO dediee,
    liee a l'OU cible (par defaut : OU des controleurs de domaine). Les reglages
    s'appliquent alors a TOUS les DC concernes et PERSISTENT (rafraichissement GPO).

    Le rollback en mode GPO consiste a supprimer la GPO (delier + supprimer) : c'est une
    restauration propre qui ne touche jamais au registre local des machines.

    Necessite le module GroupPolicy (RSAT-GPMC, present sur un DC). L'import de GroupPolicy
    est fait DANS chaque fonction : le module se charge donc meme si GroupPolicy est absent,
    et l'absence se manifeste a l'execution (erreur par mesure) plutot qu'au chargement.
#>

# Journal des operations GPO de la session (pour trace / rollback eventuel).
$script:GpoBackup = New-Object System.Collections.Generic.List[object]

function Get-HADDomainControllersOU {
    <# .SYNOPSIS Retourne le DN de l'OU par defaut des controleurs de domaine. #>
    [CmdletBinding()] param()
    Import-Module ActiveDirectory -ErrorAction Stop
    return ('OU=Domain Controllers,{0}' -f (Get-ADDomain -ErrorAction Stop).DistinguishedName)
}

function New-HADHardeningGpo {
    <# .SYNOPSIS Cree (si absente) et retourne la GPO de hardening. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name)

    Import-Module GroupPolicy -ErrorAction Stop
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if (-not $gpo) {
        if ($PSCmdlet.ShouldProcess($Name, 'Create GPO')) {
            $gpo = New-GPO -Name $Name -Comment 'Genere par BlueLock ad-hardening. Ne pas editer manuellement.' -ErrorAction Stop
            $script:GpoBackup.Add([pscustomobject]@{
                Action = 'Created'; GpoName = $Name; GpoId = $gpo.Id.Guid
                Timestamp = (Get-Date).ToString('o')
            })
        }
    }
    return $gpo
}

function Set-HADGpoRegistryValue {
    <# .SYNOPSIS Ecrit une valeur de registre dans une GPO (en tracant l'etat precedent). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$ValueName,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String', 'QWord', 'ExpandString', 'Binary', 'MultiString')][string]$Type = 'DWord'
    )
    Import-Module GroupPolicy -ErrorAction Stop

    $existed = $false; $prior = $null
    try {
        $cur = Get-GPRegistryValue -Name $GpoName -Key $Key -ValueName $ValueName -ErrorAction Stop
        if ($null -ne $cur) { $existed = $true; $prior = $cur.Value }
    }
    catch { }

    $script:GpoBackup.Add([pscustomobject]@{
        Action = 'SetValue'; GpoName = $GpoName; Key = $Key; ValueName = $ValueName
        Existed = $existed; PriorValue = $prior; NewValue = $Value; Type = $Type
        Timestamp = (Get-Date).ToString('o')
    })

    Set-GPRegistryValue -Name $GpoName -Key $Key -ValueName $ValueName -Type $Type -Value $Value -ErrorAction Stop | Out-Null
}

function Test-HADGpoRegistryValue {
    <# .SYNOPSIS Retourne $true si la GPO contient la valeur attendue. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$ValueName,
        [Parameter(Mandatory)]$Value
    )
    try {
        Import-Module GroupPolicy -ErrorAction Stop
        $cur = Get-GPRegistryValue -Name $GpoName -Key $Key -ValueName $ValueName -ErrorAction Stop
        return ($null -ne $cur -and "$($cur.Value)" -eq "$Value")
    }
    catch { return $false }
}

function Add-HADGpoLink {
    <# .SYNOPSIS Lie la GPO a la cible (OU/domaine) si elle ne l'est pas deja. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)][string]$Target
    )
    Import-Module GroupPolicy -ErrorAction Stop

    $inheritance = Get-GPInheritance -Target $Target -ErrorAction SilentlyContinue
    $alreadyLinked = $inheritance.GpoLinks | Where-Object { $_.DisplayName -eq $GpoName }
    if (-not $alreadyLinked) {
        if ($PSCmdlet.ShouldProcess("$GpoName -> $Target", 'Link GPO')) {
            New-GPLink -Name $GpoName -Target $Target -LinkEnabled Yes -ErrorAction Stop | Out-Null
            $script:GpoBackup.Add([pscustomobject]@{
                Action = 'Linked'; GpoName = $GpoName; Target = $Target
                Timestamp = (Get-Date).ToString('o')
            })
        }
    }
}

function Get-HADDomainRoot {
    <# .SYNOPSIS Retourne le DN de la racine du domaine. #>
    [CmdletBinding()] param()
    Import-Module ActiveDirectory -ErrorAction Stop
    return (Get-ADDomain -ErrorAction Stop).DistinguishedName
}

# GUID du CSE "Audit Settings" cote client (et de l'outil cote editeur GP).
# Ces deux GUID sont stables Microsoft et doivent etre presents dans
# gPCMachineExtensionNames pour que le client applique l'audit.csv depuis SYSVOL.
$script:AuditCseGuid  = '{F3CCC681-B74C-4060-9F26-CD84525DCA2C}'
$script:AuditToolGuid = '{0F3F3735-573D-9804-99E4-AB2A69BA5FD4}'

function Register-HADAuditCSE {
    <#
    .SYNOPSIS
        Ajoute le CSE "Audit Settings" a gPCMachineExtensionNames de la GPO et conserve
        l'ordre alphabetique (exigence Windows : les blocs CSE doivent etre tries par
        leur premier GUID, sinon le client ignore l'extension).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GpoName)
    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module GroupPolicy -ErrorAction Stop

    $gpo = Get-GPO -Name $GpoName -ErrorAction Stop
    $domainDn = (Get-ADDomain).DistinguishedName
    $gpcDn = "CN={$($gpo.Id.Guid)},CN=Policies,CN=System,$domainDn"
    $cur = (Get-ADObject -Identity $gpcDn -Properties gPCMachineExtensionNames).gPCMachineExtensionNames
    if (-not $cur) { $cur = '' }
    if ($cur -match [regex]::Escape($script:AuditCseGuid)) { return }

    # Decoupe en blocs [{CSE}{Tool}...], ajoute le bloc audit, trie alphabetiquement
    # par la premiere accolade (premier GUID) de chaque bloc.
    $blocks = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($cur, '\[[^\]]+\]')) { $blocks.Add($m.Value) }
    $blocks.Add("[$script:AuditCseGuid$script:AuditToolGuid]")
    $sorted = $blocks | Sort-Object   # tri lexicographique sur les blocs entiers
    $new = -join $sorted
    Set-ADObject -Identity $gpcDn -Replace @{ gPCMachineExtensionNames = $new } -ErrorAction Stop
}

function Set-HADGpoAuditCsv {
    <#
    .SYNOPSIS
        Ecrit audit.csv dans SYSVOL pour la GPO (strategie d'audit avancee) et enregistre
        le CSE Audit. Le bump de version de la GPO sera assure par les Set-GPRegistryValue
        ulterieurs (registry.pol incremente versionNumber / GPT.INI).
    .PARAMETER Subcategories
        Tableau de [pscustomobject]@{ guid; name; value } - value 0..3 (0=None,1=S,2=F,3=S+F).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)][object[]]$Subcategories
    )
    Import-Module GroupPolicy -ErrorAction Stop
    Import-Module ActiveDirectory -ErrorAction Stop

    $gpo = Get-GPO -Name $GpoName -ErrorAction Stop
    $domain = (Get-ADDomain).DNSRoot
    $auditDir = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id.Guid)}\Machine\Microsoft\Windows NT\Audit"
    if (-not (Test-Path -LiteralPath $auditDir)) {
        New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
    }
    $csvPath = Join-Path $auditDir 'audit.csv'

    $header = 'Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting,Setting Value'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($header)
    foreach ($s in $Subcategories) {
        $label = switch ([int]$s.value) {
            0 { 'No Auditing' }
            1 { 'Success' }
            2 { 'Failure' }
            3 { 'Success and Failure' }
            default { 'No Auditing' }
        }
        # Champs (ordre): Machine Name (vide), Policy Target=System, Subcategory, GUID,
        # Inclusion Setting=libelle, Exclusion Setting=vide, Setting Value=numerique.
        $lines.Add((",System,$($s.name),$($s.guid),$label,,$($s.value)"))
    }
    # ASCII volontaire : audit.csv n'admet pas de BOM (Windows refuse parfois UTF8-BOM).
    Set-Content -LiteralPath $csvPath -Value $lines -Encoding ASCII

    Register-HADAuditCSE -GpoName $GpoName

    $script:GpoBackup.Add([pscustomobject]@{
        Action = 'AuditCsv'; GpoName = $GpoName; Path = $csvPath
        Subcategories = $Subcategories.Count
        Timestamp = (Get-Date).ToString('o')
    })
}

function Test-HADGpoAuditCsv {
    <# .SYNOPSIS Verifie qu'audit.csv est present et contient les sous-categories demandees. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)][object[]]$Subcategories
    )
    try {
        Import-Module GroupPolicy -ErrorAction Stop
        Import-Module ActiveDirectory -ErrorAction Stop
        $gpo = Get-GPO -Name $GpoName -ErrorAction Stop
        $domain = (Get-ADDomain).DNSRoot
        $csv = "\\$domain\SYSVOL\$domain\Policies\{$($gpo.Id.Guid)}\Machine\Microsoft\Windows NT\Audit\audit.csv"
        if (-not (Test-Path -LiteralPath $csv)) { return $false }
        $content = Get-Content -LiteralPath $csv -Raw
        foreach ($s in $Subcategories) {
            if ($content -notmatch [regex]::Escape($s.guid)) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Set-HADGpoMeasure {
    <#
    .SYNOPSIS
        Deploie une mesure (bloc 'gpo' du catalogue) dans la GPO : cree la GPO si besoin,
        ecrit toutes ses valeurs, puis lie la GPO a la cible.
    .PARAMETER Gpo
        Bloc 'gpo' issu du catalogue : { key, values:[ { valueName, type, value, [key] } ] }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)]$Gpo,
        [string]$Target
    )
    New-HADHardeningGpo -Name $GpoName | Out-Null
    # audit.csv ECRIT EN PREMIER : le Set-GPRegistryValue qui suit bumpe alors la version
    # de la GPO, ce qui force le client a recharger SYSVOL (incluant le nouvel audit.csv).
    if ($Gpo.auditCsv) {
        Set-HADGpoAuditCsv -GpoName $GpoName -Subcategories $Gpo.auditCsv
    }
    foreach ($v in $Gpo.values) {
        $key  = if ($v.key)  { $v.key }  else { $Gpo.key }
        $type = if ($v.type) { $v.type } else { 'DWord' }
        Set-HADGpoRegistryValue -GpoName $GpoName -Key $key -ValueName $v.valueName -Type $type -Value $v.value
    }
    if ($Target) { Add-HADGpoLink -GpoName $GpoName -Target $Target }
}

function Test-HADGpoMeasure {
    <# .SYNOPSIS Retourne $true si TOUTES les valeurs du bloc 'gpo' sont presentes dans la GPO. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)]$Gpo
    )
    foreach ($v in $Gpo.values) {
        $key = if ($v.key) { $v.key } else { $Gpo.key }
        if (-not (Test-HADGpoRegistryValue -GpoName $GpoName -Key $key -ValueName $v.valueName -Value $v.value)) {
            return $false
        }
    }
    if ($Gpo.auditCsv) {
        if (-not (Test-HADGpoAuditCsv -GpoName $GpoName -Subcategories $Gpo.auditCsv)) {
            return $false
        }
    }
    return $true
}

function Get-HADGpoBackup {
    <# .SYNOPSIS Retourne le journal des operations GPO de la session. #>
    [CmdletBinding()] param()
    return $script:GpoBackup.ToArray()
}

function Remove-HADHardeningGpo {
    <#
    .SYNOPSIS
        Rollback GPO : supprime la GPO (delie automatiquement tous ses liens).
        N'affecte jamais le registre local des machines.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name)

    Import-Module GroupPolicy -ErrorAction Stop
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if ($gpo -and $PSCmdlet.ShouldProcess($Name, 'Remove GPO (unlink + delete)')) {
        Remove-GPO -Name $Name -ErrorAction Stop | Out-Null
    }
}
