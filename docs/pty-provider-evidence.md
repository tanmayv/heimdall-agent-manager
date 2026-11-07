# M3b native PTY/provider evidence procedure

Status: Linux native literal/replay observations and a Claude TAB failure are
recorded below. No production interrupt-profile or macOS pass is established. The required baseline is real Codex CLI and Claude Code
on Linux and macOS, using the existing configured profile, not a mock provider
or Readline substituted for that provider. Other advertised providers must be
inventoried with explicit unavailable/unsupported results when evidence is missing.

## Isolated host prerequisites

Use an online, currently enrolled Bridge with explicit access to a disposable
checkout of the exact worker commit. Record Bridge ID, OS/architecture, commit,
CLI executable path/version, configured provider/profile/model and enabled state.
Do not dump profile secrets, authentication files or agent tokens into evidence.
The actual selected profile must already be authenticated. Missing auth, disabled
provider, unsupported model, unavailable executable and unavailable host are
separate gate failures, not successful interruption tests.

Build and run private test daemons and children only. Do not replace/restart the
live Bridge or daemon, change enrollment, alter user provider profiles or push.
Use private Unix sockets and unique output paths under the test account home.
Clean up every child and private daemon even on failure. macOS requires a real
TTY-capable login/session; Linux results or Darwin compilation are not substitutes.

## Portable transport gate

From the disposable checkout, record `uname -sm` and `git rev-parse HEAD`, then:

```bash
nix build .#ham-pty-host -o "$HOME/.cache/heimdall-tests/m3b-native-pty-UNIQUE"
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_NOTIFICATION_REQUIRE_PTY=1 cargo test --manifest-path tools/pty_host/Cargo.toml notification -- --test-threads=1 --nocapture
```

The notification required flag fails when a real PTY probe is unavailable. For
the separate Readline transport fixture, set `HEIMDALL_NOTIFICATION_READLINE_BASH`
to an existing Bash with Readline/DEC2004 support. In particular, inspect macOS
system Bash support instead of assuming it has current Readline capabilities.
An explicit unavailable Bash path or required missing Readline fails the gate.
This fixture tests editor-buffer preservation, not actual provider behavior.

## Actual configured provider gate

For both Codex and Claude, record the existing launch plan and actual CLI version
without changing profile configuration. Launch a fresh isolated child using that
plan, normal approved authentication and a disposable empty workdir. Do not give
the evidence child production Heimdall credentials. Record visible provider-ready,
busy/generating, interruption and post-delivery states. A startup/login/consent
screen is not readiness. Keep requested actions confined to the disposable fixture.

Deliver a literal multi-line message containing LF, TAB, euro, Japanese and an
astral emoji via the exact-child notification prepare/dispatch/query path. Retain
intent/ticket and byte offsets; verify one editor submission with exact Unicode
content and no split lines, interpreted controls, duplicate submission or dropped
suffix. Repeat the same ticket after a lost reply; require the same result and
one provider effect. Start an observable long-running provider action, deliver
its validated interrupt profile, and verify actual cancellation before the new
message is accepted once. Record unsupported profiles without selecting a generic
ESC delay. Unknown profiles must remain fail-closed.

Finally exercise a genuine existing owner producer through current authorized
target resolution, encrypted executor dispatch and signed exact result/replay.
Record owner/executor/reservation/incarnation/config/token generations, authority
change rejection, replacement refusal, no-current-target behavior, and retained
receipt recovery across reconnect/partial I/O. Source visibility/ACK, PTY-written
and provider-handled outcomes must stay separate. A direct local transport test
alone does not pass this production gate.

## Windows boundary

Run native build and the native explicit unsupported-delivery test when a Windows
host is available. The selected daemon notification primitive currently refuses
Windows before lookup/write. Record native build/runtime availability honestly;
do not claim a Windows pass from Linux compilation, mocks or test source alone.
Preserve existing declared provider support in the inventory; unsupported
notification behavior is a specific capability result, not silent support removal.


## Linux native observations at checkpoint 015304f3

The disposable harness tests/observe_provider_notification.py launches a private
daemon and fresh native CLI, clears inherited HEIMDALL_* credentials/routing
values, retains the exact daemon ticket before dispatch, deliberately loses a
dispatch reply, queries/replays that ticket, and checks only the exact new native
session transcript. It cleans up the private child/daemon on success or failure.
It may acknowledge Claude's trust prompt only when it names the empty fixture
directory just created by this harness. It never approves authentication prompts.

The enabled cached catalog models selected explicitly were gpt-6.1-sol and
claude-opus-5-5. Native profile lookup has no codex/claude override and uses the
existing default fallback. The observation harness adds Codex read-only sandbox
and no-alt-screen options for the disposable probe; it is native CLI evidence,
not a full production-launch-profile attestation.

Final Codex command:

```bash
nix develop --command python3 tests/observe_provider_notification.py --daemon $HOME/.cache/heimdall-tests/m3b-transport-bins-20261107-0719-1/bin/ham-pty-host --provider codex --model gpt-6.1-sol --seconds 5 --literal --escape-observe
```

Session sh_075a32cedc12a70dcfc3d7a9f801f35e exited 0. Actual codex-cli 0.162.0
accepted one exact 130-byte LF/TAB/euro/Japanese/astral-emoji input. Lost-reply
query and duplicate Dispatch retained one exact native user transcript entry.
The native busy screen advertised ESC interruption; a separate ordinary raw
ESC produced the native interruption acknowledgment in 202ms. After observing
that acknowledgment, a second 100-byte literal notification was consumed once,
including a lost reply and same-ticket duplicate. Full private evidence:

/home/tanmay/.cache/heimdall-tests/provider-observe-00a07693e6414a21b3a14f31c449660d/observation.json

This does **not** establish a production notification InputProfile: raw ESC and
observed native acknowledgment were separate from interrupt=true daemon
dispatch. In particular, do not turn the observed 101ms/202ms timings into a
generic settle delay or infer macOS behavior.

Claude command (same daemon, seconds and flags, provider/model replaced):

```bash
nix develop --command python3 tests/observe_provider_notification.py --daemon $HOME/.cache/heimdall-tests/m3b-transport-bins-20261107-0719-1/bin/ham-pty-host --provider claude --model claude-opus-5-5 --seconds 5 --literal --escape-observe
```

Actual Claude Code 2.1.319 reached its authenticated Opus 5.5 generating UI.
Session sh_3d9371b3b0b50430659c4d51ae6a2d6d exited 1: the daemon delivered the
literal payload, but Claude's native user transcript replaced U+0009 TAB with
four U+0020 spaces. This is a native literal-input **failure**, not a rendering
pass, an auth failure or evidence that its interrupt profile works. Evidence:

/home/tanmay/.cache/heimdall-tests/provider-observe-91f7299503ec44bf863602dda8521af9/failure.json

The exact expected/native strings were compared in
sh_c721c3851e26353a60248aa42eff0d25. A bounded inspection of the installed
claude.exe found the paste handler's unconditional TAB-to-four-space
normalization at byte offset 320511660, plus prompt onChange normalization at
320502497/320468854 (sh_7e7d600cb7f56ac3b2ea9c461932eb70). No relevant
preserve-TAB flag was found in help or the bounded native flag-name inspection.
This is not an exhaustive claim about future vendor versions or APIs. No
configuration, encoding, API substitution or expected-text normalization was
used to conceal the failure. Coordinator/user disposition remains pending;
exact TAB capability must stay failed/unsupported unless preservation is proven.

An earlier Claude harness attempt looked under the wrong project slug and saw
zero transcript entries. The fixed harness locates only its explicit fresh
session UUID, then exposes the actual TAB mismatch above. Do not repeat that
diagnostic dead end or treat count=0 as evidence of missing provider auth.

Mac host access, native Mac evidence, validated production interruption profiles,
positive integrated owner checkpoint delivery/replay, Windows native availability
and named independent review remain open. No live Bridge/daemon restart,
deployment, provider upgrade or push occurred.


## Spawn-bound native Codex profile (2026-11-07 continuation)

The daemon now accepts the trusted spawn declaration
codex-native-session-v1. It independently requires an absolute native Codex
executable, checks exact CLI version 0.162.0 with a bounded native --version
invocation, and records its SHA256 in the immutable profile identifier.
Unknown binaries/versions/platforms retain no interrupt capability. No
notification or environment field selects a profile.

A current-child SessionStart observation binds once to a native JSONL session
inside the configured Codex sessions root. The daemon checks exact session ID,
cwd, fresh startup time and observed state-producer version 0.162.0 or 0.167.0.
It pins file identity/header and refuses clear/resume/replacement retargeting.
Before ESC it requires a structured active native turn and captures the complete
file boundary and prefix digest. Before paste it requires a newly appended outer
event_msg/turn_aborted(reason=interrupted) for that same turn, with a native UTC
timestamp after physical ESC. Nested user/assistant strings, old events, newer
turns, file changes and timeout cannot acknowledge delivery. There is no
fixed-delay fallback. Idle/unknown state is explicitly unsupported. Native
history reads are bounded at 8MiB; partial delimiters fail closed without an
assumed native parser timeout.

The Linux real native probe passed in sh_22f528f0bd6ebe2552e7154fec02a987:

```bash
nix develop --command python3 tests/observe_provider_notification.py --daemon $HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107/release/ham-pty-host --provider codex --model gpt-6.1-sol --seconds 5 --literal --native-interrupt
```

Actual CLI and session producer were both 0.162.0 in that passing probe.
The initial 130-byte literal input and the subsequent 102-byte interrupt
notification each produced exactly one byte-exact native user entry, retaining
LF/TAB/euro/Japanese/astral emoji. The interrupt=true daemon delivery waited for
one fresh typed native abort; deliberate lost dispatch reply, Query and duplicate
Dispatch preserved its exact ticket and one submission. Evidence:

/home/tanmay/.cache/heimdall-tests/provider-observe-fd726e9746fc464ca9c1d753089acba2/observation.json

This probe supplies the exact disposable native SessionStart observation itself;
it is a real daemon/provider profile pass, not the complete original owner
producer -> encrypted executor -> native child -> owner signed-result proof.
Production local SessionStart and the narrowly scoped remote bootstrap-authenticated
observation route still require their cumulative and positive connected tests.

Draft failures were retained honestly: a five-second debug Spawn timeout was
too short for executable hashing; the harness now allows thirty seconds only
for Spawn. A readiness predicate assumed an absent context footer and refused
input safely; it now recognizes the observed ready UI while rejecting update,
security/onboarding and auth/workspace gates. A transcript check initially read
only native user_message events, while this release uses user response_item
records; the existing event-or-response fallback now compares the same exact
expected string. No normalization of input or expected transcript is allowed.

Mac f6a8f209 evidence is preserved separately. Its three failing native tests
exposed od whitespace, an interactive-shell mode/EOF race in a mocked-writer
fixture, and an assertion comparing Darwin read-only F_GETFL flags. Fixture
corrections retain exact physical byte/status checks and specifically verify
O_NONBLOCK restoration. Long Darwin TMPDIR paths use a bounded /tmp socket
fallback. A separately leased rerun must validate these changes and the new
native profile; Linux results imply no Mac/Windows pass. Claude TAB remains
failed/unwaived. Windows native access is currently blocked by the reported
invalid_vault_key managed-shell error. Independent review and full connected
production evidence remain required; no live restart/deploy/push occurred.


## Audit corrections after 7f13c94e (2026-11-07 09:12 UTC; not acceptance)

These corrections supersede the earlier native-profile capability description.

- F1: authenticated SessionStart now retains an immutable exact session/path
  observation without reading a not-yet-created file. PREPARE validates its
  canonical root, metadata/version, identity and header lazily. A unit test
  proves startup-before-file resolution. This is not the missing positive
  installed-hook -> authenticated observer proof.
- F2: clear/resume/unknown lifecycle sources or different startup observations
  permanently invalidate the profile. Both local and bootstrap-authenticated
  remote observation routes forward that lifecycle source. Pending input cannot
  continue after invalidation; completed receipt replay remains read-only.
- F3: Linux capability admission now checks the exact observed vendor executable
  SHA25650ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38.
  Native --version and PTY exec use the daemon-held file descriptor via
  /proc/<daemon-pid>/fd/<fd>, rather than reopening the original path. Tests
  reject an unknown native executable before a version probe and preserve the
  original inode across a pathname replacement. Actual descriptor-executed
  Codex interrupt/literal/replay passes sh_0d5fdeb5d38efb51a7cea42c354312db.
- F4: native session producer version must now equal0.162.0;0.167.0 is refused.
- F5: fixture IDs add a process-wide atomic suffix; native tests pass in default
  parallel mode.
- F6: an already validated same-ticket paste resumes its remaining bytes without
  re-polling the eight-second native acknowledgment horizon. Lifecycle/paste-mode
  invalidation still refuses writes.

Darwin native capability is conservatively refused in this hardened revision
until a safe immutable executable backend is demonstrated. This is an open
Milestone3 gate, not an accepted platform reduction; prior Mac native results
at9e6b89af/7f13c94e remain historical evidence. Source-backed backend choices:
portable-pty0.9.0/src/unix.rs:228-282 constructs a std Command and closes random
descriptors at pre_exec line276, so inherited /dev/fd execution is not currently
a proven Darwin substitute for Linux parent-procfd execution. Options to verify
are a narrowly scoped native spawn backend retaining exactly one verified
executable descriptor, or a vendor-hash-pinned canonical installation whose
file and every mutable ancestor are OS-enforced root-owned/non-writable to the
child. Neither option is implemented/proven here; no generic-copy/path-name
solution is claimed immutable. Same-uid writable native logs remain transport
evidence only, and bounded8MiB reads/hashes still hold the daemon agents lock.

Checks after corrections:
```bash
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_PTY_REQUIRED=1 CARGO_TARGET_DIR=$HOME/.cache/heimdall-tests/m3b-native-profile-target-20261107 cargo test --locked --manifest-path tools/pty_host/Cargo.toml
```
Default-parallel214 unit+2 safety pass,2 subprocess-only ignores in
sh_49d5c145e7c4b73641e7a6b51040d9dd. The earlier full parallel run failed an
existing resize test race: Attach's first Screen preceded processing the next
one-way Resize. The fixture now waits up to3s for actual40x120 effect before
disconnect; the production resize path is unchanged. Serial212+2 passed before
the two new inode/digest tests (sh_31a297ad41171a297266f81b8b669440).
Final pending-lifecycle guard focused23+2 passes sh_9cab8796820d506dcfc5f3309dc50020.
Full hardened Bridge1043 pass sh_b6a5bf76c098c2d68e370f1519b53e4e with prior
required-PTY command/output m3b-audit-full-bridge-20261107-0903. ham-bridge
package build passes sh_31b3be554aaee07aecaed3a1f613fae4:
nix build .#ham-bridge -o $HOME/.cache/heimdall-tests/m3b-audit-profile-bins-20261107-0910.

Native hook prerequisite investigation:
The read-only installed native plugin inventory contains no Heimdall entry.
The strict --native-hook probe failed rather than using direct0x42 observation.
Official OpenAI docs https://learn.chatgpt.com/docs/hooks and installed0.162.0
help support project hooks plus --dangerously-bypass-hook-trust for automation
that vets exact hook sources. Coordinator explicitly authorized the inspected
private fixture only, with per-invocation flags and no persisted settings.
The --vetted-fixture-hook harness writes only a private project hook/script and
records SHA256/config/argv. Both lexical and canonical project trust -c keys
still reached a native Folder access prompt saying the decision will be saved;
no approval/input was sent. Sessions sh_ecd5a09147d6877d4cd1fc1ffba612b6 and
sh_807a73bad8bb4a6b88606c97141ed746 fail honestly. Last fixture source:
hook SHA2564aef8b5850f310c1f50c6e9895deeedef1eeddca9e42db827c5e1eb50d65cf4d,
config SHA256c064480da9bd5dd1d546690a50d28303a49b7d7ccf90becb435454ea610db353;
exact argv/screen retained in
/home/tanmay/.cache/heimdall-tests/provider-observe-64bc54afb4b64d31b4fbe1a63eb24128/.
No native hook pass is inferred. A supported disposable already-trusted real
extension launch is still needed, followed by the original owner hold producer
through encrypted exact-child dispatch, physical result/replay and owner
acceptance. Windows access, Claude TAB disposition and named audit re-review
also remain open. No complete submission, live restart, deployment or push.
