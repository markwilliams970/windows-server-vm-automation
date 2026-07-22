# Promotes this server to the first Domain Controller of a new AD forest,
# with DNS Server installed alongside (both required by CLAUDE.md's AD DS
# section). Domain name comes from $env:AD_DOMAIN_NAME, set by
# run-services.ps1 from the domain_name Packer variable - falls back to a
# sensible default so this script can also be run/tested standalone.
#
# Install-ADDSForest normally reboots the machine itself on completion.
# -NoRebootOnCompletion suppresses that: reboot instead happens under
# Packer's own "windows-restart" provisioner (windows-server.pkr.hcl /
# dev/role-test.pkr.hcl), which is designed to survive WinRM dropping and
# reconnect - an uncontrolled reboot mid-script here would just drop the
# still-running powershell provisioner's connection with no way to recover.
#
# AD DS/DNS aren't actually up until that later reboot completes, so this
# script can only configure the promotion, not verify it succeeded. It
# leaves a marker file for verify-post-reboot.ps1 to act on after the
# restart.
$ErrorActionPreference = "Stop"

$domainName = if ($env:AD_DOMAIN_NAME) { $env:AD_DOMAIN_NAME } else { "corp.example.internal" }
Write-Host "Promoting to Domain Controller for new forest: $domainName"

Write-Host "Installing AD-Domain-Services and DNS features..."
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools | Out-Null

$feature = Get-WindowsFeature -Name AD-Domain-Services
if ($feature.InstallState -ne "Installed") {
    throw "AD-Domain-Services feature did not report Installed after Install-WindowsFeature (InstallState: $($feature.InstallState))"
}

Import-Module ADDSDeployment

# Same disposable-lab placeholder as the local Administrator password
# (packer/variables.pkr.hcl's admin_password) - not treated as a real
# secret in this project. DSRM password requirements mirror the domain
# Administrator's, so reusing the same value keeps this to one password
# to remember for lab access.
$dsrmPassword = ConvertTo-SecureString "ChangeMe-Lab123!" -AsPlainText -Force

Write-Host "Running Install-ADDSForest (this can take several minutes)..."
try {
    Install-ADDSForest `
        -DomainName $domainName `
        -SafeModeAdministratorPassword $dsrmPassword `
        -InstallDns `
        -Force `
        -SkipPreChecks `
        -NoRebootOnCompletion `
        -ErrorAction Stop | Out-Null
} catch {
    throw "Install-ADDSForest failed: $_"
}

New-Item -Path "C:\Windows\Temp\.ad-ds-installed" -ItemType File -Force | Out-Null
Write-Host "AD DS promotion configured for domain '$domainName'. Verification deferred to verify-post-reboot.ps1 after the restart."
