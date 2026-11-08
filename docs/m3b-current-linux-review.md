# M3b current Linux Codex review

Revision 3 of task `task_18e5beeef261412e` is ready for named review. The current scope is encrypted exact-child PTY notifications/results for Linux Codex. The user explicitly deferred real Mac execution and Claude PTY notifications (`msg_18e5c304c93b438a`); both remain disabled/unsupported, not passed. Windows notifications remain unsupported. Future Claude support retains exact bytes without normalization or an alternate transport.

## Implementation and evidence boundary

This task preserves reviewed guard source `df0b952742c622ecdf2d1ace16faa54606489cfe`, including the exact intended predecessor carry `d4b73182` from `ecb30481..4afd3a09`. Successor commits `4863f160` and `8f01ebd1` record Mac deferral and Linux evidence reconciliation. The final delta adds current revision-3 documentation only. No production code or wire contract changed in this continuation.

| Requirement | Evidence retained for current review | Boundary |
|---|---|---|
| REQ-M3p-1 | Connected original-owner native audit `e4ca4ae9`: exact signed identities, encrypted owner notice/result, same-turn interruption, once-only and partial/lost-result reconciliation | No executor task-authority grant |
| REQ-M3p-2 | Linux Codex 0.162.0 busy-turn Unicode/LF/TAB native proof; real idle refusal/cancel/revocation audit merged `873aa65c` | Idle refusal is not delivery; Mac/Claude deferred; Windows unsupported |
| REQ-M3p-3 | Existing renewal/global admission and M3a production launch evidence; current platform matrix and checkpoint reconciled | M3c cumulative verification remains separate |

Production exchange opens the signed encrypted request against the enrolled owner key at `src/bridge/executor_exchange.odin:109`, binds immutable owner authority at lines116-118, dispatches notifications at line122, and seals the result at line127. The signing allowlist includes only explicit proof kinds at `src/bridge/executor_issuance.odin:37`. These are source references, not a substitute for retained native evidence.

The current Linux binary digest is `50ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38`; its exact0.162 profile and sealed memfd execution remain inherited unchanged. Production native profile gating is in `tools/pty_host/src/native_notification.rs:76`; unknown images refuse before the version probe at line107. Idle/unknown state refuses at line203. Darwin remains absent at line88 and its guarded substrate refuses unproven lifetime policy at `tools/pty_host/src/darwin_image.rs:190`. Claude gets no enabled native interrupt profile; Prepare without one refuses at `tools/pty_host/src/delivery.rs:123`.

## Retained checks and exact reproduction records

The approved native audits are not rerun for a documentation-only scope reconciliation, as directed by the task. Exact commands, evidence sessions, failures and cleanup remain in `docs/m3b-provider-support-matrix.md`, `docs/executor-dispatch-checkpoint.md`, and `docs/pty-provider-evidence.md`.

- Connected Linux busy-turn audit: `task_18e5bb3fa781e488`, named audit `e4ca4ae9`. It establishes actual current-child encrypted owner delivery and typed interrupt.
- Pending hostloss audit: `task_18e5bc3a60e3f390`, `89bfda15`, [evidence](artifact://art_18e5bc7e475b471c). It establishes refusal/retained capacity, not eventual recovery or refund.
- Idle audit: `task_18e5bcc3dcc57c61`, merged `873aa65c`. Native test1 passed in `sh_fccfda47c755776dcf34871798eba283`; required-daemon Bridge1045 passed in `sh_f4166e587edeabe16697c0a514cd1437`. It establishes zero-input refusal, signed cancellation and newer owner revocation.
- Guard dependency: Linux Rust218 unit+2 safety passed (2 existing ignores), native focused4+2 passed, Python3 passed, Nix package build passed. [Exact source hashes and logs](artifact://art_18e5c076f93e4ef2), [engineering report](artifact://art_18e5c0830a534d58). Earlier broad Mac failures remain disclosed; no full Mac pass is claimed.
- M3a dependency `ab8beb00`: required-daemon Bridge1036 passed, focused launch/cancel5 passed, Bridge package built. Those dependency commands/results remain in the task output and checkpoint.

This continuation runs `git diff --check` and verifies a clean committed tree. No build/test is necessary for the documentation delta. No provider authentication/configuration, system package, protected image installation, live service, deployment, restart or push changed.

## Deferred support and next gate

Claude2.1.319 literal TAB-to-spaces failure remains recorded, not repaired or normalized. Revision3 defers its notification capability instead of treating failure as a pass. Mac guard inspection/preparation also remains refusal evidence only. The protected-install plan is separate and supplies no installation authority.

Named review must assess the current complete scoped delta and inherited Linux evidence. M3c retains cumulative crash/replay/capacity verification; retained pending-hostloss and idle refusals do not pre-approve it. M4 migration/ordinary routes remain separate. Confidence is high for current scoped review readiness; deferred platforms and cumulative guarantees remain explicitly outside this acceptance.

## Re-verification on the integrated Bridge-owned branch

Milestone R5 re-checks the scoped Linux Codex delivery guarantees on branch `bridge-owned/r5`, which starts from the integrated `bridge-owned/subagents` head `846b1b72`. R2-R4 left the audited delivery files unchanged but changed what they rely on:

- executor_local migrations 009-015 added native-journal sequence triggers to the executor tables, including intents, receipts and issuances;
- owner_local `control_ready`/`control_active` now also refuse a chain that is `migration_quarantined`;
- budget admission and budget holds were removed from owner_local execution and controls. The native proof creates its owner notice with `task.hold`, so that removal does not affect it.

### Checks run on the merged head

All checks ran inside `nix develop` with `-out` under `$HOME/.cache/heimdall-tests/r5-*`. The required-daemon Bridge suite uses the packaged daemon from `nix build .#ham-pty-host`, supplied through `HEIMDALL_EXECUTOR_TEST_PTY`. No real provider was run.

```bash
nix build .#ham-pty-host --out-link $HOME/.cache/heimdall-tests/r5-pty-host
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/r5-pty-host/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -out:$HOME/.cache/heimdall-tests/r5-bridge-final
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/r5-executor_local
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/r5-owner_local
nix develop --command odin test src/contracts -collection:odin_test=src -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/r5-contracts
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_PTY_REQUIRED=1 CARGO_TARGET_DIR=$HOME/.cache/heimdall-tests/r5-cargo cargo test --locked --manifest-path tools/pty_host/Cargo.toml -- --test-threads=1
```

| Check | Result | Managed session |
|---|---|---|
| Required-daemon Bridge | 1,068 passed, 0 failed, exit 0 (2m35s) | `sh_63cb4941a91ffee3a89750b90565d83c` |
| executor_local | 81 passed, exit 0 | `sh_2f1eda197a99c577e842267929244dda` |
| owner_local | 270 passed, exit 0 | `sh_b8912d025682457fb27fd16323dac0c8` |
| contracts | 47 passed, exit 0 | `sh_b4470740e9b5cf7c7525ce29cd9c5158` |
| pty_host `cargo test`, PTY required | 218 unit + 2 passed, 2 existing ignores, exit 0 | `sh_d5607521fe05b9535a0b21d8988f7602` |

The Bridge run has two expected skips: the opt-in real-provider proof (`EXECUTOR_NATIVE_OWNER`), which is pending below, and the old-daemon compatibility phase, which needs `HEIMDALL_EXECUTOR_OLD_PTY`. The tests named as allowed pre-existing or flaky failures all passed in this run: `bridge_executor_local_resolver_rechecks_catalog_mapping_and_full_spawn`, `test_executor_original_owner_remote_stop` and `test_wake_nudge_unknown_native_admission_keeps_process_and_refuses_task_md`. Allocator warnings are unchanged, so this run makes no leak-free claim.

The first full run (`sh_592564c8465a1890356454654be28328`, on the unmodified head) and the first run after the fixture commits (`sh_34df6881495ef10eb4f4084874d16a83`) both hung. The cause was in `test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection`: its fence probe changed the claude profile binary to `/bin/false`, which does not exist on this NixOS host (only `/bin/sh` does). `profile_upsert` returned `Binary_Invalid`, the probe panicked (reproduced in `sh_af458cded66c75b78888114215d8a27a`), and the panic left the next test blocked. This is a test-portability problem in a fixture added by `deff1cfe`, not an R2-R4 regression. Commit `b0ff6b12` switches the probe to `/bin/sh`, which the same test already uses, and makes the panic report the profile error. The focused rerun passed (`sh_bb021cae35901ef8b509576ee91b2372`), followed by the full run above. Processes left by the hung runs were killed.

### New non-provider fixtures

These use the existing fake executor and owner harnesses. They start no provider or daemon.

- `executor_local.executor_notification_hold_notice_settles_once_under_native_journal` (`src/lib/executor_local/notification_test.odin`). It first checks that the three `native_journal_executor_receipts_*` triggers are installed. Then it records ticket, dispatch and result for the exact owner `task.hold` notice text. The first result write is made to fail after the physical write, simulating a lost result. That transaction rolls back, the journal sequence stays where it was, and the result stage still reads `not_found`. The retry commits exactly one result and advances the journal. Three later attempts are all read-only replays that return the first stored body and leave the sequence unchanged: an exact retry, a retry with a different body, and a re-signed transport copy. The store ends with one receipt per stage.
- `owner_local.owner_hold_notification_settles_once_after_lost_result` (`src/lib/owner_local/execution_notification_r5_test.odin`). One `task.hold` produces one `executor.notification` intent. After the executor result is lost (`intent_result` records a failure), the retried claim (attempt 2) re-signs the same intent, message and `executor.notification_effect`, so the executor journal above would return its original receipt. The intent settles once. A second settlement and a settlement from the stale attempt-1 claim are both refused. No further claim is produced, and lease, attempt, command-receipt, event, control-notice, bootstrap and journal counts are unchanged from the hold.
- `owner_local.owner_quarantined_chain_refuses_execution_admission`. An unactivated `migration_imports` row is inserted over the live fixture chain. Execution preparation (`execution_prepare_start`), the activation fence and the bootstrap of an already committed reservation are each refused and write nothing. After the import is activated, each of them succeeds, which shows that quarantine caused the refusal.
- `owner_local.owner_quarantined_chain_refuses_notification_admission`. On a quarantined chain, `task.hold` returns `operation_conflict` and no notification intent is created. If a notification was already queued before the quarantine, the owner refuses to report it current, sign it or fence it (`no_current_target`). It succeeds after activation.

The last fixture found a gap. `execution_notification_current_locked` selects the held control through its own SQL join, so it bypassed the quarantine gate that R3 added to `control_active`. A notification queued before a chain was quarantined could still be signed and fenced. Commit `5d6b9dce` adds the same `migration_quarantined` check there. Production imports only create new chains (`src/lib/owner_local/migration_import.odin:188`), so the gap was not reachable through import; the check is defense in depth. No audited Bridge or pty-host delivery file changed.

### Real Linux Codex run: PENDING

The real-provider proof was **not run** in R5. It is pending a user decision and is recorded here as PENDING, not passed. To run it on another Linux x86_64 host:

1. **Codex binary.** Use the pinned vendor Codex `0.162.0` Linux release binary, whose canonical file must have SHA256 `50ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38`. The daemon resolves symlinks, hashes the actual bytes and seals them before running `--version` (`tools/pty_host/src/native_notification.rs:76-110`). The path must be absolute and its file name must be `codex`. Any other digest gets no native profile, and the notice is refused rather than delivered. In particular, the Nix-packaged Codex 0.162.0 on dawnstar has a different digest and would be refused. Check with `sha256sum "$(readlink -f /path/to/codex)"`. Provider authentication must already be set up on that host. The procedure never copies or edits it.
2. **Build the inputs** from the worktree:
   ```bash
   W=$HOME/.cache/heimdall-tests/r5-native-$(date +%Y%m%d-%H%M)
   nix build .#ham-pty-host --out-link $W-pty
   nix build .#ham-ctl --out-link $W-ctl
   sha256sum "${CODEX_HOME:-$HOME/.codex}/config.toml" > $W-config-before.sha256
   ```
3. **Generate the args file.** `tests/prepare_native_owner_notification.py` reads only the native Codex config. It refuses to continue if an unreviewed user hook source is present (`hooks.json` or capitalized `[hooks]` keys). It writes the private per-invocation flags as a JSON list: `--no-alt-screen`, `--sandbox read-only`, `check_for_update_on_startup=false`, `--dangerously-bypass-hook-trust`, an inline `SessionStart` hook taken from `extensions/codex/hooks/hooks.json`, and a disable flag for each configured plugin. It also writes `<out>.manifest.json` with the SHA256 of the hook source, `ham-ctl`, the Codex binary, the args file and the native config. Nothing is saved to the native settings.
   ```bash
   nix develop --command python3 tests/prepare_native_owner_notification.py --out $W-args.json --ctl $W-ctl/bin/ham-ctl --codex /path/to/codex
   ```
4. **Plain delivery run.**
   ```bash
   nix develop --command env HEIMDALL_NATIVE_CODEX=/path/to/codex HEIMDALL_NATIVE_MODEL=gpt-6.1-sol HEIMDALL_NATIVE_ARGS=$W-args.json HEIMDALL_NATIVE_CTL=$W-ctl/bin/ham-ctl HEIMDALL_EXECUTOR_TEST_PTY=$W-pty/bin/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_NATIVE_OWNER=true -define:ODIN_TEST_NAMES=main.test_executor_original_owner_native_notification -out:$W-native
   ```
   Expected result: 1 test passes, ending with `[native-owner] actual signed owner hold -> encrypted executor/nonce -> partial interrupt/paste -> lost-result recovery -> signed receipt/replay PASS bytes 66 submissions 1 typed_aborts 1 ...`. That means the 66-byte `[owner-local] task.hold ...` notice is submitted exactly once in the native transcript after exactly one typed `turn_aborted`. The partial result and the lost result persistence reconcile to one `delivered` receipt. The stale epoch returns `no_current_target`, and the replay after daemon journal loss returns the original ticket.
5. **Idle-refusal run.** Use the same command with `-define:EXECUTOR_NATIVE_IDLE_REFUSAL=true` and `-out:$W-idle`. Expected result: 1 test passes, ending with `[native-owner] real idle refusal/cancellation/signed revocation PASS submissions 0 aborts 0 charge 1 ...`. Both encrypted hold notices return signed `unsupported_not_delivered` with zero ESC, message and Enter writes. A signed `task.cancel` and a newer device-signed owner revocation then refuse the old ticket. One ticket and one capacity charge remain, and no task authority is added.
6. **Cleanup evidence.** Record that each native PID printed by the fixture is absent. Record that no `/tmp/ham-native-owner-*.sock` or `/tmp/ham-native-hook-*.sock` sockets, and no locks created after the run started, remain. Record that the Codex config SHA256 matches `$W-config-before.sha256`.

Until those results are recorded with session IDs, R5 adds no new real-provider evidence. The retained Linux native evidence listed above is the latest real run.

### Limits (unchanged)

- Idle refusal is not delivery. Idle notification delivery remains an open requirement.
- Host-loss refusal is not recovery and does not refund capacity.
- Real execution on Mac, for both Codex and Claude, is deferred, and the Darwin profile stays disabled. Claude PTY notifications are deferred too.
- Windows notifications are unsupported.
- Future Claude support must keep the exact bytes, with no normalization and no alternate transport.
