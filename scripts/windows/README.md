# Windows hub dependencies

The default Windows release builds only the bridge, CLI and PTY host. NATS is
built and linked only when selecting the opt-in hub with
`scripts/windows/build.ps1 -Components ham-hub`.

Run builds from an **x64 Visual Studio 2022 developer PowerShell** with Odin,
CMake and Strawberry Perl installed. Git's MSYS Perl cannot build native
OpenSSL. `build-nats.ps1 -Perl <path>` can select another native Windows Perl.

`nix/nats-windows-pin.json` records source URLs and SHA-256 hashes.
The nats.c version must match the locked nixpkgs version used by
`nix/nats.nix` (currently 3.13.0). Windows uses static OpenSSL 3.6.4 for
NATS TLS; Windows libcurl continues to use Schannel. All three C builds
(nats.c, OpenSSL and the adapter) use the static MSVC runtime. OpenSSL is built
without assembly, external provider modules or shared libraries.

Build and reuse the native libraries:

```powershell
scripts/windows/build-nats.ps1 -OutDir C:/heimdall-deps/nats
scripts/windows/build.ps1 -OutDir C:/heimdall-bin -Components ham-hub -NatsLibDir C:/heimdall-deps/nats/lib
```

Omit `-NatsLibDir` to build the dependencies automatically. The library directory
contains `ham_nats.lib`, `nats_static.lib`, `ssl.lib` and `crypto.lib`.
The NATS builder compiles and runs a C smoke executable that links the adapter,
checks nats.c's version and confirms TLS is compiled in. A cached build must be
invalidated when the source pin, builder or adapter changes.

## Native Windows validation

The Windows job in `.github/workflows/bridge-lifecycle-e2e.yml` builds these
libraries, builds the opt-in hub and runs the real enrollment and lifecycle
suites. Its NATS helper starts a private `nats-server -js` for each hub on an
ephemeral loopback port with a private store, supplies `HEIMDALL_NATS_URL`,
clears inherited credentials/CA settings, and stops the child during teardown.
Do not start a second ambient NATS server for these suites.

Equivalent local validation from the repository root, after installing Node 22+
and Go (and the native build tools above):

```powershell
npm ci
go install github.com/nats-io/nats-server/v2@v2.14.7
if ($LASTEXITCODE -ne 0) { throw 'NATS server build failed' }
$env:HEIMDALL_E2E_NATS_BIN = Join-Path (go env GOPATH) 'bin/nats-server.exe'
scripts/windows/test-build-nats.ps1
scripts/windows/build.ps1 -OutDir C:/heimdall-bin -Components ham-bridge,ham-hub,ham-pty-host
$env:HEIMDALL_E2E_HUB_BIN = 'C:/heimdall-bin/ham-hub.exe'
$env:HEIMDALL_E2E_BRIDGE_BIN = 'C:/heimdall-bin/ham-bridge.exe'
node --test tests/e2e/nats_server_test.mjs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/e2e-bridge-enroll.ps1 -SkipBuild -Lifecycle
```

Set `HEIMDALL_E2E_SERVICE=1` to include scheduled-task service installation as
the CI job does. Save the builder's version/TLS smoke result and the E2E result
as execution evidence. This procedure is a reproduction recipe, not a claim
that a native Windows run has already passed.

The routing test uses fake libraries and a fake compiler to verify that
bridge/CLI builds never build or link NATS, the hub builds it automatically,
explicit libraries are reused, incomplete libraries fail early, and component-specific linker paths are supplied. It also runs under PowerShell 7 on Linux; that run does not
validate MSVC linking or Windows hub startup.
