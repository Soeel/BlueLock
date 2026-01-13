
<# 
LAB "AD réaliste" (OU + Users + Groupes + Partages + ACL NTFS + GPO)
➡️ À lancer sur le DC (Server Core OK) en PowerShell Admin.

Ce script :
- Crée une arbo OU (LAB\Users, Groups, Computers, Servers, Workstations, ServiceAccounts)
- Crée des groupes (AGDLP simplifié)
- Crée des users “réalistes” par département + service accounts
- Crée des dossiers/partages + ACL NTFS (et tente de créer les SMB shares)
- Crée 2 GPO basiques et les lie aux OU Servers/Workstations
- Ajoute un FGPP (policy mdp fine-grained) appliqué aux groupes users

PRÉREQUIS : Domaine déjà créé (Install-ADDSForest terminé).
#>

[CmdletBinding()]
param(
  [string]$CompanyName = "Blue",
  [string]$RootOUName  = "Blue",
  [string]$ShareRoot   = "C:\Shares",
  [int]$UsersPerDept   = 10,
  [switch]$WhatIfOnly
)

# ------------------ Helpers ------------------
function Ensure-Module {
  param([string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    throw "Module requis introuvable: $Name (installe les RSAT/Features ou exécute sur un DC)."
  }
  Import-Module $Name -ErrorAction Stop
}

function New-RandomPassword {
  param([int]$Length = 16)
  $chars = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%*-_+=?"
  -join (1..$Length | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
}

function Ensure-OU {
  param([string]$Name, [string]$Path, [bool]$Protect = $true)
  $dn = "OU=$Name,$Path"
  $existing = Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$dn)" -ErrorAction SilentlyContinue
  if (-not $existing) {
    Write-Host "Création OU: $dn"
    if (-not $WhatIfOnly) {
      New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion:$Protect | Out-Null
    }
  } else {
    Write-Host "OU existe: $dn" -ForegroundColor DarkGray
  }
  return $dn
}

function Ensure-Group {
  param(
    [string]$Name,
    [string]$Path,
    [ValidateSet("Global","DomainLocal","Universal")] [string]$Scope,
    [string]$Desc = ""
  )
  $g = Get-ADGroup -Identity $Name -ErrorAction SilentlyContinue
  if (-not $g) {
    Write-Host "Création groupe: $Name ($Scope)"
    if (-not $WhatIfOnly) {
      New-ADGroup -Name $Name -SamAccountName $Name -GroupScope $Scope -GroupCategory Security -Path $Path -Description $Desc | Out-Null
    }
  } else {
    Write-Host "Groupe existe: $Name" -ForegroundColor DarkGray
  }
}

function Add-GroupMemberSafe {
  param([string]$Group, [string[]]$Members)
  foreach ($m in $Members) {
    try {
      if (-not $WhatIfOnly) { Add-ADGroupMember -Identity $Group -Members $m -ErrorAction Stop }
      Write-Host "Ajout membre: $m -> $Group" -ForegroundColor DarkGreen
    } catch {
      if ($_.Exception.Message -notmatch "already a member") {
        Write-Warning "Impossible d'ajouter $m à $Group : $($_.Exception.Message)"
      }
    }
  }
}

function Ensure-Folder {
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    Write-Host "Création dossier: $Path"
    if (-not $WhatIfOnly) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
  }
}

function Set-NTFSAcl {
  param([string]$Path, [hashtable[]]$Rules)
  if ($WhatIfOnly) { return }
  $acl = Get-Acl $Path

  # On retire les règles explicites (on laisse l’héritage si présent) et on ajoute nos règles
  $acl.Access | Where-Object { -not $_.IsInherited } | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }

  foreach ($r in $Rules) {
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $prop    = [System.Security.AccessControl.PropagationFlags]::None
    $type    = [System.Security.AccessControl.AccessControlType]::$($r.Type)
    $rights  = [System.Security.AccessControl.FileSystemRights]::$($r.Rights)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($r.Identity, $rights, $inherit, $prop, $type)
    $acl.AddAccessRule($rule) | Out-Null
  }
  Set-Acl -Path $Path -AclObject $acl
}

# ------------------ Modules ------------------
Ensure-Module ActiveDirectory
# GroupPolicy module peut être absent selon install; on gère ça clean.
$HasGPO = $true
try { Ensure-Module GroupPolicy } catch { $HasGPO = $false; Write-Warning "Module GroupPolicy absent → GPO ignorées (le reste sera créé)." }

# ------------------ Domaine ------------------
$domain   = Get-ADDomain
$domainDN = $domain.DistinguishedName
$netbios  = $domain.NetBIOSName

Write-Host "Domaine: $($domain.DNSRoot)  DN: $domainDN  NetBIOS: $netbios" -ForegroundColor Cyan

# ------------------ Maquette ------------------
$Depts = @(
  @{ Key="IT";         Name="Informatique" },
  @{ Key="HR";         Name="Ressources Humaines" },
  @{ Key="Finance";    Name="Finance" },
  @{ Key="Sales";      Name="Commercial" },
  @{ Key="Operations"; Name="Opérations" }
)

# ------------------ OU Layout ------------------
$rootOUdn = "OU=$RootOUName,$domainDN"

Ensure-OU -Name $RootOUName -Path $domainDN | Out-Null
Ensure-OU -Name "Users" -Path $rootOUdn | Out-Null
Ensure-OU -Name "Groups" -Path $rootOUdn | Out-Null
Ensure-OU -Name "Computers" -Path $rootOUdn | Out-Null
Ensure-OU -Name "Servers" -Path $rootOUdn | Out-Null
Ensure-OU -Name "Workstations" -Path $rootOUdn | Out-Null
Ensure-OU -Name "ServiceAccounts" -Path $rootOUdn | Out-Null

foreach ($d in $Depts) {
  Ensure-OU -Name $d.Key -Path "OU=Users,$rootOUdn" | Out-Null
  Ensure-OU -Name $d.Key -Path "OU=Computers,$rootOUdn" | Out-Null
}

# ------------------ Groupes (AGDLP) ------------------
$groupOuDn = "OU=Groups,$rootOUdn"

# Global groups (identité)
$GlobalGroups = @(
  "GG_IT_Users","GG_HR_Users","GG_Finance_Users","GG_Sales_Users","GG_Operations_Users",
  "GG_IT_Helpdesk","GG_IT_Admins","GG_Finance_Readers","GG_HR_Managers"
)

# Domain Local groups (ACL)
$LocalGroups = @(
  "DL_Share_Public_RW",
  "DL_Share_HR_RW","DL_Share_HR_R",
  "DL_Share_Finance_RW","DL_Share_Finance_R",
  "DL_Share_IT_RW","DL_Share_IT_R"
)

foreach ($g in $GlobalGroups) { Ensure-Group -Name $g -Path $groupOuDn -Scope Global -Desc "$CompanyName - $g" }
foreach ($g in $LocalGroups)  { Ensure-Group -Name $g -Path $groupOuDn -Scope DomainLocal -Desc "$CompanyName - $g" }

# Nesting GG -> DL
Add-GroupMemberSafe -Group "DL_Share_Public_RW" -Members @("GG_IT_Users","GG_HR_Users","GG_Finance_Users","GG_Sales_Users","GG_Operations_Users")

Add-GroupMemberSafe -Group "DL_Share_HR_RW" -Members @("GG_HR_Users","GG_HR_Managers")
Add-GroupMemberSafe -Group "DL_Share_HR_R"  -Members @("GG_IT_Helpdesk")

Add-GroupMemberSafe -Group "DL_Share_Finance_RW" -Members @("GG_Finance_Users")
Add-GroupMemberSafe -Group "DL_Share_Finance_R"  -Members @("GG_Finance_Readers","GG_IT_Helpdesk")

Add-GroupMemberSafe -Group "DL_Share_IT_RW" -Members @("GG_IT_Admins","GG_IT_Helpdesk")
Add-GroupMemberSafe -Group "DL_Share_IT_R"  -Members @("GG_IT_Users")

# ------------------ Users ------------------
$FirstNames = "Alex","Camille","Jordan","Morgan","Lina","Yanis","Nina","Hugo","Lea","Sami","Ines","Noah","Zoe","Lucas","Emma","Tom","Sarah","Louis","Eva","Adam"
$LastNames  = "Martin","Bernard","Dubois","Thomas","Robert","Richard","Petit","Durand","Leroy","Moreau","Simon","Laurent","Michel","Garcia","David","Bertrand","Roux","Vincent","Fournier","Lambert"

function Ensure-User {
  param(
    [string]$Sam,
    [string]$GivenName,
    [string]$Surname,
    [string]$DisplayName,
    [string]$Path,
    [string]$Department,
    [string]$Title,
    [string[]]$Groups
  )

  $u = Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue
  if (-not $u) {
    $pwd = New-RandomPassword 16
    Write-Host "Création user: $Sam ($Department)  PWD: $pwd" -ForegroundColor Yellow
    if (-not $WhatIfOnly) {
      New-ADUser -SamAccountName $Sam `
        -UserPrincipalName "$Sam@$($domain.DNSRoot)" `
        -Name $DisplayName -GivenName $GivenName -Surname $Surname -DisplayName $DisplayName `
        -Department $Department -Title $Title `
        -Path $Path `
        -AccountPassword (ConvertTo-SecureString $pwd -AsPlainText -Force) `
        -Enabled $true -ChangePasswordAtLogon $true | Out-Null
    }
  } else {
    Write-Host "User existe: $Sam" -ForegroundColor DarkGray
  }

  foreach ($g in $Groups) { Add-GroupMemberSafe -Group $g -Members @($Sam) }
}

foreach ($d in $Depts) {
  $deptOu = "OU=$($d.Key),OU=Users,$rootOUdn"
  $deptGG = "GG_$($d.Key)_Users"

  for ($i=1; $i -le $UsersPerDept; $i++) {
    $fn = $FirstNames | Get-Random
    $ln = $LastNames  | Get-Random

    $samBase = (($fn.Substring(0,1) + $ln) -replace "[^a-zA-Z]", "").ToLower()
    $samBase = $samBase.Substring(0, [Math]::Min(16, $samBase.Length))
    $sam = $samBase
    $n = 0
    while (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
      $n++
      $sam = ($samBase + $n)
      if ($sam.Length -gt 20) { $sam = $sam.Substring(0,20) }
    }

    $title = switch ($d.Key) {
      "IT"         { "Support Technician" }
      "HR"         { "HR Specialist" }
      "Finance"    { "Accountant" }
      "Sales"      { "Sales Representative" }
      "Operations" { "Operations Analyst" }
      default      { "Employee" }
    }

    $display = "$fn $ln"
    $groups = @($deptGG)

    # rôles aléatoires
    if ($d.Key -eq "IT" -and (Get-Random -Minimum 1 -Maximum 6) -eq 3) { $groups += "GG_IT_Helpdesk" }
    if ($d.Key -eq "IT" -and (Get-Random -Minimum 1 -Maximum 10) -eq 5) { $groups += "GG_IT_Admins" }
    if ($d.Key -eq "Finance" -and (Get-Random -Minimum 1 -Maximum 6) -eq 2) { $groups += "GG_Finance_Readers" }
    if ($d.Key -eq "HR" -and (Get-Random -Minimum 1 -Maximum 8) -eq 4) { $groups += "GG_HR_Managers" }

    Ensure-User -Sam $sam -GivenName $fn -Surname $ln -DisplayName $display -Path $deptOu -Department $d.Name -Title $title -Groups $groups
  }
}

# Service accounts
$svcOu = "OU=ServiceAccounts,$rootOUdn"
$svcAccounts = @(
  @{ Sam="svc_backup"; Desc="Service account - Backup agent" },
  @{ Sam="svc_sql";    Desc="Service account - SQL service" }
)
foreach ($svc in $svcAccounts) {
  $sam = $svc.Sam
  if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) {
    $pwd = New-RandomPassword 24
    Write-Host "Création svc: $sam  PWD: $pwd" -ForegroundColor Magenta
    if (-not $WhatIfOnly) {
      New-ADUser -SamAccountName $sam `
        -UserPrincipalName "$sam@$($domain.DNSRoot)" `
        -Name $sam -DisplayName $sam `
        -Description $svc.Desc `
        -Path $svcOu `
        -AccountPassword (ConvertTo-SecureString $pwd -AsPlainText -Force) `
        -Enabled $true `
        -PasswordNeverExpires $true `
        -CannotChangePassword $true | Out-Null
    }
  } else {
    Write-Host "Svc existe: $sam" -ForegroundColor DarkGray
  }
}

# ------------------ Partages + ACL ------------------
Ensure-Folder $ShareRoot

$shares = @(
  @{ Name="Public";  Path=(Join-Path $ShareRoot "Public");  DL_RW="DL_Share_Public_RW"; DL_R=$null },
  @{ Name="HR";      Path=(Join-Path $ShareRoot "HR");      DL_RW="DL_Share_HR_RW";     DL_R="DL_Share_HR_R" },
  @{ Name="Finance"; Path=(Join-Path $ShareRoot "Finance"); DL_RW="DL_Share_Finance_RW";DL_R="DL_Share_Finance_R" },
  @{ Name="IT";      Path=(Join-Path $ShareRoot "IT");      DL_RW="DL_Share_IT_RW";     DL_R="DL_Share_IT_R" }
)

foreach ($s in $shares) {
  Ensure-Folder $s.Path

  $rules = @(
    @{ Identity="BUILTIN\Administrators"; Rights="FullControl";   Type="Allow" },
    @{ Identity="NT AUTHORITY\SYSTEM";    Rights="FullControl";   Type="Allow" }
  )
  if ($s.DL_RW) { $rules += @{ Identity="$netbios\$($s.DL_RW)"; Rights="Modify";         Type="Allow" } }
  if ($s.DL_R)  { $rules += @{ Identity="$netbios\$($s.DL_R)";  Rights="ReadAndExecute"; Type="Allow" } }

  Write-Host "ACL NTFS: $($s.Path)"
  Set-NTFSAcl -Path $s.Path -Rules $rules

  # SMB share (si File Server cmdlets dispos)
  try {
    $existingShare = Get-SmbShare -Name $s.Name -ErrorAction SilentlyContinue
    if (-not $existingShare) {
      Write-Host "Création SMB share: $($s.Name) -> $($s.Path)"
      if (-not $WhatIfOnly) {
        $read = @()
        if ($s.DL_R) { $read = @("$netbios\$($s.DL_R)") }
        New-SmbShare -Name $s.Name -Path $s.Path -FullAccess "BUILTIN\Administrators" -ChangeAccess "$netbios\$($s.DL_RW)" -ReadAccess $read | Out-Null
      }
    } else {
      Write-Host "Share existe: $($s.Name)" -ForegroundColor DarkGray
    }
  } catch {
    Write-Warning "SMB share non créé (cmdlets SMB indisponibles / rôle). Tu peux ignorer si tu ne veux que les ACL NTFS."
  }
}

# ------------------ FGPP (policy mdp fine-grained) ------------------
$fgppName = "PSO-StandardUsers"
try {
  if (-not (Get-ADFineGrainedPasswordPolicy -Identity $fgppName -ErrorAction SilentlyContinue)) {
    Write-Host "Création FGPP: $fgppName"
    if (-not $WhatIfOnly) {
      New-ADFineGrainedPasswordPolicy -Name $fgppName `
        -Precedence 100 `
        -MinPasswordLength 14 `
        -PasswordHistoryCount 24 `
        -ComplexityEnabled $true `
        -LockoutThreshold 8 `
        -LockoutObservationWindow (New-TimeSpan -Minutes 30) `
        -LockoutDuration (New-TimeSpan -Minutes 30) `
        -MaxPasswordAge (New-TimeSpan -Days 60) | Out-Null
    }
  }

  $targets = @("GG_IT_Users","GG_HR_Users","GG_Finance_Users","GG_Sales_Users","GG_Operations_Users")
  foreach ($t in $targets) {
    Write-Host "Affectation FGPP $fgppName -> $t"
    if (-not $WhatIfOnly) { Add-ADFineGrainedPasswordPolicySubject -Identity $fgppName -Subjects $t -ErrorAction SilentlyContinue }
  }
} catch {
  Write-Warning "FGPP non appliqué: $($_.Exception.Message)"
}

# ------------------ GPO (si module dispo) ------------------
if ($HasGPO) {
  function Ensure-GPO {
    param([string]$Name)
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if (-not $gpo) {
      Write-Host "Création GPO: $Name"
      if (-not $WhatIfOnly) { $gpo = New-GPO -Name $Name }
    } else {
      Write-Host "GPO existe: $Name" -ForegroundColor DarkGray
    }
    return $gpo
  }

  $gpoPrefix = "$CompanyName-$RootOUName"

  # Workstations baseline
  $gpoWS = Ensure-GPO -Name "$gpoPrefix-Workstations-Baseline"
  if (-not $WhatIfOnly) {
    # verrouillage écran (HKCU policies) + UAC
    Set-GPRegistryValue -Name $gpoWS.DisplayName -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" -ValueName "ScreenSaveActive" -Type String -Value "1"
    Set-GPRegistryValue -Name $gpoWS.DisplayName -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" -ValueName "ScreenSaverIsSecure" -Type String -Value "1"
    Set-GPRegistryValue -Name $gpoWS.DisplayName -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" -ValueName "ScreenSaveTimeOut" -Type String -Value "900"
    Set-GPRegistryValue -Name $gpoWS.DisplayName -Key "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "EnableLUA" -Type DWord -Value 1
  }
  try {
    $wsOU = "OU=Workstations,$rootOUdn"
    Write-Host "Link GPO -> $wsOU"
    if (-not $WhatIfOnly) { New-GPLink -Name $gpoWS.DisplayName -Target $wsOU -Enforced:$false -ErrorAction SilentlyContinue | Out-Null }
  } catch { Write-Warning "Link GPO Workstations impossible: $($_.Exception.Message)" }

  # Servers baseline
  $gpoSV = Ensure-GPO -Name "$gpoPrefix-Servers-Baseline"
  if (-not $WhatIfOnly) {
    Set-GPRegistryValue -Name $gpoSV.DisplayName -Key "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" -ValueName "NoLMHash" -Type DWord -Value 1
    Set-GPRegistryValue -Name $gpoSV.DisplayName -Key "HKLM\Software\Policies\Microsoft\Windows\EventLog\Security" -ValueName "MaxSize" -Type DWord -Value 196608
  }
  try {
    $svOU = "OU=Servers,$rootOUdn"
    Write-Host "Link GPO -> $svOU"
    if (-not $WhatIfOnly) { New-GPLink -Name $gpoSV.DisplayName -Target $svOU -Enforced:$false -ErrorAction SilentlyContinue | Out-Null }
  } catch { Write-Warning "Link GPO Servers impossible: $($_.Exception.Message)" }

} else {
  Write-Host "⚠️ GPO ignorées (module GroupPolicy absent). Le reste (OU/users/groupes/ACL) est OK." -ForegroundColor Yellow
}

Write-Host "`n✅ Terminé : OU + groupes + users + ACL + (GPO si dispo) créés sous OU=$RootOUName" -ForegroundColor Cyan
if ($WhatIfOnly) { Write-Host "Mode WhatIfOnly : aucune modification n'a été faite." -ForegroundColor Yellow }
