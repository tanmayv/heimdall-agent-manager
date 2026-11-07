# macOS native PTY evidence at f6a8f209

Evidence version 1, collected 2026-11-07 for `task_18e5b5451a9fe819` and M3b
`task_18e5ac3dc3e13d1e`. The native daemon builds. The unchanged notification suite
fails on macOS: 11/15 baseline tests pass; a short private temporary directory
improves this to 12/15. Actual Codex accepts exact Unicode/LF/TAB input once across
lost-reply replay, and accepts another exact input once after an observed raw ESC
interruption. Claude remains at its first-run security screen. These results do
**not** validate a production interrupt profile, encrypted owner-path delivery, or
full M3 acceptance. Failed checks remain failed; this is an evidence deliverable.

## Host, source, and dependency inventory

All native commands ran through the enrolled Mac Bridge
`brg_18e30f3f36df903e`, using an existing Linux orchestration worker. No Mac LLM
agent was launched or replaced. The foreground `shell run --bridge` shortcut
returned `not_found` for `sh_47840cc42d3d14da388001c60f349944`; explicit managed
shell creation worked:

```bash
./bin/ham-ctl shell start --bridge brg_18e30f3f36df903e \
  --kind run --agent inst_18e568efd2a64539 --cmd 'uname -srm'
```

| Item | Native result |
| --- | --- |
| Kernel / architecture | Darwin 25.6.0, x86_64 |
| macOS | 26.7.2, build 25G330 |
| Existing Python | `/usr/bin/python3`, 3.9.6 |
| Existing Clang / Xcode | Apple Clang 21.0.0; `/Applications/Xcode.app/Contents/Developer` |
| Existing Nix | `/nix/var/nix/profiles/default/bin/nix`; Determinate Nix 3.11.1 / Nix 2.31.1 |
| Isolated toolchain | rustc 1.95.0 (59807616e), Cargo 1.95.0 (f2d3ce0bd), Python 3.13.17 |
| Node / npm | v24.22.1 / 11.19.1 |
| Readline fixture | Nix `bashInteractive`, GNU Bash 5.3.9 |
| Codex | Private npm install, `codex-cli 0.162.0`; exact native session metadata also 0.162.0 |
| Claude | Private npm install, `2.1.319 (Claude Code)` |

Initial managed PATH and bounded conventional paths lacked Rust/Cargo and both
provider CLIs. The user explicitly authorized installing dependencies in the
answered task block. Existing Nix was outside PATH. Its default nixpkgs 26.11
rejects x86_64-darwin. An explicit supported package set resolved to
`github:NixOS/nixpkgs/57f1c8965649ce5bcac5118a0d2e41f1fbdc56e5` (26.05 Darwin).
No host channels, global profiles, startup files, sign-ins, or Bridge services
were changed. Nix store/cache downloads remain ordinary dependency cache entries.

The portable artifact `art_18e5b52e7465e3eb` was downloaded using artifact tooling
on Linux, transferred as five bounded source-only chunks through managed shells,
and verified again on the Mac:

```text
SHA256 87a6ec0ba2505c86105e333ba2f87592f889c22d475091a4ee0dcde4cc42f8e9
bytes  211555
prefix heimdall-m3b-f6a8f209/
```

This verifies the coordinator-supplied pinned archive. The portable archive has
no Git metadata, so no native `git rev-parse HEAD` attestation is claimed. It
contains the Cargo lock, contracts fixtures, procedure, and observation harness;
it lacks the complete Bridge/owner demonstration source. Archive members and
scripts were inspected before test execution.

Native private source/dependency workspace:
`/Users/tanmay/.cache/heimdall-mac-evidence-task_18e5b5451a9fe819`.
The original extracted Rust implementation was not modified. Separate scratch
copies used for diagnostics are explicitly identified below.

## Reproduction commands and native results

Define the pinned package set and private source root on the Mac:

```bash
NIX=/nix/var/nix/profiles/default/bin/nix
PKG=github:NixOS/nixpkgs/57f1c8965649ce5bcac5118a0d2e41f1fbdc56e5
SOURCE="$HOME/.cache/heimdall-mac-evidence-task_18e5b5451a9fe819/heimdall-m3b-f6a8f209"
cd "$SOURCE"
```

The native test invocation used these exact flags and Cargo arguments inside
the pinned Nix shell:

```bash
"$NIX" shell "$PKG#cargo" "$PKG#rustc" "$PKG#bashInteractive" --command sh -c '
  export HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_NOTIFICATION_REQUIRE_PTY=1
  export HEIMDALL_NOTIFICATION_READLINE_BASH=$(command -v bash)
  cargo test --locked --manifest-path tools/pty_host/Cargo.toml notification -- --test-threads=1 --nocapture
'
```

| Check | Session | Outcome |
| --- | --- | --- |
| Baseline, default Darwin TMPDIR | `sh_fc81eedf7fe59d431863ccf5a7a3ba30` | Exit 101; 11 passed, 4 failed, 0 ignored, 192 filtered; 15 executed |
| Unchanged source, private `TMPDIR=/tmp/hm-mac-18e5b545` | `sh_b2371dc66876e25a7c41cb9334e58eb8` | Exit 101; 12 passed, 3 failed, 0 ignored, 192 filtered; 15 executed |
| Separate daemon build | `sh_3415bd21d6a3d3f6782e099c2ed76758` | Exit 0 |

The build command was:

```bash
"$NIX" shell "$PKG#cargo" "$PKG#rustc" --command \
  cargo build --locked --manifest-path tools/pty_host/Cargo.toml
```

Baseline failures, using original archive line numbers:

| Test | Actual failure / interpretation |
| --- | --- |
| `daemon::tests::notification_readline_runtime_preserves_multiline_tab_and_unicode_as_one_paste` | `daemon.rs:2428`: generated socket path is 111 bytes, exceeding the 103-byte limit. Passes with short private TMPDIR, including literal editor-buffer and duplicate checks. This is a fixture-path issue; no global TMPDIR change was made. |
| `daemon::tests::notification_exact_child_socket_retry_and_lost_host_state` | `daemon.rs:2374`: expected single-space `1b 1b 5b 32 30 30 7e` capture absent. Logging-only diagnostic shows native `od` emits double spaces and wrapped output containing those physical bytes. Formatting-sensitive fixture failure; original assertion remains failed. |
| `host::tests::notification_full_pty_buffer_is_bounded_and_reader_survives` | `host.rs:661`: `F_GETFL` actual 65538 versus saved 2. Native flag-restoration discrepancy remains unresolved by this evidence task. |
| `host::tests::notification_partial_excludes_raw_and_startup_writers` | `host.rs:584`: final status actual 2 versus expected 1. Native discrepancy remains failed; diagnostic query/capture retained in session evidence. |

For requested diagnostics, another archive extraction under `diagnostic/` added
only two `eprintln!` calls: one before the socket capture assertion and one before
the final partial-delivery assertion. All assertions and production implementation
were retained. Its separate session is `sh_a9025b5317c2dcf218767ff64588b385`.
This diagnostic is not represented as an unchanged-source pass.
It exited 101 with 12 passed and 3 failed. Its partial query retained ESC written,
zero message bytes, Enter false, status 2, profile `readline-bound-escape-v1:50:100`,
and retry 0; the actual capture included `sh-5.3$` and `logout`. The full capture
is preserved in the companion logs, without inferring a production root cause.

## Native provider and profile matrix

Dependencies were installed under a private prefix, without changing global npm
configuration or existing provider executable locations:

```bash
"$NIX" shell "$PKG#nodejs" --command npm install \
  --prefix "$HOME/.cache/heimdall-mac-evidence-task_18e5b5451a9fe819/providers" \
  --cache "$HOME/.cache/heimdall-mac-evidence-task_18e5b5451a9fe819/npm-cache" \
  --no-audit --no-fund @openai/codex@0.162.0 @anthropic-ai/claude-code@2.1.319
```

npm did not run Claude's unapproved postinstall script; the installed CLI still
executed and reported its exact version. No postinstall approval was added.
Redacted CLI status checks reported Codex logged in and Claude
`loggedIn=true`, `authMethod=claude.ai`, `apiProvider=firstParty`. Credential files,
tokens, environment values, and unrelated conversation bodies were not dumped or
transferred.

| Provider | Existing selection / actual readiness | Literal / replay | Interrupt observation |
| --- | --- | --- | --- |
| Codex 0.162.0 | Existing config `gpt-5.6-sol`; no named profile/provider override. Actual ready UI showed GPT-5.6-Sol high. Exact fresh `session_meta.cli_version=0.162.0`, originator `codex-tui`. | 130-byte LF/TAB/euro/Japanese/emoji message exactly once in native transcript. Lost dispatch reply, query, and same-ticket duplicate return one effect. | Native busy UI advertised ESC; separate raw ESC yielded interruption acknowledgment in 174ms. Next 100-byte literal message exactly once with lost reply and same-ticket replay. No production profile pass. |
| Claude 2.1.319 | Existing settings model unset; coordinator approved observing the default. CLI reaches first-run Security notes / Press Enter screen. Actual model unavailable. | Unavailable: no provider-ready state or native submission established. Initial harness count=0 is a startup-gate failure, not a TAB result. | Idle/busy/post-interrupt unavailable because readiness was not established. No onboarding, sign-in, or settings changes accepted. |
| Other providers | Not inventoried by this bounded Codex/Claude subtask | No evidence claimed | Unknown profiles remain unsupported/fail-closed |

Codex evidence:
`/Users/tanmay/.cache/heimdall-tests/provider-observe-701b1732dec24ea3954340caf84e5344/observation.json`.
Successful native session: `sh_2f3fb18873379399cfb092ad10f34670`.
It used the exact built private daemon, `--provider codex --model gpt-5.6-sol
--seconds 10 --literal --escape-observe`. The existing model was preserved rather
than replaced with the Linux model.

The scratch observation harness added only: a per-invocation Codex
`-c check_for_update_on_startup=false`, a positive native ready-UI requirement
with rejection of startup prompts, and explicit cleanup evidence. Literal,
ticket/replay, byte-count, and native-transcript equality assertions were
unchanged. A separate ready-only run preceded injection. UI gating here is a
bounded observation precaution, **not** the structured interrupt-profile identity
and active-turn validation being implemented independently by M3b.

The successful initial receipt retained test ticket
`5464ef8f64937b12aa1ec4efd843f8dec6a1ea68765dd6df27f7676897a0baad`,
130 message bytes, Enter written, ESC false, delivered status 1. Post-interrupt
ticket was `93b9430823e94b46a4521e2a08ca4644bb9475acfff3bf761d80092acfa3c276`,
100 bytes, one native submission. These are disposable test identities.

### Preserved failed attempts and limits

The original pinned harness's startup check did not reject all update/onboarding
screens. Both initial provider attempts therefore ended with zero matching
native transcript entries:

- Codex session `sh_4ff27655299621da238f5ae1b26a1933`, fixture
  `provider-observe-a40f20e7d39340b887fdaa111e029ef7`: input reached an update
  prompt and triggered `npm install -g @openai/codex`. That attempt **failed**
  with EACCES writing the immutable Nix store; no global update succeeded. npm
  wrote a diagnostic log under the existing user's `.npm/_logs`. The attempt is
  explicitly disclosed rather than described as no attempted global operation.
- Claude session `sh_d19b4a20fc490f00c705b30ea43e6be1`, fixture
  `provider-observe-31317fa0f0e74818a0ccbedd7b0d7019`: input reached the first-run
  security screen. No native user transcript or model was established. The
  scratch launch copy omitted only `--model` to use the approved default; no
  persistent onboarding approval was accepted.

The later Codex per-invocation override is documented in the
[official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
It preserved installed version and user configuration. No global update retry
was performed. Claude's Linux TAB-to-spaces defect remains unresolved; the Mac
onboarding failure provides no evidence that Mac preserves or normalizes TAB.

Idle-provider interruption was not exercised. Busy raw ESC and its post-message
observation do not validate daemon `interrupt=true`, interruption correlation,
or a production InputProfile. No generic settle delay is inferred from 174ms.
No complete Bridge build, live service replacement, encrypted owner producer,
signed owner result/replay, authority-change proof, or full profile acceptance
was run from this partial portable archive. Full M3 review remains separate.

## Cleanup and evidence delivery

The successful guarded run recorded child PID 4813 absent from `ps`, private
daemon PID 4812 return code 0, and its unique socket absent. Every provider run
used its own generated socket/instance/tickets; the harness closes its exact
instance and terminates only its private daemon in `finally`.

Final cross-run resource inspection `sh_edf5e02307cfeb03b7086a87d8c1d15c` exited 0:
no private test processes remained, all four exact provider sockets were absent,
and PID 4813 was absent. It removed the private source/build/provider/npm-cache
workspace, the private short TMPDIR (including test lockfiles), and two identified
baseline runner-4507 temporary files. Both private workspace and TMPDIR were then
absent. Four exact test evidence directories and native vendor transcript
artifacts remain for audit. Existing credentials, profiles, unrelated transcripts,
Nix store/cache entries, live Bridge processes, and user npm diagnostic logs were
retained. No broad process kill or shared temporary-directory cleanup was used.

The companion `evidence/macos-f6a8f209-sessions.json` retains managed session
identities, final statuses and native logs. Findings and the Codex metadata were
sent directly to the M3b engineer `inst_18e554e13ee165a7` and coordinator
`inst_18e554c99e0743ee`, and posted on both tasks. The report and evidence are
submitted to the task's named independent reviewer. A passing evidence review
does not turn the recorded native failures or unavailable capabilities into
implementation acceptance.
