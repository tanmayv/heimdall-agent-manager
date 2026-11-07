# macOS native profile evidence: 9e6b89af and 7f13c94e

Evidence version 1, collected 2026-11-07 for `task_18e5b7218741d031`,
requirements revision 2, and M3b `task_18e5ac3dc3e13d1e`. Final pinned native
macOS checks pass 20 selected unit tests and 2 integration tests, and a disposable
Codex session accepts exact literal input and a daemon interrupting notification
once each across lost-reply replay. These are historical isolated observations,
not production support or full M3b acceptance. Independent audit F1–F6 remains
open, including executable trust and the unproven production SessionStart path.

## Source and native inventory

The approved [f6a8f209 baseline](pty-macos-evidence-f6a8f209.md) and its
24-session evidence remain unchanged at commit `c2425cf21241063db12794c77c5343d2e0314315`.
Baseline report: artifact://art_18e5b673cd5ba573; logs: artifact://art_18e5b673f96394e2.

| Snapshot | Artifact | Bytes | SHA256 |
| --- | --- | ---: | --- |
| `9e6b89af35783b76ff908406972db54ecdd3964b` | `art_18e5b70ab432aca5` | 233207 | `ed9ce0c8d4b13353af6013a335ed4496c4e6a17c8e2ee225fb240f88a4e1ca88` |
| `7f13c94e580693fe6f3482fa3a4c3b699494a56b` | `art_18e5b767aed52fce` | 233208 | `ed698840070f747c34822cbca1c236e13d7e0db752f425738770f6f7ff3da724` |

Both archives were downloaded through artifact tooling and verified on Linux and
again on the native Mac after source-only chunk transfer. Prefix is
`m3b-native-profile/`. The portable archive contains no Git metadata: the hash
attests the coordinator-pinned snapshot, not a native Git checkout. Scripts and
the native parser were inspected before execution. Extracted archive comparison
shows exactly one test-only change: `tests::root()` returns `fs::canonicalize(p)`
after directory creation. Production Rust and observation harness bytes are
identical. Other full-repository codec/docs deltas are assessed in the independent
audit, not silently included in this portable archive.

All native execution used enrolled Mac Bridge `brg_18e30f3f36df903e`, from the
existing Linux orchestration worker. No Mac LLM agent/model was started or changed.

| Item | Observed native value |
| --- | --- |
| OS / architecture | Darwin 25.6.0 x86_64; macOS 26.7.2 build 25G330 |
| Rust / Cargo | rustc 1.95.0 (59807616e); Cargo 1.95.0 (f2d3ce0bd) |
| Readline fixture | GNU Bash 5.3.9 from pinned Darwin Nix package set |
| Python | Existing `/usr/bin/python3`, 3.9.6 |
| Node / npm | 24.22.1 / 11.19.1 |
| Actual native Codex | `codex-cli 0.162.0`, Mach-O x86_64 |
| Codex native producer | `session_meta.cli_version=0.162.0` in both exact fixture sessions |
| Existing configured model | `gpt-5.6-sol`; no profile/provider override |
| Native executable SHA256 | `fd4bb93679bfcc546765a3363a0df9a855f364b61ea6681009b28ba4c2e5b60d` |

Existing Nix at `/nix/var/nix/profiles/default/bin/nix` was reused with
`github:NixOS/nixpkgs/57f1c8965649ce5bcac5118a0d2e41f1fbdc56e5`.
Previously authorized isolated dependencies were recreated under private task
scratch, including `npm install --ignore-scripts --no-audit --no-fund
@openai/codex@0.162.0` with private prefix/cache. The actual Mach-O vendor
directory preceded PATH; the npm JavaScript launcher is not admitted as a native
profile. Codex login status reported existing ChatGPT authentication. No auth
files, keys, unrelated transcripts, environment values or account identifiers
were exported. No global update, onboarding, persistent settings, channels,
profiles, live services, deployment or push occurred.

## Checks and preserved failures

The native suite used the pinned Nix Cargo/Rust/Readline shell and these exact
inner commands from each verified extraction:

```bash
export HEIMDALL_EXECUTOR_REQUIRE_PTY=1 HEIMDALL_NOTIFICATION_REQUIRE_PTY=1
export HEIMDALL_NOTIFICATION_READLINE_BASH=$(command -v bash)
cargo test --locked --manifest-path tools/pty_host/Cargo.toml notification -- --test-threads=1 --nocapture
cargo build --locked --manifest-path tools/pty_host/Cargo.toml
```

The final extraction reused only the task-private Cargo target cache through
`CARGO_TARGET_DIR`; Cargo recompiled the changed crate and recorded its new source
path. Default Darwin TMPDIR was retained for the final suite.

| Source / check | Managed session | Actual result |
| --- | --- | --- |
| 9e6b89af, default TMPDIR | `sh_6f1066755bde04e080f4fbf07511304d` | Exit 101; 17 unit pass, 3 fail, 193 filtered; integration not reached |
| 9e6b89af, canonical private TMPDIR | `sh_c3f6bb9bd76e4cb1ef1aaacf4425b871` | Exit 0; 20 unit + 2 integration pass |
| 9e6b89af, focused canonical-TMPDIR parser diagnostic | `sh_6094c6efe4d7482185b93d6c8860920c` | Exit 0; `cargo test ... native_notification -- --test-threads=1 --nocapture`: 4 pass, 209 filtered |
| 9e6b89af, daemon build | `sh_f33869ed3bb5ed0cbb4618afdfe5b977` | Exit 0 |
| 7f13c94e, default TMPDIR suite and build | `sh_f8c282894d942b6f67e20edc42c025e7` | Exit 0; 20 unit + 2 integration pass; 0 failed/ignored; 193 unit filtered; build passes |

The original socket/od capture, F_GETFL restoration and partial-writer regressions
now pass, as does Readline with the default long Darwin temporary path. The new
9e6b89af failures are all at `native_notification.rs:228`, test setup reporting
`notification session: outside native session root`:

- `session_replacement_version_and_old_start_are_rejected`
- `stale_wrong_turn_timeout_and_mutated_prefix_fail_closed`
- `typed_fresh_same_turn_ack_excludes_echo_and_replay`

The unchanged-source diagnostic used only
`TMPDIR=/private/tmp/ham-mac-rerun-9e6b89af`; it is not relabeled as a default-path
pass. The engineer's fixture correction was explicitly pinned by requirements
revision 2 before final execution. No worker implementation/assertion edits
manufactured a pass. Initial tool inventory exited 1 because conventional
executable paths were absent; the successful explicit Nix/native paths above
supersede that narrow inventory, not its recorded exit status.

One revised source-chunk launch returned no parseable response and was retried
to its same task-private chunk file. The delayed managed record
`sh_a13646e2acbd3929f0608535822f938c` is failed with PID 0 and no log available;
the record and log refusal remain in the evidence JSON. All seven replacement
chunks completed and the reassembled archive passed the exact native hash before
execution. Local `diff -ru` exits 1 for the expected one-line fixture difference;
that comparison is not reported as a failed native test.

## Exact-session Codex results

The unmodified pinned harness ran from each source extraction with the native
vendor executable on PATH and the exact rebuilt private daemon:

```bash
/usr/bin/python3 tests/observe_provider_notification.py \
  --daemon "$PRIVATE_TARGET/debug/ham-pty-host" \
  --provider codex --model gpt-5.6-sol --seconds 10 --literal --native-interrupt
```

The harness clears inherited Heimdall routing/credentials, rejects startup/login/
update/onboarding gates, and disables update checks only for this invocation.
It prepares one ticket, deliberately loses a dispatch reply, queries and replays
that same ticket, then compares the exact fixture's native transcript. It uses
daemon `interrupt=true` and typed abort acknowledgment, not separate raw ESC.

| Source | Native session / managed run | Literal | Interrupting notice |
| --- | --- | --- | --- |
| 9e6b89af | `01a1b536-55c6-7e32-8b74-243cac9dc810` / `sh_d3d9c7e817ff78d44afeca4944a67f13` | 130 bytes, exact LF/TAB/euro/Japanese/emoji, one submission and replay | 102 bytes, exact once and replay, one typed abort |
| 7f13c94e | `01a1b53b-027f-7891-b22c-d989f5770320` / `sh_f1fe5edb7796b6308d3dece92222337e` | Same 130-byte exact/unique checks pass | Same 102-byte exact/unique checks pass, one typed abort |

Final literal ticket: `0bee2bca63bb0e2aedf6bc91c8e6684ab562db1607dc1ff2c80d1aa161001985`.
Final interrupt ticket: `6767f251c197dd3f726873c5d79746e0a60660b7a77294f6d84f6eabae78ed4d`.
Both receipts retain the native profile/version/digest shown above; interrupt
receipt has ESC and Enter written, 102 message bytes, delivered status 1, retry 0.

Post-run **worker** audits (not the named independent review) re-read only the
two exact fixture transcripts and compare expected text from retained intents.
Final audit `sh_0540b82e73a4f24160f5b25dee7ca907` records active turn
`01a1b53b-265f-75f3-8d7b-c52ede73bd37` at `08:58:34.984Z`, outer typed
`turn_aborted(reason=interrupted)` for that same turn at `08:58:35.902Z`, followed
by a new turn at `08:58:36.150Z`. Both exact texts appear once. Earlier worker
audit: `sh_f52dde91cb0a26de88a5f3c2d348541c`.

## Production gates and independent audit remain open

The harness directly supplies daemon IPC `0x42` binding after the native file
exists. It bypasses real local/remote production SessionStart. No positive
original owner producer → encrypted executor → native child → signed owner
result/replay demonstration was run. No idle-provider positive interrupt,
authority-change, partition, cross-owner, production restart or retained receipt
recovery acceptance is inferred from this disposable daemon observation.

Independent source audit `task_18e5b73835a29c2e`, report
`docs/native-interrupt-profile-audit-9e6b89af.md` at `fdbb67397186f63761954cbd9471c04739584c43`,
remains applicable to both pins:

- F1: production startup binding may precede lazy transcript creation; positive proof missing.
- F2: non-startup/clear/resume observations do not invalidate an old binding.
- F3: executable digest is attribution only; hash-to-path-exec race remains. This run does not prove immutable executable admission. Darwin safe pinned execution for a future hardened profile is unproven and must fail closed.
- F4: accepted state version 0.167.0 differs from admitted executable 0.162.0; these observed sessions both happened to be 0.162.0.
- F5: timestamp-only fixture directories collide under parallel tests. This serial 20+2 pass does not contradict the auditor's repeated parallel failures on both pins.
- F6: partial delivery may re-poll after an acknowledgment and enter recovery.
- L1/L2: same-uid writable state is transport evidence, never authority; bounded state reads/hashing hold the agents lock, and version probing can delay spawn.

These findings are neither fixed nor waived by this report. Future hardened
versions require separately pinned native evidence. Claude's prior 2.1.319
security-onboarding gate and Linux TAB-to-four-spaces failure remain unresolved;
Claude was not reinstalled/retested here and exact TAB was not waived. Other
unknown versions/profiles and Windows/WSL provide no Mac pass. Windows access
restoration was reported by the coordinator and awaits its separate lease.

## Cleanup and delivery

Final native cleanup `sh_a15e61c137bdb695d35c8f86315c4596` exits 0: no process
whose executable points inside task scratch, child PIDs 6663 and 7030 absent,
both exact provider sockets absent. It removes only task-private source/build/
provider/npm-cache scratch and canonical private TMPDIR, then verifies both
absent. No shared cache/process cleanup was attempted. Two provider fixture
evidence directories and their native transcripts remain for audit; Nix cache,
existing auth/config and any failed unit-test diagnostic fixtures are retained.

Full captured managed-session logs/statuses are in
[the versioned evidence JSON](evidence/macos-native-profile-sessions.json).
M3b engineer and coordinator received source/session findings during execution;
this report and logs are submitted for the task's named independent reviewer.
Evidence approval does not approve M3b implementation or close its audit gates.
