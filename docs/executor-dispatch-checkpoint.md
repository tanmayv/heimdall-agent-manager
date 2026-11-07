# M3 continuation: executor dispatch checkpoint

**Current continuation status (2026-11-07):** automatic exact activation,
bounded reconciliation, executor-local readiness, and production signed physical
deadline renewal are implemented. Continue at
[Signed physical renewal](#signed-physical-renewal-2026-11-07-continuation)
for renewal evidence, then [Local admission foundation](#local-admission-foundation-2026-11-07-continuation)
for the admission foundation, then
[M3a durable draft and authenticated cancellation](#m3a-durable-draft-and-authenticated-cancellation-checkpoint-2026-11-07)
for the latest partial checkpoint and remaining work. Earlier sections
preserve historical checkpoints; their unfinished renewal lists are superseded.
**Full M3 acceptance remains incomplete.**

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

### Attempt 4: isolated owner executor outbox worker

Coordinator scope is recorded in `cmt_18e59f4bd7ff7274` and
`msg_18e59f4d5dd43458`: implement the dedicated owner executor worker and its
concurrency/retry evidence, then commit this bounded checkpoint. **M3 remains
unfinished; this checkpoint is not a task submission or acceptance.**

The owner publisher now claims only registry/control/source/merge effects
(`src/bridge/owner_local.odin:49`). Consumer selection precedes the claim limit,
so more than one batch of executor work cannot starve registry delivery;
unrecognized kinds remain pending (`src/lib/owner_local/outbox.odin:38`).
Invalidated claims reject both successful and failed late completions
(`src/lib/owner_local/outbox.odin:90`).

The dedicated worker is started independently of the maintenance/dispatch jobs
(`src/bridge/main.odin:279`, `src/bridge/owner_local_executor.odin:243`).
It claims one activation effect under the owner mutex, snapshots the immutable
accepted executor key and original signed action, releases the mutex for HTTP,
then reacquires it for exact claim and response checks
(`src/bridge/owner_local_executor.odin:54`,
`src/bridge/owner_local_executor.odin:115`,
`src/lib/owner_local/completions.odin:74`). The exchange callback has no Store
parameter. It retains the original operation/reservation/action bytes; each
attempt's transport request ID is correlation only. HTTP attempts are bounded by
the original signed request deadline
(`src/bridge/owner_local_executor.odin:130`).

One bounded retained item owns its strings beyond temporary allocator resets.
Read failures preserve the opaque response without repeating I/O. Statement or
COMMIT failures preserve the interpreted completion and full dispatch snapshot;
every persistence retry rechecks the exact claim. Failed/unknown external
outcomes retry the same effect after the durable floor
(`src/bridge/owner_local_executor.odin:59`).

Response verification observes a newer genuinely signed paired log before
peer/keyring admission, rejects directory rollback, checks the assigned enrolled
key and original encrypted scope/signature, and rechecks the current owner fence
and vault generation (`src/bridge/owner_local_executor.odin:175`,
`src/bridge/owner_local_executor.odin:199`). Completion is delivery evidence;
it grants no lease, renews no deadline and supplies no refund/failure disposition.

#### Exact checkpoint verification

All commands ran through `ham-ctl shell run --cwd` with workdir
`/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c`:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-worker-owner-full-20261107-0141
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_owner_executor_worker_retains_response_and_completion_across_storage_failures,main.test_owner_executor_worker_allows_concurrent_owner_callback_and_fences_late_reply,main.test_owner_executor_worker_unknown_outcome_retries_original_claim_after_floor,main.test_owner_executor_worker_rechecks_route_after_result_persistence_failure,main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.test_owner_local_publication_recovers_result_write_and_commit_failure_in_process,main.test_owner_local_periodic_batch_expires_and_publishes_after_commit -out:$HOME/.cache/heimdall-tests/m3-worker-final4-20261107-0147
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3-worker-bridge-final-20261107-0147
git diff HEAD --check
```

- Full owner-local suite: **241 PASS**, session `sh_2c645cc5f99d241e055efb2a5c465de6`.
- Final focused Bridge suite: **7 PASS**, session `sh_564282c1c9f4e5db2111b6b3014672df`.
- Final Bridge package build: **PASS**, session `sh_5cca9d751037cfd263e018003c190203`.
- Earlier focused consumer tests: **2 PASS**, included again in the full suite.
- No shared wire/schema, UI, Hub or Rust changes; their unrelated builds/suites
  were deliberately skipped. No macOS/Windows/provider or enrolled-network pass
  is inferred from these Linux tests.

The concurrency test uses an actual second thread while owner callbacks acquire
the mutex, with overlapping ticks refused. It tests ordinary completion,
append-only invalidation and owner-store restart during I/O
(`src/bridge/owner_local_executor_test.odin:112`). Fault tests reset the temporary
arena, retain responses through a failed recheck, and inject statement and
deferred-COMMIT failures without reopening or redelivering
(`src/bridge/owner_local_executor_test.odin:78`). Tests preserve original retry
identities and verify that claimed route/fence rewrites are already rejected by
the transition guard (`src/bridge/owner_local_executor_test.odin:161`,
`src/bridge/owner_local_executor_test.odin:180`).
The extended production directory helper test uses real paired P256 signatures,
rejects another enrolled assignment key and refuses an older response after
observing a newer content-key rotation
(`src/bridge/executor_issuance_test.odin:226`).

Draft corrections: multiline Odin `do` syntax, Tick/Duration arithmetic, and a
test's incorrect assumption that claimed row metadata could be rewritten. The
corrected test explicitly checks the existing transition rejection. All final
checks pass. No unrelated cleanup, live restart, deployment or push occurred.

#### Remaining M3 integration

The mounted worker consumes **committed activation intents only**. The current
executor action handler still denies fresh activation/heartbeat without its
signed nonce callback (`src/bridge/executor_exchange.odin:112`). This checkpoint
does not mount outbound prepare/query recovery, create automatic owner grants,
provision operator policy, reconcile committed-grant failure, run physical PTY
dispatch or demonstrate an enrolled multi-Bridge network. These are explicit
continuation items, not evidence supplied by the injected worker transport tests.

Continue by mounting signed nonce request/reply and executor activation context
before opening fresh activation, and add owner prepare/retry/query using the
original journal identities. Preserve snapshot -> unlocked I/O -> exact recheck;
do not wait on a fence callback inside an exclusive Bridge command job. Keep
exact physical charges until trusted child evidence; a released receipt alone
does not prove no child ran. Then finish operator provisioning, actual enrolled
network/lost-reply/crash evidence, shared manual/warm admission, encrypted
notifications/results, real provider/platform gates, and the independent plus
explicit user review required by the full milestone.

#### Exact modified paths

- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/docs/executor-dispatch-checkpoint.md`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/main.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/owner_local.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/owner_local_executor.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/owner_local_executor_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/bridge/executor_issuance_test.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/completions.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/outbox.odin`
- `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e556f90cfa1e9c/src/lib/owner_local/outbox_consumers_test.odin`

### Attempt 5: reverse encrypted owner fence ingress

The nonce callback has an authenticated reverse relay at
`POST /api/v1/executor/fence`. Account Bridge authentication may route only to
the immutable registered chain owner. The forwarded executor Bridge identity
comes from that authenticated token, not the encrypted request
(`src/hub/transport/http/owner_local_handlers.odin:207`). The owner additionally
checks the enrolled executor signature, exact encrypted channel scope and
current claimed activation intent. The paired-directory observation is durable
before key admission (`src/bridge/owner_executor_fence.odin:24`).

The callback runs as a short Interactive command without the executor exchange's
Bridge ordering key (`src/bridge/hub_command_dispatch.odin:282`). It performs
neither network I/O nor outbox publication while holding the owner mutex.
`execution_fence_channel_reply` authenticates and signs the existing nonce
protocol, returns encrypted output and preserves the saved request scope
(`src/lib/owner_local/execution_channel.odin:13`). It does not create a grant,
renew a deadline or supply physical execution evidence.

All commands below ran through managed shell sessions in this task worktree:

```bash
nix develop --command odin check src/bridge -collection:odin_test=src
nix develop --command odin check src/hub -collection:odin_test=src
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=owner_local.owner_execution_encrypted_callback_binds_claim_and_rejects_account_key_forgery -out:$HOME/.cache/heimdall-tests/m3-fence-channel2-20261107-0202
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection -out:$HOME/.cache/heimdall-tests/m3-fence-mounted-20261107-0202
nix develop --command odin test src/hub/transport/http -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=http.executor_resource_relay_requires_exact_registered_owner_bridge -out:$HOME/.cache/heimdall-tests/m3-fence-hub-20261107-0200
nix build .#ham-bridge .#ham-hub -o $HOME/.cache/heimdall-tests/m3-fence-ingress-bins-20261107-0203
git diff --cached --check
```

Both compile checks and package builds passed. Focused tests passed: owner
encrypted callback **1** (`sh_8bd8a46ed4dfb635d7a14d3425c34e86`), Bridge
paired-directory/dispatcher **1** (`sh_d23ca81e4c9b08d92736d77b729704b4`), Hub
relay authorization **1** (`sh_80e759023cf7a07ad57470be4d593e3c`). Build session:
`sh_da049e10751951fb5345edeb08f00a04`. The callback test uses genuine P256
executor/owner signatures and channel encryption, consumes the executor nonce
once, rejects account-key forgery and invalidated claims, and verifies unchanged
owner state. The Bridge test verifies callback dispatcher independence and
paired-directory rollback denial; it does not exercise a real network callback.
Full owner regression session `sh_93d4c91819ac4abbd9fd57e5fe00fec3` subsequently
passed **242 tests** in 2m28s, with no reported memory errors.

Draft corrections: multiline Odin `do` syntax and test `expect_value` message
arguments were corrected before the passing checks. No shared record schema,
UI, Rust or provider behavior changed. Platform/provider suites were skipped
because no support claim is made. Fresh activation remains closed in the
executor handler until the outbound challenge and exact activation context are
mounted. This ingress checkpoint is not M3 completion or submission.

Modified paths (all under the Workdir stated above):

- `src/bridge/owner_executor_fence.odin`
- `src/bridge/executor_issuance_test.odin`
- `src/bridge/hub_command_dispatch.odin`
- `src/bridge/hub_runtime_client.odin`
- `src/hub/app/wiring.odin`
- `src/hub/transport/http/owner_local_handlers.odin`
- `src/hub/transport/http/task_chain_search_relay_test.odin`
- `src/lib/owner_local/execution_channel.odin`
- `src/lib/owner_local/execution_channel_test.odin`
- `docs/executor-dispatch-checkpoint.md`

### Attempt 5: mounted outbound nonce activation

Coordinator approved separate bounded General_IO activation routing in
`msg_18e5a0e1449cf98f`, and authorized a formal M3-2 continuation in
`msg_18e5a15ce4f83ba9`. This is a concrete checkpoint, not full M3 acceptance.

The strict native/TypeScript `activation_exchange` contract adds encrypted
claim id/attempt context without changing existing exchange records
(`src/contracts/executor.odin:28`, `src/ui/api/executor.ts:16`). The owner worker
sends its original signed action and claimed intent identity to the new
`/api/v1/executor/activate` route (`src/bridge/owner_local_executor.odin:151`).
Hub authentication remains immutable-owner-only; it selects the separate
activation command without acquiring task authority
(`src/hub/transport/http/owner_local_handlers.odin:246`).

The executor activation command uses General_IO with no Bridge ordering key
(`src/bridge/hub_command_dispatch.odin:286`). Ordinary receipt replay does not
call the owner again. Fresh activation creates a random signed nonce, releases
the executor mutex for bounded HTTP, then reacquires it and verifies current
paired directory/self/owner binding. It consumes the one-use reply and repeats
ledger admission, including incarnation, expiry and state guards
(`src/bridge/executor_exchange.odin:117`). The callback HTTP function receives
no Store pointer and uses the nonce expiry as its retry deadline
(`src/bridge/executor_fence_client.odin:24`). The legacy exchange and fresh
heartbeat remain fail-closed without this activation nonce path. This opens
ledger activation only; no physical launch worker or deadline renewal is
mounted by this change.

Commands ran through managed shell sessions in the same assigned Workdir:

```bash
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-nonce-contracts-20261107-0208
node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_contract_test.ts tests/ui_executor_channel_test.ts tests/ui_executor_issuance_test.ts
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.test_owner_executor_worker_retains_response_and_completion_across_storage_failures,main.test_owner_executor_worker_allows_concurrent_owner_callback_and_fences_late_reply,main.test_owner_executor_worker_unknown_outcome_retries_original_claim_after_floor,main.test_owner_executor_worker_rechecks_route_after_result_persistence_failure -out:$HOME/.cache/heimdall-tests/m3-nonce-mounted3-20261107-0212
nix develop --command odin test src/hub/transport/http -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=http.executor_resource_relay_requires_exact_registered_owner_bridge -out:$HOME/.cache/heimdall-tests/m3-nonce-hub-20261107-0212
npm run typecheck
nix build .#ham-bridge .#ham-hub -o $HOME/.cache/heimdall-tests/m3-nonce-bins-20261107-0214
git diff --cached --check
```

| Check | Outcome / session |
|---|---|
| Shared native wire vectors including activation context rejection | **32 PASS**, `sh_f18e1cf89aef0b881e437ab88857701c` |
| Mirrored TS contract/channel/issuance | **10 PASS**, `sh_605a7abbbbda9a61c857a5dd8e4bd2f5` |
| Production activation ingress plus retained worker fault/concurrency regressions | **5 PASS**, `sh_438428b0c5f9d555c156a237e0cdbb18` |
| Hub resource/reverse fence/activation relay authorization | **1 PASS**, `sh_d89e6f80df99e105ee7f1ff62d10aca4` |
| Typecheck | PASS, `sh_e889a4c9d4ee84a39b473d19bc366a7a` |
| Hub + Bridge packages | PASS, `sh_994e6457362765cd7079b5b05aef308a` |

The expanded mounted ingress regression injects the callback transport but
uses genuine owner signatures, channel encryption, production challenge signing
and the real SQLite ledger. It verifies cancellation while the mutex is
released, successful activation, duplicate historical replay without another
callback/launch, and actual ledger close/reopen during the callback followed by
stale-incarnation rejection (`src/bridge/executor_issuance_test.odin:228`).
Trusted test-daemon absence is used only to drain the test charge between cases;
no physical provider or real network absence evidence is inferred.

An initial activation regression exposed the narrower `bridge_executor_sign`
wrapper rejecting `fence_request` despite the inner signer allowing it. Added
that specific signing domain (`src/bridge/executor_issuance.odin:36`), then the
mounted activation test passed; the final expanded five-test run also passes.
This failed draft did not authorize activation or create a launch intent.
No live restart, deploy or push occurred.

#### M3-2 continuation requirements

Preserve both Attempt 5 commits on this task branch. Mount owner preparation
initiation and prepare/query/retry reconciliation from the original journal
documents. There is currently no production caller of
`execution_prepare_start` (`src/lib/owner_local/execution.odin:58`); maintenance
only expires preparations (`src/bridge/owner_local_leases.odin:113`). Do not
invent new unknown-outcome reservation/operation identities. Preserve opaque
response retention across read/result-COMMIT failures, exact post-I/O
rechecks, current directory observations and original operation deadlines.

Then complete device operator budget/mapping provisioning, shared manual/warm
admission, physical launch/input/stop/result fencing and bounded child deadline
renewal, unknown-child reconciliation, committed-grant failure disposition,
encrypted PTY notification/result tickets and actual enrolled lost-reply/crash/
cross-owner evidence. A released reservation or expired owner lease still does
not prove that a child never ran or authorize refunds. Real Linux/macOS
provider interrupt/Unicode-paste and bounded Windows gates need explicit
evidence or honest unsupported limits. Complete independent and explicit user
review before full M3 acceptance. The network client itself has compilation
coverage here; injected callbacks do not establish its enrolled end-to-end pass.

Modified paths, relative to the same absolute Workdir:

- `src/bridge/executor_exchange.odin`
- `src/bridge/executor_fence_client.odin`
- `src/bridge/executor_issuance.odin`
- `src/bridge/executor_issuance_test.odin`
- `src/bridge/hub_command_dispatch.odin`
- `src/bridge/hub_runtime_client.odin`
- `src/bridge/owner_local_executor.odin`
- `src/contracts/executor.odin`
- `src/contracts/fixtures/executor-v1.json`
- `src/hub/app/wiring.odin`
- `src/hub/transport/http/owner_local_handlers.odin`
- `src/hub/transport/http/task_chain_search_relay_test.odin`
- `src/ui/api/executor.ts`
- `docs/executor-dispatch-checkpoint.md`

## M3-2 continuation checkpoint — 2026-11-07

Workdir: `/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e5a16377e1ae67`.
Coordinator authorized transplantation of this chain's linear M3 checkpoints
through `660ad79b` in `msg_18e5a19acce4ec40`. Their new lineage is
`4c649e4c..fddffbd2`, based on `813ef994`. No external candidate-history
merge, shared checkout change, live restart, deployment or push occurred.

### Concrete additions

- Retained existing linked-content V25 migration and native/TS schemas. The
  executor journal now follows it as V26
  (`src/lib/owner_local/migrations.odin:3`,
  `src/lib/owner_local/migration_026.sql:1`). Historical upgrade fixtures
  reconstruct both additions correctly; old runtime identity, receipt and
  live-capability regression coverage remains in the combined suite.
- Accepted remote assignments initiate signed prepare and lease documents with
  deterministic reservation/operation identities, persisted before I/O.
  A restart reuses the saved documents, and the old owner incarnation fails
  closed (`src/lib/owner_local/execution_prepare.odin:12`).
- A fixed signed query and the exact signed prepare receipt are durably stored
  before query I/O. The original preparation deadline remains binding.
  Query evidence is checked even when the original prepare receipt is fresh
  (`src/lib/owner_local/execution_prepare.odin:75`,
  `src/lib/owner_local/execution.odin:124`).
- The existing executor worker now runs bounded preparation scanning and a
  separate retained-response delivery worker. It holds no owner mutex across
  HTTP. Runtime allocation preserves opaque response bytes through request
  allocator resets and failed local admission reads
  (`src/bridge/owner_local_preparation.odin:19`, `:52`).
  Scanning admits one outstanding preparation at a time and rotates past
  inadmissible assignments.
- The transport seals prepare/action scopes separately and selects the existing
  relay endpoint for prepare/query and the nonce-protected activation endpoint
  for activate (`src/bridge/owner_local_executor.odin:131`). Receipt processing
  still verifies the current paired directory, exact pinned executor key,
  signed request correlation, owner readiness and post-I/O cancellation fences.

### Verification

All commands below ran in the Workdir above through managed shell sessions.
`-out:` paths are unique and below `$HOME`.

| Command | Result / session |
|---|---|
| `nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-owner-import2-20261107-0218` | 253 PASS; `sh_76907213bef5cddc97717bbc6424f15b` |
| `nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-prep-owner-full-20261107-0225` | 256 PASS; `sh_eb6df0dd1355a5dddd9559e75913d54a` |
| `nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-contracts-20261107-0226` | 33 PASS; `sh_a1e0462cd55135f60350c5619989e5b4` |
| `nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-executor-20261107-0226` | 24 PASS; `sh_f956041b461668b6f523deba5f1778cd` |
| `node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_contract_test.ts tests/ui_executor_channel_test.ts tests/ui_executor_issuance_test.ts` | 10 PASS; `sh_e39f68381d81925e084e24b6bd758404` |
| `nix develop --command npm ci --ignore-scripts --no-audit --no-fund && npm run typecheck` | PASS; `sh_ab0671f0e5fe0dd40dd7bfefab945396` |
| `nix build .#ham-bridge .#ham-hub -o $HOME/.cache/heimdall-tests/m3b-prep-bins-20261107-0227` | PASS; `sh_b4ec11e0f4e0be7a74348d955cbec8a0` |

The final focused Bridge command is:

```bash
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_owner_preparation_worker_retains_response_across_temp_reset_and_storage_retry,main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.test_owner_executor_worker_retains_response_and_completion_across_storage_failures -out:$HOME/.cache/heimdall-tests/m3b-prep-bridge3-20261107-0228
```

It passed all 3 tests (`sh_f67f23447c1742aebffca73ae80a3946`).
The owner additions cover lost prepare replies, immutable query replay,
query-write rollback, query/request substitution rejection, exact grant commit,
owner restart without replacement reservation, and signed task cancellation.
The Bridge orchestration test injects transport/admission callbacks to verify
mutex release, retained-response storage retry and allocator lifetime. The
mounted ingress test uses production encryption/signatures/ledger behavior.
Neither establishes enrolled real-network or provider launch behavior.

Failed drafts: initial V25 test expectations and historical reconstruction
fixtures were incompatible with the combined branch; fixed before 253/256-pass
runs. New Odin multiline `do` drafts were corrected before passing compilation.
The first cancellation regression attempted a forbidden raw fleet update;
replaced with a signed `task.cancel` command. Two editing scripts had Python
quoting errors and made no changes. Initial typecheck lacked the known pinned
`posthog-js` dependency; lockfile-based npm installation fixed it without
dependency-manifest changes.

### Remaining acceptance work

This is a preparation checkpoint, not full M3-2 acceptance. Physical process
launch, shared manual/warm admission, budget/mapping provisioning, encrypted
PTY delivery/results, bounded child deadline renewal and real enrolled
lost-reply/crash/cross-owner evidence remain to be implemented or verified.

Issued instances/credentials are executor-local
(`src/lib/executor_local/issuance.odin:78`, `:105`); existing prespawn bootstrap
fetch expects a Hub instance (`src/bridge/bootstrap_prespawn.odin:47`), and the
current authoritative lease handler expects a live local owner child
(`src/bridge/owner_local_leases.odin:55`). Coordinator clarification was requested
in `msg_18e5a256cceec1ad` before introducing the owner-rendered sealed bootstrap
and executor-attested remote child relay boundary. No Hub registration or task
authority shortcut was introduced.

Coordinator platform guidance in `msg_18e5a19acce4ec40`: run real execution/PTY
integration on Linux, verify Darwin interrupt/paste behavior through
unit/contracts, document explicit Windows limits. No macOS or Windows host is
provisioned; no real-provider, Darwin runtime or Windows runtime pass is claimed
by this checkpoint.

### Follow-up evidence and confirmed continuation boundary

Coordinator confirmed the owner-rendered/signed sealed bootstrap and
executor-attested child relay in `msg_18e5a26de2522317` /
`cmt_18e5a26cc02ea57b`. No further permission is needed for that implementation
within this task. The Hub must remain encrypted transit only. The requested
next slice is executor admission, sealed bootstrap prespawn and encrypted PTY
delivery with Linux/Darwin profiles and isolated loopback/mock integration.

Actual POSIX SIGKILL evidence also passed on this checkpoint:

```bash
nix develop --command sh -c 'odin build tests/executor_crash_probe -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/m3b-crash-probe-20261107-0230 && HEIMDALL_EXECUTOR_CRASH_PROBE=$HOME/.cache/heimdall-tests/m3b-crash-probe-20261107-0230 python3 tests/test_executor_process_crash.py'
```

Session `sh_6a72ad04b8c8509ddb048af66cbf55fb`: **1 test PASS**, covering
four committed boundaries (issuance, preparation, activation and claimed launch).
This proves isolated ledger recovery across actual process death, not a provider
or physical bootstrap launch.

The final Bridge three-test run passed after adding the failed-current-read
retention assertion; typecheck passed after the pinned dependency installation.
No dependency manifest or lockfile changed. No unrelated cleanup was performed.

## M3-2 bootstrap continuation (2026-11-07, checkpoint fdc0b675 + writer)

This remains an incomplete M3-2 checkpoint. No production physical-launch or
remote child relay acceptance is claimed.

- `src/contracts/executor_child.odin:8` defines owner-signed bootstrap content,
  bootstrap metadata and executor-signed child requests. Matching requires exact
  prepare/action/configuration/body/child/deadline identities. Current-owner and
  exact-live-child checks remain required at callers.
- `src/lib/executor_local/bootstrap.odin:14` accepts bootstrap content only
  against a locally committed activation receipt, exact local issuance and a
  freshly obtained bilateral owner proof. The immutable executor V4 table
  retains historical output; replay does not produce new launch authority.
- `src/lib/executor_local/bootstrap.odin:60` returns local credentials only for
  an exact live, undispatched launch claim in this serving incarnation.
- `src/bridge/executor_bootstrap.odin:15` resolves the current local provider
  profile and mapping, then prepares a Spawn request from accepted content.
  `src/bridge/executor_bootstrap.odin:54` writes fixed bootstrap files and
  locally selected skill paths, generating the CLI shim locally. The caller
  must own the startup I/O mutex and still perform fresh dispatch admission.
  A process whose dispatch already crossed the durable boundary must only be
  queried; it must never have its run directory cleaned again.
- Production signer allowlists now include the separate bootstrap/child-request
  domains (`src/bridge/unseal_protocol.odin:851`,
  `src/bridge/executor_issuance.odin:36`).

Verification, all through managed shells in the task Workdir:

| Exact command | Result |
|---|---|
| `nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-bootstrap-content-contracts-20261107-0248` | 36 PASS; sh_52933d3bd1ebae39129b68876301c65e |
| `nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-bootstrap-content-ledger-20261107-0248` | 27 PASS; sh_11ec1b1726bcdc01ceb26435c8a9cc25 |
| `node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_child_test.ts tests/ui_executor_contract_test.ts tests/ui_executor_channel_test.ts tests/ui_executor_issuance_test.ts` | 14 PASS; sh_35be65d64bb6e065a2498aa63d15a2c7 |
| `npm run typecheck` | PASS; sh_39b14c0c73721a80cb965a8886103700 |

Focused Bridge command (3 PASS; sh_a93f5529512a3e20ccb041abae2f8d32):

```bash
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_executor_bootstrap_materializes_owner_content_without_hub_and_local_shim,main.test_executor_bootstrap_denies_content_substitution_and_planted_root_symlink,main.test_owner_local_executor_signer_domains_and_missing_identity -out:$HOME/.cache/heimdall-tests/m3b-bootstrap-writer3-20261107-0248
```

Earlier durable-store checkpoint fdc0b675 passed the production Bridge build:
`nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3b-bootstrap-bins-20261107-0242`
(sh_92549d43ccb08ad6ec7bcfba10536346). It predates the prespawn writer.

Draft failures corrected: Odin multiline-do and variable-index literal syntax;
file APIs return os.Error rather than bool; the writer test initially lacked
a local provider catalog and correctly failed closed. No production fallback
was added. An empty-map test helper originally lost its map header; direct
initialization fixed the fixture. No unrelated cleanup.

Remaining: durable owner-rendered bootstrap snapshot tied to the original
activation identity; encrypted exchange ingress/egress mounting; worker
prespawn/launch/query/stop and exact-child token/relay auth; bounded renewal;
shared manual/warm admission and provisioning; encrypted PTY ticket/results;
Linux actual execution and Darwin contract profiles, documented Windows bounds.

## M3-2 durable owner snapshot and encrypted ingress (2026-11-07)

This supersedes the preceding remaining-work list for bootstrap snapshot and
ingress only. **M3-2 is still incomplete; do not submit it as accepted.**

`src/lib/owner_local/execution_bootstrap.odin:12` persists the first owner-signed
bootstrap under the exact current activation claim. Owner migration V27 retains
it separately from the source grant. The body includes complete current
requirements, the existing capability and bounded derived context; creating it
does not create another lease/attempt or acknowledge requirements. Replays use
the same original metadata, bytes and deadline. Current owner incarnation and
assignment admission still apply before replay.

`src/bridge/owner_local_executor.odin:127` now snapshots this content before I/O
and sends it inside the existing encrypted activation relay. The owner snapshot
buffer is wiped when released. This call currently provides minimal worker
instructions and no memories/skills; the native renderer accepts trusted
owner-provided instruction/memory/skill content for future richer provisioning.

`src/bridge/executor_exchange.odin:70` accepts a separate strict
`activation_bootstrap_exchange` content contract, retaining the existing signed
action, paired-directory checks, consumed owner challenge and current executor
incarnation. `src/bridge/executor_exchange.odin:144` persists bootstrap content
against the exact locally committed activation before replying. Case-folded
duplicate skill names are rejected for Darwin/Windows filesystem compatibility.

### Verification

All commands ran through managed shell in the task Workdir. No Hub task authority
or legacy bootstrap registration was introduced.

| Command | Result |
|---|---|
| `nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-owner-bootstrap-full-20261107-0259` | 259 PASS; sh_af10a98105018803a161be87ef5768a0 |
| `nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-final-contracts-20261107-0303` | 36 PASS; sh_d3de1b24f6c85333dc4fb1f62c338a98 |
| `node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_child_test.ts tests/ui_executor_contract_test.ts tests/ui_executor_channel_test.ts tests/ui_executor_issuance_test.ts` | 14 PASS; sh_f937178704dac605a4ed825752ce872d |
| `npm run typecheck` | PASS; sh_596187bad9187ce49428ce668da09ad5 |
| `nix build .#ham-bridge .#ham-hub -o $HOME/.cache/heimdall-tests/m3b-ingress-bins-20261107-0303` | PASS; sh_018cc2da1a4bd1265df0f533141bd460 |
| `nix build .#ham-pty-host -o $HOME/.cache/heimdall-tests/m3b-bootstrap-pty-20261107-0300` | PASS; sh_ca50da6b2aa3802c6d49e8977e6ab151 |

Four focused Bridge tests (mounted encrypted ingress, writer, planted-root
rejection and signer domains) passed with:

```bash
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.test_executor_bootstrap_materializes_owner_content_without_hub_and_local_shim,main.test_executor_bootstrap_denies_content_substitution_and_planted_root_symlink,main.test_owner_local_executor_signer_domains_and_missing_identity -out:$HOME/.cache/heimdall-tests/m3b-bootstrap-ingress-20261107-0258
```

Session: sh_21f5e789766d41247f0005daf4123a3f.

The final Linux **actual PTY child** integration also passed (1 test,
sh_d5213838d0cd894140331ff02e780f58):

```bash
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-bootstrap-pty-20261107-0300/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection -out:$HOME/.cache/heimdall-tests/m3b-bootstrap-real-child-20261107-0301
```

It uses production signed issuance, encryption and ingress, then explicitly
connects the accepted local bootstrap to a real daemon running `sh`. It proves
exact child presence, duplicate-dispatch rejection, no rematerialization after
dispatch, unchanged PID on replay, exact stop and observed absence. The owner
network/check transport is injected. It is **not** an actual provider execution,
a full-network enrollment demonstration or automatic production dispatch.

Actual POSIX process-death ledger evidence was rerun against the new source
(1 PASS, four committed boundaries; sh_4999c47904d36f0d6e243344438e22ed):

```bash
nix develop --command sh -c 'odin build tests/executor_crash_probe -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/m3b-bootstrap-crash-probe-20261107-0304 && HEIMDALL_EXECUTOR_CRASH_PROBE=$HOME/.cache/heimdall-tests/m3b-bootstrap-crash-probe-20261107-0304 python3 tests/test_executor_process_crash.py'
```

Owner tests cover genuine V26→27 collision rollback/recovery, preservation of
activation bytes/identity, failed COMMIT, original snapshot replay, current
incarnation and no additional grant/attempt. Historical-schema fixtures now drop
the dependent bootstrap table and assert V27. Draft fixes: test requirements
must be installed by a signed requirements.edit before bootstrap (the old lease
fixture intentionally had none); a map-encoded response reordered wrapper keys
on replay, fixed with a stable struct. A mistaken broad test-version replacement
temporarily changed native-history record counts; reverted before final passing
259-test run. No unrelated cleanup.

### Precise continuation boundaries

1. **Automatic physical dispatch is still unmounted.** The production handler
   replies with a resource receipt after bootstrap acceptance
   (`src/bridge/executor_exchange.odin:149`). It does not call
   `bridge_executor_prepare_spawn` or `bridge_executor_dispatch`. Connect the
   physical launch/query before acknowledging the original activation outbox, or
   introduce a separately verified current launch fence with contracts/tests.
   The existing owner activation callback requires the original claimed outbox;
   after owner acceptance settles it, that same callback cannot authorize a new
   launch. Prefer finishing physical dispatch before the receipt acknowledgement.
2. A lost physical spawn reply must query the same daemon key without obtaining
   another credential or cleaning the run directory. `launch_material` now
   refuses after dispatch begins. Retain the original resolved request in a live
   delivery worker or add an explicit query-only reconciliation branch.
3. Issued credentials remain executor-local and are not legacy Hub tokens.
   Before starting real workers, mount exact-child token authentication and the
   sealed executor-attested child relay to the owner. The owner must derive the
   current exact child/assignment/lease from its journal, verify the current paired
   executor key and run the existing authoritative lease/lifecycle handlers.
   Do not register a Hub task/lease or accept remote task grants.
4. Implement bounded child renewal, expiry/stop reconciliation and shared
   manual/warm admission, including legacy launch paths through the same
   device-wide ledger. Preserve charges until trusted exact-child absence.
5. Implement encrypted PTY delivery tickets/results and actual provider
   interrupt profiles. Selected source `5b307a18` can supply the PTY primitive,
   but adapt away its legacy BO/Hub authority. Linux actual integration plus
   Darwin unit/contracts and explicit Windows bounds remain the approved gate.
   No Darwin/Windows runtime or real-provider pass is claimed here.
6. Complete all acceptance evidence and obtain independent review before submit.

## M3-2 exact child authentication and reverse relay (2026-11-07)

This supersedes continuation boundary 3 above for the lease/lifecycle request
path. **M3-2 remains incomplete. Automatic physical dispatch, bounded renewal,
global legacy/manual/warm admission and encrypted PTY delivery remain open.**

Commit `fea2f510` adds query-only recovery after the durable physical dispatch
boundary. The retry supplies neither Spawn material nor an owner nonce. It
observes the original daemon key and cannot clean the run directory or launch a
replacement (`src/bridge/executor_runtime.odin:24`,
`src/lib/executor_local/actions.odin:159`). The real-daemon regression simulates
a lost response before local observation and verifies the original PID.

`src/lib/executor_local/child.odin:14` authenticates the exact issued secret only
for a current, confirmed, unexpired child generation. It fails closed on local
clock regression, owner incarnation changes and executor restart. The Bridge
also queries the actual daemon by its exact launch key before attesting input
(`src/bridge/executor_child.odin:16`). No executor credential is inserted into the
legacy agent-token store or sent to the Hub or owner.

The local endpoint fallback accepts these credentials only for
`agent.owner_local.lease` (`src/bridge/wrapper_endpoint.odin:225`). It fetches and
verifies the current paired directory, signs the exact child/input digest and
uses the encrypted reverse relay (`src/bridge/executor_child.odin:55`). Both HTTP
steps run without the executor mutex. Returned directory observations are
persisted before interpreting results. Unknown/revoked peers, substituted
results and changed local child fences fail closed.

The Hub exposes Bridge-authenticated directory retrieval and reverse child
transit, using the immutable registered owner route
(`src/hub/transport/http/owner_local_handlers.odin:211`). It reads routing and
paired-directory metadata only. The receiving Bridge validates the enrolled
executor and authenticated channel, resolves identity from its own retained
bootstrap/journal/current assignment and calls the ordinary authoritative
lease/lifecycle handlers (`src/lib/owner_local/execution_child.odin:15`,
`src/bridge/owner_executor_child.odin:14`). A remote `lease.claim` is rejected;
no replacement task grant or work attempt is admitted.

The owner signs a separate `child_result` receipt over the exact request and
result bytes; the content bundle remains encrypted. Unicode result content is
allowed without relaxing the ASCII authority envelope. A shared account key
cannot forge this owner signature or substitute another result
(`src/contracts/executor_child.odin:64`,
`src/lib/executor_channel/channel.odin:121`). Odin and TypeScript share signed
substitution fixtures for both request and result.

A fresh child transport attestation may carry the exact **expired original
input**. The owner alone decides historical receipt replay versus a fresh
expired mutation. Changing the original input expiry would change the operation
digest and is forbidden recovery. Native owner tests prove the same committed
heartbeat result replays after input expiry, while a new expired operation is
rejected. Current child/assignment read scope still applies.

### Verification for this continuation

All commands run through managed shells in the task Workdir. No real provider,
full enrolled-network, Darwin runtime or Windows runtime result is claimed.

```bash
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-query-ledger-20261107-0310
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-bootstrap-pty-20261107-0300/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.bridge_executor_real_daemon_ledger_dispatch_and_stale_stop,main.bridge_executor_expiry_during_owner_check_and_clock_regression_fail_before_io -out:$HOME/.cache/heimdall-tests/m3b-query-bridge-20261107-0310
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3b-query-bins-20261107-0311
```

Results: executor **27 PASS** (`sh_80a1c335f94ec4198f4b260e449eda7c`), Bridge
**2 PASS** (`sh_1d5bd570d88c6e3a5d4cf22123bdc7dc`), production Bridge build
**PASS** (`sh_342a19656d905fdc2ec5b94ed13d53b3`). The optional old-daemon phase
was skipped because `HEIMDALL_EXECUTOR_OLD_PTY` was absent.

```bash
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-child-contracts-20261107-0327
nix develop --command odin test src/lib/executor_channel -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-child-channel-20261107-0327
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-child-ledger-20261107-0327
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=owner_local.owner_execution_child_uses_native_journal_and_ordinary_capability_replay,owner_local.owner_execution_child_rejects_substitution_revocation_regrant_and_restart -out:$HOME/.cache/heimdall-tests/m3b-child-owner-replay-20261107-0327
```

Results: contracts **37 PASS**, channel **4 PASS**, executor **29 PASS**
(`sh_f1f5f1566cdaa4fc149a520976b11dc6`); owner replay **2 PASS**
(`sh_7f61d0c04d856f442caff2b390bdca95`). The earlier full owner run passed
**261 tests** (`sh_2da8a45eaae8571aa68582f5474f7598`), before the added expired-input
replay assertions and result sealing helper.

```bash
node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_child_test.ts tests/ui_executor_contract_test.ts tests/ui_executor_channel_test.ts tests/ui_executor_issuance_test.ts
npm run typecheck
nix develop --command odin test src/hub/transport/http -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=http.executor_resource_relay_requires_exact_registered_owner_bridge -out:$HOME/.cache/heimdall-tests/m3b-child-hub-relay-20261107-0330
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-bootstrap-pty-20261107-0300/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.test_owner_local_executor_signer_domains_and_missing_identity -out:$HOME/.cache/heimdall-tests/m3b-child-endpoint-real3-20261107-0334
```

Results: TypeScript **15 PASS** and typecheck **PASS**
(`sh_a8edf645b1d8851c62af3df6afc65909`); Hub routing **1 PASS**
(`sh_f9d78ec7bcd4104b1a32cf0839c32479`); real-child endpoint and signer domains
**2 PASS** (`sh_7ce2772addd5957fa1d31780de41c8a0`). The endpoint integration uses
injected directory/owner transport and real encrypted owner-signed results. It
proves exact live child authentication, unlocked I/O, result/scope substitution
rejection and denial after physical absence despite a retained confirmed ledger.
Native owner journal/capability behavior is independently tested; this is not an
end-to-end enrolled-network owner mutation demo.

Draft failures corrected: Odin test variable redeclaration; heartbeat fixture
used `heartbeat` instead of `lease.heartbeat`; TypeScript referenced a nonexistent
digest helper; the isolated PTY test initially used the production socket path
instead of its explicit test socket. The test fence safely refused that dial.
No production authority fallback or unrelated cleanup was introduced.

Final-source verification also passed:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-child-relay-owner-full-20261107-0336
nix build .#ham-bridge .#ham-hub -o $HOME/.cache/heimdall-tests/m3b-child-relay-bins-20261107-0336
git diff HEAD --check
```

Full owner suite **261 PASS** (`sh_7c9f9203eedd413924b710d16db39aa2`), both
production builds **PASS** (`sh_e8672266caa0933bc13fb3dadbcc452e`), whitespace
check **PASS**. All new source files were staged before the Nix builds so the
flake included them.

### Automatic exact activation dispatch (2026-11-07 continuation)

Activation with accepted bootstrap now calls physical dispatch before returning a
successful receipt (`src/bridge/executor_exchange.odin:146`). Exact reservation
selection binds the original prepare digest and retains the original daemon key;
a dispatch marker, confirmed child, or executor restart permits only observation
(`src/lib/executor_local/actions.odin:181`). A retained bootstrap replay avoids
another admission nonce, but still checks exact original bootstrap/body equality
(`src/lib/executor_local/bootstrap.odin:75`).

First launch resolves local provisioning and materializes files before obtaining
a new signed owner nonce. The executor mutex is released across owner HTTP, and
the startup I/O gate is acquired only after the callback returns and current
paired keys are rechecked (`src/bridge/executor_activation.odin:65`). Final proof
checks enforce wall and monotonic expiry, including after the durable dispatch
commit, immediately before Spawn (`src/bridge/executor_runtime.odin:55`).
Failure after that commit remains query-only. Confirmed replay neither
rematerializes the run directory nor requests another nonce
(`src/bridge/executor_activation.odin:55`).

The mounted activation handler is exercised with real signatures/encryption and
a real isolated PTY daemon. The fixture injects the owner transport and local
Spawn resolver (shell stand-in); it verifies the same child PID on replay,
one materialization, and executor/startup mutex availability during the nonce
callback (`src/bridge/executor_issuance_test.odin:450`). Earlier signature/storage
acceptance cases explicitly inject an acceptance-only dispatcher; they do not
claim physical launch. This is not an enrolled-network or real-provider demo.

Final-source checks, all through managed shells in this task Workdir:

```bash
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-auto-dispatch-ledger-20261107-0349
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-bootstrap-pty-20261107-0300/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.bridge_executor_real_daemon_ledger_dispatch_and_stale_stop,main.bridge_executor_expiry_during_owner_check_and_clock_regression_fail_before_io,main.bridge_executor_physical_fence_rechecks_wall_and_monotonic_expiry -out:$HOME/.cache/heimdall-tests/m3b-mounted-auto-dispatch-final-20261107-0349
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3b-auto-dispatch-bins-20261107-0348
git diff --cached --check
```

Results: executor **30 PASS** (`sh_08c7fcf647980bc1ce8af24e885553d4`),
Bridge **4 PASS** (`sh_15ce625903c02f1d0812aece19fc43b9`), production Bridge build
**PASS** (`sh_e81ec4c9a5e3f088352df92f237c1708`). Old-daemon compatibility phase
was skipped because `HEIMDALL_EXECUTOR_OLD_PTY` was absent.

Draft failures corrected: multiline Odin loop syntax, a fixture timestamp that
regressed after another owner's activation, and Tick/Duration test arithmetic.
Moving the capability probe before the first owner check broke the existing
expiry regression; preserved its original ordering and added a separate local
final proof check around durable dispatch. No clock or authority check was
relaxed. No unrelated cleanup.

### Bounded safety reconciliation (2026-11-07 continuation)

The Bridge starts an independent executor safety worker at startup
(`src/bridge/main.odin:280`). Each tick expires reservations and observes at most
16 exact retained children, with a durable-identity cursor that wraps for another
sweep. Unknown daemon results retain the charge and advance the cursor so later
owners are not starved (`src/bridge/executor_reconcile.odin:14`).
The cursor itself is in memory; restart safely restarts the sweep.

Candidates exclude the current runtime's queued and undispatched claims, because
a fresh owner callback can be in flight with the application mutex released.
Dispatched/confirmed claims, retained children from prior executor incarnations,
and stopping reservations are eligible (`src/lib/executor_local/reconcile.odin:10`).
The exact instance/key/document/incarnation is rechecked before local daemon I/O;
only stopping reservations are closed (`src/lib/executor_local/reconcile.odin:30`).
This worker cannot Spawn, renew, or mutate owner task state. Recovery completes
only after all charged retained children have trusted current observations.

Checks:

```bash
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-reconcile-ledger-final-20261107-0353
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-bootstrap-pty-20261107-0300/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.bridge_executor_real_daemon_ledger_dispatch_and_stale_stop,main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.bridge_executor_expiry_during_owner_check_and_clock_regression_fail_before_io,main.bridge_executor_physical_fence_rechecks_wall_and_monotonic_expiry -out:$HOME/.cache/heimdall-tests/m3b-reconcile-bridge-20261107-0353
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3b-reconcile-bins-20261107-0353
git diff --cached --check
```

Results: executor **32 PASS** (`sh_feebefff9c60d0792692d0a7ccc58859`),
Bridge **4 PASS** (`sh_2edb735cc24a0b9be1131da3b94190d2`), production Bridge
build **PASS** (`sh_548ddc8a3d99e6cbc78bc4d98873934e`).
The real daemon fixture covers live child observation, an expired warm child's
exact stop/absence, and charge retention across real daemon loss. Native tests
cover undispatched exclusion, restart observation without launch authority and
two-owner cursor progress. No new platform/provider evidence is claimed.
An initial test used an unsupported message argument to `expect_value`; corrected
to `expect` before the passing run. No unrelated cleanup.

### Executor-local startup readiness (2026-11-07 continuation)

Coordinator guidance (`msg_18e5a6f1a1e4556d`) authorizes exact local
child/token-generation readiness with replay and stale-child denial, without
owner task-authority effects. The legacy consumer still relays readiness using
its Hub instance token (`src/bridge/startup_readiness.odin:222`); remote activation
uses the owner activation fence and active execution receipt instead
(`src/bridge/owner_local_executor.odin:117`,
`src/bridge/owner_local_executor.odin:238`). No additional remote owner waiting
consumer was identified, so this change adds no owner readiness observation.

The existing local `agent.start_success` method now admits executor credentials
through the separate executor path (`src/bridge/wrapper_endpoint.odin:227`).
Readiness accepts empty params only: identity/generation come from local retained
issuance, not caller assertions. It fetches and verifies the paired directory,
checks exact daemon presence, and rechecks current bootstrap/secret/deadline
under the startup I/O gate before persisting
(`src/bridge/executor_child.odin:130`).
The acknowledgement contract is `accepted` plus the original `ready_ms`
(`src/contracts/executor_child.odin:143`, TypeScript mirror in
`src/ui/api/executor.ts`).

Executor schema V5 appends exact reservation/instance/launch-key/token-generation/
executor-incarnation readiness. Scope and append-only SQL triggers guard records
(`src/lib/executor_local/schema.sql:110`). Fresh authentication precedes receipt
replay, so retained success cannot authenticate a revoked, expired, stopped or
prior-runtime child (`src/lib/executor_local/readiness.odin:9`). The V4-to-V5
migration transactionally rebuilds the runtime version guard without reissuing
identities. Historical reconstruction fixtures now remove readiness too.

Native tests exercise exact observation, wrong keys/secrets, expiry, restart,
idempotent original timestamp, immutable evidence, statement and deferred-COMMIT
rollback, and genuine V4 migration collision/rollback/recovery
(`src/lib/executor_local/readiness_test.odin:7`,
`src/lib/executor_local/readiness_test.odin:56`).
The real-child endpoint test verifies accepted readiness, identical replay
without owner exchange, denial of caller-selected fields/wrong secrets, and
denial after physical child absence (`src/bridge/executor_issuance_test.odin:512`).

Final-source checks:

```bash
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-readiness-ledger-final-20261107-0400
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-readiness-contracts-20261107-0400
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-bootstrap-pty-20261107-0300/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.bridge_executor_real_daemon_ledger_dispatch_and_stale_stop,main.bridge_executor_expiry_during_owner_check_and_clock_regression_fail_before_io,main.bridge_executor_physical_fence_rechecks_wall_and_monotonic_expiry,main.startup_both_events_and_cli_share_one_ready_relay,main.startup_stop_relaunch_and_revocation_are_fenced -out:$HOME/.cache/heimdall-tests/m3b-readiness-real-final-20261107-0400
npm run typecheck
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3b-readiness-bins-20261107-0400
git diff --cached --check
```

Results: executor **34 PASS** (`sh_9feae8b95558e76ff4c7fbf68addd433`);
contracts **37 PASS** (`sh_440ed6cc7e78391e5b221ce91499c13e`);
Bridge **6 PASS** (`sh_9dd3ec188bb8aa3c56cf04b46267ed11`);
typecheck **PASS** (`sh_05d4aa2a2668b7707a9862a446182102`);
production Bridge build **PASS** (`sh_de78069c06f8b713fbca9eaa4bf65073`).
Old-daemon compatibility phase remains skipped without
`HEIMDALL_EXECUTOR_OLD_PTY`. No real provider or additional platform evidence is
claimed. An initial scripted edit also inserted a migration call in rollback;
compilation caught it and it was removed before all passing checks.
No unrelated cleanup or owner task mutation was added.

### Next implementation boundary

1. Implement bounded signed deadline renewal through the owner/executor path,
   including the exact daemon deadline. Existing bootstrap immutability and exact
   deadline-version/expiry checks must be reconciled with renewal; never extend a
   process by trusting a child or a historical receipt.
2. Complete device-wide admission across legacy/manual/warm launch paths.
   Current remote reservations share one ledger, but legacy physical launches
   still need accounting and mapping/identity fences.
3. Implement encrypted PTY tickets/results, bracketed paste, Linux/Darwin
   interrupt profiles and documented Windows bounds. Rich owner-rendered
   profile/memory/skill provisioning remains separate from the minimal snapshot.
4. Complete actual failure/cross-owner evidence, real provider and platform
   verification gates, and independent review before submit. The full M3 task
   remains incomplete; continue this same branch without reimporting predecessors.

### Exact daemon renewal primitive (2026-11-07 continuation)

This checkpoint implements the physical renewal primitive only. **Signed
owner-to-executor renewal remains unfinished and is not mounted.** The existing
production launch path still sends only its original deadline, so it creates
nonrenewable children. No remote child request, task heartbeat result or
historical receipt is used to extend a process.

The local IPC contract adds tag `0x40`: length-prefixed instance, exact launch
key and Bridge-only renewal secret, followed by little-endian u64 deadline
version, absolute expiry and hard deadline
(`tools/pty_host/src/dproto.rs:319`). A successful response is the existing
exact-key `StartupLaunch` response with a positive PID. It is a per-request
acknowledgement, not permission to issue another renewal. Unsupported daemons
reject the new tag; no legacy fallback is provided.

The daemon accepts renewal only for the exact live keyed child
(`tools/pty_host/src/daemon.rs:809`). Version must increment by one; the same
version and expiry are idempotent without resetting the monotonic clock.
Conflicting/stale/skipped versions, decreased expiry and changed hard bounds
fail. A shared deadline mutex linearizes renewal against irreversible expiry.
Both wall expiry and monotonic expiry retire the child, and renewal cannot
revive it. The initial monotonic hard bound cannot move backwards with the
wall clock (`tools/pty_host/src/daemon.rs:421`).

Renewable initial spawns must carry canonical positive
`HEIMDALL_EXECUTOR_DEADLINE_VERSION` and `HEIMDALL_EXECUTOR_HARD_MS`, plus an
unpredictable `HEIMDALL_EXECUTOR_RENEW_SECRET`. The secret is removed before
creating the child and from its retained restart spec; the daemon retains only
a SHA256 digest (`tools/pty_host/src/daemon.rs:400`,
`tools/pty_host/src/daemon.rs:559`). An initial spawn without that separate
credential cannot renew. The child-visible launch key and deadline are
insufficient. The future production implementation must durably retain this
control credential separately from all child bootstrap/configuration material.

Native encoding and the one-shot adapter are in
`src/bridge/pty_executor.odin:48`. The real isolated-daemon native test at
`src/bridge/executor_runtime_test.odin:281` exercises success, exact lost-reply
replay, wrong child, conflicting version, changed hard bound and denial after
stop. Rust tests cover actual survival beyond the original physical timeout,
shared-watcher expiry, wrong secret, credential exclusion from the retained
child spec, monotonic hard cap, stale replacement and unknown daemon state
(`tools/pty_host/src/daemon.rs:1900`).

Next implementation boundary remains:
1. Add owner-authored renewal journal/outbox and fresh nonce verification for the
   exact current lease/version/expiry. Existing
   `src/lib/owner_local/execution.odin:220`,
   `src/contracts/executor.odin:281` and
   `src/lib/executor_local/fence.odin:18` admit activation only.
2. Reconcile immutable bootstrap authentication with accepted signed deadline
   updates. `src/lib/executor_local/child.odin:44` currently requires the
   bootstrap deadline/version to equal the current reservation. Do not simply
   loosen that check or trust a child heartbeat result.
3. Persist the separate Bridge control credential, send bounded initial metadata
   only from validated reservation state, and invoke physical renewal only after
   fresh current owner/directory rechecks under startup I/O serialization.
   Recover lost daemon replies using the exact version/expiry; never respawn.
4. Complete global manual/warm admission, encrypted PTY tickets/results,
   provider/platform evidence and independent review as already listed above.

Draft failures corrected: an initial shell-quoting edit stripped Rust byte
literal quotes; a credential-aware test fixture initially omitted the new
credential and was correctly rejected. Neither failed draft is claimed as
passing evidence. No unrelated cleanup, push, deployment or task-authority
effect was introduced.

Final-source verification, through managed shells in this task Workdir:

```bash
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 cargo test --manifest-path tools/pty_host/Cargo.toml --offline -- --test-threads=1
nix develop --command cargo build --manifest-path tools/pty_host/Cargo.toml --offline
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$PWD/tools/pty_host/target/debug/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.pty_executor_exact_control_wire_shape_and_invalid_identity,main.pty_executor_renew_wire_bounds,main.bridge_executor_renewal_exact_ipc,main.bridge_executor_real_daemon_ledger_dispatch_and_stale_stop,main.bridge_executor_expiry_during_owner_check_and_clock_regression_fail_before_io,main.bridge_executor_physical_fence_rechecks_wall_and_monotonic_expiry,main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection -out:$HOME/.cache/heimdall-tests/m3b-renew-secret-real-20261107-0415
nix build .#ham-bridge .#ham-pty-host -o $HOME/.cache/heimdall-tests/m3b-renew-secret-bins-20261107-0416
git diff --cached --check
```

Results: Rust **188 PASS**, two existing child helpers ignored at the top
level and invoked by their passing parent fresh-process tests; real PTY required.
Local binary build **PASS** and native Bridge **7 PASS**
(`sh_2f9940c7e87e08bcd29cfe01240faf69`).
Production Bridge/PTY package builds **PASS**
(`sh_d8df08e045448e9c6aa78db1b13e6f85`).
The old-daemon phase was explicitly skipped without
`HEIMDALL_EXECUTOR_OLD_PTY`; no new old-daemon/platform/provider proof is
claimed. No TypeScript or owner/ledger contracts changed, so their suites were
not rerun for this local IPC checkpoint. Full M3 acceptance remains incomplete.

Exact modified paths under
`/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e5a16377e1ae67/`:

- `docs/executor-dispatch-checkpoint.md`
- `src/bridge/executor_runtime_test.odin`
- `src/bridge/pty_executor.odin`
- `src/bridge/pty_executor_test.odin`
- `tools/pty_host/src/daemon.rs`
- `tools/pty_host/src/dproto.rs`


### Signed physical renewal (2026-11-07 continuation)

The owner heartbeat transaction now appends an immutable signed
`executor.heartbeat` action to its existing outbox, atomically with the lease
deadline/capability and operation receipt. Historical replay returns before
enqueueing. A new remote heartbeat cannot skip an unsettled physical version
(`src/lib/owner_local/leases.odin:169`,
`src/lib/owner_local/execution.odin:343`). No synthetic task authority is added.

Fresh bilateral fences now admit activation or heartbeat. Owner validation binds
the exact claimed action, current lease version/expiry/hard bound and its
matching receipt. Renewal task revision comes from the matching immutable
heartbeat event, rather than the initial claim revision
(`src/lib/owner_local/execution.odin:219`,
`src/contracts/executor.odin:281`,
`src/lib/executor_local/fence.odin:18`). TypeScript mirrors this contract.

Executor schema V6 adds a separate immutable Bridge-only control credential and
a signed renewal journal with pending/confirmed delivery. Credentials are created
once before first dispatch and excluded from child launch material. The existing
daemon strips the secret before spawning and retains only its digest. A migrated
nonrenewable child gains no new secret or launch permission
(`src/lib/executor_local/migration_006.sql:1`,
`src/lib/executor_local/renewal.odin:13`,
`src/bridge/executor_runtime.odin:58`,
`tools/pty_host/src/daemon.rs:400`).

Production renewal consumes a new signed nonce even for exact lost-reply
recovery, rechecks the enrolled directory/current owner binding, and serializes
the exact daemon IPC with invalidation. Repeating the same accepted
version/expiry recovers delivery without resetting its timer or spawning.
Only a successful exact daemon response can confirm local delivery
(`src/bridge/executor_activation.odin:106`,
`src/lib/executor_local/renewal.odin:41`).
A generic relay or historical replay cannot obtain a signed heartbeat receipt
for pending-only ledger acceptance
(`src/lib/executor_local/receipts.odin:15`).

Immutable bootstrap identity is retained. Child authentication and attestations
may supplement its deadline only from the exact daemon-confirmed signed renewal;
the owner independently resolves its own authored renewal journal
(`src/lib/executor_local/child.odin:44`,
`src/contracts/executor_child.odin:150`,
`src/lib/owner_local/execution_child.odin:37`). Exact live-child read scope
still reaches native submission receipts after successful lease retirement.
The new regression performs a real native submit, loses its response, then
replays through a fresh executor attestation without a second grant or mutation
(`src/lib/owner_local/execution_child_test.odin:88`).

Vault purge/reset/rekey and generation invalidation now take an exclusive
physical-I/O gate; activation, query recovery and renewal take its shared side
under startup serialization. Reset holds the gate through identity/cache
deletion, and unseal rejects a generation captured before invalidation. Lock
order is install mutex -> exclusive vault gate for mutations, and startup mutex
-> shared vault gate for physical I/O
(`src/bridge/vault_decrypt.odin:79`,
`src/bridge/unseal_protocol.odin:743`,
`src/bridge/task_chain_search_index.odin:335`,
`src/bridge/executor_activation.odin:60`).

Independent read-only source review caught and rechecked fixes for:
- skipping a pending physical renewal version;
- pinning renewal to the original claim revision;
- rejecting committed submit replay after lease retirement;
- emitting historical physical-success receipts before confirmation;
- vault invalidation during physical I/O and partial reset/unseal interleaving.

No remaining concrete renewal blocker was found by that review. It is a
checkpoint source audit, not full task/platform approval.

Final checks ran through managed shells in
`/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e5a16377e1ae67`:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-renew-owner-final-20261107-0441
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-renew-ledger-receipt-20261107-0437
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-renew-contracts-final-20261107-0441
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$PWD/tools/pty_host/target/debug/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.bridge_executor_real_daemon_ledger_dispatch_and_stale_stop,main.bridge_executor_expiry_during_owner_check_and_clock_regression_fail_before_io,main.bridge_executor_physical_fence_rechecks_wall_and_monotonic_expiry,main.bridge_executor_renewal_exact_ipc,main.bridge_executor_physical_authority_gate_linearizes_vault_invalidation -out:$HOME/.cache/heimdall-tests/m3b-renew-real-final-20261107-0446
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.test_v2_unseal_accepts_signed_payload_and_rejects_negatives,main.test_v2_unseal_keyring_owner_and_superset,main.test_v2_epoch_floor_survives_lock,main.test_v2_unseal_requires_chain_to_pinned_root,main.test_v2_identity_is_never_regenerated,main.task_chain_search_rebuild_is_atomic_and_lock_drops_plaintext,main.task_chain_search_lock_generation_prevents_late_refresh_swap,main.test_enroll_replace_other_account_wipes_old_secrets,main.bridge_executor_physical_authority_gate_linearizes_vault_invalidation -out:$HOME/.cache/heimdall-tests/m3b-renew-vault-final-20261107-0441
nix develop --command node --experimental-strip-types --test --import ./tests/helpers/vaultEndpointHarness.ts tests/ui_executor_contract_test.ts tests/ui_executor_child_test.ts tests/ui_executor_channel_test.ts tests/ui_executor_issuance_test.ts
nix develop --command npm run typecheck
nix build .#ham-bridge .#ham-pty-host -o $HOME/.cache/heimdall-tests/m3b-signed-renew-bins-20261107-0444
git diff --check
```

| Check | Final outcome / managed session |
| --- | --- |
| Owner store | 264 PASS; `sh_685a45e8f430180b9feae8ea5f3bd988` |
| Executor store, V6 collision/recovery, child deadline and receipt gates | 36 PASS; `sh_584685f8b9cf481de43631304f10109e` |
| Native contracts | 37 PASS; `sh_531152d237be46dcf976e9f94bdd89c0` |
| Mounted encrypted real daemon, lost confirmation, generic pending replay refusal, generation invalidation/recovery, same-PID replay | 6 PASS; `sh_537360969193c4b2ad56ba9fb586f0d5` |
| Vault/unseal/search/reset-adjacent regressions | 9 PASS; `sh_2b1a31095c4b770b9306fe4248d54808` |
| TS contracts/channel/child/issuance | 16 PASS; `sh_1188e51e960b7fe1526bc535f4d12bb5` |
| Typecheck | PASS; `sh_99860b1115db355847dc60fd054c53f0` |
| Bridge/PTY Nix packages | PASS; `sh_7be89e2932e80ece801e7fc21b2e1784` |

The old-daemon phase explicitly skipped without `HEIMDALL_EXECUTOR_OLD_PTY`.
No new old-daemon, real-provider, Darwin or Windows evidence is claimed.
Rust sources did not change in this checkpoint; the prior 188-pass real-PTY
Rust evidence remains historical and was not rerun. Package tests alone are
not host PTY evidence; the separate required-daemon native run is.

Corrected draft failures: Odin multiline `do` and variable redeclarations;
a remote owner fixture using a lease-only signer; a supplemental TS fixture
which initially decreased the original expiry; V5 migration reconstruction
whose renamed runtime invalidated a retained readiness trigger; and an extended
mounted fixture which needed to recover its intentionally pending version before
reasserting physical-absence errors. Failed drafts are not passing evidence.
One managed diagnostic lacked `rg`, and one exploratory log ID did not exist;
neither affected the working tree. No unrelated cleanup, push or rollout.

#### Current remaining boundary

1. Complete global manual/warm admission. Coordinator decision
   `cmt_18e5a9a3dc79631c` / `msg_18e5a9a3e8badc19` selects an
   enrolled-device-authorized local launch journal sharing the same finite
   device/account/provider slots, exact instance and protected directory ledger.
   Do not invent chain/task/lease IDs or treat Hub launch commands alone as
   admission. Task-owned dispatch retains the signed owner protocol.
2. Ordinary user shells and isolated disposable test fixtures are outside
   agent-slot budgets. A real managed-agent provider test through production
   launch machinery must be admitted and counted. Warm children remain charged
   until exact trusted stop/exit evidence, without timeout-only refunds.
3. Complete encrypted PTY tickets/results, literal bracketed paste,
   real provider Linux/Darwin interrupt profiles and documented Windows bounds,
   actual owner/executor failure and cross-owner integration, then the required
   independent task review. Preserve executor-local readiness and read-only
   receipt recovery. **Do not submit this task as complete yet.**


### Local admission foundation (2026-11-07 continuation)

Base: `d62a9a8ef81319c93e0b1a45f52b638b340fa552`.
This is a foundation checkpoint for coordinator decision
`cmt_18e5a9a3dc79631c`, not completed global production admission.

The new `local_launch` device consent signs the exact raw digest of a
`local_configuration`: physical instance, launch epoch/run/token generation,
configuration and executor revisions, policy/slot/profile, protected directory
revision/key, purpose and full Spawn digest. Neither document invents owner,
chain, task or lease authority. Native and TypeScript schemas share canonical
vectors and fail closed on extra authority fields. Unicode model labels stay in
the content configuration; the signed authority envelope remains ASCII
(`src/contracts/executor_local_launch.odin:5`,
`src/contracts/executor.odin:240`, `src/ui/api/executor.ts:7`).

V7 retains local consent/configuration in a distinct immutable journal.
`executor_live_resources` unifies its charges with every owner's reservation.
Both insert paths have SQL conflict backstops for device capacity, slot, exact
instance and protected directory; policy and directory changes require both
classes to drain. Existing V1-V5 reconstruction tests remove V7 additions first.
A genuine V6 collision/rollback/recovery test preserves the existing active
reservation and runtime identity
(`src/lib/executor_local/schema.sql:152`,
`src/lib/executor_local/schema.sql:187`,
`src/lib/executor_local/store.odin:177`,
`src/lib/executor_local/local_launch_test.odin:165`).

Admission authenticates an enrolled device, checks the current mapping and
trusted resolver output, and journals exact bytes before granting one-shot I/O.
It saves a monotonic admission tick, fenced by executor incarnation, so wall
rollback or a slow commit cannot extend the consent window. Dispatch rechecks
the current device signature and policy/mapping, consumes permission durably,
then checks the deadline again. A replay returns retained identity/state; it
cannot refresh the configuration, deadline, incarnation or launch permission.
A Bridge restart never reissues an old admission
(`src/lib/executor_local/local_launch.odin:23`,
`src/lib/executor_local/local_launch.odin:83`,
`src/lib/executor_local/local_launch.odin:157`).

Manual/warm lifetime is separate from owner lease deadlines. Local daemon
capability `0x41` explicitly admits exact-key local mode without a lease timer,
preserving optional provider-test timeouts. The daemon rejects duplicate local
markers, missing launch keys and any mixture of local mode with owner
deadline/renewal fields. Owner dispatch also rejects caller-supplied local
markers. All launches still share the daemon's serialized lifecycle, exact
full-Spawn digest, tombstones, query and stop keys
(`tools/pty_host/src/daemon.rs:371`,
`tools/pty_host/src/daemon.rs:518`,
`tools/pty_host/src/dproto.rs:322`,
`src/bridge/executor_runtime.odin:34`).

The native adapter canonicalizes the current directory and resolves catalog/
profile/model before physical I/O. It reads current journal state on every
retry, so an old admitted snapshot becomes query-only after first dispatch.
Only trusted exact daemon absence can refund a dispatched local charge.
Explicit cancellation can release an undispatched admission; expiry alone
cannot release either class. Local reconciliation is bounded with a separate
cursor from owner reconciliation, and restart readiness waits for both classes
(`src/bridge/executor_local_launch.odin:17`,
`src/bridge/executor_local_launch.odin:38`,
`src/lib/executor_local/local_launch.odin:105`,
`src/bridge/executor_reconcile.odin:44`,
`src/lib/executor_local/actions.odin:135`).

The real packaged-daemon proof injects a failed observation transaction after
successful Spawn, recovers the same PID with an old snapshot, reopens the ledger,
requires exact recovery before readiness, stops/refunds the exact warm child,
launches an independently authorized replacement, rejects stale-key stop, kills
the actual daemon and restarts it, then verifies that unknown prior identity
stays charged/stopping. The resolver separately rejects changed Spawn bytes,
reserved fields, missing catalog models and vanished canonical directories
(`src/bridge/executor_local_launch_test.odin:16`).

Checks ran through managed shells in
`/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e5a16377e1ae67`:

```bash
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-local-store-final-20261107-0505
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-local-contracts-final-20261107-0505
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-local-owner-final-20261107-0505
nix develop --command node --experimental-strip-types --test --import ./tests/helpers/vaultEndpointHarness.ts tests/ui_executor_contract_test.ts
nix develop --command npm run typecheck
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 cargo test --manifest-path tools/pty_host/Cargo.toml --offline -- --test-threads=1
nix build .#ham-bridge .#ham-pty-host -o $HOME/.cache/heimdall-tests/m3-local-admission-bins-20261107-0505
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3-local-admission-bins-20261107-0505-1/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.bridge_executor_real_daemon_ledger_dispatch_and_stale_stop,main.bridge_executor_expiry_during_owner_check_and_clock_regression_fail_before_io,main.bridge_executor_physical_fence_rechecks_wall_and_monotonic_expiry,main.bridge_executor_renewal_exact_ipc,main.bridge_executor_physical_authority_gate_linearizes_vault_invalidation,main.bridge_executor_local_resolver_rechecks_catalog_mapping_and_full_spawn,main.bridge_executor_local_real_daemon_lost_observation_restart_and_exact_stop -out:$HOME/.cache/heimdall-tests/m3-local-real-final-20261107-0507
git diff --check
```

| Check | Outcome / managed session |
| --- | --- |
| Executor store, shared quota/race/replay/directory/clock/rollback/restart and V6 migration | 44 PASS; `sh_3d8ad68ed9c742993fad991cd70e961d` |
| Native contracts, shared new wire vectors | 37 PASS; `sh_c810dccb2bf9ef7efbb7c6d93d2694e2` |
| Owner regression | 264 PASS; `sh_aae3c13a4e6693c9dcdf5edc1ed3e5c3` |
| TS contracts/device consent | 7 PASS; `sh_aeab01ccf857a187fb99d933762a909c` |
| Typecheck | PASS; `sh_48758f31e911662c860c1c417ab12fce` |
| Rust host suite with real PTY required | 190 PASS; `sh_06e026afdcaff91c84e8ff23b2cb8fd2`; two ignored helper tests are invoked by their parent fresh-process tests |
| Bridge/PTY Nix packages | PASS; `sh_03d7e5fe9bbda0a9625f27907a38ed44` |
| Packaged real-daemon local proof plus retained remote issuance/activation/deadline/renewal/vault regressions | 8 PASS; `sh_5df4a7d20975575f70d1728f3e1c6b1b` |

Corrected drafts: missing explicit i32-to-int cleanup conversion; an Odin
multiline `do`; and the meaningful retry defect where an old caller snapshot's
state was trusted instead of reading the current durable journal. No failing
draft is counted as passing evidence. No unrelated cleanup or rollout.

#### Remaining production boundary

The new local dispatch adapter is internal. **Production manual/warm launch
entrypoints and the enrolled-device consent/draft transport are not wired.**
Existing production calls at `src/bridge/hub_runtime_client.odin:2670`,
`:2701`, and `:2773` must be replaced with this authenticated path before
claiming global admission. A native durable draft must preserve the exact
Bridge-generated startup credentials and Spawn digest for the device to approve;
never ask a caller to invent a physical Spawn or expose startup secrets, and
never treat a Hub command alone as consent. Reuse current paired-directory
verification and the shared vault/startup I/O gate, then recheck current
enrollment immediately before first I/O. Preserve task-owned signed dispatch.

Ordinary user shells and isolated disposable fixtures remain excluded. A real
managed provider test through production launch must use the same budget.
Encrypted PTY tickets/results, literal bracketed paste, real Linux/Darwin
provider interrupt profiles, explicit Windows limits, full owner/executor
crash/cross-owner integration and required independent final task review remain.
The old-daemon phase was explicitly skipped without
`HEIMDALL_EXECUTOR_OLD_PTY`; no new real-provider, Darwin or Windows evidence is
claimed. The coordinator is arranging an independent source audit of a pinned
checkpoint. That audit does not replace full M3 acceptance or the final review.

### Explicit abandoned-admission recovery regression (2026-11-07)

The pinned independent audit at
`03f2d4112e47f9dc3ee6309b108cf7ffd920b52b`
identified P3: an abandoned admitted row deliberately remains charged after
restart until exact explicit cancellation. This checkpoint adds storage-level
proof in `src/lib/executor_local/local_launch_test.odin`:

- Admit, reopen, recover and expire: charge remains and old-incarnation first
  dispatch fails. Wrong-identity cancellation has no effect; exact cancellation
  releases the charge. Signed historical replay retains released state across
  another reopen and cannot regain first I/O.
- Race exact cancellation against first-dispatch consumption in 16 fresh ledgers:
  exactly one wins. A dispatch winner stays charged, including after stop intent;
  cancellation cannot refund it.
- Force a deferred foreign-key failure at cancellation COMMIT: the state update
  rolls back, the admission stays charged, and cancellation succeeds only after
  removing the injected failure.

Check, from the task Workdir:

```bash
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-cancel-atomic-20261107-0523
```

47 tests PASS, exit 0; managed session
`sh_fa4298efc7505721f1e1cf0e0697896e`. Earlier focused restart-only run passed
45 tests in `sh_be673d0a94479ee0391f0970a4082e94`.
No production behavior changed; no additional package builds are needed for
these storage-only regression additions.

P3 is **not closed**: authenticated production cancellation/recovery must still
be wired. P2 is also open. Coordinator decision
`cmt_18e5abb5ff4ac800` confirms existing encrypted executor relay with
domain-separated device-signed exact draft prepare/inspect/authorize/cancel;
principal-owned drafts, current enrollment/resources, stable native random
startup material, no unsigned Hub launch authority, no secrets in inspect, and
atomic replay/conflict/cancel handling. Production first I/O must hold the
startup/vault gates and recheck current paired key/filesystem/catalog. Dispatched
or uncertain children use exact stop/reconciliation, retaining their charge until
trusted absence. This decision resolves the interface question; no further
permission is needed for routine implementation within it.

All remaining production and full M3 gates in the preceding section remain.
This test checkpoint is neither full acceptance nor the final independent review.


## M3a durable draft and authenticated cancellation checkpoint (2026-11-07)

Task `task_18e5ac3db3f3fce0`, revision 1, initial lease
`lease_18e5ac3db6b20b6c`. The task branch was explicitly based on authorized
predecessor `65557436`; the audit-only `03f2d411` branch and shared checkout
were preserved. All prior scoped M3 implementation ancestry remains intact.

This is a verified **partial checkpoint**, not M3a submission or P2/P3 closure.

### Implemented boundary

- `src/contracts/executor_local_launch.odin:23` adds strict, separately signed
  device commands for prepare/inspect/authorize/cancel, binding the account,
  executor, preparing principal/key, exact draft ID/revision/configuration
  digest, operation ID, and bounded request lifetime. Native and TS schemas
  match; task/lease/chain fields are rejected.
- `src/lib/executor_local/local_draft.odin:17` stages native-only JSON material
  once per native source digest. Retries and reopen retain the original bytes.
  This helper **does not generate** startup randomness or activate tokens.
  Its future production caller must generate and validate those facts natively;
  no relay accepts material, an argv, credentials or a physical Spawn.
- `src/lib/executor_local/local_draft.odin:52` explicitly projects public
  configuration/state without startup material, local tokens, consent or daemon
  launch keys. The first signed prepare claims ownership. Other enrolled
  principals/keys cannot inspect, authorize, cancel or replay that draft.
- `src/lib/executor_local/local_draft.odin:68` commits draft authorization,
  existing shared-budget local admission, and exact operation receipt together.
  The original signed authorize document is itself dispatch consent, with no
  second approval signature required. Receipt replay does not revive state.
- Signed cancellation releases admitted rows atomically, including after reopen;
  dispatching/active/stopping rows instead retain charge and enter stopping for
  existing exact daemon reconciliation. Cancellation and first dispatch share
  the Store mutex. Deferred COMMIT failures roll back state, receipts and quota.
- V8 migration rebuilds the runtime header while recreating all retained
  readiness/shared-admission triggers referring to it. Genuine V7 collision
  rollback/retry preserves an active local child/key and its shared exclusion.
  Historical V1-V6 fixtures also upgrade to V8.
- `src/hub/transport/http/owner_local_handlers.odin:174` and
  `src/hub/app/wiring.odin:844` route the minimal encrypted local relay through
  `POST /api/v1/executor/local-launch`. No synthetic owner, chain, task or lease
  is added. Hub checks user/account/device routing and transports ciphertext.
- `src/bridge/executor_local_relay.odin:28` opens current-epoch ciphertext,
  resolves the signed preparing browser and executor against the paired
  directory/high-water pin, and executes retained-draft methods under startup
  and vault gates. Replies have a separate enrolled Bridge signature binding
  the principal, operation, transport request and exact result bytes. Both the
  Bridge signing wrapper and inner identity signer admit only the new explicit
  result domain.
- `src/ui/api/executorLocalLaunch.ts:31` prepares/retries exact signed
  operations and verifies current-enrollment signed encrypted replies. It is a
  client module; **no approval screen is mounted yet**.

### Verified evidence

All commands below ran in
`/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e5ac3db3f3fce0`
through managed shells. The final functional change preserves the original
admission-entry monotonic tick across signature/transaction work in both paths.

```bash
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3a-drafts-final-20261107-0549
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3a-contracts-final-20261107-0548
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3a-owner-final-20261107-0548
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.test_executor_local_mounted_signed_prepare_inspect_cancel_restart,main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection -out:$HOME/.cache/heimdall-tests/m3a-mounted-final-20261107-0549
nix develop --command odin test src/hub/transport/http -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES=http.executor_local_launch_relay_requires_user_account_and_keeps_runtime_offline_opaque,http.executor_issuance_relay_requires_user_account_and_keeps_runtime_offline_opaque -out:$HOME/.cache/heimdall-tests/m3a-http-local-relay-20261107-0545
nix develop --command node --experimental-strip-types --test --import ./tests/helpers/vaultEndpointHarness.ts tests/ui_executor_contract_test.ts tests/ui_executor_issuance_test.ts tests/ui_executor_local_launch_test.ts
nix develop --command npm ci --ignore-scripts --no-audit --no-fund
nix develop --command npm run typecheck
nix build .#ham-bridge .#ham-hub -o $HOME/.cache/heimdall-tests/m3a-draft-relay-bins-final-20261107-0549
git diff --cached --check
```

| Check | Result | Managed session |
| --- | --- | --- |
| Executor storage, including seven new draft regressions | 54 PASS, exit 0 | `sh_a9cdabe2d86bf5c8097d911f0a556700` |
| Native shared contracts | 37 PASS, exit 0 | `sh_52a64c70df33533e13dbfe6649759a12` |
| Owner regression | 264 PASS, exit 0 | `sh_226279de368750bb39dff814f1b30bb1` |
| Mounted signed draft plus retained remote issuance/activation | 2 PASS, exit 0 | `sh_fbd17b7af8fdd97f4339d3f09d457cba` |
| HTTP opaque user/account routing, new and retained | 2 PASS, exit 0 | `sh_e31c866dbada8c68cc9aecdfd87017bd` |
| TS strict contracts/issuance/local client | 9 PASS, exit 0 | `sh_2abff33a872619d603bb0020dd633534` |
| Pinned dependency install | PASS, exit 0, no lock change | `sh_6fb775b80355282542c3d993ac07f523` |
| Typecheck | PASS, exit 0 | `sh_4d5107563cfc599113b0e57be4cb4ce0` |
| Bridge and Hub packages | PASS, exit 0 | `sh_8b893008585f9e6121b29159fc41f3ca` |

Mounted coverage uses genuine paired root/device/Bridge keys and production
decryption, signature, dispatch registration, signed reply, vault/startup gates
and cancellation. It creates a native draft internally, admits it through the
storage API with trusted test resources, reopens before dispatch, then cancels
through the real relay. **This does not prove ordinary production launch**.

Corrected draft failures: an overbroad scripted insertion in rollback; Odin
multiline `do` syntax in a test; and using a stale saved wall time after live
mounted operations (correctly rejected as clock regression). Initial typecheck
lacked pinned `posthog-js`; the pinned install above restored it. An EOF blank
line was removed after diff-check. One attempted run-directory-relative CLI
heartbeat from the Workdir failed with no state effect; subsequent CLI calls
used the managed run directory. No failed run is counted as passing evidence.
No unrelated cleanup, restart, deploy or push occurred.

Rust/daemon/provider/platform suites were not repeated: no Rust source or
physical production dispatch changed. Required production freshness and actual
launch evidence remain below.

### Required continuation; acceptance remains open

1. Build the native ordinary-launch draft caller. Generate CSPRNG startup
   material once, retain exact native command/Spawn facts, and choose the
   signed policy/slot/protected-directory mapping. Pending unsigned Hub
   launch/wake must not invalidate a prior token, write/clean bootstrap,
   spawn or report readiness. Define the stable native source digest across
   transport retries and retain the original exact generation.
2. Wire `src/bridge/hub_runtime_client.odin:2558`, `:2677`, and `:2714`
   (ordinary/manual, warm/wake and managed provider tests). The legacy launch
   path is still present. Keep task-owner dispatch/renewal/readiness intact.
   `src/bridge/executor_local_relay.odin:95` intentionally supplies no trusted
   resources yet: new authorize requests fail closed with invalid_resources.
   Replace that unfinished native apply boundary with resource resolution and
   physical dispatch; never decode a Spawn/material from a relay.
3. Close P2 in that wrapper: fresh paired key/enrollment and current canonical
   filesystem/catalog/profile checks under startup/vault gates through first
   physical I/O, including delayed-consent revocation/mapping replacement/
   catalog-disable regressions. Preserve the original signed authorization
   for exact retry/query; do not request redundant approval per wake.
4. Mount the usable pending/review/authorize/inspect/cancel screen using the
   signed client, with exact operation retention on lost replies and fresh
   directory verification. The API/client alone is not this UI.
5. Finish ordinary lifecycle cancellation/recovery/dispatch integration and
   actual-launch race evidence. The new mounted exact cancellation route
   advances P3, but does not close it without native ordinary drafts and UI.
6. Commit final implementation and obtain the named independent review before
   M3a submission. Encrypted PTY/result/provider-platform work belongs to the
   separately scoped continuation; this checkpoint grants no full M3 gate.

## M3a production admission completion — 2026-11-07

This section supersedes the preceding M3a continuation list for production
admission. Requirements revision 1 and coordinator interface/provisioning decisions
`cmt_18e5af02125aae50` and `cmt_18e5af47889e76ab` remain the scope. Independent
review is routed to named reviewer `agt_18e5281575868be4` through normal lease
submission, as confirmed by the coordinator. This is not the full Milestone 3
PTY/result/provider-platform gate or permission to roll out a runtime.

### Connected behavior and authority

- `src/bridge/executor_local_native.odin:195` is the native manual/warm/provider-test
  entry. It selects an available exact-profile slot from installed signed policy
  and an unambiguous signed canonical directory mapping. Missing resources return
  actionable configuration refusal. OS CSPRNG material is generated once and
  retained with the native command/full Spawn; unsigned requests do not invalidate
  the old token, clean bootstrap, arm startup or start a child. Compatible native
  generation retries reuse original material and current exact signed consent;
  conflicting configuration/epoch retries cannot replace it. No synthetic
  chain/task/lease or Bridge-fabricated Hub credential is introduced.
- `src/bridge/executor_local_relay.odin:105` connects the signed draft authorize
  transaction to physical dispatch. It checks preparing principal/key and exact
  revision/digest before preparation. Slow bootstrap assembly releases the
  application executor mutex. Fresh paired directory/key verification then runs
  under startup/vault gates, and native catalog/profile/model/path configuration
  remains serialized through I/O. The bounded directory GET has no reverse Bridge
  callback and holds no SQL transaction. Immutable Spawn and signed mapping are
  resolved again before admission. Enrollment is fetched again across the durable
  dispatch COMMIT and bootstrap writes (`executor_local_native.odin:59`).
- `src/bridge/executor_local_launch.odin:40` consumes durable first-I/O permission
  before the startup callback. Lost replies/restarts are exact observation only.
  `src/bridge/startup_readiness.odin:383` reuses the exact daemon startup-key check
  while already holding startup serialization, restoring a lost projection without
  rotating token/bootstrap or claiming readiness from a historical receipt.
- Signed cancellation in `src/bridge/executor_local_relay.odin:107` invalidates only
  the retained exact startup credential, targets the exact daemon launch key, and
  retains stopping/uncertain charges until trusted exact absence commits. A lost
  stop-observation commit cannot refund a live/uncertain child. Receipt replay
  cannot revive cancelled state. Existing all-owner shared-budget, owner-fence,
  renewal and readiness paths remain connected and covered below.
- `src/ui/components/agents/LocalLaunchApproval.tsx:27` mounts review, inspect,
  approve, cancel and exact retry in ordinary instance details. Current directory
  verification runs before and after relay I/O. Only unresolved signed operation
  bytes and small draft references are retained as session-storage vault
  ciphertext; response/configuration plaintext is not persisted as a detail cache.
  Reload retries the same signature/operation rather than minting authority.
  Controls remain reachable after readiness clears the instance error.

### Explicit operator provisioning

`src/bridge/executor_operator.odin:20` adds an explicit native CLI signer for
supplied bounded policy/directory records. It uses existing protected Bridge
identity/account/key/domain binding. The authority is OS-account/keystore access;
it does **not** distinguish humans from agents with the same OS account/access.
There is no signing RPC, private-key export, imported private key, automatic
signing/provisioning or agent-token operator authority.

`src/bridge/executor_operator.odin:49` and
`src/lib/executor_local/operator.odin:9` provide independently verified signed
import/readback through the running single journal writer, under the same gates.
Import enforces canonical paths, revision/replay, finite allocations and drain
rules. Public identity inspection and complete operator record/command examples
are in `docs/executor-local-operator.md`. Verification used disposable isolated
identities, config files, sockets, journal and daemon; no live configuration was
signed/installed or restarted.

### Verification

Commands ran through managed shells in
`/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e5ac3db3f3fce0`,
except the explicitly detached unchanged baseline described below.

```bash
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3-local-admission-bins-20261107-0505-1/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/m3a-bridge-final-20261107-0637
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3-local-admission-bins-20261107-0505-1/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_local_native_pending_fresh_resources_and_real_dispatch,main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection,main.bridge_executor_local_real_daemon_lost_observation_restart_and_exact_stop,main.bridge_executor_physical_authority_gate_linearizes_vault_invalidation -out:$HOME/.cache/heimdall-tests/m3a-acceptance-real-final-20261107-0643
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3-local-admission-bins-20261107-0505-1/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_local_native_pending_fresh_resources_and_real_dispatch -out:$HOME/.cache/heimdall-tests/m3a-operator-final-20261107-0644
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3a-storage-final-20261107-0636
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3a-contracts-final-20261107-0640
nix develop --command odin test src/hub/service/agent -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3a-agent-final-20261107-0641
nix develop --command node --experimental-strip-types --test --import ./tests/helpers/vaultEndpointHarness.ts tests/ui_local_launch_approval_test.ts tests/ui_executor_local_launch_test.ts tests/ui_executor_contract_test.ts tests/ui_executor_issuance_test.ts tests/ui_wire_error_test.ts
nix develop --command npm run typecheck
nix develop --command npm run build
nix build .#ham-bridge .#ham-hub -o $HOME/.cache/heimdall-tests/m3a-native-review-bins-20261107-0648
git diff --cached --check
```

| Check | Outcome | Managed session |
| --- | --- | --- |
| Full Bridge, including real-daemon tests when configured | 1033 pass, exit 0 | `sh_a983406e16e88f936a6c1baac90ee73f` |
| Required real native/remote/recovery/vault gate | 4 pass, exit 0 | `sh_221588b1a55adb1bcd34603b4acaf805` |
| Final native operator/input-bound check | 1 pass, exit 0 | `sh_9c5e315b3c732105826cc8c24fe102c1` |
| Executor journal | 54 pass, exit 0 | `sh_db722051400dadc3b4cadfa7b45f84bd` |
| Contracts | 37 pass, exit 0 | `sh_2a60d8af5a79376125d81c8e912f1b67` |
| Hub agent/routing | 68 pass, exit 0 | `sh_d87b2594e09f864a7185ffe02fa32fde` |
| TS contracts/client/mounted UI/error regression | 13 pass, exit 0 | `sh_073a09db1feac7e9b3f62587ed1acbaf` |
| Final typecheck | pass, exit 0 | `sh_c54e898d14e30aebc7382b4e326adb0f` |
| UI/Electron build | pass, exit 0 | `sh_e7c67db605fde1ea56254a752de98ca9` |
| Final Hub/Bridge packages | pass, exit 0 | `sh_9c127464d42573df6cb3c49f7a4cb72c` |

The mounted native scenario (`executor_local_native_test.odin:23`) exercises the
CLI sign/export and import/inspect over an isolated real local socket, before any
native launch. It proves missing-config refusal, forged operator/agent-token
rejection, no signing RPC, live reallocation rejection, signed prepare ownership,
delayed expiry, fresh root-signed revocation/high-water rollback rejection,
catalog disable and signed directory replacement. It then exercises admission
rollback before startup, actual managed provider-test Spawn, lost observation,
same-operation/native retry preserving one child, reopen/cancel/failed observation
charge retention and historical authorize-after-cancel. Finally it runs ordinary
manual launch through production bootstrap HTTP/template materialization and a
real daemon, warm reuse with projection recovery, and exact signed cancellation.
The browser scenario exercises actual mounted buttons, signed/encrypted replies,
lost reply plus unmount/remount, identical signature replay, post-ready controls
and delayed reply after enrolled Bridge revocation.

### Baseline failures and corrected drafts

The broader Task System v2 suite has **193 tests, 3 failures** on both changed
source (`sh_64cbeb0817a95b398f0584e920ec96cc`) and untouched `9ea25988`
(`sh_d538c42fd181b75b173d1d1bdc228db7`):

- `test_clock_jump_extension_only_when_jump_detected`;
- `test_d1_verify_waiting_task_gets_fresh_review_after_migration`;
- `test_fleet_delete_reevaluates_gate`.

Both ran the following exact command, differing only in unique output and cwd:

```bash
nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3a-taskv2-wake-final-20261107-0636
nix develop --command odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3a-taskv2-baseline-20261107-0638
```

The baseline used a detached temporary worktree under `$HOME/.cache/heimdall-tests`,
created from `9ea25988` and removed after comparison; shared/predecessor branches
were untouched. These existing failures are disclosed, not counted as passing
coverage or broadened into unrelated fixes.

An early full Bridge run was stopped after obsolete unsigned-wake tests expected
token/bootstrap replacement and waited for now-forbidden bootstrap I/O. They are
replaced by unsigned refusal/credential preservation and exact credential-forwarding
checks; the real signed native scenario retains lost-reply/projection recovery
coverage. The obsolete unused unsigned PTY launcher was removed. Draft errors
corrected before final passes: shell-edit quoting, Odin crypto helper/length,
dynamic file-set ownership, flat provider-test parsing, fixture model flag,
complete root-signed revoke subject, provider-test clean-slate behavior,
procedure-pointer compatibility and an `expect_value` source-location argument.

No Rust/daemon source changed. Real daemon verification used the retained matching
local-admission package; Rust/provider/platform matrices were not rerun or claimed.
No unrelated cleanup, live provisioning, restart, deployment or push occurred.


## M3a independent-review corrections (attempt 3, 2026-11-07)

Both findings against `64935dda` are addressed without changing wire contracts.
`src/bridge/executor_local_relay.odin:113` refreshes the signed paired directory
inside the startup/vault gates before durable cancellation or exact token/child
side effects. Unavailable directory transport fails closed. A browser key revoked
while cancellation is queued cannot invalidate the retained credential, Close the
child, change the authorized draft, or release its charge. Trusted durable stop
and reconciliation remain a separate safety path.

`src/bridge/executor_local_launch.odin:29` checks global provider enablement
separately from selected-profile model support. Custom models and models discovered
only for that profile now reach dispatch; disabled providers still fail closed.
The native scenario variants exercise provider-test, ordinary manual bootstrap,
warm reuse, exact cancellation, catalog-disable rejection and real daemon identity.
The cancellation variant queues a genuine paired signed request behind startup
serialization, revokes its key, and checks that enrollment refresh occurs under
the gate before any side effect; it then verifies independent trusted cleanup.

The mounted successful-cancel fixture supplies a genuine complete paired-directory
response through the directory-fetch seam. Native scenario fixtures isolate
process-global token, bootstrap and wake state whose allocations otherwise outlive
the per-test allocator. This keeps the four real-daemon variants runnable together.

Focused verification passed **5 tests, exit 0**, session
`sh_e58f0e2f2a05d25834c8beb2c931801b`:

```bash
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3-local-admission-bins-20261107-0505-1/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_local_native_pending_fresh_resources_and_real_dispatch,main.test_executor_local_native_custom_profile_model_dispatch,main.test_executor_local_native_discovered_profile_model_dispatch,main.test_executor_local_native_cancel_rechecks_revocation_before_io,main.test_executor_local_mounted_signed_prepare_inspect_cancel_restart -out:$HOME/.cache/heimdall-tests/m3a-review-native-fixes-20261107-0712
```

Before the production fixes, isolated custom/discovered tests failed with
`invalid_resources` (`sh_1544ba14e8a9cb36564c5da55d52ce6f`,
`sh_4cff556bbdda6caa5e81991259c4b166`), and queued revoked cancellation still
invalidated the token/closed the child (`sh_c9195cfae0b0a616bc5cc1a830bd95c9`).
Combined draft fixtures initially retained allocator-owned process-global state;
those failed/hung runs were stopped, corrected, and are not passing evidence.
An intermediate fixture compile rejected an invalid dynamic-array delete overload;
that was corrected before the passing run.


Broader verification passed **1036 Bridge tests, exit 0**, session
`sh_41b9a4068adbebf1f67212dcd7fb89c9`; the production Bridge package build
passed **exit 0**, session `sh_b971734bbc090dc08d9efdb6528ce74c`:

```bash
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3-local-admission-bins-20261107-0505-1/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -out:$HOME/.cache/heimdall-tests/m3a-review-bridge-full-20261107-0714
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3a-review-fixes-bins-20261107-0714
```

After making initial wake-map allocation explicitly process-lifetime in the
fixture, the final focused rerun passed **5 tests, exit 0**, session
`sh_5d89bf3aa0867b04808b4663276dc653`:

```bash
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3-local-admission-bins-20261107-0505-1/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_local_native_pending_fresh_resources_and_real_dispatch,main.test_executor_local_native_custom_profile_model_dispatch,main.test_executor_local_native_discovered_profile_model_dispatch,main.test_executor_local_native_cancel_rechecks_revocation_before_io,main.test_executor_local_mounted_signed_prepare_inspect_cancel_restart -out:$HOME/.cache/heimdall-tests/m3a-review-native-fixes-20261107-0717
```

`git diff --check` is clean. Unchanged Hub/contracts/storage/UI/daemon code retains
the prior submission's evidence above; those suites were not rerun for these
Bridge-only corrections. The three disclosed Task System v2 baseline failures
remain out of scope. No live restart, provisioning, deployment or push occurred.

## M3b transport checkpoint (2026-11-07, incomplete production gate)

Base `ecb30481` already contains approved M3a `ab8beb00` and predecessor
`65557436`; no branch reset, history merge or duplicate predecessor import was
needed. Selected additive PTY hunks came from `b193d3d0^..12b7f198`. Existing
executor controls, absolute deadlines, signed renewal and local admission were
retained when resolving the additive daemon/protocol conflicts.

The local protocol contract is `src/contracts/pty_notification.md`, with native
types/validation in the adjacent Odin file. The Bridge adapter validates exact
receipt identity, ticket, profile, progress and status. Rust retains bounded
prepare/dispatch/query receipts, partial-write offsets, literal Unicode and
DEC2004 paste gates. Daemon notification writes now enforce the inherited
absolute child deadline before the watcher catches up; ambiguous duplicate
runtime environment identities fail closed. Spawn assembly removes caller
copies of startup/notification identity keys before appending Bridge-derived
values. This small nearby correction prevents ambiguous duplicate identities.

This is a **transport checkpoint**, not completed encrypted owner production
delivery. No arbitrary child notification permission or legacy Hub permit was
imported. Coordinator decision `msg_18e5b1e083c6b73c` selects existing
owner-authorized source/wake/lifecycle intents only. Decision
`msg_18e5b225f5280a88` specifically approves replacing the existing task.hold
checkpoint producer, preserving its original exact Child/reservation/intent and
hold/checkpoint authority. The current raw one-way control notice remains at
`src/bridge/owner_local_controls.odin:62` and is the next integration point;
do not claim connected owner-to-encrypted-PTY results yet.

Checks, cwd this task worktree:

- `nix develop --command cargo test --manifest-path tools/pty_host/Cargo.toml notification -- --test-threads=1`
  passed 14 unit + 2 integration tests (initial transport, session
  `sh_24703d229913d0379306ab21a46f27d3`).
- `nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_NOTIFICATION_REQUIRE_PTY=1 cargo test --manifest-path tools/pty_host/Cargo.toml -- --test-threads=1`
  passed 205 unit + 2 integration tests, 2 existing ignored unit tests, exit 0
  (`sh_eb6586b85fa08c9b2fccfbca519736a4`).
- Final focused notification run with both required flags and the same command
  plus `notification` passed 15 unit + 2 integration tests, exit 0
  (`sh_a5b1887ac83880197f411f093fa5ed82`). This follows the explicit
  Readline-Bash selector and required-prerequisite checks.
- `nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-contracts-20261107-0719`
  passed 37 tests, exit 0 (`sh_67da7356f89b2c91d25b9a4ec504bb3b`).
- `nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.pty_notification_wire_matches_rust_golden,main.pty_notification_shared_unicode_and_control_vectors,main.pty_notification_reply_is_strict_and_tracks_phases,main.pty_notification_transport_distinguishes_receipt_uncertainty_and_unsupported,main.pty_notification_spawn_fence_tracks_exact_issued_token -out:$HOME/.cache/heimdall-tests/m3b-notification-bridge-20261107-0719`
  passed 5 tests, exit 0, no allocator warnings
  (`sh_38d05aef0be2dc025ad828a2d6aee553`).
- `nix build .#ham-bridge .#ham-pty-host -o $HOME/.cache/heimdall-tests/m3b-transport-bins-20261107-0719`
  passed exit 0 (`sh_a5b1f8f930614b4c4eec58acc54ddec2`).
- `nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-transport-bins-20261107-0719-1/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -out:$HOME/.cache/heimdall-tests/m3b-transport-bridge-full-20261107-0720`
  passed 1041 tests, exit 0 (`sh_4bbc3cfc26705d5bd672d157d42d9bb2`).
  The broad suite emitted allocator warnings in untouched VCS/process/wake
  tests; these are disclosed, not claimed as a leak-free resource gate.

The first Nix build failed because cleanCargoSource excluded shared hex/JSON
fixtures. Applying the selected explicit fixture filter to native and release
source sets fixed it; later both package builds pass. One draft native validator
had shell-quoted character literals stripped; using numeric LF/TAB codepoints
fixed the compile error before focused/full passes. No failure is counted as
passing evidence.

Native evidence procedure: `docs/pty-provider-evidence.md`. Real required PTY
checks have an explicit fail-instead-of-skip flag; the separate Readline fixture
can select an existing compatible Bash with
`HEIMDALL_NOTIFICATION_READLINE_BASH`, including on macOS. Readline evidence is
not Codex/Claude evidence. Linux has codex-cli 0.162.0 and Claude Code 2.1.319,
but no actual-provider interruption pass is claimed. Effective Bridge data_dir
was discovered from narrowly redacted runtime flags:
`/home/tanmay/.local/share/heimdall/bridges/heimdall-bridge-hub-brolabs-ai`.
Its profile store contains only disabled pi; the existing native default-profile
fallback applies to codex/claude. The cached catalog advertises claude/codex/
copilot/antigravity/pi; copilot and agy were absent from PATH, pi is installed
but disabled. No support was silently removed. Mac host access is coordinated
separately; no macOS/Windows native pass or live restart/deploy/push occurred.

Next: mount existing exact owner-authorized checkpoint intent through encrypted
request/result AAD, durable exact ticket/progress, current fence and receipt-first
recovery; map no-current-target explicitly without changing source visibility/
ACK. Preserve retained retired/checkpoint authorization rather than granting
fresh work or redirecting a stale ticket. Then run actual Codex/Claude Linux and
macOS profiles plus honest Windows gates, connected producer/result failure
proofs, cumulative suites and independent review. M3b is not complete.


## M3b encrypted checkpoint implementation (2026-11-07, incomplete acceptance)

Commits 286c0c42 and 7f8fe004 add admitted remote notification identity and
strict Odin/TypeScript checkpoint contracts. The continuation mounts only
the approved remote task.hold producer, not arbitrary child notification.send.

Source path:

- src/lib/owner_local/execution_notification.odin:11 selects the original
  committed journal/Child inside the hold transaction. controls.odin preserves
  the journal's complete Child when no local lifecycle configuration exists.
- execution_notification.odin:30 checks the original claimed hold receipt,
  control notice, journal, live exact lease, assignment, bootstrap and current
  held state. Release/replacement gives explicit no_current_target; no new work
  grant is requested. The distinct nonce callback starts at line 93.
- src/lib/executor_local/notification.odin:61 uses the existing append-only
  executor_receipts journal for notification.ticket/dispatch/result stages.
  First PID/ticket/profile cannot be replaced. Stable effect identity excludes
  only refreshed request/deadline timing, preserving the original intent,
  target, message and reservation. Capacity fails closed; receipts are retained.
- src/bridge/executor_notification.odin:42 performs exact reservation-key
  observation, persists the first daemon ticket before dispatch, releases
  executor/startup gates for the owner callback, rechecks current directory and
  deadline/nonce fences, queries the saved ticket before dispatch/resume, and
  signs exact physical results. Journal loss never becomes another Prepare
  after a saved ticket. Startup IPC token digest and executor reservation launch
  key remain distinct.
- owner_local_executor.odin uses its existing snapshot/unlocked-exchange/recheck
  worker. executor_exchange.odin and owner_executor_fence.odin carry the
  encrypted request/result and separate checkpoint nonce. The corresponding
  executor and owner signer allowlists were extended explicitly. Sources are
  not acknowledged by physical result settlement.

Evidence (cwd this task worktree):

| Check | Outcome / session |
| --- | --- |
| Odin contracts, final schema domains | 40 pass; sh_146ca40691e08130ac6c2b45c21e848c |
| Native executor_channel | 5 pass; sh_67dfaa3fd64f73fb2a281eb392c223c0 |
| Mirrored TS notification/contracts/child/channel | 20 pass; sh_1a5d30ad276782a428a6e6ec8c83e5d2 |
| Pinned npm ci and typecheck | exit 0; sh_0bd68d548c3289106435ce32d767f523 |
| Owner suite after source/hold integration | 265 pass; sh_3253608258bec821cc3047cedbdbbe51 |
| Focused owner held checkpoint nonce/release | 1 pass; sh_4a3f5dacf1c4fe560f7c9a0d5e72b409 |
| Executor suite with journal/nonce tests | 56 pass; sh_97307aacbd4ad4d4534564e9e408751b |
| Real-daemon mounted encrypted unsupported/replacement path | 1 pass; sh_1519a50b0481e8d20dd294ecc53def0f |
| Cumulative required-daemon Bridge | 1042 pass, exit 0; sh_0da4d435c77f3995277e13bfe4df29d6 |
| ham-bridge package | exit 0; sh_04d5a7aa90594dbfdcf2ec803c7f808a |

Exact final integration commands:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-owner-notice-full-20261107-0750
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3b-executor-notice-20261107-0755
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-transport-bins-20261107-0719-1/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection -out:$HOME/.cache/heimdall-tests/m3b-notice-mounted-20261107-0801
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-transport-bins-20261107-0719-1/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -out:$HOME/.cache/heimdall-tests/m3b-notice-bridge-full-20261107-0802
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3b-notice-bins-20261107-0802
```

The full Bridge suite emits allocator warnings in existing bootstrap/config,
VCS/process/wake tests; it is not a leak-free resource gate. Focused new tests
have no allocator warnings. Rust transport was unchanged in this continuation;
the prior required-PTY 205+2 evidence is retained, not claimed rerun.

Failed drafts: the new source regression initially exposed empty remote
agent_id; preserve the committed Child instead of weakening equality.
A mounted test initially used the derived production socket rather than the
private injected socket; correction passes. One Odin multiline-do syntax and
one test variable redeclaration were corrected. Typecheck required restoring
the pinned posthog-js dependency through npm ci. Direct Node fixture generation
failed on extensionless imports; use the existing vaultEndpointHarness.

**Still required:** a positive connected original-owner-producer -> encrypted
exact-child PTY -> signed result/replay proof, including uncertain/partial I/O
through the new production path. The current actual daemon has only an
explicitly configured Readline InputProfile; no validated production native
Codex/Claude configurator has been established (delivery.rs:56,
daemon.rs:1052). The mounted production test establishes honest signed
unsupported_not_delivered with zero progress, not actual-provider delivery.
Native Linux/macOS literal Unicode/paste and interrupt evidence, Mac host
access, honest Windows limits, cumulative final gate and the named independent
review remain open. Never equate the synthetic signed fixture profile string
or Readline evidence with native provider support. No live restart, deployment
or push occurred. M3b must not be submitted as complete at this checkpoint.

Final native Linux probe results are recorded in docs/pty-provider-evidence.md: Codex exact literal/replay and separate raw ESC/acknowledged post-input observation; Claude exact TAB failure. Neither is a production interrupt-profile or Mac pass. Final TS20/typecheck rerun exited0 in sh_a6726eb21a37ef061c4d6720c79156d9 after claim_attempt exchange binding.


## M3b native profile continuation (2026-11-07 08:47 UTC; still incomplete)

The trusted Spawn request now carries a fixed codex-native-session-v1
declaration. The daemon independently validates native executable/version,
records its SHA256, and binds current-child SessionStart to one fresh exact
native session. Delivery requires a fresh structured abort of the captured
active turn before any paste, with no empirical settle-delay fallback. Native
session identity/header/prefix changes, stale/echoed/wrong-turn events, idle,
unknown state and timeout fail closed. See docs/pty-provider-evidence.md for the
exact trust contract, tested versions and native evidence.

The remote observation endpoint reuses existing signed executor child-token,
paired-directory, bootstrap/incarnation/deadline and exact daemon launch checks.
It accepts only native SessionStart observation, not arbitrary legacy extension
effects or a Hub token registration. This fixes the session-observation gap
without extending task authority. Native state is transport evidence only.

Verification so far (cwd this task worktree):

```bash
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_PTY_REQUIRED=1 CARGO_TARGET_DIR=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107 cargo test --locked --manifest-path tools/pty_host/Cargo.toml -- --test-threads=1
```

211 pass, 2 subprocess-only tests explicitly ignored and exercised by their
parent resource tests; integration safety tests 2 pass; exit0 in
sh_f0795a7c62d9d74b4370c95dcb2f5003. A later header-pin tightening reran the
focused notification suite successfully in sh_8b3c00dd3fe9bbc19abca97eeeb9ef5e.

```bash
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection -out:$HOME/.cache/heimdall-tests/m3b-native-profile-mounted-20261107-0845
```

1 pass, exit0, sh_b2e6074cc39d85e6e58842bd55c10fe7. This includes remote
SessionStart invalid-path/no-profile refusal through real current bootstrap auth,
wrong-token rejection and unchanged readiness/renewal behavior. Native Linux
interrupt=true daemon literal/replay passed in
sh_22f528f0bd6ebe2552e7154fec02a987; that probe supplies its exact disposable
SessionStart observation rather than exercising the complete owner producer.

Remaining: original owner hold producer -> encrypted executor -> real native
child -> signed owner result/replay proof, full affected cumulative gate, new
Mac source/profile rerun and named independent review. Original Mac f6a8f209
evidence remains separate. Claude TAB is failed with no waiver. Windows native
managed-shell access is blocked by invalid_vault_key. No complete submission,
live restart, deployment or push is authorized by this checkpoint.


### Native checkpoint cumulative and Mac follow-up (08:54 UTC)

The full Bridge gate passes1043 tests in sh_afb369b83aaa94af0fd34c91e02bebd9
with the same command above, output path
$HOME/.cache/heimdall-tests/m3b-native-profile-full-bridge-20261107-0850.
The first cumulative run had1040 pass2 failures solely in old Spawn wire-length
expectations; those golden arrays now include the optional native-profile byte
and a new present-profile trailing-option regression. Production native code
did not change for that correction. The ham-bridge package build passed
sh_4ea80b1f20972e7bd5484a0c8319312d:
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3b-native-profile-bins-20261107-0849.
Allocator warnings remain in existing Bridge tests; this is no leak-free gate.

A final native-header-pin source rerun passed real Linux interruption/literal/
replay in sh_947ffefcd8c097686027926685cc65cf. Mac worker reports actual
9e6b89af native profile PASS in sh_d3d9c7e817ff78d44afeca4944a67f13:
CLI/state0.162.0,130-byte literal once/replay and interrupt=true102-byte exact
once/replay after one fresh typed abort; model gpt-5.6-sol, native executable
digest fd4bb93679bfcc546765a3363a0df9a855f364b61ea6681009b28ba4c2e5b60d.
Mac cleanup/event audit and independent review remain separately tracked.

The Mac native suite at9e6b89af records17 pass3 fail. All four original platform
failures are fixed; three new parser fixtures failed because their synthetic
root retained Darwin's /var alias while production canonicalizes /private/var.
The test-only root helper now canonicalizes after mkdir; production containment
checks are unchanged. Linux focused notification suite after this correction:
20+2 pass, exit0, sh_460363b84abd9a118b2672be2cdfc3f9, same required-PTY
cargo command with filter notification. Mac must rerun the explicitly updated
source pin; the failing run is not erased. Full connected owner production
proof, Windows access/Claude disposition and named review are still required.


## Audit corrections after 7f13c94e (2026-11-07 09:12 UTC; not acceptance)

These corrections supersede the earlier native-profile capability description.

- F1: authenticated SessionStart now retains an immutable exact session/path
  observation without reading a not-yet-created file. PREPARE validates its
  canonical root, metadata/version, identity and header lazily. A unit test
  proves startup-before-file resolution. This is not the missing positive
  installed-hook -> authenticated observer proof.
- F2: clear/resume/unknown lifecycle sources or different startup observations
  permanently invalidate the profile. Both local and bootstrap-authenticated
  remote observation routes forward that lifecycle source. Pending input cannot
  continue after invalidation; completed receipt replay remains read-only.
- F3: Linux capability admission now checks the exact observed vendor executable
  SHA25650ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38.
  Native --version and PTY exec use the daemon-held file descriptor via
  /proc/<daemon-pid>/fd/<fd>, rather than reopening the original path. Tests
  reject an unknown native executable before a version probe and preserve the
  original inode across a pathname replacement. Actual descriptor-executed
  Codex interrupt/literal/replay passes sh_0d5fdeb5d38efb51a7cea42c354312db.
- F4: native session producer version must now equal0.162.0;0.167.0 is refused.
- F5: fixture IDs add a process-wide atomic suffix; native tests pass in default
  parallel mode.
- F6: an already validated same-ticket paste resumes its remaining bytes without
  re-polling the eight-second native acknowledgment horizon. Lifecycle/paste-mode
  invalidation still refuses writes.

Darwin native capability is conservatively refused in this hardened revision
until a safe immutable executable backend is demonstrated. This is an open
Milestone3 gate, not an accepted platform reduction; prior Mac native results
at9e6b89af/7f13c94e remain historical evidence. Source-backed backend choices:
portable-pty0.9.0/src/unix.rs:228-282 constructs a std Command and closes random
descriptors at pre_exec line276, so inherited /dev/fd execution is not currently
a proven Darwin substitute for Linux parent-procfd execution. Options to verify
are a narrowly scoped native spawn backend retaining exactly one verified
executable descriptor, or a vendor-hash-pinned canonical installation whose
file and every mutable ancestor are OS-enforced root-owned/non-writable to the
child. Neither option is implemented/proven here; no generic-copy/path-name
solution is claimed immutable. Same-uid writable native logs remain transport
evidence only, and bounded8MiB reads/hashes still hold the daemon agents lock.

Checks after corrections:
```bash
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_PTY_REQUIRED=1 CARGO_TARGET_DIR=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107 cargo test --locked --manifest-path tools/pty_host/Cargo.toml
```
Default-parallel214 unit+2 safety pass,2 subprocess-only ignores in
sh_49d5c145e7c4b73641e7a6b51040d9dd. The earlier full parallel run failed an
existing resize test race: Attach's first Screen preceded processing the next
one-way Resize. The fixture now waits up to3s for actual40x120 effect before
disconnect; the production resize path is unchanged. Serial212+2 passed before
the two new inode/digest tests (sh_31a297ad41171a297266f81b8b669440).
Final pending-lifecycle guard focused23+2 passes sh_9cab8796820d506dcfc5f3309dc50020.
Full hardened Bridge1043 pass sh_b6a5bf76c098c2d68e370f1519b53e4e with prior
required-PTY command/output m3b-audit-full-bridge-20261107-0903. ham-bridge
package build passes sh_31b3be554aaee07aecaed3a1f613fae4:
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3b-audit-profile-bins-20261107-0910.

Native hook prerequisite investigation:
The read-only installed native plugin inventory contains no Heimdall entry.
The strict --native-hook probe failed rather than using direct0x42 observation.
Official OpenAI docs https://learn.chatgpt.com/docs/hooks and installed0.162.0
help support project hooks plus --dangerously-bypass-hook-trust for automation
that vets exact hook sources. Coordinator explicitly authorized the inspected
private fixture only, with per-invocation flags and no persisted settings.
The --vetted-fixture-hook harness writes only a private project hook/script and
records SHA256/config/argv. Both lexical and canonical project trust -c keys
still reached a native Folder access prompt saying the decision will be saved;
no approval/input was sent. Sessions sh_ecd5a09147d6877d4cd1fc1ffba612b6 and
sh_807a73bad8bb4a6b88606c97141ed746 fail honestly. Last fixture source:
hook SHA2564aef8b5850f310c1f50c6e9895deeedef1eeddca9e42db827c5e1eb50d65cf4d,
config SHA256c064480da9bd5dd1d546690a50d28303a49b7d7ccf90becb435454ea610db353;
exact argv/screen retained in
/home/tanmay/.cache/heimdall-tests/provider-observe-64bc54afb4b64d31b4fbe1a63eb24128/.
No native hook pass is inferred. A supported disposable already-trusted real
extension launch is still needed, followed by the original owner hold producer
through encrypted exact-child dispatch, physical result/replay and owner
acceptance. Windows access, Claude TAB disposition and named audit re-review
also remain open. No complete submission, live restart, deployment or push.

## Immutable Linux executable snapshot (2026-11-07 09:20 UTC; incomplete M3b)

The inode-only F3 mitigation above is superseded. A retained read-only descriptor
does not prevent a same-UID writer changing that inode between admission and
execution. Linux now copies the bounded executable into a private memfd, adds
and verifies WRITE/GROW/SHRINK/SEAL seals, then hashes the sealed bytes. Both
version probe and PTY spawn execute the same retained sealed image via procfs.
Unknown hashes acquire no notification capability. Non-Linux and unavailable
memfd/sealing support remain unsupported. Owned File handles drop on error.
See tools/pty_host/src/native_notification.rs:47-78 and daemon.rs:603-604.
Regression covers original inode overwrite, path replacement, write/reopened
write, truncate/grow and seal change rejection.

Checks (M3b worktree):
```bash
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_PTY_REQUIRED=1 CARGO_TARGET_DIR=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107 cargo test --locked --manifest-path tools/pty_host/Cargo.toml native_notification
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_PTY_REQUIRED=1 CARGO_TARGET_DIR=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107 cargo test --locked --manifest-path tools/pty_host/Cargo.toml
nix develop --command env CARGO_TARGET_DIR=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107 cargo build --release --locked --manifest-path tools/pty_host/Cargo.toml
nix develop --command python3 tests/observe_provider_notification.py --daemon $HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host --provider codex --model gpt-6.1-sol --seconds 5 --literal --native-interrupt
```
Focused7 pass sh_5ae562e2b178001f24a9df64a7392b24. First full run
sh_4082b62d7873824add95c41c4d7082f7 failed existing lockless listener stale
socket assertion (213pass1fail2ignores); focused rerun1 pass
sh_e02836c465dfae7cc32f5262fcbc37db and full rerun214+2 pass,2 subprocess-only
ignores sh_ef70ece7b3d0fbc55281e500b420bb41. No socket behavior changed;
transient failure remains recorded. Release build exit0
sh_d6150de43f69de398a56582f55444486. Actual sealed-image Linux probe exit0
sh_b9bd1111843f4c304e6667c5bc71cd6d: CLI/state0.162.0,130-byte literal
once/replay and102-byte interrupt=true literal once/replay after one typed abort.
Direct native observation remains in this probe: no installed-hook/authenticated
observer or full owner producer pass inferred. Darwin safe image/native proof
remains open and enrolled Mac is offline. Windows native refusal/ConPTY evidence
6bd47371 remains evidence-only. No M3b completion implied.

Authenticated malformed SessionStart now permanently invalidates the native profile
before returning an error, including changed session with empty/relative path.
This closes a residual F2 ordering gap (old bound session otherwise survived).
Regression24+2 pass sh_6e2dd623f4218f5f1aaade2dd7232c6c using the same required
PTY cargo command above with filter notification. Completed receipt replay
remains read-only; invalidation blocks pending physical input.

Bridge lifecycle propagation now preserves authenticated malformed observations:
local token/current-launch route no longer drops empty native session/path;
shared remote-child helper validates runtime authority IDs separately and sends
a bounded invalid lifecycle observation for malformed native fields. Daemon
receives it only after current token/PID/epoch/count fences, then invalidates.
Route regression covers local startup queries plus the shared remote IPC helper,
8 observed frames, bad authority still rejected without IPC. Native invalidation
is verified separately in Rust; no complete remote/native integration inferred.
Focused Bridge1 pass sh_c0d6ece3c109c0b6181328ea7d8fac3f:
```bash
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.pty_notification_malformed_lifecycle_reaches_daemon_after_current_child_fences -out:$HOME/.cache/heimdall-tests/m3b-malformed-route-20261107-0925
```
Actual callback mechanics now passes using session inline hook config instead
of project .codex config, avoiding persisted folder trust. Official source:
https://learn.chatgpt.com/docs/hooks (session config hooks and one-invocation
reviewed-source flag). sh_0379e09bb569a80b1151d660ac13d90b exit0 using prior
native probe command plus --native-hook --vetted-fixture-hook: actual startup
callback bound native session,130/102-byte literal/interrupt submissions once,
replay no duplicate. Evidence provider-observe-fb41c8fe3f5a44d5bb4dca861bdfdb31.
This script still calls daemon0x42 directly and is fixture mechanics only;
production ham-ctl extension/Bridge observer and full owner producer remain open.
No saved native trust/config changes or credential export.

## Connected original-owner native proof (2026-11-07 10:03 UTC; incomplete M3b)

The Linux gap is now covered by a genuine owner producer, not manually inserted
owner authority or a signed unsupported fixture. Native gate is explicitly
EXECUTOR_NATIVE_OWNER=true; ordinary Bridge tests skip the provider invocation.
Source: src/bridge/owner_executor_native_test.odin:60 creates signed chain/task/
policy/reservation/requirements through owner APIs, execution_prepare_assignment,
real mounted encrypted prepare, original prepare_commit and execution_bootstrap.
Its :124 actual private socket receives ham-ctl extension hook codex output and
uses the production current-bootstrap/paired-directory observer. :197 calls
production prepare_spawn/materialize before reviewed invocation-only hook flags.
:162 preserves signed encrypted current owner nonce callbacks without holding
executor/startup mutexes. :357 injects only a result-journal storage failure
AFTER physical output, recovering the original ticket/receipt. :404 restarts
the private daemon after exact child close: the new daemon reports UNKNOWN exact
launch state and an empty roster; completed result replay remains read-only.
:461 pairs a distinct normally enrolled test owner and calls production
bridge_owner_executor_accept, rejecting altered pending-scope AAD before accepting
the authentic response. Original lease/attempt/bootstrap counts do not grow.
This is a mounted production-handler proof with hermetic reverse transport;
it is not a new live Hub/remote-network enrollment demonstration.

Real Codex SessionStart occurs on the first user turn, not the idle composer.
The fixture's initial non-interrupt paste waits for explicit daemon paste-mode
support; it preserves literal LF/TAB/euro/Japanese/astral content exactly once.
The native callback invokes the actual built ham-ctl adapter, not direct0x42.
Owner task.hold then produces the exact66-byte one-line notice. The real native
turn aborts once, notice submits once, partial result/lost persistence/replay
reuse one immutable ticket. Stale launch epoch and altered result scope fail.
Actual signed result returns through production owner acceptance and settles
only delivery evidence; no new lease, attempt, bootstrap or task authority.

The first complete physical run exposed native Codex trimming a FINAL newline
from the notice (exact0 / without-final-LF1 / typed-abort1 in
sh_b8c5ca5e567c7e578e3a2892a9f45f52). The one-line producer and fence message at
src/lib/owner_local/execution_notification.odin:77,134 now omit this unnecessary
finalLF. Enter stays a separate transport boundary. The owner unit asserts exact
text, and the arbitrary multiline Unicode initial input remains byte-exact;
no blanket normalization was introduced. This prerelease format change is not
permission for a live upgrade of already pending old-format delivery stages.

Reproduction from the M3b worktree (normal provider auth stays in its store;
no export/copy, saved hook trust/config changes, production tokens or endpoints):
```bash
nix develop --command python3 tests/prepare_native_owner_notification.py --out $HOME/.cache/heimdall-tests/native-owner-args-final-20261107-1002.json --ctl $HOME/.cache/heimdall-tests/m3b-native-ctl-20261107-0931/bin/ham-ctl --codex /home/linuxbrew/.linuxbrew/bin/codex
nix develop --command env HEIMDALL_NATIVE_CODEX=/home/linuxbrew/.linuxbrew/bin/codex HEIMDALL_NATIVE_MODEL=gpt-6.1-sol HEIMDALL_NATIVE_ARGS=$HOME/.cache/heimdall-tests/native-owner-args-final-20261107-1002.json HEIMDALL_NATIVE_CTL=$HOME/.cache/heimdall-tests/m3b-native-ctl-20261107-0931/bin/ham-ctl HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_NATIVE_OWNER=true -define:ODIN_TEST_NAMES=main.test_executor_original_owner_native_notification -out:$HOME/.cache/heimdall-tests/m3b-owner-native-final-20261107-1004
```
Final native1 pass sh_b29ecfce43bb535588e125fadc22b5bb,4.74s, real PID3103501,
66-byte notice/submission1/typed-abort1/callbacks5, stale request refusal,
partial + lost-result recovery, same-ticket replay after daemon journal loss,
wrong-AAD owner rejection and authentic production owner acceptance. Earlier
connected proof without host-loss negative variant also passes
sh_b433d550124996c3ef2f2e9132a5f48d. CLI/state0.162.0 and exact vendor SHA
50ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38 only.
Actual ham-ctl SHA f5a6674a72089664be9cbdc5fc77c22bf82bd323d4ed969658226dd34710e754;
repo hook source SHA801b83d72454d057ab4ad73dd6a5bcc6fa7acd955a99f2a0598621f4df02c8bd.
Arguments/source manifest sh_ea0f1aacfc647db57500a334549278b8; rendered wrapper
hash and actual redacted argv appear in each native run. Wrapper records native
callback mechanics then calls the same repo CLI command. All fixture services,
identities, runtime directories and sockets are private and cleaned.

Full owner265 pass sh_28e38dfa86e4147c71e73ae4ebe2ebd9 using:
```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/m3b-native-owner-full-20261107-0956
```
Earlier hardened full Bridge1044 and package passed before this owner correction;
latest full Bridge/package checks follow. Rust215+2 serial and release pass
sh_e1a1425be99ad3ad8600e48500a56039; independent final parallel215+2 pass is in
e2f9a89a delta audit. Retain worker parallel FD-exhaustion subprocess failure
sh_c22cd0ac3341d236d825d07fd554733a and prior stale-socket transient; no silent
retry-only claim. Fixture development failures included do-body/return syntax,
missing private runtime base/profile binary, idle callback assumption, wrong
activation-vs-notification ingress, owner consent/scope mismatch, missing fresh
owner enrollment floor, and expecting journal loss to imply known absence.
Final fixture uses normal signed enrollment/current fences throughout.

No full M3b completion/rollout is implied: hardened Darwin safe image/native
proof remains open (Mac offline; source report e624fc84/artifact art_18e5b8e6ebe7f0ba),
Windows repair integration/review and Claude TAB disposition remain separately
gated, and this connected delta needs named independent review. Previous
Linux audit e2f9a89a closes F2-F6 only within its reviewed evidence boundary.

Final cumulative checks on d2864a05 source (2026-11-07 10:06 UTC):
```bash
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -out:$HOME/.cache/heimdall-tests/m3b-native-owner-full-bridge-20261107-1005
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3b-native-owner-bins-20261107-1005
```
Full Bridge1045 pass sh_ec11503a488c802872ddb180dedad7e9; includes explicit
native opt-in skip in the ordinary suite. Separate actual native proof above
supplies that evidence. Existing allocator warnings persist; not a leak-free
gate. ham-bridge package exit0 sh_cb492ccbee9da9d36c2ddbfbb87a0ee4.
Cleanup/config audit sh_904d99d5f4eec19cfc5669b01d2e6eb1: no private native
processes, native PID3103501 absent, original native config SHA256 unchanged
(d111397be1b38940d9b795a64f8b75dc61a659e98895d6aff0a41ba372aba6cf).
Removed14 old unheld private daemon lock files only after verifying same UID,
no socket and exclusive flock; final fixture removes its own socket and lock.
Independent connected-delta audit task_18e5bb3fa781e488 is pinned through
source d2864a05, with a separate named safety reviewer. Its verdict is pending;
no full milestone approval, live restart, deployment or push.

## Pending partial notification journal loss (2026-11-07 10:20 UTC; incomplete M3b)

The optional EXECUTOR_NATIVE_PENDING_LOSS mode in
src/bridge/owner_executor_native_test.odin:378 reuses the original signed owner,
production prepare/bootstrap, real Codex SessionStart hook and encrypted hold
notification. It stops at the first signed partial result: ESC written, zero
message bytes and no Enter (:379). The daemon is killed without first closing
the child, then restarted on the same private socket (:389). Exact launch query
is UNKNOWN (:395); Query of the original saved ticket returns recovery_required
(:401). This status is successful observation of uncertainty, not delivery or
known absence (tools/pty_host/src/delivery.rs:130).

Production reconciliation runs at the current time (:405); three encrypted
production notification retries return child_unavailable with no additional
owner callback (:407). The original durable ticket is byte-identical, no final
result exists and the shared live-resource charge stays1 (:413). A revoked-key
input and request-expiry boundary fail the current check (:419); this is direct
current-check coverage, not a new signed directory-revocation demonstration.
Normal signed task.cancel then makes the owner reject a fresh pending nonce
with no_current_target (:423). Actual native transcript contains zero notice
submissions and at most one interrupted turn; task lease/attempt/bootstrap
counts do not grow (:434). A production reconciliation sweep with its clock
advanced past the signed reservation expiry attempts exact cleanup but retains
charge1 and only the original ticket/dispatch evidence (:440). Test-only child
cleanup uses bridge_shell_test_kill_pid (:292), never an authority observation.

This proves safe refusal with retained ambiguity. It does not prove eventual
delivery, recovery of a lost daemon journal, or authoritative absence/capacity
release. The ordinary native mode separately still proves eventual delivery
when the original daemon receipt survives, followed by completed-cache replay.
No production code changed in this delta.

Exact native reproduction (same reviewed invocation-only fixture, no saved
trust/config/auth changes):
```bash
nix develop --command python3 tests/prepare_native_owner_notification.py --out $HOME/.cache/heimdall-tests/native-owner-pending-20261107-1017.json --ctl $HOME/.cache/heimdall-tests/m3b-native-ctl-20261107-0931/bin/ham-ctl --codex /home/linuxbrew/.linuxbrew/bin/codex
nix develop --command env HEIMDALL_NATIVE_CODEX=/home/linuxbrew/.linuxbrew/bin/codex HEIMDALL_NATIVE_MODEL=gpt-6.1-sol HEIMDALL_NATIVE_ARGS=$HOME/.cache/heimdall-tests/native-owner-pending-20261107-1017.json HEIMDALL_NATIVE_CTL=$HOME/.cache/heimdall-tests/m3b-native-ctl-20261107-0931/bin/ham-ctl HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_NATIVE_OWNER=true -define:EXECUTOR_NATIVE_PENDING_LOSS=true -define:ODIN_TEST_NAMES=main.test_executor_original_owner_native_notification -out:$HOME/.cache/heimdall-tests/m3b-owner-pending-loss-20261107-1019
```
Manifest sh_f455cfc8ef8ae0908699e665f4aedb2f; native pending test1 PASS in
sh_15f0d1520b27b96105f79a3a259ae6c6 (3.46s, PID3127772, notice0/abort1/charge1).
Earlier sh_2408cd1dd486a02e62090e9a0d6fdfba also passed before adding actual
reconciliation/expiry sweeps. First sh_e536cc45e4d7a0b659dd3f28b059d523 failed a
fixture assumption that unknown-ticket Query must be an IPC error; corrected
to require the actual recovery_required receipt. No production defect inferred.
Native normal-mode regression1 PASS in sh_76a1eb0e977e0c6f8aa8b0583deb5f80
(4.16s, PID3128945, notice1/abort1/callbacks5), using the exact native command
above without EXECUTOR_NATIVE_PENDING_LOSS and with
-out:$HOME/.cache/heimdall-tests/m3b-owner-normal-regression-20261107-1020.

Full required-daemon Bridge1045 PASS (58.37s, exit0) in
sh_f3892ed9c47f882576b4b1d2f3886169:
```bash
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -out:$HOME/.cache/heimdall-tests/m3b-pending-full-bridge-20261107-1021
```
The suite explicitly skips old-daemon compatibility without
HEIMDALL_EXECUTOR_OLD_PTY and native-owner opt-in (covered separately above).
Existing allocator warnings remain, not a leak-free result. No new package,
owner or Rust rerun: only Bridge test code and this checkpoint changed; earlier
production package/owner/Rust evidence remains attributed to its source.
Cleanup sh_6d75dd5cc2b82d76d0fcc0bbaf779d13 verifies all four native run PIDs
(3125480/3126550/3127772/3128945) absent, no native-owner/hook sockets or locks
created since this run began, and first failed fixture workdir removed. Native
config SHA256 remains d111397be1b38940d9b795a64f8b75dc61a659e98895d6aff0a41ba372aba6cf.

Named review approved connected audit e4ca4ae9 for890f87eb..d2864a05 only;
this new pending-loss delta still needs independent review. Coordinator reports
Windows12838668 repaired, reapproved and merged, with notification explicitly
unsupported. Darwin source investigation e624fc84 is reviewed but Mac remains
offline; no hardened safe-image/native pass. Claude2.1.319 literal TAB becomes
four spaces in actual transcript (docs/pty-provider-evidence.md:121), with bounded
vendor-code investigation at :130. Exact TAB remains failed/unwaived; no text
normalization, API substitution or new provider support is claimed. Idle/unknown
native state remains unsupported. Full M3b/platform and cumulative recovery
gates remain open; no live restart, deployment or push.

## Real idle refusal and provider matrix (2026-11-07 10:31 UTC)

New opt-in EXECUTOR_NATIVE_IDLE_REFUSAL uses the same original-owner/native
proof, with a short exact Unicode/LF/TAB first prompt and bounded wait for the
actual completed turn. Source src/bridge/owner_executor_native_test.odin:299,346
and :527. Two production idle retries return signed unsupported_not_delivered
with no ESC/text/Enter (:549); signed task.cancel denies the owner nonce (:560).
A real device-signed enrolled-owner-key revocation advances the directory pin4
despite missing next epoch content key, and an older directory cannot reach a
fresh callback (:569). No notice submission or abort, one unchanged ticket,
charge1 and no lease/attempt/bootstrap growth (:595). Native1PASS5.58s in
sh_fccfda47c755776dcf34871798eba283,PID3141451; required-daemon Bridge1045PASS
59.16s in sh_f4166e587edeabe16697c0a514cd1437. Exact commands, draft failures,
cleanup and source-cited unsupported/enabled matrix are in
docs/m3b-provider-support-matrix.md. No production implementation changed.

The previous pending-loss section's source line references are pinned to
c61dad29. Its independent audit89bfda15/artifact art_18e5bc7e475b471c is now
named-review approved for87b6df96..c61dad29 only. That scope proves safe refusal,
not eventual recovery, authoritative absence, persistent Bridge restart or
full M3b/platform acceptance. This new idle delta needs independent review.

Claude2.1.319 installed paste-handler inspection reconfirms TAB replacement
before large-paste collapse; no supported exact-TAB current-PTY route is proven.
Official external-editor and print stream-JSON options are different transport
approaches requiring separate approval/design, not substitutions or waivers.
Mac still needs online access and a proven hardened executable backend. Full
milestone remains incomplete; no live restart/deployment/push.
