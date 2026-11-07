# Live Mac native prerequisites and conditional backend proposal

2026-11-07, M3b task `task_18e5ac3dc3e13d1e`, attempt3. The Mac connectivity prerequisite is now resolved: managed encrypted commands ran on enrolled bridge `brg_18e30f3f36df903e`. No hardened Darwin backend or provider pass is established. The available Codex is 0.146.0, not the required, previously tested 0.162.0; its public launcher is a compiled wrapper. No package was installed, version enabled, provider session started, auth/token/config changed or live service restarted.

## Observed target and executable

The selected raw log excerpts are preserved in `docs/evidence/macos-live-native-prerequisites.json` and [the evidence artifact](artifact://art_18e5bda3529a466a); full session logs remain authoritative.

| Observation | Actual evidence |
| --- | --- |
| Access/kernel/toolchain | `sh_30e7db523fdf91493757ebbc4cd8cb46`: Darwin25.6.0 x86_64; Apple clang21.0.0, clang-2100.1.1.101; Xcode SDK available. |
| Documented SDK declarations | `sh_2d14f95ac7e233c21b5102d392571c9f`: syntax-only `<unistd.h>`/`<spawn.h>` checks reject undeclared `fexecve` and `execveat`; `posix_spawn_file_actions_addinherit_np` compiles. `fexecve` manual absent. This proves those declaration checks, not the absence of every possible kernel/private API. |
| Previously tested installation | Historical private0.162.0 path from `ca87631a:docs/pty-macos-native-profile-evidence.md` is absent. Bounded usual launcher paths and known fixture/store patterns find no0.162.0 candidate (`sh_2d14f95ac7e233c21b5102d392571c9f`, `sh_f88494a6b9d5cd24e850c508c7c65202`). This is not a whole-disk search. |
| Existing candidate | `/run/current-system/sw/bin/codex` resolves to `/nix/store/0yd2iwrahi7bg2rv2sanmfhpg0dk7vcg-codex-0.146.0/bin/codex`; `--version` reports `codex-cli 0.146.0` (`sh_76fa9465e697974bcaa443ab63ce07ab`). |
| Public launcher versus actual image | The13248-byte Mach-O launcher references `bin/.codex-wrapped` and a ripgrep store path. Launcher SHA256:`8aeff09a5164b383a14be7f9652f9d4713511b08e9fb4e982f0891b1a31d2ec5`; underlying381827576-byte Mach-O SHA256:`c92993a099decee6b728f52209705bcabb8a1db93e0e7102bc1d8985aec0f607` (`sh_e6c1fdc7a2e5bca09eecf0189f8e8e10`, `sh_1eae50bf473a461a00dfd14e069c2b20`). A launcher digest is not its child's digest. |
| Direct filesystem protections | Launcher, underlying image and package ancestors are root:nixbld0555; `/nix/store` is root:nixbld1775, `/nix` root:wheel0755, root has `sunlnk`. `ls -ldeO` records no printed ACL entries on this canonical chain. Caller uid501 is not in nixbld gid350, and access checks report no write permission. `/nix` is an APFS local/nosuid mount, not a read-only mount (`sh_2d14f95ac7e233c21b5102d392571c9f`, `sh_76fa9465e697974bcaa443ab63ce07ab`). |
| Existing open image | Exact-file `lsof` sees pre-existing native PID11412 uid501 with a text-image mapping, no writer record in this snapshot (`sh_1eae50bf473a461a00dfd14e069c2b20`). It is not a probe child; it was not signalled or interacted with. A snapshot cannot exclude a future privileged updater or previously established writer outside its visibility. |
| Nix trust snapshots | Client-selected values:trusted-users=`root`, allowed-users=`*`, require-sigs=true, sandbox=false, build-users-group empty. `/etc/nix/nix.conf` includes the root-store-backed `nix.custom.conf`, whose selected relevant line is sandbox=false. Existing daemon PID364 uid0; known launch plist uses `/bin/sh` (`sh_9bdbc4da55784d2ede2560ae3d643301`). Client configuration is not proof of the daemon's complete effective policy or updater behavior. |
| Root/liveness snapshot | Query reports existing system-5/system-4 and `/run/current-system` roots; inspected current-system/system/gcroots entries are root-owned (`sh_4c1de603bece9a2326f9aabddff6dfb4`). A caller-removable private GC root would be weaker; no new root was created. |

The source still explicitly refuses non-Linux native-profile admission (`tools/pty_host/src/native_notification.rs:68`, `:81`) and admits only exact0.162.0 Linux release bytes (`:97`, `:120`). Neither the0.146.0 version result nor existing root ownership may override these fences.

## Observed query housekeeping and investigation limits

`nix-store --query --roots` unexpectedly emitted automatic maintenance: `removing stale temporary roots file '/nix/var/nix/temproots/9390'`. This side effect is retained in the evidence; no build, installation, garbage collection or repair was requested. Further Nix metadata queries stopped. Do not describe the whole session as zero-write merely because the requested operation was a query.

No scratch binary, provider turn, PTY daemon, root installation or system protection was created. Clang ran syntax-only checks through stdin. Existing Nix/Codex services and PID11412 were left running. A diagnostic accidentally printed part of the compiled launcher as a decoded first line; the evidence extraction omits that noisy line and lengthy Nix option descriptions while preserving the raw log IDs and selected configuration values. No authority/native transcript evidence is transformed.

This assessment does **not** establish current daemon policy, safe concurrent update/delete/rebuild semantics, exact image immutability through activation, an eligible0.162.0 installation, or a real native notification pass.

## Conditional proposal for coordinator scoping; no implementation approval

The reviewed source investigation `e624fc84:docs/macos-pinned-executable-investigation.md:43` explains why simply inheriting an FD through `portable-pty` or using `/dev/fd/N` is not a proven image backend. The present SDK declaration checks do not resolve that obstacle. Continue refusing those speculative paths.

The narrow candidate to assess is **a protected canonical native0.162.0 image under the existing privileged store trust model**, with its actual bytes and full closure identified independently of a launcher. This needs explicit scope before any new package/installation or version enablement:

1. Supply a reproducible, source/digest-pinned Mac native0.162.0 package proposal and identify the actual image, closure and supported session format. A user-owned cache copy, the present0.146.0 image and a wrapper-only hash are ineligible. No global profile or system change is proposed as an implicit dependency install.
2. Establish the daemon's effective policy, build-user isolation, trusted-user permissions, persistent trusted GC roots and allowed updater/repair/delete/import behavior. Explain why a compromised uid501 child cannot replace or recreate the admitted image/path between hashing and activation. Current mode bits, a root-owned pathname, code-signing publisher identity and a client config snapshot are insufficient individually.
3. Design Darwin admission that checks the concrete approved trust model, all canonical ancestors/ACLs/symlinks/mount policy, held image identity/metadata and exact digest before both version and PTY exec. Reject user-writable paths, ambiguous wrappers and changed protection; retain no fallback. Any assumption about privileged updaters must be explicit and reviewed rather than silently treating the whole store as immutable.
4. After approval, use disposable Mach-O A/B controls for pathname replacement and an in-place writer established before admission. An admissible backend executes the originally admitted bytes or refuses; rename-only success is insufficient. Repeat through the real PTY backend with exact argv/Unicode/cwd/environment/controlling terminal, descriptor whitelist, resize/signal/exit and bounded cleanup proof. Do not mutate the existing live0.146.0 package to test this.
5. Only after backend safety passes, prove the real0.162.0 provider hook/current-child binding, exact Unicode/LF/TAB, typed interruption, signed original-owner encrypted notification/result acceptance, stale/revoked/duplicate/partial behavior and cleanup. Preserve Linux behavior and the fixed owner/executor authority model. Named independent review is required.

If that protected-install proof cannot be established without changing privileged installation/protection, stop at a concrete new scope decision. The Mac being online resolves access only. Claude's retained exact-TAB interactive PTY requirement also remains open; no alternate transport or normalization is authorized. Full M3b is still incomplete.

Final coordinator direction at10:50 UTC: preserve this assessment on M3b; no package/backend implementation or system/version change is authorized by the inspection. Independent Linux idle audit is separately done/named-approved/merged at `873aa65c`; that does not accept a Mac backend. The next Mac work requires a concrete scoped vendor/backend proposal and the safety gates above, not another connectivity or read-only-inspection permission request. The unrelated auth fix is deferred by the user to later Bridge work and is outside this task.
