# Independent audit: completed-idle refusal and signed revocation

The exact `c61dad2973aeefb0f1494686769e75d5f4e4abc4..caa8a8feae62d67095f2f694335430e95366a35a` delta has no blocking finding for its bounded evidence claims. Independent native reproduction passed, and the required-daemon Bridge suite passed all 1,045 tests. REQ-IDLE-A1 and REQ-IDLE-A2 are satisfied as safe-refusal evidence. This assessment does not accept full M3b, enable idle interruption, establish eventual recovery, or waive provider/platform gates. Confidence: high (90%) for this scoped conclusion.

## Scope and method

Task `task_18e5bcc3dcc57c61`, requirements revision 1; comprehensive audit on 2026-11-07. Ancestry was verified with `git merge-base --is-ancestor`; the range contains one commit, `caa8a8fe`. Every changed file was inspected: `src/bridge/owner_executor_native_test.odin` (+94), `docs/executor-dispatch-checkpoint.md` (+29), and `docs/m3b-provider-support-matrix.md` (+58). No production implementation changed. `git diff --check c61dad29 caa8a8fe` passed.

A clean detached checkout of the exact head was created inside the leased workdir for checks and removed afterward. The engineer checkout was not edited. Only this report is committed by the audit. Existing earlier native/owner/executor/Rust/package evidence is retained as earlier evidence; those suites are not represented as newly rerun here.

## Independent findings against requirements

| Requirement | Verified evidence | Boundary |
| --- | --- | --- |
| REQ-IDLE-A1: actual idle refusal | The real sealed Codex 0.162.0 child receives one exact Unicode/LF/TAB initial prompt, actual repository SessionStart hook reaches the authenticated current-bootstrap observer, and the fixture waits for a real completed turn. Two encrypted production notification exchanges return signed `unsupported_not_delivered`, with ESC/message/Enter counters all zero. | Refusal is the correct current behavior; idle delivery remains unimplemented. |
| REQ-IDLE-A1: cancellation | Normal device-signed `task.cancel` succeeds; retry reaches the owner nonce check and reports `no_current_target`, with outer exchange `invalid_scope`. The current-intent query also rejects. | This is a sequential cancellation proof, not every cancellation race. |
| REQ-IDLE-A1: revocation/rollback | A real P-256 device signature is added to a chained revoke statement for the actual enrolled owner signing-key identifier. Production directory verification accepts the observation and advances enrollment pin to 4 even though the next epoch content key is unavailable. Old-directory exchange returns `invalid_scope` without increasing nonce callback count. | Revocation follows cancellation in this scenario. It proves pin/rollback admission fencing before callback, not an independent race against a still-active dispatch. |
| REQ-IDLE-A2: retained resources | Zero notice transcript submissions/aborts, still idle, exactly one ticket with unchanged saved body, one capacity charge, and unchanged lease/work-attempt/bootstrap counts are asserted. | No capacity refund or trusted process absence is inferred from refusal, timeout, cancellation, or a lost journal. |
| REQ-IDLE-A2: cleanup | Own native PID and scratch tree are absent; Codex config digest is unchanged. Engineer cleanup output was independently read. | Cleanup is test hygiene, not an authoritative absence receipt. Older socket files predate this audit and were left untouched. |

Source audit followed genuine signed chain/task/policy/reservation/requirements creation, preparation/commit/bootstrap APIs, production materialization and spawn, and encrypted signed reverse-channel nonce replies. SQL in the new idle path reads evidence; authority is not fabricated with inserted rows or direct daemon observation opcode `0x42`. The fixture does explicitly invoke the real initial noninterrupt literal-paste transport to create the first turn.

`bridge_executor_directory` verifies the paired root and pinned directory, persists newer verified enrollment before content-key admission, and rejects older observations. Exchange admission resolves current trusted owner/executor keys. Notification dispatch checks current reservation/bootstrap/grant, persists the ticket before dispatch, consumes a fresh action-scoped nonce outside executor/startup locks, rechecks directory and current authority, queries the retained ticket, then dispatches only under startup serialization. Daemon `NativeProfile::begin` requires a current active native turn before ESC. Existing partial-write offsets, typed acknowledgment, immutable-ticket retry and capacity-retention logic remain unchanged by this delta. No automatic recovery claim is justified.

## Reproduction and outcomes

Both commands ran in the detached exact-head checkout through `ham-ctl shell run`; each exited 0.

```bash
nix develop --command env \
  HEIMDALL_NATIVE_CODEX=/home/linuxbrew/.linuxbrew/bin/codex \
  HEIMDALL_NATIVE_MODEL=gpt-6.1-sol \
  HEIMDALL_NATIVE_ARGS=/home/tanmay/.cache/heimdall-tests/native-owner-pending-20261107-1017.json \
  HEIMDALL_NATIVE_CTL=/nix/store/mdi06wsv3nnn1h7rx9pakgx1pqm0yx8a-ham-ctl-0.5.49/bin/ham-ctl \
  HEIMDALL_EXECUTOR_TEST_PTY=/home/tanmay/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host \
  odin test src/bridge -collection:odin_test=src \
  -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 \
  -define:EXECUTOR_NATIVE_OWNER=true -define:EXECUTOR_NATIVE_IDLE_REFUSAL=true \
  -define:ODIN_TEST_NAMES=main.test_executor_original_owner_native_notification \
  -out:/home/tanmay/.cache/heimdall-tests/audit-idle-caa8a8fe-1034

nix develop --command env \
  HEIMDALL_EXECUTOR_TEST_PTY=/home/tanmay/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host \
  odin test src/bridge -collection:odin_test=src \
  -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 \
  -define:EXECUTOR_TEST_REQUIRED=true \
  -out:/home/tanmay/.cache/heimdall-tests/audit-idle-bridge-caa8a8fe-1035
```

- Native: **1 pass in 7.063637438s**, `sh_14f1a174f04b50278206105aff0e34f5`, PID `3148991`, hook accepted 1; notice 0, abort 0, charge 1, cancellation/revoked replay `invalid_scope`, pin 4.
- Bridge: **1,045 successful in 58.641086043s**, `sh_291efce1751bf77bdc89d87e06147622`. Explicitly skips old-daemon compatibility without `HEIMDALL_EXECUTOR_OLD_PTY` and native opt-in (covered separately above). Existing allocator leak/bad-free warnings remain; passing assertions do not imply memory-clean execution.
- Configuration/vendor/cleanup checks: `sh_2e197796b04c162bb1a41a8b64b5cde5`, `sh_65c9cf570c53a61944406e80ad877036`, `sh_bf83397e726baa83197a0a4af7308467`. The documented cache symlink for ham-ctl was gone, so the same immutable store target was used and hashed inside `nix develop` (the store path is not visible outside that environment). Hash `f5a6674a72089664be9cbdc5fc77c22bf82bd323d4ed969658226dd34710e754` matches the reviewed hook manifest. Arguments digest `91fce628cbe0866a93d18e883c20767853927b10bf3e614a03de0c6697a3fac8`; daemon digest `83789d55a8219b5e61dedd33fa7992c5986303dbcbc7f27529ce348b0a10a0b3`.
- Codex binary digest matches the pinned `50ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38`. Config digest remains `d111397be1b38940d9b795a64f8b75dc61a659e98895d6aff0a41ba372aba6cf`. Own `/tmp/ham-p1c-3148943-1794047669525970320` and PID are absent. Remaining private sockets carry the older `1794044981445794420` suffix and 09:49 UTC timestamps, predating this audit.

The per-invocation hook/inline trust exception was inspected; it uses fresh bootstrap and private endpoint and does not save trust/auth/settings. No credentials were copied, provider installed, or live service restarted.

## Provider matrix and options

The matrix accurately separates ordinary child launch from native notification capability. Source checks: `pty_host_runtime.odin:406` declares the profile for Codex only; `daemon.rs:603` admits it from executable/platform checks; `delivery.rs:123` rejects interrupt Prepare without a profile. `native_notification.rs` requires the sealed exact binary/version and current session, rejects non-Linux hardened admission, and refuses idle/unknown state. `daemon.rs:1023` explicitly refuses Windows notifications. Historical Mac/Windows evidence does not establish current hardened notification support. Mac offline status is supplied chain context, not newly probed by this audit.

Independent bounded reads of the installed Claude binary confirm hash `dabafec82ca1319fa43d8be36a10fc61b1d11821cb98ad5df04ad95e199b8eed` and TAB-to-four-space replacement at the three documented offsets. In the paste handler this precedes the large-paste branch. This corroborates the actual native TAB failure documented in `docs/pty-provider-evidence.md:121`; no new Claude physical session or saved-config change was needed. It is not an exhaustive assessment of every vendor release or alternate input path.

Official documentation was independently opened: [interactive mode](https://code.claude.com/docs/en/interactive-mode) documents external-editor input; [terminal configuration](https://code.claude.com/docs/en/terminal-config#paste-large-content) describes collapsed pastes; [CLI reference](https://code.claude.com/docs/en/cli-reference) specifies structured input for print mode. These establish option descriptions, not exact-TAB preservation or authorization to replace the current PTY integration. Vendor-supported fix investigation, a separately approved alternate-transport prototype, or explicit continued unsupported behavior remain honest options. None closes M3b by itself.

## Preserved failure history and remaining gates

Engineer logs were read directly: `sh_6d212e09ec8efa8229782206fd3b8be7` failed fixture compilation for dynamic-array slicing and nonexistent directory-device field; `sh_71129ea978fa0d5769dd1ce361b76ae4` reached actual idle/cancellation refusal then failed an assertion comparing enrolled key ID with runtime principal. The final fixture correctly uses `p.key.key_id`. These are fixture corrections, not production fixes. Engineer final native and cleanup logs agree with the new evidence. The supplied `sh_98cfd4500beb88c560ef78c02b143e45` log contains commit output, not scratch-absence evidence; cleanup is supported instead by `sh_1303b4bc9bc6124e760f60fa28357300` and this audits own checks.

Full M3b remains open: idle delivery, Claude exact TAB, native hardened Darwin backend/online validation, Windows notification capability, broader revocation/cancellation races, cumulative failure/replay/capacity coverage, unfinished-ticket recovery, persistent Bridge restart, and authoritative absence before capacity release. Earlier connected and pending-loss audits remain scoped evidence. No implementation edits, deployment, push, provider reconfiguration, or platform waiver are part of this report.
