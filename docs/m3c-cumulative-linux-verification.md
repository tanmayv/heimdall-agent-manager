# M3c cumulative Linux runtime verification

**Historical attempt-1 report:** named review rejected `4cfa224f` for remote
activation resource revalidation and remote-stop routing gaps. Passing suites
below did not cover those interleavings. The repairs, intended-behavior tests,
current exact-head checks and actual Codex rerun are documented in
`docs/m3c-remote-runtime-repair.md`. Independent re-review remains required.

Current Linux Codex scope is ready for independent cumulative review under revision 3 of `task_18e5ac3dd21cf93e`. This work verifies the retained runtime and dependency deltas, adds two missing fault/race checks, and maps the original requirements to actual source and evidence. It does not grant its own review approval. Real Mac execution and Claude PTY notifications are explicitly deferred and remain disabled/unsupported; Windows notifications remain unsupported. Future Claude support retains exact bytes without normalization or another transport.

## Provenance and change

Starting head is `08ed6adee3e82b330aa8e063ad2cc84e7ace41ad`. Direct ancestry checks passed for every required checkpoint: `fea2f510`, `8edc0310`, `edcac849`, `4dbcecfc`, `de32e5a1`, `e864d7b2`, `d62a9a8e`, `30d313b3`, and `65557436`. No duplicate import, branch reset or unrelated history merge was needed. Dependency M3b `726b938e` is inherited via its reviewed merge.

Test commit `ed86718a` modifies only:

- `src/bridge/executor_local_launch_test.odin`: real daemon/control-endpoint disconnection, repeated query-only retries, queued stop, ledger reopen and reconnection. The original PID survives disconnected retries; capacity stays charged through the unacknowledged stop and reopen; exact known stop/absence finally releases it. Existing daemon SIGKILL/unknown-key refusal remains.
- `src/lib/executor_local/store_test.odin`: the genuine signed two-owner barrier race now independently collides on slot, instance and protected directory. Each case uses a fresh ledger, distinct other resource keys and exactly one successful prepare/receipt.

No production behavior, contract, authority or capability changed. [Selected logs and exact test-source hashes](artifact://art_18e5c3916a576662) are also committed as `docs/evidence/m3c-cumulative-linux.json`.

## Original requirement map

Source references below describe test commit `ed86718a`; unchanged production references are inherited at its parent.

| Original requirement | Current production path and verification |
|---|---|
| REQ-M3-1: shared slots, manual/warm/directory exclusion, durable owner commit/activation | Union `src/lib/executor_local/schema.sql:187`; signed prepare and dispatch journal; current native staging `src/bridge/executor_local_native.odin:195`; ordinary/provider-test ingress `src/bridge/hub_runtime_client.odin:2569` and `:2576`. Signed two-owner slot/instance/directory barrier tests at `src/lib/executor_local/store_test.odin:172`; manual-versus-remote race `local_launch_test.odin:122`; actual manual/warm/native scenario `src/bridge/executor_local_native_test.odin:40`. |
| REQ-M3-2: old runtime/deadline/stop/result fencing and safe lost replies | First permission consumed durably at `src/lib/executor_local/actions.odin:170`; physical retries query only at `src/bridge/executor_runtime.odin:24`; exact query/observation at `:103`; local retry boundary `src/bridge/executor_local_launch.odin:46`. Current store56, owner265 and required-daemon Bridge1045 all pass, including stale replacement stop, late callbacks, clock and renewal version tests. |
| REQ-M3-3: encrypted identity-bound notification/results, actual provider evidence and platform limits | Signed encrypted exchange `src/bridge/executor_exchange.odin:109`, immutable owner binding `:116`, notification dispatch `:122`, result encryption `:127`. Linux Codex connected actual-owner native audit `e4ca4ae9` retained; it proves literal Unicode/LF/TAB, same-turn typed interrupt and once-only partial/lost-result reconciliation. Contracts40 and UI23 current checks verify signatures/AAD/correlation. Mac/Claude are explicitly deferred by revision3, not passed; Windows refuses. |
| REQ-M3-4: independent crash/duplicate/cross-owner evidence, no executor task authority | Actual SIGKILL at issuance/prepare/activate/launch ledger boundaries; actual daemon kill/restart; current disconnected exact-stop recovery and signed barrier races. Existing named native connected/hostloss/idle audits remain scoped. This task requests the required independent cumulative review; those audits do not blanket-approve it. |
| REQ-M3b-1: production preparation/query/outbox, restarts/lost replies/cancel | Owner prepare initiation tests `src/lib/owner_local/execution_prepare_test.odin:10`, restart `:54`, cancel `:76`; worker retained-response/late-reply tests `src/bridge/owner_local_executor_test.odin:78` and `:112`; real signed mounted ingress `src/bridge/executor_issuance_test.odin:67`. Current suites execute these. |
| REQ-M3b-2: global manual/warm admission and fresh resource/identity checks | Native stage and signed relay under shared gates; P2/P3 mapping below. Signed total-capacity/slot/instance/directory constraints apply to both local and remote live rows; no opportunistic quota borrowing. Existing drain/rollback tests and new independently contended resource races pass. |
| REQ-M3b-3: encrypted PTY/result/literal/interrupt | Current Linux Codex native evidence retained; deferred Mac/Claude and explicit Windows limits are in `docs/m3b-provider-support-matrix.md`. The actual provider proof is separate from shell/Readline or signed fixture checks; no shell pass is relabeled as provider support. |
| REQ-M3b-4: crash/duplicate/cross-owner evidence | Same cumulative fault table below, with independent current review requested. Executors attest exact children and relay already-issued owner operations; no task grant authority is introduced by this test delta. |

Static device budgets are signed allocations; tests establish local enforcement and drain-before-reallocation. They do not invent an independent entitlement allocator across devices.

## Connected failure evidence and exact limits

| Failure | Actual boundary exercised | Result and evidence |
|---|---|---|
| Ledger process SIGKILL | Separate probe processes killed after committed issuance, prepare, activate and launch permission; reopen in a new process | One Python test with four subcases passed, session `sh_d2dae96c29e028e18efca02c2ffa548b`; `tests/test_executor_process_crash.py:18`. This is isolated ledger evidence, not provider execution. |
| Physical Spawn succeeded, observation write failed | Actual packaged daemon launches child; SQLite observation trigger rejects persistence | Retry retains original PID, no new Spawn; ledger reopen and exact recovery pass in `src/bridge/executor_local_launch_test.odin:16` and mounted native scenario `src/bridge/executor_local_native_test.odin:334`. |
| Disconnected control endpoint, stop lost, journal reopened | Real socket connection attempts to unavailable private endpoint while original daemon/child stay live | New test at `src/bridge/executor_local_launch_test.odin:80`: repeated retry stays uncertain/charged; stop remains charged across reopen; reconnect stops original exact key and then releases. This is local IPC disconnection, not an external WAN partition or live Hub outage. |
| Daemon SIGKILL and empty replacement journal | Actual daemon process killed, verified own child cleaned, new daemon started | Unknown prior key stays uncertain/stopping and charged; empty registry never proves absence. Current full Bridge suite reruns `src/bridge/executor_runtime_test.odin:193` and local lifecycle test. No eventual recovery/refund is claimed. |
| Competing owners | Real barrier-synchronized threads with independent signed owner inputs | Slot, instance and directory each admit exactly one prepare/receipt at `src/lib/executor_local/store_test.odin:172`; local/manual-versus-remote slot race and cancel-versus-first-I/O races also execute in current store suite. These are concurrent storage calls, not a claim of two physical remote machines. |
| Signed activation callbacks, cancellation/restart, lost replies | Production mounted handlers with actual paired P256 directory/signatures and channel encryption; callback transport is injected | `src/bridge/executor_issuance_test.odin:281` and bootstrap real-child helper at `:504` execute in full Bridge suite. Conflicts/restart refuse; duplicate activation retains child/key; readiness, heartbeat and signed physical renewal use exact child. Injected callback transport is not a separate enrolled network demonstration. |
| Actual provider partial/lost-result/duplicates and owner revocation | Previously named-reviewed Linux Codex original-owner connected proof, pending-hostloss and idle variants | Audits `e4ca4ae9`, `89bfda15`, `873aa65c` retained. Busy-turn exact delivery differs from hostloss/idle refusal. No new provider run was needed for this test-only delta. |
| Client lost reply/reload | Mounted approval component plus current signed request/encrypted reply validation | Current UI test23 pass, including retained exact operation after reload and fresh enrollment verification. Not a new browser-to-live-Hub rollout demo. |

The failure model combines production mounted-handler tests, actual child/daemon processes, actual ledger process crashes and retained reviewed provider evidence. It does not claim one physical multi-machine end-to-end WAN-failure run. The named reviewer must assess this explicit evidence against the cumulative requirement, rather than infer a broader pass.

## P2 and P3 disposition for named verification

The immutable interim audit is `docs/audits/m3-local-admission-30d313b3.md`; its source was foundation `30d313b3`, before the production wrapper existed. It did not close either integration follow-up.

**P2: fresh resource/key resolution before first I/O.** Current `src/bridge/executor_local_relay.odin:167` acquires startup serialization and vault authority, fetches paired directory at line170, resolves the current key at line172, holds launch-configuration read serialization, rebuilds current resources at line179, then dispatches at line202. Cancellation refreshes the key too at lines112-122. The native scenario at `src/bridge/executor_local_native_test.odin:40` exercises disabled catalog/profile, missing/changed directory, replaced mapping and revoked enrollment while consent is pending. The dedicated revoked-cancel test at line36 covers revocation while waiting for the startup gate. Full Bridge1045 current pass includes these. This is implementation evidence for closure, subject to the named cumulative reviewer.

**P3: explicit recovery/cancel for abandoned admissions.** Signed device-owned draft commands enter `src/lib/executor_local/local_draft.odin:102`; local consent cancellation is not an unsigned Hub action. The mounted relay test `src/bridge/executor_local_relay_test.odin:20` reopens and cancels with exact signed identity. Native signed cancellation at `src/bridge/executor_local_native_test.odin:365` retains a dispatched charge on observation failure, then releases only after trusted exact stop. UI controls at `src/ui/components/agents/LocalLaunchApproval.tsx:100` expose prepare/inspect/authorize/cancel; the current mounted UI test validates exact operation retention and fresh enrolled replies. Store tests `local_draft_test.odin:55`, `:80`, `:144` cover reopen/replay, dispatched-charge retention and signed cancel racing first dispatch. No timeout shortcut refunds uncertain work. This is evidence for named closure, not self-approval.

## Current checks

All commands ran through managed shell in:

```text
/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e5ac3dd21cf93e
```

| Check | Result | Session |
|---|---|---|
| Final executor store, including three independent resource races | 56 passed, 9.03s | `sh_f8f4bca5df78a1deb97cd95e803ea9a0` |
| Owner store | 265 passed, 131.81s | `sh_d2dae96c29e028e18efca02c2ffa548b` |
| Real SIGKILL harness | 1 passed, four boundaries | same session |
| Final required-daemon Bridge | 1045 passed, 59.22s | `sh_f8f4bca5df78a1deb97cd95e803ea9a0` |
| Focused disconnected lifecycle | 1 passed, 0.93s | `sh_2df2e61edc4692fef193e033dfc99715` |
| Contracts / UI protocol and approval | 40 / 23 passed, no UI skips | `sh_c8611a4612e62bbaf20149850f5e083e` |
| Bridge and PTY Nix packages | exit0 | `sh_73c3cf1e1c0e22a8802482a975d8bc81` |

Exact commands:

```bash
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/m3c-executor-final-20261107-1235
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/m3c-owner-20261107-1233
nix develop --command odin build tests/executor_crash_probe -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/m3c-crash-20261107-1233
nix develop --command env HEIMDALL_EXECUTOR_CRASH_PROBE=$HOME/.cache/heimdall-tests/m3c-crash-20261107-1233 python3 tests/test_executor_process_crash.py
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/mac-guard-pty-package-20261107-1134/bin/ham-pty-host HEIMDALL_EXECUTOR_OLD_PTY=$HOME/.cache/heimdall-tests/c1f-v24-bins-3/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -out:$HOME/.cache/heimdall-tests/m3c-bridge-final-20261107-1235
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/m3c-contracts-20261107-1236
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_contract_test.ts tests/ui_executor_channel_test.ts tests/ui_executor_issuance_test.ts tests/ui_executor_child_test.ts tests/ui_executor_local_launch_test.ts tests/ui_executor_notification_test.ts tests/ui_local_launch_approval_test.ts
nix build .#ham-bridge .#ham-pty-host -o $HOME/.cache/heimdall-tests/m3c-bins-20261107-1235
git diff --check
```

The full Bridge suite retains existing allocator warnings; no leak-free claim. Actual native-provider opt-in is skipped there and covered by the retained separate reviewed evidence. Existing package sandbox limits do not become provider passes. No new Rust behavior changed; actual Linux Rust218+2 and native safety evidence from the reviewed dependency remain applicable.

Draft failures are retained in the evidence JSON: an unsupported extra `expect_value` message caused compilation failure; switching to `testing.expect` fixed it. The new second reopen correctly advanced incarnation, causing the old fixture's hardcoded replacement incarnation2 to fail; the fixture now uses the current journal incarnation. No production fence was relaxed. An earlier baseline full Bridge run also passed1045 before the new checks.

## Review and remaining milestone

Named review must inspect retained implementation plus this exact test delta, independently assess P2/P3 closure and the original requirement map, and judge current Linux Codex cumulative acceptance. No prior interim audit substitutes for that verdict. Mac/Claude deferrals are explicit user scope decisions, not hidden waivers or passes; Windows stays unsupported.

M4 retains migration/ordinary-route cutover/restore and repeated-cycle resource verification. No live restart, deployment, push, system install, persistent credential/config change, takeover or task-authority transfer occurred. Test fixture processes and sockets use their established scoped cleanup; the new disconnected endpoint is never created. High confidence in the reported current checks and bounded safety properties; broader availability or multi-machine failure guarantees are not invented from them.
