# AWS CLI v2 install script for Windows (PowerShell 5.1+).
#
# Defaults to a user-local install under %LOCALAPPDATA%. Use -System for the
# traditional Program Files layout (requires admin). See -Help for details.

param(
    [string] $Version,  # specific version to install; empty means "latest"
    [switch] $System,   # install system-wide (Program Files); requires admin
    [switch] $Quiet,    # suppress non-essential stdout
    [switch] $SkipSignatureVerification,  # explicit opt-out of installer verification
    [switch] $Help
)

# Allow the signature-verification opt-out via environment as well as the
# -SkipSignatureVerification switch. This is a version-independent escape hatch
# for callers that cannot pass the switch -- notably `aws update` run from an
# older AWS CLI, whose bundled update command predates the switch but still
# fetches and runs this (newer, verification-enforcing) script.
# Match the AWS CLI boolean-env-var convention (ensure_boolean): the value is
# true only when it equals "true", case-insensitively. -ieq is case-insensitive
# and null-safe.
if (-not $SkipSignatureVerification -and
    $env:AWS_CLI_INSTALL_SKIP_SIGNATURE_VERIFICATION -ieq 'true') {
    $SkipSignatureVerification = $true
}

# Stop on any error so failures don't silently continue.
$ErrorActionPreference = 'Stop'
# PowerShell 5.1 defaults to TLS 1.0; force 1.2 for the CDN.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================================
# Configuration
# ============================================================================

$DownloadBaseUrl    = 'https://awscli.amazonaws.com'
$LatestVersionUrl   = "$DownloadBaseUrl/v2/version.txt"

# The system MSI always installs to the 64-bit Program Files. Use
# ProgramW6432, which points there even from a 32-bit PowerShell host;
# $env:ProgramFiles would resolve to "Program Files (x86)" under 32-bit
# and make the post-install check look in the wrong place.
$SystemProgramFiles = $env:ProgramW6432
if (-not $SystemProgramFiles) { $SystemProgramFiles = $env:ProgramFiles }
$SystemInstallDir   = Join-Path $SystemProgramFiles 'Amazon\AWSCLIV2'
$UserInstallDir     = Join-Path $env:LOCALAPPDATA 'Programs\Amazon\AWSCLIV2'

$DistributionSource = 'script-exe'
if ($env:AWS_CLI_DISTRIBUTION_SOURCE_OVERRIDE) {
    $DistributionSource = $env:AWS_CLI_DISTRIBUTION_SOURCE_OVERRIDE
}
$DownloadQuery = "?src=$DistributionSource"

$MsiexecSuccessCodes = @(0, 1641, 3010)

# ============================================================================
# Output helpers
# ============================================================================

$EscRed    = [char]27 + '[31m'
$EscYellow = [char]27 + '[33m'
$EscGreen  = [char]27 + '[32m'
$EscReset  = [char]27 + '[0m'

function Use-Color {
    param([bool] $IsErrStream)
    if ($env:NO_COLOR) { return $false }
    if ($IsErrStream) { return -not [Console]::IsErrorRedirected }
    return -not [Console]::IsOutputRedirected
}

# Progress/info on stdout, silenced by -Quiet.
function Write-Info {
    param([string] $Message)
    if (-not $Quiet) { Write-Host $Message }
}

# Green success on stdout, silenced by -Quiet.
function Write-Success {
    param([string] $Message)
    if ($Quiet) { return }
    if (Use-Color $false) {
        Write-Host "$EscGreen$Message$EscReset"
    } else {
        Write-Host $Message
    }
}

# Yellow warning on stderr; never silenced.
function Write-Warn {
    param([string] $Message)
    if (Use-Color $true) {
        [Console]::Error.WriteLine("${EscYellow}aws-cli installer: warning:${EscReset} $Message")
    } else {
        [Console]::Error.WriteLine("aws-cli installer: warning: $Message")
    }
}

# Red error on stderr; never silenced.
function Write-Err {
    param([string] $Message)
    if (Use-Color $true) {
        [Console]::Error.WriteLine("${EscRed}aws-cli installer: error:${EscReset} $Message")
    } else {
        [Console]::Error.WriteLine("aws-cli installer: error: $Message")
    }
}

# Record the exit code and throw to unwind. We never call `exit` here: under
# `irm | iex` the script runs in the caller's session, so `exit` would close
# the user's PowerShell. The error is printed by the top-level handler (which
# also reports any other exception), so nothing is silently swallowed; the
# recorded code becomes a process exit status only when run as a file.
$Script:ExitCode = 0
function Throw-Error {
    param([int] $Code, [string] $Message)
    $Script:ExitCode = $Code
    throw $Message
}

# ============================================================================
# Argument validation
# ============================================================================

function Show-Help {
    @"
Usage: install.ps1 [-Version <X.Y.Z>] [-System] [-Quiet]
                   [-SkipSignatureVerification] [-Help]

Install or update the AWS CLI v2.

Parameters:
  -Version <X.Y.Z>  Install a specific fully-qualified version. Otherwise
                    installs the latest release. Downgrades are not
                    supported. To install a previous version, see:
                    https://docs.aws.amazon.com/cli/latest/userguide/getting-started-version.html
  -System           Install system-wide (requires admin). Otherwise installs
                    under %LOCALAPPDATA%\Programs\Amazon\AWSCLIV2\.
  -Quiet            Suppress non-essential output. Errors and warnings are
                    still printed to stderr.
  -SkipSignatureVerification
                    Skip signature verification of the downloaded installer.
                    NOT RECOMMENDED: this disables a security control that
                    confirms the installer is authentic. Only use it if you
                    understand and accept the risk. The
                    AWS_CLI_INSTALL_SKIP_SIGNATURE_VERIFICATION env var
                    (below) does the same.
  -Help             Show this help and exit.

Environment:
  AWS_CLI_INSTALL_SKIP_SIGNATURE_VERIFICATION
                    Set to "true" (case-insensitive) to skip signature
                    verification, equivalent to the
                    -SkipSignatureVerification switch. Provided so callers
                    that cannot pass the switch (e.g. an older AWS CLI running
                    'aws update') can still opt out. NOT RECOMMENDED.
"@ | Write-Host
}

# Accept only fully-qualified MAJOR.MINOR.PATCH.
function Test-Semver {
    param([string] $Value)
    return ($Value -match '^\d+\.\d+\.\d+$')
}

# Returns $false when the run should stop early without error.
function Validate-Args {
    if ($Help) { Show-Help; return $false }
    if ($Version -and -not (Test-Semver $Version)) {
        Throw-Error 2 "-Version must be fully-qualified semver (e.g. 2.27.41), got: $Version"
    }
    return $true
}

# ============================================================================
# Pre-install checks
# ============================================================================

function Test-Windows {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $IsWindows
    }
    return $true
}

function Assert-Platform {
    if (-not (Test-Windows)) {
        Throw-Error 1 'unsupported OS. install.ps1 supports only Windows; use install.sh on Linux/macOS.'
    }
}

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-SystemPrivilege {
    if ($System -and -not (Test-IsAdmin)) {
        Throw-Error 1 '-System requires admin privileges. Re-run from an elevated PowerShell, or omit -System for a user-local install.'
    }
}

# ============================================================================
# Path resolution
# ============================================================================

$Script:InstallDir = $null

function Resolve-InstallPath {
    if ($System) {
        $Script:InstallDir = $SystemInstallDir
    } else {
        if (-not $env:LOCALAPPDATA) {
            Throw-Error 2 'LOCALAPPDATA is not set; cannot resolve user-local install path.'
        }
        $Script:InstallDir = $UserInstallDir
    }
}

# ============================================================================
# Download
# ============================================================================

$Script:TempDir = $null   # working dir; removed in the finally block

function New-TempDir {
    $Script:TempDir = Join-Path $env:TEMP "aws-cli-install-$([guid]::NewGuid().Guid)"
    New-Item -ItemType Directory -Path $Script:TempDir -Force | Out-Null
}

function Remove-TempDir {
    if ($Script:TempDir -and (Test-Path $Script:TempDir)) {
        try {
            Remove-Item -Recurse -Force $Script:TempDir -ErrorAction Stop
        } catch {
            Write-Warn "could not remove temp directory: $Script:TempDir"
        }
    }
}

function Get-InstallerFilename {
    if ($System) {
        if ($Script:TargetVersion) {
            return "AWSCLIV2-$($Script:TargetVersion).msi"
        }
        return 'AWSCLIV2.msi'
    }
    if ($Script:TargetVersion) {
        return "AWSCLIV2-User-$($Script:TargetVersion).msi"
    }
    return 'AWSCLIV2-User.msi'
}

function Get-InstallerUrl {
    return "$DownloadBaseUrl/$(Get-InstallerFilename)$DownloadQuery"
}

function Download-File {
    param([string] $Url, [string] $Out)
    Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing -TimeoutSec 60
}

function Download-WithRetry {
    param([string] $Url, [string] $Out, [string] $Label)
    Write-Info "Downloading $Label from $Url"
    try {
        Download-File -Url $Url -Out $Out
        return
    } catch {
        Write-Warn "download of $Label failed; retrying once"
    }
    try {
        Download-File -Url $Url -Out $Out
    } catch {
        Throw-Error 1 "failed to download $Label from $Url after one retry: $($_.Exception.Message)"
    }
}

$Script:InstallerPath = $null

function Download-Installer {
    $Script:InstallerPath = Join-Path $Script:TempDir 'AWSCLIV2.msi'
    Download-WithRetry -Url (Get-InstallerUrl) -Out $Script:InstallerPath -Label 'AWS CLI installer'
}

# ============================================================================
# Signature verification
# ============================================================================

# The AWS CLI MSI is Authenticode-signed by AWS Signer using a DigiCert-issued
# EV code-signing certificate. We verify the signer *identity* (organization +
# issuing CA) rather than a specific certificate thumbprint: the certificate is
# renewed (~yearly) and pinning its thumbprint would break installs on every
# rotation, whereas the organization and issuing CA are stable across renewals.
#
# The organization must be one of AWS's approved code-signing org names. Check
# a signed MSI on Windows with:
#   (Get-AuthenticodeSignature .\AWSCLIV2.msi).SignerCertificate |
#       Format-List Subject, Issuer
$AwsCliSignerOrgs = @(
    'Amazon.com Services LLC',
    'Amazon Web Services, Inc.',
    'Amazon.com, Inc.'
)
$AwsCliSignerIssuerPattern = 'DigiCert'

# Extract the Organization (O) relative distinguished name from a certificate's
# subject/issuer. Format($true) emits one RDN per line, so an O value that
# itself contains commas (e.g. "Amazon Web Services, Inc.") parses correctly.
# Format wraps such values in double quotes, so we strip a surrounding quote
# pair before returning so the value matches the plain allowlist entry.
function Get-CertOrg {
    param([System.Security.Cryptography.X509Certificates.X500DistinguishedName] $Name)
    foreach ($line in ($Name.Format($true) -split "\r?\n")) {
        if ($line -match '^O=(.*)$') {
            $v = $matches[1].Trim()
            if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
                $v = $v.Substring(1, $v.Length - 2) -replace '""', '"'
            }
            return $v
        }
    }
    return $null
}

function Verify-Installer {
    # Verification is on by default. -SkipSignatureVerification is an explicit,
    # human-made opt-out; it disables a security control, so it is never silent.
    if ($SkipSignatureVerification) {
        Write-Warn ('signature verification disabled (via ' +
            '-SkipSignatureVerification or ' +
            'AWS_CLI_INSTALL_SKIP_SIGNATURE_VERIFICATION); installing ' +
            'without verifying installer authenticity.')
        return
    }

    $sig = Get-AuthenticodeSignature -FilePath $Script:InstallerPath

    # 1. The signature must be cryptographically valid: the file is unmodified
    #    and chains to a certificate trusted by the OS.
    if ($sig.Status -ne 'Valid') {
        Throw-Error 1 ("Authenticode signature verification failed for " +
            "$($Script:InstallerPath): status is '$($sig.Status)'. " +
            'Refusing to install.')
    }

    $cert = $sig.SignerCertificate
    if (-not $cert) {
        Throw-Error 1 ("Authenticode signature for $($Script:InstallerPath) " +
            'has no signer certificate. Refusing to install.')
    }

    # 2. The signer must be AWS. A valid signature alone only proves *some*
    #    trusted CA signed it; checking the organization confirms it is ours.
    #    Match the O RDN exactly, not a substring of the whole subject DN: a
    #    substring match would also accept a cert whose CN/OU merely contained
    #    one of these strings.
    $subjectOrg = Get-CertOrg $cert.SubjectName
    if ($AwsCliSignerOrgs -notcontains $subjectOrg) {
        Throw-Error 1 ("$($Script:InstallerPath) is not signed by AWS " +
            "(signer O=$subjectOrg; subject: $($cert.Subject)). " +
            'Refusing to install.')
    }

    # 3. The certificate must be issued by our CA (DigiCert). This narrows
    #    "any trusted CA" down to the CA that issues AWS's code-signing certs.
    $issuerOrg = Get-CertOrg $cert.IssuerName
    if ($issuerOrg -notlike "*$AwsCliSignerIssuerPattern*") {
        Throw-Error 1 ("$($Script:InstallerPath) was signed by an unexpected " +
            "certificate authority (issuer O=$issuerOrg; " +
            "issuer: $($cert.Issuer)). Refusing to install.")
    }

    Write-Success 'MSI Authenticode signature verified (signed by AWS).'
}

# ============================================================================
# Version resolution
# ============================================================================

# Extracts the semver from `aws --version`.
function Read-InstalledVersion {
    param([string] $AwsExe)
    if (-not (Test-Path $AwsExe)) { return $null }
    try {
        $out = & $AwsExe --version 2>$null
    } catch {
        return $null
    }
    if ($out -match '^aws-cli/(\d+\.\d+\.\d+)') {
        return $Matches[1]
    }
    return $null
}

function Get-CandidateAwsBinary {
    return Join-Path $Script:InstallDir 'aws.exe'
}

$Script:PreInstallVersion  = $null   # version present before install
$Script:TargetVersion      = $null   # version we resolved to install
$Script:PostInstallVersion = $null   # version present after install

function Capture-PreInstallVersion {
    $Script:PreInstallVersion = Read-InstalledVersion (Get-CandidateAwsBinary)
}

# Best-effort fetch of the published "latest" version; $null on any failure.
function Fetch-LatestVersion {
    try {
        $resp = Invoke-WebRequest -Uri $LatestVersionUrl -UseBasicParsing -TimeoutSec 10
        $text = ([string] $resp.Content).Trim()
        if (Test-Semver $text) { return $text }
    } catch {}
    return $null
}

function Resolve-TargetAndAnnounce {
    if ($Version) {
        $Script:TargetVersion = $Version
    } else {
        $Script:TargetVersion = Fetch-LatestVersion
    }

    if (-not $Script:TargetVersion -or -not $Script:PreInstallVersion) {
        if ($Script:TargetVersion) {
            Write-Info "Installing AWS CLI $($Script:TargetVersion)"
        }
        return $true
    }

    if ($Script:TargetVersion -eq $Script:PreInstallVersion) {
        Write-Info "AWS CLI $($Script:TargetVersion) is already installed at $($Script:InstallDir); nothing to do."
        return $false
    }

    if ([version]$Script:TargetVersion -lt [version]$Script:PreInstallVersion) {
        Write-Info "AWS CLI $($Script:PreInstallVersion) is already installed at $($Script:InstallDir). To install $($Script:TargetVersion), uninstall the existing AWS CLI at $($Script:InstallDir) and try again. See https://docs.aws.amazon.com/cli/latest/userguide/uninstall.html"
        return $false
    }

    Write-Info "Installing AWS CLI $($Script:PreInstallVersion) -> $($Script:TargetVersion)"
    return $true
}

# ============================================================================
# Install
# ============================================================================

function Run-Installer {
    $msiFilename = Split-Path $Script:InstallerPath -Leaf
    $msiDir = Split-Path $Script:InstallerPath -Parent

    $msiArgs = @('/i', $msiFilename, '/qn', '/norestart')

    Write-Info 'Running MSI installer...'
    $proc = Start-Process -FilePath 'msiexec' -ArgumentList $msiArgs `
                          -WorkingDirectory $msiDir -Wait -PassThru
    if ($MsiexecSuccessCodes -notcontains $proc.ExitCode) {
        Throw-Error 1 "msiexec failed with exit code $($proc.ExitCode)"
    }
}

# ============================================================================
# Post-install
# ============================================================================

function Verify-InstallRuns {
    $awsExe = Get-CandidateAwsBinary
    $Script:PostInstallVersion = Read-InstalledVersion $awsExe
    if (-not $Script:PostInstallVersion) {
        Throw-Error 1 "post-install check failed: '$awsExe --version' did not run successfully."
    }
}

# Writes install-time metadata next to the bundled metadata.json. `aws update`
# reads this back to learn where and how the CLI was installed. No bin_dir
# field - on Windows the MSI manages PATH, there's no symlink dir to record.
function Write-InstallJson {
    $installJson = Join-Path $Script:InstallDir 'awscli\data\install.json'
    $parent = Split-Path $installJson -Parent
    if (-not (Test-Path $parent)) { return }

    $obj = [ordered]@{
        distribution_source = $DistributionSource
        install_dir         = $Script:InstallDir
        script_install      = [ordered]@{
            system           = [bool]$System
            version_resolved = $Script:PostInstallVersion
            quiet            = [bool]$Quiet
        }
    }
    $json = $obj | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText($installJson, $json, (New-Object Text.UTF8Encoding $false))
}

function Invoke-PostInstallChecks {
    Verify-InstallRuns
    Write-InstallJson
    Write-Success "AWS CLI $($Script:PostInstallVersion) installed to $($Script:InstallDir)"
    Write-Info "When multiple installs exist, PATH order determines which 'aws' runs."
}

# ============================================================================
# Entry point
# ============================================================================

function Invoke-Main {
    try {
        # Pre-flight: validate args and environment before touching disk/network.
        if (-not (Validate-Args)) { return }
        Assert-Platform
        Assert-SystemPrivilege
        Resolve-InstallPath

        # Install: stage, resolve target (may short-circuit), download, run.
        New-TempDir
        Capture-PreInstallVersion
        if (-not (Resolve-TargetAndAnnounce)) { return }
        Download-Installer
        Verify-Installer
        Run-Installer
        Invoke-PostInstallChecks
    } finally {
        # Always remove the temp dir, even on error or early return.
        Remove-TempDir
    }
}

# Run the body inside a scriptblock and catch errors here rather than calling
# `exit` from deep in the script. Under `irm | iex` the script shares the
# caller's session, so `exit` would close the user's PowerShell window. All
# errors are printed here -- both Throw-Error (which sets $Script:ExitCode)
# and any other exception raised under $ErrorActionPreference = 'Stop' -- so
# nothing is silently swallowed.
& {
    try {
        Invoke-Main
    } catch {
        Write-Err $_.Exception.Message
        if ($Script:ExitCode -eq 0) { $Script:ExitCode = 1 }
    }
}

# Only set a real process exit status when invoked as a file (powershell
# -File, or .\install.ps1), where $PSCommandPath is populated. Under
# `irm | iex` $PSCommandPath is empty and calling `exit` would terminate the
# user's shell, so we leave it alone there.
if ($PSCommandPath) {
    exit $Script:ExitCode
}

# SIG # Begin signature block
# MIIuqgYJKoZIhvcNAQcCoIIumzCCLpcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDO/0N7MHda+3Bk
# N7ebIeGtki9LdOlIK8K99LAL+w0By6CCE98wggXAMIIEqKADAgECAhAP0bvKeWvX
# +N1MguEKmpYxMA0GCSqGSIb3DQEBCwUAMGwxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xKzApBgNV
# BAMTIkRpZ2lDZXJ0IEhpZ2ggQXNzdXJhbmNlIEVWIFJvb3QgQ0EwHhcNMjIwMTEz
# MDAwMDAwWhcNMzExMTA5MjM1OTU5WjBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMM
# RGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQD
# ExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz7MKnJS7JIT3yithZwuEppz1Yq3aa
# za57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllV
# cq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT
# +CFhmzTrBcZe7FsavOvJz82sNEBfsXpm7nfISKhmV1efVFiODCu3T6cw2Vbuyntd
# 463JT17lNecxy9qTXtyOj4DatpGYQJB5w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+
# EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14Ztk6MUSaM0C/CNdaSaTC5qmgZ92k
# J7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2h4mXaXpI8OCiEhtmmnTK3kse5w5j
# rubU75KSOp493ADkRSWJtppEGSt+wJS00mFt6zPZxd9LBADMfRyVw4/3IbKyEbe7
# f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJU
# KSWJbOUOUlFHdL4mrLZBdd56rF+NP8m800ERElvlEFDrMcXKchYiCd98THU/Y+wh
# X8QgUWtvsauGi0/C1kVfnSD8oR7FwI+isX4KJpn15GkvmB0t9dmpsh3lGwIDAQAB
# o4IBZjCCAWIwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5n
# P+e6mK4cD08wHwYDVR0jBBgwFoAUsT7DaQP4v0cB1JgmGggC72NkK8MwDgYDVR0P
# AQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMH8GCCsGAQUFBwEBBHMwcTAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEkGCCsGAQUFBzAC
# hj1odHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRIaWdoQXNzdXJh
# bmNlRVZSb290Q0EuY3J0MEsGA1UdHwREMEIwQKA+oDyGOmh0dHA6Ly9jcmwzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydEhpZ2hBc3N1cmFuY2VFVlJvb3RDQS5jcmwwHAYD
# VR0gBBUwEzAHBgVngQwBAzAIBgZngQwBBAEwDQYJKoZIhvcNAQELBQADggEBAEHx
# qRH0DxNHecllao3A7pgEpMbjDPKisedfYk/ak1k2zfIe4R7sD+EbP5HU5A/C5pg0
# /xkPZigfT2IxpCrhKhO61z7H0ZL+q93fqpgzRh9Onr3g7QdG64AupP2uU7SkwaT1
# IY1rzAGt9Rnu15ClMlIr28xzDxj4+87eg3Gn77tRWwR2L62t0+od/P1Tk+WMieNg
# GbngLyOOLFxJy34riDkruQZhiPOuAnZ2dMFkkbiJUZflhX0901emWG4f7vtpYeJa
# 3Cgh6GO6Ps9W7Zrk9wXqyvPsEt84zdp7PiuTUy9cUQBY3pBIowrHC/Q7bVUx8ALM
# R3eWUaNetbxcyEMRoacwggawMIIEmKADAgECAhAIrUCyYNKcTJ9ezam9k67ZMA0G
# CSqGSIb3DQEBDAUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0
# IFRydXN0ZWQgUm9vdCBHNDAeFw0yMTA0MjkwMDAwMDBaFw0zNjA0MjgyMzU5NTla
# MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UE
# AxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcgUlNBNDA5NiBTSEEz
# ODQgMjAyMSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDVtC9C
# 0CiteLdd1TlZG7GIQvUzjOs9gZdwxbvEhSYwn6SOaNhc9es0JAfhS0/TeEP0F9ce
# 2vnS1WcaUk8OoVf8iJnBkcyBAz5NcCRks43iCH00fUyAVxJrQ5qZ8sU7H/Lvy0da
# E6ZMswEgJfMQ04uy+wjwiuCdCcBlp/qYgEk1hz1RGeiQIXhFLqGfLOEYwhrMxe6T
# SXBCMo/7xuoc82VokaJNTIIRSFJo3hC9FFdd6BgTZcV/sk+FLEikVoQ11vkunKoA
# FdE3/hoGlMJ8yOobMubKwvSnowMOdKWvObarYBLj6Na59zHh3K3kGKDYwSNHR7Oh
# D26jq22YBoMbt2pnLdK9RBqSEIGPsDsJ18ebMlrC/2pgVItJwZPt4bRc4G/rJvmM
# 1bL5OBDm6s6R9b7T+2+TYTRcvJNFKIM2KmYoX7BzzosmJQayg9Rc9hUZTO1i4F4z
# 8ujo7AqnsAMrkbI2eb73rQgedaZlzLvjSFDzd5Ea/ttQokbIYViY9XwCFjyDKK05
# huzUtw1T0PhH5nUwjewwk3YUpltLXXRhTT8SkXbev1jLchApQfDVxW0mdmgRQRNY
# mtwmKwH0iU1Z23jPgUo+QEdfyYFQc4UQIyFZYIpkVMHMIRroOBl8ZhzNeDhFMJlP
# /2NPTLuqDQhTQXxYPUez+rbsjDIJAsxsPAxWEQIDAQABo4IBWTCCAVUwEgYDVR0T
# AQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUaDfg67Y7+F8Rhvv+YXsIiGX0TkIwHwYD
# VR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNV
# HR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkUm9vdEc0LmNybDAcBgNVHSAEFTATMAcGBWeBDAEDMAgGBmeBDAEEATAN
# BgkqhkiG9w0BAQwFAAOCAgEAOiNEPY0Idu6PvDqZ01bgAhql+Eg08yy25nRm95Ry
# sQDKr2wwJxMSnpBEn0v9nqN8JtU3vDpdSG2V1T9J9Ce7FoFFUP2cvbaF4HZ+N3HL
# IvdaqpDP9ZNq4+sg0dVQeYiaiorBtr2hSBh+3NiAGhEZGM1hmYFW9snjdufE5Btf
# Q/g+lP92OT2e1JnPSt0o618moZVYSNUa/tcnP/2Q0XaG3RywYFzzDaju4ImhvTnh
# OE7abrs2nfvlIVNaw8rpavGiPttDuDPITzgUkpn13c5UbdldAhQfQDN8A+KVssIh
# dXNSy0bYxDQcoqVLjc1vdjcshT8azibpGL6QB7BDf5WIIIJw8MzK7/0pNVwfiThV
# 9zeKiwmhywvpMRr/LhlcOXHhvpynCgbWJme3kuZOX956rEnPLqR0kq3bPKSchh/j
# wVYbKyP/j7XqiHtwa+aguv06P0WmxOgWkVKLQcBIhEuWTatEQOON8BUozu3xGFYH
# Ki8QxAwIZDwzj64ojDzLj4gLDb879M4ee47vtevLt/B3E+bnKD+sEq6lLyJsQfmC
# XBVmzGwOysWGw/YmMwwHS6DTBwJqakAwSEs0qFEgu60bhQjiWQ1tygVQK+pKHJ6l
# /aCnHwZ05/LWUpD9r4VIIflXO7ScA+2GRfS0YW6/aOImYIbqyK+p/pQd52MbOoZW
# eE4wggdjMIIFS6ADAgECAhAFkMTPDbAUGZlTpoz86bDnMA0GCSqGSIb3DQEBCwUA
# MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UE
# AxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcgUlNBNDA5NiBTSEEz
# ODQgMjAyMSBDQTEwHhcNMjYwNDEzMDAwMDAwWhcNMjcwNDEyMjM1OTU5WjCB6zET
# MBEGCysGAQQBgjc8AgEDEwJVUzEZMBcGCysGAQQBgjc8AgECEwhEZWxhd2FyZTEd
# MBsGA1UEDwwUUHJpdmF0ZSBPcmdhbml6YXRpb24xEDAOBgNVBAUTBzQxNTI5NTQx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdTZWF0
# dGxlMSIwIAYDVQQKExlBbWF6b24gV2ViIFNlcnZpY2VzLCBJbmMuMQwwCgYDVQQL
# EwNBV1MxIjAgBgNVBAMTGUFtYXpvbiBXZWIgU2VydmljZXMsIEluYy4wggGiMA0G
# CSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCdnV6w7tV727PaCeTlAamSDuzpMtRI
# BOhJ12XroPRlI0DEX54YlUOG98dBqsMrLyKn/Ftc/z00ZjOB1syVpnaCDdr3whoB
# 2lQMIVblLSqoSJjCkVmJX8aNqLuwJZZ8kPIMoXrPifCQR7jMJfp2JCaFHCXVCU3r
# JULv7XkMBOev/W0fGxNzAOJJ0irO53zTexSADYUDWYuJ48MANwbHe8e8nvo50M0L
# /YWPWHy1s5rpUtnBKPmuC1U5Uc/ooZQa16SAkM3IR6zqGTF+7JC+1NMipPrIvmPe
# +uB39PzRf+orNiSvy7GC3eAnHH7hKsErQOYcdCu6eQjeul86Qyzb7/lLLLyxCli1
# qivpjvPTt9/rkUVMVaTPRDZzZJonNebs7VBFckHJO6SehjP/WYG2Fw0582XeBgBx
# +k9qWvkhLcKWy5rxSZV4P1b+3TBpdzOoJDlWJwnVIjXGlgZtpnbcYLPOaHy4Z5j2
# lMoWsbEXromK9xQLlhLMYNpB0OZEo9PYVdUCAwEAAaOCAgIwggH+MB8GA1UdIwQY
# MBaAFGg34Ou2O/hfEYb7/mF7CIhl9E5CMB0GA1UdDgQWBBTjYxPRDvWBv/mKUWry
# YB/WRh7UtTA9BgNVHSAENjA0MDIGBWeBDAEDMCkwJwYIKwYBBQUHAgEWG2h0dHA6
# Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAww
# CgYIKwYBBQUHAwMwgbUGA1UdHwSBrTCBqjBToFGgT4ZNaHR0cDovL2NybDMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hB
# Mzg0MjAyMUNBMS5jcmwwU6BRoE+GTWh0dHA6Ly9jcmw0LmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFRydXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEu
# Y3JsMIGUBggrBgEFBQcBAQSBhzCBhDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3Au
# ZGlnaWNlcnQuY29tMFwGCCsGAQUFBzAChlBodHRwOi8vY2FjZXJ0cy5kaWdpY2Vy
# dC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQy
# MDIxQ0ExLmNydDAJBgNVHRMEAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQCrPzJbznZM
# nFDrHJU/sZ3iXchw0zJZ5PXJSf8+w8/LH2aCp87tJCqRKUe2VWvsUD2cD3QP3aT+
# wdMDxlkyeKquSD3XN8InQcvbR57+bmJDuD2Rpa9NNdRUeafVkHuiQDOUpEzWdH22
# h7SjaCwokTe+0de5opUDFak1XqvT5sMgItkf6vZ0oObTUTlPYhfsfjJllF1x+AAR
# hQRHx/1dfl/xh6rmGVUhHPb7qcq4D7BxRmpTGG1yeopdMukxi9zQf/XdfT03RSKt
# VAGZEeXEoyFMz10L+Pwz5IG4RZDOjXCZ4WEH4INZ5k5ttNGrg2NBd2VGxPfiKz3N
# v0H2uC1NJLXFD6mTp/x6yo4pwyEolbMWUVnQS27laaGtBgrjNRjGv6sotLJzyXzJ
# dwYEGZ0eEfhaveIYVHB9K3nnu4qko4JjaKdNkw6JtpU/mS2urxqfUBYcfcmTC72M
# XUeM2W5xUN3W1GX/kh3GDy8lCEci/tr0gRfw/0R4MDD+BsqoRyDuiour/eFR6xpB
# FO23RdAZWGfY7jLKZ4WvKbqslQgamlXPE98mdfMSmgRWaKPNWujCDzTa5K8IJArV
# PmLL9Z3prTyUsdLL/9HSe/Q5/mFWvrO9wcCxK8JP34lIGRKAxdSZff3lxvITQ7WS
# 7dZSFgJwhzLW/YqlPzSiS3+CA9/EQzQi6DGCGiEwghodAgEBMH0waTELMAkGA1UE
# BhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2Vy
# dCBUcnVzdGVkIEc0IENvZGUgU2lnbmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENB
# MQIQBZDEzw2wFBmZU6aM/Omw5zANBglghkgBZQMEAgEFAKB8MBAGCisGAQQBgjcC
# AQwxAjAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsx
# DjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCD7OPy7j5vpd4nKpJmYCOaN
# 1j9BHRPkiv9Pvl9Fcsl+eDANBgkqhkiG9w0BAQEFAASCAYBhg0IDSEYVaL4ZUMOy
# zKbIAoHQOMoOM6tePThEGBTw6gNBCUYxzE1XjUr2XSRwPu4FDR6Yo/E24e7OSeH1
# cPZeKiKpONfFd0X+ZD17YdWQjjRCMZv1ZTDJdQnAWAWMs59ZH0uCcL6dGBhSskCv
# CcDaFt0e8pFStQ98+1EDtpqIcw4JSOzdqs5LcfHZ5DRpa7/J0Z0O/N5MzIUfwBIW
# cIA+pOTf6BHyf7cChH6entJLbNh6mDy7SG54BndT6fAz/VRZ0tV8j5d4wR8VbmX/
# goTNCsxBYfkSSyh4SE3b5BY1Poe7qwNdltLrsWrgOwhLxB++/kLi3tCefwvOuxJP
# BlcUcmpohydN0wdu7twMeI8wtZkm2FYAGkoi+YwBcqibG1wxfOJoDVNtFRRLgvTa
# A4p2d9FqG2XSBOmjsEW5IYrE2Ho77/5a8KtkUVAsCpSPmfiFxrO6+T1QIRbagpde
# lZ7+TWCIbxaZZ4HRzaOyEljhiEwTLGGPwyavqC4oo+2/eR+hghd3MIIXcwYKKwYB
# BAGCNwMDATGCF2MwghdfBgkqhkiG9w0BBwKgghdQMIIXTAIBAzEPMA0GCWCGSAFl
# AwQCAQUAMHgGCyqGSIb3DQEJEAEEoGkEZzBlAgEBBglghkgBhv1sBwEwMTANBglg
# hkgBZQMEAgEFAAQgFnzl4u6vY9W6QG1H4w9M+DcT8cuidgfYWKHLuFUbHTYCEQDn
# RlbQNKiYCQATZ0CPh+T6GA8yMDI2MTAzMDE4MDc0OFqgghM6MIIG7TCCBNWgAwIB
# AgIQCE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRy
# dXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMB4X
# DTI2MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzELMAkGA1UEBhMCVVMxFzAV
# BgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBTSEEyNTYg
# UlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYgMTCCAiIwDQYJKoZIhvcN
# AQEBBQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz/TjGMPh8CQ6RucZCLv5a
# nHzWJjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMxt9l3Dm5oCG5Z69AqEN1k
# gHg2epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkUxDjLJhBI+qiZP3aixAC/
# qEGLjsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZEeoy/0B8Zm+nzKBgSWG52
# lCO1w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEOvZ3fP2VxIgeR28Y90ZSt
# d3F9VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn/FnbuTegcoRcFEZ9FOqM
# 5T6MTdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolvykE1jive4PuESaT8zzVe
# FWDAMDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZCZVl6pNUOCybMc/kxC6E
# AmSJY24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW83vV8d67WowuUs0HdY4H8
# AMLGvdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjdzi0xlp70W+ow63/0++YD
# EX1M0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9icflf55W1zOEKAcJVAIXpc
# MCU9AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBQUyWOKMC7U
# SvtulPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQGfHrK4pBW9i/USezLTjAO
# BgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwgZUGCCsGAQUF
# BwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20w
# XQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2Vy
# dFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNydDBf
# BgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNl
# cnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcmww
# IAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUA
# A4ICAQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQIENoyKqxrFbJblzCVP/pk
# XmwXOdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGhz45F4Wt4WGdNdIbRWt3Y
# TYJmpR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfHhHv1mx9EVh71SJelcEN/
# oORSjXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA02nXD1nYLI7Ijmiv+xLC
# iYC41DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7KVyF5aQyWP4KhVGUUTnmm
# /RlYJoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jhtKVnd3D0rbHXEu27o+Q8p
# 4sEWPMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvKqzpAec9etE14jOQAzLKW
# dE3w/TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs0NzU/+xX7NbEdcofy0W3
# Wdwd1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGRsMNbXmMREUTgu+Oca7Y7
# 3MPWcslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJNt68Yfim6cjEzVSiLSeZ
# fdkr5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yWQPT9gzCCBrQwggScoAMC
# AQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAwYjELMAkGA1UEBhMC
# VVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0
# LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0MB4XDTI1MDUw
# NzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMCVVMxFzAVBgNVBAoT
# DkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRp
# bWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCCAiIwDQYJKoZIhvcN
# AQEBBQADggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysddujRmh0tFEXnU2tjQ2U
# tZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S9SLrC6Kbltqn7SWC
# WgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+42DFUF0mR/vtLa4+
# gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg62IVwxKSpO0XaF9DP
# fNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21Qomb+zzQWKhxKTVV
# gtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8y9IaaGBpPNXKFifi
# nT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQNfVmUB5KlCX3ZA4x
# 5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gaou30yZ46t4Y9F20HH
# fIY4/6vHespYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6gqztiT96Fv/9bH7mQ
# yogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJDpsZGKdlsjg4u70Ew
# gWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D8bpfm4CLKczsG7Zr
# IGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBTv
# b1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC0nFdZEzfLmc/57qY
# rhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwgwdwYIKwYB
# BQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20w
# QQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2Vy
# dFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwz
# LmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3JsMCAGA1UdIAQZ
# MBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOCAgEAF877
# FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6FTGNpoV2V4wzSUGvI
# 9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mCefSG+tXqGpYZ3ess
# BS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57mQfQXwcAEGCvRR2qK
# tntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9ydOal95CHfmTnM4I
# +ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dBwp9nEC8EAqoxW6q1
# 7r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdqfMTCW/NmKLJ9M+Mt
# ucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2puE6FndlENSmE+9J
# GYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAOk5eCkhSxZON3rGlH
# qhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL0Q4ssd8xHZnIn/7G
# ELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBunvAZapsiI5YKdvlar
# Evf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggWNMIIEdaADAgECAhAOmxiO
# +dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAi
# BgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAw
# MDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdp
# Q2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERp
# Z2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsb
# hA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iT
# cMKyunWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGb
# NOsFxl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclP
# XuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCr
# VYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFP
# ObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTv
# kpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWM
# cCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls
# 5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBR
# a2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6
# MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qY
# rhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8E
# BAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDig
# NoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9v
# dENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCg
# v0NcVec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQT
# SnovLbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh
# 65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSw
# uKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAO
# QGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjD
# TZ9ztwGpn1eqXijiuZQxggN8MIIDeAIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBH
# NCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO
# 28MPj/mSGDUwDQYJYIZIAWUDBAIBBQCggdEwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3
# DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjEwMzAxODA3NDhaMCsGCyqGSIb3DQEJ
# EAIMMRwwGjAYMBYEFFHZq9oDSXPYT0JmrKSCSOazacQ5MC8GCSqGSIb3DQEJBDEi
# BCCjs6lmLj4wktIjW8AOeMJyi46P980JNv8HTO4eWyGCeTA3BgsqhkiG9w0BCRAC
# LzEoMCYwJDAiBCAtoJ2n9BMfn+cttsXm6cllZ1WvBD8ep0LMDSEg4UHr/DANBgkq
# hkiG9w0BAQEFAASCAgCmvn3pBwWUSMgAgUxfvgq3tribZX0dXYtq+bLjjB6akGyt
# n2XEz0zHT1dFppa6GNRTygsLd5sOny6g1oi6yC/hqpi1UNOgbQ43dqcBvwG+rBB6
# VQbiPEvK+KZXVOGQ4IXH7HpOWYzIQgtMF3PCHYr16vg+sebC4sI4bZ7VdqjowJfD
# XKymArIuiL77Pm46RvWfF3frkB8NGYABbWQpweTnMkRy0LLUD2jO3ZFt/iR7je1e
# n3sGX4CNx5BqOlZKeTtiAAwodRKbyVZk7nqX7IgjizH4oOW9kU3AHc2gJz+nJxCW
# yLQuGQfcCNFi00hk0fZt+Y+Kw4HBUKPuqPXEqhTMmAtHEHVhbWkC6zMrtaxMNyJT
# Opm/qoB5LGIWBqqUQXtx/O1390p9BK/75uVRzfyktA8g5bX36vuyAsJRhYkreuMI
# gAL4nQr000rN/hH2xoBDpfgmKgQ5sJ6AHZ4icN+e3RxOvc7jYygYh0TAqv5b5wxv
# HJ6Mve8svtuxClAKqTQ2Z4HwK8/6VLPDP31S+s2JXbYHg714NwoTQ3W9G5knumon
# +H/AMpz5AljfeUWGvYPm+Q9WzkR+2x1G3s/iGOfXR4KQizfVk3vB7VrZzD8JFOft
# thZtklChnU50A5cyRshU0F5LRuKMTaa5hdFwyqCTjjVuMwEv+Vx6tFOYNqO9GQ==
# SIG # End signature block
