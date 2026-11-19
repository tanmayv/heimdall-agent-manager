# Tests build.ps1's component routing with fake libraries/compiler; no VS needed.
# Run with powershell.exe or pwsh -NoProfile -File scripts/windows/test-build-nats.ps1.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$temp = Join-Path ([IO.Path]::GetTempPath()) ('heimdall nats-routing-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $temp | Out-Null
try {
  # Isolate fake dependencies from real builds and downloads.
  $scripts = Join-Path $temp 'scripts/windows'
  $deps = Join-Path $temp 'deps'
  New-Item -ItemType Directory -Force $scripts, $deps, (Join-Path $temp 'nix') | Out-Null
  Copy-Item (Join-Path $PSScriptRoot 'build.ps1') $scripts
  Copy-Item (Join-Path $repo 'nix/libcurl-pin.json') (Join-Path $temp 'nix')
  foreach ($lib in 'sqlite3.lib', 'libcurl.lib', 'zlib.lib') {
    Set-Content (Join-Path $deps $lib) 'fixture'
  }
  $compiler = Join-Path $temp 'odin.ps1'
  @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$OdinArgs)
$OdinArgs | ConvertTo-Json -Compress | Add-Content (Join-Path $PSScriptRoot 'calls.jsonl')
$global:LASTEXITCODE = 0
'@ | Set-Content $compiler
  @'
param([string]$OutDir)
New-Item -ItemType Directory -Force (Join-Path $OutDir 'lib') | Out-Null
foreach ($lib in 'ham_nats.lib', 'nats_static.lib', 'ssl.lib', 'crypto.lib') {
  Set-Content (Join-Path $OutDir "lib/$lib") 'fixture'
}
Add-Content (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'nats-builds.txt') 'build'
'@ | Set-Content (Join-Path $scripts 'build-nats.ps1')
  $build = Join-Path $scripts 'build.ps1'
  $callsPath = Join-Path $temp 'calls.jsonl'
  $buildsPath = Join-Path $temp 'nats-builds.txt'
  & $build -OutDir (Join-Path $temp 'out') -Odin $compiler -CurlLibDir $deps -SqliteLibDir $deps -Components ham-bridge,ham-ctl
  if (Test-Path $buildsPath) { throw 'bridge/ctl unexpectedly built NATS' }
  $calls = @(Get-Content $callsPath | ForEach-Object { ,(ConvertFrom-Json $_) })
  if ($calls.Count -ne 2) { throw 'expected bridge and ctl invocations' }
  foreach ($call in $calls) {
    $flags = @($call | Where-Object { $_ -like '-extra-linker-flags:*' })
    $expectedPath = '/LIBPATH:"' + ($deps -replace '\\\\', '/') + '"'
    if ($flags.Count -ne 1 -or -not $flags[0].Contains($expectedPath)) { throw "library path quoting broken: $flags" }
    if (($call -join ' ') -match 'nats/lib|crypt32|ham_nats') { throw 'bridge/ctl gained NATS linker inputs' }
  }
  Remove-Item $callsPath
  & $build -OutDir (Join-Path $temp 'out') -Odin $compiler -CurlLibDir $deps -SqliteLibDir $deps -Components ham-hub
  if (@(Get-Content $buildsPath).Count -ne 1) { throw 'hub must build NATS exactly once' }
  $call = Get-Content $callsPath | ConvertFrom-Json
  $flags = @($call | Where-Object { $_ -like '-extra-linker-flags:*' })
  if ($flags.Count -ne 1 -or $flags[0] -notmatch '/LIBPATH:.*nats/lib' -or $flags[0] -notmatch 'crypt32.lib') {
    throw "missing hub NATS linker inputs: $flags"
  }
  # Explicit reuse must not invoke the builder.
  foreach ($lib in 'ham_nats.lib', 'nats_static.lib', 'ssl.lib', 'crypto.lib') {
    Set-Content (Join-Path $deps $lib) 'fixture'
  }
  & $build -OutDir (Join-Path $temp 'out') -Odin $compiler -CurlLibDir $deps -SqliteLibDir $deps -NatsLibDir $deps -Components ham-hub
  if (@(Get-Content $buildsPath).Count -ne 1) { throw 'explicit NatsLibDir rebuilt NATS' }
  Remove-Item (Join-Path $deps 'crypto.lib')
  $rejected = $false
  try {
    & $build -OutDir (Join-Path $temp 'out') -Odin $compiler -CurlLibDir $deps -SqliteLibDir $deps -NatsLibDir $deps -Components ham-hub
  } catch {
    if ($_.Exception.Message -notlike 'crypto.lib not found*') { throw }
    $rejected = $true
  }
  if (-not $rejected) { throw 'incomplete NATS libraries were accepted' }
  Write-Host 'PASS: bridge/ctl isolation, hub build, explicit reuse, missing library rejection (4 checks)'
} finally {
  Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
}
