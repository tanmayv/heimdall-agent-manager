# Native profile mitigation audit through `890f87eb`

Independent evidence audit for `task_18e5b8748bbe4cb8`, requirements revision 4,
2026-11-07. **F2–F6 are closed within the audited Linux transport boundary;
F1's lazy-file defect is corrected, but production startup binding remains unproven.
This is not full M3b acceptance.** No production implementation was edited.

## Exact scope and ancestry

Verified consecutive parents, inspected committed diffs, and used detached checkouts:

1. Basis `7f13c94e580693fe6f3482fa3a4c3b699494a56b`.
2. Original mitigation `96697a86fc9c1db7e529707c09631c31546c4dd3`
   (nine files, 386 insertions / 43 deletions).
3. Immutable-image correction `2bcae028d0b26755dd69e7120a26d7834ac94cbf`
   (two files, 84 / 7).
4. Malformed-observer correction `4a1813d97da465af9d49619b3bef064771c07c64`
   (two files, 25 / 0).
5. Final route correction `890f87eb50fc51da5a178e44a2367dc1098afdfc`
   (four files, 119 / 11).

The engineer's mutable checkout was not used. Prior audit:
`docs/native-interrupt-profile-audit-9e6b89af.md` at `fdbb6739`.
Reproduction sources and exact experiment distinctions:
[public-API probes](artifact://art_18e5b91f7fb8e3f2).
Its “final pin” denotes the immutable-image probe's `4a1813d9`;
`890f87eb` changes no Rust implementation.

## Findings and closure

| Finding | At original `96697a86` | At final `890f87eb` |
|---|---|---|
| F1: startup file timing / bypassed proof | Lazy immutable observation fixes premature file read; real production hook still missing | Timing correction verified; **production-proof gap OPEN** |
| F2: lifecycle leaves old binding usable | clear/resume/unknown source poison correctly; malformed startup can leave old binding usable | **Closed in inspected observer/routes**, after two further corrections; connected positive production proof remains separate |
| F3: executable trust / TOCTOU | Trusted SHA allowlist and path-swap protection added, but same-inode overwrite still executes unverified bytes | **Closed for admitted Linux image** by sealed snapshot before hashing and execution; Darwin remains unsupported/open |
| F4: state version mismatch | Exact `0.162.0` required | **Closed**; public probe rejects `0.167.0`, accepts `0.162.0` |
| F5: parallel fixture collisions | Atomic suffix adds process-local uniqueness | **Closed**; independent default-parallel full suite passes |
| F6: repoll after acknowledged partial paste | Per-delivery ACK guard skips further polls | **Closed by source and regression evidence**; identity, lifecycle and paste-mode guards still precede writes |

### F1 / F2: observation, invalidation and authority

Final `native_notification.rs:135–157` records the exact startup session/path
without opening the file, retries validation through `ensure_bound`, and
irreversibly rejects non-startup, malformed or replacement observations.
The public probe observes a nonexistent file, rejects mismatched producer version,
then binds once matching metadata appears.

At `96697a86`, the public probe demonstrated that
`observe("other", "", "startup")` returned an error while `bound()` and
`begin()` remained usable (`sh_cc77d271153cb5f238f37f96ee5cb095`, exit 0).
`4a1813d9` fixes that observer ordering, verified by the public probe and its
new four-case unit regression. However, that pin's Bridge still discarded empty
session/path before IPC (`pty_notification.odin:112,125–126`), preserving the old
binding in production routes.

`890f87eb` removes those local filters. Its shared helper separately validates
instance/PID/key/epoch/count and converts malformed native fields into a bounded
invalid lifecycle observation. Empty startup paths reach the Rust poison check.
The remote caller retains bootstrap signature, executor identity, exact launch
PID and current bootstrap checks (`executor_child.odin:150–180`);
daemon token/PID/epoch/count/live-child checks remain at `daemon.rs:1082–1094`.
The independently run route test captures eight local/shared-helper observation
frames, preserves authority fields, and refuses bad authority without IPC.
This is composed route/observer evidence, not a complete remote/native launch.

### F3: preserve the failed inode-only mitigation

At `96697a86`, the public API admitted a disposable copy of vendor SHA256
`50ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38`.
After its version child exited, overwriting that **same inode** with
`/usr/bin/false` made parent-procfd execution run `false` while the profile
still claimed the vendor digest. Confirmed in `sh_73fb3f274b78aae0ee5c513963231208`
and `sh_cc77d271153cb5f238f37f96ee5cb095`, exit 0.
The initial immediate overwrite encountered transient `ETXTBSY`
(`sh_eee673e0ed1ec0c9cda9d79cb718068e`, exit 101);
a bounded 10 ms retry after process teardown reproduced the defect.

`2bcae028` changes admission to a bounded private memfd snapshot
(`native_notification.rs:47–66,84–120`). WRITE/GROW/SHRINK/SEAL are added and
verified **before** digest comparison and version execution. The same owned
descriptor supplies eventual PTY execution (`daemon.rs:601–604`).
No admitted capability is created on snapshot/seal/hash/version failure.
An ordinary unprofiled child may still launch; it cannot gain interrupt capability.

The final public-API experiment overwrites the original inode, then verifies:
both descriptor `--version` and actual `PtyHost::spawn` still execute
`codex-cli 0.162.0` with exit 0; all four seals equal 15; reopened writes,
truncate/grow and seal changes fail; child exits and PTY releases.
FD counts return to baseline after profile drop, unknown image, short header
and post-version invalid-cwd failure. Source ownership via immediate
`File::from_raw_fd` also covers copy/seal errors; syscall failures were not
fault-injected. Full experiment `sh_489ba0b5df65fb775ce27d9580981159`, exit 0.
An initial writable-alias attempt hit transient `ETXTBSY`
(`sh_90818e36bdb9aa133e3b1d5e4f1b43ac`, exit 101);
the passing probe uses bounded retry.

### F5 / F6 and resize regression

Atomic fixture suffixes prevent same-process same-millisecond collisions.
The resize test now waits up to three seconds for **both 40 rows and 120 columns**
before disconnect; this checks the actual queued Resize effect and strengthens
the old row-only assertion, rather than weakening production behavior.

`daemon.rs:1055–1070` queries the exact saved receipt/ticket first, returns
completed/recovery receipts without writing, checks lifecycle usability, and only
polls when that delivery has not already acknowledged native interruption.
`host.rs:278–304` still checks DEC2004 and paste generation; delivery byte
offsets and delimiter recovery are unchanged. The passing suite includes native
ACK/time, partial-boundary/lost-reply, stale-child/deadline, paste-mode and
fresh-same-turn/rotation tests. There is no dedicated daemon test forcing an
ACKed partial body past eight seconds; closure of that branch additionally rests
on direct source inspection, not a claimed end-to-end regression.

## Independent checks and evidence limits

All checks ran through managed shell sessions.

```bash
# In detached 96697a86, then detached 4a1813d9:
nix develop --command env HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_PTY_REQUIRED=1 CARGO_TARGET_DIR=/home/tanmay/.cache/heimdall-tests/audit-96697a86-target cargo test --locked --manifest-path tools/pty_host/Cargo.toml

# In detached 890f87eb:
nix develop --command odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.pty_notification_malformed_lifecycle_reaches_daemon_after_current_child_fences -out:/tmp/audit-890f87eb-route-test124
```

| Independent check | Result |
|---|---|
| Original full parallel Rust, required PTY | 214 unit + 2 safety PASS, 2 subprocess-only ignores; `sh_35b7fc0b53ce65ee1a15e5b0ae9581de`, exit 0 |
| Final Rust implementation at `4a1813d9` | 215 unit + 2 safety PASS, same 2 ignores; `sh_9295ba58b2591cde3bdd917a02f84362`, exit 0 |
| Final Bridge route regression | 1 PASS / eight observation IPCs; `sh_63c46f407fc520e5f1674c89b4ba1bca`, exit 0 |
| Public image/lazy/version/poison/cleanup probes | Original attack reproduces; corrected image/observer pass; sessions above |

The first Odin invocation misspelled the test selector and ran **zero tests**
(`sh_8ce67a0f75b0b3d3df1f394c18d9041e`, exit 0); it is not pass evidence.
The corrected invocation explicitly reports one successful test.

Worker evidence inspected separately: sealed full Rust rerun `214+2`
(`sh_ef70ece7b3d0fbc55281e500b420bb41`), following a real stale-socket assertion
failure `213 pass / 1 fail` in `sh_4082b62d7873824add95c41c4d7082f7`;
focused rerun passed. The failure is preserved, not erased by the rerun.
Worker real sealed-image probe `sh_b9bd1111843f4c304e6667c5bc71cd6d` reports
130-byte literal and 102-byte interrupt submissions once, replay without duplication,
one typed abort, CLI/state `0.162.0`, **native_hook=false**.
Worker inline native callback probe later passes, but its script sends daemon
`0x42` directly; it does not exercise the production Bridge observer.
Full cumulative Bridge/package/release checks after the final route change were
pending when scoped; they are not inferred from earlier 1043-test/build evidence.

## Gates and limits that remain open

- **Production startup:** real installed extension → authenticated local/remote
  Bridge observer → lazy native bind remains unproven. Earlier absent-callback
  and saved-folder-trust failures remain historical evidence despite the later
  disposable inline-hook mechanics pass.
- **Connected ownership:** original owner hold producer → encrypted executor →
  exact native child → signed result and owner replay/acceptance remains unproven.
- **Darwin:** hardened capability explicitly refuses non-Linux pending a safe
  immutable execution backend. Historical `7f13c94e` Mac passes do not accept
  the hardened pin. No platform waiver.
- Windows build/ConPTY/refusal evidence is separate; it does not establish native
  notification support. Claude TAB/onboarding and idle-interrupt limits remain.
- **L1:** same-UID writable rollout state is transport evidence, never task authority.
  **L2:** reads/hashes up to 8 MiB still occur under the daemon agents lock;
  snapshot copying/hashing and version probing also add synchronous spawn cost.

Report delivery to M3b and named reviewer is recorded in the audit task handoff.
No live restart, deployment, push, platform waiver or full M3b verdict is implied.
