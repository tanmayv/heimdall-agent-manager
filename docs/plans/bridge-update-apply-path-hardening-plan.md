# Bridge Update Apply Path: Robustness Audit & Hardening Plan

**Audit & Implementation Plan**
**Document Location**: `docs/plans/bridge-update-apply-path-hardening-plan.md`
**Requirement IDs**: `REQ-BUPD-FIX-1` … `REQ-BUPD-FIX-11`
**Status**: Audit reviewed, implementation plan locked, implementation in progress
**Target Subsystems**: `scripts/apply-bridge-update.sh`, `scripts/install.sh`, `src/bridge/`, `src/hub/`, `tests/`
**Relates to**: `docs/bridge_update_pipeline_design.md` (`REQ-BUPD-1` … `REQ-BUPD-6`) — this plan audits that
design as built and fixes where the implementation diverges from it.

---

## 1. Verdict

The UI-triggered update path — **Update** button → `POST /api/v1/bridges/{id}/update` →
`bridge_service.send_bridge_update` → WS `bridge_update` → `bridge_runtime_apply_update`
(`src/bridge/hub_runtime_client.odin:1097`) → detached `scripts/apply-bridge-update.sh` — **does not
satisfy either of its two core requirements**: the binaries are not replaced, and the restart
relaunches the old build.

Detection is sound. Apply, restart, and authoritative completion reporting are not.

| Stage | State |
|---|---|
| Version reporting (`bridge_hello` → `bridges.version`) | works |
| Update availability detection (`is_bridge_update_available`) | works |
| Progress frames to UI (`bridge_update_progress`) | works |
| Bundle download | **fails — no route serves the default URL (F1)** |
| Bundle integrity verification | **skipped when no manifest is configured (F7)** |
| Binary replacement | **writes to a directory nothing executes (F2)** |
| Restart | restarts the service, which re-execs the **old** binary (F2) |
| Success/failure signal | **reports success before restart and reconnect prove the target build is running (F2, F5, F9)** |
| Rollback | **impossible on a standard install (F3)** |
| Failure containment | **no ERR trap; mid-swap failure leaves the bridge stopped (F4)** |

### 1.1 Method, and what was deliberately not run

Findings are from source reading only. The apply path was **not executed**: `stop_service`'s fallback
is `pkill -f "ham-bridge"` (`scripts/apply-bridge-update.sh:129`), which kills every matching process
on the host. `src/bridge/bridge_update_test.odin:24-32` records that this previously killed the live
dawnstar bridge and the unrelated `heimdall-bridge-qa` service, and is why the end-to-end test was
deleted. Re-running it to confirm these findings would reproduce that outage, so §6 makes a test seam
a prerequisite rather than an afterthought.

---

## 2. Root Cause: Two Divergent Install Layouts

`apply-bridge-update.sh` was written against the layout that `install.sh`'s `do_update()` function
creates. A **fresh** `install.sh` run creates a different one. Nothing reconciles them.

| | fresh `install.sh` | `do_update()` | `apply-bridge-update.sh` assumes |
|---|---|---|---|
| binary location | `install -m 0755` **copies** into `$install_dir` (`:2670`) | `$data_dir/bin` (`:1956`, `:2204`) | `$DATA_DIR/bin` |
| `$install_dir` | `/usr/local/bin` or `~/.local/bin` (`:2387`, `:2407`) | symlinks `ham-ctl` only (`:2250`) | not consulted |
| unit `ExecStart` | `"$install_dir/ham-bridge"` (`:943`) | unchanged | not consulted |
| `$DATA_DIR/bin` exists? | **no** — never created outside `do_update()` | yes | assumed yes |
| supervisor script present? | **no** — copied only in `do_update()` (`:2241-2244`) | yes | assumed findable |

Everything in §3 follows from this. The supervisor performs a technically correct atomic swap of a
directory that, on a standard install, neither exists beforehand nor is executed afterwards.

`scripts/install.sh:2612-2616` already documents this failure class for `heimdall update`:

> `heimdall update` stops the service by NAME, replaces binaries in a directory that unit never
> execs, and restarts it: a production bounce for zero benefit. T22 (REQ-INST-24) fixes that

The supervisor has the same defect, and additionally reports success.

---

## 3. Findings

### F1 — Blocking: the bundle download 404s · `REQ-BUPD-FIX-6`

`resolve_bridge_update_info` defaults `download_url` to
`/api/v1/updates/bundle/heimdall-local-<target>.tar.gz`
(`src/hub/service/bridge/bridge_update_catalog.odin:127`). **No `/api/v1/updates/bundle/*` route is
registered** in `src/hub/app/wiring.odin` — only tests reference the path.

The only way to supply a working URL is the `HEIMDALL_UPDATE_MANIFEST_PATH` env var: nothing
populates `catalog.override_version` / `override_download_url` / `override_sha256` /
`manifest_path` from a CLI flag or config key, and neither deployed hub sets the env var (the
`heimdall-hub-prod` unit's `environment` block carries only `HAM_TLS_CA_FILE` and `SSL_CERT_FILE`).

**Consequence**: from the UI today, the update fails at `tarball download failed (HTTP 404)`. This is
fail-safe, but it means F2–F7 have never run in production and are latent.

### F2 — Critical: silent no-op reported as success · `REQ-BUPD-FIX-1`

With F1 fixed, the sequence is: supervisor swaps `$DATA_DIR/bin` → restarts the unit → unit re-execs
`$install_dir/ham-bridge`, which is **untouched** → health probe returns 200 → supervisor deletes
`bin.bak` and the staging dir → exits 0 → hub receives `bridge_hello` carrying the **old**
`APP_VERSION`.

**Consequence**: the UI still shows "update available", and clicking Update again repeats
indefinitely. A production service bounce for zero change, reported to the operator as success. This
is the finding that most directly contradicts the requirement.

### F3 — Critical: rollback cannot work · `REQ-BUPD-FIX-3`

The backup is guarded `if [ -d "$DATA_DIR/bin" ]` (`apply-bridge-update.sh:159`), false on a standard
install, so no `bin.bak` is written. The rollback branch then logs
`No $DATA_DIR/bin.bak found to restore from!` and continues to restart anyway.

**Consequence**: `REQ-BUPD-5`'s "guaranteed automated rollback" does not hold. Whether a failed update
can be recovered depends on whether `do_update()` happened to run on that host previously.

### F4 — Critical: a mid-swap failure bricks the bridge · `REQ-BUPD-FIX-2`

`set -euo pipefail` with **no `trap` on `ERR` or `EXIT`** anywhere in the 234-line script.
`stop_service` runs at `:154`, before the backup and swap. If any subsequent step fails —
`cp -R -p "$STAGE_BIN/"*`, either `mv`, a full disk, a permissions error — the script aborts
immediately with the bridge **stopped and never restarted**, and the rollback code is unreachable
because it lives only inside the health-check `else` branch (`:210`).

**Consequence**: exactly the bricking risk `docs/bridge_update_pipeline_design.md` §1 was written to
eliminate. A remote bridge is left offline with no recovery path short of manual SSH.

### F5 — High: the health gate cannot distinguish old from new · `REQ-BUPD-FIX-4`

`if [ "$http_code" = "200" ] || [ "$http_code" = "401" ]` (`:196`). Two problems: `401` is accepted
as healthy, and the gate never inspects the reported version or commit. A successfully restarted
**old** binary satisfies it — which is precisely what F2 produces.

Prerequisite: `bridge_health_json` (`src/bridge/main.odin:537`) currently emits `ok`,
`contract_version`, `ws_frame_version`, `self_daemon_id`, `bridge_id`, `chunk_bytes`,
`large_payload_target_bytes` — **no version, commit or pid**. The gate cannot be fixed without
adding them.

### F6 — High: `pkill -f "ham-bridge"` is host-wide · `REQ-BUPD-FIX-5`

`stop_service`'s final fallback (`:129`) matches every process whose command line contains
`ham-bridge` — other bridges, QA services, log tails, editors. Known and documented
(`src/bridge/bridge_update_test.odin:24-32`); still live.

**Consequence**: on any host running more than one bridge, or a dev box running hub and bridge
together, an update takes down unrelated services. Also blocks automated testing of the apply path.

### F7 — Medium: the bundle is executed unverified · `REQ-BUPD-FIX-7`

`sha256 := ""` (`bridge_update_catalog.odin:128`) unless a manifest supplies it, and the bridge skips
verification entirely when the field is empty:
`if strings.trim_space(sha256) != ""` (`src/bridge/hub_runtime_client.odin:1177`).

**Consequence**: integrity checking is opt-in, and the default UI path does not opt in. A corrupted or
substituted bundle would be extracted and executed. The preflight `--version` check is the only
barrier, and it does not authenticate anything.

### F8 — Low: unreachable and machine-specific supervisor lookup · `REQ-BUPD-FIX-8`

`script_candidates` (`src/bridge/hub_runtime_client.odin:1243-1247`) contains a CWD-relative entry
(`scripts/apply-bridge-update.sh`) and a hardcoded personal path
(`/usr/local/google/home/tanmayvijay/heimdall-cloudtop/scripts/apply-bridge-update.sh`, repeated at
`src/hub/transport/http/bridge_update_integration_test.odin:363`). On a fresh install none of the five
candidates resolves, because the script is only copied by `do_update()`.

### F9 — Critical: update completion is not durable or authoritative · `REQ-BUPD-FIX-9`

The bridge reports the update as succeeded before the replacement process has restarted and proved
its identity. The hub then resets `updating` to `idle` on a reconnect without reconciling the
reconnected bridge's version and commit against the requested target. There is no durable update
attempt to survive a hub restart between dispatch and reconnect.

**Consequence**: an old binary, a rollback, or an unrelated reconnect can be presented as a
successful update. The operator cannot distinguish accepted, restarting, verified, rolled back, and
timed-out states.

### F10 — Critical: the PTY host survives a bridge binary update · `REQ-BUPD-FIX-10`

The PTY-host daemon deliberately outlives the bridge and is adopted by the replacement bridge. That
is correct for an ordinary bridge restart, but wrong when the update bundle contains a new
`ham-pty-host`: the old daemon and executable continue serving new work after the bridge claims the
bundle was applied. Active agent, shell, and provider-test sessions also make an unqualified update
unsafe.

**Consequence**: the running process set can contain mixed releases, and an update can interrupt
live work without an explicit force decision.

### F11 — High: service control is neither installed nor portable · `REQ-BUPD-FIX-11`

The supervisor assumes a systemd unit name that does not match the installer's current unit and has
no equivalent contract for launchd or standalone processes. Inferring service ownership from
ambient host state is ambiguous and makes the fallback paths dangerous.

**Consequence**: the same bundle can stop the wrong service, fail to restart the right one, or behave
differently across supported operating systems.

---

## 4. Target Design

### 4.1 Immutable releases and one atomic activation pointer

Installer-managed binaries use this canonical layout:

```text
$DATA_DIR/
  releases/<version>-<commit>/bin/{ham-bridge,ham-pty-host,...}
  current -> releases/<version>-<commit>
$install_dir/ham-bridge -> $DATA_DIR/current/bin/ham-bridge
```

The supervisor stages and validates a new immutable release, fsyncs its files and parent directory,
then atomically replaces the `current` symlink with a same-directory rename. Rollback atomically
points `current` back to the previous release. It never swaps a non-empty directory in place and
never edits a release after activation.

Existing copied-binary installs migrate only through an explicit, transactional installer step. A
host recorded as externally managed (NixOS, distro package, or another owner) is never migrated or
updated by the UI; the hub returns a distinct `externally_managed` outcome with operator guidance.
**Refuse, never no-op** is the governing rule.

### 4.2 Installed service descriptor

Fresh installs and explicit migrations write `$DATA_DIR/install.json` atomically. It is the only
authority the supervisor uses for process and path ownership. The versioned contract contains:

- `schema_version`, `managed_by`, and `service_manager`
- the systemd user unit, launchd label, or standalone pid-file identity
- `release_root`, `current_link`, and exposed command-link directory
- bridge port and the **path** to the bridge token file (never the token value)
- PTY-host socket/pid metadata needed to stop and replace that daemon

The allowed `service_manager` values are `systemd-user`, `launchd-user`, and `standalone`.
Unknown versions, missing required fields, mismatched executable paths, or `managed_by !=
"heimdall-installer"` fail before any process is stopped. The installer owns platform-specific
service creation; the supervisor consumes the descriptor and does not guess unit names.

### 4.3 Idempotent failure-containment state machine

The supervisor records explicit in-process phases: `preflight_complete`, `service_stopped`,
`activation_changed`, `service_started`, and `verified`. Its `ERR`/`EXIT` handler is idempotent:

- before activation, restart only if this invocation stopped the service
- after activation but before verification, restore the prior `current` link and restart it
- after verification, disable rollback cleanup and retain releases according to policy

All command execution uses argv arrays or fixed case branches; `eval` is forbidden. The failed
release and bounded diagnostics are retained for investigation. Deterministic fault-injection hooks
exercise each transition in tests without using full disks, permissions tricks, or real services.

### 4.4 Authenticated identity gates before and after restart

`bridge_health_json` gains `version`, `commit_sha`, `built_at`, and `pid`. Health remains protected by
the bridge bearer token. The supervisor receives only `--token-file <path>`, reads the credential
from the installed 0600 file, sends `Authorization: Bearer ...`, and never places or logs the token
in argv.

The hub update command includes `target_version`, `target_commit_sha`, bundle `sha256`, and an
`update_attempt_id`. Before stopping the service, the staged bridge must report matching build
identity through a side-effect-free machine-readable command such as `--build-info-json`. After
restart, authenticated health must return HTTP 200 and the exact target version and commit. A 401,
old build, wrong commit, timeout, or malformed body fails verification and triggers rollback.

### 4.5 Durable, reconnect-based completion

The hub persists one update-attempt record before dispatch, keyed by `update_attempt_id`, with bridge
id, target identity, checksum, status, timestamps, and bounded error details. States are:

```text
requested -> accepted -> restarting -> verifying -> succeeded
                                      \-> rolling_back -> failed
requested/accepted/restarting/verifying -> timed_out
```

The original bridge may acknowledge only `accepted`/`restarting`; it cannot report final success.
On `bridge_hello`, the hub reconciles the bridge's reported version and commit with the active
attempt. Only an exact match marks `succeeded`. A reconnect on the old identity after rollback marks
`failed`; an unrelated or stale reconnect leaves the attempt pending until timeout. Attempts and
their deadlines survive a hub restart, and duplicate commands with the same attempt id are
idempotent.

### 4.6 Scoped drain and complete process replacement

The normal update path fails closed if any agent launch, shell session, server session, provider
test, or other PTY consumer remains at drain timeout. A separately authorized `force` update stops
those resources through their owning APIs and waits for their registered readers/owners to finish;
it does not use process-name matching.

After the bridge stops, the supervisor shuts down the installed PTY-host daemon using the descriptor
identity and waits for exit. The replacement bridge must start a new PTY-host from the activated
release. Verification includes both bridge and PTY-host build identity/PID, so adoption of the old
daemon cannot pass. `pkill -f` is removed entirely.

### 4.7 Bundle source, authentication, and archive safety

The hub serves bundles from an explicitly configured local release directory; there is no synthetic
default URL when no bundle exists. A release manifest generated by release tooling supplies target
platform, version, commit, size, and mandatory SHA-256. The checksum travels in the authenticated
hub-to-bridge command, so a bundle endpoint cannot substitute both archive and expected digest.

Bundle download requires bridge authentication (or a short-lived, attempt-bound signed URL). HTTPS
is required for non-loopback hub URLs. Extraction rejects absolute paths, `..` traversal, device
nodes, and symlink/hardlink escapes, and enforces size/file-count limits before anything becomes
executable. A missing checksum, missing target identity, or unsupported platform is a preflight
failure.

---

## 5. Work Items

| ID | Finding | Change | Subsystem |
|---|---|---|---|
| `REQ-BUPD-FIX-1` | F2 | Immutable release directories, atomic `current` link, explicit transactional migration, and external-manager refusal | installer, supervisor |
| `REQ-BUPD-FIX-2` | F4 | Idempotent phase-based `ERR`/`EXIT` recovery with deterministic fault injection | supervisor |
| `REQ-BUPD-FIX-3` | F3 | Roll back by atomically restoring the previous release link; retain failed release and diagnostics | supervisor |
| `REQ-BUPD-FIX-4` | F5 | Build identity in health and staged binary; token-file-authenticated exact version/commit verification | bridge, supervisor, installer |
| `REQ-BUPD-FIX-5` | F6 | Descriptor/PID-scoped stop; remove `pkill -f` and shell `eval` | bridge, supervisor |
| `REQ-BUPD-FIX-6` | F1 | Configured authenticated bundle route; no fabricated URL when no release exists | hub catalog/transport/config |
| `REQ-BUPD-FIX-7` | F7 | Mandatory authenticated checksum plus bounded, traversal-safe archive validation | hub, bridge |
| `REQ-BUPD-FIX-8` | F8 | Ship and install the supervisor on every installer-managed platform; one descriptor-provided path | release tooling, installer, bridge |
| `REQ-BUPD-FIX-9` | F9 | Durable attempt state machine; expected commit on wire; reconnect reconciliation and timeout recovery | contracts, hub store/service, UI |
| `REQ-BUPD-FIX-10` | F10 | Drain every PTY consumer, stop old PTY host, and verify replacement daemon identity | hub, bridge, PTY host, supervisor |
| `REQ-BUPD-FIX-11` | F11 | Versioned install/service descriptor for systemd-user, launchd-user, and standalone modes | installer, supervisor |

### 5.1 Suggested order

1. **Test seam + `FIX-5`.** Replace direct detached execution with an injectable supervisor-launch
   boundary, delete host-wide matching, and prove an unrelated bridge survives.
2. **`FIX-11` + `FIX-8`.** Lock the install/service descriptor, platform adapters, and supervisor
   location before changing layouts.
3. **`FIX-9`.** Add the wire fields and durable attempt store so later apply work cannot claim
   success prematurely.
4. **`FIX-4`.** Add staged and live authenticated identity gates. Until activation is implemented,
   this converts silent no-ops into explicit failures.
5. **`FIX-2` + `FIX-3`.** Implement the phase state machine and rollback under fault injection.
6. **`FIX-1`.** Add immutable releases, atomic activation, fresh-install layout, and explicit
   migration.
7. **`FIX-10`.** Complete drain accounting and PTY-host replacement/verification.
8. **`FIX-6` + `FIX-7`.** Expose configured bundles, enforce integrity/archive policy, then enable
   the end-to-end UI path.

Each step must be independently safe to merge. The UI update action remains disabled unless the hub
catalog, install descriptor, and bridge capabilities all advertise the complete protocol.

### 5.2 Implementation progress

- **2026-10-09 — Step 1 / `REQ-BUPD-FIX-5` foundation implemented.** Bridge update launch now goes
  through an injectable, structured-argv supervisor boundary and passes the exact current bridge
  PID. The supervisor no longer uses `pkill -f`, shell command strings, or `eval`; it stops only the
  supplied PID (or an explicit executable test hook) and fails closed when no scoped stop mechanism
  exists. Focused coverage asserts the launch argv and proves an unrelated bridge-like process
  remains alive. Descriptor-authoritative service restart remains part of Step 2 (`FIX-11`).

---

## 6. Testing

The existing end-to-end test was deleted as unsafe
(`src/bridge/bridge_update_test.odin:20-32`), and its deletion note sets the requirement:

> Any future coverage of the apply path must inject a seam for the supervisor spawn rather than
> letting the real script run.

**Prerequisite — the spawn seam.** `bridge_runtime_apply_update` currently spawns via
`os.process_exec` on a `nohup …` string (`hub_runtime_client.odin:1266-1272`). Introduce an
injectable spawn (a proc pointer, or an env override consulted only under test) so tests can assert
the supervisor's argv — data dir, stage dir, port, hub url, and the new `--bridge-pid` — without
executing it. The `when !ODIN_TEST` guard at `:1286` only suppresses the test binary's own
self-exit and sits one step too late.

**Supervisor coverage.** `tests/test_bridge_update_supervisor.sh` already exists and drives the
script directly; extend it, using the existing `--stop-cmd` / `--restart-cmd` / `--health-url`
injection points against a fake service in a temp dir, to cover:

- correct activation under systemd-user, launchd-user, and standalone adapters
- missing, malformed, external-manager, or executable-mismatched descriptor → nothing stopped
- every injected failure phase → prior release active and service running exactly once
- health without auth or with a wrong token → 401 and verification failure
- health returns 200 with old version or wrong commit → rollback
- staged build identity disagrees with the manifest → refused before drain/stop
- unrelated bridge process survives and no process-name kill is invoked
- active agent, shell, server, or provider-test session → normal update refuses
- forced drain waits for registered owners, old PTY host exits, and a new binary/PID is verified
- empty/mismatched checksum, oversized archive, traversal, or escaping link → refused before extract

**Hub and contract coverage:**

- command round-trip preserves attempt id, target version, target commit, checksum, and force bit
- update attempt survives a hub restart between dispatch and bridge reconnect
- matching reconnect completes exactly once; stale/old/wrong-commit reconnect cannot complete it
- rollback reconnect records failure; deadline expiry records `timed_out`
- duplicate dispatch/reconnect frames are idempotent
- UI renders externally managed, draining, restarting, rolling back, failed, timed out, and succeeded

**End-to-end acceptance:** build a configured local bundle, enroll a local bridge, start a
disposable agent and shell to prove non-force refusal, then apply the update and verify both bridge
and PTY-host version/commit/PID changed. Restart the hub during a second attempt and prove durable
reconciliation. No test may target the developer's installed service or use global process matching.

---

## 7. Locked Decisions

1. **Bundle source:** the hub serves release-tool-generated bundles from an explicitly configured
   local directory. Absence is an unavailable capability, not a guessed URL.
2. **Trust model:** the authenticated hub command carries the mandatory checksum and target identity;
   bundle retrieval is authenticated and uses TLS off-loopback. Release signing can be added later
   without weakening this threat model because a compromised trusted hub can already command a
   bridge.
3. **Layout:** installer-managed hosts use immutable releases plus an atomic `current` link. Existing
   hosts migrate only through an explicit installer operation.
4. **External managers:** NixOS and package-managed bridges are reported as externally managed and
   cannot be mutated through the UI update path.
5. **Drain:** timeout fails closed. `force` is explicit, audited, and stops all registered PTY
   consumers before replacing the PTY host.
6. **Completion:** only the hub may declare success, after an authenticated reconnect reports the
   exact requested bridge and PTY-host identities.

## 8. Completion Gate

Implementation is complete only when every `REQ-BUPD-FIX-*` has a passing automated test linked in
the change summary, all three service-manager adapters pass supervisor contract tests, hub-restart
reconciliation passes, archive adversarial tests pass, and the isolated local end-to-end scenario in
§6 succeeds. A 200 response, script exit 0, service restart, or version-only match is not sufficient
evidence by itself.
