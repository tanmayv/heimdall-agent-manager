# M3 local admission foundation audit

No confirmed blocking defect was found in this interim foundation audit. Independent checks passed 44 executor-store tests, 37 native contract tests, and 2 Bridge tests including the packaged real-daemon lifecycle proof. Two integration follow-ups below require explicit handling before production wiring. This report grants no full Milestone 3 acceptance.

## Immutable provenance

- Audit task: task_18e5aae29be28072; parent: task_18e5a16377e1ae67.
- HEAD: `30d313b3819d21f4f5490e3102eb4c41359f41df`.
- BASE and verified HEAD parent: `d62a9a8ef81319c93e0b1a45f52b638b340fa552`.
- Engineer's checkpoint announcement: `cmt_18e5ab16439b7609`.
- Snapshot: unmodified `git archive HEAD` extracted under the audit Workdir's `.audit-snapshot`; no inspection of the engineer's moving source tree.
- Archive SHA-256: `c8999301a4bd6f46a2f671c958669b46e5c4ff2ef865d78cdd5bd524d453b667`.
- Approved plan: `docs/plans/bridge-owned-runtime-local-search.md@1c83a464f19ded8ba967ecda24130d9e12fa4ef4`; source SHA-256 `480cf0886216223be675fb62ea1f98fe43a84260246b083ec225e666d025a65a`. Relevant requirements: signed device authority, shared slot ledger, canonical protected directory and warm charge until trusted exit.
- All source references below refer to HEAD above. Later engineer changes are outside this audit.

## Severity-ranked actionable follow-ups

### P2: enforce fresh resource/key resolution in the future production wrapper

This is a caller-contract integration risk, not a demonstrated production exploit or a confirmed defect under the helper's documented preconditions.

`src/bridge/executor_local_launch.odin:17` checks filesystem canonicalization and current catalog/profile/model. Dispatch at line 38 accepts an already-created `Local_Resources` and verified key. It neither invokes that resolver nor acquires the documented startup/vault gates itself. `src/lib/executor_local/local_launch.odin:93` rechecks current SQL mapping/policy, while line 157 checks durable dispatch/time/signature using the supplied key. Neither establishes fresh filesystem/catalog or paired-enrollment state.

When wiring delayed device consent, do not reuse draft-time resolver/key snapshots as current authority. Resolve again under the shared gates immediately before first I/O; serialize dispatch against reconciliation. Add mounted tests for revoked enrollment, directory disappearance/alias replacement and disabled catalog/profile while consent is pending. Preserve the helper's exact-Spawn digest and query-only retries.

### P3: provide an explicit recovery route for abandoned undispatched admissions

This is an operational follow-up consistent with the deliberate no-timeout-refund policy.

An admitted row survives `Store.open` at `src/lib/executor_local/store.odin:64`. Old-incarnation first dispatch fails at `local_launch.odin:88`, and reconciliation candidates at line 140 exclude admitted rows. Such rows remain in the live-resource union and block directory/policy drains until `cancel_local_admission` at line 120 is invoked.

Production draft/consent cancellation and restart recovery should expose exact journal identity and explicit cancellation for undispatched rows. Add an admit-before-dispatch/reopen/cancel regression. Do not apply this cancellation shortcut to dispatching, active or stopping rows.

## Boundaries checked

| Boundary | Evidence and assessment |
| --- | --- |
| Signed authority | `src/contracts/executor_local_launch.odin:5` and `executor.odin:181,245,261`: distinct canonical domain, exact field schema, bounded transport lifetime, enrolled nonrevoked device key bound to account/key/principal. Full raw configuration digest binds purpose, physical identity and Spawn digest. No task/chain/lease fields are admitted. Fresh enrollment resolution is the caller obligation above. |
| Replay | `src/lib/executor_local/local_launch.odin:29-40`: signature/scope/configuration digest checked before operation lookup; changed input conflicts; unchanged replay returns original retained identity/state before fresh capacity/time checks. It cannot reacquire first dispatch. Revoked supplied keys fail even on replay. |
| Shared resources | `schema.sql:187`, `migration_007.sql:60`: local and task-owned live rows share one union with bilateral insert guards for total capacity, slot, instance and nonempty protected directory. `store.odin:143` and `directories.odin:51` require both classes drained for policy/mapping changes. Slots are trusted signed static allocations; this does not independently prove entitlement allocation across devices. |
| Migration | `store.odin:44-69` migrates inside the opening transaction; identity checks precede mutation and failure rolls back. V7 rebuilds runtime header consistently. `local_launch_test.odin:165` exercises genuine V6 schema collision, rollback and successful retry preserving active remote reservation. |
| First I/O | `local_launch.odin:83,157,170`: durable single consumption, incarnation fencing, saved monotonic tick plus wall checks. `src/bridge/executor_local_launch.odin:42` rereads durable state before selecting first dispatch versus query-only recovery. No SQL transaction spans daemon I/O. |
| Physical identity/lifetime | `tools/pty_host/src/daemon.rs:371,518,780,810,851`: local marker requires exact launch key and excludes owner deadline/renewal fields; local lifetime uses only optional native timeout. Serialized daemon lifecycle, full request digest, retained launch state and exact-key stop/query prevent replay launches and stale replacement stops. Executor Restart is rejected. |
| Capability | `src/bridge/pty_executor.odin:46`, `tools/pty_host/src/dproto.rs:787`, `daemon.rs:1750`: distinct local capability 0x41 and expected Pong gate before fenced Spawn. Historical-daemon compatibility was not independently exercised. |
| Observations/cleanup | `local_launch.odin:105,128,147`: exact instance/key/current incarnation required; stopping stays stopping on presence, absence releases transactionally and released rows cannot revive. `executor_reconcile.odin:44` serializes local sweep with startup I/O. `actions.odin:135` readiness waits for unobserved local and remote children. Unknown daemon ledger keys retain charge. |
| Crash limits | Crash after dispatch consumption but before daemon receipt remains uncertain/query-only; daemon loss cannot establish absence. These fail-closed availability limits are intentional, not evidence of a duplicate launch or permission to refund by timeout. |
| Authority separation | Local journal and daemon mode do not create owner/task grants or mutate authoritative task state. Physical presence remains separate from a task lease. |

## Independent verification

Commands ran in the immutable snapshot under:
`/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e5aae29be28072/.audit-snapshot`.

```bash
nix develop path:. --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-audit-executor-20261107-0511
nix develop path:. --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/m3-audit-contracts-20261107-0511
nix develop path:. --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3-local-admission-bins-20261107-0505-1/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -define:ODIN_TEST_NAMES=main.bridge_executor_local_resolver_rechecks_catalog_mapping_and_full_spawn,main.bridge_executor_local_real_daemon_lost_observation_restart_and_exact_stop -out:$HOME/.cache/heimdall-tests/m3-audit-bridge-local-20261107-0513
```

| Check | Outcome | Managed session |
| --- | --- | --- |
| Executor store | 44/44 PASS, exit 0 | sh_df6197e210beb62254d0c996be7e9a2b |
| Native contracts | 37/37 PASS, exit 0 | sh_cda630e8ed44e81d026fbe5d50fc7d76 |
| Resolver and required real daemon | 2/2 PASS, exit 0 | sh_f63741412819c7c84a300ce9c95ce071 |

The daemon executable is the engineer's checkpoint package, not an independently rebuilt binary; Bridge test source compiled from the pinned archive. The daemon test covers lost observation commit, old-snapshot retry retaining PID, ledger reopen/reconciliation, exact stop/refund, replacement stale-stop rejection and daemon-loss retained charge.

Initial plain `nix develop` attempts failed before compilation because Nix selected the parent Git repository and its untracked archive path. Explicit `path:.` corrected selection. Those failures are harness failures, not source regressions. No production code or test source was modified.

Full Rust190, owner264, TS7/typecheck and package build outcomes are engineer-reported checkpoint evidence at `docs/executor-dispatch-checkpoint.md:2071`; they were inspected, not rerun. Broad repetition was unnecessary for this source-only audit after focused checks passed.

## Known incomplete milestone gates

`src/bridge/hub_runtime_client.odin:2670,2701,2773` still reaches the legacy production launch path. Local adapter calls are currently tests/internal helpers. Production manual/warm/provider-test admission and device-consent/durable-draft transport remain knowingly unwired; these are not newly discovered foundation defects.

Encrypted PTY/result delivery, bracketed paste, actual Linux/macOS provider interrupt profiles, documented Windows limits, historical-daemon behavior, full executor/owner crash and cross-owner integration, and final independent current-submission review remain required. This immutable interim audit cannot approve later code or replace the named final M3 reviewer.
