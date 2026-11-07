# Windows native PTY evidence at f6a8f209

Evidence version 1, 2026-11-07, for `task_18e5b5452b33312c` and M3b
`task_18e5ac3dc3e13d1e`, requirements revision 1. This is native Windows
evidence only. The pinned daemon deliberately refuses notification delivery on
Windows before child lookup or PTY write. No literal, replay, idle/busy interrupt,
post-interrupt delivery or full encrypted owner-path acceptance is inferred.

## Access, source and native inventory

The orchestration worker remained on Linux. All native commands used managed
shells on Windows Bridge `brg_18e3e1f4d5867bcd`; neither Linux nor WSL substituted
for Windows/ConPTY. Initial access was refused with `invalid_vault_key` before
execution. The error covers encrypted-spec decryption or parsing, not a specific
repair. The worker changed no credentials/services. The user later reported
re-enrollment, and a fresh own-scope native shell verified restored access.

Source is the coordinator-pinned portable snapshot `f6a8f209`, artifact
`art_18e5b52e7465e3eb`, prefix `heimdall-m3b-f6a8f209/`:

```text
bytes  211555
SHA256 87a6ec0ba2505c86105e333ba2f87592f889c22d475091a4ee0dcde4cc42f8e9
```

The archive was downloaded through artifact tooling, hashed on Linux, and
reassembled from 142 bounded source-only chunks on Windows. Native
`Get-FileHash -Algorithm SHA256` and file length match before extraction. There
is no Git metadata in the archive: no native Git commit attestation is claimed.
The procedure, Python harness, notification refusal and exact Windows test were
inspected before execution. The harness uses Unix-specific socket/PTY assumptions;
it is not silently adapted into a Windows provider pass.

Private scratch `C:\Users\Tanmay\.cache\hw-f6a8-18e5b545` was newly created
and restricted to the current user SID with `icacls /inheritance:r /grant:r`.
No dependency installer, global update, authentication change, persistent provider
configuration, live service restart/replacement, deployment or push was performed.
Cargo uses the existing native toolchain and locked dependency graph.

| Item | Observed value |
| --- | --- |
| OS / architecture | `Microsoft Windows 10.0.26200`, X64; not WSL |
| Native Rust target | `x86_64-pc-windows-msvc`, existing stable toolchain |
| rustc | 1.99.1, commit `58cf8f9c35b355199727627d07ae34a4e2846d67`, LLVM 23.1.1 |
| Cargo | 1.99.1 (`5f94df478`) |
| Native build tools | VS 18 BuildTools, existing MSVC component verified through `vswhere` |
| Python | Existing Python 3.12.2 in `C:\Program Files\Python312` |
| Git | 2.54.0.windows.1 |
| Codex | Existing `codex-cli 0.166.0`, npm PowerShell entrypoint; login status reports ChatGPT authentication |
| Codex model/profile | Config exists; no top-level model/profile/provider selection observed; actual interactive selection not established |
| Claude | Existing 2.1.302 native executable installed through WinGet |
| Claude model/auth | Settings contain `opus` alias; auth reports logged in, `claude.ai`, first-party. Actual session model/readiness not established |

Provider inventory printed only versions, selected non-secret configuration
fields and authentication booleans/methods. No credentials, account identifiers,
unrelated transcript contents or environment values were exported. The Windows
Codex version also differs from the newer native profile's 0.162.0 admission;
there is no profile/version support inference from this inventory.

## Exact execution and capability boundary

Initial inventory `sh_acf4fcd090fc5025aa6790d5b275e5b1` printed a quoted command
instead of evaluating it; that is not an inventory pass. Encoded PowerShell
`sh_9ce294460d29876dd3bcd19c10b04abc` established real OS/tool paths.
Version/profile checks are `sh_06b63352d4061779e4d08737e04532e3` and
`sh_9feb3ebb5da222a375af68b3d10f3785`.

The first 9000-character encoded source chunks exceeded the managed Windows
command-line limit. A raw nested `cmd.exe` quoting attempt also failed. The
first native hash was the empty-file SHA256 and the guard refused extraction
(`sh_dbc02262e4675e39b72b874967fd63f9`). No failed transfer was executed.
The replacement 2000-character encoded chunks passed the native hash gate in
`sh_fd5b51f0886aded60507b72613882ce9`. A local optional `rg` command was absent
from managed-shell PATH after successful extraction; direct read-only source
inspection supplied the intended source search instead.

Native build and exact test commands from the verified extraction:

```powershell
cargo build --locked --manifest-path tools/pty_host/Cargo.toml
$env:HEIMDALL_EXECUTOR_REQUIRE_PTY='1'
$env:HEIMDALL_NOTIFICATION_REQUIRE_PTY='1'
cargo test --locked --manifest-path tools/pty_host/Cargo.toml daemon::tests::notification_windows_is_explicitly_unsupported_before_lookup_or_write -- --exact --nocapture
```

The selected test exercises PREPARE, DISPATCH and QUERY, asserting the literal
`notification: unsupported_not_delivered` error and an empty daemon agent list
for every mode. It is a refusal test, not provider delivery. Source
`tools/pty_host/src/daemon.rs:1017` rejects Windows before lookup/write;
`host.rs` also has an explicit Windows refusal. Unknown or unsupported profiles
remain fail closed. No expected-text normalization, escape/API substitution or
requirement waiver was used.

| Check | Managed session | Native result |
| --- | --- | --- |
| Locked native MSVC build | `sh_fd5b51f0886aded60507b72613882ce9` | PASS, exit 0, 2m53s |
| Exact Windows notification refusal test | Same session | PASS, 1 executed, 0 failed/ignored, 192 unit tests filtered; 2 integration tests filtered, not coverage |
| Real private daemon/ConPTY spawn and capture | `sh_205e8ba64b64ff8291257b3cc4e99292` | PASS, real native `cmd.exe` output captured; exact child closed; daemon agent list empty; daemon stopped |

The test compiler emitted one unused-function warning for
`executor_pty_available`; no compile error was hidden. The Windows test was
selected with its fully qualified name and `--exact`, and actually executed once.
The Unix-centric generic PTY suite was not run or represented as Windows coverage.

The inspected [standalone ConPTY probe](evidence/windows-conpty-probe-f6a8f209.py)
uses existing Python, the exact built `ham-pty-host.exe`, a private `native.sock`,
and instance `win_native_f6a8`. It removes inherited `HEIMDALL_*` variables from
the private daemon environment and sets a 10-second native child lifetime. CLI
operations include:

```powershell
ham-pty-host.exe --socket PRIVATE_SOCKET daemon
ham-pty-host.exe --socket PRIVATE_SOCKET spawn --instance win_native_f6a8 --cwd PRIVATE_SCRATCH --timeout-seconds 10 -- C:\Windows\System32\cmd.exe /d /c echo NATIVE_CONPTY_F6A8
ham-pty-host.exe --socket PRIVATE_SOCKET capture --instance win_native_f6a8
ham-pty-host.exe --socket PRIVATE_SOCKET close --instance win_native_f6a8
ham-pty-host.exe --socket PRIVATE_SOCKET list
ham-pty-host.exe --socket PRIVATE_SOCKET stop
```

Actual daemon PID 15804 spawned native child PID 30092. Rendered ConPTY capture
contains `NATIVE_CONPTY_F6A8`. Close succeeds, list reports `(no agents)`, stop
succeeds, daemon exits 0 and the socket is absent. This proves native spawn/output/
cleanup transport, not literal notification delivery or provider interruption.

## Limits and handoff

| Capability | Native Windows disposition |
| --- | --- |
| Provider literal LF/TAB/Unicode | Unsupported through pinned notification path; not injected |
| Lost-reply same-ticket provider replay | Unsupported through that path; no pass claimed |
| Idle/busy interruption and post-interrupt message | Unsupported/unexecuted; no raw-ESC timing workaround |
| Claude exact TAB | Unverified here; known Linux normalization defect remains unresolved, with no waiver |
| Full encrypted owner/executor/native-result proof | Not run; portable source is not the complete integrated Bridge demo |
| Newer Mac/Linux profile evidence | Separate pins/tasks; cannot establish this Windows capability |

Existing provider support was inventoried rather than silently removed; the
unsupported result is specific to the notification primitive. The separate
Readline/Unix required-PTY suite is not treated as native ConPTY proof. No skipped
or zero-count suite is represented as coverage.

Final native cleanup `sh_206584b74db4197170c9f79cf4bb61c3` exits 0 and verifies
both test PIDs absent, zero private processes, socket absent and private workspace
absent. It checks exact PIDs 15804/30092, executable paths inside only
task scratch and the exact socket before deleting the private workspace. No
broad process kill or shared cache deletion is used. Source/build/chunks/probe
and the private daemon log are removed after capture; ordinary existing Cargo
caches, provider authentication/configuration and live services remain.

Selected versioned [managed-session records](evidence/windows-f6a8f209-sessions.json)
retain full native build/test/ConPTY/cleanup logs and representative failed
transport attempts. Chunk transfers are represented by the verified native
142-part count and exact reconstructed hash, rather than a claim that every
transient transport session was a native check. This evidence and defects are
posted to M3b and submitted for the named independent reviewer. Evidence approval
does not turn the explicit unsupported Windows capability into M3b acceptance.
