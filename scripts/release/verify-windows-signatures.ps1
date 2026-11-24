# T8 / REQ-SIGN-1: verify Authenticode signatures on the standalone Windows binaries.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release/verify-windows-signatures.ps1 `
#     -Path <heimdall-local-windows-amd64.zip | bin dir> [-Required -Publisher <name>]
#
# Signing is OFF until an operator configures it (docs/desktop_auto_updates.md).
#  - Without -Required (switch off): unsigned binaries pass with a SKIP line, so
#    today's release keeps working. A binary that IS signed must still be Valid;
#    a broken or untrusted signature is never shipped silently.
#  - With -Required (switch on): every bin/*.exe must be Valid, carry an RFC 3161
#    timestamp and be signed by -Publisher. Matching follows the desktop
#    installer check: the full Subject when -Publisher contains CN=, else the
#    certificate's simple name.
# ham-bridge.exe, ham-ctl.exe and ham-pty-host.exe are required.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [switch]$Required,
  [string]$Publisher = ''
)
$ErrorActionPreference = 'Stop'

if ($Required -and -not $Publisher) { throw 'FAIL: -Required needs -Publisher (the expected Authenticode publisher)' }

$cleanup = $null
try {
  if (Test-Path -PathType Container $Path) {
    $bin = $Path
  } elseif (Test-Path -PathType Leaf $Path) {
    $cleanup = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-sigverify-' + [Guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $Path -DestinationPath $cleanup
    $bin = Join-Path $cleanup 'bin'
    if (-not (Test-Path -PathType Container $bin)) { throw "FAIL: $Path has no bin/ directory" }
  } else {
    throw "FAIL: $Path does not exist"
  }

  foreach ($exe in @('ham-bridge.exe', 'ham-ctl.exe', 'ham-pty-host.exe')) {
    if (-not (Test-Path -PathType Leaf (Join-Path $bin $exe))) { throw "FAIL: $exe is missing from $bin" }
  }

  $unsigned = 0
  $signed = 0
  foreach ($f in Get-ChildItem -LiteralPath $bin -Filter '*.exe' -File) {
    $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
    if ($sig.Status -eq 'NotSigned') {
      if ($Required) { throw "FAIL: $($f.Name) is not Authenticode-signed" }
      Write-Host "unsigned: $($f.Name)"
      $unsigned++
      continue
    }
    if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate) {
      throw "FAIL: $($f.Name) signature status is $($sig.Status): $($sig.StatusMessage)"
    }
    if ($Required) {
      if (-not $sig.TimeStamperCertificate) { throw "FAIL: $($f.Name) has no timestamp (signature dies with the certificate)" }
      $cert = $sig.SignerCertificate
      $actual = $cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
      if ($Publisher -match '(^|,)\s*CN=') { $actual = $cert.Subject }
      if ($actual -ne $Publisher) { throw "FAIL: $($f.Name) publisher '$actual' does not match '$Publisher'" }
    }
    $ts = if ($sig.TimeStamperCertificate) { 'timestamped' } else { 'no timestamp' }
    Write-Host "ok: $($f.Name) signer='$($sig.SignerCertificate.Subject)' $ts"
    $signed++
  }

  if ($Required) {
    Write-Host "verified $signed Authenticode signatures (publisher $Publisher)"
  } elseif ($signed -eq 0) {
    Write-Host "SKIP: Windows binary signing is off; $unsigned binaries are unsigned (expected)"
  } else {
    Write-Host "signing switch off: $signed valid signatures, $unsigned unsigned"
  }
} finally {
  if ($cleanup) { Remove-Item -Recurse -Force -LiteralPath $cleanup -ErrorAction SilentlyContinue }
}
