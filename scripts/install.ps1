# Heimdall Bridge bootstrap for Windows (PowerShell 5.1 and 7, no admin rights):
#
#   $env:HEIMDALL_HUB = 'https://hub.example.com'; irm https://install.ninjy.ai/ps1 | iex
#   & ([scriptblock]::Create((irm https://install.ninjy.ai/ps1))) -Hub https://hub.example.com
#
# It only resolves a release, downloads the windows-amd64 bundle, verifies it
# against the release's SHA256SUMS and runs `ham-bridge setup --headless` from it
# with the remaining options passed through. Detecting, installing, enrolling,
# the Scheduled Task, extensions and rollback all live in ham-bridge; updates use
# `ham-bridge update --version`. Behaviour, flags and exit codes:
# docs/specs/bridge-installer-contract.md (install.sh implements the same).
# Self-contained: it makes no assumption about where it was fetched from
# (install.ninjy.ai, a release asset or main), never prompts and needs no console.
# -Interactive drops --headless so ham-bridge opens the enrollment approval page
# in a browser for standalone CLI installs. The desktop installer is app-only;
# desktop Bridge installation and approval run through the in-app setup wizard.
#
# Without arguments (the `| iex` form) these environment variables are read:
#   HEIMDALL_HUB, HEIMDALL_BRIDGE_NAME (profile), HEIMDALL_VERSION.
# A parameter, or its --flag form, wins over the environment variable.
#
# Keep this file pure ASCII (Windows PowerShell 5.1 reads a BOM-less .ps1 as
# ANSI). Never call `exit` outside the bottom of the file: under the scriptblock
# one-liner that would close the operator's PowerShell window.
# PositionalBinding off: a bare `--hub URL` must reach $Rest, not bind to -Hub/-Name.
[CmdletBinding(PositionalBinding = $false)]
param(
  [Alias('HubUrl')][string]$Hub = '',
  [Alias('Profile')][string]$Name = '',
  [string]$Version = '',
  [string]$Bundle = '',
  [string]$ChecksumFile = '',
  [string]$ReuseBridge = '',
  [switch]$NewBridge,
  [switch]$Reenroll,
  [switch]$AllowDowngrade,
  [switch]$SeparateAccount,
  [switch]$ReplaceOtherAccount,
  [switch]$JsonProgress,
  [switch]$Interactive,
  [switch]$Uninstall,
  [switch]$Help,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$HeimdallRepo = 'tanmayv/heimdall-agent-manager'
$HeimdallTarget = 'windows-amd64'
# Which options were given as parameters (an env var is only their default).
$HeimdallBound = @{}
if ($PSBoundParameters) { foreach ($k in $PSBoundParameters.Keys) { $HeimdallBound[$k] = $true } }

# Stop with exit code $Code: 2 = usage error, 3 = bootstrap failure (nothing touched).
function Stop-HeimdallBootstrap([int]$Code, [string]$Message) {
  $e = New-Object System.Exception $Message
  $e.Data['HeimdallExitCode'] = $Code
  throw $e
}

function Invoke-HeimdallBootstrap {
  $ErrorActionPreference = 'Stop'
  try {
    $hubUrl = $Hub; $profileName = $Name; $tag = $Version
    $bundlePath = $Bundle; $sumsPath = $ChecksumFile
    $isUninstall = [bool]$Uninstall; $isInteractive = [bool]$Interactive; $showHelp = [bool]$Help
    $hubSet = $HeimdallBound.ContainsKey('Hub'); $profileSet = $HeimdallBound.ContainsKey('Name'); $versionSet = $HeimdallBound.ContainsKey('Version')
    # The --flag forms the script owns are bound here, so exactly one value per
    # option reaches ham-bridge; everything else passes through unchanged.
    $pass = @()
    $items = @($Rest)
    for ($i = 0; $i -lt $items.Count; $i++) {
      $a = $items[$i]
      switch -CaseSensitive ($a) {
        { $_ -in @('--hub', '--hub-url', '--profile', '--name', '--version', '--bundle', '--checksum-file') } {
          if ($i + 1 -ge $items.Count -or -not $items[$i + 1]) { Stop-HeimdallBootstrap 2 "$a requires a value." }
          $v = $items[$i + 1]; $i++
          switch ($a) {
            { $_ -in @('--hub', '--hub-url') } { $hubUrl = $v; $hubSet = $true }
            { $_ -in @('--profile', '--name') } { $profileName = $v; $profileSet = $true }
            '--version' { $tag = $v; $versionSet = $true }
            '--bundle' { $bundlePath = $v }
            '--checksum-file' { $sumsPath = $v }
          }
          continue
        }
        '--uninstall' { $isUninstall = $true; continue }
        '--interactive' { $isInteractive = $true; continue }
        { $_ -in @('--help', '-h') } { $showHelp = $true; continue }
        default { $pass += $a }
      }
    }
    if ($showHelp) {
      Write-Host @'
Usage: install.ps1 -Hub URL [-Name PROFILE] [-Version TAG|latest]
                   [-Bundle ZIP -ChecksumFile FILE] [-Interactive]
                   [-NewBridge | -ReuseBridge ID] [-Reenroll] [-AllowDowngrade]
                   [-SeparateAccount | -ReplaceOtherAccount] [-JsonProgress]
                   [other ham-bridge setup flags]
       install.ps1 -Uninstall [-Hub URL [-Name PROFILE]] [ham-bridge uninstall flags, e.g. --purge --yes]

Headless one-liner (no admin rights, no browser needed on this machine; approve
the pairing code it prints from any device signed in to your Ninjy account):
  $env:HEIMDALL_HUB = 'https://hub.example.com'; irm https://install.ninjy.ai/ps1 | iex
  & ([scriptblock]::Create((irm https://install.ninjy.ai/ps1))) -Hub https://hub.example.com
Safe to re-run: a healthy enrolled bridge is left untouched.

  -Hub URL        Hub origin (alias -HubUrl, --hub, --hub-url; env HEIMDALL_HUB). Required.
  -Name PROFILE   Profile, [a-z0-9][a-z0-9-]{0,30} (alias -Profile, --profile, --name;
                  env HEIMDALL_BRIDGE_NAME). Default profile when empty.
  -Version TAG    Release to bootstrap from (--version; env HEIMDALL_VERSION). Default
                  latest = GitHub's latest (promoted, stable) release; then an
                  installed bridge keeps its version (--keep-version). With a TAG
                  (passed on as setup --version) an installed bridge is moved to
                  it; an older TAG is refused (exit 5) unless -AllowDowngrade.
  -Bundle ZIP -ChecksumFile FILE
                  Use an already-downloaded bundle (verified first); an
                  installed bridge is moved to the bundle's version.
  -Interactive    Open the approval page in a browser (no --headless).
  -Uninstall      Run ham-bridge uninstall instead.
Parameters win over environment variables. Every --flag form is accepted too.

Exit codes: 0 done, 1 setup failed (previous state restored), 2 usage error,
3 bootstrap failed (nothing touched), 4 installed but not enrolled (re-run),
5 refused (needs the named flag), 6 busy, 7 rollback incomplete.
'@
      return 0
    }
    # An environment variable is only the default for an option that is absent.
    if (-not $hubSet) { $hubUrl = $env:HEIMDALL_HUB }
    if (-not $profileSet) { $profileName = $env:HEIMDALL_BRIDGE_NAME }
    if (-not $versionSet) { $tag = $env:HEIMDALL_VERSION }
    if (-not $isUninstall -and -not $hubUrl) { Stop-HeimdallBootstrap 2 'No hub given: pass -Hub URL or set HEIMDALL_HUB (see -Help).' }
    if ($profileName -and $profileName -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') { Stop-HeimdallBootstrap 2 "Invalid profile `"$profileName`": use [a-z0-9][a-z0-9-]{0,30}." }
    if ($tag -eq 'latest') { $tag = '' }
    if ($tag -and $tag -cnotmatch '^[A-Za-z0-9._-]+$') { Stop-HeimdallBootstrap 2 "Invalid release tag: $tag" }
    $useLocalBundle = [bool]($bundlePath -or $sumsPath)
    # Only when the script resolves the release itself (no -Version /
    # HEIMDALL_VERSION, no -Bundle) must a re-run never change an installed
    # bridge's version (spec section 7, S8a): ham-bridge setup keeps it. An
    # explicit release or bundle means "install this one" (S8b). Releases before
    # --keep-version ignore the flag.
    $keepVersion = -not $tag -and -not $useLocalBundle
    # A concrete TAG the user asked for (not latest, not a release this script
    # resolves below) reaches setup as --version, so an installed newer bridge is
    # not downgraded without -AllowDowngrade (S8c, exit 5). With -Bundle, setup
    # checks the TAG names that bundle (exit 2 otherwise).
    $requestedTag = $tag
    if ($useLocalBundle -and (-not $bundlePath -or -not $sumsPath -or -not (Test-Path -PathType Leaf -LiteralPath $bundlePath) -or -not (Test-Path -PathType Leaf -LiteralPath $sumsPath))) {
      Stop-HeimdallBootstrap 2 '-Bundle and -ChecksumFile must both name regular files.'
    }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') { Stop-HeimdallBootstrap 3 "PowerShell 5.1 or later is required (this is $($PSVersionTable.PSVersion))." }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Stop-HeimdallBootstrap 3 "Unsupported platform $([Environment]::OSVersion.Platform); install.ps1 is for Windows (Linux and macOS: install.sh)." }
  } catch {
    $code = $_.Exception.Data['HeimdallExitCode']
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    if ($code) { return [int]$code } else { return 3 }
  }

  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
  $ProgressPreference = 'SilentlyContinue'
  $work = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-install-' + [Guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Path $work | Out-Null
    $sums = Join-Path $work 'SHA256SUMS'
    if ($useLocalBundle) {
      $archive = Split-Path -Leaf $bundlePath
      # The desktop app stages its bundle unversioned (heimdall-local-windows-amd64.zip).
      if ($archive -notlike "heimdall-local-$HeimdallTarget-*.zip" -and $archive -cne "heimdall-local-$HeimdallTarget.zip") { Stop-HeimdallBootstrap 3 "Bundle $archive is not for this machine ($HeimdallTarget)." }
      Copy-Item -LiteralPath $sumsPath $sums
      Copy-Item -LiteralPath $bundlePath (Join-Path $work $archive)
    } else {
      $headers = @{ 'User-Agent' = 'heimdall-install.ps1'; 'Accept' = 'application/vnd.github+json' }
      if (-not $tag) {
        # Releases start as prereleases (canary candidates); stable is the promoted
        # release GitHub reports as latest. It must carry SHA256SUMS and this
        # target's bundle; never fall back to an older release, never read a list
        # page (report F9). An explicit -Version may be any release.
        try { $r = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$HeimdallRepo/releases/latest" }
        catch { Stop-HeimdallBootstrap 3 "Cannot resolve the stable release from GitHub ($($_.Exception.Message)); pass -Version TAG." }
        if ($null -eq $r -or $r -is [string] -or $r -is [array]) { Stop-HeimdallBootstrap 3 'Cannot resolve the stable release from GitHub (the response is not a release); pass -Version TAG.' }
        $tag = [string]$r.tag_name
        if (-not $tag) { Stop-HeimdallBootstrap 3 'Cannot resolve the stable release from GitHub (no tag_name in the response); pass -Version TAG.' }
        if ($r.draft -or $r.prerelease) { Stop-HeimdallBootstrap 3 "Cannot resolve the stable release from GitHub ($tag is not a promoted release); pass -Version TAG." }
        $assets = @($r.assets | ForEach-Object { [string]$_.name })
        if (-not ($assets -ccontains 'SHA256SUMS')) { Stop-HeimdallBootstrap 3 "Stable release $tag has no SHA256SUMS for $HeimdallTarget; pass -Version TAG." }
        if (-not ($assets -ccontains "heimdall-local-$HeimdallTarget-$tag.zip")) { Stop-HeimdallBootstrap 3 "Stable release $tag has no bundle for $HeimdallTarget; pass -Version TAG." }
        if ($tag -cnotmatch '^[A-Za-z0-9._-]+$') { Stop-HeimdallBootstrap 3 "Invalid release tag: $tag" }
      }
      $archive = "heimdall-local-$HeimdallTarget-$tag.zip"
      $base = "https://github.com/$HeimdallRepo/releases/download/$tag"
      Write-Host "[INFO] Release $tag ($HeimdallTarget)"
      try { Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "$base/SHA256SUMS" -OutFile $sums } catch { Stop-HeimdallBootstrap 3 "Release $tag has no SHA256SUMS (unknown tag?)." }
      Write-Host "[INFO] Downloading $archive"
      try { Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "$base/$archive" -OutFile (Join-Path $work $archive) } catch { Stop-HeimdallBootstrap 3 "Release $tag has no $archive." }
    }
    # Exactly one SHA256SUMS entry for the bundle, and it must match.
    $expected = @(Get-Content -LiteralPath $sums | ForEach-Object { $f = @($_.Trim() -split '\s+'); if ($f.Count -eq 2 -and $f[1].TrimStart('*') -ceq $archive) { $f[0].ToLowerInvariant() } })
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $work $archive)).Hash.ToLowerInvariant()
    if ($expected.Count -ne 1 -or $expected[0] -ne $actual) { Stop-HeimdallBootstrap 3 'SHA-256 verification failed; nothing installed.' }
    Write-Host "[OK] SHA-256 verified: $archive"
    # ExtractToDirectory refuses entries that would land outside the destination.
    $dest = Join-Path $work 'bundle'
    try {
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $work $archive), $dest)
    } catch { Stop-HeimdallBootstrap 3 "Cannot unpack the bundle ($($_.Exception.Message)); nothing installed." }
    $bridge = Join-Path (Join-Path $dest 'bin') 'ham-bridge.exe'
    if (-not (Test-Path -PathType Leaf $bridge)) { Stop-HeimdallBootstrap 3 'The bundle has no bin\ham-bridge.exe.' }

    $argv = @()
    if ($isUninstall) { $argv += 'uninstall' } elseif ($isInteractive) { $argv += 'setup' } else { $argv += @('setup', '--headless') }
    if ($hubUrl) { $argv += @('--hub', $hubUrl) }
    if ($profileName) { $argv += @('--profile', $profileName) }
    if (-not $isUninstall) {
      if ($keepVersion) { $argv += '--keep-version' }
      if ($requestedTag) { $argv += @('--version', $requestedTag) }
      if ($NewBridge) { $argv += '--new-bridge' }
      if ($ReuseBridge) { $argv += @('--reuse-bridge', $ReuseBridge) }
      if ($Reenroll) { $argv += '--reenroll' }
      if ($AllowDowngrade) { $argv += '--allow-downgrade' }
      if ($SeparateAccount) { $argv += '--separate-account' }
      if ($ReplaceOtherAccount) { $argv += '--replace-other-account' }
    }
    if ($JsonProgress) { $argv += '--json-progress' }
    $argv += $pass
    # ham-bridge copies what it needs out of the bundle; the temporary copy is removed below.
    # Out-Host: inside a function a native command's stdout would become the return
    # value, hiding the pairing code and corrupting the exit code. ham-bridge's exit
    # code is returned unchanged.
    & $bridge @argv | Out-Host
    return $LASTEXITCODE
  } catch {
    $code = $_.Exception.Data['HeimdallExitCode']
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    if ($code) { return [int]$code } else { return 3 }
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
  }
}

$HeimdallExitCode = Invoke-HeimdallBootstrap
# Only a script file (-File) exits with the code; the scriptblock/iex forms leave
# it in $LASTEXITCODE so the operator's window stays open.
if ($MyInvocation.InvocationName -and $MyInvocation.MyCommand.Path) { exit $HeimdallExitCode }
$global:LASTEXITCODE = $HeimdallExitCode
