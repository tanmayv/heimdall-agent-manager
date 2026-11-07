# Ledger-only Linux runtime verification proposal

Task `task_18e5c7109a726015`, revision 1: approved source and actual Bridge/CLI/PTY builds are pinned. Executable scope is narrowed to in-process owner/executor ledger verification because the prior broader candidate lacked durable process capture for crash rollback. Ordinary ingress remains M4; physical/native proofs are historical evidence.

Pending independent named review and existing gates. No execution approval requested. No live chains, credentials, config, services, installation or startup changed.

## 1. Source and actual build pins (REQ-DEP-P1)

| Item | Pin |
|---|---|
| Repository | `/var/home/tanmay/heimdall-agent-manager` |
| Reviewed M3c source commit | `3d7cd69492a5a9b857b2e54c667366f62986d778` |
| Source tree | `02a5593160759b5de141811b25e871a260d35460` |
| Runtime implementation commit | `7d72d11e7b26c6f53c32d1e3eb53af910e15bb82` |
| Build checkout used during preparation | `.heimdall/worktrees/task_18e5c7109a726015`, clean at approved commit before this document |
| Package version / platform | `0.5.49` / `x86_64-linux` |
| Lockfile SHA256 | `51210591a4999db7fe38cdc906398e94a1116cd51f838276871907f265428136` |
| flake.nix SHA256 | `46e4c7819d2fef20b2207e5c76556c9c164df702ed58a86c9e6a9ab3f28b2241` |
| libcurl pin JSON SHA256 | `b9d53a73be302e93dc3019de68a47262829cf73984b876e936ce8e5332f1b366` |

Actual preparation command, managed session `sh_7da5832a497eba6a0b1b06f2d0b1f0b3`, exit 0:

```bash
nix build .#ham-bridge .#ham-ctl .#ham-pty-host --no-link --json
```

These outputs were built from the approved commit, rather than assumed from the older worker's success claim. No package was executed. The package entrypoints and hashes are:

| Package | Absolute entrypoint | SHA256 |
|---|---|---|
| Bridge wrapper | `/nix/store/s5gn1r88nl42dfyav0jzq74isfnvbq9r-ham-bridge-0.5.49/bin/ham-bridge` | `26b9e52bda8a2e2d3df3f2d706586f785988aa3fff9717fe68251bc23d0763b8` |
| Bridge executable | `/nix/store/s5gn1r88nl42dfyav0jzq74isfnvbq9r-ham-bridge-0.5.49/bin/.ham-bridge-wrapped` | `2e4636fda695aa69b81b28b3bb61db574184e18c71eb5fb406e49e0cbcab8d3a` |
| CLI | `/nix/store/551axj2arhddg3rqi566lhpvc7m54vdz-ham-ctl-0.5.49/bin/ham-ctl` | `640986fc90950675b9ba351aa692ae5e00806c6fe9f3a11c1afc4596b515c251` |
| PTY daemon | `/nix/store/8mbr1mz360m9v6ys15hrbfdgyxz4y2am-ham-pty-host-0.5.49/bin/ham-pty-host` | `bbe0cf588a293e0599b422fd3e7c5c2b82bbe3184e3148bcaed80e037c2d6309` |

NAR hashes cover whole outputs, including Bridge wrapper/resources:

| Output basename | NAR hash |
|---|---|
| `s5gn1r88nl42dfyav0jzq74isfnvbq9r-ham-bridge-0.5.49` | `sha256-7jHLL0g2SxdwPc1V3eFCbzTLEPg6HRlRcbQ6/lzBF8A=` |
| `551axj2arhddg3rqi566lhpvc7m54vdz-ham-ctl-0.5.49` | `sha256-tPGCsqdXkAtUFqnSxBC+K2g7d2hJxpyxxA6u4biNCKs=` |
| `8mbr1mz360m9v6ys15hrbfdgyxz4y2am-ham-pty-host-0.5.49` | `sha256-6MbsKGtg/Vt12Y2XMtZkyUUbPkNgnY2VMe3I/chu/3c=` |

The corresponding derivations are `q4dp2cg2580r446sjqrbr12qj135f13w-ham-bridge-0.5.49.drv`, `1zpisrmsv4ryprsnlr6ij58p3l64d6p4-ham-ctl-0.5.49.drv`, and `68wmw2f85gvnzqnxgn53nsryz2ig2ykw-ham-pty-host-0.5.49.drv`, all under `/nix/store`.

Riverwood uses the existing `/home/tanmay/.local/bin/nix` wrapper, rootless nix-portable with `NP_RUNTIME=bwrap`. Its store is visible inside `nix develop`, not directly from the host shell. Direct host `sha256sum /nix/store/...` therefore failed; repeating it inside the development environment read all four files successfully (session `sh_b12b3665b1043c2948e5c7bcc28f0307`; that session's final help grep returned 1, not a hash failure). No system Nix installation is proposed.

Dependencies are fixed by `flake.lock`: observed development tools Odin `dev-2026-09`, Rust `1.98.1`, Node `v26.4.0`; the Bridge package closure includes Odin `dev-2026-07a`, SQLite `3.53.3`, OpenSSL `3.6.4`, socat `1.8.1.3`, glibc `2.42-84`. Linked libcurl is the repository-pinned `8.23.0` (zlib source pin `1.3.2`); the closure also contains curl CLI `8.22.0`. The CLI version is not the linked-library version. Existing Nix caches/store may gain build objects; no global profile or service is changed. The build emitted the existing deprecated `stdenv.isDarwin` evaluation warning.

## 2. Named finding resolved by narrowing

Review of `8bdf4667` correctly found no operational mechanism to create the rollback ownership manifest. The remote-stop fixture holds original/replacement child PIDs locally; manual observation cannot durably capture every generation before a crash. Artifact `art_18e5c78488835689` is superseded.

This revision takes the reviewer's narrowing alternative, accepted by coordinator message `msg_18e5c7afe88cf48a`: **ledger-only verification**. Child-starting commands and manifest-dependent PID rollback are removed. No supervisor or runtime feature is added. Real shell/PTY and native proofs are historical evidence only.

The proposed command runs only `src/lib/owner_local`, without `-all-packages`. Static audit covered its 51 test files and production repository import closure: contracts, context_compaction, executor_channel, executor_local, html_bundle, jsonx, os_random, vault, workflow_v1. No process-start/kill/fork/exec/system call was found. Owner OS calls perform HOME lookup and fixture-file remove/chmod/exists; SQLite is in-process FFI. Imported package tests do not run. Execution fixtures inject observations and call ledger APIs, never Bridge/PTY/provider launches.

Audit session `sh_008deee76316003fa08c86866c1f2136` enumerated that closure and checked process-call patterns. This is static evidence, not fresh test execution. Odin/compiler/test-runner processes remain ordinary managed verification processes; the tests launch no separate runtime daemon, provider or fixture child.

## 3. Exact isolated configuration (REQ-DEP-P1)

Private absent root: `/home/tanmay/.cache/heimdall-candidates/linux-owner-ledger-3d7cd694`, with `source/`, `home/.cache/heimdall-tests/` and `bin/owner-tests`.

| Boundary | Ledger-only configuration |
|---|---|
| Account/keys | Fixture `account`, owner `bridge`/`bridge_key`, creator `device`, generated fixture P-256 keys; no live enrollment. |
| Executor | In-process `executor`/`operator` with separate SQLite store; no enrolled machine. |
| Owner DB | Private HOME + `/.cache/heimdall-tests/owner-unit-<nanoseconds>-<atomic-sequence>.sqlite`; WAL/SHM/`.writer` sidecars. |
| Executor DB | Owner DB path + `.executor` and its own sidecars. |
| Setup | `src/lib/owner_local/store_test.odin:24` creates keys/owner DB; `src/lib/owner_local/execution_test.odin:38` creates executor ledger. Destructors close/remove fixture DBs. |
| Runtime/profile | No Bridge config, keystore, provider profile/catalog, TASK filesystem bootstrap, PTY host or provider executable. Provider names are inert fixture data. |
| Endpoints/ports | None: no TCP/HTTP, Unix socket, Hub relay, browser session or daemon socket. |
| Auth/roles | Private HOME has no provider auth. Inherited Heimdall/provider keys removed. Fixture worker/reviewer capabilities have no physical process or live Hub authority. |
| State | Private root, Git worktree metadata and existing Nix caches. Failure can leave private DB files. |

Pinned Bridge/CLI/PTY outputs remain build evidence; this candidate executes none of their entrypoints. No dynamic /tmp/socket/child ownership manifest is needed because those resources are excluded.

## 4. Proposed ledger commands — NOT EXECUTED

For a later execution task after named review and existing gates; no execution approval requested now. Use managed `ham-ctl shell run` with explicit cwd, never `serve`.

```bash
set -eu
candidate_root=/home/tanmay/.cache/heimdall-candidates/linux-owner-ledger-3d7cd694
test ! -e "$candidate_root" || exit 1
umask 077
mkdir -p "$candidate_root"/{home/.cache/heimdall-tests,bin}
git -C /var/home/tanmay/heimdall-agent-manager worktree add --detach \
  "$candidate_root/source" 3d7cd69492a5a9b857b2e54c667366f62986d778
git -C "$candidate_root/source" rev-parse HEAD HEAD^{tree}
git -C "$candidate_root/source" status --porcelain
```

Require section 1 commit/tree and empty status. Run below with cwd `/home/tanmay/.cache/heimdall-candidates/linux-owner-ledger-3d7cd694/source`. Establish Nix before overriding HOME:

```bash
nix develop --command bash -c '
set -eu
candidate_root=/home/tanmay/.cache/heimdall-candidates/linux-owner-ledger-3d7cd694
for name in $(compgen -A variable HEIMDALL_); do unset "$name"; done
unset OPENAI_API_KEY ANTHROPIC_API_KEY CODEX_HOME
export HOME="$candidate_root/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
umask 077
odin test src/lib/owner_local -collection:odin_test=src \
  -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 \
  -out:"$candidate_root/bin/owner-tests"
sha256sum "$candidate_root/bin/owner-tests"
printf "%s\n" "LEDGER_ONLY_VERIFICATION_COMPLETE"
'
```

Do not add `-all-packages`, change to `src/bridge`, add native opt-ins or supply a PTY binary. This builds and RUNS owner tests, not build-only. It was not run during preparation. Require managed exit 0, zero failures and final marker. M3c previously reported 269 owner tests; investigate unexpected count changes. Save session ID/results and future test-executable hash. No unbuilt test hash is claimed.

Review surface: named output plus pinned source assertions. DBs are removed on normal exit; no interactive product/SQL inspection window.

## 5. Coverage and missing ingress (REQ-DEP-P2)

| Behavior | Available ledger-only check |
|---|---|
| Signed chain/fleet | Fixture keys sign commands and validate chain/fleet/reservation history. Some setup seeds prior rows by SQL; this is not the mounted signed Bridge proof. |
| Claim/requirements/submit | `src/lib/owner_local/review_roles_test.odin:13` claims, presents/acks requirements and submits exact revision through APIs. No worker process. |
| Named/user gates | `src/lib/owner_local/review_roles_test.odin:29` keeps in_review until primary, both roles and human approval; author/stale exclusion asserted. |
| Prepare/commit | Separate in-process owner/executor DBs/signatures in execution tests; no daemon. |
| Stop/replay | Signed durable phases and acceptance against injected observations; no fresh physical termination/PTY-input proof. |
| Crash/offline/unknown | Charge retained without correlated trusted executor released proof; stopping is acceptance only. Unknown/expiry/journal loss cannot prove absence/refund capacity. |

No fresh real shell/PTY/native child, daemon restart, replacement-generation stop or provider session is proposed.

Dedicated source paths exist: `task-chain owner-local relay --request-file` forwards human-device-signed browser exports; `task-chain owner-local lease --request-file` calls `agent.owner_local.lease`. Tokens authenticate transport, not human signatures/grants; Wrapper access is denied. See `src/ctl/taskv2_cmds.odin:1336`, `src/bridge/owner_local_leases_test.odin:6`, `src/bridge/executor_child.odin:56`.

No fixture Hub/browser signer/paired live account is supplied. Ordinary UI/CLI/worker migration, cutover/restore and repeated-cycle convergence remain M4. Dedicated APIs are not normal ingress readiness. Do not use live tokens, exports or chains to fill the gap. This is not a deployable app.

## 6. Historical physical/native evidence, excluded from execution

Release scope remains Linux Codex only. Mac execution and Claude notifications remain disabled/user-deferred; Windows is unsupported.

[M3c report](artifact://art_18e5c657a8858a2a) and [source/evidence](artifact://art_18e5c63e31f87a5e) retain implementation `7d72d11e` in approved `3d7cd694`.

Prior remote-stop proof used genuinely signed original-owner chain/fleet/requirements/prepare/commit/bootstrap, real shell/PTY, owner/executor DB restarts, disconnected stopping with charge 1, reconnected exact released proof reducing charge to 0, and replacement isolation. Source `src/bridge/owner_executor_stop_test.odin:18` holds PIDs locally at lines 46/130 without durable external capture. Prior required-daemon Bridge suite: 1046 passes. No rerun command is supplied.

Recorded Linux Codex `0.162.0` / `gpt-6.1-sol` run `sh_79d0d26107ba8390215cca35652fed86`: 1 pass/4.69s, real SessionStart binding, one notice, one typed abort, 66 message bytes, partial/lost-result recovery and signed receipt replay. Notification is typed PTY interrupt/paste/Enter, not desktop notification. Completed exact receipts replay read-only; unfinished unknown partials refuse recovery/resend and retain charge. Replay does not override expiry/revocation.

Existing authorization permits one-invocation inspected hamctl hook with the already-authenticated provider profile, no credential export/copy, login or persistent auth/trust/settings change. It is separate from private no-auth state. `src/bridge/owner_executor_native_test.odin:201` generates the script calling `"$HEIMDALL_CTL_BIN" extension hook codex`. Inspected arguments use read-only sandbox, no alt-screen, updates disabled and authorized invocation-only `--dangerously-bypass-hook-trust`, not persistent trust installation.

Retained read-only pins:

- `/home/linuxbrew/.linuxbrew/bin/codex` resolves to `/var/home/linuxbrew/.linuxbrew/Caskroom/codex/0.162.0/bin/codex`, SHA256 `50ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38`.
- `/home/tanmay/.cache/heimdall-tests/native-owner-pending-20261107-1017.json` SHA256 `91fce628cbe0866a93d18e883c20767853927b10bf3e614a03de0c6697a3fac8`.

Existing profile can write sessions/transcripts outside private state. No fresh private native readiness or execution command is proposed. Historical cleanup `sh_6c03dce5a69d4a3d6116f8359895e022` found PID3304905 absent, no new sockets/locks, unchanged config SHA256 `d111397be1b38940d9b795a64f8b75dc61a659e98895d6aff0a41ba372aba6cf`; not an expected current hash.

Before any future child-starting proposal, require independently reviewed pre-start supervision/containment with durable host/inner-Nix PID mapping, every daemon/original/replacement generation, state/socket ownership and prevention of further spawns during teardown. Establish capture before spawn; fail closed if unavailable. Manual later polling/empty manifests do not qualify. This preparation implements/assumes none of it; native authorization alone does not supply rollback.

## 7. Ledger-only cleanup

No runtime service/profile cutover, running Bridge/PTY/provider, socket or keyring exists in this scope. Rollback removes only private checkout/fixture files after verified inactivity.

Normal managed exit 0 plus `LEDGER_ONLY_VERIFICATION_COMPLETE` means Odin waited for its test executable. Destructors close/remove DBs/sidecars. Save managed results externally, then clean up below. On failure, abort, host crash, missing marker, unknown status or uncertain completion, **preserve the root; do not remove it**. Let managed verification finish or investigate its owning session. Never guess PIDs/kill by provider name/delete open state.

After interruption, cleanup waits for confirmed end of managed process and no compiler/test runner using the root; otherwise quarantine it for the later execution holder. This does not promise crash cleanup for physical child generations: the narrowed tests cannot launch them.

```bash
set -eu
candidate_root=/home/tanmay/.cache/heimdall-candidates/linux-owner-ledger-3d7cd694
# Require recorded exit 0 + marker, or separately verified inactivity.
test "$candidate_root" = /home/tanmay/.cache/heimdall-candidates/linux-owner-ledger-3d7cd694
test "$(git -C "$candidate_root/source" rev-parse HEAD)" = 3d7cd69492a5a9b857b2e54c667366f62986d778
test -z "$(git -C "$candidate_root/source" status --porcelain)"
git -C /var/home/tanmay/heimdall-agent-manager worktree remove "$candidate_root/source"
rm -r -- "$candidate_root"
```

Stop on any failed precondition/removal. Never remove M4 worktrees, shared caches/store, ordinary Bridge state, provider sessions/config, global profiles/services. Filesystem cleanup cannot forge executor absence or settle charge.

## 8. Acceptance and checks (REQ-DEP-P3)

| Requirement | Disposition |
|---|---|
| REQ-DEP-P1 | Source/tree and actual package SHA256/NAR/dependencies retained; private ledger account/DB/config/commands specified. No live endpoint/auth. |
| REQ-DEP-P2 | Smallest currently safe scope is ledger-only. Physical child rollback lacks pre-start capture, so starts are excluded. M4/historical-proof limits explicit. |
| REQ-DEP-P3 | Committed document/replacement artifact for independent review; no deployment/startup/auth/service/install/push. |

Preparation: prior three-package build/hash reads; revised static initial-owner-test/import-closure no-child audit; Bash syntax/source-reference/diff checks and artifact roundtrip. No ledger test, child suite, daemon/server/provider ran during preparation.

Retained M3c: owner269, executor56, channel6, contracts40, required-daemon Bridge1046, UI24, typecheck/packages and native proof above. Existing Bridge allocator warnings remain; no leak-free claim. Pins do not turn historical evidence into fresh runs or waive gates.
