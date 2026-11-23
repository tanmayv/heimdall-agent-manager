# T8 / REQ-SIGN-1: Authenticode-sign the standalone Windows binaries in place.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/release/sign-windows-binaries.ps1 `
#     -BinDir dist/windows-bin -Publisher "<expected publisher>"
#
# Env: WIN_CSC_LINK          base64-encoded PFX (the same secret electron-builder
#                            uses for the desktop installer, so one identity
#                            signs both; file paths/URLs are not accepted here)
#      WIN_CSC_KEY_PASSWORD  PFX password
#
# Runs only when the release workflow's signing switch is on
# (vars.WINDOWS_UPDATE_PUBLISHER_NAME set). Signs every *.exe with SHA-256 and
# an RFC 3161 timestamp, then re-verifies with verify-windows-signatures.ps1
# -Required. The decoded PFX is deleted even on failure.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BinDir,
  [Parameter(Mandatory = $true)][string]$Publisher,
  [string]$TimestampUrl = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'

$pfxB64 = $env:WIN_CSC_LINK
$pfxPassword = $env:WIN_CSC_KEY_PASSWORD
if (-not $pfxB64 -or -not $pfxPassword) { throw 'FAIL: WIN_CSC_LINK and WIN_CSC_KEY_PASSWORD are required when Windows signing is on' }
if ($pfxB64 -match '^(https?|file)://' -or (Test-Path -LiteralPath $pfxB64 -ErrorAction SilentlyContinue)) {
  throw 'FAIL: WIN_CSC_LINK must be a base64-encoded PFX for binary signing, not a path or URL'
}

function Find-SignTool {
  $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  $found = Get-ChildItem -Path $kits -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $found) { throw 'FAIL: signtool.exe not found (Windows SDK)' }
  return $found.FullName
}

$files = @(Get-ChildItem -LiteralPath $BinDir -Filter '*.exe' -File | ForEach-Object FullName)
if ($files.Count -eq 0) { throw "FAIL: no .exe files in $BinDir" }

$pfx = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-sign-' + [Guid]::NewGuid().ToString('N') + '.pfx')
try {
  [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String(($pfxB64 -replace '\s', '')))
  $signtool = Find-SignTool
  & $signtool sign /fd SHA256 /tr $TimestampUrl /td SHA256 /f $pfx /p $pfxPassword @files
  if ($LASTEXITCODE) { throw "FAIL: signtool sign exited $LASTEXITCODE" }
} finally {
  Remove-Item -Force -LiteralPath $pfx -ErrorAction SilentlyContinue
}

& (Join-Path $PSScriptRoot 'verify-windows-signatures.ps1') -Path $BinDir -Required -Publisher $Publisher
