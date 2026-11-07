# Darwin guarded image engineering evidence

The scoped engineering task `task_18e5bee6624fa541` delivers concrete Darwin image inspection, fail-closed activation, pinned private package preparation, and actual native Mach-O mutation/PTY tests. It does **not** deliver an admitted Darwin provider backend: production Darwin profiles remain disabled. Independent review is required; full M3b acceptance remains a successor gate.

## Source and requirements

The isolated task branch carries the exact intended predecessor delta from `ecb30481..4afd3a09` in commit `d4b73182`, preserving the predecessor checkout and unrelated starting documentation. Implementation is commit `faab1ee8`. Selected native logs, exact eight-file SHA-256 values, environment and outcomes are in [engineering evidence](artifact://art_18e5c076f93e4ef2), also committed as `docs/evidence/darwin-guarded-image-engineering.json`.

| Requirement | Delivered evidence | Limit |
|---|---|---|
| REQ-MAC-E1 | Actual Mach-O digest/identity inspection, ancestor checks, ACL/APFS checks, guarded activation; pinned private 0.162 package preparation | No lifetime policy proof; activation always refuses |
| REQ-MAC-E2 | Actual native pathname replacement and preheld writer mutation refusal, actual PTY control and cleanup | Refusal evidence, not an admitted provider pass |
| REQ-MAC-E3 | Linux regression checks pass; Darwin profile stays off; private-only work | Full provider/owner/Claude/Windows successor gates retained |

At implementation commit, `tools/pty_host/src/darwin_image.rs:106` opens a bounded regular Mach-O image without following its final symlink and verifies its digest. `darwin_image.rs:57` rejects noncanonical/symlink ancestors; `darwin_image.rs:155` rechecks path/descriptor identities, content and ancestors. `darwin_image.rs:174` requires root ownership, no writable file bits, executable mode, single link and protected ancestors. Darwin ACL checks at `darwin_image.rs:200` reject every explicit entry; filesystem checks at `darwin_image.rs:239` require local APFS. Even after those checks, `darwin_image.rs:190` refuses with `lifetime_policy_unproven`.

The guarded entry point at `tools/pty_host/src/host.rs:103` checks program identity and authorizes before creating a PTY. It has no fallback to ordinary spawn. The production profile branch at `tools/pty_host/src/native_notification.rs:83` performs inspection diagnostics and unconditionally returns no Darwin profile at line 88. The existing Linux hash/version and sealed-image path remains unchanged by the new implementation delta. No wire contract changed.

## Private pinned package

`tools/pty_host/fixtures/codex-darwin-x64-0.162.0.json` and `tests/prepare_darwin_native_package.py` pin the actual platform package `@openai/codex@0.162.0-darwin-x64`. The archive SHA-512 is checked before archive parsing; only the unique regular native member is extracted, with bounded sizes and exact native SHA-256:

```text
fd4bb93679bfcc546765a3363a0df9a855f364b61ea6681009b28ba4c2e5b60d
```

The script permits only a new direct child of the current user's `~/.cache/heimdall-tests`, refuses existing/global destinations, and neither invokes npm lifecycle scripts nor executes the image. Actual preparation succeeded on both Linux and Mac. Mac staging is `/Users/tanmay/.cache/heimdall-tests/mac-package-0162-20261107-1125/codex`, owned by uid 501, with manifest `executed:false` and `production_admissible:false`. This is user-owned staging, not a protected installation.

## Verification

| Check | Result |
|---|---|
| Python package preparation tests | 3 passed |
| Final Linux full PTY Rust suite | 218 unit + 2 safety integration passed; 2 existing subprocess ignores |
| Final Linux focused image suite | 3 passed |
| Native Mac focused image suite | 4 passed, including real absent/explicit ACL distinction |
| Native Mac integration suite | 2 passed, no skips: Mach-O mutation/PTY control and actual pinned staged image refusal |
| Nix ham-pty-host package build | Passed |
| Earlier broad Mac suite | 215 passed, 3 failed, 2 ignored; **not a full Mac pass** |

Exact Linux commands, from the task checkout:

```bash
python3 tests/test_prepare_darwin_native_package.py
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_PTY_REQUIRED=1 CARGO_TARGET_DIR=$HOME/.cache/heimdall-tests/mac-guard-linux-20261107 cargo test --locked --manifest-path tools/pty_host/Cargo.toml -- --test-threads=1
nix develop --command env CARGO_TARGET_DIR=$HOME/.cache/heimdall-tests/mac-guard-linux-20261107 cargo test --locked --manifest-path tools/pty_host/Cargo.toml --lib darwin_image -- --test-threads=1
nix build .#ham-pty-host -o $HOME/.cache/heimdall-tests/mac-guard-pty-package-20261107-1134
```

Native source is retained at `/Users/tanmay/.cache/heimdall-tests/mac-guard-20261107-1121/source`. The final native session `sh_bcb3fcc4eeb52dc2eb7c137f60b5f255` verifies all eight source hashes against the committed implementation. It uses existing store Rust 1.95 tools, private CARGO_HOME/target, PATH `/usr/bin:/bin:/usr/sbin:/sbin`, and removes inherited HEIMDALL variables before explicitly requiring PTY and staged package tests. The evidence JSON records exact paths/environment.

```bash
cargo test --locked --offline --manifest-path tools/pty_host/Cargo.toml --lib darwin_image -- --nocapture --test-threads=1
cargo test --locked --offline --manifest-path tools/pty_host/Cargo.toml --test darwin_image_safety -- --nocapture --test-threads=1
```

`tools/pty_host/tests/darwin_image_safety.rs:55` builds disposable actual Mach-O A/B programs. Replacing A's pathname with B causes candidate revalidation and guarded spawn refusal. An ordinary PTY control executes B and verifies spaced/Unicode argv, cwd, nonsecret environment, TTY status on all three streams, foreground process group, and 24x80 dimensions. A writer opened before inspection then modifies the held inode; revalidation and guarded spawn refuse. The staged vendor test at line 142 verifies the exact vendor digest and refuses activation without executing vendor bytes.

The earlier broad native run failed on two existing platform assumptions: `daemon.rs:4170` uses unavailable /proc in a nested child, and `daemon.rs:2491` expects DEC2004 support absent from the Mac system Bash. Its third failure was the new ACL fixture passing numeric uid 501 to chmod, which cannot resolve that value as a UUID. The fixture now uses the actual username and RAII cleanup; final focused native checks pass. An initial compile-time f_flags integer mismatch was corrected. An initially guessed npm package endpoint returned 404; the platform alias was resolved to its actual package. These failures remain in the selected evidence; no broad Mac success is claimed.

## Cleanup and remaining gate

Native cleanup session `sh_b05742f78941a4a10a584241e721a639` removed only two identified dead-test fake-image fixtures from the earlier failed ACL tests. Final tests remove their own disposable Mach-O images and reap their children. The owned-process scan was empty; existing Codex PID 11412 remained untouched. Private source/build caches and the unexecuted staged package remain for review. No live services, system packages, Nix policy, auth/trust settings or user processes were modified. The prohibited roots query was not repeated.

Static inspection reports 13 direct OS dependencies and no LC_RPATH. That does not establish transitive closure, dynamic-loader environment safety or immutable lifetime. A future eligible backend needs a concrete protected-image trust model covering effective daemon/updater permissions, deletion and GC policy, non-user-removable lifetime roots, ancestor ACL/mount protections, and the complete executable/loader closure through activation. Root ownership alone is insufficient.

The guarded substrate deliberately has no accepted proof constructor, environment override or manifest bypass. Full native provider/owner gates, Claude exact TAB PTY behavior, explicit Windows unsupported handling, and later M3c/M4 gates remain open. No provider run was attempted against inadmissible staged bytes. No new owner/Bridge/TypeScript tests were run for the eight-file Rust/Python-only implementation delta; the exact predecessor carry retains its prior evidence. Confidence is high for this scoped refusal/preparation substrate, not for an admitted Mac backend.

