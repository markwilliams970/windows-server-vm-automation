# Installs IIS and verifies the default site actually responds over HTTP
# before returning - a broken install should fail the Packer build loudly,
# not silently produce a VM with no working web server. See CLAUDE.md's IIS
# section.
#
# Server and client Windows use entirely different cmdlet families for
# this: Install-WindowsFeature/Get-WindowsFeature are Server-only and don't
# exist on client SKUs at all, which instead use the DISM-backed
# Enable-WindowsOptionalFeature/Get-WindowsOptionalFeature. One script
# branches on (Get-ComputerInfo).OsProductType ("Server" vs "WorkStation")
# so services.yaml's single "iis" role name works unchanged on both.
$ErrorActionPreference = "Stop"

$osProductType = (Get-ComputerInfo).OsProductType
Write-Host "Installing IIS (OS product type: $osProductType)..."

if ($osProductType -eq "Server") {
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools -IncludeAllSubFeature | Out-Null

    $feature = Get-WindowsFeature -Name Web-Server
    if ($feature.InstallState -ne "Installed") {
        throw "Web-Server feature did not report Installed after Install-WindowsFeature (InstallState: $($feature.InstallState))"
    }
} else {
    Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole -All -NoRestart | Out-Null

    $feature = Get-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole
    if ($feature.State -ne "Enabled") {
        throw "IIS-WebServerRole did not report Enabled after Enable-WindowsOptionalFeature (State: $($feature.State))"
    }
}

$svc = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
if (-not $svc) {
    throw "W3SVC service not found after IIS install"
}
if ($svc.Status -ne "Running") {
    Start-Service W3SVC
    Start-Sleep -Seconds 2
    $svc.Refresh()
}
if ($svc.Status -ne "Running") {
    throw "W3SVC service is not running (status: $($svc.Status))"
}

Write-Host "Verifying default site responds over HTTP..."
try {
    $response = Invoke-WebRequest -Uri "http://localhost/" -UseBasicParsing -TimeoutSec 15
} catch {
    throw "HTTP request to default IIS site failed: $_"
}
if ($response.StatusCode -ne 200) {
    throw "Default IIS site returned HTTP $($response.StatusCode), expected 200"
}

Write-Host "IIS installed and verified: W3SVC running, default site returns HTTP 200."
