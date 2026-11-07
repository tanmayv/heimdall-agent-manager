# M3c remote activation and stop repair

Both blocker findings from the named review of `4cfa224f` are repaired at implementation head `7d72d11e7b26c6f53c32d1e3eb53af910e15bb82` (initial activation fix `deff1cfe`). Intended-behavior regressions and current cumulative checks pass, including a fresh actual Linux Codex owner proof. This report supersedes the earlier review-readiness assessment; independent named re-review is required before acceptance. Current release scope remains Linux Codex. Mac execution and Claude PTY notifications stay user-deferred/disabled; Windows notifications stay unsupported. M4 remains separate.

[Selected logs and all 45 changed source-file hashes](artifact://art_18e5c63e31f87a5e) are committed in `docs/evidence/m3c-remote-runtime-repair.json`. Reviewer reproduction source is retained in task comment `cmt_18e5c42088238de6`.

## 1. Activation rechecks the resources that produced the actual Spawn

The old path prepared argv before an unlocked owner callback, then checked owner/time/vault authority without checking the local profile/catalog/filesystem again. The reviewer demonstrated a live child after callback-time catalog disable.

Current preparation in `src/bridge/executor_bootstrap.odin:53` holds startup serialization and the launch-configuration read gate while resolving and building the request. It returns a pin for that actual prepared configuration. The pin at line15 covers the original signed configuration, materialized profile, active catalog, selected directory device/inode, catalog binary and discovered-path state. Managed profile, model, catalog and path publishers use the corresponding write gate. Remote preparation uses a previously discovered path rather than invoking discovery while holding the read gate.

After the unlocked callback, `src/bridge/executor_activation.odin:99` holds startup/vault/configuration serialization, recomputes the pin and rejects changed or invalid resources at line102. It retains the configuration read gate through first I/O. The owner callback still runs without those application locks; query-only retries keep their existing exact-child observation path and do not rematerialize a live child.

The pin travels with preparation rather than being captured in a separate earlier unlocked snapshot, avoiding an A→B→A configuration race while argv is built. Directory content timestamps are excluded: legitimate bootstrap or owner journaling can change contents without replacing the selected directory. The identity check concerns the directory itself; it is not a general filesystem immutability claim.

The mounted actual-daemon fixture changes each of four inputs during the callback: catalog disabled, profile binary changed, selected directory missing, selected directory replaced. Each now returns `invalid_resources` with no exact child. After restoration, activation succeeds once and duplicate activation retains its PID. The shell preparer is an isolated fixture, not a provider claim.

## 2. Remote retirement uses durable signed query → ordinary stop

The old owner producer emitted generic `stop` intents addressed by a child hash. The Owner consumer could see an empty local daemon and settle `child_absent` without reaching the recorded remote executor. Review demonstrated the remote child still live and its charge retained.

The producer at `src/lib/owner_local/execution_stop.odin:11` now creates `executor.stop:<reservation>` from the original committed remote journal and cancellation/retirement notice. Per-reservation kind identity also separates multiple tasks stopped by one control operation on the same execution device. The Executor consumer claims these effects; there is no generic local duplicate.

The bounded recovery at line29 repairs retained pre-fix generic stops, including ones already wrongly marked settled. It preserves their original evidence, appends the exact executor intent from the original committed control receipt and invalidates the old consumer. It neither invents a new task command nor refunds a process.

The source check at line54 uses original committed cancellation/retirement evidence, exact Child, reservation, prepare, owner, executor and historical configuration. It does not require an active lease or current assignment after retirement, and cannot retarget a replacement.

V28 adds `owner_execution_stop_steps` (`src/lib/owner_local/migration_028.sql:48`) with retained phase/request/outcome rows and immutable signed operation bytes. `execution_stop_request` at line79 in the Odin file persists each query or stop before I/O. Retries reuse those bytes. A verified query supplies only the current serving incarnation, deadline version and expiry; immutable reservation scope, prepare digest, grant/hard bounds, original child incarnation and launch key stay pinned. Owner restart or an expired transport window produces a new query and a new exact ordinary stop. Stale stop/version races therefore requery; they do not bypass admission. Failed replies may wait for the existing transport expiry/retry floor before refresh.

The coordinator explicitly chose this durable query/ordinary-stop flow rather than a new safety-stop authority domain. Existing `action.stop`, activate and heartbeat admission checks are unchanged.

### Narrow query discovery and exact acknowledgement

Authenticated read-only queries can reach the serving executor after an incarnation change at `src/bridge/executor_exchange.odin:119`. The opt-in response exception at `src/lib/executor_channel/channel.odin:75` applies only to a signed query receipt, retains the original AAD/input correlation and original child incarnation, and cannot admit a mutating action. The dedicated matcher `src/contracts/executor.odin:356` additionally binds all immutable fields and the original launch key. Native and TypeScript implementations/tests cover substitution, wrong method, old incarnation and revoked-key refusal. Ordinary channel matching remains strict by default.

At `src/bridge/executor_exchange.odin:181`, an accepted ordinary stop performs the exact committed stop against the execution daemon under startup/vault serialization. The response reflects the serving ledger after observation. A signed `stopping` response proves durable acceptance only; it does not settle the owner's intent or release capacity.

The production worker at `src/bridge/owner_local_executor.odin:140` snapshots the durable phase, sends it to the recorded executor and validates current paired-directory/enrolled keys. Acceptance at line279 invokes `execution_stop_accept` (`src/lib/owner_local/execution_stop.odin:135`). Only a correlated signed `released` result settles physical delivery and retires the original owner execution journal. Unknown daemon state remains charged.

The generic Owner consumer now rejects a known remote target before local daemon observation (`src/bridge/owner_local_controls.odin:24`). A local absence response cannot settle this remote stop.

## Regression evidence

| Case | Intended behavior verified |
|---|---|
| Callback catalog/profile/directory changes | Refuse before first Spawn; restored resources launch once; exact replay retains PID |
| Signed task cancellation and signed handoff | Only the recorded Executor gets the stop; no generic Owner stop; phase bytes retained |
| Query reply lost | Same signed query bytes reused |
| Executor ledger restart | Query discovers current serving incarnation while retaining original child/key; ordinary stop uses that exact refreshed incarnation |
| Owner ledger restart | Terminal source and phase evidence survive; no active lease is recreated |
| Stop endpoint disconnected | Signed stopping is acceptance only, original child remains live, charge1 retained |
| Reconnection, lost stop reply, duplicate | Exact executor absence produces released receipt; duplicate reuses the operation; charge becomes0 |
| Stale stop after replacement | Old signed reservation stop leaves a distinct replacement key/PID alive; replacement is a test-only physical control, not a new task grant |
| Renewal races the queried version | Ordinary stale stop refuses; after its transport window the durable worker requeries and signs a new exact version |
| Wrong/revoked observer | Refuses; no release or retarget |
| Pre-fix wrong-device settlement | Old evidence retained/invalidated, correct executor effect remains pending; recovery idempotent |
| V27→V28 name collision | Entire migration rolls back preserving identity/journal; repair/retry succeeds |

The connected test starts with genuine signed owner chain, assignment, preparation, commit and bootstrap APIs. It then drives signed cancellation through persisted query/stop phases, encrypted mounted executor handlers and an actual daemon, including both database restarts and disconnected/reconnected control. It uses an injected shell preparer, not a claimed native-provider stop run or a physical multi-machine WAN partition. Signed handoff and renewal-race cases also exercise the shared owner protocol in isolated ledger tests.

## Current verification

All commands use the task workdir:

```text
/var/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e5ac3dd21cf93e
```

| Check | Result | Managed session |
|---|---|---|
| Owner | 269 passed, including V28/phase/recovery tests | `sh_3b490d68c299d986f116b38640fa68dd` |
| Executor / encrypted channel / contracts | 56 / 6 / 40 passed | same session |
| Final required-daemon Bridge | 1046 passed, 61.73s | `sh_3c90c666773085a25cf85a9c91cb65f6` |
| UI protocol and approval | 24 passed, no skips | `sh_78fd23ae25da86e494c10d2e491d07c8` |
| Typecheck after restoring pinned dependencies | Passed | `sh_b6d10dd5a2fe468c33667d7bf5fc2868` |
| Bridge, CLI and PTY Nix packages | exit0 | `sh_e1204870b2f2522b33288d3208ebf7a4` |
| Actual Linux Codex original-owner proof | 1 passed, 4.69s | `sh_79d0d26107ba8390215cca35652fed86` |

Exact principal commands:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/m3c-repair-owner-final-20261107-1319
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/m3c-repair-executor-final-20261107-1319
nix develop --command odin test src/lib/executor_channel -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/m3c-repair-channel-final-20261107-1319
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/m3c-repair-contracts-final-20261107-1319
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/mac-guard-pty-package-20261107-1134/bin/ham-pty-host HEIMDALL_EXECUTOR_OLD_PTY=$HOME/.cache/heimdall-tests/c1f-v24-bins-3/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -out:$HOME/.cache/heimdall-tests/m3c-repair-bridge-confirmed-20261107-1323
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_executor_contract_test.ts tests/ui_executor_channel_test.ts tests/ui_executor_issuance_test.ts tests/ui_executor_child_test.ts tests/ui_executor_local_launch_test.ts tests/ui_executor_notification_test.ts tests/ui_local_launch_approval_test.ts
nix develop --command npm ci --ignore-scripts --no-audit --no-fund
nix develop --command npm run typecheck
nix build .#ham-bridge .#ham-ctl .#ham-pty-host -o $HOME/.cache/heimdall-tests/m3c-repair-bins-confirmed-20261107-1323
```

The modified first-I/O gate justified a targeted actual-provider rerun:

```bash
nix develop --command env HEIMDALL_NATIVE_CODEX=/home/linuxbrew/.linuxbrew/bin/codex HEIMDALL_NATIVE_MODEL=gpt-6.1-sol HEIMDALL_NATIVE_ARGS=$HOME/.cache/heimdall-tests/native-owner-pending-20261107-1017.json HEIMDALL_NATIVE_CTL=$HOME/.cache/heimdall-tests/m3b-native-ctl-20261107-0931/bin/ham-ctl HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/mac-guard-pty-package-20261107-1134/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_NATIVE_OWNER=true -define:ODIN_TEST_NAMES=main.test_executor_original_owner_native_notification -out:$HOME/.cache/heimdall-tests/m3c-repair-owner-native-20261107-1325
```

It verifies actual Codex0.162.0 `gpt-6.1-sol`, original signed owner/encrypted child binding and the real SessionStart hook: one exact notice submission, one typed abort, 66 message bytes, partial/lost-result persistence recovery and signed receipt replay. Cleanup `sh_6c03dce5a69d4a3d6116f8359895e022` confirms native PID3304905 absent, no new native-owner/hook sockets or locks, and unchanged Codex config SHA256 `d111397be1b38940d9b795a64f8b75dc61a659e98895d6aff0a41ba372aba6cf`.

Existing allocator warnings remain in the full Bridge suite; no leak-free claim. Native opt-in is covered separately above. Rust implementation did not change; its previously reviewed actual PTY/vendor safety evidence remains retained. No Mac/Claude probe, protected installation, persistent auth/settings edit, live service restart, deployment or push occurred.

## Corrections and review boundary

Draft failures are retained, not hidden: missing json imports and an Odin multiline-do form were corrected; a dynamic SQL concatenation was changed to the supported API; the initial handoff fixture lacked explicit lifecycle configuration and was corrected before admission. V28 initially exposed two older-schema fixtures retaining the new table; those reconstructions and expected schema headers now reflect the genuine historical boundary. The full Bridge fixture using a nil Store now supplies the current journal required to identify remote targets. A missing pinned `posthog-js` dependency caused the first typecheck failure; `npm ci` restored it without changing the lockfile. Resource-pin drafts were corrected to use immutable signed configuration bytes and actual directory identity rather than unordered JSON or content timestamps.

The prior attempt's passing suites did not cover the two reported remote interleavings; that submission was correctly rejected. The new regressions assert refusal and exact remote acknowledgement, not the review probes' bad-behavior success. Local P2/P3 evidence remains available, but independent review must now reassess the full repaired runtime and cumulative original requirements. M4 migration/cutover/restore/repeated-cycle work is still separately gated.
