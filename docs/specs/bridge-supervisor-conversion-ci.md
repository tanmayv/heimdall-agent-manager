# Cross-OS conversion CI (P2-7)

Spec §13 of `bridge-supervisor-conversion.md` says what must be proven; this file maps it to the
job that proves it. Workflow: `.github/workflows/conversion-e2e.yml` (ubuntu-24.04, macos-15,
windows-2022). Harness: `tests/e2e/conversion_e2e.mjs`.

## How it works

1. **Build** (`scripts/supervisor/conversion-build.sh`, Windows: `scripts/windows/build.ps1
   -ExtraOdinFlags`): a supervisor-capable bundle (`ham-bridge`, `ham-ctl`, `ham-pty-host`,
   `ham-launcher`, `ham-supervisor`) at test version 0.9.0 (newer than every legacy release),
   compiled with `-define:HEIMDALL_SUPERVISOR_TEST=true` and the e2e test key
   (`src/supervisor/testdata/e2e-test-key.pub`) as an extra trusted key; plus
   `tools/conversion_release_server`. The Unix script fails if a default build carries the
   hooks or the key.
2. **Legacy install**: the REAL v0.5.77 / v0.5.86 release (SHA-256 checked against the release's
   `SHA256SUMS`) runs its own `ham-bridge setup` against a throwaway hub with the OS service
   manager; the harness approves the pairing code like `/device/add` (same flow as
   `bridge_lifecycle_e2e.mjs`). The bridge must connect before anything is converted.
3. **Fake release repo**: `conversion_release_server` packs the bundle, signs a release manifest
   with the test key and serves it as GitHub does (`/gh/<repo>/releases/download/...`).
4. **Trigger**: the legacy `ham-bridge update --bundle <bundle> --service S --auto-worker`
   (the only seam the old, GitHub-hard-wired updater has, as in P2-6) runs the NEW setup, which
   fetches and verifies the release from the fake origin.

## Test hooks (test builds only)

Service-manager-started processes do not inherit the test's environment, so the harness writes
`~/.heimdall-supervisor-test.env` (`KEY=VALUE`), read by `service.test_env`
(`src/supervisor/service/test_env.odin`) after the environment itself:

| Key | Effect |
|---|---|
| `HEIMDALL_SUPERVISOR_TEST_ORIGIN` | fake GitHub for setup's fetch and the supervisor's resolver |
| `HEIMDALL_CONVERT_FAIL_AFTER=C<n>` | step `C<n>` returns an error after its effects (rollback must undo them) |
| `HEIMDALL_CONVERT_KILL_AFTER=C<n>` | setup exits abruptly (137, no rollback code runs) after `C<n>` |
| `HEIMDALL_CONVERT_GATE_SECONDS=<s>` | the Q3 gate waits `<s>` instead of 2 h |

## Phases and §13 coverage

| Phase | What | §13 item |
|---|---|---|
| P1 v0.5.77 | auto-update converts; journal `committed`, `known-good.json`, connected; the old worker exits 0 and its late bookkeeping leaves the instance healthy; `status`, `service restart` work | 1 |
| P2 v0.5.86 | the same for the newest legacy release | 1 |
| P3 v0.5.77 | `FAIL_AFTER` C2..C7 (each: old bridge running and connected, `bin/` (minus the `ham-ctl-<svc>` wrapper), service definition, credentials and config identical, no `instance.json`/`releases/`/`launcher/`); abrupt exit after C4 (rescuer); Q3 gate: waits with a running agent (countdown file, agent untouched, nothing changed), forced after the test timeout (agent stopped); abrupt exit after C8 then `finalize_conversion` | 2, 4 |
| P4 v0.5.77 | hub-started update converts a legacy bridge; the next hub update becomes an `install_version` intent | 1 |
| P5 v0.5.77 | `install.sh` / `install.ps1` re-run converts | 1 |

## Not covered here (unit-tested in `src/bridge/convert_cmd_test.odin`, or later)

Manifest failures (§13.5), two profiles / other OS user (§13.6), Windows task rename (§13.7) and
the `KillMode` flip (§13.8) have unit coverage with fake host seams; READY timeout / probation
crash (§13.3) are the T15 suite's (`supervisor-e2e.yml`). Real logon/logoff is not simulated.
