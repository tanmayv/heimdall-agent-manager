# T8: checks of scripts/release/verify-windows-signatures.ps1 on Windows.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/windows/verify_windows_signatures_test.ps1 `
#     -Bundle dist/heimdall-local-windows-amd64.zip
#
# Uses the real (unsigned) release bundle. Cases that need a trusted signature
# make a throwaway self-signed code-signing certificate, trust it in the
# LocalMachine stores (CI runners are elevated; those cases are skipped
# otherwise) and remove it again.
param([Parameter(Mandatory = $true)][string]$Bundle)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$verifier = Join-Path $repo 'scripts\release\verify-windows-signatures.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-sigtest-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$failures = 0

function Invoke-Verify([string[]]$ArgList) {
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifier @ArgList 2>&1 | Out-String
  return @{ Code = $LASTEXITCODE; Out = $out }
}
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
  if ($Ok) { Write-Host "PASS: $Name" } else { Write-Host "FAIL: $Name`n$Detail"; $script:failures++ }
}
function New-BinCopy([string]$Name) {
  $dir = Join-Path $tmp $Name
  Expand-Archive -LiteralPath $Bundle -DestinationPath $dir
  return (Join-Path $dir 'bin')
}

$certs = @()
try {
  # 1. Switch off, unsigned bundle: the release keeps working.
  $r = Invoke-Verify @('-Path', $Bundle)
  Check 'switch off: unsigned bundle passes with SKIP' ($r.Code -eq 0 -and $r.Out -match 'SKIP: Windows binary signing is off') $r.Out

  # 2. Switch on, unsigned bundle: fails closed.
  $r = Invoke-Verify @('-Path', $Bundle, '-Required', '-Publisher', 'Example Ltd')
  Check 'switch on: unsigned bundle fails' ($r.Code -ne 0 -and $r.Out -match 'is not Authenticode-signed') $r.Out

  # 3. Switch on without a publisher: refused.
  $r = Invoke-Verify @('-Path', $Bundle, '-Required')
  Check 'switch on: publisher is mandatory' ($r.Code -ne 0 -and $r.Out -match 'needs -Publisher') $r.Out

  # 4. Missing binary: refused even with the switch off.
  $bin = New-BinCopy 'missing'
  Remove-Item (Join-Path $bin 'ham-pty-host.exe')
  $r = Invoke-Verify @('-Path', $bin)
  Check 'missing ham-pty-host.exe fails' ($r.Code -ne 0 -and $r.Out -match 'ham-pty-host.exe is missing') $r.Out

  # 5. Untrusted self-signed signature: never shipped, switch off or on.
  $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Heimdall T8 Test Signer' `
    -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(1)
  $certs += $cert
  $bin = New-BinCopy 'untrusted'
  Set-AuthenticodeSignature -FilePath (Join-Path $bin 'ham-ctl.exe') -Certificate $cert -HashAlgorithm SHA256 | Out-Null
  $r = Invoke-Verify @('-Path', $bin)
  Check 'switch off: untrusted signature fails' ($r.Code -ne 0 -and $r.Out -match 'ham-ctl.exe signature status is') $r.Out

  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $admin) {
    Write-Host 'SKIP: trusted-signature cases need an elevated runner'
  } else {
    foreach ($store in @('Root', 'TrustedPublisher')) {
      $s = New-Object System.Security.Cryptography.X509Certificates.X509Store($store, 'LocalMachine')
      $s.Open('ReadWrite'); $s.Add($cert); $s.Close()
    }
    # 6. Trusted but not timestamped: switch on rejects it.
    $bin = New-BinCopy 'notimestamp'
    Get-ChildItem (Join-Path $bin '*.exe') | ForEach-Object {
      Set-AuthenticodeSignature -FilePath $_.FullName -Certificate $cert -HashAlgorithm SHA256 | Out-Null }
    $r = Invoke-Verify @('-Path', $bin, '-Required', '-Publisher', 'Heimdall T8 Test Signer')
    Check 'switch on: missing timestamp fails' ($r.Code -ne 0 -and $r.Out -match 'has no timestamp') $r.Out
    $r = Invoke-Verify @('-Path', $bin)
    Check 'switch off: valid signatures pass' ($r.Code -eq 0 -and $r.Out -match '3 valid signatures') $r.Out

    # 7. Trusted and timestamped: passes for the right publisher only.
    $bin = New-BinCopy 'timestamped'
    $stamped = $true
    Get-ChildItem (Join-Path $bin '*.exe') | ForEach-Object {
      $s = Set-AuthenticodeSignature -FilePath $_.FullName -Certificate $cert -HashAlgorithm SHA256 `
        -TimestampServer 'http://timestamp.digicert.com'
      if (-not $s.TimeStamperCertificate) { $stamped = $false } }
    if (-not $stamped) {
      Write-Host 'SKIP: timestamp server unreachable; timestamped cases not run'
    } else {
      $r = Invoke-Verify @('-Path', $bin, '-Required', '-Publisher', 'Heimdall T8 Test Signer')
      Check 'switch on: valid timestamped signatures pass' ($r.Code -eq 0 -and $r.Out -match 'verified 3 Authenticode') $r.Out
      $r = Invoke-Verify @('-Path', $bin, '-Required', '-Publisher', 'CN=Heimdall T8 Test Signer')
      Check 'switch on: full Subject publisher matches' ($r.Code -eq 0) $r.Out
      $r = Invoke-Verify @('-Path', $bin, '-Required', '-Publisher', 'Someone Else')
      Check 'switch on: wrong publisher fails' ($r.Code -ne 0 -and $r.Out -match 'does not match') $r.Out
    }
  }
} finally {
  foreach ($c in $certs) {
    foreach ($loc in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\Root', 'Cert:\LocalMachine\TrustedPublisher')) {
      Remove-Item -LiteralPath (Join-Path $loc $c.Thumbprint) -ErrorAction SilentlyContinue
    }
  }
  Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures failure(s)"; exit 1 }
Write-Host 'all verify-windows-signatures cases passed'
