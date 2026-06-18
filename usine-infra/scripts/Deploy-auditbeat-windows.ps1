<#
.SYNOPSIS
    Automated Deployment Script for Auditbeat FIM on Windows File Server / DC.
    Target: Windows Server 2022 / 2025 (SOC BlueLock Production)
#>

$ElasticIP   = "10.30.0.151"
$BeatVersion = "8.12.2"
$WorkDir     = "C:\Program Files\Auditbeat"

Write-Host "[*] Initializing Auditbeat Endpoint Hardening Deployment..." -ForegroundColor Cyan

# Elevate privileges check
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Execution Failed: This deployment script requires administrative privileges."
    Exit
}

# Download and Extract Binary
$DownloadUrl = "https://artifacts.elastic.co/downloads/beats/auditbeat/auditbeat-$BeatVersion-windows-x86_64.zip"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Write-Host "[+] Downloading Auditbeat Security core v$BeatVersion..." -ForegroundColor Green
Invoke-WebRequest -Uri $DownloadUrl -OutFile "$env:TEMP\auditbeat.zip"

Write-Host "[+] Extracting security binaries..." -ForegroundColor Green
Expand-Archive -Path "$env:TEMP\auditbeat.zip" -DestinationPath "$env:TEMP\auditbeat_tmp" -Force
Move-Item -Path "$env:TEMP\auditbeat_tmp\auditbeat-$BeatVersion-windows-x86_64\*" -Destination $WorkDir -Force

# Generate Security-Oriented Configuration
Write-Host "[+] Injecting File Integrity Monitoring (FIM) rules..." -ForegroundColor Green
$Config = @"
auditbeat.modules:
  - module: file_integrity
    paths:
      - C:\Windows\System32\drivers\etc\hosts
      - C:\Users\Administrator\Documents
    recursive: true

  - module: system
    datasets:
      - host
      - process # Monitors rogue process creation on Windows
      - login

output.elasticsearch:
  hosts: ["http://$ElasticIP:9200"]
  username: "elastic"
  password: "Basile44"

setup.kibana:
  host: "http://$ElasticIP:5601"
"@
Set-Content -Path "$WorkDir\auditbeat.yml" -Value $Config -Force

# Register as a Windows Service and Run
Set-Location $WorkDir
Write-Host "[+] Registering Auditbeat security service..." -ForegroundColor Green
& .\install-service-auditbeat.ps1 | Out-Null

Set-Service auditbeat -StartupType Automatic
Start-Service auditbeat

Write-Host "[SUCCESS] Auditbeat endpoint compliance monitoring initialized." -ForegroundColor Green
