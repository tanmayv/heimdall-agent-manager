# Bridge supervisor conversion (Phase 2: legacy `bin/` install → launcher + supervisor)

Status: **spec, for review** (chain `chain_18ea9cf21732bfc6`, task P2-1). Implemented by
P2-2 … P2-7 (§14) and rolled out by P2-8. Written against `feat/bridge-supervisor` at
`22c47a15` (v0.5.85 + the Phase 1 engine); `file:line` references are to that tree and may
drift.

Sources: plan `task_18eae3e1ceb1882d` (P2-0, comments `cmt_18eae41321cbc27b`,
`cmt_18eae4dd97f82f49`, `cmt_18eae4e4ef29563f`); engine spec
`docs/specs/bridge-supervisor-engine.md` (cited `engine §n`); installer contract
`docs/specs/bridge-installer-contract.md` (cited `contract §n`, esp. §3 rows and §7 "A
legacy (non-converted) instance … is converted by setup"); release signing
`docs/release-signing.md`.

Keywords: **must**, **must not**, **may** are normative. Everything here is **PROPOSAL**
unless it cites current code. Decisions that this spec makes on its own (the sources were
silent) are marked **[P2-1]** and are listed in §0 so the reviewer can overrule them.

## 0. Decisions this spec fixes

User decisions (plan P2-0, 2026-11-24), unchanged:

| # | Decision |
|---|---|
| U1 | Existing bridges convert **automatically on their next auto-update**; one-shot; **no change to already-released binaries** (REQ-CONV-3). |
| U2 | Running agents during conversion follow the **Q3 agent gate**: wait up to 2 h, then convert anyway, with a countdown (§9). |
| U3 | After conversion, hub-started updates are routed to the supervisor as an `install_version` intent (§12.3). |
| U4 | **No kill switch** (REQ-CONV-4 dropped). Consequence: every legacy bridge that auto-updates to the first supervisor release converts, so Mundus validation (P2-8) must precede any **stable** release. |

Decisions this spec adds **[P2-1]**:

| # | Question | Decision |
|---|---|---|
| C1 | What is "legacy"? | An instance with no valid `<data>/instance.json` and no `<data>/launcher/` that has a service registration or `bin/ham-bridge`. Classified as row **S10** (§2). |
| C2 | Which runs convert? | Every `ham-bridge setup` run of a **supervisor-capable bundle** (§3.1) on a legacy instance: the old updater's S8b (with or without `--reinstall`), an `install.sh`/`install.ps1` re-run (S2/S8a), a `--bundle` run (desktop `.pkg`/app), a plain `ham-bridge setup`. Conversion is **not** a version policy: it overrides `--keep-version`, and applies after the S8c downgrade refusal. A bundle that is **not** supervisor-capable (older release) is a plain legacy S8b update, as today. |
| C3 | New instances | S1 (nothing installed) with a supervisor-capable bundle installs the supervisor layout **directly** (§4.5, "greenfield"); it never creates a legacy `bin/` instance, so no new bridge needs a later conversion. |
| C4 | Where does the new tree come from? | From the **signed manifest and archive**, re-fetched and verified by setup (§3.2), installed by the bundle's `ham-supervisor repair` (§4, C5). The directory the old updater extracted is **not** trusted as a source of the release tree (v0.5.77 verified only `SHA256SUMS`, and never downloaded `release.json`/`.minisig`). |
| C5 | `bin/` | **Untouched** (not moved, not deleted; every file except one is never rewritten) until Phase 4. **The one exception** is the generated `bin/ham-ctl-<svc>` wrapper (§8.3), which C6 rewrites and the supervisor keeps rewriting; rollback restores it from the C3 backup. Rollback therefore needs no binary restore; the old exe in `bin/` is also the reason the legacy updater refuses to run from a release tree (§12.2). |
| C6 | Service identity | Linux unit name and macOS label/plist path are **unchanged**; only Windows renames its task (§10.3). A running-state crash therefore never leaves two definitions of one service except on Windows, where the old task is **disabled** (not deleted) until commit. |
| C7 | Env | The service definition stops naming `bin/`. The **supervisor** sets `PATH`, `HEIMDALL_HAM_PTY_HOST_BIN`, `HEIMDALL_HAM_CTL_BIN` per release tree when it spawns the runtime (§8). |
| C8 | `KillMode` | Final unit has `KillMode=control-group`, but it is written as `KillMode=process` during the transaction and flipped after the commit (§10.1), because the legacy worker and setup run inside the unit's cgroup. |
| C9 | Setup's own crash journal | `<data>/conversion.json` (§4.1). Next `setup` run rolls **forward** if the service cut-over (C6) is recorded done, otherwise rolls **back**. |
| C10 | Success criterion | Supervisor journal op `op_convert_<txn>` is `committed` **and** `known-good.json.committed_op` equals it **and**, if the legacy bridge was connected before, the hub connection is `connected` within 45 s after the commit (§4, C8). A connection failure after `committed` still rolls back to legacy (the supervisor files are deleted with the layout). |
| C11 | Agents | Gate counts the profile's PTY-daemon agents (§9). The gate applies only to timer-started runs; every other caller interrupts at once. |
| C12 | Legacy updater | Off by an explicit marker, not by accident: a valid `instance.json` makes `ham-bridge` skip the auto-update timer, refuse `--auto-worker`, and route `update` to the supervisor (§12). The user-wide lock file and `auto-update.json` are left alone (§11). |

## 1. Scope, trigger and isolation

In scope: converting one legacy instance (one service name `heimdall-bridge-<hub>[_<profile>]`,
`bridgesvc.odin:188-191`) to the launcher + supervisor layout of engine §3 on Linux (incl.
Fedora Atomic), macOS and Windows (REQ-OS-1). Out of scope: Termux (no bundle, engine §1;
Termux stays legacy), the Phase 3 hub UI, deletion of `bin/` and the legacy updater code
(Phase 4), Nix/home-manager installs.

**Trigger (REQ-CONV-3).** There is nothing to add to old binaries. A v0.5.77+ bridge:

1. its timer finds the newest release and spawns `ham-bridge update --version <tag>
   --service <svc> --auto-worker` (`src/bridge/auto_update.odin:349,436`);
2. the worker takes `~/.heimdall-auto-update.lock` (`update_cmd.odin:59`), downloads the
   bundle and `SHA256SUMS`, preflights the new `ham-bridge --version` and checks it is newer
   (`update_cmd.odin:92-131`);
3. it runs the **new** bundle's `ham-bridge setup --hub H [--profile P] --headless
   [--reinstall] [--json-progress]` (`update_setup_argv`, `src/lib/bridgesvc/uninstall.odin:266-279`;
   v0.5.77 passes no `--reinstall`, i.e. contract row S8b, later builds pass it) and waits for
   its exit code with no timeout (`bridge_setup_exec_inherit`, `setup_cmd.odin:243`).

Everything after step 3 is new code in the first supervisor release's setup. The release
must keep the shape the old updater expects: asset name `heimdall-local-<target>-<tag>.tar.gz`
/ `.zip`, `SHA256SUMS`, `ham-bridge` at `<bundle>/bin/ham-bridge` (`update_bundle_exe`,
`uninstall.odin:255-263`), and `ham-bridge --version` printing `ham-bridge <ver>` within 5 s.

**Isolation (Q8, REQ-ISO-1).** Setup runs as the invoking OS user and only touches paths
derived from that user's `layout_for(service)`; it never enumerates other users' homes or
services. `instance.json.owner` is that user's uid/SID (engine §3). Each profile converts
independently; two profiles of one user may be at different states. The user-wide auto-update
lock (§11.1) serialises their conversions when they are timer-started.

## 2. Classification: the S-row for a legacy instance

`classify_install` (`src/lib/bridgesvc/install_state.odin:164`) gains one fact, `legacy`
(C1), one more, `bundle_supervisor_capable` (§3.1), and one more, `conversion_record`
(`<data>/conversion.json` exists). New rows (contract §3 numbering continues):

| # | Starting state | Action | Exit | Final line |
|---|---|---|---|---|
| S10 | **Legacy instance**, any of S2–S8 apart from refusals (S5b, S7a, S8c without `--allow-downgrade`), run with a supervisor-capable bundle. | Convert (§4): the version policy of S8a/S8b is replaced by "install the bundle's release as a supervisor tree". Repairs of S3/S4/S6/S7 (enroll, ports, config, service) happen in the same run, as today. | 0 / 1 / 7 | `Converted <service> v<old> → v<new> to the supervisor; connected.` |
| S10a | **Interrupted conversion**: `conversion.json` exists. | Recover first (§6.3): roll forward when C6 is recorded done, else roll back; then classify again (the run may convert, or, if its bundle is not capable, stay legacy). | 0 / 1 / 7 | as S10, or `Recovered an interrupted conversion of <service>: <rolled back to legacy \| completed>; …` |
| S10b | Legacy instance, bundle **not** supervisor-capable (an older TAG, or a pre-supervisor release). | Plain legacy S8b/S8c, unchanged. | as S8 | as S8 |
| S10c | **Supervisor-managed** instance (valid `instance.json` + launcher) run with a bundle that is not supervisor-capable. | Refuse before any stop: `engine: no_engine`. | 5 | `[ERROR] <service> is supervisor-managed; v<X> has no supervisor and cannot be installed over it.` |
| S1 (changed) | **Nothing installed** with a supervisor-capable bundle. | Greenfield layout (§4.5). | 0 / 1 / 4 | as S1 |

**How S8b / `--reinstall` from old updaters map to conversion.** The old updater's argv
carries no information about conversion, and must not need to. Mapping, in order (first match
wins), evaluated after `lock` and before any mutation:

| Setup invocation (caller) | `--reinstall` | Legacy + capable bundle | Legacy + non-capable bundle |
|---|---|---|---|
| `update_setup_argv` from v0.5.77 (auto/manual/hub update) | no | **S10 convert** (this is the whole of S8b for it) | S8b legacy update |
| `update_setup_argv` from later legacy builds | yes | **S10 convert**; `--reinstall` is ignored for conversion purposes (a conversion always runs the full transaction) | S8b legacy update |
| `install.sh`/`install.ps1` without flags (`--keep-version`) | no | **S10 convert** (contract §7 "converted by setup"); S8a "no change" never applies to a legacy instance | S8a |
| `install.sh`/`install.ps1` with a concrete `--version X` / `--bundle` | no | S8c check first (older X refused), then **S10 convert** | S8b/S8c |
| `ham-bridge setup` from a desktop `.pkg`/app (`--bundle`) | no | **S10 convert** | S8b |
| Already converted instance, any of the above | — | not legacy: contract §7 "After Phase 2" (intent, §12.3) | S10c |

The exit codes are contract §4's. The caller's "was it an update" bookkeeping stays with the
old worker (§11).

## 3. Preconditions

### 3.1 Supervisor-capable bundle

A bundle is capable when all hold; otherwise S10b (nothing is installed from it as a tree):

- it contains `bin/ham-supervisor[.exe]`, `bin/ham-launcher[.exe]`, `bin/ham-bridge`,
  `bin/ham-pty-host`, `bin/ham-ctl` (P2-2 makes the packaging script ship them always;
  today `scripts/release/package-local-binary-tarball.sh` ships them only when given);
- its release publishes a manifest with `min_engine ≥ 1`, `journal_schema: 1`,
  `state_schema: 1`, `state_compat_min: 1`, `min_launcher_abi: 1` (engine §13.4), and the
  manifest verifies (§3.2). A manifest with `min_engine ≥ 1` that lacks any field is
  `manifest_incomplete`, which is a **refusal**, not S10b: a release that claims an engine
  but is malformed must not be silently installed as legacy.

The running setup binary's own digest must equal the verified tree's `bin/ham-bridge`
digest (checked at C5): the setup that converts is the setup that was signed.

### 3.2 Fetching and verifying `release.json` / `.minisig` (the old updater did not)

Setup does this at **C2, before anything is stopped**, so that any failure costs nothing.
It reuses `src/supervisor/fetch` (T12) so there is one verifier (engine §14); it does not
reimplement minisign.

1. **Where from.** First, siblings of the bundle (`<bundle>/../heimdall-release-manifest.json`
   and `.minisig`, supplied by new installers/updaters); otherwise GitHub release asset
   downloads for tag `v<APP_VERSION>` of `tanmayv/heimdall-releases` (REQ-SRC-1; the repo
   constant `src/lib/releaserepo`). The hub never supplies a URL or digest. Size cap 1 MiB each.
2. **Verify** exactly as engine §14 steps 2–4 with the pins compiled into **this** setup binary
   (`key_unpinned`, `signature_invalid`, `manifest_invalid`, `manifest_mismatch`,
   `manifest_incomplete`, `manifest_expired`; schema 1, canonical JSON via strict `.JSON` plus
   canonical re-encode, not the JSON5 default). The manifest's `version` must equal the
   bundle's `contracts.APP_VERSION` and `targets[<this target>]` must name the asset.
3. **Eligibility** (engine §13.2 rules 5–6): `min_engine ≤ ENGINE_VERSION` of the bundle's own
   `ham-supervisor`, `min_launcher_abi ≤ 1`. The version must be ≥ the installed version
   (a legacy instance cannot be converted by downgrade except with `--allow-downgrade`, S8c).
4. **Archive.** The directory the old updater extracted is not reused: the archive named by
   the manifest is downloaded to `<data>/updates/convert-<txn>/` (`.part`, size cap = manifest
   size, SHA-256 must equal the manifest, engine §14 step 6). If `--bundle FILE` was given,
   `FILE` is that archive: it is checked against the manifest the same way.
5. **Failure** at any point: exit 1, nothing changed, message
   `[ERROR] Conversion of <service> refused: <code>; the previous install was not touched.`
   (the code names the failing step). The old updater records the failure and retries with
   its own backoff. **No legacy-style install of a capable bundle is ever done as a fallback**
   (it would produce a half-new instance whose next update converts again).
6. **Offline / rate-limited / GitHub down.** Same as 5; the retry is the old updater's
   (`bridge_auto_update_delay`) or the user's re-run.

Verification of the signature on the OS binaries (`require_os_signature`, Authenticode,
Developer ID) is done once, by `repair` (C5), exactly as for any tree.

## 4. The conversion transaction

It is part of `ham-bridge setup`, using its existing lock, event stream
(`--json-progress`), exit codes and undo order (`bridge_setup_run`, `setup_cmd.odin:514`;
`bridge_setup_undo`, `:875`; `bridge_setup_finish`, `:925`). The existing ten steps
(Lock → Stage → Binaries → Config → Ports → Service → Enroll → Extensions → Start → Verify)
map onto C0–C9 as shown; the conversion replaces the **Stage/Binaries** pair (no `bin/` swap,
no `bin.bak`), and wraps the **Service/Start/Verify** pair. New `--json-progress` step ids
`convert_gate`, `convert_fetch`, `convert_tree`, `convert_commit` are added to
`docs/bridge-setup-progress.md` by P2-4; the other ids keep their meaning (Electron sees the
same ten steps, as contract §3 requires, with `skipped` where a step is not needed).

### 4.1 `conversion.json` (setup's crash journal)

`<data>/conversion.json`, owner-only, written by atomic replace (temp file + rename; Windows
`ReplaceFileW`/`MoveFileExW` as engine §4.2) **before** each step's side effects (`step`,
`state: "begin"`) and after (`state: "done"`):

```json
{"schema":1,"txn":"cv_<16 hex>","mode":"convert|greenfield","service":"heimdall-bridge-…",
 "from_version":"0.5.77","to_version":"0.5.86","to_tree":"0.5.86-<d12>",
 "instance_id":"ins_<32 hex>","op_id":"op_convert_<txn>","backup":".convert-<txn>",
 "was_running":true,"was_connected":true,"started_at":1795400000,
 "step":"C6","state":"begin","done":["C0","C1","C2","C3","C4","C5"],"phase":"forward|rolling_back"}
```

`txn` is also the name of the backup directory `<data>/.convert-<txn>/` (0700). It is deleted
at the end of C9 (§4.4). The file is deleted last.

### 4.2 Steps

| Step | Existing setup step | Action | Writes (on failure undone by §6) |
|---|---|---|---|
| **C0** lock & classify | `Lock` | `.install.lock` as today (S7a if busy). Owner check (Q8, S5b). Gather facts incl. `legacy`, `conversion_record`. Recover an interrupted conversion first (§6.3). Delete layout **garbage** of a crashed rollback: with no `conversion.json` and no valid `instance.json`, any of `launcher/`, `releases/`, `current`, `previous`, `known-good.json`, `supervisor/` is removed (rename-aside on Windows if busy). Record `was_running`, `was_connected` (status read, no probe), runtime pid, ports. | nothing yet |
| **C1** agent gate | (new, before `Stage`) | §9. No service is touched; the old bridge keeps running and admitting launches. | `conversion.json` (`gate`), `<state>/conversion-status.json` |
| **C2** fetch & verify | `Stage` | §3.2. Exit 1 on any failure, **nothing** changed. | `<data>/updates/convert-<txn>/` (deleted at end) |
| **C3** backup | (new) | Copy to `<data>/.convert-<txn>/`: the service definition (`l.service_file`; Windows `run.cmd`, `run.vbs`, `task.xml`), `config.toml`, `hub-url`, `profile`, `ports.json`, `update.json` if present, `bin/ham-ctl-<svc>` wrapper. **Never** credentials (`bridge-token*`, keystore, `identity_key`; engine §11.1). `bin/` is not copied. The schema-bearing **state stores** are snapshotted in C4b, not here (they must be quiescent). Write `conversion.json` (`mode`, `from_version`, `op_id`, …). | backup dir, `conversion.json` |
| **C4** quiesce | `Binaries` (first half) | Stop the old bridge with today's action (`bridge_service_action(.Stop)`, `service_cmds.odin:145`; Windows: the verified-pid stop, never `schtasks /End`, so the task's PTY daemon and this setup survive), then stop the profile's **PTY daemon(s)** (`bridge_setup_stop_idle_pty_host`, `setup_pty_host.odin:39`; with agents still running after the gate (forced) `bridge_update_stop_pty_host`), wait until each recorded pid has exited. A daemon that cannot be stopped fails the step. **C4a (rescuer)** is started first, see §6.4. **C4b (state snapshot)**, once the old bridge and PTY daemon have exited: copy every store of the engine's registry (`state_stores`, engine §11.1: `config.toml`, `ports.json`, the JSON stores under `<data>/bridge/` such as `provider_*.json`, `acp-runtimes/`; same list, same per-store and 256 MiB total limits as `engine.take_snapshot`, `src/supervisor/engine/snapshot.odin:107`, which `repair` skips when there is no `from`, `repair.odin:179`) into `<data>/.convert-<txn>/state/` with a `snapshot.json` (path, size, SHA-256), written last, fsynced. Never credentials. A store over its limit or an unreadable store fails the step (nothing changed yet). Windows: stop the tray as setup does today. **The tray is not otherwise touched in Phase 2** (it keeps running `bin/ham-bridge tray`; moved in Phase 4). | service stopped |
| **C5** instance record, tree, launcher | `Binaries` (second half) | (a) write `instance.json` (engine §3; fresh `instance_id`, or the existing one on resume; `data_root`/`state_root` are the **textual** `layout_for` strings, no realpath, so the launcher's textual equality check (engine §7.1) holds on Fedora Atomic `/home` → `/var/home`); (b) run `<bundle>/bin/ham-supervisor repair --instance-root <data> --state-root <state> --bundle <archive> --manifest <m> --signature <sig> --op-id op_convert_<txn>` (`src/supervisor/service/repair.odin:52`): verifies offline again, unpacks `releases/<ver>-<d12>`, `previous := current if valid else new`, `current := new`, journals op `repair actor installer`; exit 0 required (6 busy / 78 refused / 1 failed → fail the step); (c) compare the running setup exe's SHA-256 with `releases/<T>/bin/ham-bridge` (`bundle_mismatch`); (d) copy `releases/<T>/bin/ham-launcher[.exe]` to `launcher/ham-launcher[.exe]` and write `launcher/launcher.json {"abi":1,"version","sha256"}` (D8: only setup writes the launcher; the engine never replaces it); (e) seed `<state>/update.json` (§11.3). | `instance.json`, `releases/`, `current`/`previous` (or `.json`), `launcher/`, `supervisor/`, `update.json` |
| **C6** service cut-over | `Config` (kept), `Ports` (kept), `Service` | Re-render and register the launcher entry (§10) using `bridge_setup_register` (`setup_cmd.odin:771`) with the new render input: Linux `systemctl --user daemon-reload` + `enable` (unit name unchanged, `KillMode=process` for now, §10.1); macOS plist (label unchanged) re-loaded by `bridge_launchd_reload`; Windows: write the new `run-launcher.cmd`/`.vbs`/`task-launcher.xml`, `schtasks /Create /XML … /F` for the **new** task name, then `schtasks /Change /TN <old> /DISABLE` (§10.3). Ports/config unchanged (the same ports are reused, `ports.json`). Also write `bin/ham-ctl-<svc>` anew pointing into the tree (§8.3). | service def (backed up in C3), new Windows task |
| **C6b** enroll | `Enroll` | As the plan says (S3/S4 repairs); a healthy enrolled legacy instance skips it. Uses `<tree>/bin/ham-bridge enroll`. A failed enrollment on the update path rolls back (exit 1), as before T2. | credential kept (setup_undo `Enroll`) |
| **C6c** extensions | `Extensions` | Today's extension sync, with the source `releases/<T>/share/heimdall/extensions/`. Failures are reported, never fatal (as today). | extension copies (`bridge_extensions_restore`) |
| **C7** start | `Start` | Start the service (Linux `systemctl --user start`, macOS `launchctl bootstrap`/`kickstart`, Windows `schtasks /Run` the **new** task). Record `restart_at`, `stale_pid`. The launcher starts the supervisor of `current`; the supervisor finds `activating/handover` for `op_convert_<txn>` and runs probation (engine §6, J15/J16). | processes |
| **C8** verify = committed | `Verify` | Wait up to **300 s** (`T_commit` 270 s + 30 s) from C7 for: journal op `op_convert_<txn>` terminal `committed` **and** `known-good.json.committed_op == op_id` (engine §3), printing each journal state as `convert_commit` events (`probation 1/…`). Fail fast on a journal `failed`/`rolling_back`, on `launcher-status.json` = `refused`, or on the service not running. Then, if `was_connected`, wait up to 45 s (`BRIDGE_SETUP_VERIFY_TIMEOUT`, `setup_cmd.odin:36`) for `bridge_service_status` = running + connected (+ the re-enroll marker check as today). Not connected before → the hub requirement is waived (journaled by the engine as `probation_offline`). | — |
| **C9** finalize | `finish` (new tail) | `finalize_conversion` (§6.5): idempotent, recorded in `conversion.json` (`step: C9`), runnable **without setup**: Linux rewrite the unit with `KillMode=control-group` + `daemon-reload` (no restart); Windows `schtasks /Delete` the old (disabled) task; tray: nothing (§C4); delete `<data>/updates/convert-<txn>/` and `.convert-<txn>/`; `conversion.json` → removed. Print `Converted <service> …`. | — |

**C6 before C5?** No: the service must not point at a launcher whose tree, `instance.json`
or `launcher/` does not exist; C5 is complete and durable first (every file and the tree are
fsynced by `repair`; `launcher/` and `instance.json` by atomic replace + directory fsync).

**C5(b) from none.** `repair` is the engine's offline installer (engine §16, J29), written for
an instance with a damaged `current`. Conversion uses it with `current`/`previous`/`known-good`
absent. The supervisor of the new tree sees `activating` with no `from`, runs probation,
commits, and writes `known-good.json`. A probation failure cannot "roll back" to a tree that
does not exist: setup's own deadline (C8) and §6 handle it, never the launcher fallback (the
launcher with `P == C` just restarts `C` with backoff, engine §7.2). **P2-4 must add a
conversion test for this case**; if the engine's J18–J24 do not handle `from = none`
cleanly (the journal line `rolling_back` with no `from`), the fix belongs to the engine and is
part of P2-4.

### 4.3 What the old process tree does while this runs

The old worker (`update --auto-worker`) is the parent of setup and waits. The old **bridge**
is stopped at C4. The old worker is a **child process of the old service**: on Linux it sits
in the service's cgroup (`bridge_os_spawn_new_session`, `os_platform_unix.odin:300`, makes a
new session, not a new cgroup); on Windows inside the task's job. See §10.1 and §10.3 for why
the transaction never stops the **new** unit with `KillMode=control-group` and never calls
`schtasks /End` while setup runs.

### 4.4 Commit boundary

The point of no return for the *old* install is the end of C8 (committed + connected). From
then on only C9 remains, which is idempotent. Rollback to legacy is possible until `conversion.json`
is removed (a crash in C9 rolls **forward**, §6.3).

### 4.5 Greenfield (S1 with a capable bundle)

Same steps with `mode: "greenfield"`: no gate (nothing runs), C3 backs up nothing, C4 stops
nothing, C5–C9 as above, Enroll (S1/S1a) between C6 and C7 as today. `bin/` is never created.
S1a (not enrolled in time) keeps the layout installed and **not started**, exactly as S1a does
today; a re-run is S3 on a supervisor-managed instance (contract §7 "After Phase 2"). A failed
S1 rolls back to "nothing installed" (§6, R4 without R2/R5).

## 5. Crash and rollback table (per step, per OS)

"Crash" = setup killed (`SIGKILL`, power loss, OOM) at that point; "fail" = the step reports an
error. The recovery on the **next** setup run is §6.3. Unless noted, the OS columns are
identical. L = Linux (incl. Fedora Atomic), M = macOS, W = Windows.

| Step | State on disk after a crash / fail | Rollback or recovery | OS differences |
|---|---|---|---|
| C0 | Nothing, or garbage layout. | Nothing to undo. Garbage removed at the next C0. | W: a busy `releases\<tree>` is renamed to `releases.stale-<txn>` and left for GC. |
| C1 gate | `conversion.json` not yet written, or `gate` only. Old bridge running. | Next run restarts the gate from `force_at` kept in `conversion-status.json` (the 2 h never reset, §9). | — |
| C2 | Download dir only. Old bridge running. | Delete `updates/convert-<txn>`. | — |
| C3 | Backup dir (partial) + `conversion.json` `begin C3`. Old bridge running. | Delete backup + record. | — |
| C4 | Old bridge **stopped**, maybe PTY daemon stopped. `bin/`, service def untouched. | Roll back: start the old service (R5). | L: unit is `enabled`, so a reboot/login restarts the legacy bridge by itself even without setup. M: LaunchAgent `RunAtLoad`. W: task has a logon trigger. A `SIGKILL`/OOM kill of setup is caught by the **rescuer** (§6.4), which recovers within ~5 s (roll forward if C6 is done, else R1–R6). Setup also handles `SIGTERM`/`SIGINT`/`SIGHUP`/console-close with the §6.2 rollback. Remaining window: setup **and** the rescuer die together (a cgroup/job kill, OOM of both); then the bridge is down until login/boot or the next setup run, and the user is told in §15 item 6. |
| C5(a) `instance.json` | Record present, no tree. Service def is legacy. | R4 removes it. A legacy bridge running with an `instance.json` but no tree is S10a (recovered at once). | — |
| C5(b) `repair` | Tree missing/partial, pointers unwritten or written. Journal has a `repair` op. | R4: stop nothing (service is stopped or legacy); delete `releases/`, pointers, `supervisor/`, `instance.json`. **Never** restart `repair`'s op: the layout is deleted wholesale. | W: if the tree is open (antivirus), retry deletion 60 s (engine §19 sharing retries), then rename aside. L/M: plain `remove_all`. |
| C5(d) launcher | `launcher/` partial. | R4 as above. | W: the file may be scanned/locked: copy with sharing-violation retries 60 s. M: copied signed binary keeps its signature; verify with `codesign --verify --strict` (cheap, fail the step). |
| C5(e) `update.json` | Written. | R4 deletes it **only if it did not exist before** (C3 recorded). | — |
| C6 render | Service def is new (or partial) while the old bridge is stopped. | R2 restores the C3 backup; L `daemon-reload`; M `bootout`+`bootstrap`; W: delete the new task, `schtasks /Change /TN <old> /ENABLE`. **Roll forward instead** if C6 is `done` (§6.3). | W: old task disabled but present means rollback needs no XML restore; a crash after `/Create new` but before `/DISABLE old` leaves **two enabled logon tasks** → the next setup run disables/deletes (§10.3). L: unit file is written by rename; a torn file cannot occur. |
| C6b enroll | Credential possibly new. | Kept (existing `Enroll` undo); legacy bridge uses it (same hub). | — |
| C6c ext | Extension copies. | `bridge_extensions_restore`. | — |
| C7 start | Service started or starting; supervisor may run probation. | **Roll forward** if C6 done and the setup is gone: the supervisor commits on its own, `conversion.json` stays until `finalize_conversion` (§6.5) runs, which does not need setup. If the setup is alive and C8 fails → rollback. | L: with `KillMode=process` a launcher `SIGTERM` is forwarded to the supervisor (engine §7.3). W: `schtasks /End` is never used while rolling back; the stop-request file + event is used first (engine §7.3). |
| C8 | As C7. | Rollback (R1–R6) on timeout, journal `failed`, launcher `refused`, or no connection. Supervisor crash-loop: the launcher restarts `C` with backoff; setup stops it at R1. | W: a supervisor stuck in the job is ended by the stop request, then by terminating the launcher job (`KILL_ON_JOB_CLOSE`). |
| C9 | Committed. `conversion.json` `step: C9`. | Always roll **forward** (every sub-step idempotent). | W: crash between "new task enabled" and "old deleted" → `finalize_conversion` (§6.5) deletes the old at the next bridge start. L: crash before the `control-group` flip → `finalize_conversion` flips it at the next bridge start. |

Failure injection: P2-7 must inject a failure (a returning error and a hard kill) at each row
and assert the §6 outcome on all three OSes.

## 6. Rollback

### 6.1 Principles (REQ-CONV-2)

- `bin/` was never modified (apart from the generated wrapper, restored from the backup), so restoring it is a **verification**, not a copy: after R5
  `bin/ham-bridge --version` must print `from_version` (otherwise exit 7).
- Rollback is a **full undo of everything the transaction created**: legacy instances have no
  `instance.json`, `launcher/`, `releases/`, pointers, `known-good.json`, `supervisor/`,
  `update.json` (unless it pre-existed). So R4 deletes all of them; there is no
  "partial supervisor" state left behind.
- The service definition and settings come back from `<data>/.convert-<txn>/`.
- The old bridge is **restarted** and verified like today (running; connected if it was).

### 6.2 Procedure (R1–R6), also run on `SIGTERM`/`SIGINT`/`SIGHUP`/console close

| Step | Action |
|---|---|
| R1 stop the new service | Write the launcher stop-request file `<data>/supervisor/launcher-stop.request` (engine §7.3) and wait ≤ 25 s; W: set `Local\heimdall-launcher-stop-<instance_id>` first when in the same session. Then the OS stop (L `systemctl --user stop`; M `launchctl bootout`; W `schtasks /End` **only now, as the fallback**). Then `procs.stop` over `procs.json` entries (the supervisor's own recorded `(pid,start_time)`), and wait for them (engine §2.1 layer 3). Failure → exit 7 `rollback incomplete`, nothing deleted. |
| R2 restore the service | Linux: copy back the unit, `daemon-reload`. macOS: copy back the plist; `bootout`/`bootstrap`. Windows: delete the new task; enable the old task; delete the new `run-launcher.*`/`task-launcher.xml`. |
| R3 restore settings and state | `config.toml`, `hub-url`, `profile`, `ports.json`, `bin/ham-ctl-<svc>` from the backup; delete a `update.json` that did not exist; **every store of the C4b snapshot** is restored (per file: copy to `<path>.restore-<txn>`, fsync, atomic replace, as engine §11.3), whether or not the new runtime ran, because probation may have migrated or rewritten them. Credentials were never copied and are **not** restored (they may have rotated; see §6.6). |
| R4 remove the created layout | Order: `instance.json` first (any stray supervisor then refuses with `ownership_mismatch`), then `current`/`previous`, `known-good.json`, `launcher/`, `releases/`, `supervisor/` **after** copying `supervisor/journal/` and `launcher-status.json` to `<data>/conversion-failed-<txn>/` (one kept, the older deleted; no credentials in them). W: sharing retries 60 s, then rename aside. |
| R5 restart the old bridge | `bridge_service_action(.Start)` (existing `bridge_setup_finish` behaviour, `setup_cmd.odin:925`); verify running and, if `was_connected`, connected (45 s); verify `bin/ham-bridge --version`. |
| R6 close | Remove the backup dir and `conversion.json`. Exit **1**, final line `ham-bridge setup FAILED at step "<step>"; the previous install was restored.` (exit 7 `rollback incomplete: <reason>` if R1, R5 or the `--version` check failed; the backup dir and `conversion.json` are then **kept** so a later run can finish). |

### 6.3 Recovery on the next run (S10a)

Under `.install.lock`, before classification:

1. `conversion.json` with `phase: rolling_back` → continue R1–R6.
2. `done` contains `C6` and the tree/launcher/`instance.json` verify (the same cheap checks
   as C5(c)) → **roll forward**: continue at C7 (start + verify, C8) and C9. A launcher/supervisor
   that is already running and already committed just passes C8.
3. Otherwise → roll back (R1–R6). Then classification continues: the same run converts again
   when it carries a capable bundle.
4. `conversion.json` unreadable → treat as case 3 using filesystem facts (backup dir present,
   service def comparison); if the legacy service definition cannot be re-derived, exit 7.

### 6.4 The rescuer (C4a): setup killed after the old bridge was stopped

Neither the service manager nor the old worker restarts a bridge that was stopped on purpose
(`Restart=on-failure`, `KeepAlive.SuccessfulExit=false`, the task restart policy do not apply;
the worker only records the failure, `update_cmd.odin:117-123`). So before C4 stops anything,
setup starts a **rescuer**:

- A copy of the running `ham-bridge` at `<data>/.convert-<txn>/rescue/ham-bridge[.exe]`, run as
  `ham-bridge convert-rescue --txn <txn> --setup-pid <pid> --setup-start <start_time>`,
  detached in a **new session** (`bridge_os_spawn_new_session`) like the old worker, so it is
  not a child of setup. Linux: the old unit is `KillMode=process`; the rescuer is in its cgroup
  but survives its stop (as the worker and PTY daemon do today). macOS: `AbandonProcessGroup`
  true on the old plist. Windows: spawned with `CREATE_BREAKAWAY_FROM_JOB` where allowed (a
  **HYPOTHESIS** for P2-7, same as §10.3).
- Every 2 s it checks the identity `(pid, start_time)` of setup. While setup lives it does
  nothing. When setup is gone and `conversion.json` still exists, it runs the §6.3 recovery
  under `.install.lock` (free, it is an OS lock): roll forward if C6 is done, else R1–R6.
- It exits when `conversion.json` is gone, or after the recovery. Setup terminates it at the end
  of C9. A rescuer found by C0 of a later run (stale, `conversion.json` gone) exits on its own.
- This shrinks the SIGKILL window from "until login/boot" to about 5 s. The remaining risk,
  setup and rescuer killed together (a cgroup/job kill, OOM taking both, power loss — which on
  reboot starts whichever definition is on disk), is listed in §15.

### 6.5 `finalize_conversion`: C9 without setup

After a commit nothing runs setup again (legacy timer off, supervisor updates never call
setup). C9's effects therefore live in an idempotent function `finalize_conversion(layout)`
that is called:

1. by setup at the end of a successful C8 (the normal path);
2. by the **new `ham-bridge` runtime at start** when `supervisor_managed` and
   `conversion.json` exists with `step` ≥ C8 or `done` containing `C8` (setup died after the
   commit, or the rescuer rolled forward);
3. by `ham-bridge status` for the same condition (so the user's look at status completes it);
4. by any later setup run (S10a).

It takes `.install.lock` non-blocking and does nothing if a live setup holds it. Effects, each
idempotent: Linux — rewrite the unit with `KillMode=control-group` and `daemon-reload` (no
restart); Windows — delete the old (disabled) task; both — delete `updates/convert-<txn>/` and
`.convert-<txn>/`, stop the rescuer, remove `conversion.json`. Owned by **P2-5**
(setup calls it from P2-4). P2-7 case: kill setup after C8, start the bridge, assert all C9
effects without running setup.

### 6.6 State and credential compatibility (the two-release rule)

Rollback after the new runtime ran is only correct if the legacy bridge can read what is on disk.
Stores are restored from the C4b snapshot (R3). **Credentials are not** (engine §11.1: they
rotate during probation; restoring an old refresh token breaks enrollment), so the first
supervisor release must **not change any credential format**: what it reads and writes in
`bridge-token*`, the keystore items, `identity_key`, `epoch_floor` must stay readable by
v0.5.77+ (the two-release rule: a credential format change ships at least one release after the
conversion release). P2-4 adds a unit check that the conversion release's credential files
round-trip through the v0.5.77 reader; P2-7 has the state round-trip test above.

## 7. Per-OS differences (one table)

| Topic | Linux (incl. Fedora Atomic) | macOS | Windows |
|---|---|---|---|
| Service identity after conversion | Same unit name `<svc>.service`; `ExecStart` = `launcher/ham-launcher --instance-root <data> --state-root <state>` | Same label and `~/Library/LaunchAgents/<label>.plist`; `ProgramArguments` = launcher | **New** task `\<svc>-<h12>` (§10.3); files `run-launcher.cmd`/`.vbs`, `task-launcher.xml`; old task disabled, deleted at C9 |
| Cut-over | `daemon-reload` (+`enable`) | `bootout` + `bootstrap` (`bridge_launchd_reload`, `service_cmds.odin:184`) | `schtasks /Create /XML /F` then `/Change /DISABLE` old |
| Kill semantics | `KillMode=process` during, `control-group` after (§10.1) | `AbandonProcessGroup=false`, `ExitTimeOut=40` (§10.2) | Launcher job `KILL_ON_JOB_CLOSE`; graceful stop by event/request file, `/End` fallback only |
| Old bridge stop (C4) | `systemctl --user stop` (old unit, `KillMode=process`: the worker and PTY daemon survive) | `launchctl bootout` (old plist has `AbandonProcessGroup=true`) | verified-pid stop only (`service_cmds.odin:150-160`) |
| Old PTY daemon | Stopped explicitly (C4); would survive as an orphan under `KillMode=process` | same | same; also keeps `bin/ham-pty-host.exe` busy if left, so it **must** be stopped |
| Tree/pointers | symlinks (`rename(2)`) | same (APFS) | record files + `ReplaceFileW` |
| Path equality | `/home` → `/var/home`: use `layout_for` strings verbatim (C5(a)) | `/var` → `/private/var`: same | junctions: same |
| Launcher binary copy | plain copy, `0755` | plain copy + `codesign --verify --strict` | plain copy with sharing retries; Authenticode only if `require_os_signature` |
| New-service visibility | none | same label/plist: no new "Background item" entry | new task name: appears as a new task (documented in the release notes) |
| Interrupt-safe stop | SIGTERM | SIGTERM | named event / stop-request file |
| Verified in P2-7 | Fedora Atomic runner or the dawnstar/riverwood Linux boxes | macos-15 and macos-15-intel | windows-latest (Defender on) |

## 8. Environment

### 8.1 What changes

Today `service_env` (`src/lib/bridgesvc/render.odin:40-58`) bakes `bin/` into
`PATH`, `HEIMDALL_HAM_PTY_HOST_BIN` and `HEIMDALL_HAM_CTL_BIN`. The supervisor passes the
environment through unchanged (`src/supervisor/service/host_posix.odin:121`,
`posix.execve(..., posix.environ)`), and the service definition is written **once** (engine
§17), so a `bin/` path in it would point into the legacy dir forever (or, when Phase 4 deletes
it, nowhere).

| Variable | Legacy service def | Converted service def | Set by the supervisor for the runtime child of tree `T` |
|---|---|---|---|
| `PATH` | `<bin><sep><captured path>` | `<captured path>` with any `<data>/bin` segment removed | `<data>/releases/T/bin<sep><inherited PATH>` |
| `HEIMDALL_HAM_PTY_HOST_BIN` | `<bin>/ham-pty-host` | **absent** | `<data>/releases/T/bin/ham-pty-host[.exe]` |
| `HEIMDALL_HAM_CTL_BIN` | `<bin>/ham-ctl` | **absent** | `<data>/releases/T/bin/ham-ctl[.exe]` |
| `HEIMDALL_BRIDGE_PTY_HOST` | `true` | `true` | (inherited) |
| `HEIMDALL_BRIDGE_ENDPOINT` | `tcp:127.0.0.1:<endpoint_port>` | same | (inherited) |
| `HEIMDALL_BRIDGE_SERVICE_NAME` | `<svc>[.service]` | same | (inherited) |

`<sep>` is `:` on POSIX and `;` on Windows. The supervisor **overwrites** the three variables
even if the inherited environment already has them (a service definition from an older
conversion, a user shell). The resolved `releases/T` path is used, not `current/`: the
runtime, the PTY host and every agent started by them exit at the next activation (engine
§12), so a path that follows `current` would only create a mixed-tree window.

### 8.2 Where implemented

P2-3 owns both halves (they are one contract): `service_env`/`render_service_file`
(`render.odin`) and the supervisor's `default_specs`/`host_start`
(`src/supervisor/service/host.odin:118`, `host_posix.odin`, `host_windows.odin`): a
`Child_Spec.env` list applied at spawn on all three OSes. `default_specs` also keeps the
runtime argv already derived from `instance.json` and `ports.json`; its
`--bridge-token-file <state>/bridge-token` must equal `service_args`'s `TOKEN_FILE`
(`bridgesvc.odin:35`): P2-3 adds a test asserting the two argv lists are identical for the
same profile.

### 8.3 The `ham-ctl-<svc>` wrapper

`bin/ham-ctl-<svc>` (`render_ctl_wrapper`, `render.odin:184-200`) execs `<bin>/ham-ctl`. After
C6 it execs `<data>/releases/T/bin/ham-ctl` (resolved at write time). The supervisor rewrites
it, only when the content differs, at every start of a supervisor on a tree (READY path), so
it follows the active tree on every OS (a symlinked `current/` path would not work on
Windows). The wrapper stays in `bin/` (still on users' PATH) until Phase 4. Owned by P2-5.

## 9. Agent gate during conversion (Q3, U2)

### 9.1 When it applies

The gate applies to **timer-started** conversions, exactly as engine §12 applies the 2 h wait
only to `actor: timer`. Setup tells the two apart by a **direct signal**: its **parent
process** is the legacy worker, i.e. the parent's command line (`bridge_os_process_lstart_and_command`,
`service_cmds.odin`, the helper `bridge_service_runtime_pid` already uses) is a `ham-bridge`
from this profile's `bin/` with `update … --auto-worker --service <this service>`
(`auto_update.odin:349,436`):

| Parent | Meaning | Gate |
|---|---|---|
| the legacy `--auto-worker` of this service | timer-started | wait ≤ 2 h (§9.2) |
| anything else (installer script, desktop app, `ham-bridge update`/hub update without `--auto-worker`, a shell) | user-started | **interrupt at once**: stop agents, convert (engine §12 "user" row) |
| unknown (parent gone, platform cannot read it) | treated as user-started | interrupt at once |

The auto-update lock is **not** used as the discriminator: it is user-wide, so a user-started
setup of profile B would otherwise wait while profile A's worker holds it.
`--convert-gate wait|now` forces either mode (tests and scripted callers). The old bridge's own
logic runs **before** it spawns the worker: it waits for a quiet window up to
`auto_update_max_defer_hours` (24 h default), then notifies the hub, waits two minutes, stops
the PTY host and its agents and only then spawns the worker (`auto_update.odin:377-455`). So a
timer conversion normally meets an idle bridge and the gate returns at once; the gate matters
for agents started between that stop and C4, for installer-triggered runs that choose `wait`,
and as the safety net the user asked for.

### 9.2 Behaviour

1. **Count**: agents hosted by the profile's PTY daemon(s) (`pty_host_stale_agent_count`,
   `bridge_profile_pty_sockets`; the same source as `bridge_setup_stop_idle_pty_host`). A
   daemon that does not answer counts as **busy** (fail closed, engine §12.1).
2. **Wait** while busy, up to `force_at = first_check + 2 h` (wall clock). `force_at` is stored
   in `conversion.json`/`<state>/conversion-status.json` at the first check, so a setup crash
   or re-run **never resets** the 2 h. The old bridge keeps running and admitting launches
   during the wait (as the engine keeps admission open); agents started during the wait are
   stopped at `force_at`.
3. **Countdown**: every minute and on every count change, one progress event
   `{"step":"convert_gate","state":"waiting","message":"Converting to the supervisor in 1 h 12 min; 3 agents will be stopped","force_at":<unix>,"remaining_s":n,"agents":n}`
   and the same fields in `<state>/conversion-status.json` (owner-only). `ham-bridge status`
   prints the line (P2-5). Old binaries cannot show it (U1): only the new setup's stdout, the
   new `status`, and the new bridge's log do. The old worker's stdio is `/dev/null`, so the
   countdown is visible through `status`/the status file/the log (`bridge.err.log` line from
   setup), never in the old UI.
4. **Idle**: count 0 → proceed to C2 at once (the order is gate, then fetch, so a slow download
   does not hold agents).
5. **Interrupt ("Update now")**: `ham-bridge setup --convert-now [--hub …]` (new flag) writes
   `<state>/convert-now.request` (`{"requested_at":<unix>}`, atomic, owner-only) and, when the
   instance lock is held by a live setup in the gate, exits 0 with `asked the running
   conversion to proceed now`. The gate polls every second, honours a request newer than
   its own start and deletes it. Cancel: `SIGTERM`/`SIGINT` of the setup (nothing was changed;
   the old updater backs off).
6. **Force**: at `force_at` re-count, then C2…; C4 stops the PTY daemon with its agents
   (`bridge_update_stop_pty_host`). Setup cannot ask the old runtime to tell the hub first
   (the old bridge is the one being stopped); the new bridge's start-up reconcile reports the
   sessions as interrupted by an update (engine §12: agents are relaunched afterwards by the
   existing hub wake/reconcile).
7. **Residual**: in-flight launches in the old bridge cannot be counted (its counters are
   in-process, `bridge_runtime_launches`, `hub_runtime_client.odin:195`); C4 ends them. The
   window is the seconds between the last count and the stop.

### 9.3 Cost of waiting

While waiting, setup holds `.install.lock` (another setup/update of this profile gets S7a/exit
6) and the old worker holds the user-wide lock (§11.1), so **other profiles' timer updates fail with
"another automatic update holds the lock"** and retry on backoff. Accepted: at most 2 h, then
they convert one after the other.

## 10. Service definitions

### 10.1 Linux: `KillMode` (engine §7.3)

`render.odin:117` today: `KillMode=process`. The converted unit is:

```
[Service]
Type=simple
ExecStart="<data>/launcher/ham-launcher" "--instance-root" "<data>" "--state-root" "<state>"
Environment=…            # §8.1 converted column
Restart=on-failure
RestartSec=5
KillMode=control-group
```

Why it is flipped late (C8): the legacy worker (setup's parent) and setup itself are processes
**in the unit's cgroup**. A `systemctl stop` or `restart` of the unit under
`KillMode=control-group` kills them, i.e. the transaction would kill itself, including its
own rollback. Therefore:

- C6 writes the same unit with `KillMode=process` (a `converting` render option; P2-3).
- The new unit is only ever **started** (never stopped by `systemctl`) while setup runs,
  except by R1, where `KillMode=process` still lets the launcher forward `SIGTERM` to the
  supervisor group (engine §7.3) and the supervisor's own lifeline/`PDEATHSIG` layers
  (engine §2.1) end the children.
- C9 rewrites the unit with the canonical `KillMode=control-group` and runs `daemon-reload`
  **without restarting**; it takes effect at the next stop, when no setup is running.
- If setup dies between commit and C9, the unit keeps `KillMode=process` until the next setup
  run: `render_service_file` differs from disk (S6 detection, `bridge_setup_service_unchanged`,
  `setup_cmd.odin:756`) and re-renders it.
- `systemd-run --scope` escape was **rejected**: it needs a user bus and still leaves the
  worker (parent) in the cgroup.

### 10.2 macOS

Same label and path. The converted plist differs from today's (`render.odin:127-139`): the
launcher is `ProgramArguments`, `AbandonProcessGroup` is **false** (launchd then also kills
leftover members of the launcher's process group at stop; the supervisor and runtime are in
their own groups and are ended by the launcher and the lifeline), and `ExitTimeOut` is **40**
(launchd's default 20 s equals the launcher's 20 s wait for the supervisor, engine §7.3, and
would race it). `KeepAlive.SuccessfulExit=false` and `ThrottleInterval=5` are kept. The old
plist has `AbandonProcessGroup=true`, so `launchctl bootout` of the old job in C4 leaves the
worker, setup and PTY daemon running, as the existing update flow relies on.

### 10.3 Windows: task rename and stop event

**Naming [P2-1].** New task path `\<service_name>-<h12>`, `h12` = first 12 lowercase hex of
`SHA-256("heimdall-task-v1" 0x00 <SID string> 0x00 <instance_id>)`. The old name is
`\<service_name>` (`service_argv`, `bridgesvc.odin:256-262`, builds it). The hash makes the name unique per OS
user and per instance (engine §17, report R1) and unguessable from the service name alone;
`<instance_id>` is stable across re-enrollment.

**Definition.** The task keeps today's shape (`render.odin:141-160`): logon trigger, the
current user's SID, `InteractiveToken`, `RestartOnFailure` PT1M ×999, no execution time limit,
hidden `wscript.exe //B //NoLogo run-launcher.vbs` → `cmd /d /s /c run-launcher.cmd` →
`launcher\ham-launcher.exe --instance-root <data> --state-root <state>`, with the §8.1 env set
in `run-launcher.cmd` and the two log redirections of `render_windows_run_cmd` kept. The new
file names leave the old `run.cmd`/`run.vbs`/`task.xml` in place so that a rollback can re-enable
the old task with no file restore.

**Sequence.** C6: write the new files; `schtasks /Create /TN \<new> /XML task-launcher.xml /F`;
then `schtasks /Change /TN \<old> /DISABLE` (never `/End`). C7: `schtasks /Run /TN \<new>`.
C9: `schtasks /Delete /TN \<old> /F`. A crash between `/Create new` and `/DISABLE old` leaves two
enabled logon tasks (two bridges on the next logon): setup's C0 recovery (§6.3) and
`ham-bridge setup` S6 always run "disable/delete the old name when `instance.json` exists".

**Stop.** After conversion, "stop" is the launcher's graceful path (engine §7.3): set the
named event `Local\heimdall-launcher-stop-<instance_id>` (same session) or write the
stop-request file (any session, including setup over SSH) and wait ≤ 25 s for the launcher to
exit; `schtasks /End` is the fallback only. P2-5 implements this in `bridge_service_action`
(`service_cmds.odin:145`): for a supervisor-managed Windows instance `.Stop`/`.Restart` use the
event/request first; the legacy "kill only the verified Bridge pid" path is for legacy
instances.

**Old worker survival.** Setup (child of the old worker, in the old task's job) must survive
the C4 stop of the old bridge; today it does because only the verified bridge pid is ended
(`service_cmds.odin:150-160`) and the PTY daemon is left alone. Conversion keeps that rule
and additionally never ends the old task. Whether Task Scheduler's job kills the worker when
the old task's instance ends (the wscript/cmd wrappers exit with the bridge) is the same
condition today's update relies on. **HYPOTHESIS to verify in P2-7**: the worker and setup
survive the old bridge's death and the C9 `schtasks /Delete` of the old task.

## 11. Old lock and state written by the legacy worker

### 11.1 `~/.heimdall-auto-update.lock`

An **OS lock** held by the old worker process (`bridge_instance_lock`, `lockf`/`LockFileEx`,
`instance_lock_unix.odin:19`), shared by all of the user's profiles. Setup:

- **never opens, deletes or breaks it** (it belongs to other profiles' updaters too);
- does not even probe it (the gate discriminator is the parent process, §9.1);
- the kernel frees it when the worker exits. If the worker dies mid-conversion (it is killed
  with the old job on Windows, or by a power loss; on Linux the unit is `KillMode=process`
  during the transaction, §10.1, so R1 does not kill it), no stale lock remains. There is nothing to clean up and no "stale lock" mode.

### 11.2 `<state>/auto-update.json`

After setup returns, the old worker's deferred step writes it: `pending_version` cleared,
`last_result = "update to vX succeeded"`, `failures = 0`, `next_check_ms = now + delay`
(`bridge_auto_update_finish_at`, `auto_update.odin:542`). After a successful conversion this
file is **dead data**: nothing reads it (§12.2). Setup therefore:

- does not write or delete it (the worker would recreate it); it is excluded from the C3 backup
  and from R3 (a failed conversion's file is the worker's `update … failed` record, exactly what
  the legacy updater wants for its backoff);
- Phase 4 deletes it.

### 11.3 Settings carried over

The user's legacy auto-update preference becomes the supervisor's: C5(e) writes
`<state>/update.json` (`Settings`, `src/supervisor/service/settings.odin`) with
`channel: "stable"`, `auto_update` = the legacy `[bridge] auto_update_enabled` of `config.toml`
(default true), `revision: 1`, `actor: "conversion"`, `last_op: "op_convert_<txn>"`. A legacy opt-out
(`auto_update_enabled = false`) is thus kept. `auto_update_max_defer_hours` has no supervisor
equivalent (the supervisor's wait is the fixed 2 h of engine §12) and is dropped.

## 12. After conversion (REQ-CONV-5)

### 12.1 Status and stop

- **Runtime pid** (`bridge_service_runtime_pid`, `service_cmds.odin:98-110`) compares the
  process image with `bin/ham-bridge`. For a supervisor-managed instance the expected image is
  the active tree's `releases/<T>/bin/ham-bridge[.exe]`, where `T` is `current` (readlink on
  POSIX, `current.json` on Windows) **and** the tree equals the supervisor's own launch tree
  (a mid-activation window may legitimately show the previous tree: the check accepts `current`
  or `previous`). A helper `bridgesvc.active_tree_bin(layout)` is added; the comparison stays
  path-normalised (`path_key`).
- **`status`** reads `runtime-status.json` as today, and appends the supervisor facts from
  `<state>/supervisor-status.json` and the journal head (engine §3): `running v<ver> tree
  <T>`, update state, `force_at` countdown.
- **`stop` / `restart`**: Linux/macOS through the service manager (`control-group`/launcher
  forwards `SIGTERM`); Windows through the event/request file first (§10.3). `start` as today.
- **`ham-bridge setup`** on a converted instance never writes `releases/`, `current` or
  `previous` and never stops the service to swap files (contract §7). S3/S4/S6 still work.
- **`uninstall`** removes, for a converted instance: the service (Windows: the new task name),
  `launcher/`, `releases/`, `instance.json`, `supervisor/` with the rest of the data dir
  (`--purge`), and a leftover legacy `bin/`. P2-5 extends `bridgesvc.uninstall` (needed so that
  `ham-bridge uninstall` and hub-triggered uninstall keep working).

### 12.2 Exactly one updater (the legacy one is disabled on purpose)

Until now the legacy updater would stop "by accident" after conversion, because the running
exe is no longer in `bin/` (`bridge_exe_in_bin_dir`, `hub_runtime_client.odin:1768`, used by
`bridge_update_via_ham_bridge`, `:1781`). That check also breaks hub updates. P2-5 makes it
explicit with a single predicate, `bridgesvc.supervisor_managed(layout)` = valid
`instance.json` (schema 1, owner, roots match, engine §7.1) **and** `launcher/ham-launcher`
present:

| Legacy path | Behaviour when `supervisor_managed` |
|---|---|
| Auto-update timer (`bridge_auto_update_*`, started from the runtime's setup) | **Not started.** Logged once: `legacy auto-update is off: the supervisor manages updates`. |
| `ham-bridge update --auto-worker` | Exits 0 immediately (`managed by the supervisor`), writes nothing, takes no lock. |
| `ham-bridge update [--version X] [--bundle …]` (CLI) | Becomes an intent (§12.3) and waits like contract §7; `--bundle` is refused (`the supervisor installs from GitHub only; use ham-bridge setup --bundle`). |
| Hub-started update (`bridge_update_via_ham_bridge`) | §12.3. |
| Config `auto_update_enabled` | Ignored; the supervisor's `update.json` is the setting. |

The old binaries in `bin/` are dormant (nothing starts them); a hub update never reaches
them. Phase 4 deletes the code and `bin/`.

### 12.3 Hub update → `install_version` intent (U3)

The hub's update command (today `bridge_update_via_ham_bridge(target_version, allow_downgrade)`
→ detached `ham-bridge update --bundle`) on a `supervisor_managed` instance:

1. validates `target_version` is a tag (`v` + SemVer) — the hub never supplies a URL (REQ-SRC-1);
2. writes `intents/inbox/<op_id>.json` (engine §10): `{"is":1,"op_id":"op_<ULID>","instance_id":
   <instance.json>,"action":"install_version","version":"<tag>","expires_at":now+3600,
   "created_at":now,"actor":"hub:<user_id>"}`; an update without a version is `update_now`.
   `allow_downgrade=true` is simply `install_version` (explicit; engine §13.2 rule 3 and §11.3
   decide);
3. acknowledges the hub command as `accepted` with the `op_id`, as the uninstall path does
   (`hub_runtime_client.odin:1827`); the outcome follows the journal (the supervisor's status
   channel), not a synchronous reply;
4. is idempotent on the hub's `command_id` (the `op_id` is derived from it, engine §10:
   re-sending is a no-op).

`install_version` is user-started: it interrupts at once (engine §12), so the hub's "update
now" semantic is preserved and a timer-style 2 h wait never applies to it.

## 13. Test obligations (for P2-7; reviewer checklist)

On Linux (incl. Fedora Atomic), macOS, Windows:

1. **Auto-convert e2e**: a **real v0.5.77 bridge** (and the newest legacy release at the time)
   auto-updates to a branch build of the first supervisor release (served from a fake release
   repo): old worker → new setup → converted, `committed`, connected, `status`/`stop`/`start`
   work, no legacy timer, hub-started update → intent.
2. **Failure injection** at every row of §5 (a returned error **and** a hard kill of setup),
   asserting §6: the old bridge restarted, `bin/` identical **except** the generated
   `ham-ctl-<svc>` wrapper (restored from the backup, compare to the backup), service def
   identical (hash), state stores identical to the C4b snapshot, no `instance.json`/`releases/`,
   `ham-bridge --version` = old. Includes **`SIGKILL` of setup at C4** (expected: the rescuer
   restarts the legacy bridge within ~5 s, or rolls forward if C6 was done), and **kill setup
   after C8**: start the bridge and assert the C9 effects (`finalize_conversion`, §6.5).
   Includes **state round trip**: convert, let probation write/migrate state, force rollback,
   assert the legacy bridge starts and connects on the restored stores.
3. Failures of the supervisor itself: READY timeout, crash in probation, never connects with
   `was_connected`, `from = none` rollback (§4.2), launcher `refused`.
4. Agents: running agents during a timer conversion wait (fake clock), countdown fields,
   `--convert-now`, force at 2 h, `force_at` survives a setup crash.
5. Manifest: unsigned, wrong key, expired, `manifest_incomplete`, offline, wrong archive
   digest, setup digest ≠ tree digest.
6. Two profiles, one converted, one legacy, independent; another OS user's bridge untouched.
7. Windows: old task disabled/deleted; crash between `/Create` and `/DISABLE`; worker survives
   the old bridge's death (§10.3 hypothesis); real logon/logoff is **not** simulated.
8. Linux: `KillMode` flip at C9 and the "setup dies before C9" self-heal.

## 14. Requirement and ticket map

| Requirement | Section | Tickets |
|---|---|---|
| REQ-CONV-1 setup transaction verified by journal `committed` | §3, §4, §5 | P2-2 (artifacts), P2-3 (render), **P2-4** (transaction), P2-7 (tests) |
| REQ-CONV-2 any failure restores service def, `bin/`, settings; restarts old bridge; `bin/` kept | §0 C5, §6, §5 | **P2-4**, P2-7 |
| REQ-CONV-3 trigger = v0.5.77+ auto-update to the first supervisor release, nothing changes in old binaries | §1, §2, §9.1, §11 | **P2-6** (compat contract), P2-4 (classification), P2-7 |
| REQ-CONV-4 kill switch | dropped (U4) | — |
| REQ-CONV-5 status/stop/hub updates work, exactly one updater | §11, §12 | **P2-5**, P2-7 |
| Q3 agent gate | §9 | P2-4 |
| REQ-OS-1 | §7 | every ticket |
| Q8 own OS user only | §1 | P2-4 |
| REQ-ISO-1 / REQ-SRC-1 | §1, §3.2, §12.3 | P2-4, P2-5 |

### What each ticket implements

- **P2-2 Package `ham-supervisor` + `ham-launcher` in bundles; manifest engine fields.**
  Every bundle ships `bin/ham-supervisor`, `bin/ham-launcher` (`package-local-binary-tarball.sh`
  already does when given; make them mandatory for supervisor-capable releases);
  the release workflow signs and publishes `heimdall-release-manifest.json` + `.minisig` with
  `min_engine: 1`, `journal_schema: 1`, `state_schema: 1`, `state_compat_min: 1`,
  `min_launcher_abi: 1`; the key pins are compiled into `ham-bridge` setup (not only into
  `ham-supervisor`) so §3.2 can verify; the asset names/layout the old updater expects (§1)
  stay unchanged with a test. `BRIDGE_SETUP_BINARIES` (`setup_cmd.odin:35`) is not extended:
  trees come from the archive, not from `bin/` staging.
- **P2-3 Service render for the launcher entry.** `render_service_file` for a converted
  instance (launcher `ExecStart`/`ProgramArguments`, `KillMode=control-group` and the
  `converting` variant `KillMode=process`, plist `AbandonProcessGroup=false` + `ExitTimeOut=40`,
  Windows new task name, `run-launcher.*`/`task-launcher.xml`, the §8.1 env split);
  `bridgesvc.task_name(instance)`; supervisor-side per-tree env injection (§8.2) and the argv
  equality test; Windows stop event/request-file helper in `bridgesvc` (used by P2-4 R1 and
  P2-5). Unit tests for every backend render.
- **P2-4 Conversion transaction in `ham-bridge setup`.** S10/S10a/S10b/S10c, greenfield S1,
  C0–C9, `conversion.json`, backup, R1–R6, recovery §6.3, signal handling, gate §9 incl.
  `--convert-now` and `--convert-gate`, §3.2 fetch/verify through `src/supervisor/fetch`,
  `update.json` seeding §11.3, exit codes, progress events + `docs/bridge-setup-progress.md`,
  unit tests of classification and of each failure point with fake host seams.
- **P2-5 Post-conversion runtime.** `supervisor_managed`, `active_tree_bin`, status/stop/
  restart/uninstall for the converted layout (§12.1), legacy updater off (§12.2), hub update →
  intent (§12.3), wrapper rewrite (§8.3), ham-bridge extension sync from its own tree at
  start when supervisor-managed.
- **P2-6 Auto-convert trigger from the old updater path.** No change to old binaries: a
  compatibility contract test that drives the **real** v0.5.77 (and latest legacy)
  `ham-bridge update --auto-worker` against a fake release repo serving the new bundle and
  asserts that the argv, the lock, the stdio, the missing `--reinstall`, the wait-forever
  `bridge_setup_exec_inherit` and the S8b classification lead to conversion; the new-release
  invariants of §1 (asset names, `bin/ham-bridge`, `--version` output, newer-than check);
  the §11 lock/state expectations (the old worker's late `auto-update.json` write is harmless).
- **P2-7 Cross-OS conversion CI** (§13), also a throwaway-branch run on all three runners.
- **P2-8** is the release and staged rollout (Mundus, then brolabs); out of this spec's scope,
  but U4 says: validate on Mundus (dawnstar/riverwood) with a pre-release or branch binaries
  **before** a stable release, because there is no kill switch.

## 15. Open items and hypotheses (not blockers for P2-2 … P2-4)

1. **Windows worker survival** (§10.3) and **session-end delivery** (engine §7.3): verify in P2-7.
2. **Tray** keeps running from the legacy `bin/` in Phase 2 (§4.2, C4); on Windows that keeps
   `bin/ham-bridge.exe` busy, which blocks Phase 4's deletion only. Moving the tray to a
   tree path (and its relaunch-on-update behaviour) is Phase 4.
3. **`from = none` in the engine** (§4.2): the journal behaviour of a probation failure with
   no `from` tree is asserted by P2-4's test; an engine change, if needed, is in P2-4.
4. **Disk**: the first conversion needs the archive (≈ bundle size) in `updates/`, the tree
   under `releases/`, and the legacy `bin/` stays: roughly 3× the bundle. C2 checks free space
   (archive + 512 MiB extraction cap) and refuses with `disk_full` before stopping anything.
6. **Setup and rescuer killed together** (§6.4): the bridge stays down until login/boot or a manual setup run; accepted by design (no further mitigation is possible without a resident watchdog, which Phase 2 does not add). The reviewer/user should confirm.
5. **Hub-offline conversions**: a legacy bridge that was not connected converts without a
   connection check (§4.2, C8); the hub reconnect is then the supervisor's normal behaviour.
