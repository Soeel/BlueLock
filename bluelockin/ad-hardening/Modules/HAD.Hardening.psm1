#Requires -Version 5.1
<#
.SYNOPSIS
    HAD.Hardening - Moteur d'execution des mesures + implementations apply/rollback/test.
.DESCRIPTION
    Le moteur (Invoke-HardeningTask) appelle dynamiquement la fonction nommee dans le
    catalogue (applyFunction / testFunction / rollbackFunction). Chaque mesure expose :
      - apply    : applique la mesure
      - test     : verifie l'etat (idempotence + verification post-application)
      - rollback : restaure une valeur sure connue

    Les modifications de registre passent par Set-HADRegistryValue qui SAUVEGARDE
    automatiquement la valeur precedente (recuperable via Get-HADRegistryBackup), ce qui
    fournit une trace forensic et permet une restauration exacte (Restore-HADRegistryBackup).

    NOTE : le tiering (comptes Tier0/1/2, OU, groupes, GPO de tiering) est gere par un
    script externe execute AVANT et n'est volontairement PAS traite dans ce module.
#>

#region Sauvegarde registre

# Magasin de sauvegarde des valeurs de registre modifiees durant la session.
$script:RegistryBackup = New-Object System.Collections.Generic.List[object]

function Set-HADRegistryValue {
    <#
    .SYNOPSIS
        Ecrit une valeur de registre en sauvegardant au prealable la valeur precedente.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String', 'QWord', 'MultiString', 'ExpandString', 'Binary')][string]$Type = 'DWord'
    )

    $existed = $false
    $prior = $null
    if (Test-Path $Path) {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $item -and $null -ne $item.$Name) {
            $existed = $true
            $prior = $item.$Name
        }
    }
    else {
        New-Item -Path $Path -Force | Out-Null
    }

    $script:RegistryBackup.Add([pscustomobject]@{
        Path       = $Path
        Name       = $Name
        Existed    = $existed
        PriorValue = $prior
        NewValue   = $Value
        Type       = $Type
        Timestamp  = (Get-Date).ToString('o')
    })

    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Get-HADRegistryBackup {
    <# .SYNOPSIS Retourne les sauvegardes de registre collectees durant la session. #>
    [CmdletBinding()] param()
    return $script:RegistryBackup.ToArray()
}

function Restore-HADRegistryBackup {
    <#
    .SYNOPSIS
        Restaure des valeurs de registre a partir d'un jeu de sauvegardes (ordre inverse).
    .PARAMETER Backup
        Tableau d'objets produits par Get-HADRegistryBackup (ou recharges depuis le JSON).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object[]]$Backup)

    for ($i = $Backup.Count - 1; $i -ge 0; $i--) {
        $b = $Backup[$i]
        if (-not (Test-Path $b.Path)) { continue }
        if ($PSCmdlet.ShouldProcess("$($b.Path)\$($b.Name)", 'Restore registry value')) {
            if ($b.Existed) {
                Set-ItemProperty -Path $b.Path -Name $b.Name -Value $b.PriorValue -Type $b.Type -Force
            }
            else {
                Remove-ItemProperty -Path $b.Path -Name $b.Name -ErrorAction SilentlyContinue
            }
        }
    }
}

#endregion

#region Sauvegarde d'etat (attributs AD / strategies)

# Magasin de sauvegarde des etats non-registre (politiques, attributs annuaire) modifies.
$script:StateBackup = New-Object System.Collections.Generic.List[object]

function Set-HADStateBackup {
    <#
    .SYNOPSIS
        Enregistre la valeur precedente d'un etat AD avant modification (trace / audit).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Item,
        $PriorValue,
        [bool]$Existed = $true
    )
    $script:StateBackup.Add([pscustomobject]@{
        Component  = $Component
        Item       = $Item
        PriorValue = $PriorValue
        Existed    = $Existed
        Timestamp  = (Get-Date).ToString('o')
    })
}

function Get-HADStateBackup {
    <# .SYNOPSIS Retourne les sauvegardes d'etat AD collectees durant la session. #>
    [CmdletBinding()] param()
    return $script:StateBackup.ToArray()
}

function Import-HADStateBackup {
    <#
    .SYNOPSIS
        Recharge des sauvegardes d'etat AD (depuis state_backup.json) dans le magasin de
        session, afin que les rollbackFunction basees sur l'etat (pre-auth, Protected Users)
        fonctionnent lors d'un run -Rollback distinct du run d'application.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Backup)
    foreach ($b in $Backup) { $script:StateBackup.Add($b) }
}

#endregion

#region Moteur

function Invoke-HardeningTask {
    <#
    .SYNOPSIS
        Applique une mesure : test prealable -> apply (si necessaire) -> test de verification.
    .PARAMETER Task
        Objet mesure issu du catalogue JSON.
    .PARAMETER DryRun
        Mode simulation : aucune modification reelle.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][psobject]$Task,
        [switch]$DryRun,
        [ValidateSet('Local', 'Gpo')][string]$DeployVia = 'Local',
        [string]$GpoName,
        [string]$GpoTarget
    )

    # Une mesure n'est deployee par GPO que si le mode est 'Gpo' ET qu'elle declare un
    # bloc 'gpo' (mesure de type "valeur de registre"). Les mesures niveau domaine/foret
    # (objet annuaire, fonctionnalite, service) restent appliquees en local.
    $viaGpo = ($DeployVia -eq 'Gpo' -and $null -ne $Task.gpo)

    $result = [pscustomobject]@{
        MeasureId      = $Task.id
        Name           = $Task.name
        Category       = $Task.category
        Severity       = $Task.severity
        Status         = 'Unknown'
        Message        = $null
        RebootRequired = [bool]$Task.rebootRequired
        DeployedVia    = if ($viaGpo) { 'Gpo' } else { 'Local' }
    }

    try {
        if ($viaGpo) {
            if (-not (Get-Command 'Set-HADGpoMeasure' -ErrorAction SilentlyContinue)) {
                $result.Status = 'Error'
                $result.Message = "Mode GPO demande mais le module HAD.Gpo n'est pas charge."
                return $result
            }
            # Permet a une mesure de cibler une GPO et un perimetre differents (audit/PSLOG
            # doivent porter sur TOUS les serveurs, pas seulement les DC). Token "@DomainRoot"
            # resolu vers le DN du domaine pour eviter qu'un catalogue contienne un DN dur.
            $effGpoName = if ($Task.gpo.gpoName) { $Task.gpo.gpoName } else { $GpoName }
            $effTarget  = if ($Task.gpo.target)  { $Task.gpo.target }  else { $GpoTarget }
            if ($effTarget -eq '@DomainRoot') { $effTarget = Get-HADDomainRoot }

            if (Test-HADGpoMeasure -GpoName $effGpoName -Gpo $Task.gpo) {
                $result.Status = 'AlreadyCompliant'
                $result.Message = "Deja conforme dans la GPO '$effGpoName'."
                return $result
            }
            if ($DryRun) {
                $result.Status = 'WouldApply'
                $result.Message = "[DryRun] Serait deploye via la GPO '$effGpoName' (liee a $effTarget)."
                return $result
            }
            if ($PSCmdlet.ShouldProcess($Task.id, "Apply via GPO '$effGpoName'")) {
                Set-HADGpoMeasure -GpoName $effGpoName -Gpo $Task.gpo -Target $effTarget
                $ok = Test-HADGpoMeasure -GpoName $effGpoName -Gpo $Task.gpo
                $result.Status  = if ($ok) { 'Applied' } else { 'AppliedButNotVerified' }
                $result.Message = if ($ok) { "Deploye et verifie dans la GPO '$effGpoName' (liee a $effTarget)." } else { 'Ecriture GPO effectuee mais verification negative (revue manuelle).' }
            }
            else {
                $result.Status = 'Skipped'
                $result.Message = 'Annule par l operateur (ShouldProcess).'
            }
            return $result
        }

        if (-not (Get-Command $Task.applyFunction -ErrorAction SilentlyContinue)) {
            $result.Status = 'Error'
            $result.Message = "Fonction d'application introuvable : $($Task.applyFunction)"
            return $result
        }

        $hasTest = [bool](Get-Command $Task.testFunction -ErrorAction SilentlyContinue)

        # Etat avant
        if ($hasTest -and (& $Task.testFunction)) {
            $result.Status = 'AlreadyCompliant'
            $result.Message = 'La mesure est deja en place, aucune action.'
            return $result
        }

        if ($DryRun) {
            $result.Status = 'WouldApply'
            $result.Message = '[DryRun] La mesure serait appliquee.'
            return $result
        }

        if ($PSCmdlet.ShouldProcess($Task.id, 'Apply hardening measure')) {
            & $Task.applyFunction

            $ok = $true
            if ($hasTest) { $ok = & $Task.testFunction }
            $result.Status  = if ($ok) { 'Applied' } else { 'AppliedButNotVerified' }
            $result.Message = if ($ok) { 'Mesure appliquee et verifiee.' } else { 'Appliquee mais la verification reste negative (revue manuelle).' }
        }
        else {
            $result.Status = 'Skipped'
            $result.Message = 'Annule par l operateur (ShouldProcess).'
        }
    }
    catch {
        $result.Status = 'Error'
        $result.Message = $_.Exception.Message
    }

    return $result
}

function Invoke-HardeningRollback {
    <#
    .SYNOPSIS
        Annule une mesure en appelant sa rollbackFunction.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][psobject]$Task)

    $result = [pscustomobject]@{
        MeasureId = $Task.id
        Name      = $Task.name
        Status    = 'Unknown'
        Message   = $null
    }

    try {
        # Mesure explicitement non reversible (ex : Corbeille AD) : on n'appelle pas la
        # rollbackFunction et on rapporte un statut clair plutot qu'un faux 'RolledBack'.
        if ($Task.reversible -eq $false) {
            $result.Status = 'Skipped - Irreversible'
            $result.Message = 'Mesure non reversible : annulation volontairement ignoree.'
            return $result
        }
        if (-not (Get-Command $Task.rollbackFunction -ErrorAction SilentlyContinue)) {
            $result.Status = 'Error'
            $result.Message = "Fonction de rollback introuvable : $($Task.rollbackFunction)"
            return $result
        }
        if ($PSCmdlet.ShouldProcess($Task.id, 'Rollback hardening measure')) {
            & $Task.rollbackFunction
            $result.Status = 'RolledBack'
            $result.Message = 'Mesure annulee (valeur sure restauree).'
        }
    }
    catch {
        $result.Status = 'Error'
        $result.Message = $_.Exception.Message
    }
    return $result
}

#endregion

#region Implementations

# --- SMBv1 ---
function Disable-SMBv1 {
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
    Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
}
function Enable-SMBv1 {
    # La fonctionnalite SMB1Protocol peut etre desinstallee : Set-SmbServerConfiguration
    # leve alors 'Windows System Error 1243'. On tolere ce cas (rien a reactiver).
    try {
        Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "Reactivation SMBv1 ignoree (fonctionnalite probablement desinstallee) : $($_.Exception.Message)"
    }
}
function Test-SMBv1Disabled {
    $cfg = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
    if (-not $cfg) { return $true }
    return -not $cfg.EnableSMB1Protocol
}

# --- LDAP Signing ---
$script:NTDSParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
function Enable-LDAPSigning  { Set-HADRegistryValue -Path $script:NTDSParams -Name 'LDAPServerIntegrity' -Value 2 }
function Disable-LDAPSigning { Set-HADRegistryValue -Path $script:NTDSParams -Name 'LDAPServerIntegrity' -Value 1 }
function Test-LDAPSigning {
    return (Get-ItemProperty -Path $script:NTDSParams -Name 'LDAPServerIntegrity' -ErrorAction SilentlyContinue).LDAPServerIntegrity -eq 2
}

# --- LDAP Channel Binding ---
function Enable-LDAPChannelBinding  { Set-HADRegistryValue -Path $script:NTDSParams -Name 'LdapEnforceChannelBinding' -Value 2 }
function Disable-LDAPChannelBinding { Set-HADRegistryValue -Path $script:NTDSParams -Name 'LdapEnforceChannelBinding' -Value 0 }
function Test-LDAPChannelBinding {
    return (Get-ItemProperty -Path $script:NTDSParams -Name 'LdapEnforceChannelBinding' -ErrorAction SilentlyContinue).LdapEnforceChannelBinding -eq 2
}

# --- Print Spooler ---
function Disable-PrintSpooler {
    Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
    Set-Service -Name Spooler -StartupType Disabled
}
function Enable-PrintSpooler {
    Set-Service -Name Spooler -StartupType Automatic
    Start-Service -Name Spooler -ErrorAction SilentlyContinue
}
function Test-PrintSpoolerDisabled {
    return (Get-Service -Name Spooler).StartType -eq 'Disabled'
}

# --- WDigest (mots de passe en clair en memoire) ---
$script:WDigestPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
function Disable-WDigest { Set-HADRegistryValue -Path $script:WDigestPath -Name 'UseLogonCredential' -Value 0 }
function Enable-WDigest  { Set-HADRegistryValue -Path $script:WDigestPath -Name 'UseLogonCredential' -Value 1 }
function Test-WDigestDisabled {
    return (Get-ItemProperty -Path $script:WDigestPath -Name 'UseLogonCredential' -ErrorAction SilentlyContinue).UseLogonCredential -eq 0
}

# --- LSASS Protection (RunAsPPL) ---
$script:LsaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
function Enable-LSASSProtection  { Set-HADRegistryValue -Path $script:LsaPath -Name 'RunAsPPL' -Value 1 }
function Disable-LSASSProtection { Set-HADRegistryValue -Path $script:LsaPath -Name 'RunAsPPL' -Value 0 }
function Test-LSASSProtection {
    return (Get-ItemProperty -Path $script:LsaPath -Name 'RunAsPPL' -ErrorAction SilentlyContinue).RunAsPPL -eq 1
}

# --- Stockage des hash LM ---
function Disable-LMHashStorage { Set-HADRegistryValue -Path $script:LsaPath -Name 'NoLMHash' -Value 1 }
function Enable-LMHashStorage  { Set-HADRegistryValue -Path $script:LsaPath -Name 'NoLMHash' -Value 0 }
function Test-LMHashStorage {
    return (Get-ItemProperty -Path $script:LsaPath -Name 'NoLMHash' -ErrorAction SilentlyContinue).NoLMHash -eq 1
}

# --- Enumeration anonyme ---
function Disable-AnonymousEnumeration {
    Set-HADRegistryValue -Path $script:LsaPath -Name 'RestrictAnonymous' -Value 1
    Set-HADRegistryValue -Path $script:LsaPath -Name 'RestrictAnonymousSAM' -Value 1
}
function Enable-AnonymousEnumeration {
    Set-HADRegistryValue -Path $script:LsaPath -Name 'RestrictAnonymous' -Value 0
    Set-HADRegistryValue -Path $script:LsaPath -Name 'RestrictAnonymousSAM' -Value 0
}
function Test-AnonymousEnumeration {
    $p = Get-ItemProperty -Path $script:LsaPath -ErrorAction SilentlyContinue
    return ($p.RestrictAnonymous -eq 1 -and $p.RestrictAnonymousSAM -eq 1)
}

# --- NTLM (defaut : AUDIT pour ne pas casser le legacy) ---
$script:Msv1Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
function Set-NTLMRestriction {
    # 1 = Audit (recommande en premier passage). 2 = Deny pour comptes domaine.
    Set-HADRegistryValue -Path $script:Msv1Path -Name 'RestrictSendingNTLMTraffic' -Value 1
}
function Reset-NTLMRestriction {
    Set-HADRegistryValue -Path $script:Msv1Path -Name 'RestrictSendingNTLMTraffic' -Value 0
}
function Test-NTLMRestriction {
    return (Get-ItemProperty -Path $script:Msv1Path -Name 'RestrictSendingNTLMTraffic' -ErrorAction SilentlyContinue).RestrictSendingNTLMTraffic -ge 1
}

# --- ms-DS-MachineAccountQuota ---
function Get-HADMachineAccountQuota {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dn = (Get-ADDomain).DistinguishedName
    return [int](Get-ADObject -Identity $dn -Properties 'ms-DS-MachineAccountQuota').'ms-DS-MachineAccountQuota'
}
function Set-MachineAccountQuotaZero {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dn = (Get-ADDomain).DistinguishedName
    Set-ADObject -Identity $dn -Replace @{ 'ms-DS-MachineAccountQuota' = 0 }
}
function Reset-MachineAccountQuota {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dn = (Get-ADDomain).DistinguishedName
    Set-ADObject -Identity $dn -Replace @{ 'ms-DS-MachineAccountQuota' = 10 }
}
function Test-MachineAccountQuota {
    try { return (Get-HADMachineAccountQuota) -eq 0 } catch { return $false }
}

# --- Delegation : marque les admins privilegies 'sensible / non delegable' ---
# Comptes systeme a ne jamais modifier.
$script:PrivilegedGroups   = @('Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators')
$script:DelegationExcluded = @('krbtgt', 'Guest')

function Get-HADPrivilegedMembers {
    # Preference locale : evite qu'un $ErrorActionPreference='Stop' herite ne transforme
    # les aleas d'enumeration AD (membres orphelins/inter-domaines) en erreur fatale.
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop

    $members = foreach ($g in $script:PrivilegedGroups) {
        try {
            Get-ADGroupMember -Identity $g -Recursive -ErrorAction Stop |
                Where-Object { $_.objectClass -eq 'user' }
        }
        catch {
            Write-Verbose "Groupe '$g' ignore : $($_.Exception.Message)"
        }
    }
    return @($members | Sort-Object -Property SID -Unique)
}

function Protect-Delegation {
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop

    $flagged = 0
    foreach ($m in (Get-HADPrivilegedMembers)) {
        try {
            $u = Get-ADUser -Identity $m.SID -Properties AccountNotDelegated -ErrorAction Stop
            if ($script:DelegationExcluded -contains $u.SamAccountName) { continue }
            if (-not $u.AccountNotDelegated) {
                Set-ADUser -Identity $u -AccountNotDelegated $true -ErrorAction Stop
                $flagged++
            }
        }
        catch {
            Write-Verbose "Compte $($m.SID) ignore : $($_.Exception.Message)"
        }
    }
    Write-Verbose "$flagged compte(s) privilegie(s) marque(s) 'non delegable'."

    # Audit informatif des delegations non contraintes hors DC (non bloquant).
    try {
        $unconstrained = Get-ADComputer -LDAPFilter '(userAccountControl:1.2.840.113556.1.4.803:=524288)' -ErrorAction Stop |
            Where-Object { $_.DistinguishedName -notmatch 'OU=Domain Controllers' }
        if ($unconstrained) {
            Write-Warning "Delegation non contrainte detectee (revue manuelle) : $(( $unconstrained.Name ) -join ', ')"
        }
    }
    catch { Write-Verbose "Audit delegation non contrainte ignore : $($_.Exception.Message)" }
}

function Unprotect-Delegation {
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    foreach ($m in (Get-HADPrivilegedMembers)) {
        try {
            $u = Get-ADUser -Identity $m.SID -ErrorAction Stop
            if ($script:DelegationExcluded -contains $u.SamAccountName) { continue }
            Set-ADUser -Identity $u -AccountNotDelegated $false -ErrorAction Stop
        }
        catch {
            Write-Verbose "Compte $($m.SID) ignore : $($_.Exception.Message)"
        }
    }
}

function Test-Delegation {
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $members = Get-HADPrivilegedMembers
        if (-not $members) { return $false }
        foreach ($m in $members) {
            $u = Get-ADUser -Identity $m.SID -Properties AccountNotDelegated, SamAccountName -ErrorAction Stop
            if ($script:DelegationExcluded -contains $u.SamAccountName) { continue }
            if (-not $u.AccountNotDelegated) { return $false }
        }
        return $true
    }
    catch { return $false }
}

# --- Politique de mot de passe des comptes machine ---
$script:NetlogonParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
function Set-MachinePasswordPolicy {
    Set-HADRegistryValue -Path $script:NetlogonParams -Name 'DisablePasswordChange' -Value 0
    Set-HADRegistryValue -Path $script:NetlogonParams -Name 'MaximumPasswordAge' -Value 30
}
function Reset-MachinePasswordPolicy {
    Set-HADRegistryValue -Path $script:NetlogonParams -Name 'MaximumPasswordAge' -Value 90
}
function Test-MachinePasswordPolicy {
    $p = Get-ItemProperty -Path $script:NetlogonParams -ErrorAction SilentlyContinue
    return ($p.DisablePasswordChange -eq 0 -and $p.MaximumPasswordAge -le 30)
}

# --- WebClient (WebDAV) sur les DC : vecteur de relais (PetitPotam-like) ---
function Disable-WebClientService {
    $svc = Get-Service -Name WebClient -ErrorAction SilentlyContinue
    if (-not $svc) { return }   # non installe = rien a faire
    Stop-Service -Name WebClient -Force -ErrorAction SilentlyContinue
    Set-Service -Name WebClient -StartupType Disabled
}
function Enable-WebClientService {
    if (Get-Service -Name WebClient -ErrorAction SilentlyContinue) {
        Set-Service -Name WebClient -StartupType Manual
    }
}
function Test-WebClientDisabled {
    $svc = Get-Service -Name WebClient -ErrorAction SilentlyContinue
    if (-not $svc) { return $true }   # absent = conforme
    return $svc.StartType -eq 'Disabled'
}

# --- Corbeille Active Directory (recuperation d'objets supprimes) ---
function Enable-ADRecycleBinFeature {
    Import-Module ActiveDirectory -ErrorAction Stop
    $forest = Get-ADForest
    if ([int]$forest.ForestMode -lt 4) {
        # ForestMode < Windows2008R2 : fonctionnalite indisponible.
        throw "Niveau fonctionnel de foret insuffisant (>= 2008 R2 requis) pour la Corbeille AD."
    }
    Enable-ADOptionalFeature -Identity 'Recycle Bin Feature' `
        -Scope ForestOrConfigurationSet -Target $forest.Name -Confirm:$false
}
function Disable-ADRecycleBinFeature {
    # Irreversible : la Corbeille AD ne peut pas etre desactivee une fois active.
    Write-Warning 'La Corbeille AD ne peut pas etre desactivee une fois activee (operation ignoree).'
}
function Test-ADRecycleBin {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $feat = Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'" -ErrorAction Stop
        if (-not $feat) { return $false }
        return (@($feat.EnabledScopes).Count -gt 0)
    }
    catch { return $false }
}

# --- Politique de mot de passe du domaine : longueur minimale ---
$script:MinPasswordLengthTarget = 12
function Set-DomainMinPasswordLength {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dn = (Get-ADDomain).DistinguishedName
    $current = (Get-ADDefaultDomainPasswordPolicy).MinPasswordLength
    Set-HADStateBackup -Component 'PasswordPolicy' -Item 'MinPasswordLength' -PriorValue $current
    if ($current -lt $script:MinPasswordLengthTarget) {
        Set-ADDefaultDomainPasswordPolicy -Identity $dn -MinPasswordLength $script:MinPasswordLengthTarget
    }
}
function Reset-DomainMinPasswordLength {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dn = (Get-ADDomain).DistinguishedName
    # Valeur sure par defaut Windows (7). La valeur exacte d'origine est dans state_backup.json.
    Set-ADDefaultDomainPasswordPolicy -Identity $dn -MinPasswordLength 7
}
function Test-DomainMinPasswordLength {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        return (Get-ADDefaultDomainPasswordPolicy).MinPasswordLength -ge $script:MinPasswordLengthTarget
    }
    catch { return $false }
}

# --- dsHeuristics : interdire les operations LDAP anonymes (7e caractere != '2') ---
function Get-HADDsHeuristicsDN {
    Import-Module ActiveDirectory -ErrorAction Stop
    $cfg = (Get-ADRootDSE).configurationNamingContext
    return "CN=Directory Service,CN=Windows NT,CN=Services,$cfg"
}
function Disable-AnonymousLDAP {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dn = Get-HADDsHeuristicsDN
    $cur = [string](Get-ADObject -Identity $dn -Properties dsHeuristics -ErrorAction Stop).dsHeuristics
    Set-HADStateBackup -Component 'dsHeuristics' -Item 'value' -PriorValue $cur -Existed ([bool]$cur)

    # Construit une valeur ou le 7e caractere (index 6) vaut '0'.
    $arr = New-Object System.Collections.Generic.List[char]
    if ($cur) { $arr.AddRange([char[]]$cur.ToCharArray()) }
    while ($arr.Count -lt 7) { $arr.Add('0') }
    $arr[6] = '0'
    $new = -join $arr

    if ($new -ne $cur) {
        if ([string]::IsNullOrEmpty($cur)) {
            Set-ADObject -Identity $dn -Add @{ dsHeuristics = $new } -ErrorAction Stop
        }
        else {
            Set-ADObject -Identity $dn -Replace @{ dsHeuristics = $new } -ErrorAction Stop
        }
    }
}
function Enable-AnonymousLDAP {
    # Rollback : on conserve une posture sure (anonymous LDAP desactive reste recommande).
    Write-Warning 'Rollback dsHeuristics ignore : la desactivation des operations LDAP anonymes reste recommandee.'
}
function Test-AnonymousLDAPDisabled {
    try {
        $dn = Get-HADDsHeuristicsDN
        $cur = [string](Get-ADObject -Identity $dn -Properties dsHeuristics -ErrorAction Stop).dsHeuristics
        if ([string]::IsNullOrEmpty($cur) -or $cur.Length -lt 7) { return $true }
        return ($cur[6] -ne '2')
    }
    catch { return $false }
}

# --- Pre-Windows 2000 Compatible Access : retrait de 'Anonymous Logon' / 'Everyone' ---
function Remove-PreWin2000Anonymous {
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    $grp = Get-ADGroup -Identity 'S-1-5-32-554' -ErrorAction Stop  # Pre-Windows 2000 Compatible Access
    $targets = @('S-1-5-7', 'S-1-1-0')                            # Anonymous Logon, Everyone
    $members = Get-ADGroupMember -Identity $grp -ErrorAction SilentlyContinue
    foreach ($m in $members) {
        if ($m.SID.Value -in $targets) {
            try {
                Remove-ADGroupMember -Identity $grp -Members $m -Confirm:$false -ErrorAction Stop
                Set-HADStateBackup -Component 'PreWin2000' -Item $m.SID.Value -PriorValue 'wasMember'
            }
            catch { Write-Warning "Pre-Win2000 : retrait de $($m.SID.Value) impossible : $($_.Exception.Message)" }
        }
    }
}
function Add-PreWin2000Anonymous {
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    $grp = Get-ADGroup -Identity 'S-1-5-32-554' -ErrorAction Stop
    foreach ($b in (Get-HADStateBackup | Where-Object { $_.Component -eq 'PreWin2000' })) {
        try { Add-ADGroupMember -Identity $grp -Members $b.Item -Confirm:$false -ErrorAction Stop } catch {}
    }
}
function Test-PreWin2000Anonymous {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $grp = Get-ADGroup -Identity 'S-1-5-32-554' -ErrorAction Stop
        $members = Get-ADGroupMember -Identity $grp -ErrorAction SilentlyContinue
        $bad = $members | Where-Object { $_.SID.Value -in @('S-1-5-7', 'S-1-1-0') }
        return (-not $bad)
    }
    catch { return $false }
}

# --- Chiffrement reversible des mots de passe (strategie de domaine) ---
function Disable-ReversibleEncryption {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dn = (Get-ADDomain).DistinguishedName
    $cur = (Get-ADDefaultDomainPasswordPolicy).ReversibleEncryptionEnabled
    Set-HADStateBackup -Component 'PasswordPolicy' -Item 'ReversibleEncryptionEnabled' -PriorValue $cur
    if ($cur) {
        Set-ADDefaultDomainPasswordPolicy -Identity $dn -ReversibleEncryptionEnabled $false
    }
}
function Enable-ReversibleEncryption {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dn = (Get-ADDomain).DistinguishedName
    Set-ADDefaultDomainPasswordPolicy -Identity $dn -ReversibleEncryptionEnabled $true
}
function Test-ReversibleEncryption {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        return (-not (Get-ADDefaultDomainPasswordPolicy).ReversibleEncryptionEnabled)
    }
    catch { return $false }
}

# --- Niveau d'authentification LM/NTLM (LmCompatibilityLevel=5 : NTLMv2 only) ---
function Set-LmCompatibilityLevel {
    # 5 = envoyer NTLMv2 uniquement, refuser LM et NTLM.
    Set-HADRegistryValue -Path $script:LsaPath -Name 'LmCompatibilityLevel' -Value 5
}
function Reset-LmCompatibilityLevel {
    # 3 = valeur par defaut moderne (envoyer NTLMv2, accepter tout).
    Set-HADRegistryValue -Path $script:LsaPath -Name 'LmCompatibilityLevel' -Value 3
}
function Test-LmCompatibilityLevel {
    return (Get-ItemProperty -Path $script:LsaPath -Name 'LmCompatibilityLevel' -ErrorAction SilentlyContinue).LmCompatibilityLevel -ge 5
}

# --- S-NoPreAuth : comptes sans pre-authentification Kerberos (AS-REP roasting) ---
# Remediation automatique (impact faible : aucun compte legitime ne necessite ce flag).
function Get-HADNoPreAuthAccounts {
    Import-Module ActiveDirectory -ErrorAction Stop
    # DONT_REQ_PREAUTH (0x400000) positionne, comptes ACTIVES uniquement (exclut bit 2).
    return Get-ADUser -LDAPFilter '(&(userAccountControl:1.2.840.113556.1.4.803:=4194304)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))' `
        -Properties userAccountControl -ErrorAction SilentlyContinue
}
function Repair-KerberosPreAuth {
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    foreach ($u in (Get-HADNoPreAuthAccounts)) {
        if ($u.SamAccountName -in @('krbtgt', 'Guest')) { continue }
        try {
            Set-ADAccountControl -Identity $u -DoesNotRequirePreAuth $false -ErrorAction Stop
            Set-HADStateBackup -Component 'NoPreAuth' -Item $u.SamAccountName -PriorValue 'DoesNotRequirePreAuth'
        }
        catch { Write-Warning "Pre-auth : $($u.SamAccountName) non corrige : $($_.Exception.Message)" }
    }
}
function Undo-KerberosPreAuth {
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    foreach ($b in (Get-HADStateBackup | Where-Object { $_.Component -eq 'NoPreAuth' })) {
        try { Set-ADAccountControl -Identity $b.Item -DoesNotRequirePreAuth $true -ErrorAction Stop } catch {}
    }
}
function Test-KerberosPreAuth {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        return (-not (Get-HADNoPreAuthAccounts))
    }
    catch { return $false }
}

# --- S-DesEnabled : comptes en chiffrement Kerberos DES uniquement (AUDIT) ---
# Audit seul : modifier le chiffrement peut casser un service legacy. On liste pour revue.
function Get-HADDesAccounts {
    Import-Module ActiveDirectory -ErrorAction Stop
    # UseDESKeyOnly (0x200000).
    return Get-ADObject -LDAPFilter '(userAccountControl:1.2.840.113556.1.4.803:=2097152)' `
        -Properties sAMAccountName -ErrorAction SilentlyContinue
}
function Show-DesAccounts {
    Import-Module ActiveDirectory -ErrorAction Stop
    $des = Get-HADDesAccounts
    if ($des) {
        Write-Warning "Comptes en chiffrement DES uniquement (revue/remediation manuelle requise) : $(( $des.Name ) -join ', ')"
    }
}
function Undo-DesAudit {
    Write-Warning "Mesure d'audit (S-DesEnabled) : aucun changement automatique a annuler."
}
function Test-DesAccounts {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        return (-not (Get-HADDesAccounts))
    }
    catch { return $false }
}

# --- Journalisation PowerShell (ScriptBlock + Module logging) ---
$script:PsScriptBlockPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'
$script:PsModuleLogPath   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging'
function Enable-PowerShellLogging {
    Set-HADRegistryValue -Path $script:PsScriptBlockPath -Name 'EnableScriptBlockLogging' -Value 1
    Set-HADRegistryValue -Path $script:PsModuleLogPath -Name 'EnableModuleLogging' -Value 1
    Set-HADRegistryValue -Path "$script:PsModuleLogPath\ModuleNames" -Name '*' -Value '*' -Type String
}
function Disable-PowerShellLogging {
    Set-HADRegistryValue -Path $script:PsScriptBlockPath -Name 'EnableScriptBlockLogging' -Value 0
    Set-HADRegistryValue -Path $script:PsModuleLogPath -Name 'EnableModuleLogging' -Value 0
}
function Test-PowerShellLogging {
    $sbl = (Get-ItemProperty -Path $script:PsScriptBlockPath -Name 'EnableScriptBlockLogging' -ErrorAction SilentlyContinue).EnableScriptBlockLogging
    $ml  = (Get-ItemProperty -Path $script:PsModuleLogPath -Name 'EnableModuleLogging' -ErrorAction SilentlyContinue).EnableModuleLogging
    return ($sbl -eq 1 -and $ml -eq 1)
}

# --- Strategie d'audit avancee (logs de securite importants) ---
# GUID des sous-categories (stables, INDEPENDANTS de la langue de l'OS - contrairement
# aux noms qui sont localises). Suffixe commun : -69AE-11D9-BED3-505054503030.
$script:AuditSubcategoryGuids = @(
    '{0CCE923F-69AE-11D9-BED3-505054503030}', # Credential Validation
    '{0CCE9242-69AE-11D9-BED3-505054503030}', # Kerberos Authentication Service
    '{0CCE9240-69AE-11D9-BED3-505054503030}', # Kerberos Service Ticket Operations
    '{0CCE9215-69AE-11D9-BED3-505054503030}', # Logon
    '{0CCE9216-69AE-11D9-BED3-505054503030}', # Logoff
    '{0CCE921B-69AE-11D9-BED3-505054503030}', # Special Logon
    '{0CCE923B-69AE-11D9-BED3-505054503030}', # Directory Service Access
    '{0CCE923C-69AE-11D9-BED3-505054503030}', # Directory Service Changes
    '{0CCE9235-69AE-11D9-BED3-505054503030}', # User Account Management
    '{0CCE9237-69AE-11D9-BED3-505054503030}', # Security Group Management
    '{0CCE9236-69AE-11D9-BED3-505054503030}', # Computer Account Management
    '{0CCE922B-69AE-11D9-BED3-505054503030}', # Process Creation
    '{0CCE922F-69AE-11D9-BED3-505054503030}', # Audit Policy Change
    '{0CCE9228-69AE-11D9-BED3-505054503030}'  # Sensitive Privilege Use
)
$script:AuditBackupFile = Join-Path $env:ProgramData 'BlueLock\auditpol-backup.csv'
function Enable-AdvancedAuditPolicy {
    # Forcer la prise en compte de la strategie d'audit AVANCEE (sinon la legacy prime).
    Set-HADRegistryValue -Path $script:LsaPath -Name 'SCENoApplyLegacyAuditPolicy' -Value 1
    # Sauvegarde de l'etat courant pour un rollback exact (auditpol /backup).
    $dir = Split-Path $script:AuditBackupFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    & auditpol /backup /file:"$script:AuditBackupFile" 2>$null | Out-Null
    Set-HADStateBackup -Component 'AuditPolicy' -Item $script:AuditBackupFile -PriorValue 'auditpol-backup'
    foreach ($guid in $script:AuditSubcategoryGuids) {
        & auditpol /set /subcategory:"$guid" /success:enable /failure:enable 2>$null | Out-Null
    }
}
function Reset-AdvancedAuditPolicy {
    if (Test-Path $script:AuditBackupFile) {
        & auditpol /restore /file:"$script:AuditBackupFile" 2>$null | Out-Null
    }
    else {
        Write-Warning "Sauvegarde auditpol introuvable : strategie d'audit laissee active (non desactivee)."
    }
}
function Test-AdvancedAuditPolicy {
    $reg = (Get-ItemProperty -Path $script:LsaPath -Name 'SCENoApplyLegacyAuditPolicy' -ErrorAction SilentlyContinue).SCENoApplyLegacyAuditPolicy
    if ($reg -ne 1) { return $false }
    foreach ($guid in $script:AuditSubcategoryGuids) {
        # /r = sortie CSV ; la derniere colonne "Setting Value" est NUMERIQUE (0/1/2/3),
        # donc fiable quelle que soit la langue de l'OS.
        $line = & auditpol /get /subcategory:"$guid" /r 2>$null | Where-Object { $_ -match [regex]::Escape($guid) }
        if (-not $line) { return $false }
        $val = ($line -split ',')[-1].Trim()
        if (-not ($val -as [int]) -or [int]$val -lt 1) { return $false }
    }
    return $true
}

# --- Protected Users : ajout des comptes adminCount=1 REELLEMENT privilegies ---
$script:ProtectedUsersGroup = 'Protected Users'
function Get-HADGenuinelyPrivilegedUsers {
    # Comptes avec adminCount=1 QUI SONT vraiment membres (recursif) d'un groupe privilegie.
    # Ecarte les flags adminCount orphelins (anciennes appartenances) et les comptes systeme.
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    $privSids = @((Get-HADPrivilegedMembers).SID.Value)
    if (-not $privSids) { return @() }
    $adminCount = Get-ADUser -LDAPFilter '(adminCount=1)' -Properties adminCount, SamAccountName -ErrorAction SilentlyContinue
    return @($adminCount | Where-Object {
            $_.Enabled -ne $false -and
            $privSids -contains $_.SID.Value -and
            $script:DelegationExcluded -notcontains $_.SamAccountName
        })
}
function Add-PrivilegedToProtectedUsers {
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    $grp = Get-ADGroup -Identity $script:ProtectedUsersGroup -ErrorAction Stop
    $existing = @((Get-ADGroupMember -Identity $grp -ErrorAction SilentlyContinue).SID.Value)
    foreach ($u in (Get-HADGenuinelyPrivilegedUsers)) {
        if ($existing -contains $u.SID.Value) { continue }
        try {
            Add-ADGroupMember -Identity $grp -Members $u -ErrorAction Stop
            Set-HADStateBackup -Component 'ProtectedUsers' -Item $u.SamAccountName -PriorValue 'added'
        }
        catch { Write-Warning "Protected Users : $($u.SamAccountName) non ajoute : $($_.Exception.Message)" }
    }
}
function Remove-PrivilegedFromProtectedUsers {
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    foreach ($b in (Get-HADStateBackup | Where-Object { $_.Component -eq 'ProtectedUsers' })) {
        try { Remove-ADGroupMember -Identity $script:ProtectedUsersGroup -Members $b.Item -Confirm:$false -ErrorAction Stop } catch {}
    }
}
function Test-ProtectedUsers {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $pending = Get-HADGenuinelyPrivilegedUsers
        if (-not $pending) { return $true }
        $members = @((Get-ADGroupMember -Identity $script:ProtectedUsersGroup -ErrorAction Stop).SID.Value)
        foreach ($u in $pending) { if ($members -notcontains $u.SID.Value) { return $false } }
        return $true
    }
    catch { return $false }
}

# --- Audit des mots de passe du domaine (AUDIT seul) ---
function Get-HADWeakPasswordAccounts {
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    # PASSWD_NOTREQD (0x20) et DONT_EXPIRE_PASSWORD (0x10000), comptes actifs (exclut bit 2).
    $notReq = Get-ADUser -LDAPFilter '(&(userAccountControl:1.2.840.113556.1.4.803:=32)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))' -ErrorAction SilentlyContinue
    $neverExp = Get-ADUser -LDAPFilter '(&(userAccountControl:1.2.840.113556.1.4.803:=65536)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))' -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        PasswordNotRequired  = @($notReq.SamAccountName)
        PasswordNeverExpires = @($neverExp.SamAccountName)
    }
}
function Get-HADDomainPasswordPolicy {
    <# .SYNOPSIS Retourne la politique de mot de passe par defaut + ecarts a la cible. #>
    Import-Module ActiveDirectory -ErrorAction Stop
    $p = Get-ADDefaultDomainPasswordPolicy -ErrorAction Stop
    $issues = New-Object System.Collections.Generic.List[string]
    if ($p.MinPasswordLength -lt 12)        { $issues.Add("longueur min = $($p.MinPasswordLength) (< 12)") }
    if (-not $p.ComplexityEnabled)          { $issues.Add("complexite DESACTIVEE") }
    if ($p.PasswordHistoryCount -lt 24)     { $issues.Add("historique = $($p.PasswordHistoryCount) (< 24)") }
    if ($p.LockoutThreshold -eq 0)          { $issues.Add("verrouillage DESACTIVE (LockoutThreshold=0)") }
    if ($p.MaxPasswordAge.TotalDays -le 0 -or $p.MaxPasswordAge.TotalDays -gt 365) {
        $issues.Add("MaxPasswordAge = $([math]::Round($p.MaxPasswordAge.TotalDays)) j (hors 1-365)")
    }
    if ($p.MinPasswordAge.TotalDays -lt 1)  { $issues.Add("MinPasswordAge = $([math]::Round($p.MinPasswordAge.TotalDays,1)) j (< 1)") }
    return [pscustomobject]@{ Policy = $p; Issues = $issues.ToArray() }
}
function Show-WeakPasswordAccounts {
    Import-Module ActiveDirectory -ErrorAction Stop
    $w = Get-HADWeakPasswordAccounts
    if ($w.PasswordNotRequired)  { Write-Warning "PASSWD_NOTREQD (mot de passe non requis) : $(( $w.PasswordNotRequired ) -join ', ')" }
    if ($w.PasswordNeverExpires) { Write-Warning "Mot de passe sans expiration : $(( $w.PasswordNeverExpires ) -join ', ')" }

    # Politique de mot de passe par defaut.
    try {
        $audit = Get-HADDomainPasswordPolicy
        Write-Host ("Politique domaine : longueur={0}, complexite={1}, historique={2}, MaxAge={3} j, MinAge={4} j, verrouillage={5}" -f `
            $audit.Policy.MinPasswordLength, $audit.Policy.ComplexityEnabled, $audit.Policy.PasswordHistoryCount, `
            [math]::Round($audit.Policy.MaxPasswordAge.TotalDays), [math]::Round($audit.Policy.MinPasswordAge.TotalDays,1), `
            $audit.Policy.LockoutThreshold) -ForegroundColor Gray
        if ($audit.Issues) { Write-Warning ("Politique par defaut non conforme : " + ($audit.Issues -join ' ; ')) }
    }
    catch { Write-Warning "Politique par defaut indisponible : $($_.Exception.Message)" }

    # Fine-Grained Password Policies (PSO).
    try {
        $psos = Get-ADFineGrainedPasswordPolicy -Filter * -ErrorAction SilentlyContinue
        foreach ($pso in $psos) {
            $iss = @()
            if ($pso.MinPasswordLength -lt 12)    { $iss += "longueur=$($pso.MinPasswordLength)" }
            if (-not $pso.ComplexityEnabled)      { $iss += "complexite=off" }
            if ($pso.PasswordHistoryCount -lt 24) { $iss += "historique=$($pso.PasswordHistoryCount)" }
            if ($iss) { Write-Warning "FGPP '$($pso.Name)' non conforme : $($iss -join ' ; ')" }
        }
    }
    catch { }

    if (Get-Module -ListAvailable -Name DSInternals) {
        Write-Warning "DSInternals detecte : audit des hash possible via Test-PasswordQuality sur un replica."
    }
    else {
        Write-Warning "DSInternals absent : installer DSInternals pour auditer les hash (faibles/reutilises/breaches)."
    }
}
function Undo-WeakPasswordAudit { Write-Warning "Mesure d'audit (mots de passe) : aucun changement a annuler." }
function Test-WeakPasswordAccounts {
    try {
        $w = Get-HADWeakPasswordAccounts
        if ($w.PasswordNotRequired -or $w.PasswordNeverExpires) { return $false }
        $audit = Get-HADDomainPasswordPolicy
        return ($audit.Issues.Count -eq 0)
    }
    catch { return $false }
}

# --- Complexite du mot de passe domaine (remediation) ---
function Enable-PasswordComplexity {
    Import-Module ActiveDirectory -ErrorAction Stop
    $p = Get-ADDefaultDomainPasswordPolicy
    Set-HADStateBackup -Component 'PasswordPolicy' -Item 'ComplexityEnabled' -PriorValue $p.ComplexityEnabled
    if (-not $p.ComplexityEnabled) {
        $dn = (Get-ADDomain).DistinguishedName
        Set-ADDefaultDomainPasswordPolicy -Identity $dn -ComplexityEnabled $true
    }
}
function Disable-PasswordComplexity {
    Import-Module ActiveDirectory -ErrorAction Stop
    # Si une sauvegarde existe et indique 'desactivee', on restaure ; sinon on laisse
    # active (etat sur). On NE force PAS la desactivation par defaut.
    $sb = Get-HADStateBackup | Where-Object { $_.Component -eq 'PasswordPolicy' -and $_.Item -eq 'ComplexityEnabled' } | Select-Object -Last 1
    if ($sb -and $sb.PriorValue -eq $false) {
        $dn = (Get-ADDomain).DistinguishedName
        Set-ADDefaultDomainPasswordPolicy -Identity $dn -ComplexityEnabled $false
    }
    else {
        Write-Verbose "Complexite : pas de sauvegarde 'desactivee' trouvee, on laisse active."
    }
}
function Test-PasswordComplexity {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        return [bool](Get-ADDefaultDomainPasswordPolicy).ComplexityEnabled
    }
    catch { return $false }
}

# --- Honeypot AD : compte leurre Kerberoastable + SACL d'audit ---
$script:HoneypotName = 'SVC-BackupLegacy'
function New-HADRandomPassword {
    param([int]$Length = 64)
    $lower = 'abcdefghijkmnpqrstuvwxyz'; $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $dig = '23456789'; $spec = '!@#$%^&*()-_=+'
    $all = "$lower$upper$dig$spec"
    $pw = @($lower, $upper, $dig, $spec | ForEach-Object { $_[(Get-Random -Maximum $_.Length)] })
    $pw += (1..($Length - 4) | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] })
    return (-join ($pw | Sort-Object { Get-Random }))
}
function Get-HADHoneypotIdentity {
    Import-Module ActiveDirectory -ErrorAction Stop
    return Get-ADUser -LDAPFilter "(sAMAccountName=$script:HoneypotName)" -Properties servicePrincipalName, description -ErrorAction SilentlyContinue
}
function New-ADHoneypot {
    $ErrorActionPreference = 'Stop'
    Import-Module ActiveDirectory -ErrorAction Stop
    if (Get-HADHoneypotIdentity) { return }
    $domain = Get-ADDomain
    $spn = "MSSQLSvc/legacy-sql01.$($domain.DNSRoot):1433"   # appat Kerberoasting
    $sec = ConvertTo-SecureString (New-HADRandomPassword -Length 64) -AsPlainText -Force
    $u = New-ADUser -Name $script:HoneypotName -SamAccountName $script:HoneypotName `
        -UserPrincipalName "$script:HoneypotName@$($domain.DNSRoot)" `
        -AccountPassword $sec -Enabled $true -PasswordNeverExpires $true `
        -Description 'Compte de service herite - NE PAS UTILISER (leurre de detection)' `
        -OtherAttributes @{ servicePrincipalName = $spn } -PassThru -ErrorAction Stop
    # SACL : journaliser tout acces a l'objet leurre (en complement des evenements 4769).
    try {
        $everyone = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAuditRule(
            $everyone,
            [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
            [System.Security.AccessControl.AuditFlags]'Success, Failure')
        $adPath = "AD:\$($u.DistinguishedName)"
        $acl = Get-Acl -Path $adPath -Audit
        $acl.AddAuditRule($rule)
        Set-Acl -Path $adPath -AclObject $acl
    }
    catch { Write-Warning "Honeypot : SACL d'audit non posee : $($_.Exception.Message)" }
}
function Remove-ADHoneypot {
    $ErrorActionPreference = 'SilentlyContinue'
    Import-Module ActiveDirectory -ErrorAction Stop
    $h = Get-HADHoneypotIdentity
    if ($h) { Remove-ADUser -Identity $h -Confirm:$false -ErrorAction SilentlyContinue }
}
function Test-ADHoneypot {
    try {
        $h = Get-HADHoneypotIdentity
        return ($null -ne $h -and @($h.servicePrincipalName).Count -gt 0)
    }
    catch { return $false }
}

#endregion
