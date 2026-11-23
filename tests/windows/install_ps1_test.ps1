# Hermetic checks of the thin Windows bootstrap (scripts/install.ps1): it only
# resolves a release, downloads + SHA-256 verifies the bundle and runs
# `ham-bridge.exe setup --headless`. These cases use -Bundle/-ChecksumFile, so
# nothing is downloaded, and every case fails or stops before ham-bridge would run;
# the install itself is ham-bridge's (tested in the odin packages).
param([string]$Engine = 'powershell')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repo 'scripts\install.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-ps1-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$failures = 0
function Get-BootstrapTemps { @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^heimdall-install-[0-9a-f]{32}$' } | ForEach-Object Name) }
$tempsBefore = Get-BootstrapTemps

function Invoke-Bootstrap([string[]]$ArgList) {
  $exe = if ($Engine -eq 'pwsh') { 'pwsh' } else { 'powershell.exe' }
  $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $script @ArgList 2>&1 | Out-String
  return @{ Code = $LASTEXITCODE; Out = $out }
}
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
  if ($Ok) { Write-Host "PASS: $Name" } else { Write-Host "FAIL: $Name`n$Detail"; $script:failures++ }
}

try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $src = Join-Path $tmp 'src'
  New-Item -ItemType Directory -Path (Join-Path $src 'bin') | Out-Null
  Set-Content -Encoding ascii -Path (Join-Path $src 'bin\README.txt') -Value 'no ham-bridge.exe here'
  $zip = Join-Path $tmp 'heimdall-local-windows-amd64-v1.0.0.zip'
  [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
  $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
  $sums = Join-Path $tmp 'SHA256SUMS'
  Set-Content -Encoding ascii -Path $sums -Value "$hash  heimdall-local-windows-amd64-v1.0.0.zip"
  $bad = Join-Path $tmp 'BAD'
  Set-Content -Encoding ascii -Path $bad -Value ("0" * 64 + "  heimdall-local-windows-amd64-v1.0.0.zip")

  $r = Invoke-Bootstrap @('-Bundle', $zip, '-ChecksumFile', $bad, '-Hub', 'https://h.example')
  Check 'tampered bundle is refused' ($r.Code -ne 0 -and $r.Out -match 'SHA-256 verification failed') $r.Out

  $r = Invoke-Bootstrap @('-Bundle', $zip, '-ChecksumFile', $sums, '-Hub', 'https://h.example')
  Check 'verified bundle without ham-bridge.exe is refused' ($r.Code -ne 0 -and $r.Out -match 'SHA-256 verified' -and $r.Out -match 'no bin\\ham-bridge.exe') $r.Out

  $other = Join-Path $tmp 'heimdall-local-linux-amd64-v1.0.0.zip'
  Copy-Item $zip $other
  $r = Invoke-Bootstrap @('-Bundle', $other, '-ChecksumFile', $sums, '-Hub', 'https://h.example')
  Check 'bundle for another target is refused' ($r.Code -ne 0 -and $r.Out -match 'not a windows-amd64 bundle') $r.Out

  $r = Invoke-Bootstrap @('-Version', '..\x', '-Hub', 'https://h.example')
  Check 'invalid tag is refused' ($r.Code -ne 0 -and $r.Out -match 'Invalid release tag') $r.Out

  # F9: 150 releases with 130 prereleases above the promoted v1.0.0. Only
  # /releases/latest is served; reading a page of the list fails the case. Runs
  # in-process in the scriptblock form so the web cmdlets can be mocked.
  $script:fetched = @()
  # install.ps1 has its own $sums/$archive; PowerShell scoping is dynamic, so the
  # mocks read the fixtures through distinct script-scoped names.
  $script:fixtureSums, $script:fixtureZip = $sums, $zip
  function Invoke-RestMethod { param($Headers, $Uri)
    $script:fetched += $Uri
    if ($Uri -like '*/releases/latest') {
      return [pscustomobject]@{ tag_name = 'v1.0.0'; draft = $false; prerelease = $false
        assets = @([pscustomobject]@{ name = 'SHA256SUMS' }, [pscustomobject]@{ name = 'heimdall-local-windows-amd64-v1.0.0.zip' }) }
    }
    $page = @(); for ($i = 129; $i -ge 30; $i--) { $page += [pscustomobject]@{ tag_name = "v1.1.$i"; draft = $false; prerelease = $true
      assets = @([pscustomobject]@{ name = 'SHA256SUMS' }, [pscustomobject]@{ name = "heimdall-local-windows-amd64-v1.1.$i.zip" }) } }
    return $page
  }
  function Invoke-WebRequest { param([switch]$UseBasicParsing, $Headers, $Uri, $OutFile)
    $script:fetched += $Uri
    if ($Uri -like '*/v1.0.0/SHA256SUMS') { Copy-Item $script:fixtureSums $OutFile; return }
    if ($Uri -like '*/v1.0.0/heimdall-local-windows-amd64-v1.0.0.zip') { Copy-Item $script:fixtureZip $OutFile; return }
    throw "404 $Uri"
  }
  $out = & ([scriptblock]::Create((Get-Content -Raw $script))) -Hub 'https://h.example' 6>&1 2>&1 | Out-String
  Check 'latest resolves from /releases/latest beyond 100 releases' ($out -match 'Release v1\.0\.0 \(windows-amd64\)' -and $out -match 'SHA-256 verified' -and
    -not ($script:fetched | Where-Object { $_.Contains('/releases?') })) ($out + ($script:fetched -join "`n"))
  Remove-Item Function:\Invoke-RestMethod, Function:\Invoke-WebRequest

  $r = Invoke-Bootstrap @('-Help')
  Check '-Help prints usage' ($r.Code -eq 0 -and $r.Out -match 'Usage: install.ps1') $r.Out

  $leaked = @(Get-BootstrapTemps | Where-Object { $tempsBefore -notcontains $_ })
  Check 'temporary directories are removed' ($leaked.Count -eq 0) ($leaked -join ', ')
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'install.ps1 bootstrap checks passed'
