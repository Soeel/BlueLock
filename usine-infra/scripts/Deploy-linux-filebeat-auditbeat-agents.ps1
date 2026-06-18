<#
.SYNOPSIS
    Cross-Platform PowerShell Orchestrator for Linux Agents.
    Deploys Filebeat & Auditbeat on Debian 12 (Wiki.js / Bastion / ELK Server)
#>

$LinuxTargets = @("10.30.0.154", "10.30.0.151") # Vos IPs Linux (Web & ELK)
$ElasticIP    = "10.30.0.151"
$BeatVersion  = "8.12.2"

Write-Host "[*] Launching Remote Linux Agents Deployment via PowerShell Core..." -ForegroundColor Cyan

foreach ($IP in $LinuxTargets) {
    Write-Host "`n[*] Target Host: $IP" -ForegroundColor Yellow

    # Commande Bash envoyée à distance pour tout installer d'un coup
    $RemoteScript = @"
        sudo apt-get update && sudo apt-get install -y curl gnupg
        
        # Téléchargement et installation d'Auditbeat & Filebeat
        wget -q https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-$BeatVersion-amd64.deb -O /tmp/filebeat.deb
        wget -q https://artifacts.elastic.co/downloads/beats/auditbeat/auditbeat-$BeatVersion-amd64.deb -O /tmp/auditbeat.deb
        sudo dpkg -i /tmp/filebeat.deb /tmp/auditbeat.deb

        # Injection de la configuration SIEM dans Filebeat
        sudo sed -i 's/localhost:9200/$ElasticIP:9200/g' /etc/filebeat/filebeat.yml
        
        # Injection de la configuration SIEM dans Auditbeat
        sudo sed -i 's/localhost:9200/$ElasticIP:9200/g' /etc/auditbeat/auditbeat.yml

        # Activation des démons au démarrage
        sudo systemctl enable filebeat auditbeat --now
        echo '[+] Remote deployment completed successfully.'
"@

    # Exécution de la commande SSH native depuis PowerShell
    ssh -o StrictHostKeyChecking=no root@$IP "$RemoteScript"
}

Write-Host "`n[SUCCESS] All Linux endpoints have been configured with Filebeat & Auditbeat." -ForegroundColor Green
