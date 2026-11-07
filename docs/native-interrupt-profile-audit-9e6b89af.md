# Native interrupt profile / session trust audit — `9e6b89af`

Independent interim audit for M3b `task_18e5ac3dc3e13d1e` (audit task
`task_18e5b73835a29c2e`, 2026-11-07). **Not an acceptance.** Scope is the exact
commit `9e6b89af35783b76ff908406972db54ecdd3964b`, inspected in a detached
worktree. The engineer's uncommitted work was not read or moved.

Files audited (from `git show --stat 9e6b89af`): `tools/pty_host/src/native_notification.rs`,
`daemon.rs`, `delivery.rs`, `dproto.rs`, `host.rs`; `src/bridge/executor_child.odin`,
`pty_notification.odin`, `pty_host_runtime.odin`, `pty_host_client.odin`,
`extension_ingest.odin`, `wrapper_endpoint.odin`; `src/ctl/extension/codex.odin`,
`event_json.odin` (SessionStart → `transcript_path`); `tests/observe_provider_notification.py`.

## What kind of evidence this is

| Evidence | What it proves | What it does not prove |
|---|---|---|
| Rust unit tests (`native_notification`, `delivery`, `dproto`) | The parser, ACK predicate and wire framing work on synthetic files | Real Codex behaviour, SessionStart timing |
| Engineer probe `sh_22f528f0…` (not rerun here) | The real daemon + real Codex 0.162.0 ACK/paste/replay works **once the session is bound** | The probe binds by sending `0x42` straight to the daemon socket (`tests/observe_provider_notification.py:243-249`), after the transcript already exists. It skips production SessionStart completely |
| Mounted Odin test | Remote bootstrap auth reaches the bind IPC, and a wrong token is rejected | Only covers the negative path (invalid path → `notification_profile_unsupported`) |
| **Not shown by anyone** | A production local or remote SessionStart that binds a real Codex session; the owner producer → encrypted executor → native child → signed owner result path | |

## Findings

| # | Severity | Status | Finding |
|---|---|---|---|
| F1 | high | plausible, needs empirical proof | Production SessionStart probably can never bind |
| F2 | medium | confirmed by source | clear/resume/other SessionStart is ignored and does not invalidate the binding |
| F3 | medium | confirmed by source | The executable digest is recorded but not checked, and exec is by path after hashing (TOCTOU) |
| F4 | low-medium | confirmed by source | The pinned executable version and the accepted `session_meta` version disagree |
| F5 | low (blocks plain `cargo test`) | **confirmed by rerun** | The native unit tests collide when run in parallel |
| F6 | low | confirmed by source | An already acknowledged partial paste is re-polled and can be turned into recovery |
| L1 | limit | — | The native ACK channel is a file the child's own tools can write (same uid) |
| L2 | limit | — | An 8 MiB read and hash runs under the daemon `agents` lock on every poll; the `--version` probe can block spawn for up to 2 s |

### F1 — production SessionStart probably cannot bind (high, plausible)

`NativeProfile::bind` (`native_notification.rs:87-108`) calls `fs::canonicalize(path)`
and then requires a first row of `session_meta`. Neither the local route
(`pty_notification.odin` `bridge_pty_notification_session`) nor the remote route
(`executor_child.odin` `bridge_executor_child_notification_session`) retries.
Only `source=="startup"` is accepted, so the bind gets exactly one attempt.

The engineer's own real rollout
`~/.codex/sessions/2026/11/07/rollout-2026-11-07T14-10-50-01a1b52a-….jsonl` shows:

- `session_meta.payload.timestamp` = `08:40:50.263Z` (session start)
- file birth time = `08:40:53.948Z`; row 0 (`session_meta`) and row 1 (`task_started`) both carry the row timestamp `08:40:53.949Z`

So Codex 0.162.0 creates the rollout lazily, at the first turn, about 3.7 s
after startup. A SessionStart(startup) hook that fires at startup will very
likely get ENOENT, and the bind fails. The result is fail-closed: interrupt
PREPARE returns `interrupt_profile_unsupported_not_delivered`. But the feature
never works in production, and no test exercises this path.

**Fix:** record the authenticated (session_id, path) at SessionStart and run
the existing checks lazily at PREPARE/`begin` (still first-bind-wins, still
child-fenced). Alternatively, prove with a real connected test that the hook
fires after the file exists. Add a positive production SessionStart test.

### F2 — non-startup SessionStart does not poison the binding (medium)

The doc comment at `native_notification.rs:86` says clear/resume "requires a
fresh child, never retargeting". In practice both routes simply `continue` or
`return` on `source != "startup"`. The bound profile stays active, pointing at
the old file.

After `/clear`, `/new` or resume, `begin()` reads the abandoned file. If that
file ends with a `task_started` that has no terminal row, ESC is written into
the new live session. `poll` then waits on the old file, times out at 8 s and
returns `RECOVERY_REQUIRED`. By then a real turn has been interrupted and no
paste follows. If the file is idle, it fails closed correctly.

**Fix:** any SessionStart for the bound child with a different session id or a
non-startup source should mark the profile permanently unusable. Treat it as
ambiguous and require a fresh child.

### F3 — digest is attribution, not admission; exec TOCTOU (medium)

`for_spawn` (`native_notification.rs:44-83`) admits any absolute file named
`codex` that has ELF or Mach-O magic and prints exactly `codex-cli 0.162.0`.
The SHA256 only goes into the profile id. It is never compared with a trusted
set. The hash is taken from an fd opened before `PtyHost::spawn`, and spawn
then executes `config.program` **by path** (`daemon.rs:603-607`). A swap
between the hash and exec is not detected.

The brief asks for "executable digest/version trust". The current code gives
version trust plus a digest for attribution only.

**Fix:** either pin the expected digest(s) in trusted host configuration, or
after spawn verify the running image (`/proc/<pid>/exe` hash on Linux) against
the hash. Either way, document plainly that the digest is attribution-only
until one of these is done.

### F4 — version mismatch (low-medium)

`for_spawn` pins the executable to `0.162.0` (line 71). `bind` accepts
`session_meta.cli_version` of `0.162.0` **or** `0.167.0` (line 102), and every
unit test uses `0.167.0`. The probed 0.162.0 child cannot have written a
0.167.0 header, so accepting one weakens the "exact current child" binding.

**Fix:** require `cli_version` to equal the probed version that is stored in
the profile, and test with matching versions.

### F5 — parallel unit-test collision (low, confirmed)

`tests::root()` (`native_notification.rs:214-217`) names the directory
`ham-native-{pid}-{wall_ms}`. Tests that run in parallel within the same
millisecond share a directory, and one test's `remove_dir_all` or appended rows
break another.

I ran this in a detached worktree at `9e6b89af` (`tools/pty_host`, `nix develop`):

- `cargo test --lib -- native_notification --test-threads=1` → 4 passed
- `cargo test --lib -- native_notification` (default threads), three runs → FAILED 2/4, 2/4, 1/4 (`typed_fresh_same_turn…` got `Ready` where `Waiting` was expected; `session_replacement…` got ENOENT)
- `cargo test --lib -- native` → `delivery::…native_profile_never_turns_elapsed_time_into_an_acknowledgment` ok; `cargo test --lib -- notification_session` → dproto roundtrip ok

The engineer's evidence used `--test-threads=1`, which hides this. The chain
already has the same dead end for SQLite names that relied on a timestamp alone.

**Fix:** add an atomic counter or use a unique tempdir.

### F6 — re-poll after ACK (low)

`Daemon::notification` (`daemon.rs` native DISPATCH branch) calls
`native.poll()` on every DISPATCH while the receipt is PARTIAL with
`esc_written`. That includes after `acknowledge_native`. `poll` returns
`Uncertain` once 8 s have passed since `begin`, or when a newer `task_started`
appears. Either case calls `recover()` on a paste that was legitimately
authorized and partly written. This is fail-safe, since no bytes are
duplicated, but it loses a delivery.

**Fix:** skip the poll when the entry is already `native_acknowledged`.

### L1 / L2 — limits to record, not defects

- **L1:** The rollout JSONL is owned by the same uid and can be written by the
  child's tool processes. A tool can append a well-formed
  `event_msg/turn_aborted(interrupted)` row with the next ordinal and cause a
  paste without a real abort. Before a genuine bind it could also plant a
  matching session file. F1 widens that window. This is acceptable only
  because native state is treated as transport evidence, never authority. The
  docs should say this explicitly.
- **L2:** Every `poll` reads up to 8 MiB and hashes it twice while holding the
  daemon `agents` mutex. The `--version` probe can block spawn for up to 2 s.

## Requirements that hold in the source

- **Profile choice is spawn-fixed and immutable.** The declaration is set only
  from the provider name in `bridge_pty_host_build_spawn_for_profile`. A legacy
  Spawn without the field decodes to `None` (dproto test). An unknown
  declaration, binary, version or platform, or a missing sessions root, gives
  no profile, and interrupt PREPARE is then refused (`delivery.rs` `apply_at`).
  `configure_profile` refuses to rebind, and `bind` is first-wins (`:93-96`).
- **The session binding is not cwd-only.** `Daemon::notification_session`
  requires an exact pid, `HEIMDALL_STARTUP_KEY`, epoch and run count (each env
  key must appear only once), and a live child that is not stopping. cwd, the
  sessions root, a `.jsonl` extension, the session id and a startup timestamp
  no older than spawn−1 s are extra checks.
- **The remote route is observation-only.** It verifies the signed bootstrap
  with the owner key and `executor_bridge_id`, finds the pid by `launch_key`,
  and fences the bootstrap again right before the IPC. It installs no legacy
  token, makes no owner exchange (the mounted test asserts `exchanges==0`), and
  does not mark readiness, select a profile or grant task authority.
- **A typed active turn is required before ESC.** `begin` needs a structured
  `task_started` with no terminal row, and the same file identity and header.
  Idle or unknown state is refused before any byte is written.
- **A fresh abort of the same turn is required before paste.** The row must
  come after the pre-ESC byte boundary, whose prefix SHA256 and inode must be
  unchanged. It must be an outer `event_msg` of type `turn_aborted` with
  reason `interrupted`, the same `turn_id`, and a timestamp ≥ the ESC send
  time. A newer `task_started`, a different turn, `task_complete`, nested
  strings or `response_item` cannot acknowledge. The screen is never consulted.
  There is no fixed-delay fallback (delivery test).
- **Rotation, truncation, replacement and restart fail closed.** A new inode,
  prefix mismatch, symlink, ordinal regression or file over 8 MiB gives
  `Uncertain`, then recovery. `restart()` rebuilds the Agent with a fresh,
  unbound profile, and executor children refuse restart. A daemon restart
  loses its in-memory receipts, and the absent entry returns
  `RECOVERY_REQUIRED`.
- **The real Codex row shape matches the parser.** I checked the engineer's
  rollout: it has `ordinal`, `session_meta.payload.{id,cwd,cli_version,timestamp}`,
  and `event_msg.payload.{type,turn_id,reason}`.

## Recommendation

Do not count this as M3b acceptance evidence. F1 needs empirical resolution
(a positive production SessionStart bind), and F2–F5 should be fixed or
explicitly waived before the cumulative gate. The isolated profile checks are
sound. Full encrypted owner-path proof is still entirely outstanding.
