# Builds the opt-in Windows hub's static nats.c, OpenSSL and ham_nats adapter.
# Requires x64 VS tools (cl/lib/nmake), CMake and Strawberry Perl. No DLLs.
# Sources and SHA-256 are pinned in nix/nats-windows-pin.json; nats.c must match
# nix/nats.nix's locked nixpkgs version. Output: lib/{ham_nats,nats_static,ssl,crypto}.lib.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$Perl = '',
  [string]$WorkDir = ''
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pinPath = Join-Path $repo 'nix\nats-windows-pin.json'
$pin = Get-Content -Raw $pinPath | ConvertFrom-Json

function Invoke-Checked([string]$what, [scriptblock]$block) {
  & $block
  if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}
function Get-PinnedTarball($entry, [string]$dest) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  (New-Object Net.WebClient).DownloadFile($entry.url, $dest)
  $got = (Get-FileHash -Algorithm SHA256 $dest).Hash.ToLowerInvariant()
  if ($got -ne $entry.sha256) { throw "SHA-256 mismatch for $($entry.url): $got" }
}

# Git's MSYS Perl cannot build native OpenSSL; prefer Strawberry explicitly.
if (-not $Perl) {
  $strawberry = 'C:\Strawberry\perl\bin\perl.exe'
  if (Test-Path $strawberry) { $Perl = $strawberry }
  else { $Perl = (Get-Command perl.exe -ErrorAction Stop).Source }
}
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('heimdall-nats-' + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Force $WorkDir | Out-Null
$WorkDir = (Resolve-Path $WorkDir).Path
$libDir = Join-Path $OutDir 'lib'
New-Item -ItemType Directory -Force $libDir | Out-Null
try {
  $sslTar = Join-Path $WorkDir 'openssl.tar.gz'
  Get-PinnedTarball $pin.openssl $sslTar
  Invoke-Checked 'tar OpenSSL' { & tar -xzf $sslTar -C $WorkDir }
  $sslSrc = Join-Path $WorkDir "openssl-$($pin.openssl.version)"
  $sslOut = Join-Path $WorkDir 'openssl-install'
  Push-Location $sslSrc
  try {
    # no-shared selects /MT on VC-WIN64A. no-asm removes a NASM dependency.
    # no-module/no-pinshared keep all providers inside the executable.
    Invoke-Checked 'configure OpenSSL' { & $Perl Configure VC-WIN64A no-shared no-asm no-tests no-module no-pinshared "--prefix=$sslOut" '--libdir=lib' }
    Invoke-Checked 'build OpenSSL' { & nmake.exe /nologo }
    Invoke-Checked 'install OpenSSL' { & nmake.exe /nologo install_sw }
  } finally { Pop-Location }

  $natsTar = Join-Path $WorkDir 'nats.tar.gz'
  Get-PinnedTarball $pin.nats $natsTar
  Invoke-Checked 'tar nats.c' { & tar -xzf $natsTar -C $WorkDir }
  $natsSrc = Join-Path $WorkDir "nats.c-$($pin.nats.version)"
  $natsBuild = Join-Path $WorkDir 'nats-build'
  $cmakeArgs = @(
    '-S', $natsSrc, '-B', $natsBuild, '-G', 'Visual Studio 17 2022', '-A', 'x64',
    "-DCMAKE_INSTALL_PREFIX=$OutDir",
    '-DCMAKE_POLICY_DEFAULT_CMP0091=NEW', '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded',
    '-DNATS_BUILD_WITH_TLS=ON', '-DNATS_BUILD_TLS_FORCE_HOST_VERIFY=ON',
    '-DNATS_BUILD_OPENSSL_STATIC_LIBS=ON', '-DOPENSSL_MSVC_STATIC_RT=TRUE',
    "-DOPENSSL_ROOT_DIR=$sslOut", "-DOPENSSL_INCLUDE_DIR=$(Join-Path $sslOut 'include')",
    "-DOPENSSL_SSL_LIBRARY=$(Join-Path $sslOut 'lib\libssl.lib')",
    "-DOPENSSL_CRYPTO_LIBRARY=$(Join-Path $sslOut 'lib\libcrypto.lib')",
    '-DNATS_BUILD_USE_SODIUM=OFF', '-DNATS_BUILD_STREAMING=OFF',
    '-DNATS_BUILD_EXAMPLES=OFF', '-DNATS_BUILD_LIB_SHARED=OFF', '-DNATS_BUILD_LIB_STATIC=ON'
  )
  Invoke-Checked 'configure nats.c' { & cmake @cmakeArgs }
  Invoke-Checked 'build nats.c' { & cmake --build $natsBuild --config Release --target nats_static --parallel }
  Invoke-Checked 'install nats.c' { & cmake --install $natsBuild --config Release }
  Copy-Item (Join-Path $sslOut 'lib\libssl.lib') (Join-Path $libDir 'ssl.lib')
  Copy-Item (Join-Path $sslOut 'lib\libcrypto.lib') (Join-Path $libDir 'crypto.lib')

  $obj = Join-Path $WorkDir 'ham_nats.obj'
  $adapter = Join-Path $repo 'src\lib\nats\adapter.c'
  Invoke-Checked 'compile ham_nats' { & cl.exe /nologo /c /O2 /MT /DNDEBUG /DNATS_STATIC "/I$(Join-Path $OutDir 'include')" $adapter "/Fo$obj" }
  Invoke-Checked 'archive ham_nats' { & lib.exe /nologo "/OUT:$(Join-Path $libDir 'ham_nats.lib')" $obj }

  # Link all adapter symbols and TLS dependencies before invoking Odin.
  $smoke = Join-Path $WorkDir 'smoke.c'
  @'
#include <nats/nats.h>
#include <string.h>
extern const char *ham_nats_version(void);
int main(int argc, char **argv) {
    natsOptions *opts = NULL;
    if (argc != 2 || strcmp(ham_nats_version(), argv[1]) != 0) return 1;
    if (natsOptions_Create(&opts) != NATS_OK) return 2;
    natsStatus status = natsOptions_SetSecure(opts, true);
    natsOptions_Destroy(opts);
    nats_CloseAndWait(1000);
    return status == NATS_OK ? 0 : 3;
}
'@ | Set-Content -Encoding ascii $smoke
  $smokeExe = Join-Path $WorkDir 'smoke.exe'
  Push-Location $WorkDir
  try {
    Invoke-Checked 'link NATS smoke' { & cl.exe /nologo /O2 /MT "/I$(Join-Path $OutDir 'include')" $smoke "/Fe$smokeExe" /link "/LIBPATH:$libDir" ham_nats.lib nats_static.lib ssl.lib crypto.lib ws2_32.lib gdi32.lib advapi32.lib crypt32.lib user32.lib }
    Invoke-Checked 'NATS version and TLS smoke' { & $smokeExe $pin.nats.version }
  } finally { Pop-Location }
  Copy-Item $pinPath (Join-Path $OutDir 'nats-windows-pin.json')
  Get-ChildItem $libDir -Filter *.lib | ForEach-Object { Write-Host ("built {0} ({1:N0} bytes)" -f $_.FullName, $_.Length) }
} finally {
  Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
}
