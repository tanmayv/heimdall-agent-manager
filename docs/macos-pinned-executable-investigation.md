# macOS pinned executable investigation at 96697a86

Evidence version 1, 2026-11-07, task `task_18e5b8966e90230e`, requirements
revision 1. **No safe macOS backend is established.** Keep hardened Darwin
native-profile admission disabled. The locked PTY crate closes inherited
descriptors, and Apple source does not support treating `/dev/fd/N` as Linux
parent-procfd image execution. The Mac is offline, so no native probe, existing
Nix installation assessment or platform acceptance ran. The coordinator directed
submission of this precise source investigation; native follow-up remains open.

## Exact scope and inspected sources

Implementation checkpoint:
`96697a86fc9c1db7e529707c09631c31546c4dd3`.
Read-only `git show` inspected `tools/pty_host/src/native_notification.rs`,
`daemon.rs`, `host.rs`, the lockfile, and the Darwin-options section of
`docs/executor-dispatch-checkpoint.md`. No engineer working-tree changes were
read or modified. This is a narrow backend investigation, not the independent
delta audit `task_18e5b8748bbe4cb8`.

`portable-pty` is locked to 0.9.0, registry checksum
`b4a596a2b3d2752d94f51fac2d4a96737b8705dddd311a32b9af47211f08671e`.
The local cached `src/unix.rs` SHA256 is
`14c85213b32074d71c8af334531fd027d6a0558dee830282620c88bab056c4b3`.
Source was read from the exact cached crate, not a newer upstream release.

Apple source was downloaded from the official repository and independently
matched byte-for-byte to commit
`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`. Four SHA256 values and sizes are in
[the evidence manifest](evidence/macos-pinned-executable-sources.json). These
sources explain the API mechanism; they are **not** proof that the offline
target's installed kernel/SDK has identical implementation. Cached web results
had older line numbers; citations below use the pinned downloaded source.

## What the implementation and APIs actually do

At `96697a86`, `NativeProfile::for_spawn` returns no profile on non-Linux targets.
Linux admits one observed vendor digest, holds a read-only file, and uses
`/proc/<daemon-pid>/fd/<fd>` for version probing and eventual launch. The daemon
substitutes that program path before `PtyHost::spawn`. Darwin has neither a
validated replacement for that procfd path nor an enabled hardened profile.

`PtyHost::spawn` passes program, argv, cwd and filtered/overridden environment
through `portable_pty::CommandBuilder`, then `slave.spawn_command`. In locked
`unix.rs:228-287`, the crate creates a standard command, assigns slave PTY stdio,
resets signals/mask, establishes a session and controlling terminal, and calls
`close_random_fds()` at line 276. Its implementation at lines 152-177 enumerates
`/dev/fd` and closes descriptors above 2. Clearing `FD_CLOEXEC` alone cannot
survive this explicit close. The existing crate exposes no executable-FD
exception in this path. A retained-FD backend would therefore require a scoped
crate/backend change, plus a separately proven image-selection mechanism.

Apple's documented `execve` accepts a pathname with explicit argv/environment;
ordinary descriptor inheritance is separate from executable selection. An
inherited descriptor does not itself request execution of its bytes.
[Apple execve manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/execve.2.html)

At pinned XNU `kern_exec.c:2397-2446`, image activation resolves the pathname
with `namei`, retains the resulting vnode, checks permission, then reads its
header using `vn_rdwr`. It does not obtain the image through the ordinary
user-space `open` duplication trick.
[Apple image activation](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_exec.c#L2397)

The descriptor filesystem's `fdesc_open` at lines 368-400 arranges special
descriptor duplication through the open machinery. Its separate `fdesc_read`
at lines 652-655 returns `ENOTSUP`; the vnode table assigns that read operation.
**Inference:** retaining `/dev/fd/N` may preserve access for ordinary open/read
after duplication, but does not establish executable-vnode header loading.
Do not advertise it as a supported macOS pinned-image backend without native
evidence contradicting or resolving this obstacle.
[Apple descriptor filesystem](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/miscfs/devfs/devfs_fdesc_support.c#L368)

Apple's `posix_spawn_file_actions_addinherit_np` at `posix_spawn.c:1875-1938`
marks descriptors to survive `POSIX_SPAWN_CLOEXEC_DEFAULT`. The header still
takes a pathname for `posix_spawn`. Inheritance actions can help control handle
leakage; they do not provide an executable-FD argument or eliminate pathname
replacement. No supported Darwin `fexecve`/`execveat` image interface was
established by this investigation; local SDK/man/symbol checks remain pending.
[Apple inheritance action](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/libsyscall/wrappers/spawn/posix_spawn.c#L1875),
[Apple spawn declarations](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/libsyscall/wrappers/spawn/spawn.h)

## Conditional options, not backend acceptance

| Option | Assessment / required proof |
| --- | --- |
| Preserve one FD and exec `/dev/fd/N` | Insufficient as a recommendation: both crate descriptor closure and Apple image-read behavior must be resolved. No native pass. |
| Custom native PTY spawn retaining an FD | Potential transport plumbing only. Must also demonstrate a supported OS image-selection primitive and exact bytes; custom fork/session/TTY handling alone solves neither. |
| Existing protected canonical vendor installation | Conditional alternative, never proven by root ownership or a Nix-store-looking pathname alone. Requires vetted digest and OS-enforced non-mutability of contents and all path components through activation. No installation assessment ran. |
| Copy/hash/chmod a user-writable scratch binary | Reject as proof: owner can change permissions/content or replace ancestors; a second pathname lookup remains. |
| Spawn suspended, then check path/version/digest | Not an established solution. A pathname is not running-image identity, and verification after launch cannot retroactively prevent execution. No native API, suspension/security or exact-image verification proof supplied. |

The protected-install option needs content and inode identity, ownership/mode,
ACLs, symlinks and every ancestor's rename/write permissions, mount semantics,
and concurrent updater/writer behavior assessed. Existing writable descriptors
and in-place mutation matter: holding an inode across rename does not freeze
its bytes between hash and activation. A cryptographic digest identifies the
bytes read; it does not lock them. Do not weaken the requirement to pathname,
version string, code-signing publisher identity, a user-owned read-only copy or
an unverified root-owned directory. No new root-owned installation, privilege,
mount, system trust or protection changes are authorized by this task.

Recommendation: retain the hard refusal. After reconnect, first inspect only
the exact existing native Codex binary and ancestor protections. If a vetted
existing immutable installation can be established, design narrow admission for
that concrete OS-enforced trust model and rerun adversarial native checks. If
not, pursue an officially supported image-handle mechanism and a dedicated PTY
backend only after the native image semantics are demonstrated. Neither branch
is approved or implemented here.

## Native prerequisite failure and reproducible next checks

The intended native host is enrolled Mac `brg_18e30f3f36df903e`, previously
Darwin 25.6.0 x86_64. This task's narrow read-only command was:

```bash
./bin/ham-ctl shell start --bridge brg_18e30f3f36df903e \
  --kind run --agent inst_18e568efd2a64539 --label mac-exec-prerequisites \
  --cmd 'uname -srm; xcrun --find clang; /usr/bin/clang --version; /usr/bin/man -w execve; /usr/bin/man -w posix_spawn; /usr/bin/man -w fexecve'
```

It was refused before session creation: `the bridge has not announced a boot id;
refusing to build enc_spec`. `bridge list --scope all` then reported offline,
runtime disconnected and empty unseal boot ID. No compiler/SDK availability,
current kernel, Nix binary path/protections or native syscall result is claimed.
The exact missing prerequisite is an online enrolled Mac with an announced boot
identity permitting managed encrypted shells. No credentials need copying.

After access is restored, the bounded disposable investigation should:

1. Record native kernel/architecture, SDK, compiler and documented API/symbol availability without installs or broad home/environment scans.
2. Build two private Mach-O fixtures A/B. Open and hash A, atomically replace its pathname with B, then compare a pathname-exec control against each actual image-handle candidate. A pathname control must run B; a safe candidate must run A or explicitly refuse. Record exact errno and child identity.
3. Separately attempt in-place modification through a concurrent writer held before admission. A candidate must prevent changed bytes from executing; rename-only success is insufficient.
4. Repeat under the real proposed PTY backend, preserving exact argv (including Unicode and spaces), explicit non-secret environment, cwd, stdio terminal state, session/process-group identity and controlling terminal. Verify descriptor whitelist, resize, signal/exit status and bounded I/O.
5. Track only private child/process-group identities; kill/wait only those on timeout. Close master/slave/image descriptors and verify children, socket and scratch drain on success and every failure path.
6. Only then add the trusted vendor digest and real Codex version/probe/PTY execution checks, followed by the separate installed-hook and complete encrypted owner-path gates. Historical 7f13c94e literal/interrupt observations do not satisfy hardened admission.

No helper was compiled or executed on another platform as a macOS substitute.
No native scratch, child, socket, provider session, installer or system change
was created in this task, so native cleanup has no created resources to drain.
Local source-download scratch is removed after manifest verification. Existing
provider authentication/settings and live services remain untouched.

## Validation and handoff

Read-only source commands were `git show 96697a86:<path>`, bounded `sed`/`rg`
against the locked crate and downloaded official Apple source, and `sha256sum`
for the cached crate source. The four Apple downloads were re-fetched at the
pinned commit and their hashes matched; this is source verification, not a
Darwin runtime test. The local JSON manifest and document links are checked
before commit. A native build/runtime check is deliberately skipped because
the required Mac is offline, and no backend-support pass is claimed.

Findings and prerequisite failure were sent to M3b, its engineer and coordinator.
The report is submitted for named independent review as a source investigation
with precise unsupported limits. It does not waive macOS, full owner-path,
same-UID state/authority, or independent platform gates.
