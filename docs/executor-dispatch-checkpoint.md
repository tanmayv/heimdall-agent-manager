# M3 continuation: executor dispatch checkpoint

Task `task_18e556f90cfa1e9c`, attempt 2, branch `heimdall/task_18e556f90cfa1e9c`.

This continuation preserves the physical dispatch foundation and adds the owner execution journal, signed single-use fence challenges (`d9253b59`), explicit reserved remote enrollment (`c4dfa43d`) and the sealed channel core documented below. The latest owner suite passed 239 tests; native/TS channel vectors also pass. Checkpoint 1 is `33107517648ae4d43e0f9aad176e24404152017a`, documented in `docs/executor-reservations-checkpoint.md`.

**M3 remains unfinished.** Production owner reconciliation, global manual/warm admission and encrypted provider delivery still need implementation and independent acceptance. The current Bridge dispatcher is an internal adapter exercised with real processes and a test owner verifier. It is not mounted as a production owner lease route.

## Current acceptance status

| Requirement | Verified checkpoint | Required continuation |
| --- | --- | --- |
| REQ-M3-1 | Signed finite device ledger; core cross-owner/manual/warm resource exclusion; owner atomic journal/outbox; device-authorized exact remote configuration and enrolled-key binding | Canonical resource/identity attestation issuance, mounted prepare/activate reconciliation and every manual/warm launch entrypoint |
| REQ-M3-2 | Exact replay, persistent single-use first dispatch, stale incarnation/deadline/stop rejection, real daemon key deduplication, expiry rechecks, signed nonce-bound owner fence and bounded physical child timeout | Mounted owner recovery/remote exchange loop, physical deadline renewal with version fencing, all stop/result consumers |
| REQ-M3-3 | Old daemon capability refusal, exact keyed local query/close and current-epoch identity-bound sealed channel core with shared native/TS vectors | Mounted encrypted transport, notification/AAD/tickets, actual provider interrupt/literal-paste profiles, macOS and bounded Windows evidence |
| REQ-M3-4 | Real two-owner thread race, transactional faults, three ledger SIGKILL boundaries, real PTY replacement and daemon-loss uncertainty | Full owner/executor crash integration, independent review and final M3 gate |

## Original physical dispatch implementation map

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

## Continuation: uncertain safety-stop adoption

Coordinator approved continuation in `msg_18e5980a25560a75`. Before mounting the
production reconciliation worker, closed the restart gap in
`src/lib/executor_local/actions.odin:79`: stop intents in uncertain state can be
claimed once by each new serving incarnation. The claim is committed before I/O,
preserves the saved reservation/instance/document/launch key, and leaves uncertain
launch intents untouched. Existing exact observations remain the only way to
release an active/stopping resource; an unknown daemon key still retains charge.

Regression tests in `src/lib/executor_local/store_test.odin:389` cover two
successive restarts, rejection of old claims/observations, absence of launch
reissue, retention until trusted absence, and deferred COMMIT failure with retry.
The existing real daemon test at `src/bridge/executor_runtime_test.odin:117` now
reopens the ledger with an uncertain stop while the daemon survives, rejects the
old dispatcher claim, adopts the exact stop, verifies physical absence, and then
launches a replacement under incarnation 2. It retains the real daemon SIGKILL
and unknown-key resource-retention phase.

All commands below ran through managed shell sessions from the task worktree:

```bash
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-stop-adoption-20261106-2324
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3-dispatch-bins-1/bin/ham-pty-host HEIMDALL_EXECUTOR_OLD_PTY=$HOME/.cache/heimdall-tests/c1f-v24-bins-3/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.pty_executor_exact_control_wire_shape_and_invalid_identity,main.bridge_executor_real_daemon_ledger_dispatch_and_stale_stop,main.bridge_executor_expiry_during_owner_check_and_clock_regression_fail_before_io -out:$HOME/.cache/heimdall-tests/m3-stop-adoption-bridge-20261106-2325
git diff --check
```

Executor suite: **16 PASS**, session `sh_635677b8f9592184d2be6cdc58cadb7a`.
Required real daemon Bridge suite: **3 PASS**, session
`sh_3024947b91604f167161a1b1a598b0ba`. No daemon or wire change was needed;
the prior packaged daemon was used. Draft test compilation failed on Odin's
no-redeclaration rule; a subsequent draft exposed shell-stripped SQL quotes in
test fixtures. Both were corrected before the reported passing runs.

Additional modified paths, all under
`/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/`:

- `src/lib/executor_local/actions.odin`
- `src/lib/executor_local/store_test.odin`
- `src/bridge/executor_runtime_test.odin`
- `docs/executor-dispatch-checkpoint.md`

No unrelated cleanup was included. This is a bounded recovery correction;
production owner reconciliation/global manual-warm admission, physical renewal,
encrypted delivery, real provider/platform evidence and independent acceptance
remain required. M3 is not submitted as complete.


## Continuation: owner execution journal (V25)

This scoped continuation adds the durable owner-side core. **It does not mount
production remote assignment, remote transport or global launch admission.**
Coordinator approval: `msg_18e59842a4bf3905`.

The owner persists the original signed prepare and lease command before remote
I/O. It binds them to the accepted exact assignment history and revalidates that
assignment and normal owner lease guards before grant. A verified current host
receipt allows an atomic owner transaction containing the normal lease grant,
its event/receipt, the verified reservation and the signed activation outbox
intent. Nested lease admission uses an owner savepoint; failure of the outer
COMMIT rolls every effect back. The prepared absolute hard deadline is retained
when admission happens later.

A historical prepare replay cannot admit a lease by itself. Recovery requires a
fresh signed query proving the same exact reservation is still prepared. Owner
restart keeps the saved identities and produces an activation bound to the new
owner incarnation; committed replay returns historical bytes without a second
grant or intent. Bounded preparation enumeration exposes only saved documents.
The fresh owner fence helper checks the exact claimed outbox target, payload,
reservation, lease, deadline version, current assignment and task revision.

Uncommitted expired preparations are retired by the ordinary Bridge maintenance
worker. They create no lease or work attempt, and do not refund execution-device
resources. The execution Bridge independently expires its own prepared charge.
The owner production signer explicitly accepts only `executor.prepare` and
`executor.action` resource domains, retains preloaded-key-only behavior and does
not accept executor capacity policy signing.

V25 uses the existing strict executor and owner wire contracts. It adds an
owner-local durable schema, not a new Hub task field or public wire method.
Old migrations are unchanged. Existing migration fixtures remove the new table
when reconstructing historical databases and expect current schema25. The rich
V23 collision test keeps its genuine historical version24 failure gate. The new
V24 test verifies identity/content preservation and complete rollback of the
runtime table and journal DDL on collision.

### Source anchors

- Persist signed preparation: `src/lib/owner_local/execution.odin:53`.
- Verified receipt, atomic grant and activation: `src/lib/owner_local/execution.odin:129`.
- Historical prepare requires fresh exact query: `src/lib/owner_local/execution.odin:106`.
- Bounded saved-identity recovery inventory: `src/lib/owner_local/execution.odin:187`.
- Current exact owner fence check: `src/lib/owner_local/execution.odin:203`.
- No-attempt uncommitted preparation expiry: `src/lib/owner_local/execution.odin:237`.
- Nested owner lease UoW and absolute hard bound: `src/lib/owner_local/leases.odin:71`.
- Immutable durable journal: `src/lib/owner_local/migration_025.sql:48`.
- Periodic preparation retirement: `src/bridge/owner_local_leases.odin:111`.
- Production resource signing domains: `src/bridge/unseal_protocol.odin:848`.
- Signed two-store integration proof: `src/lib/owner_local/execution_test.odin:81`.
- Production signer proof: `src/bridge/vault_v2_bridge_test.odin:880`.


### Chosen verification

Commands run through managed shell sessions with the assigned worktree as
`--cwd`:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-owner-v25-full-final2-20261106-2346
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_owner_local_periodic_batch_expires_and_publishes_after_commit,main.test_owner_local_publication_recovers_result_write_and_commit_failure_in_process,main.test_owner_local_signer_never_loads_keystore_inside_transaction,main.test_owner_local_executor_signer_domains_and_missing_identity -out:$HOME/.cache/heimdall-tests/m3-owner-maintenance-signer-final-20261106-2348
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3-owner-v25-bridge-final-20261106-2347
python3 scripts/check-owner-aggregate-parity.py
git diff --check
```

Final owner suite: **227 PASS**, including nine new journal tests, session
`sh_bf9ef7b168910ba365381562b6631841`. Final Bridge maintenance/publication and
signer suite: **4 PASS**, session `sh_93acf1edc070b0d32376a241f57cc259`. Bridge build
passed in `sh_21b4a3d1ac7d9884f92ae00342fef67f`. Aggregate parity passed: all 240
original fields/23 structs and 73 signed methods, session
`sh_c5b398c26560661908efcd5eafcf8917`. No Rust/TS/contracts changes were needed,
so their checkpoint evidence was retained rather than rerun.

Draft corrections: V25 initially retained a schema24 default, corrected before
passing focused runs. Test drafts had an Odin multiline-loop/concatenation
syntax error and an unsupported assertion-message argument. The first broader
run was 223/224 passing; a historical V23 fixture retained the V25 journal table.
Its teardown was corrected while preserving the version24 fault gate. Initial
Nix build omitted new untracked files; staging the new source/SQL made it
available to the Git-source snapshot. A parity run caught a shifted exact test
line anchor; retaining the fixture constant on its original line restored the
actual command-specific evidence. These were corrected, not waived.

### Remaining production work

1. Establish explicit reserved-remote assignment/enrollment from authorized
   fleet/member/lifecycle policy. Current journal admission requires existing
   accepted exact assignment history; it deliberately cannot fabricate a local
   live-child proof or bypass those controls.
2. Mount authenticated encrypted owner/executor transport, key/directory and
   canonical resource resolution, plus the owner matcher/reconciliation worker.
   The new current-fence helper is an internal authoritative read; it still
   needs a signed/sealed challenge-bound transport response before replacing
   the injected Bridge owner check.
3. Consume `executor.activate` through a fenced production handler. The generic
   outbox publisher currently returns unsupported for this kind. After owner
   restart, query the saved activation before disposition; old activation bytes
   cannot be reused as fresh launch permission. Add durable committed-grant
   failure disposition with no agent-failure charge for an expired reservation.
   Query/released state alone cannot prove a child never ran; preserve exact
   physical outcome evidence rather than infer a refund.
4. Provision the one device ledger and host-signed static policy; route every
   manual/warm/owner launch through it, without an unfenced fallback. Wire
   reservation renewal, exact stop/input/results and safe child recovery.
5. Add physical deadline renewal, encrypted notification/AAD/tickets and actual
   provider/macOS/Windows gates; obtain independent final acceptance.

No global production route, deployment, live restart or push occurred. No
unrelated boy-scout changes were included. M3 remains unfinished.

## Continuation: bilateral signed fence challenges

Source anchors in this section describe checkpoint `d9253b59`; the subsequent
reserved-enrollment section records later changes to those files.

Coordinator approved this bounded step in `msg_18e59949a8d52e41`, followed by
remote enrollment and production transport/reconciliation. This checkpoint
implements the signed exchange core; it does not mount a remote route or replace
the injected production owner-check boundary.

`src/contracts/executor.odin:167` and `src/ui/api/executor.ts:406` verify both
enrolled Bridge signatures, the original activation signature, exact account,
owner/executor identities and incarnations, chain/reservation, action and prepare
digests, owner commit sequence, request digest, nonce and deadlines. Strict shared
wire vectors include the new domain-separated request/reply documents and
malformed/unknown-field/TTL cases. The request also binds the exact owner outbox
intent ID and claim attempt. A reply is evidence for one outstanding challenge,
never a reusable capability.

`src/lib/owner_local/execution.odin:243` authenticates the requesting executor,
rechecks the externally verified directory version/hash under the owner
transaction, loads the claimed activation from durable owner storage and checks
the existing authoritative fence guards before signing. The requester cannot
supply a replacement claim or activation. Reads create no lease, receipt, event
or outbox effect; unsuccessful checks return no signed positive answer.

`src/lib/executor_local/fence.odin:18` generates 32 bytes from the fail-closed OS
CSPRNG and retains the original request/action for one serialized exchange.
`src/lib/executor_local/fence.odin:45` consumes successful or expired challenges
and checks a monotonic timeout as well as signed wall-clock bounds. Restart
cannot adopt a pending challenge; current executor incarnation is checked again.
The Bridge signer explicitly supports the two new domains while retaining its
preloaded-identity requirement and refusal to sign executor capacity policies.

Tests at `src/lib/owner_local/execution_test.odin:98` exercise two independent
SQLite stores and real P256 signatures: valid activation, fresh nonce isolation,
single use, scope/digest/incarnation substitution, revoked keys, mismatched
directory pins, expiry/clock rollback, retired/retried claims, both runtime
restarts and monotonic expiry with a frozen wall clock. These are core tests,
not evidence for an enrolled network transport or real-provider support.

### Fence checkpoint verification

All commands ran through `ham-ctl shell run --cwd` with this task worktree:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-fence-owner-final-20261106-2351
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-fence-contracts-20261106-2348
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-fence-executor-20261106-2350
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_owner_local_executor_signer_domains_and_missing_identity -out:$HOME/.cache/heimdall-tests/m3-fence-signer-20261106-2350
node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_contract_test.ts
npm run typecheck
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3-fence-bridge-20261106-2350
python3 scripts/check-owner-aggregate-parity.py
git diff --check
```

Final owner suite: **231 PASS**, `sh_d53e1fad9079bdd481235dbc6049c074`.
Contracts: **32 PASS**, `sh_3a4f76bb8192abf892d124b157d69c94`.
Executor: **16 PASS**, `sh_d716dc284b4d6c8bfd9dab401811c9b5`.
Bridge signer: **1 PASS**, `sh_d9750799f2457fc9a6e241c55a74ac3f`.
TS: **4 PASS**, `sh_d5ed39ed495f3652b2ec53ad0abb90c8`.
Typecheck: PASS, `sh_970f35c360f6153e050861a26e07d6ec`.
Bridge build: PASS, `sh_44ac8f84a80402e9f86b44e39ed58743`.
Aggregate parity: PASS, 240 fields/23 structs and 73 signed device methods,
`sh_de710b30a04c9d8a7fd0e2c7c563f4ef`.

Draft corrections: Odin test failure-helper syntax and temporary allocator
setup; TS tests require the existing vaultEndpointHarness; a fixture owner ID
and a mutation that accidentally retained the original digest were corrected.
No check was waived. Rust, actual provider/platform and network transport tests
were not rerun because this checkpoint changes no daemon or mounted transport.

Remaining work is the production list above: explicit reserved-remote enrollment
and current enrolled-key verification at both transport ends, encrypted relay,
matcher and saved-identity prepare/activation reconciliation, exact committed
grant failure disposition, device-wide manual/warm admission, physical renewal,
encrypted notifications/results/tickets and real provider/platform evidence.
The serialized dispatcher must recheck the exact local ledger intent after an
exchange; returned core proof values must never be cached as launch permission.
M3 remains unfinished and requires independent and explicit user review.

Exact signed-fence modified paths:

- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/executor.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/fixtures/executor-v1.json`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/executor.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tests/ui_executor_contract_test.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/fence.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/execution.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/execution_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/unseal_protocol.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/vault_v2_bridge_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/docs/executor-dispatch-checkpoint.md`

## Continuation: explicit reserved remote enrollment

Coordinator approved the distinct signed device `fleet.reserve` boundary in
`msg_18e599de90fa25d9`. The existing `fleet.edit` and local live-child proof are
preserved. The generic encrypted device ingress now resolves the executor key
against paired, signed directory evidence and passes it to ordinary owner
command admission. Directory approval alone does not bind arbitrary Bridge IDs:
the signed device configuration authorizes the exact executor Bridge ID/key pair,
and the executor signs the digest of those exact configuration bytes.

The strict generated payload retains instance, configuration revision, enabled
flag and `body_cipher`. The decrypted reservation contains the exact remote
configuration and signed executor enrollment. Content documents admit Unicode
model labels without relaxing ASCII authority envelope parsing. Original signed
ciphertext and verified plaintext are retained atomically together in immutable
assignment history; no migration or historical-row rewrite was needed.

Enrollment creates no lease, host resource reservation or child process. It
checks current native fleet policy, paused roles, capacity, member identity and
directory configuration, and establishes an explicitly reserved worker member.
Existing local child identities and unsettled execution journals cannot be
relabeled as reserved remote children. Ordinary direct lease admission rejects
reserved facts; the verified host-reservation journal remains the explicit grant
path. Cross-Bridge preparation now requires accepted `fleet.reserve` history and
matches the exact executor incarnation, policy, slot, profile and directory key.
Host receipt/fence verification also checks the key pinned by that history.

Read-scope validation and changed-input conflict lookup precede fresh admission
checks. A policy pause can leave historical replay readable while denying a new
grant or launch fence. Member/directory changes invalidate pending assignment;
directory invalidation includes remote configuration history. Accepted reserve
events participate in the existing attempt/budget replacement folds. The signed
method coverage inventory records the approved extension and its executed test
anchor: 74 signed methods, with the original 240 fields/23 structs preserved.

### Reserved enrollment verification

Commands ran through managed shell sessions with the assigned worktree as cwd:

```bash
python3 scripts/generate-owner-local-contracts.py
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-reserve-owner-final-20261107-0013
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-reserve-contracts-final-20261107-0013
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_owner_local_executor_signer_domains_and_missing_identity -out:$HOME/.cache/heimdall-tests/m3-reserve-signer-20261107-0006
node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_contract_test.ts tests/ui_owner_local_contract_test.ts
npm run typecheck
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3-reserve-bridge-final-20261107-0013
python3 scripts/check-owner-aggregate-parity.py
git diff --check
```

Full owner suite: **239 PASS**, `sh_29607d24792160372df4b7eb8609f1c0`.
Nine focused owner/directory/replay tests passed in
`sh_b63b9213d0d1584a6a364b05a3c9af20`.
Native contracts: **32 PASS**, `sh_c3a8043cd78f55326cfd6befe481c095`.
Bridge signer including enrollment domain: **1 PASS**,
`sh_dabb7f07d097d2729a3cfb577a43cb80`.
TS contracts: **25 PASS**, `sh_955e40595613d2e41db822253c5d4360`.
Typecheck: PASS, `sh_8d4ee0e74c16ef7a939071d368c97ba0`.
Bridge build: PASS, `sh_0d7b00bb86672f8fbc4ea72b3da29347`.
Aggregate parity and diff check: PASS, `sh_daf6b633a3f7cccbcedec01584b52a61`.

Draft corrections were not waived: immutable-parameter address and dynamic
string syntax; null-prototype TS assertion; a 237/238 owner run exposed live
configuration checking before changed-input conflict detection; native empty
policy fields needed to preserve executor resolution; multiline Odin `do`
syntax prevented a draft build; the Unicode model test caught the ASCII/content
boundary and led to the encrypted body rather than broader authority parsing.

This checkpoint tests signed owner admission, actual P256 directory evidence,
SQLite rollback/restart, strict wire parity and the production signer. It does
not demonstrate a real enrolled multi-Bridge request, issue remote attestations,
mount prepare/activate/fence transport, or dispatch provider processes. Existing
Rust/provider/platform evidence was retained because no daemon/input code
changed. No unrelated cleanup, live restart, deployment or push occurred.

Next: issue enrollment only after canonical device resource/catalog resolution
and exact reserved identity allocation; add sealed, identity-bound executor relay
and current directory verification in both directions; mount matcher and exact
saved-identity reconciliation, including lost replies and committed-grant failure
disposition. Global manual/warm admission, physical renewal, encrypted delivery
and results, actual provider/platform tests and final independent/user acceptance
remain required. M3 is unfinished.

### Exact owner-journal modified paths

- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/docs/executor-dispatch-checkpoint.md`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/owner_local_leases.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/unseal_protocol.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/vault_v2_bridge_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/aggregate_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/context_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/controls_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/execution.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/execution_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/fleet_policy_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/foundations_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/grants_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/leases.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/migration_025.sql`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/migrations.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/search_test.odin`

### Reserved enrollment source anchors

- Encrypted device ingress and current executor key: `src/bridge/owner_local.odin:189`.
- Paired root/current directory verification: `src/lib/owner_local/directory.odin:48`.
- Device configuration/host attestation binding: `src/contracts/executor.odin:178`.
- Current policy/capacity: `src/lib/owner_local/remote_assignment.odin:9`; membership/directory/physical-outcome guards: `src/lib/owner_local/remote_assignment.odin:49`.
- Atomic assignment history: `src/lib/owner_local/store.odin:330`; exact preparation/replay: `src/lib/owner_local/execution.odin:29`; direct grant guard: `src/lib/owner_local/leases.odin:110`.
- Browser writer verifies the approved executor before signing/encrypting: `src/ui/api/ownerLocalClient.ts:68`.

### Exact reserved-enrollment modified paths

- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/docs/executor-dispatch-checkpoint.md`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/docs/owner-local-parity-evidence.json`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/owner_local.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/unseal_protocol.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/vault_v2_bridge_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/executor.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/fixtures/executor-v1.json`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/fixtures/owner-local-schema.json`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/owner_local.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/owner_schema.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/attempts.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/budget_overlap.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/budget_runtime.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/directory.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/execution.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/execution_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/leases.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/operational_metadata.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/remote_assignment.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/remote_assignment_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/remote_directory_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/store.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/executor.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/ownerLocal.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/ownerLocalClient.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/ownerSchema.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tests/ui_executor_contract_test.ts`

## Continuation: sealed executor channel core

Coordinator approved this bounded step in `msg_18e59b429c7faaf6` and requested
checkpoint/handoff in `msg_18e59bae46b2cb6b`. This is a library/contract
checkpoint; no Hub relay endpoint, Bridge request handler or remote process
launcher is mounted.

`src/lib/executor_channel/channel.odin:19` binds the account, immutable owner,
executor, chain, reservation, request ID, method, direction, original request and
fence digests, both runtime incarnations, issued/expiry times and current vault
identity/epoch into canonical AEAD associated data. Scope has a bounded 60-second
transport lifetime; this does not extend the separately signed command/fence
deadlines. Sealing uses the existing vault AES-GCM implementation and a fresh
fail-closed OS nonce (`src/lib/executor_channel/channel.odin:34`), with a distinct
AAD domain and bounded ciphertext/plaintext. No new encryption primitive was
introduced.

`src/lib/executor_channel/channel.odin:42` accepts only the keyring's current
epoch, even when older epoch keys are retained. Generic content envelopes and
request/response reflection fail authentication. The expected scope must come
from the locally pending exchange and current runtime state, not unchecked relay
metadata. Ordinary encryption alone authenticates no particular account device.

`src/lib/executor_channel/channel.odin:57` additionally verifies the current
enrolled inner Bridge signature, exact record kind, identities, original input
digest and prepare/action/configuration fence correlation. Caller command
admission, receipt matching, durable deduplication and physical fence validation
remain mandatory. Historical receipts remain evidence. Enrollment requests fail
closed here until the distinct signed issuance-consent contract exists; an
account-key holder cannot use the generic primitive to mint that authority.

The TypeScript mirror is `src/ui/api/executorChannel.ts`. Shared synthetic
vectors in `src/contracts/fixtures/executor-channel-v1.json` contain public
verification keys, deterministic test ciphertext/AAD and two signed directions.
Native and TS tests compare the same bytes and reject substitutions in every
scope field, retained old epochs, wrong vault, expiry, generic-content reflection,
oversized bodies, invalid/revoked sender signatures and re-encrypted wrong
correlation. Test request/reply/content envelopes use distinct synthetic nonces.

### Channel verification

All commands used managed shell sessions and this task worktree as cwd:

```bash
nix develop --command odin test src/lib/executor_channel -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-channel-shared-final-20261107-0028
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-channel-contracts-20261107-0027
node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_channel_test.ts tests/ui_executor_contract_test.ts
npm run typecheck
python3 scripts/check-owner-aggregate-parity.py
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3-channel-bridge-20261107-0027
git diff --check
```

Native channel: **3 PASS**, `sh_97e5b83a0ae0bf80a1aa8f636ff7a767`.
Native contracts: **32 PASS**, `sh_32d96545958c1dd53d62b64b9bd258c4`.
TS channel/contracts: **8 PASS**, `sh_1a05e615276dbb16d5cd7bff22bc5556`.
Typecheck/parity/diff: PASS, `sh_8311fb81fc4375667e771631b4533698`.
Bridge build: PASS, `sh_f44c6cfe251d43b4706ed57c3591a661`.
The full owner **239 PASS** evidence above belongs to `c4dfa43d`; this step
changes no owner transaction or daemon code, so those suites were not repeated.
No new test failure was waived. No unrelated cleanup, push, deployment or live
restart occurred.

### Exact continuation for the next lease

1. Preserve this task/worktree and all checkpoint commits. Implement issuance
   consent plus actual canonical directory/trusted-root/catalog/profile
   resolution and durable reserved identity allocation. Never sign token/path
   facts solely because the caller supplied them. Current channel signed opening
   intentionally refuses enrollment requests until that contract exists.
2. Add the enrolled, sealed owner/executor relay and production request handlers
   using this channel. Resolve/recheck current directory pins at both ends;
   derive expected scope from pending saved identities. Replace injected owner
   verification only with the signed single-use fence exchange. Keep network I/O
   outside SQLite transactions and serialize physical I/O with invalidations.
3. Mount matcher/prepare/activate reconciliation and query lost replies by saved
   original identities. A committed owner grant needs exact physical failure
   disposition; a released receipt alone never proves that a child did not run
   and never justifies resource/attempt refunds.
4. Route every owner/manual/warm launch through one device ledger; integrate
   exact lifecycle/result fences, uncertain-child recovery, physical deadline
   renewal, encrypted notification/result AAD and tickets. Keep warm charges
   until trusted exact-child absence.
5. Run actual enrolled Hub/owner/executor/provider failure evidence, including
   executor crashes, duplicate deliveries and cross-owner races. Linux core
   crypto/PTY tests do not establish real provider, macOS or Windows support.
   Obtain independent and explicit user acceptance only after M3 is complete.

M3 is **unfinished**. This handoff preserves implemented, tested checkpoints and
does not submit the milestone as complete.

### Exact sealed-channel modified paths

- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/docs/executor-dispatch-checkpoint.md`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/executor.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/fixtures/executor-channel-v1.json`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/fixtures/executor-v1.json`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_channel/channel.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_channel/channel_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/executor.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/executorChannel.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tests/ui_executor_channel_test.ts`

Agent-scoped Unicode-ingress habit proposed as pending memory `mem_18e59bb1a0e1a243`; no approval was inferred or performed.

## Continuation: consent-bound issuance and host directory authority

Coordinator approvals: `msg_18e59c4d4a2d0a5d` (consent/receipt/allocation) and
`msg_18e59cad788aadb7` (host-signed local directory mappings). This checkpoint
mounts issuance only. M3 is **unfinished**.

An enrolled browser device signs `issuance_consent`, binding account, owner and
executor Bridge/key, chain/task/agent, configuration revision, operation ID,
requested-selector digest and deadline. Selectors contain provider/model,
profile, directory ID, policy revision and slot ID; caller instance, token, epoch
and path fields reject. Unicode selectors remain encrypted content; authority
envelopes stay ASCII. Native and TS schemas/canonical byte lengths share vectors
(`src/contracts/executor.odin:303`).

Host operator authority provisions immutable signed directory versions. Enabled
versions require a trusted canonical existing path. Aliases of one canonical path
share a resource key; replacement/disable requires drained old/new resources.
Historical replay cannot re-enable a mapping
(`src/lib/executor_local/directories.odin:26`). The Bridge resolver rechecks
trusted-root containment, existence and exact active catalog model/profile
(`src/bridge/executor_issuance.odin:55`). It never attests raw caller paths.

Executor V2 migration preserves V1 active resources/receipts/fences atomically.
Immutable issuance rows retain consent/selectors, generated configuration,
private random child credential and complete signed response. The response
excludes the credential, retaining its generation digest. The executor generates
instance/epoch/credential facts. Authenticated retries return original historical
bytes before fresh clock/policy/resources/incarnation checks; changed input
conflicts, and revoked device/executor keys still deny reading saved output.
Issuance creates no lease, resource reservation or child
(`src/lib/executor_local/issuance.odin:30`).

A separate signed `issuance_receipt` binds consent, configuration and enrollment
digests. Channel opening checks current enrolled keys and pending original
request/selectors. Re-encrypting another response with an account key fails.
Fresh opening checks executor incarnation; explicit historical opening retains
old facts and grants no launch rights
(`src/lib/executor_channel/channel.odin:95`).

`POST /api/v1/executor/issuance` checks user authentication, account Bridge
ownership and availability, then relays opaque bytes plus signed directory
evidence without authoritative task reads/writes
(`src/hub/transport/http/owner_local_handlers.odin:171`).
The mounted Bridge verifies account/current epoch/correlation, paired root,
durable monotonic directory pin and device consent before allocation
(`src/bridge/executor_issuance.odin:74`).
The client preserves consent across fresh encrypted transport attempts and
verifies current enrollment/request-bound replies
(`src/ui/api/executorIssuance.ts:36`).

### Verification

All commands ran through managed shell sessions with this assigned worktree as cwd:

```bash
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-issuance-native-final-20261107-0055
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-issuance-contracts-final-20261107-0100
nix develop --command odin test src/lib/executor_channel -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-issuance-channel-draft-20261107-0051
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.test_executor_issuance_resolves_signed_directory_catalog_and_profile,main.test_owner_local_executor_signer_domains_and_missing_identity -out:$HOME/.cache/heimdall-tests/m3-issuance-mounted-final-20261107-0101
nix develop --command odin test src/hub/transport/http -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=http.executor_issuance_relay_requires_user_account_and_keeps_runtime_offline_opaque -out:$HOME/.cache/heimdall-tests/m3-issuance-hub-relay-final3-20261107-0103
node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_contract_test.ts tests/ui_executor_channel_test.ts tests/ui_executor_issuance_test.ts
npm run typecheck
nix develop --command odin check src/hub -collection:odin_test=src
nix build .#ham-bridge .#ham-hub -o $HOME/.cache/heimdall-tests/m3-issuance-mounted-bins-20261107-0100
nix develop --command odin build tests/executor_crash_probe -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/m3-issuance-crash-probe-20261107-0103
nix develop --command env HEIMDALL_EXECUTOR_CRASH_PROBE=$HOME/.cache/heimdall-tests/m3-issuance-crash-probe-20261107-0103 python3 tests/test_executor_process_crash.py
python3 scripts/check-owner-aggregate-parity.py
git diff --check
```

- Executor **21 PASS**, `sh_f3d6f34dff5b248e62f39c3b51b71527`: immutable generated
  output/credential, signature/scope rejection, expired/conflicting/revoked retry,
  deferred-COMMIT rollback, V1 migration collision rollback preserving active
  resources, mapping drain/alias/history, pins and sealed pending correlation.
- Contracts **32 PASS**, `sh_dc239fd77cd4e6b390270f7551b55b75`.
- Existing channel **3 PASS**, `sh_7a20b998236959f53192f22ff0956971`; new issuance
  channel paths are covered by executor/TS tests.
- Bridge **3 PASS**, `sh_fe5bf911e7cafc48410e3a10f0e1388c`: actual filesystem/
  catalog/profile resolver; production handler with `conn=nil`, disposable paired
  keystore/root, fully signed directory, encrypted consent, host signatures,
  duplicate delivery and invalid-directory rejection. This is native handler
  coverage, **not** a real network or multi-Bridge/provider demonstration.
- Hub auth/account/offline **1 PASS**, `sh_5cc6b1c24c330520acd74ec373ea904c`.
- TS contracts/channel/client **10 PASS**, `sh_d11d658aa880bcce5367dd3a3f0f2aad`.
- Typecheck PASS, `sh_e33693e15dac4103d1f1a932266de1ab`.
- Hub check PASS, `sh_6e34d23d51ee40682986ff29a33e6ceb`.
- Hub/Bridge builds PASS, `sh_e53be3b2f93f71db2bf22d012ec3fd3e`.
- Independent Python supervisor **1 PASS / four SIGKILL boundaries**: issuance,
  prepare, activate, first dispatch (`sh_2b04b3df623c7ba52b8d68bd0153e392`).
  An independently restarted native process verifies original saved issuance/
  credential and expired historical replay. This proves isolated-ledger crash
  recovery, not provider behavior.
- Existing aggregate gate PASS: 240 fields/23 structs, 74 owner methods
  (`sh_5250a888c41e63c2a481fa802b1ea71c`).

Draft failures were corrected, not waived: quoting errors caused no writes;
Odin tuple-conditional/array/type/scope/multiline-do syntax; a reserialized test
selector needed its exact signed digest updated; a TS spread needed explicit
record typing; the old unseal proof omitted full-directory epoch commitment;
a mounted-reply check used time captured before issuance; the Hub offline fixture
still had a live hello with no vault service, causing a test segfault until
explicitly marked offline. Production verification stayed strict.
No unrelated cleanup, live restart, deployment or push occurred.

### Remaining work

Host-signed static policy/directory provisioning is validated by native APIs;
operator UI/CLI provisioning is not yet mounted. Next: actual enrolled network
issuance, owner/executor prepare/action/fence relays, matcher/outbox exact
reconciliation and committed-grant failure disposition. All manual/warm launches,
physical renewal and unknown-child recovery must use one ledger before claiming
global resource safety. Encrypted notification/results, actual provider
interrupt/Unicode delivery, macOS/Windows gates and independent/explicit user
acceptance remain outstanding.

Final dispatch audit also registers `executor_issuance` on the existing
exclusive Bridge worker queue, so filesystem/profile/SQLite work never runs on
the WebSocket reader (`src/bridge/hub_command_dispatch.odin:282`).
The mounted native test checks this production registration.
Final reruns: Bridge **3 PASS**, `sh_7f9aa41ef03377582277e19a57863d83`;
Bridge build PASS, `sh_fe8486f16045b0a0788b71759985fcf7`.
Exact commands:

```bash
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.test_executor_issuance_resolves_signed_directory_catalog_and_profile,main.test_owner_local_executor_signer_domains_and_missing_identity -out:$HOME/.cache/heimdall-tests/m3-issuance-dispatch-tests-20261107-0106
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3-issuance-dispatch-bridge-20261107-0106
git diff HEAD --check
```

### Exact issuance-checkpoint modified paths

- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/docs/executor-dispatch-checkpoint.md`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/executor_issuance.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/executor_issuance_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/hub_runtime_client.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/unseal_protocol.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/vault_v2_bridge_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/executor.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/fixtures/executor-v1.json`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/hub/app/wiring.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/hub/transport/http/owner_local_handlers.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/hub/transport/http/task_chain_search_relay_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_channel/channel.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/directories.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/directories_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/issuance.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/issuance_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/migration_002.sql`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/schema.sql`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/store.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/executor.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/executorChannel.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/executorIssuance.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tests/executor_crash_probe/main.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tests/test_executor_process_crash.py`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tests/ui_executor_contract_test.ts`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/tests/ui_executor_issuance_test.ts`

- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/hub_command_dispatch.odin`

## Continuation: immutable owner binding and sealed prepare ingress

After issuance commit `1f1c6e3e`, coordinator requested exact owner/key binding
(`msg_18e59deab83fb5e4`) and acknowledged ingress evidence
(`msg_18e59e9a3e6b41ae`). This is another bounded M3 checkpoint, not milestone
completion.

Executor V3 adds immutable account-local chain/genesis/owner Bridge/key pins.
First binding requires both a currently approved creator device signature and
the currently enrolled owner's signature. Replays retain the original genesis;
creator revocation does not rewrite previously trusted history, but the current
owner key is always mandatory. First observation after creator revocation
fails closed; no recovery consent or ownership transfer is invented
(`src/lib/executor_local/owner_binding.odin:11`).

Fresh prepare facts must match the exact configuration this executor allocated:
chain/task/instance, epoch/run/token generation, configuration/executor/policy
versions, slot/profile and canonical directory resource. The latest signed
directory mapping must still be enabled
(`src/lib/executor_local/owner_binding.odin:54`).
The Bridge rechecks actual directory/catalog/profile availability before fresh
prepare; historical receipt replay bypasses only fresh resource admission.

`POST /api/v1/executor/relay` requires a Bridge token for the immutable owner in
the canonical signed registry. It forwards the stored signed genesis plus current
signed directory evidence to the account-owned executor. It reads routing
metadata, not task eligibility or grant state
(`src/hub/transport/http/owner_local_handlers.odin:203`).
The queued exclusive executor handler verifies paired root/directory, signed
scope/command and durable owner binding before prepare/query/stop. It signs and
seals exact receipts. No network assertion is converted into
`Current_Owner_Fence`: fresh activate/heartbeat stay closed while their signed
nonce-bound exchange is unmounted
(`src/bridge/executor_exchange.odin:47`).

The shared executor directory verifier persists a fully signed newer paired log
**before** principal admission or content-epoch checks. A rejected command or
missing new content key therefore cannot allow a later older snapshot to
resurrect access (`src/bridge/executor_exchange.odin:20`). Issuance uses this
same verifier. The native test observes a valid epoch-2 log while holding only
epoch-1 content keys, verifies rejection, and then rejects the older correctly
signed log against the durable pin.

V1 and V2 ledger migrations to V3 are transactional. Genuine V2 collision
reconstruction preserves committed issuance response/credentials and active
reservations with the old incarnation; successful recovery advances the header
and incarnation exactly once. Existing physical charges and historical rows are
not rewritten.

### Exact owner-binding verification

Commands ran through managed shell sessions in the assigned task worktree:

```bash
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-owner-binding-v3-check-20261107-0116
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.test_executor_issuance_resolves_signed_directory_catalog_and_profile,main.test_owner_local_executor_signer_domains_and_missing_identity -out:$HOME/.cache/heimdall-tests/m3-owner-binding-mounted-draft2-20261107-0119
nix develop --command odin test src/hub/transport/http -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=http.executor_issuance_relay_requires_user_account_and_keeps_runtime_offline_opaque,http.executor_resource_relay_requires_exact_registered_owner_bridge -out:$HOME/.cache/heimdall-tests/m3-owner-binding-hub-20261107-0119
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-owner-binding-contracts-final-20261107-0121
nix develop --command odin test src/lib/executor_channel -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-owner-binding-channel-final-20261107-0121
node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_contract_test.ts tests/ui_executor_channel_test.ts tests/ui_executor_issuance_test.ts
npm run typecheck
nix develop --command odin check src/hub -collection:odin_test=src
nix build .#ham-bridge .#ham-hub -o $HOME/.cache/heimdall-tests/m3-owner-binding-bins-20261107-0119
nix develop --command odin build tests/executor_crash_probe -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/m3-owner-binding-crash-probe-20261107-0121
nix develop --command env HEIMDALL_EXECUTOR_CRASH_PROBE=$HOME/.cache/heimdall-tests/m3-owner-binding-crash-probe-20261107-0121 python3 tests/test_executor_process_crash.py
python3 scripts/check-owner-aggregate-parity.py
git diff HEAD --check
```

| Check | Outcome / managed session |
|---|---|
| Executor, including V1/V2 migration and immutable owner/configuration gates | **24 PASS**, `sh_cc6f98b652a1be3c901dc6a7365943f7` |
| Bridge mounted issuance + distinct enrolled owner ingress, resolver and signer | **3 PASS**, `sh_8e2cdfbf26a2663a5f3bfe3ea25d1a1b` |
| Hub issuance/resource relay authorization | **2 PASS**, `sh_0d288a9547bf4ade2ebe5e7167fa5820` |
| Native shared contracts | **32 PASS**, `sh_4315051ca4770a011ec7eccd8efcea16` |
| Native channel core | **3 PASS**, `sh_a8ddf0e01b102415785cac611ebf80b5` |
| TS contracts/channel/client | **10 PASS**, `sh_9dc84babbb7c0cd2eb3e8f29670bbca8` |
| Typecheck | PASS, `sh_e227f0b971db642f1c3bb75089463c80` |
| Hub compilation | PASS, `sh_e77da6bdbb61ebcbdd7241025a5b0328` |
| Hub and Bridge package builds | PASS, `sh_0dd5274924c8ddf5a55dcc086646abd9` |
| Rebuilt V3 independent SIGKILL supervisor, four boundaries | **1 test PASS**, `sh_015578ef26fcca371d6b1aaf33369ccb` |
| Existing aggregate gate | PASS, 240 fields/23 structs/74 owner methods, `sh_c253473aecc9a07edeaa6868c2439653` |

The expanded Bridge test exercises real P256 owner and executor keys enrolled
under the disposable paired root, signed genesis, actual filesystem/profile/
catalog lookup and production handler calls: prepare, duplicate historical
receipt, exact query, prepared stop, and rejected activation with **zero launch
intents**. These calls use `conn=nil`; the Hub checks are authenticated handler
regressions. This is **not** a real enrolled multi-Bridge network, provider
execution, macOS or Windows pass.

Draft corrections were confined to multiline Odin syntax, a missing test import,
and an overbroad test expectation replacement that accidentally changed a
distinct-identity count from two to three. All reported final checks pass.
No unrelated cleanup, live restart, deployment or push occurred.

### Continuation constraints for owner outbound outbox wiring

1. Preserve this commit series and the task worktree; no candidate-history merges.
2. Mount a dedicated owner executor worker. Snapshot/claim under the owner mutex,
   release before network I/O, then reacquire and recheck exact claim, paired
   directory, original request and current fence before committing outcomes.
   The existing registry publisher runs while `bridge_owner_mutex` is held
   (`src/bridge/owner_local_leases.odin:101`, `src/bridge/owner_local.odin:49`).
   Reusing it for a synchronous activation/fence callback would deadlock.
   Do not wait for that callback from an exclusive Bridge dispatch job either.
3. Preserve completion persistence retry behavior and saved original prepare/
   action/reservation identities. Do not regenerate unknown-outcome operations.
   Preparations have a 30-second TTL; the existing 30-second maintenance cadence
   cannot be relied upon for timely first dispatch.
4. Mount the signed one-use owner fence challenge/reply before admitting fresh
   activate/heartbeat or auto-committing owner grants. The verified fence must
   be consumed and rechecked with local invalidations before physical I/O.
5. Add exact committed-grant failure disposition: a released receipt alone never
   proves a child did not run and never authorizes refunds or failure-charge
   suppression. Provision operator policy/mappings through an actual operator
   path and demonstrate real enrolled network recovery, not only these handlers.
6. Complete manual/warm/global admission, unknown-child reconciliation, physical
   deadline renewal, encrypted notification/results and actual provider/platform
   gates before final independent and explicit user acceptance.

M3 remains **unfinished**. No task submission or acceptance is claimed.

### Exact owner-binding checkpoint modified paths

- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/docs/executor-dispatch-checkpoint.md`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/executor_exchange.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/executor_issuance.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/executor_issuance_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/hub_command_dispatch.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/hub_runtime_client.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/executor.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/contracts/fixtures/executor-v1.json`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/hub/app/wiring.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/hub/transport/http/owner_local_handlers.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/hub/transport/http/task_chain_search_relay_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/issuance_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/migration_003.sql`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/owner_binding.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/owner_binding_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/schema.sql`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/executor_local/store.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/ui/api/executor.ts`
