# M3 continuation: executor dispatch checkpoint

Task `task_18e556f90cfa1e9c`, attempt 2, branch `heimdall/task_18e556f90cfa1e9c`.

Checkpoint 1 is committed at `33107517648ae4d43e0f9aad176e24404152017a`; its evidence is in `docs/executor-reservations-checkpoint.md`. The second scoped commit adds the physical dispatch foundation below. Coordinator continuation instructions: `msg_18e5966c77baea81`, `msg_18e59763464904aa`.

**M3 remains unfinished.** Production owner reconciliation, global manual/warm admission and encrypted provider delivery still need implementation and independent acceptance. The current Bridge dispatcher is an internal adapter exercised with real processes and a test owner verifier. It is not mounted as a production owner lease route.

## Current acceptance status

| Requirement | Verified checkpoint | Required continuation |
| --- | --- | --- |
| REQ-M3-1 | Signed finite device ledger; cross-owner/manual/warm resource exclusion, canonical resource-proof boundary, drain-before-policy replacement | Production owner prepare/commit/activate journal and every manual/warm launch entrypoint |
| REQ-M3-2 | Exact replay, persistent single-use first dispatch, stale incarnation/deadline/stop rejection, real daemon key deduplication, expiry rechecks and bounded physical child timeout | Owner recovery loop, remote instance/config binding, physical deadline renewal with version fencing, all stop/result consumers |
| REQ-M3-3 | Old daemon capability refusal and exact keyed local query/close protocol | Encrypted notification/AAD/tickets, actual provider interrupt/literal-paste profiles, macOS and bounded Windows evidence |
| REQ-M3-4 | Real two-owner thread race, transactional faults, three ledger SIGKILL boundaries, real PTY replacement and daemon-loss uncertainty | Full owner/executor crash integration, independent review and final M3 gate |

## Implementation map

| Behavior | Source |
| --- | --- |
| Persistent first-dispatch permission; retries query the saved key | `src/lib/executor_local/actions.odin:154` |
| Fresh owner check and expiry before physical I/O | `src/bridge/executor_runtime.odin:15` |
| Exact binary capability/query/stop adapter | `src/bridge/pty_executor.odin:6` |
| Atomic daemon lifecycle and immutable full-spec SHA256 deduplication | `tools/pty_host/src/daemon.rs:409` |
| Stale close and unknown-key recovery boundary | `tools/pty_host/src/daemon.rs:707` |
| Actual packaged daemon launch/stop/replacement and daemon-loss proof | `src/bridge/executor_runtime_test.odin:37` |
| Owner check latency and clock-regression rejection before I/O | `src/bridge/executor_runtime_test.odin:190` |

The daemon serializes lifecycle changes across both legacy and fenced spawns, eliminating the check-before-fork race. For a fenced launch, it retains only the instance, SHA256 of the full canonical spawn spec, and outcome under the opaque execution key. Same-key changed input fails; same-key live retry returns the existing PID; a retired key never respawns. The map is bounded at 100,000 entries without silently dropping live identity.

The exact-control handshake is tag `0x3D` returning Pong only when executor fencing and absolute deadline enforcement are supported. Close/query use `0x3E/0x3F`. Tag `0x3C` remains reserved for the selected notification adapter. The Bridge proves capability before sending Spawn; an actual pre-M3 daemon was refused with no fallback launch.

The reserved `HEIMDALL_EXECUTOR_LAUNCH_KEY` and `HEIMDALL_EXECUTOR_DEADLINE_MS` values come from the ledger. The daemon checks the absolute deadline immediately before fork and clamps its monotonic child timeout to the remaining bound. Already-expired admission is recorded as known no-child. A failure after launch setup begins remains uncertain. Duplicate reserved fields and malformed exact controls fail closed.

`begin_dispatch` durably consumes first-I/O permission. Old runtime claims cannot gain a fresh launch permission. A retried stop can safely repeat the same exact-key close; a retried launch only queries the saved identity. The Bridge commits expiry observations again after owner verification and capability I/O so a slow check or backward clock cannot reopen an elapsed admission window. Late daemon observations retain the captured claim incarnation.

A fresh daemon with no knowledge of an old key returns uncertainty. It does not attest absence from an empty registry. The real-process test kills the daemon while a bounded child exists, cleans up that verified test child, starts a new daemon and verifies that the old reservation remains charged/stopping. No automatic takeover, refund or new launch follows.

## Reproduce the chosen checks

All commands ran through managed `ham-ctl shell run --cwd <worktree> --cmd ...` from:

```bash
cd /var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-ledger-checkpoint2-final
nix develop --command odin build tests/executor_crash_probe -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/m3-crash-checkpoint2
nix develop --command env HEIMDALL_EXECUTOR_CRASH_PROBE=$HOME/.cache/heimdall-tests/m3-crash-checkpoint2 python3 tests/test_executor_process_crash.py
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 cargo test --manifest-path tools/pty_host/Cargo.toml --offline -- --test-threads=1
nix build .#ham-bridge .#ham-pty-host -o $HOME/.cache/heimdall-tests/m3-dispatch-bins
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3-dispatch-bins-1/bin/ham-pty-host HEIMDALL_EXECUTOR_OLD_PTY=$HOME/.cache/heimdall-tests/c1f-v24-bins-3/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.pty_executor_exact_control_wire_shape_and_invalid_identity,main.bridge_executor_real_daemon_ledger_dispatch_and_stale_stop,main.bridge_executor_expiry_during_owner_check_and_clock_regression_fail_before_io -out:$HOME/.cache/heimdall-tests/m3-bridge-packaged-crash-proof
git diff --check
```

| Check | Result |
| --- | --- |
| Executor ledger | 14 PASS, including persisted single-use dispatch and restart fencing; `sh_d60efa1d9d662ff02fac2e7142ad2845` |
| Ledger process crashes | PASS: real SIGKILL at all three committed boundaries; same session |
| Full Rust with real PTY required | 186 PASS; two helper tests are invoked by parent fresh-process tests; no PTY skips; `sh_5af9894ecc92b2c504e8cb4419a49ab8` |
| Bridge and PTY package builds | PASS; `sh_9f1e4d6e48d9b5dfcdb9d936aac3849f` |
| Real packaged Bridge/PTY and old daemon | 3 PASS, including real daemon SIGKILL, unknown-key resource retention, stale-stop replacement and pre-spawn refusal of old daemon; `sh_916666ffa7ba18e89e55698d3e64d5b9` |
| Contracts and TS | Retained passing checkpoint-1 evidence: 32 native contracts, three TS P256/wire tests and typecheck. These contracts did not change in checkpoint 2. |

The Nix build sandbox has no PTY. Its test run follows the repository skip convention. The separate host run sets `HEIMDALL_EXECUTOR_REQUIRE_PTY=1`, which makes absence of PTY support a failure, and passed. The actual Bridge test similarly uses `EXECUTOR_TEST_REQUIRED=true` and explicit packaged new/old daemon paths. Default development runs print an explicit skip when the integration binary is not configured.

## Exact remaining work for the next lease

1. Add the owner-side durable prepare request, verified host reservation receipt, revalidation, grant/activation intent and query/recovery states in the owner UoW. Handle prepare expiry after owner commit by retiring the failed grant without charging an agent failure. Existing owner outbox rules at `src/lib/owner_local/outbox.odin:22` remain the pattern.
2. Replace the injected `Executor_Owner_Check` with current authenticated owner verification. Existing `src/lib/owner_local/leases.odin:75` still admits only the owner Bridge key, and `src/bridge/owner_local_leases.odin:17` still requires an already-running local child. Do not pretend a prepared remote process is that live-child proof; add an explicit reserved-remote admission path and pinned remote assignment/configuration.
3. Provision host-signed finite policy and a single account/device ledger. Resolve canonical directories and launchable catalog/profile configuration on the execution Bridge. Wire `src/bridge/hub_runtime_client.odin:2694` and every manual/warm agent launch through it, with no unfenced admission fallback. Keep existing warm process charges until exact stop and explicitly bind each new lease fence.
4. Add the enrolled remote relay and owner/executor reconciliation worker. Serialize dispatch with application of invalidations; poll/query only saved identities. After restart, adopt uncertain exact-key safety stops under the new runtime without reissuing old launch permission. Unknown daemon state requires explicit recovery and verified old-child stop.
5. Add versioned physical deadline renewal, remaining signal/input/result fences and exact observation handling. The current physical child keeps its conservative original deadline and can exit early after a logical renewal; no extension support is claimed.
6. Integrate selected notification code hunks, encryption/AAD, exact tickets and uncertain delivery queries. Never restore candidate Hub dispatch permission or arbitrary filesystem bodies.
7. Run actual provider interrupt and Unicode/literal-paste profiles, macOS validation and bounded Windows gates. Linux shell/PTY and storage checks are not provider or Windows evidence. Complete independent review and final M3 acceptance only after these paths pass.

## Corrections and limits recorded

Draft Odin test syntax, a missing warm test commit sequence, and owned codec string cleanup were corrected. A first Nix package build failed because new tests demanded PTY support inside its sandbox; the explicit skip/required-host gate above resolved that environment mismatch. The final chosen checks passed.

The opcode capability handshake was added after auditing old-daemon compatibility: accepting a legacy Spawn response cannot prove executor fencing. Fresh-clock and absolute-deadline checks were added after auditing time spent in owner/IPC checks.

No live restart, deployment, push, production cutover, Hub task authority or final M3 approval occurred.

## Exact checkpoint-2 modified paths

- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/docs/executor-dispatch-checkpoint.md`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/executor_runtime.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/executor_runtime_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/pty_executor.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/pty_executor_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/actions.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/store_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tests/executor_crash_probe/main.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tools/pty_host/Cargo.lock`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tools/pty_host/Cargo.toml`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tools/pty_host/src/daemon.rs`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tools/pty_host/src/dproto.rs`

Step 2 deliberately keeps the production owner/matcher/legacy launch callsites untouched until resource admission and owner reconciliation are complete. The daemon and tested Bridge adapter have real physical effects; they do not grant or fold task state. Continue the same task branch and preserve checkpoint 1.
