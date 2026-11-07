# M3 checkpoint 1: executor contracts and isolated resource ledger

Task `task_18e556f90cfa1e9c`, attempt 2. Coordinator scope: `cmt_18e595295a314976`, confirmed in `msg_18e5952c74b415ca`. This is the first bounded implementation checkpoint. **M3 remains incomplete.** Production launch admission, owner reconciliation, encrypted notification delivery, real provider profiles, macOS and Windows evidence are still required.

## Implemented boundary

This additive package stores executor resources separately from owner-local task authority. There are no task tables, lease grants, Hub authority calls or network I/O in `src/lib/executor_local`. Existing owner-local migrations and production launch entrypoints are unchanged. The ledger is not mounted as a production endpoint.

| Rule | Implementation |
| --- | --- |
| Strict signed policy, prepare, action and receipt domains; ASCII authority, exact i64 decimal strings, duplicate/unknown-field rejection, raw-document bound | `src/contracts/executor.odin:105`, `src/contracts/executor.odin:111` |
| Host Bridge key signs static finite slot policy; each slot pins a profile; policy replacement requires every resource drained | `src/contracts/executor.odin:127`, `src/lib/executor_local/store.odin:110` |
| Account/executor/operator-key binding, lifetime writer lock, FULL WAL and persistent restart incarnation | `src/lib/executor_local/store.odin:36`, `src/lib/executor_local/schema.sql:2` |
| Exact slot, instance and directory uniqueness shared by owners and launch purposes; preparation TTL at most 30 seconds | `src/lib/executor_local/store.odin:152`, `src/lib/executor_local/schema.sql:36` |
| Current owner fence/commit evidence required for activation and renewal; immutable operation receipts precede mutation admission | `src/lib/executor_local/actions.odin:10`, `src/lib/executor_local/store.odin:152` |
| Durable launch/stop intentions; uncertain dispatch claimed once before I/O | `src/lib/executor_local/actions.odin:72` |
| Expiry queues safety stops and retains active/warm charges; only exact trusted absence frees the resource | `src/lib/executor_local/actions.odin:96`, `src/lib/executor_local/actions.odin:107` |
| Restart stops fresh admission until every active/stopping exact child reconciles | `src/lib/executor_local/actions.odin:122` |
| Host-signed result snapshots bind request digest, original child incarnation, serving-runtime incarnation and historical flag; historical receipts cannot become fresh admission | `src/lib/executor_local/receipts.odin:10`, `src/contracts/executor.odin:141` |

Static policy is an operator allocation, not an entitlement issuer. The configured pool must be provisioned within the device/account allocation; the ledger enforces that pool and cannot borrow from another device. Capacity is bounded at 128 slots. Reservation, receipt and policy admission is bounded at 100,000 records per class; replay and local safety expiry are retained at capacity. No active evidence is silently pruned.

## Required integration contract

1. Open exactly one ledger in a private device directory, after loading the enrolled host key. Drain callers before closing it. The parent directory must be account-private; database files are mode 0600 on POSIX.
2. Verify current enrolled directory keys and revocation before passing `Owner_Verified_Key`. These are trusted verifier results, not decoded envelope assertions.
3. Resolve the canonical protected directory, current instance/configuration and provider profile on the execution Bridge. Pass that result as `Resolved_Resources`; a caller-supplied path or hash is not a resource proof.
4. Persist an owner prepare intent, send its exact signed document, verify the host receipt against the original request, then revalidate owner eligibility and commit the grant plus activation intent. The prepared resource is never itself a task lease.
5. Obtain `Current_Owner_Fence` from a fresh authoritative owner check; never deserialize `current=true` from the remote request. Activation/renewal must match its prepare digest, owner incarnation and commit sequence. Keep network I/O outside both SQLite transactions.
6. Claim a durable executor intent. The daemon adapter must atomically deduplicate the exact launch key, resolve uncertain delivery by querying that same key and never fall back to an unfenced spawn. A pending/uncertain intent is not evidence that a child exists.
7. `Child_Observation` is a trusted exact daemon query. Instance plus launch key and current observation incarnation must match; PID, timeout or an old exit event cannot free a resource. Active/stopping resources remain charged while absent/unknown status is unresolved.
8. On restart, the serving runtime incarnation advances while an already-running physical child retains its original incarnation. Signed snapshots carry both. Replayed results keep their original serving incarnation and say `historical=1`.
9. Wire every manual, warm and owner-triggered launch through the same ledger. Reuse of an existing warm process must retain its resource charge and explicitly bind the new owner execution fence; it cannot free/reallocate a slot while that child is running.

## Verification

Run from the assigned worktree:

```bash
cd /var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-ledger-checkpoint-final
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-contracts-checkpoint-final
nix develop --command npm run typecheck
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_contract_test.ts
nix develop --command odin build tests/executor_crash_probe -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/m3-executor-crash-probe-final
nix develop --command env HEIMDALL_EXECUTOR_CRASH_PROBE=$HOME/.cache/heimdall-tests/m3-executor-crash-probe-final python3 tests/test_executor_process_crash.py
nix build .#ham-bridge .#ham-hub .#ham-ctl -o $HOME/.cache/heimdall-tests/m3-checkpoint-bins
git diff --check
```

Checks run through managed `ham-ctl shell run --cwd <worktree> --cmd ...`. The pinned dependency install used `nix develop --command npm ci --ignore-scripts --no-audit --no-fund`, with no lockfile changes.

The ledger suite has 13 tests: signed replay/activation, competing owner/manual/warm charges, exact restart reconciliation, statement and COMMIT rollback, simultaneous two-owner thread race, expired preparations, heartbeat/stop versions and replacement safety, persisted clock quarantine, signed historical receipt binding, separate serving/physical incarnations, activation/stop rollback, policy rollback, owner watermark/scope rejection, and retention-capacity safety. Some tests combine related cases.

The subprocess proof uses real SIGKILL after committed preparation, committed activation before launch dispatch, and persisted uncertain launch dispatch. Each new process reopens the actual SQLite files, checks resource retention, rejects duplicate launch claims, reconciles an explicit test absence observation and verifies replay plus foreign keys. It proves ledger crash persistence. It does not launch a provider or prove a real daemon observation.

Shared Odin/TypeScript vectors cover all four domains. TypeScript also creates a real P-256 key and proves signature, request digest, scope, expiration and historical-admission rejection.

## Remaining M3 work

- Owner durable prepare/commit/activate/query/recovery pipeline, including expiration after owner commit without charging an agent failure.
- Enrolled remote executor relay, fresh owner validation and host policy provisioning.
- Atomic daemon launch-key deduplication, canonical directory resolution and all manual/warm launch entrypoints.
- Exact daemon observations and stop/result fences, reconciliation after real executor and daemon crashes.
- Selected PTY notification adapter, opaque result tickets, encryption/AAD, literal Unicode paste and provider-specific interrupt profiles.
- Actual Linux provider evidence, primary macOS validation and bounded Windows build/delivery/unsupported gates. None is inferred from these Linux ledger tests.
- Independent review and final integrated M3 acceptance.

No Hub writer fallback, live restart, deployment, push or production migration was performed.

Checkpoint results: all commands above passed. Native suites: 13 executor tests and 32 contract tests; actual SIGKILL harness: one test covering all three committed boundaries; three application binaries build. Final native/crash/build session: `sh_556c9210b7c47c474fc144511588b7e2`. Typecheck and all three TypeScript tests passed in `sh_dc0ba5683061cebf3dd06c440e7fede5`. Rust, real provider, macOS and Windows suites were not run because this checkpoint changes no PTY runtime and supplies no platform/delivery evidence.

Exact modified paths (relative to `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c`):

- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/docs/executor-reservations-checkpoint.md`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/executor.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/executor_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/fixtures/executor-v1.json`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/actions.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/receipts.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/schema.sql`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/sqlite.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/store.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/store_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/executor.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tests/executor_crash_probe/main.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tests/test_executor_process_crash.py`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tests/ui_executor_contract_test.ts`
