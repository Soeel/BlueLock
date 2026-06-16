#Requires -Version 5.1
<#
.SYNOPSIS
    HAD.Hardening - Moteur d'execution des mesures + implementations.
.DESCRIPTION
    Le moteur (Invoke-HardeningTask) appelle dynamiquement la fonction nommee dans le
    catalogue (applyFunction / testFunction). Chaque mesure expose apply / rollback / test.
    Les implementations ci-dessous sont des squelettes prets a etre completes : par
    defaut elles tournent en -WhatIf pour ne RIEN modifier tant que ce n'est pas valide.

    NOTE : le tiering (comptes Tier0/1/2, OU, groupes, GPO de tiering) est gere par un
    script externe et n'est volontairement PAS traite dans ce module.
#>

#region Moteur

function Invoke-HardeningTask {
    <#
    .SYNOPSIS
        Applique une mesure : test prealable -> apply (si necessaire) -> test de verification.
    .PARAMETER Task
        Objet mesure issu du catalogue JSON.
    .PARAMETER WhatIf
        Mode simulation : aucune modification reelle.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][psobject]$Task,
        [switch]$DryRun
    )

    $result = [pscustomobject]@{
        MeasureId = $Task.id
        Name      = $Task.name
        Status    = 'Unknown'
        Message   = $null
    }

    try {
        # Verifie si la fonction d'application existe
        if (-not (Get-Command $Task.applyFunction -ErrorAction SilentlyContinue)) {
            $result.Status = 'Error'
            $result.Message = "Fonction d'application introuvable : $($Task.applyFunction)"
            return $result
        }

        # Etat avant
        $alreadyCompliant = $false
        if (Get-Command $Task.testFunction -ErrorAction SilentlyContinue) {
            $alreadyCompliant = & $Task.testFunction
        }

        if ($alreadyCompliant) {
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

            # Verification post-application
            $ok = $true
            if (Get-Command $Task.testFunction -ErrorAction SilentlyContinue) {
                $ok = & $Task.testFunction
            }
            $result.Status  = if ($ok) { 'Applied' } else { 'AppliedButNotVerified' }
            $result.Message = if ($ok) { 'Mesure appliquee et verifiee.' } else { 'Appliquee mais verification negative.' }
        }
    }
    catch {
        $result.Status = 'Error'
        $result.Message = $_.Exception.Message
    }

    return $result
}

#endregion

#region Implementations (squelettes - completer avant production)

# --- SMBv1 ---
function Disable-SMBv1 {
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
    Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
}
function Enable-SMBv1 {
    Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force
}
function Test-SMBv1Disabled {
    return -not (Get-SmbServerConfiguration).EnableSMB1Protocol
}

# --- LDAP Signing ---
function Enable-LDAPSigning {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
    Set-ItemProperty -Path $p -Name 'LDAPServerIntegrity' -Value 2 -Type DWord
}
function Disable-LDAPSigning {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
    Set-ItemProperty -Path $p -Name 'LDAPServerIntegrity' -Value 1 -Type DWord
}
function Test-LDAPSigning {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
    return (Get-ItemProperty -Path $p -Name 'LDAPServerIntegrity' -ErrorAction SilentlyContinue).LDAPServerIntegrity -eq 2
}

# --- LDAP Channel Binding ---
function Enable-LDAPChannelBinding {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
    Set-ItemProperty -Path $p -Name 'LdapEnforceChannelBinding' -Value 2 -Type DWord
}
function Disable-LDAPChannelBinding {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
    Set-ItemProperty -Path $p -Name 'LdapEnforceChannelBinding' -Value 0 -Type DWord
}
function Test-LDAPChannelBinding {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
    return (Get-ItemProperty -Path $p -Name 'LdapEnforceChannelBinding' -ErrorAction SilentlyContinue).LdapEnforceChannelBinding -eq 2
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

# --- NTLM (defaut : AUDIT pour ne pas casser le legacy) ---
function Set-NTLMRestriction {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    # 1 = Audit (recommande en premier passage). 2 = Deny pour comptes domaine.
    Set-ItemProperty -Path $p -Name 'RestrictSendingNTLMTraffic' -Value 1 -Type DWord
}
function Reset-NTLMRestriction {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
    Set-ItemProperty -Path $p -Name 'RestrictSendingNTLMTraffic' -Value 0 -Type DWord
}
function Test-NTLMRestriction {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
    return (Get-ItemProperty -Path $p -Name 'RestrictSendingNTLMTraffic' -ErrorAction SilentlyContinue).RestrictSendingNTLMTraffic -ge 1
}

# --- Delegation Kerberos ---
function Protect-Delegation {
    # Squelette : a adapter a votre perimetre. Exemple : flag des comptes admins sensibles.
    # Get-ADGroupMember 'Domain Admins' | Set-ADUser -AccountNotDelegated $true
    Write-Warning 'Protect-Delegation : squelette a completer selon le perimetre de comptes sensibles.'
}
function Unprotect-Delegation {
    Write-Warning 'Unprotect-Delegation : squelette a completer.'
}
function Test-Delegation {
    # Retourne $false par defaut pour forcer une revue manuelle tant que non implemente.
    return $false
}

# --- Machine password policy ---
function Set-MachinePasswordPolicy {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
    Set-ItemProperty -Path $p -Name 'DisablePasswordChange' -Value 0 -Type DWord
    Set-ItemProperty -Path $p -Name 'MaximumPasswordAge' -Value 30 -Type DWord
}
function Reset-MachinePasswordPolicy {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
    Set-ItemProperty -Path $p -Name 'MaximumPasswordAge' -Value 90 -Type DWord
}
function Test-MachinePasswordPolicy {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
    return (Get-ItemProperty -Path $p -Name 'DisablePasswordChange' -ErrorAction SilentlyContinue).DisablePasswordChange -eq 0
}

#endregion

Export-ModuleMember -Function * -Alias *
