<#
.SYNOPSIS
    Automated Deployment Script for Winlogbeat on Active Directory Domain Controller.
    Target: Windows Server 2022 / 2025 (SOC BlueLock Production)
#>

$ElasticIP   = "10.30.0.151"
$BeatVersion = "8.12.2"
$WorkDir     = "C:\Program Files\Winlogbeat"

Write-Host "[*] Initializing Winlogbeat Automated Deployment Suite..." -ForegroundColor Cyan

# Elevate privileges check
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Execution Failed: This deployment script requires administrative privileges."
    Exit
}

# Download and Extract Binary
$DownloadUrl = "https://artifacts.elastic.co/downloads/beats/winlogbeat/winlogbeat-$BeatVersion-windows-x86_64.zip"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Write-Host "[+] Downloading Winlogbeat MSI payload v$BeatVersion..." -ForegroundColor Green
Invoke-WebRequest -Uri $DownloadUrl -OutFile "$env:TEMP\winlogbeat.zip"

Write-Host "[+] Extracting binaries to production directory..." -ForegroundColor Green
Expand-Archive -Path "$env:TEMP\winlogbeat.zip" -DestinationPath "$env:TEMP\winlogbeat_tmp" -Force
Move-Item -Path "$env:TEMP\winlogbeat_tmp\winlogbeat-$BeatVersion-windows-x86_64\*" -Destination $WorkDir -Force

# Generate Production YAML Configuration
Write-Host "[+] Injecting winlogbeat.yml SIEM target configuration..." -ForegroundColor Green
$Config = @"
winlogbeat.event_logs:
  - name: Application
  - name: Security
    event_id: 4624, 4625, 4720, 4722, 4724, 4738 # Logon success/failures, User management
  - name: System
  - name: Directory Service # Critical for Active Directory DC Audit
  - name: DNS Server

output.elasticsearch:
  hosts: ["http://$ElasticIP:9200"]
  username: "elastic"
  password: "Basile44"

setup.kibana:
  host: "http://$ElasticIP:5601"
"@
Set-Content -Path "$WorkDir\winlogbeat.yml" -Value $Config -Force

# Register as a Windows Service and Run
Set-Location $WorkDir
Write-Host "[+] Registering Windows Service Daemon..." -ForegroundColor Green
& .\install-service-winlogbeat.ps1 | Out-Null

Set-Service winlogbeat -StartupType Automatic
Start-Service winlogbeat

Write-Host "[SUCCESS] Winlogbeat Service is fully functional and streaming logs to SIEM." -ForegroundColor Green
