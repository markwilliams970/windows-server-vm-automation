# Always invoked (same "PowerShell decides, HCL stays static" pattern as
# run-services.ps1), immediately after Packer's windows-restart provisioner.
# No-ops unless install-ad.ps1 actually ran, since AD DS/DNS only finish
# coming up after that reboot completes - install-ad.ps1 itself runs before
# the reboot and can't verify anything real yet.
$ErrorActionPreference = "Stop"

$marker = "C:\Windows\Temp\.ad-ds-installed"
if (-not (Test-Path $marker)) {
    Write-Host "No post-reboot verification needed (ad-ds was not selected)."
    exit 0
}

Write-Host "Verifying AD DS/DNS after promotion reboot..."

foreach ($svcName in @("NTDS", "DNS")) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        throw "Service '$svcName' not found after AD DS promotion"
    }
    if ($svc.Status -ne "Running") {
        throw "Service '$svcName' is not running after AD DS promotion (status: $($svc.Status))"
    }
    Write-Host "Service '$svcName' is running."
}

try {
    $domain = Get-ADDomain -ErrorAction Stop
} catch {
    throw "Get-ADDomain failed after promotion: $_"
}

Write-Host "AD DS verified: domain '$($domain.DNSRoot)' is up, NTDS and DNS services running."
