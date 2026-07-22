# Installs SQL Server 2022 Developer Edition (free for non-production use,
# functionally identical to Enterprise - full feature set including SQL
# Server Agent, unlike Express - chosen to more realistically simulate an
# enterprise customer's SQL Server for Datadog integration testing) as an
# independent, single-layer role: no dependency on ad-ds or iis.
#
# Mixed Mode authentication (SQL logins + Windows auth), since a later
# Datadog integration phase will likely want a dedicated SQL login rather
# than requiring Windows/AD-integrated auth - a common pattern in Datadog's
# own SQL Server integration setup docs.
#
# Bootstrap URL, /FEATURES value, and service-account parameter behavior
# were all verified directly against Microsoft's own Learn docs and a live
# HEAD request before writing this (not guessed) - see the AD DS build for
# why that discipline matters here (a wrong installer URL or unattended
# switch fails loudly, but wastes a full test cycle finding out).
$ErrorActionPreference = "Stop"

# Same disposable-lab placeholder as the local Administrator password and
# the AD DS DSRM password - not treated as a real secret in this project.
$saPassword = "ChangeMe-Lab123!"

$bootstrapUrl = "https://go.microsoft.com/fwlink/?linkid=2215158"
$bootstrapPath = "C:\Windows\Temp\SQL2022-SSEI-Dev.exe"
$mediaDir = "C:\SQLMedia"

Write-Host "Downloading SQL Server 2022 Developer Edition bootstrapper..."
Invoke-WebRequest -Uri $bootstrapUrl -OutFile $bootstrapPath -UseBasicParsing

Write-Host "Downloading full installation media (this can take a while)..."
New-Item -Path $mediaDir -ItemType Directory -Force | Out-Null
$proc = Start-Process -FilePath $bootstrapPath -ArgumentList @(
    "/Action=Download",
    "/MediaType=ISO",
    "/MediaPath=$mediaDir",
    "/Quiet"
) -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "SQL Server media download failed with exit code $($proc.ExitCode)"
}

$isoFile = Get-ChildItem -Path $mediaDir -Filter "*.iso" | Select-Object -First 1
if (-not $isoFile) {
    throw "No ISO found in $mediaDir after bootstrapper download"
}

Write-Host "Mounting $($isoFile.FullName)..."
$mountResult = Mount-DiskImage -ImagePath $isoFile.FullName -PassThru
$driveLetter = ($mountResult | Get-Volume).DriveLetter
if (-not $driveLetter) {
    throw "Could not determine drive letter for mounted SQL Server media"
}

Write-Host "Running SQL Server setup (this can take several minutes)..."
$setupExe = "${driveLetter}:\setup.exe"
$setupArgs = @(
    "/Q",
    "/ACTION=Install",
    "/FEATURES=SQL",
    "/INSTANCENAME=MSSQLSERVER",
    "/SECURITYMODE=SQL",
    "/SAPWD=$saPassword",
    # Values containing spaces (the two built-in account names below) need
    # their own embedded quotes - Start-Process -ArgumentList does not
    # auto-quote array elements, so an unquoted "NT AUTHORITY\NETWORK
    # SERVICE" gets split into multiple broken argv tokens by the child
    # process's own command-line parsing. Confirmed live: this exact bug
    # caused setup.exe to fail with a generic 0x80004003 (E_POINTER).
    '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"',
    '/SQLSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"',
    '/AGTSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"',
    "/TCPENABLED=1",
    "/IACCEPTSQLSERVERLICENSETERMS",
    # Required whenever /Q is specified. Without this, setup tries to check
    # Windows Update for product updates as part of unattended install and
    # fails (0x876E0003) in this isolated lab network - not optional here.
    "/UPDATEENABLED=False"
)
$proc = Start-Process -FilePath $setupExe -ArgumentList $setupArgs -Wait -PassThru
$setupExitCode = $proc.ExitCode

Dismount-DiskImage -ImagePath $isoFile.FullName | Out-Null

if ($setupExitCode -ne 0) {
    throw "SQL Server setup failed with exit code $setupExitCode. See C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt for details."
}

$svc = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
if (-not $svc) {
    throw "MSSQLSERVER service not found after install"
}
if ($svc.Status -ne "Running") {
    throw "MSSQLSERVER service is not running after install (status: $($svc.Status))"
}

# Developer Edition includes SQL Server Agent (the reason it was chosen
# over Express) - make sure it's actually running, not just installed,
# since a realistic enterprise environment (and Datadog's Agent job
# monitoring) expects it available.
$agentSvc = Get-Service -Name "SQLSERVERAGENT" -ErrorAction SilentlyContinue
if ($agentSvc) {
    Set-Service -Name "SQLSERVERAGENT" -StartupType Automatic
    if ($agentSvc.Status -ne "Running") {
        Start-Service "SQLSERVERAGENT"
    }
}

Write-Host "Verifying SQL Server responds to a query over Mixed Mode auth..."
Add-Type -AssemblyName "System.Data"
$connectionString = "Server=localhost;Database=master;User Id=sa;Password=$saPassword;TrustServerCertificate=True;"
try {
    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = "SELECT 1"
    $result = $command.ExecuteScalar()
    $connection.Close()
} catch {
    throw "SQL connectivity check failed: $_"
}
if ($result -ne 1) {
    throw "Unexpected result from verification query: $result"
}

Write-Host "SQL Server installed and verified: MSSQLSERVER running, SA login works, SELECT 1 returned successfully."
