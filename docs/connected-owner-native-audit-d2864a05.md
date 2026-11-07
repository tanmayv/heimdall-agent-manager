# Connected original-owner native notification audit

Independent evidence audit for `task_18e5bb3fa781e488`, 2026-11-07. **No blocking finding in the exact Linux connected delta; high confidence (90%) that REQ-CON-A1/A2 are satisfied within the boundaries below.** This is an audit deliverable submitted for separate named review, not full M3b completion or platform approval.

## Source and review boundary

Exact base `890f87eb50fc51da5a178e44a2367dc1098afdfc` to head `d2864a0555085362d9d4f5159bd28a34e97007a6`. Inspected all six changed files: `docs/executor-dispatch-checkpoint.md`, `src/bridge/executor_issuance_test.odin`, `src/bridge/owner_executor_native_test.odin`, `src/lib/owner_local/execution_notification.odin`, its test, and `tests/prepare_native_owner_notification.py`. Only production behavior change is removal of the generated notice final LF in producer and current-fence reconstruction. Sealed executable, lifecycle, source-session and route fences are unchanged.

Tests ran in a detached exact-head checkout `.audit-source` inside this task worktree; mutable engineer source was never changed. Report branch starts at `128386680d2250c803bcda6b7b9dc67920a456fa`; this report does not merge the engineer implementation. Native run used independently built CLI and Rust daemon, Linux, Codex 0.162.0, model `gpt-6.1-sol`. No install, deployment, persistent trust/config edit, production endpoint, or copied credential was used.

## Authority and delivery trace

`executor_issuance_test.odin` provisions distinct disposable owner/executor identities and constructs cryptographically verified approval history under the existing test account root. Device consent, executor policy/directory and mounted encrypted issuance handler issue the configuration. This is valid hermetic test enrollment, not evidence of new remote network enrollment.

`owner_executor_native_test.odin:60` creates the owner store and uses signed `chain.create`, `task.create`, `fleet.policy.set`, `fleet.reserve`, and `requirements.edit`. Production assignment preparation, encrypted mounted prepare, prepare commit and original `execution_bootstrap` create the original lease/attempt/bootstrap. SQL reads inspect this state; the only SQL mutation in the new physical proof is a fault trigger on executor result persistence. No authoritative lease/bootstrap row is manually inserted or substituted.

Production `bridge_executor_prepare_spawn` materializes that bootstrap and launches the real sealed executable. Invocation-only flags replace SessionStart with an inspected recording shell wrapper that calls the real built `ham-ctl extension hook codex`. This is the real adapter invocation through a wrapper, not a byte-identical direct hook command. Its private socket relays to production `bridge_local_endpoint_handle_jsonl_line`; production child-token/bootstrap/paired-directory/current PID checks bind the observed native session. No direct daemon session-bind callback substitutes for that observer.

The first user turn is necessary: idle composer startup is not demonstrated. Initial non-interrupt paste waits for DEC2004 readiness, preserves exact LF/TAB/euro/Japanese/astral content, and appears once in native transcript. Signed owner `task.hold` then produces the exact 66-byte notice. Hermetic reverse transport retains encrypted signed current nonce request/reply and calls production owner fence APIs with executor/startup mutexes released. Source inspection confirmed rechecks of vault generation, paired keys, current notification, bounded nonce time and exact child before dispatch.

The physical test requires partial interrupt, an injected result-journal failure after output, same-ticket recovery, one exact notice and one typed native abort. Repeated completed response preserves ticket. Stale epoch rejects. After exact child close and private daemon restart, exact query is UNKNOWN and roster empty; **only the already completed executor result cache is replayed**. This does not prove pending-ticket recovery after daemon journal loss or authoritative child absence.

Production `bridge_owner_executor_accept` receives the encrypted signed result using a normally paired distinct original owner. Altered pending-scope input digest fails AAD authentication; authentic result settles original notification evidence. Lease, attempt and bootstrap counts remain unchanged. Native fixture closes child/daemon and removes its workdir/socket; no capacity growth is inferred from notification settlement. Existing owner test additionally rejects notification/fence after task release; executor suite covers immutable ticket replay, conflict and one-use nonce. Required Bridge fixtures cover revoked/current child and lifecycle checks. These checks supplement source review rather than broaden this audit into full cumulative acceptance.

## Independent checks

All commands below ran from the exact-head checkout using `ham-ctl shell run`. `$HOME` resolved to `/home/tanmay` inside the Nix environment.

```bash
nix develop --command odin build src/ctl -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/audit-d2864a05-ctl-1006
nix develop --command env CARGO_TARGET_DIR=$HOME/.cache/heimdall-tests/audit-d2864a05-rust-1006 cargo build --offline --release --manifest-path tools/pty_host/Cargo.toml
nix develop --command odin test src/lib/owner_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/audit-d2864a05-owner-1006
nix develop --command odin test src/lib/executor_local -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/audit-d2864a05-executor-1008
nix develop --command python3 tests/prepare_native_owner_notification.py --out $HOME/.cache/heimdall-tests/audit-d2864a05-args-1008.json --ctl $HOME/.cache/heimdall-tests/audit-d2864a05-ctl-1006 --codex /home/linuxbrew/.linuxbrew/bin/codex
nix develop --command env HEIMDALL_NATIVE_CODEX=/home/linuxbrew/.linuxbrew/bin/codex HEIMDALL_NATIVE_MODEL=gpt-6.1-sol HEIMDALL_NATIVE_ARGS=$HOME/.cache/heimdall-tests/audit-d2864a05-args-1008.json HEIMDALL_NATIVE_CTL=$HOME/.cache/heimdall-tests/audit-d2864a05-ctl-1006 HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/audit-d2864a05-rust-1006/release/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_NATIVE_OWNER=true -define:ODIN_TEST_NAMES=main.test_executor_original_owner_native_notification -out:$HOME/.cache/heimdall-tests/audit-d2864a05-native-1008
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/audit-d2864a05-bridge-1007
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/audit-d2864a05-rust-1006/release/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -out:$HOME/.cache/heimdall-tests/audit-d2864a05-bridge-required-1010
```

| Check | Outcome / session |
| --- | --- |
| Own CLI build | exit 0, `sh_995723ca2715044542d762ac5cec94cf` |
| Own offline Rust release build | exit 0, 27.62s, `sh_d7b6352b2d02c1181041fbd3f57577ef` |
| Owner | 265 pass, 141.36s, `sh_d9e6c7a0ff9fde9115698e7bfb316565` |
| Executor | 56 pass, 10.01s, `sh_a09412d1083bc0aad9c436aba5d32e51` |
| Native | 1 pass, 4.92s, PID 3113754, bytes66/submission1/abort1/callbacks5, `sh_89fe786b5a525512b390352bee83eaa7` |
| Ordinary Bridge | 1045 pass, 48.51s, daemon fixtures skipped, `sh_2994736745af344319a3c01ad91668fa` |
| Required-daemon Bridge | 1045 pass, 59.07s, `sh_60036e24932b7e7bbfbc46981774a326`; old-daemon compatibility skipped without old binary; native owner separately gated and covered above |

Bridge suites emit allocator/leak warnings; no assertion failure. Ordinary skip coverage prompted the required-daemon run. Initial cargo invocation outside Nix failed 127 (cargo unavailable); corrected Nix invocation passed, no install. Packaging was not independently repeated: engineer reports `nix build .#ham-bridge` exit 0 in `sh_cb492ccbee9da9d36c2ddbfbb87a0ee4` and required Bridge1045 in `sh_ec11503a488c802872ddb180dedad7e9`. Those remain attributed evidence.

Native executable SHA256: `50ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38`; own CLI `1b25f669db334403c706c3bd4338e7db0979436447be6fda6012ae48556b7cf2`; own daemon `91d8765c9f510f59909447e399c2e71abe0a43bc871cde3b43204053555d09d9`; hook source `801b83d72454d057ab4ad73dd6a5bcc6fa7acd955a99f2a0598621f4df02c8bd`. Manifest session `sh_d258fdd0f39a9695030ee33f04017233`; wrapper digest `affd636ca32fc90081bebfe1b9ca45298b1498b97056b3e679217b837a8f0c50`.

Cleanup independently passed in `sh_d942d918f6418c36a18996ca23b88a7c`: exact native PID absent, fixture workdir removed, this-run private sockets/locks absent, config SHA256 unchanged (`d111397be1b38940d9b795a64f8b75dc61a659e98895d6aff0a41ba372aba6cf`). Initial all-sockets assertion failed because an unrelated older pair stamped `1794044981445794420` predates this run; it was not removed. Generated binaries/manifest remain in test cache as evidence.

## Original failures and remaining gates

Engineer original native failure `sh_b8c5ca5e567c7e578e3a2892a9f45f52` is retained: final LF was trimmed (exact0/without-final-LF1/abort1). Source correction changes only the generated one-line text in both producer/fence; exact unit assertion and independent arbitrary multiline input show no blanket normalization. Already pending old-format delivery stages are not approved for live upgrade.

Preserve prior worker FD-exhaustion/default-parallel failure `sh_c22cd0ac3341d236d825d07fd554733a`, stale-socket transient and earlier fixture development failures documented at the pinned checkpoint; this audit does not erase them or rerun every historical probe. Prior F2-F6 Linux transport audit remains separately scoped. Writable native session-state and bounded 8MiB under-lock observation limits remain.

Hardened Darwin remains unsupported/native Mac offline; Windows notification remains unsupported; Claude TAB/onboarding and idle delivery are unproven. Full M3b, M3c failure/replay/capacity and M4 migration/recovery/UI-CLI-worker convergence remain open. No live Hub/network enrollment demonstration, pending-ticket host-loss guarantee, deployment approval or platform waiver follows from this report.
