# Independent pending notification host-loss audit

The exact `87b6df9694d7dcf6638dbcf4d54524ce46625c72..c61dad2973aeefb0f1494686769e75d5f4e4abc4` delta satisfies the scoped safe-refusal and retained-capacity evidence requirements REQ-PEND-A1/A2. No blocking finding emerged from source inspection and independent execution. This is evidence for unfinished delivery uncertainty, not eventual recovery, authoritative child absence, full M3b acceptance, or platform approval. Task: `task_18e5bc3a60e3f390`; reviewer instance: `inst_18e569b6fc61248b`; date: 2026-11-07.

## Exact scope and source inspection

`c61dad2973aeefb0f1494686769e75d5f4e4abc4` has direct parent `87b6df9694d7dcf6638dbcf4d54524ce46625c72`. Connected source `d2864a0555085362d9d4f5159bd28a34e97007a6` is an ancestor. Only `src/bridge/owner_executor_native_test.odin` and `docs/executor-dispatch-checkpoint.md` changed: 153 insertions, one deletion. The complete diff was inspected, with no production changes. Commands and ancestry are recorded in `sh_77b98dcd48ec160ab17cd3e6a8c22d74`, `sh_0137af7d811258c6d779b4a639107bc8`, and `sh_99424650347a9d2d0f27c74ca6234e01`.

Execution used a detached exact-source checkout `.audit-source` inside this task worktree, starting from a clean tree. No modification of the engineer checkout, no implementation edits, and no source-history merge occurred. The audit report is committed separately for named review.

Inspected fixture and production paths:

- `owner_executor_native_test.odin`: genuine signed commands create chain/task/policy/reservation/requirements; real assignment preparation, commit and bootstrap APIs issue authority. Encrypted signed reverse-channel callbacks use the owner APIs. SQL reads verify authority; a result-persistence fault trigger inserts no authority.
- `tests/prepare_native_owner_notification.py`, `extensions/codex/hooks/hooks.json`, `src/ctl/extension/{hook,codex}.odin`: invocation-only inspected SessionStart hook routes through actual built repository `ham-ctl`; the fixture adds local status capture, then calls `extension hook codex`. A private socket and fresh issued bootstrap authenticate the real native session. Daemon environment filters inherited `HEIMDALL_` credentials. No saved trust/auth/settings, credential copies, global installs, or live-service changes were used.
- `executor_notification.odin`: current authority is checked before saved-result lookup and again before exact launch query. Unknown exact child returns `child_unavailable` before ticket replacement, Prepare, nonce callback or Dispatch. Retained ticket/dispatch evidence cannot authorize another write by itself.
- `executor_reconcile.odin`, `executor_runtime.odin`, `lib/executor_local/{actions,reconcile,notification}.odin`: expiry changes active reservations to stopping; exact observation is required to release their charge. Unknown query returns `executor_uncertain` without `observe_child`. Reconcile candidate/current checks do not grant launches. Notification current checks verify signature, scope, incarnation, directory-linked key, exact bootstrap/reservation fences and time.
- `tools/pty_host/src/delivery.rs`: Query without a journal entry returns a valid `recovery_required` receipt, without reconstructing delivery or writing ESC/text. It does not certify absence.

## Acceptance evidence

REQ-PEND-A1: the native fixture reaches a signed partial receipt with ESC written, zero message bytes and no Enter, kills the private daemon, and restarts it on the same socket. Exact launch becomes unknown; original-ticket Query returns `recovery_required`. Three production notification retries return `child_unavailable`. Byte-identical saved ticket, no final result, unchanged callback count and charge1 are asserted. The transcript has zero notice submissions; the assertion bounds typed aborts to at most one (the independent observation was one). Lease/attempt/bootstrap counts do not grow. Signed `task.cancel` rejects a fresh pending owner nonce with `no_current_target`. Revoked-key and request-expiry inputs directly fail `notification_current`; this is not a separate signed directory-revocation integration demonstration.

REQ-PEND-A2: production reconciliation runs both at current time and with an injected clock beyond reservation expiry. The latter attempts exact cleanup and retains charge1, with only the original ticket/dispatch notification receipts. Test-only PID cleanup is separate from authority and never used as evidence of trusted child absence. A successful sweep boolean means the bounded sweep ran, not that the unknown child recovered or capacity was released.

Preserved failed expectation: engineer session `sh_e536cc45e4d7a0b659dd3f28b059d523` originally expected an IPC error for unknown-ticket Query. The corrected fixture requires the existing valid `recovery_required` response. This was a test expectation correction, not a production repair. Earlier pre-sweep evidence and final engineer evidence remain attributed in the checkpoint; independent results below do not replace that history.

## Independent commands and outcomes

All commands ran at exact detached `c61dad29` through `ham-ctl shell run`. Binaries were placed under the home cache, not `/tmp`.

```bash
nix build .#ham-ctl --out-link /home/tanmay/.cache/heimdall-tests/audit-pending-c61-ctl
nix develop --command python3 tests/prepare_native_owner_notification.py --out /home/tanmay/.cache/heimdall-tests/audit-pending-c61-args.json --ctl /home/tanmay/.cache/heimdall-tests/audit-pending-c61-ctl/bin/ham-ctl --codex /home/linuxbrew/.linuxbrew/bin/codex
nix develop --command env HEIMDALL_NATIVE_CODEX=/home/linuxbrew/.linuxbrew/bin/codex HEIMDALL_NATIVE_MODEL=gpt-6.1-sol HEIMDALL_NATIVE_ARGS=/home/tanmay/.cache/heimdall-tests/audit-pending-c61-args.json HEIMDALL_NATIVE_CTL=/home/tanmay/.cache/heimdall-tests/audit-pending-c61-ctl/bin/ham-ctl HEIMDALL_EXECUTOR_TEST_PTY=/home/tanmay/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_NATIVE_OWNER=true -define:EXECUTOR_NATIVE_PENDING_LOSS=true -define:ODIN_TEST_NAMES=main.test_executor_original_owner_native_notification -out:/home/tanmay/.cache/heimdall-tests/audit-pending-c61-native
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:/home/tanmay/.cache/heimdall-tests/audit-pending-c61-executor
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:/home/tanmay/.cache/heimdall-tests/audit-pending-c61-owner
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=/home/tanmay/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -out:/home/tanmay/.cache/heimdall-tests/audit-pending-c61-bridge
```

| Check | Independent session | Result |
| --- | --- | --- |
| Exact-source ctl package | `sh_de0888158eda07ea06005d11702cceab` | exit0 |
| Invocation manifest | `sh_7dcb0bcbad3065e0558de06875d3db05` | exit0 |
| Native pending loss | `sh_0a7f2839ffd08d9ca16604dd73fa831e` | 1 PASS, 3.70s, exit0; notice0, abort1, charge1, nonce refusal |
| Executor package | `sh_51663ef06a5050ec3cd2ec4c256f18db` | 56 PASS, 8.33s, exit0 |
| Required-daemon Bridge | `sh_21034ae82deb76b9f2e658ddccd82ec5` | 1045 PASS, 59.12s, exit0; allocator warnings remain |

The Bridge run does not opt into native-owner coverage (run independently above) or old-daemon compatibility (no old binary supplied). Warnings prevent a leak-free claim. Ordinary native delivery/completed-result-cache replay was not rerun: it remains distinct prior connected evidence, including engineer normal-mode `sh_76a1eb0e977e0c6f8aa8b0583deb5f80`, rather than evidence that an unfinished ticket recovers after daemon loss. No new Rust/platform suite was required for this test-only delta; the private daemon binary was reused explicitly, not claimed as an independent fresh daemon build.

Manifest pins actual Codex0.162.0 executable SHA256 `50ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38`, built ctl `99fde6116479be5e657867e6b90a28758b74418e1872abeab6f07fd8d2e74769`, argument file `91fce628cbe0866a93d18e883c20767853927b10bf3e614a03de0c6697a3fac8`, repository hook `801b83d72454d057ab4ad73dd6a5bcc6fa7acd955a99f2a0598621f4df02c8bd`, and reused private daemon `83789d55a8219b5e61dedd33fa7992c5986303dbcbc7f27529ce348b0a10a0b3`.

## Cleanup and practical limits

`sh_bb682312d68d684c9fe6745f16bd1090` independently checked native PID3135775 absent, no native-owner/hook socket or lock created since this run, and removed fixture workdir `/tmp/ham-p1c-3135721-1794047090130003644`. The source checkout remained clean. Native configuration SHA256 after execution equals the manifest before execution: `d111397be1b38940d9b795a64f8b75dc61a659e98895d6aff0a41ba372aba6cf`. These cleanup observations are not fed to owner/executor authority.

An initial environment lookup found no `rg` in the shell-service PATH and the engineer cached ctl link was absent. The audit used read-only fallback searches and independently built ctl from the exact checkout. No product failure was inferred.

Confidence is high for the two scoped acceptance items. No claim is made for persistent Bridge restart in this new mode (the daemon is restarted), signed directory-key-revocation integration, delivery of the pending notice, eventual recovery/refund, native idle readiness, or real network transport resilience. Hardened Darwin remains fail-closed/unverified; Claude literal TAB remains failed/unwaived; Windows notification is unsupported; M3c/M4 and full M3b/platform gates remain open. No live restart, deployment or push occurred.

Owner package independently finished **265 PASS**, 128.51s, exit0 in `sh_1a7c985d15fed4617b9517aa520c6e0d`. Final scoped confidence: **90%**. `sh_b6ea9f3110f4675ba3acc28d59306d5a` removed the clean detached source worktree after all checks; only this report remains as the deliverable. The native transcript itself is not published because test bootstrap/session material is unnecessary for the review; bounded output and exact assertions provide the evidence.
