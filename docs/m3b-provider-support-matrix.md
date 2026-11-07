# M3b provider behavior and remaining gates

As of 2026-11-07, the tested Linux Codex busy-turn path delivers the exact owner notice once. A real idle Codex session safely refuses input; cancellation and a newer device-signed owner revocation preserve that refusal. Claude literal TAB, hardened macOS execution, and Windows notifications remain unsupported or unproved. Passing refusal checks does not complete the cross-platform M3b acceptance criteria.

**User decision, 2026-11-07:** retain the current exact PTY requirement (source message `msg_18e5bcdbb5cda4c6`, coordinator relay `msg_18e5bce0f924df3e`). No alternate editor/stream-JSON/API transport planning or implementation as a substitute is authorized. No TAB normalization or acceptance waiver. Claude remains an open gate until a supported literal PTY path is proven.

## Enabled behavior versus notification capability

**Mac deferral, 2026-11-07:** the user answered the successor task's block with
“Skip real mac for now” (task `task_18e5beeef261412e`, attempt 2). Real Mac
provider execution is deferred. This is not native acceptance or permission to
install a protected image. The approved guarded-image engineering at `df0b9527`
proves inspection and refusal only; see `docs/darwin-guarded-image-engineering.md`.
Production Darwin activation still refuses at
`tools/pty_host/src/darwin_image.rs:190`, and the notification profile remains
disabled at `tools/pty_host/src/native_notification.rs:88`. The separate Claude
exact-TAB requirement is unchanged by this Mac-only decision.

Provider launch/profile enablement is separate from notification support. The Bridge requests the native notification profile for Codex only (`src/bridge/pty_host_runtime.odin:406`). The daemon enables it only when executable and platform admission succeeds (`tools/pty_host/src/daemon.rs:603`); other children can still launch, but interrupt Prepare without a profile refuses before input (`tools/pty_host/src/delivery.rs:123`).

| Platform/provider/state | Current behavior | Evidence boundary and remaining gate |
| --- | --- | --- |
| Linux Codex CLI 0.162.0, tested `gpt-6.1-sol`, authenticated active turn | Exact Unicode/LF/TAB input and owner notice; typed same-turn interruption; partial/lost-result reconciliation; once-only delivery | Connected original-owner/native proof and named audit `e4ca4ae9`. Admission requires the exact vendor SHA256 below and sealed executable bytes, not merely a version string (`tools/pty_host/src/native_notification.rs:75`). Other releases/hashes are unapproved. |
| Same Codex, real completed/idle turn | Signed `unsupported_not_delivered`; zero ESC/message/Enter; same prepared ticket on retry | New real idle proof below. The profile requires an independently active turn (`tools/pty_host/src/native_notification.rs:187`); idle notification delivery remains an open requirement, not an enabled feature. |
| Same Codex, cancelled owner intent | Retrying prepared idle delivery refuses; owner nonce reports `no_current_target` | Signed `task.cancel` followed by actual encrypted production retry (`src/bridge/owner_executor_native_test.odin:560`). No new task authority or native input. |
| Same Codex, newer signed owner revocation | Verified next directory advances the pin to 4 despite unavailable next epoch key; old-directory replay refuses before another nonce callback | Actual device-signed log entry and production directory verification (`src/bridge/owner_executor_native_test.odin:569`). This does not test every possible revocation race. |
| Same Codex, daemon loses a pending partial ticket journal | Exact launch is unknown; original ticket Query says `recovery_required`; production retries refuse; expiry retains capacity | Named pending-loss audit `89bfda15`, artifact `art_18e5bc7e475b471c`, exact delta `87b6df96..c61dad29`. Safe refusal only: no eventual recovery, persistent Bridge restart, known absence, or capacity refund is established. |
| Linux Claude Code 2.1.319, tested Opus 5.5 | Normal CLI launch is distinct from interrupt notification capability; no native interrupt profile is enabled. Prior literal-paste probe changes TAB into four spaces | Actual native failure documented in `docs/pty-provider-evidence.md:121`. Interrupt notification Prepare refuses without a profile (`tools/pty_host/src/delivery.rs:123`). Exact TAB remains failed/unwaived; no native interrupt support is claimed. |
| macOS Codex/Claude | Real execution deferred by user for the current milestone; Darwin notification profile disabled | Reviewed guarded-image engineering `df0b9527` verifies private pinned 0.162 bytes and native refusal tests, not provider eligibility. Activation refuses unproven lifetime policy (`tools/pty_host/src/darwin_image.rs:190`); production profile remains absent (`tools/pty_host/src/native_notification.rs:88`). No new Mac probes or installation are authorized by the deferral. |
| Windows providers | Notification dispatch unsupported; platform launch/ConPTY evidence is separate | Explicit daemon refusal (`tools/pty_host/src/daemon.rs:1023`). Coordinator reports repaired/reapproved Windows checkpoint `12838668`; this is not a Windows notification/provider pass. |
| Other binaries, versions, or unknown lifecycle state | No native interrupt capability inferred | Fixed declaration, native binary/hash/version and current session checks fail closed (`tools/pty_host/src/native_notification.rs:75`, `:120`, `:187`). |

Pinned Codex vendor SHA256: `50ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38`.

## Claude TAB assessment and approved next work

The installed Claude Code 2.1.319 binary has SHA256 `dabafec82ca1319fa43d8be36a10fc61b1d11821cb98ad5df04ad95e199b8eed`. Read-only inspection in session `sh_026de142f7025211fe9cd49285fa2786` reconfirmed the paste handler's TAB-to-four-space replacement at byte offset `320511660`, before its large-paste collapse decision. Prompt change and restore handlers also replace TAB (`320502497`, `320468854`). These observations agree with the real native transcript failure; they are a bounded inspection of this vendor build, not a claim about every future version.

The [official interactive reference](https://code.claude.com/docs/en/interactive-mode) documents external-editor input and Tab as an interactive shortcut. The [terminal reference](https://code.claude.com/docs/en/terminal-config#paste-large-content) explains collapsed pastes. Neither demonstrates preservation through this installed paste handler. The [CLI reference](https://code.claude.com/docs/en/cli-reference) puts structured stdin in print mode; it is a different transport from sending an exact notice into the current PTY child. Documentation checked 2026-11-07; installed `claude --help` was also inspected in `sh_24371647545b39e394f8e18523772005`.

No supported exact-TAB route is demonstrated for the current Claude PTY integration. Larger paste does not bypass the inspected replacement. External-editor or stream-JSON work must not silently replace the required PTY path, change the payload, or alter saved user configuration.

| Current disposition | Concrete work needed | What it would establish |
| --- | --- | --- |
| Preserve the current acceptance gate and investigate a vendor-supported fix | Obtain a documented TAB-preserving interactive path or fixed vendor release; pin its bytes; prove LF/TAB/Unicode and native interruption on actual supported hosts | Could close the existing PTY requirement after independent review. No such fix is established now. |
| Alternate transport rejected as a substitute by current user decision | No editor/structured-input/API planning or implementation under this task | No scope expansion or substitute evidence. The exact PTY requirement remains unchanged. |
| Keep unsupported behavior explicit while other gates are investigated | Continue refusing unproved notification paths; make the failed Claude TAB and offline Mac evidence visible | Honest current capability reporting, with M3b remaining incomplete. It is not a platform or provider waiver. |

Mac access was restored and subsequent guarded engineering prepared private pinned 0.162.0 bytes, but established no eligible immutable executable backend. Revision 2 of successor `task_18e5beeef261412e` now defers real Mac execution from the current milestone; Darwin remains disabled. The protected-image plan is separate and grants no installation authority. Missing daemon journals still need explicit recovery/absence evidence before releasing capacity. Claude's exact-TAB requirement remains unchanged.

## New bounded real idle and revocation evidence

The opt-in `EXECUTOR_NATIVE_IDLE_REFUSAL` fixture uses the original signed owner/enrollment/bootstrap setup and actual repository `ham-ctl` SessionStart hook. It sends one exact initial Unicode/LF/TAB prompt asking for a short response, then waits at most 15 seconds for a real completed turn (`src/bridge/owner_executor_native_test.odin:299`, `:346`, `:527`). No fake session event or native transcript is inserted.

Two encrypted production hold-notice attempts return signed `unsupported_not_delivered` with zero write counters (`:549`). Normal signed owner cancellation refuses the old ticket (`:560`). A root-device-signed revocation of the actual enrolled owner signing key advances the trusted directory and denies old-directory replay (`:569`). The native transcript has zero notice submissions and zero aborts; one immutable ticket and one capacity charge remain, with no lease/attempt/bootstrap growth (`:595`). SQL reads inspect evidence; no authority row is inserted.

Final native test: **1 pass**, 5.58 seconds, `sh_fccfda47c755776dcf34871798eba283`, native PID `3141451`, cancellation `invalid_scope` after owner nonce refusal, revoked replay `invalid_scope`, pin 4. Full required-daemon Bridge: **1,045 pass**, 59.16 seconds, `sh_f4166e587edeabe16697c0a514cd1437`. The normal suite skips native opt-in (covered separately here) and old-daemon compatibility without the old binary. Existing allocator warnings remain; no leak-free claim.

Exact commands from the task worktree:

```bash
nix develop --command env HEIMDALL_NATIVE_CODEX=/home/linuxbrew/.linuxbrew/bin/codex HEIMDALL_NATIVE_MODEL=gpt-6.1-sol HEIMDALL_NATIVE_ARGS=$HOME/.cache/heimdall-tests/native-owner-pending-20261107-1017.json HEIMDALL_NATIVE_CTL=$HOME/.cache/heimdall-tests/m3b-native-ctl-20261107-0931/bin/ham-ctl HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_NATIVE_OWNER=true -define:EXECUTOR_NATIVE_IDLE_REFUSAL=true -define:ODIN_TEST_NAMES=main.test_executor_original_owner_native_notification -out:$HOME/.cache/heimdall-tests/m3b-owner-idle-refusal-20261107-1028
nix develop --command env HEIMDALL_EXECUTOR_TEST_PTY=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:EXECUTOR_TEST_REQUIRED=true -out:$HOME/.cache/heimdall-tests/m3b-idle-full-bridge-20261107-1028
```

The arguments manifest and reviewed per-invocation hook come from `sh_f455cfc8ef8ae0908699e665f4aedb2f`; normal native config/auth stores are not copied or edited. Initial compile `sh_6d212e09ec8efa8229782206fd3b8be7` failed a dynamic-array argument and directory-device field name. First physical idle run `sh_71129ea978fa0d5769dd1ce361b76ae4` proved refusal/cancellation, then failed a fixture assertion comparing an enrolled signing-key identifier with the runtime Bridge principal. The final fixture uses the actual key identifier; no identity is relabeled and no production defect is inferred.

Cleanup `sh_1303b4bc9bc6124e760f60fa28357300` verifies both physical idle-run PIDs (`3140140`, `3141451`) absent, no native-owner/hook sockets or locks created since this idle run began, and the first physical fixture workdir removed. Codex config SHA256 remains `d111397be1b38940d9b795a64f8b75dc61a659e98895d6aff0a41ba372aba6cf`. No Claude user-config change, onboarding approval, or new Claude physical run was needed for the bounded installed-vendor/help assessment. Package/owner/Rust checks were not repeated for this Bridge-test/docs-only delta.

Coordinator confirmation at10:50 UTC: independent idle audit `task_18e5bcc3dcc57c61` is done, named-approved and merged at `873aa65c`, for exact `c61dad29..caa8a8fe` evidence only. This does not enable idle delivery or close platform gates. M3b is not submitted as complete; no deployment, live restart, provider reconfiguration, or push is authorized by this evidence.
