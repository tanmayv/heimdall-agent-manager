# Hermetic checks of the thin Windows bootstrap (scripts/install.ps1): it only
# resolves a release, downloads + SHA-256 verifies the bundle and runs
# `ham-bridge.exe setup --headless`. Nothing is downloaded: local cases use
# -Bundle/-ChecksumFile, release resolution runs in-process with the web cmdlets
# mocked. The bundle's ham-bridge.exe is a stub that records its argv and exits
# with $env:STUB_EXIT, so flag binding, env precedence and exit codes are checked
# without installing anything (the install itself is ham-bridge's). With
# $env:STUB_INSTALLED the stub also applies setup's S8c rule (an older --version
# exits 5 unless --allow-downgrade).
#
# Runs on Windows (CI: Windows PowerShell 5.1 and PowerShell 7). Also runs under
# pwsh on Linux/macOS for local development: there it uses a copy of install.ps1
# without the Windows platform guard and a shell-script stub.
param([string]$Engine = 'powershell')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repo 'scripts\install.ps1'
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-ps1-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$failures = 0
function Get-BootstrapTemps { @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^heimdall-install-[0-9a-f]{32}$' } | ForEach-Object Name) }
$tempsBefore = Get-BootstrapTemps
# The bootstrap must see no HEIMDALL_* the test did not set.
Get-ChildItem Env: | Where-Object { $_.Name -like 'HEIMDALL_*' } | ForEach-Object { Remove-Item "Env:\$($_.Name)" }
if (-not $onWindows) {
  $copy = Join-Path $tmp 'install.ps1'
  $text = (Get-Content -Raw $script) -replace '(?m)^.*\[PlatformID\]::Win32NT\).*$', '    # (platform guard removed for the non-Windows test run)'
  Set-Content -NoNewline -Path $copy -Value $text
  $script = $copy
}

function Invoke-Bootstrap([string[]]$ArgList, [hashtable]$Env = @{}) {
  $exe = if ($Engine -eq 'pwsh') { 'pwsh' } else { 'powershell.exe' }
  foreach ($k in $Env.Keys) { Set-Item "Env:\$k" $Env[$k] }
  # Windows PowerShell 5.1 with 'Stop' turns the child's redirected stderr into a
  # terminating NativeCommandError; the child's output is only inspected here.
  $ErrorActionPreference = 'Continue'
  try { $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $script @ArgList 2>&1 | Out-String -Width 4096; $code = $LASTEXITCODE }
  finally { foreach ($k in $Env.Keys) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue } }
  return @{ Code = $code; Out = $out }
}
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
  if ($Ok) { Write-Host "PASS: $Name" } else { Write-Host "FAIL: $Name`n$Detail"; $script:failures++ }
}
function New-Bundle([string]$Dir, [string]$ZipName, [switch]$WithBridge) {
  $src = Join-Path $tmp ('src-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path (Join-Path $src 'bin') | Out-Null
  if ($WithBridge) { Copy-Item $script:stub (Join-Path $src 'bin\ham-bridge.exe') }
  else { Set-Content -Encoding ascii -Path (Join-Path $src 'bin\README.txt') -Value 'no ham-bridge.exe here' }
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $zip = Join-Path $Dir $ZipName
  [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
  $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
  $sums = Join-Path $Dir 'SHA256SUMS'
  Set-Content -Encoding ascii -Path $sums -Value "$hash  $ZipName"
  return @{ Zip = $zip; Sums = $sums }
}
function Get-StubCalls { if (Test-Path $env:STUB_LOG) { @(Get-Content $env:STUB_LOG) } else { @() } }

try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  # The stub ham-bridge.exe: appends its argv to $env:STUB_LOG, exits $env:STUB_EXIT;
  # with $env:STUB_INSTALLED, an older --version without --allow-downgrade exits 5.
  $script:stub = Join-Path $tmp 'stub-ham-bridge.exe'
  $env:STUB_LOG = Join-Path $tmp 'ham-bridge.log'
  if ($onWindows) {
    $cs = Join-Path $tmp 'stub.cs'
    Set-Content -Encoding ascii -Path $cs -Value @'
using System; using System.IO;
class Stub { static int Main(string[] a) {
  File.AppendAllText(Environment.GetEnvironmentVariable("STUB_LOG"), string.Join(" ", a) + "\n");
  string inst = Environment.GetEnvironmentVariable("STUB_INSTALLED");
  if (!string.IsNullOrEmpty(inst)) {
    string req = null; bool allow = false;
    for (int i = 0; i < a.Length; i++) {
      if (a[i] == "--version" && i + 1 < a.Length) req = a[i + 1].TrimStart('v');
      if (a[i] == "--allow-downgrade") allow = true;
    }
    inst = inst.TrimStart('v');
    if (req != null && !allow && new Version(req) < new Version(inst)) {
      Console.Error.WriteLine("ham-bridge setup: runs v" + inst + ", newer than requested v" + req + "; pass --allow-downgrade to downgrade");
      return 5;
    }
  }
  string c = Environment.GetEnvironmentVariable("STUB_EXIT");
  return string.IsNullOrEmpty(c) ? 0 : int.Parse(c); } }
'@
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $csc /nologo /target:exe "/out:$script:stub" $cs | Out-Host
    if ($LASTEXITCODE) { throw 'cannot compile the stub ham-bridge.exe' }
  } else {
    Set-Content -NoNewline -Path $script:stub -Value @'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG"
if [ -n "${STUB_INSTALLED:-}" ]; then
  req='' allow=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version) req="${2#v}"; shift ;;
      --allow-downgrade) allow=1 ;;
    esac
    shift
  done
  inst="${STUB_INSTALLED#v}"
  if [ -n "$req" ] && [ -z "$allow" ] && [ "$req" != "$inst" ] &&
     [ "$(printf '%s\n%s\n' "$req" "$inst" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$req" ]; then
    echo "ham-bridge setup: runs v$inst, newer than requested v$req; pass --allow-downgrade to downgrade" >&2
    exit 5
  fi
fi
exit "${STUB_EXIT:-0}"
'@
    chmod 755 $script:stub
  }

  $plain = New-Bundle (Join-Path $tmp 'plain') 'heimdall-local-windows-amd64-v1.0.0.zip'
  $zip, $sums = $plain.Zip, $plain.Sums
  $bad = Join-Path $tmp 'BAD'
  Set-Content -Encoding ascii -Path $bad -Value ("0" * 64 + "  heimdall-local-windows-amd64-v1.0.0.zip")
  $good = New-Bundle (Join-Path $tmp 'good') 'heimdall-local-windows-amd64-v1.0.0.zip' -WithBridge

  $r = Invoke-Bootstrap @('-Bundle', $zip, '-ChecksumFile', $bad, '-Hub', 'https://h.example')
  Check 'tampered bundle is refused with exit 3' ($r.Code -eq 3 -and $r.Out -match 'SHA-256 verification failed; nothing installed\.') $r.Out

  $r = Invoke-Bootstrap @('-Bundle', $zip, '-ChecksumFile', $sums, '-Hub', 'https://h.example')
  Check 'verified bundle without ham-bridge.exe is refused with exit 3' ($r.Code -eq 3 -and $r.Out -match 'SHA-256 verified' -and $r.Out -match 'no bin\\ham-bridge.exe') $r.Out

  $other = Join-Path $tmp 'heimdall-local-linux-amd64-v1.0.0.zip'
  Copy-Item $zip $other
  $r = Invoke-Bootstrap @('-Bundle', $other, '-ChecksumFile', $sums, '-Hub', 'https://h.example')
  Check 'bundle for another target is refused with exit 3' ($r.Code -eq 3 -and $r.Out -match 'not for this machine \(windows-amd64\)') $r.Out

  # Usage errors: exit 2, before anything is fetched or run.
  $usage = @(
    @(@('-Version', '..\x', '-Hub', 'https://h.example'), 'Invalid release tag'),
    @(@('-Bundle', $good.Zip, '-ChecksumFile', $good.Sums), 'No hub given: pass -Hub URL or set HEIMDALL_HUB'),
    # A bare --hub is bound by PowerShell itself (as -Hub); --hub-url reaches $Rest.
    @(@('--hub-url'), '--hub-url requires a value\.'),
    @(@('-Hub', 'https://h.example', '-Name', 'Bad_Name'), 'Invalid profile "Bad_Name"'),
    @(@('-Hub', 'https://h.example', '-Bundle', (Join-Path $tmp 'missing.zip'), '-ChecksumFile', $good.Sums), 'must both name regular files')
  )
  foreach ($u in $usage) {
    $r = Invoke-Bootstrap $u[0]
    Check "usage error exits 2: $($u[1])" ($r.Code -eq 2 -and $r.Out -match $u[1]) $r.Out
  }
  Check 'usage errors never run ham-bridge' (@(Get-StubCalls).Count -eq 0) ((Get-StubCalls) -join "`n")

  # --flag forms bind to the script's options (no positional binding), win over
  # the environment, and reach ham-bridge exactly once.
  $envVars = @{ HEIMDALL_HUB = 'https://env.example'; HEIMDALL_BRIDGE_NAME = 'envprof' }
  $r = Invoke-Bootstrap @('--bundle', $good.Zip, '--checksum-file', $good.Sums, '--hub', 'https://flag.example', '--name', 'flagprof', '--reenroll') $envVars
  Check '--flag forms win over env and pass once' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://flag.example --profile flagprof --reenroll') ($r.Out + ((Get-StubCalls) -join "`n"))

  $r = Invoke-Bootstrap @('-Bundle', $good.Zip, '-ChecksumFile', $good.Sums, '-HubUrl', 'https://param.example', '-Profile', 'pprof', '-AllowDowngrade', '-SeparateAccount', '-JsonProgress') $envVars
  Check 'parameters win over env; new switches map to ham-bridge flags' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://param.example --profile pprof --allow-downgrade --separate-account --json-progress') ($r.Out + ((Get-StubCalls) -join "`n"))

  $r = Invoke-Bootstrap @('-Bundle', $good.Zip, '-ChecksumFile', $good.Sums) $envVars
  Check 'environment configures an argument-less run' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://env.example --profile envprof') ($r.Out + ((Get-StubCalls) -join "`n"))

  # An explicit bundle means "install this bundle" (S8b, e.g. the desktop
  # installer): no --keep-version, with or without a release or HEIMDALL_VERSION=latest.
  # A concrete TAG is still forwarded (setup checks it names the bundle); latest is not.
  foreach ($v in @(@('v1.0.0', ' --version v1.0.0'), @('latest', ''))) {
    $r = Invoke-Bootstrap @('-Bundle', $good.Zip, '-ChecksumFile', $good.Sums) ($envVars + @{ HEIMDALL_VERSION = $v[0] })
    Check "-Bundle with HEIMDALL_VERSION=$($v[0]) omits --keep-version" ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq ('setup --headless --hub https://env.example --profile envprof' + $v[1])) ($r.Out + ((Get-StubCalls) -join "`n"))
  }

  # S8c: an explicit TAG older than the installed bridge is refused by setup
  # (exit 5, returned unchanged) unless -AllowDowngrade / --allow-downgrade.
  $installed = @{ STUB_INSTALLED = 'v1.2.0' }
  $b = @('-Bundle', $good.Zip, '-ChecksumFile', $good.Sums, '-Hub', 'https://h.example')
  $r = Invoke-Bootstrap ($b + @('-Version', 'v1.0.0')) $installed
  Check 'older -Version TAG is refused with exit 5' ($r.Code -eq 5 -and $r.Out.Contains('runs v1.2.0, newer than requested v1.0.0; pass --allow-downgrade to downgrade') -and
    @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://h.example --version v1.0.0') ($r.Out + ((Get-StubCalls) -join "`n"))
  $r = Invoke-Bootstrap $b ($installed + @{ HEIMDALL_VERSION = 'v1.0.0' })
  Check 'older HEIMDALL_VERSION TAG is refused with exit 5' ($r.Code -eq 5 -and $r.Out.Contains('newer than requested v1.0.0')) ($r.Out + ((Get-StubCalls) -join "`n"))
  $r = Invoke-Bootstrap ($b + @('-Version', 'v1.0.0', '-AllowDowngrade')) $installed
  Check 'older TAG with -AllowDowngrade installs' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://h.example --version v1.0.0 --allow-downgrade') ($r.Out + ((Get-StubCalls) -join "`n"))
  $r = Invoke-Bootstrap ($b + @('--version', 'v1.0.0', '--allow-downgrade')) $installed
  Check 'older TAG with --allow-downgrade installs' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://h.example --version v1.0.0 --allow-downgrade') ($r.Out + ((Get-StubCalls) -join "`n"))
  $r = Invoke-Bootstrap $b $installed
  Check '-Bundle alone forwards no --version (S8b)' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://h.example') ($r.Out + ((Get-StubCalls) -join "`n"))
  $r = Invoke-Bootstrap ($b + @('-Version', 'v1.0.0')) @{ STUB_INSTALLED = 'v0.9.0' }
  Check 'newer -Version TAG installs' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://h.example --version v1.0.0') ($r.Out + ((Get-StubCalls) -join "`n"))
  $r = Invoke-Bootstrap @('-Bundle', $good.Zip, '-ChecksumFile', $good.Sums, '-Version', 'v1.0.0', '-Uninstall', '--yes')
  Check 'uninstall gets no --version' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'uninstall --yes') ($r.Out + ((Get-StubCalls) -join "`n"))

  $r = Invoke-Bootstrap @('-Bundle', $good.Zip, '-ChecksumFile', $good.Sums, '-Uninstall', '--service', 'heimdall-bridge-h', '--yes')
  Check 'uninstall needs no hub' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'uninstall --service heimdall-bridge-h --yes') ($r.Out + ((Get-StubCalls) -join "`n"))

  foreach ($code in 1, 4, 5, 6, 7) {
    $r = Invoke-Bootstrap @('-Bundle', $good.Zip, '-ChecksumFile', $good.Sums, '-Hub', 'https://h.example') @{ STUB_EXIT = "$code" }
    Check "ham-bridge exit code $code is returned unchanged" ($r.Code -eq $code) $r.Out
  }

  # Stable resolution: GET /releases/latest only (F9), per-target check, no
  # fallback. In-process (scriptblock form) so the web cmdlets can be mocked.
  # install.ps1 has its own $sums/$archive; PowerShell scoping is dynamic, so the
  # mocks read the fixtures through distinct script-scoped names.
  $script:fetched = @()
  $script:fixtureSums, $script:fixtureZip = $good.Sums, $good.Zip
  $script:latest = $null
  function Invoke-RestMethod { param($Headers, $Uri)
    $script:fetched += $Uri
    if ($Uri -like '*/releases/latest') {
      if ($null -eq $script:latest) { throw 'Response status code does not indicate success: 404 (Not Found).' }
      return $script:latest
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
  # -Width: Out-String would otherwise wrap long [ERROR] lines at the host width.
  # Parameters go in a hashtable: splatting an array would pass '-Version' as a
  # positional string.
  function Invoke-InProcess([hashtable]$Params = @{}, [hashtable]$Env = @{}) {
    $script:fetched = @()
    foreach ($k in $Env.Keys) { Set-Item "Env:\$k" $Env[$k] }
    try { $o = & ([scriptblock]::Create((Get-Content -Raw $script))) -Hub 'https://h.example' @Params 6>&1 2>&1 | Out-String -Width 4096 }
    finally { foreach ($k in $Env.Keys) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue } }
    return @{ Code = $global:LASTEXITCODE; Out = $o }
  }
  function New-Release([string[]]$Assets) {
    [pscustomobject]@{ tag_name = 'v1.0.0'; draft = $false; prerelease = $false; assets = @($Assets | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
  }

  $script:latest = New-Release @('SHA256SUMS', 'heimdall-local-windows-amd64-v1.0.0.zip')
  $r = Invoke-InProcess
  Check 'latest resolves from /releases/latest beyond 100 releases' ($r.Out -match 'Release v1\.0\.0 \(windows-amd64\)' -and $r.Out -match 'SHA-256 verified' -and
    -not ($script:fetched | Where-Object { $_.Contains('/releases?') })) ($r.Out + ($script:fetched -join "`n"))
  Check 'a resolved release passes --keep-version' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://h.example --keep-version') ($r.Out + ((Get-StubCalls) -join "`n"))

  # Spec section 7: --keep-version only when the script resolves the release
  # itself; 'latest' counts as no release.
  $r = Invoke-InProcess @{ Version = 'latest' }
  Check '-Version latest passes --keep-version' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://h.example --keep-version') ($r.Out + ((Get-StubCalls) -join "`n"))
  $r = Invoke-InProcess @{} @{ HEIMDALL_VERSION = 'latest' }
  Check 'HEIMDALL_VERSION=latest passes --keep-version' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://h.example --keep-version') ($r.Out + ((Get-StubCalls) -join "`n"))
  # An explicit TAG (not 'latest', not the resolved release) is forwarded as --version.
  $r = Invoke-InProcess @{ Version = 'v1.0.0' }
  Check '-Version TAG omits --keep-version and forwards --version' ($r.Code -eq 0 -and $r.Out -match 'Release v1\.0\.0 \(windows-amd64\)' -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://h.example --version v1.0.0') ($r.Out + ((Get-StubCalls) -join "`n"))
  $r = Invoke-InProcess @{} @{ HEIMDALL_VERSION = 'v1.0.0' }
  Check 'HEIMDALL_VERSION=TAG omits --keep-version and forwards --version' ($r.Code -eq 0 -and @(Get-StubCalls)[-1] -ceq 'setup --headless --hub https://h.example --version v1.0.0') ($r.Out + ((Get-StubCalls) -join "`n"))

  $script:latest = New-Release @('heimdall-local-windows-amd64-v1.0.0.zip')
  $r = Invoke-InProcess
  Check 'stable release without SHA256SUMS: exit 3, no fallback' ($r.Code -eq 3 -and $r.Out -match 'Stable release v1\.0\.0 has no SHA256SUMS for windows-amd64; pass -Version TAG\.' -and
    -not ($script:fetched | Where-Object { $_ -like '*/releases/download/*' })) ($r.Out + ($script:fetched -join "`n"))

  $script:latest = New-Release @('SHA256SUMS')
  $r = Invoke-InProcess
  Check 'stable release without the bundle: exit 3, no fallback' ($r.Code -eq 3 -and $r.Out -match 'Stable release v1\.0\.0 has no bundle for windows-amd64; pass -Version TAG\.') $r.Out

  $script:latest = $null
  $r = Invoke-InProcess
  Check 'no stable release: exit 3' ($r.Code -eq 3 -and $r.Out -match 'Cannot resolve the stable release from GitHub \(.*404.*\); pass -Version TAG\.') $r.Out

  $script:latest = [pscustomobject]@{ message = 'API rate limit exceeded' }
  $r = Invoke-InProcess
  Check 'response without tag_name: exit 3' ($r.Code -eq 3 -and $r.Out -match 'no tag_name in the response') $r.Out
  Remove-Item Function:\Invoke-RestMethod, Function:\Invoke-WebRequest

  $r = Invoke-Bootstrap @('-Help')
  Check '-Help documents the headless one-liner' ($r.Code -eq 0 -and $r.Out -match 'Usage: install.ps1' -and $r.Out.Contains('irm https://install.ninjy.ai/ps1 | iex')) $r.Out

  $leaked = @(Get-BootstrapTemps | Where-Object { $tempsBefore -notcontains $_ })
  Check 'temporary directories are removed' ($leaked.Count -eq 0) ($leaked -join ', ')
} finally {
  Remove-Item Env:\STUB_LOG -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'install.ps1 bootstrap checks passed'
