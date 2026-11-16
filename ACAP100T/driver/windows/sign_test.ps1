<#
.SYNOPSIS
    Create a self-signed test certificate, sign the ACAP driver package and
    optionally install it.

.DESCRIPTION
    This is the lab/test-signing path.  Windows will show "Test Mode" on the
    desktop, but the device installs without a yellow triangle as long as the
    certificate is trusted and test signing is enabled.

    Production distribution requires an EV code-signing certificate and a
    Microsoft Partner Center attestation signature; that cannot be produced
    offline.

    Run from an elevated PowerShell.  A reboot is required after enabling test
    signing.  Secure Boot must be disabled for test signing to work.

.EXAMPLE
    .\sign_test.ps1
    .\sign_test.ps1 -Install
#>
param(
    [switch]$Install
)

$ErrorActionPreference = "Stop"
$subject = "CN=ACAP Test Driver"
$outDir  = Join-Path $PSScriptRoot "build\Release"
$sys     = Join-Path $outDir "acap.sys"
$inf     = Join-Path $outDir "acap.inf"
$cat     = Join-Path $outDir "acap.cat"
$cer     = Join-Path $PSScriptRoot "acap_test.cer"

function Require-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must run from an elevated PowerShell."
    }
}

Require-Admin

if (-not (Test-Path $sys)) {
    throw "Missing $sys - run build_driver.cmd first."
}
if (-not (Test-Path $inf)) {
    throw "Missing $inf - run build_driver.cmd first."
}

Write-Host "Creating self-signed code-signing certificate..."
$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $subject `
    -CertStoreLocation "Cert:\LocalMachine\My" `
    -KeyUsage DigitalSignature `
    -KeyExportPolicy Exportable `
    -FriendlyName "ACAP Test Driver" `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")

Export-Certificate -Cert $cert -FilePath $cer -Force | Out-Null
Write-Host "Exported public certificate to $cer"

Write-Host "Trusting the test certificate (LocalMachine Root + TrustedPublisher)..."
Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\TrustedPublisher" | Out-Null

Write-Host "Signing acap.sys..."
& signtool.exe sign /v /sm /s My /n "ACAP Test Driver" /fd SHA256 /a $sys
if ($LASTEXITCODE -ne 0) { throw "signtool failed for acap.sys" }

# The .cat hashes the .sys, so regenerate it after signing the binary.
Write-Host "Regenerating the catalogue..."
& Inf2Cat.exe /driver:$outDir /os:10_X64
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat failed" }

Write-Host "Signing acap.cat..."
& signtool.exe sign /v /sm /s My /n "ACAP Test Driver" /fd SHA256 /a $cat
if ($LASTEXITCODE -ne 0) { throw "signtool failed for acap.cat" }

Write-Host "Verifying signatures..."
& signtool.exe verify /v /kp $sys
& signtool.exe verify /v /kp $cat

Write-Host "Enabling test signing..."
bcdedit /set testsigning on | Out-Null

if ($Install) {
    Write-Host "Installing the driver package..."
    & pnputil.exe /add-driver $inf /install
    if ($LASTEXITCODE -ne 0) { throw "pnputil failed" }
    Write-Host "Driver installed.  Reboot if test signing was just enabled."
} else {
    Write-Host ""
    Write-Host "Certificate and signatures are ready."
    Write-Host "Reboot, then install with:"
    Write-Host "  pnputil /add-driver `"$inf`" /install"
}

Write-Host ""
Write-Host "NOTE: Windows will display the 'Test Mode' watermark.  This is expected."
Write-Host "For production, sign with an EV certificate and Microsoft attestation."
