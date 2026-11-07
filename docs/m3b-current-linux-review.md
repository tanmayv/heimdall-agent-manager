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
