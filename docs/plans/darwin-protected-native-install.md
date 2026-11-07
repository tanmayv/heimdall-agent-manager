# Protected Darwin native image: installation and lifetime proposal

This is a **planning/preparation deliverable, not installation authorization or a
supported Mac backend**. Choose a fresh root-created image in a dedicated,
append-only version tree with indefinite retention. This resolves the proposed
pathname lifetime model without adding a privileged service. The complete loader
invariant is still unproven for the pinned vendor image, so **do not execute a
privileged install or enable the backend on this evidence**. The assets below are
exact review proposals; their CLI refuses every apply request. Production Darwin
native notifications remain disabled. Nothing in this proposal changes Nix,
global provider profiles, credentials, owner authority, encryption, or PTY transport.

Task: `task_18e5c0c80f6ae9c1`, requirements revision 1. Baseline:
`df0b952742c622ecdf2d1ace16faa54606489cfe`; substrate implementation `faab1ee8`,
predecessor carry `d4b73182`. This document specifies future code rather than
claiming it already exists.

## Decision, attacker and trusted computing base

The attacker is an arbitrary process running as the provider uid (observed Mac
uid 501), another unprivileged uid/group, or an unprivileged installer. It can hold
an input writer before inspection, race its own input paths, send hostile spawn
environment/arguments, and attempt rename, hardlink, truncate, ACL or mount tricks.
It has **no root, sudo authorization, kernel exploit, mount administration,
signing authority, or ability to alter the trusted daemon**. Same-uid compromise
of the daemon itself is outside the native image byte guarantee: this is not a
new isolation boundary protecting daemon memory from arbitrary ptrace/task-port
access. Existing owner/executor fences remain independently required.

The TCB is the macOS kernel/VFS/APFS/AMFI/dyld and approved system image/cache;
the trusted daemon and its dependency closure; the reviewed one-shot installer,
its trusted isolated interpreter/standard library; and **all privileged writers**
(administrator, MDM, backup restore, updater, security software, recovery tools).
The latter must obey the no-overwrite/no-delete/no-remount contract throughout
every admitted child lifetime. The Nix daemon is not the owner or updater of this
tree and gains no new trust or policy change. Ordinary trusted-root capability
is not the same as a policy proof: the administrator explicitly accepts this
contract. A hostile root can replace paths or mutate bytes; this design makes no
Linux-sealed-FD-equivalent claim against hostile privileged writers.

**Lifetime choice:** retain each published version indefinitely, including after
update, rollback, daemon crash, reboot, or logical uninstall. There is no online
GC and no root runtime helper. This is stronger than retaining until an `lsof`
snapshot looks empty: descriptors, mappings, descendants and daemon crashes do not
need a privileged global reference counter. Disk usage is the explicit cost.
Physical purge is a separately scoped offline maintenance operation, unsupported
by these assets. A requirement to reclaim versions online would require a new
reviewed supervisor/reference protocol; it cannot be added to this plan silently.

## Exact paths, pins and filesystem contract

Let `V` be the following literal directory name (not a symlink selector):

```text
codex-0.162.0-darwin-x64-fd4bb93679bfcc546765a3363a0df9a855f364b61ea6681009b28ba4c2e5b60d
```

| Path | Ownership/mode | Contract |
| --- | --- | --- |
| `/`, `/Library` | uid 0; no group/other write; observed identity/mount/ACL accepted explicitly | Every canonical ancestor inspected; no symlink substitution or user-controlled mount. APFS firmlinks are not automatically classified as Unix symlinks; record their resolved VFS/mount identities. |
| `/Library/HeimdallProtectedNative` | root:wheel `0755` | Dedicated namespace outside Nix and home directories; no ACLs; never recreate/repair silently. |
| `.../.admin.lock` | root:wheel `0600`, regular, single link | Permanent inode; nonblocking exclusive `flock` for every installer transaction; never unlink the lock. |
| `.../versions` | root:wheel `0755` | Only reviewed installer publishes new names; never overwrite existing names. |
| `.../versions/.stage-<random>` | root:wheel `0700` initially | Fresh root-only directory and fresh destination inode; failure retains unpublished stage. |
| `.../versions/V` | root:wheel `0555` | Atomic publication after validation; retained forever. |
| `.../versions/V/codex` | root:wheel `0555`, link count 1, flags 0 | Actual native image; no launcher, executable aliases, resource forks, copied xattrs, ACLs or writable links. |
| `.../versions/V/install.json` | root:wheel `0444` | Audit receipt only; contains disabled/unproven flags; never runtime authority. |

The proposed installer accepts no destination, version, digest, URL, mode, group,
manifest override or recursive extraction argument. The only input is a raw native
member. Copy bounded bytes to a new inode; do not `mv`, hardlink, clonefile, preserve
metadata, `chown` a user-created file, or copy a writable package directory into
place. An attacker-held descriptor to the input then refers to a different inode.
Hash the root-created result before publication and reject changes during copying.
No unprivileged process can open the root-created inode for writing before or after
publication. Root's write descriptor is closed before publication; no writable mmap
is created. Read-only mode bits alone would not revoke an old writer and are not
the basis of this argument.

Require local, root-mounted APFS with ownership enforced on **every** ancestor;
reject removable, union, noexec and ignore-ownership mounts, unknown mount policy,
symlinks, explicit ACL entries (including deny-only entries until reviewed),
non-directory ancestors, uid other than 0, or group/other writable ancestors.
For ancestors, only flags 0 or `SF_NOUNLINK` are proposed; image flags must be 0.
Do not set or clear system flags, alter ACLs on `/` or `/Library`, disable SIP,
change ownership semantics or remount anything to make a candidate pass. Reject
and return for scope review instead. `SF_NOUNLINK` is additional protection, not
byte sealing; its Apple definition covers remove/rename/mount-on operations.
The ABI/flag definitions come from [Apple XNU mount.h](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/sys/mount.h#L104)
and [stat.h](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/sys/stat.h#L462).
The proposal's Python ACL/statfs bindings still need native ABI/behavior tests.

The manifest [proposal.json](../../scripts/darwin-protected-native/proposal.json)
duplicates and is tested against
`tools/pty_host/fixtures/codex-darwin-x64-0.162.0.json`:

```text
archive: https://registry.npmjs.org/@openai/codex/-/codex-0.162.0-darwin-x64.tgz
integrity: sha512-4XzCUJgEDDdme6VWDEKvbWDA6f+470d4xhhorYUgNBZwY8Dq5NYqvWkO33rnc1vjxkqSj+SwkymHxRMxL6h1CA==
member: package/vendor/x86_64-apple-darwin/bin/codex
native SHA256: fd4bb93679bfcc546765a3363a0df9a855f364b61ea6681009b28ba4c2e5b60d
expected later version output: codex-cli 0.162.0
```

Private package preparation already checks archive SHA-512 before parsing and
extracts only the unique bounded regular member, never archive paths or scripts.
The proposed privileged stage only copies the raw image, verifies its exact digest,
and does not execute it. A source archive or raw file race may cause refusal; it
cannot select another accepted digest. No archive parser/network/npm hook runs
with privilege. A post-signing image would have a different pin and is not this
candidate.

## Installation assets and exact unexecuted commands

[install-protection.py](../../scripts/darwin-protected-native/install-protection.py)
contains the full proposed transaction in `proposed_install`: platform/root
checks, ancestor/ACL/mount checks, permanent lock validation, fresh root-only stage,
bounded no-follow copy and independent destination hash, no copied metadata,
protected audit receipt, close writers, atomic directory publication, directory
fsync. An existing version always refuses; partial failures remain unpublished or
published-but-disabled. A failed fsync after rename is uncertain durability, never
permission to overwrite/delete/retry that version. There is no enablement code.

Its main program has **no call to the privileged transaction**. `--apply` exits 78
before checking uid, input or filesystem. Neither a root caller nor an approval
JSON/env flag bypasses that guard. These assets are reviewable source, not a
privilege-boundary enforcement mechanism against someone who can edit root code.

Safe local review commands (no provider execution, no root):

```bash
python3 scripts/darwin-protected-native/install-protection.py --plan
python3 tests/test_darwin_protected_native_proposal.py
python3 tests/test_prepare_darwin_native_package.py
```

The exact proposed future privileged invocation is below. **It is not to be run
now and currently refuses.** A successor must first validate and review the native
transaction, name and pin its final script/interpreter/stdlib hashes in the
installation approval, and deliberately replace the CLI guard in that reviewed
revision. Do not execute root Python from a user-writable checkout or use a
user-controlled interpreter/import path. `/usr/bin/python3` must be present and
its actual executable/stdlib selected and verified as trusted system tools; if it
is an Xcode shim, absent or unsuitable, stop rather than install a runtime or
silently substitute Nix/Homebrew. Python 3.9+ is the proposed minimum.

```bash
# Proposed root-only tool directory, provisioned by the approving administrator
# from the exact reviewed revision, with independently verified script hashes:
# /Library/HeimdallProtectedNativeTools/install-protection.py
# root:wheel, directory 0700, file 0400, no ACL/symlink/writable ancestors.
# The bootstrap copy/provision is itself privileged scope requiring approval;
# this document intentionally supplies no curl|sudo or unchecked root copy.
/usr/bin/sudo /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/python3 -I /Library/HeimdallProtectedNativeTools/install-protection.py \
  --apply /Users/tanmay/.cache/heimdall-tests/mac-package-0162-20261107-1125/codex
```

This command names the existing evidence's raw input path, not a trusted installed
image. The independent root-created copy/hash is the admission prerequisite; the
input's uid is irrelevant. Interpreter/tool provisioning is an **unapproved,
unvalidated remaining step**, not a claim of ready-to-run installation. No existing
service, Nix setting, profile, global provider selection or startup item is touched.

## Update, drain, uninstall and rollback

[lifecycle.json](../../scripts/darwin-protected-native/lifecycle.json) is the exact
operation contract. It intentionally has **empty filesystem command arrays** for
uninstall and rollback: retained bytes need no destructive undo operation.

| Operation | Proposed transaction | Lifetime effect |
| --- | --- | --- |
| Install | Publish one new disabled immutable-by-contract version. | Retain forever; publication does not enable admission. |
| Update | Independently review new archive/native pins, loader evidence and version constant; same exclusive publication algorithm, new name. | Old and new images retained; no mutable `current` symlink or in-place replacement. Current assets cannot install any other pin. |
| Drain | Current backend is already disabled, so no action now. Future trusted daemon closes new native admissions under its registry mutex, invalidates pending native operations, and waits for owned child exits/PTY joins. If authorized cancellation is needed, use existing exact launch-key `ExecutorClose` path, not machine-wide kill. | Not proof that no unrelated process holds a mapping/FD; never permits deletion. |
| Logical uninstall | Disable the future native capability in a reviewed backend revision; drain owned sessions; retain every published file and lock. | Exact root deletion command set: empty. No launch daemon was installed to unload. |
| Rollback before publish | Keep root-only failed `.stage-*` for inspection. | Do not recurse/delete from an exception handler. |
| Rollback after publish | Keep new and old versions disabled. In the current backend there is no selector to undo. | No rename over a version, chmod repair, unlink, root cleanup or global profile change. |
| Rollback future enablement | Close admissions/drain, restore an independently approved retained version via a separately reviewed backend selection revision. | Existing children retain their originally admitted version; rollback is not hot substitution. |

The permanent admin lock serializes publication and survives crashes. Runtime does
not acquire it because administrative operations never mutate admitted versions
or their ancestors. An updater that cannot obey this is ineligible. A future
drain mutex closes the spawn/disable race at admission; it is not a new root
service. OS updates/security-policy changes require stopping new admissions and
requalification of the system-loader epoch before enabling again. Root recovery,
backup restore or package repair must never restore over retained versions while
children may exist. Offline purge requires independent disable/autostart fencing
and a cold-boot/maintenance proof; no command for it is authorized here.

## Loader: what is known, what is not, and the exact required contract

Recorded evidence `docs/evidence/darwin-guarded-image-engineering.json`,
`logs[label=native_closure]`, session `sh_c7ebea12514f04c217a2ca5a2a050618`,
reports the following direct dependencies, and `rpath_count 0`:

```text
/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit
/System/Library/Frameworks/LocalAuthentication.framework/Versions/A/LocalAuthentication
/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
/System/Library/Frameworks/SystemConfiguration.framework/Versions/A/SystemConfiguration
/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics
/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices
/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation
/usr/lib/libSystem.B.dylib
/usr/lib/libobjc.A.dylib
/System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork
/System/Library/Frameworks/Security.framework/Versions/A/Security
/usr/lib/libiconv.2.dylib
```

This is an `otool -L` report, not a complete load-command inventory, signature
entitlement report, cache-membership graph, or runtime plugin audit. Do not infer
absence of `LC_DYLD_ENVIRONMENT`, weak/reexport/upward/lazy dependencies, alternate
architectures, custom dylinker, or `dlopen` from it.

Apple's [dyld Loader.cpp, dyld-1330](https://github.com/apple-oss-distributions/dyld/blob/dyld-1330/dyld/Loader.cpp#L1260)
expands rpaths recursively from dependency images. Its
[DyldProcessConfig.cpp](https://github.com/apple-oss-distributions/dyld/blob/dyld-1330/dyld/DyldProcessConfig.cpp#L1887)
handles environment and embedded executable load-command overrides, including
library insertion. These sources explain why absolute direct names and zero main
image rpaths alone do not close resolution. They are design references, not proof
that this published dyld tag is byte-identical to the observed Darwin 25.6 build.

The future accepted loader policy must prove all of the following:

1. Parse every Mach-O slice and every load command without executing it; require
   the exact x86_64 image, normal `/usr/lib/dyld`, no embedded dyld environment,
   no unknown dependency command or private loader. Resolve all dependency kinds,
   including missing weak ones (whose appearance later must not change authority).
2. Resolve the complete initial graph against the actual qualified OS build/cache
   UUID and signed system content. Cache images may not have standalone files:
   enumerate membership/dependencies using tools that read the actual cache, and
   identify the cache/cryptex backing rather than assuming `/usr/lib` files exist.
   Apple's [dyld4 design](https://github.com/apple-oss-distributions/dyld/blob/main/doc/dyld4.md)
   describes precomputed dependency graphs and runtime loaders; it is not a
   security assertion that every process uses only the cache.
3. Reject private/user/Nix libraries, relative paths, unknown `@rpath`,
   `@loader_path`, `@executable_path` expansions, fallback search results and
   user-controlled overrides. Do not classify arbitrary `/System/...` strings as
   protected without verifying the mounted OS/cache origin and protection state.
4. Include deferred `dlopen`/CFBundle/framework plugins and provider-selected
   helpers, not only startup linkage. Inventory reachable provider call sites and
   system framework plugin policy; demonstrate no user-writable executable code
   can join the authoritative process. Runtime image logging is useful negative
   evidence, not proof of all future code paths. A cache-only claim needs an
   enforcement mechanism or complete source-backed reachable-loader proof.
5. Identify every native executable helper chosen by the provider (`rg`, shell,
   git, hooks, MCP/plugin commands, configured tools, updater/reexec paths).
   PATH pinning does not stop explicit executable paths or config-selected
   commands. Treat their results as untrusted tool data under existing authority
   fences; if one can replace/reexec the notification-authoritative image or
   mutate its transcript/authority assumptions, refuse that configuration until
   a specific proof exists. This proposal does not remove normal agent tools or
   claim all agent-executed code belongs to the admitted image's loader closure.

Apple's [signed system volume description](https://support.apple.com/en-ie/guide/security/secd698747c9/web)
documents runtime verification for system content. It does not establish that this
Intel Mac has the required protection state, that every candidate library resides
in that protected content, or that third-party binaries gain that protection.
Record actual SIP/authenticated-root/OS/cache identities without changing policy.
These target facts and the recursive/deferred graph are **missing evidence**.

### Launch environment contract (future implementation)

Both the version probe and real PTY exec must construct their final environment
with `env_clear`, then the same explicit allowlist. No inherited map and no
post-validation generic `extra_env` merge. Proposed exact keys:

| Keys | Source/validation |
| --- | --- |
| `PATH` | Literal `/usr/bin:/bin:/usr/sbin:/sbin`; extra pinned helper directories require separate closure review. |
| `HOME`, `USER`, `LOGNAME` | Actual passwd entry of the provider uid; no privileged child. |
| `CODEX_HOME` | Existing authorized per-instance canonical session root; retain current owner/profile checks. |
| `LANG`, `LC_CTYPE` | Literal `en_US.UTF-8`; verify target supports it; no locale-library override keys. |
| `TERM`, `COLORTERM` | Literals `xterm-256color`, `truecolor` for PTY; version probe has no terminal assumptions. |
| `TMPDIR` | Trusted per-instance private canonical directory mode `0700`; not an executable search root. |
| `HEIMDALL_AGENT_TOKEN`, `HEIMDALL_AGENT_INSTANCE_ID`, `HEIMDALL_BRIDGE_ENDPOINT` | Only the exact existing launch-bound values supplied by trusted Bridge code, never raw caller inheritance. Do not log their values. |

No other keys in this first policy. Reject unknown requested extras rather than
silently stripping required setup; any needed proxy/certificate/provider config
variable requires an explicit reviewed extension. Reject all `DYLD_*`, `LD_*`,
`__XPC_DYLD_*`, `LIBRARY_PATH`, language-runtime injection/search variables,
unapproved XPC/CF/Objective-C configuration and all duplicate/conflicting keys.
An allowlist also excludes unknown future override names. It does not replace
load-command, runtime plugin or helper validation.

Current `host.rs:27` inherits almost all daemon variables;
`host.rs:125` clears the builder but repopulates that inherited map, and
`host.rs:138` overlays arbitrary extras. Current Linux version probing also
inherits most environment. **Do not reuse those paths unchanged for Darwin.**
This task changes neither of them, preserving the reviewed Linux baseline.

## Exact source admission integration required in a successor

1. Keep `Candidate::inspect`/`revalidate` diagnostic-only. Replace the unconditional
   `lifetime_policy_unproven` refusal only after the chosen policy is implemented
   and reviewed, with a private `ProtectedDarwinImage` constructor owning the FD,
   exact path/dev/inode/hash and observed chain/mount/ACL/flags plus qualified
   loader/OS epoch. Never accept a manifest boolean or environment override as
   proof. The policy names the fixed version path, not any root-owned path.
2. Current `Identity` omits file flags and mount identity; add and recheck these,
   plus ACL and mount ownership policy. Walk/open the chain without following
   symlinks, verify held descriptors against names. Record VFS firmlink crossings.
   Verify root-only installer provenance under the explicit TCB contract. Metadata
   alone cannot prove that an old inode never had an attacker-held writer.
3. Under the trusted daemon admission mutex, check disabled/epoch state and acquire
   an owned admission object before any `--version` child or PTY creation. Construct
   the final environment, check loader policy, rehash/revalidate, run a bounded
   version probe against the protected literal path, reap it, then revalidate
   again before PTY exec. Retain the object until child wait/PTY cleanup joins.
   No mutable alias, shell wrapper or `/dev/fd` workaround. Revalidation detects
   violations; the trusted root append-only contract prevents the residual
   pathname race between final check and exec.
4. Route Darwin profile spawns through `PtyHost::spawn_darwin_candidate` (currently
   guarded before `openpty`) or its typed replacement. Extend `NativeProfile`
   executable storage/path selection explicitly; its current fd path is Linux
   `/proc/<pid>/fd/N`, not a Darwin implementation. Route version and PTY through
   the same accepted object/environment. In `daemon.rs:603`, preserve a distinction
   between ordinary children and requested-but-refused native capability; do not
   turn `.ok().flatten()` into a fallback that labels an ordinary child native.
5. `native_notification.rs:83-88` must continue returning no Darwin profile until
   all gates pass. Any eventual enablement requires a separate reviewed commit
   and explicit user authorization. Keep child/session/owner binding, revocation,
   encrypted original-owner result checks and all existing profile fences.

## Concrete alternative and recommendation

If a source-backed loader graph cannot exclude user-writable plugin/library
injection for these exact vendor bytes, a concrete alternative is a separately
packaged, Developer-ID-signed hardened executable, without disable-library-
validation/dyld-environment/debugging exceptions, with OS-enforced library
constraints narrowed to qualified platform code. Apple's
[library validation documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
states the default permits Apple code or the same Team ID; that is **broader than
an exact hash allowlist**. A strict alternative must additionally constrain the
permitted code origin/identity, using the documented
[library constraints](https://developer.apple.com/documentation/security/defining-launch-environment-and-library-constraints),
and native-test actual denial of user-controlled libraries. Do not equate Team ID
with immutable bytes or assume ad-hoc signing provides a Developer ID.

Concretely, build/sign a separate artifact in a trusted release environment using
an explicitly approved signing identity, pin the resulting complete native bytes
and constraints, publish it via the same fresh-inode/retention installer, and test
both version and PTY execution. No signing key or account is supplied/used here;
no exact signed pin exists yet. This adds signing/release machinery and changes
the current vendor digest, so it is a distinct scope/approval decision. It offers
an enforcement route for deferred loading, whereas plain root ownership does
not. If it cannot preserve required provider behavior, keep Darwin unsupported.

**Recommendation now:** accept the append-only lifetime design for further
engineering review; retain disabled production; do not recommend installation or
enablement until loader and native transaction evidence exists. The outstanding
invariant is precise: no user-writable executable code may enter or substitute
the notification-authoritative process from first version exec through final
child cleanup. Existing direct load evidence does not establish it.

## Review, approval and verification gates

Named independent reviewer: durable reviewer agent `agt_18e5281575868be4` assigned
to this task; coordinator `inst_18e554c99e0743ee` routes the result. The user
**Tanmay** must explicitly approve the exact privileged target bridge
`brg_18e30f3f36df903e`, final reviewed commit/tool hashes, image/loader pins,
paths/modes/retention/TCB, tool provisioning and protection-only install scope.
Plan approval is not installation approval. Installer approval is not permission
to change SIP/Nix/system policy or enable a backend. A subsequent separately named
backend-enable approval must include the tested source revision and provider
scope. Preserve task review gates and record explicit verdicts; silence and
answer selections grant none of these permissions.

Before recommending any executable privileged scope, independently validate on a
disposable Mac namespace with the approved native test scope: ACL/statfs ABI and
no-ACL behavior, preheld input writer, source replacement/FIFO/link/size races,
fresh destination identity, exact modes/flags and empty ACLs, hardlink refusal at
admission, concurrent installer lock, existing-version refusal, crashes before
and after rename, directory durability, and retained versions across
update/drain/rollback/uninstall/restart. Never mutate the existing live Nix image.
Then prove actual loader closure/enforcement, hostile env and extra-env rejection,
forged manifest refusal, OS-epoch invalidation, and actual Mach-O A/B path/in-place
mutation controls through **both** version and PTY admission. Verify exact
argv/Unicode/cwd/environment, controlling terminal, descriptor whitelist,
resize/signal/exit and bounded cleanup.

After backend safety, the full M3b gates remain: real pinned Codex notification
hook/current-child binding, exact Unicode/LF/TAB and typed interruption,
signed/encrypted original-owner acceptance, stale/revoked/duplicate/partial cases,
cleanup, Claude's exact-TAB interactive PTY requirement, explicit unsupported
Windows behavior, and all retained provider/owner requirements. No alternate
transport, text normalization, live auth or global profile changes are approved.

Offline validation for this deliverable exercises only proposal pin consistency,
CLI refusal, private disposable copy independence, hostile input rejection and
non-destructive lifecycle declarations. It cannot validate Darwin ACL/APFS ABI,
system protection state, loader behavior or a real privileged installation.
No broad Rust suite is needed for documentation/assets-only changes; existing
production Rust source is untouched.

### Recorded offline results

On riverwood, 2026-11-07, session
`sh_35a7a89cdbd3ab5ab6b533a3dcc82e75` ran:

```bash
python3 tests/test_darwin_protected_native_proposal.py
python3 tests/test_prepare_darwin_native_package.py
git diff --cached --check
git diff --exit-code df0b952742c622ecdf2d1ace16faa54606489cfe -- tools/pty_host/src
```

Results: **5 proposal tests passed; 3 package preparation tests passed; staged
whitespace check and unchanged-production-source check exited 0**. The proposal
test's `REFUSED` diagnostic is expected evidence of the unconditional apply guard.
`--plan` separately exited 0 and reported `apply_available:false`,
`closure_proven:false`, `enabled:false`. AST syntax parsing passed for both Python
files. No privileged transaction, Darwin-native checks, provider execution,
connectivity probes, broad Rust suites, live authorization or system changes ran.
