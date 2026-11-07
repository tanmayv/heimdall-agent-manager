# Isolated Linux owner-runtime test candidate and rollback

This is a review proposal for task `task_18e5c7109a726015`, requirements revision 1. Preparation rebuilt and hashed approved Bridge, CLI and PTY packages; it did not deploy, start a daemon/child/server, install software, modify live credentials/configuration, or push. The smallest meaningful candidate is signed owner/executor ledger tests plus a real shell/PTY fixture. Normal UI/CLI/worker migration is still M4 work. The optional actual Codex route uses the already-authorized existing provider profile and is explicitly separate from the fully private no-auth candidate.

## Decision and review boundary

Independent named review and the task's explicit user approval must precede any execution of the proposed child-starting commands below. Approval of this document is not approval to migrate an existing chain. No existing chain, account, runtime socket, Bridge configuration, user service, provider trust setting or production database is an input to the private fixture candidate.

The candidate validates runtime primitives and failure boundaries. It does not offer an interactive deployed product, a fresh provider login, WAN partition proof, general release readiness, Mac/Claude execution notifications, or Windows support. Native release scope is Linux Codex only; Mac and Claude notifications remain disabled/user-deferred and Windows is unsupported.

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

## 2. Isolation contract

The operator selects a new, absent candidate root:

```text
/home/tanmay/.cache/heimdall-candidates/linux-owner-3d7cd694
  source/                 detached checkout of the reviewed commit
  home/                   private HOME for no-auth fixtures
  home/.cache/heimdall-tests/
  home/.config/heimdall/bridges/brg_test_<test-pid>/
  home/.config/heimdall/bridges/brg_test_<test-pid>_b/
  bin/                    compiled fixture test executables
  evidence/               exit status, hashes and owned-process manifest
```

An existing root is a refusal, not an invitation to overwrite. No deployment profile is added to the ordinary Bridge. Test configuration is in-process and restores its globals on normal return.

| Boundary | Actual candidate behavior |
|---|---|
| Account | Bridge fixture `usr_bridge_test`; owner-unit fixture `account`. Neither is a live Hub login. |
| Creator/device | Fixture root signing key and genuinely signed test directory; owner unit uses generated fixture keys. No production enrollment/export. |
| Owner/executor | Separate test identities `brg_test_<pid>_b` and `brg_test_<pid>`; owner and executor databases remain distinct even when both run in one test process. |
| Key scope | `http://keystore.test.invalid:1` is the test-only canonical scope default, not a server to start. Test builds refuse non-`brg_test_` keystore identities. Fixture-only Linux keyring entries may exist during execution and are purged by fixture teardown. |
| Profile/catalog | `p1c_test_setup` creates a private catalog/profile file under `/tmp/ham-p1c-<pid>-<nanoseconds>/provider_profiles.json`; shell fixture injects a test preparer. Its nominal Claude catalog entry is not Claude execution evidence. |
| Owner DB | Remote-stop/native fixture `/tmp/ham-p1c-<pid>-<ns>/work/owner-native.sqlite`; owner unit `<private HOME>/.cache/heimdall-tests/owner-unit-<ns>-<sequence>.sqlite`. |
| Executor DB | Private per-test Bridge vault directory, account-digest subdirectory `executor-local-<SHA256(account)>`; `runtime.sqlite` plus `runtime.sqlite.writer` and SQLite WAL/SHM sidecars (`src/bridge/executor_issuance.odin:21`). Account digest is `17a9731873dce63118def85569ef7dfcc01b9d2933165932e9d6b30ab1c6b0c4`. Record the created directory before cleanup. |
| Runtime content | Private p1c data/work tree, generated TASK/bootstrap, profile and exact launch key; never an active M4 worktree. |
| Ports / Hub | No TCP port, HTTP server, production Hub endpoint, browser account or relay service. |
| PTY endpoints | Remote stop: `/tmp/ham-remote-stop-<ns>.sock`, plus empty-owner control `/tmp/ham-owner-empty-<ns>.sock`; both have separate lock files. Native optional route: `/tmp/ham-native-owner-<ns>.sock`, `/tmp/ham-native-hook-<ns>.sock`. Fail on collision. |
| Native auth | Fully private HOME has no provider auth. No credential copy, provider login, trust/config edit or implicit fallback to the ordinary profile. |
| Roles/capabilities | Capacity 1 worker policy in signed remote fixture; original owner prepares/commits one lease/bootstrap. Separate owner-unit role tests require every configured named pair and explicit human approval; fixture capabilities are not reusable live tokens. |

Paths containing `<pid>`, `<ns>`, and account digests are generated by reviewed source, not caller-selected deployment flags. Record their exact realized values for each approved execution. Hardcoded /tmp paths are not redirected by setting TMPDIR. Private HOME covers state that uses home expansion, while p1c/socket paths are separately owned temporary state.

## 3. Proposed execution commands — NOT EXECUTED

Run via managed `ham-ctl shell run --cwd <source>`; use explicit background mode only when desired and read completion logs. These commands are for the later approved execution task. Do not run a Bridge daemon, `nix run .#bridge`, Hub server, provider installer or service manager.

First create the absent candidate root and pinned source, using the existing repository only as a read source plus Git worktree metadata:

```bash
set -eu
candidate_root=/home/tanmay/.cache/heimdall-candidates/linux-owner-3d7cd694
test ! -e "$candidate_root" || exit 1
umask 077
mkdir -p "$candidate_root"/{home/.cache/heimdall-tests,bin,evidence}
git -C /var/home/tanmay/heimdall-agent-manager worktree add --detach \
  "$candidate_root/source" 3d7cd69492a5a9b857b2e54c667366f62986d778
git -C "$candidate_root/source" rev-parse HEAD HEAD^{tree}
git -C "$candidate_root/source" status --porcelain
```

Stop if HEAD/tree differ from section 1 or status is nonempty. All subsequent commands run from `$candidate_root/source`. Inside the existing Nix environment, verify section 1 SHA256 and NAR hashes before using the exact PTY package. The Bridge and CLI outputs are pinned deliverables; baseline fixtures exercise Bridge source as a test executable, not a running package service.

The following shell body is the complete no-auth test scope. It deliberately does not run any native provider test. It sanitizes inherited Heimdall credentials before compiling/running test code, keeps HOME private, and preserves the compiler/tool environment established by Nix:

```bash
nix develop --command bash -c '
set -eu
candidate_root=/home/tanmay/.cache/heimdall-candidates/linux-owner-3d7cd694
for name in ${!HEIMDALL_@}; do unset "$name"; done
unset OPENAI_API_KEY ANTHROPIC_API_KEY CODEX_HOME
export HOME="$candidate_root/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
export HEIMDALL_EXECUTOR_TEST_PTY=/nix/store/8mbr1mz360m9v6ys15hrbfdgyxz4y2am-ham-pty-host-0.5.49/bin/ham-pty-host
umask 077
odin test src/lib/owner_local -collection:odin_test=src \
  -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 \
  -out:"$candidate_root/bin/owner-tests"
odin test src/bridge -collection:odin_test=src \
  -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 \
  -define:EXECUTOR_TEST_REQUIRED=true \
  -define:ODIN_TEST_NAMES=main.test_executor_original_owner_remote_stop \
  -out:"$candidate_root/bin/remote-stop-tests"
sha256sum "$candidate_root/bin/owner-tests" "$candidate_root/bin/remote-stop-tests"
'
```

These commands build and RUN tests; they must not be mistaken for private build-only preparation. `EXECUTOR_TEST_REQUIRED=true` makes missing actual PTY support fail instead of silently skipping. The source-level remote-stop test name is verified in `src/bridge/executor_issuance_test.odin:68`. Compilation hashes of these future test executables are not claimed as already prepared outputs.

Observe managed output and exit status. Require zero failing tests, no required-daemon skip, and the remote-stop final marker:

```text
[remote-stop] signed original owner cancel -> durable query/stop -> executor/owner restart -> disconnected stopping retains charge -> exact released receipt PASS
```

The user can inspect signed protocol/SQL assertions directly in `src/bridge/owner_executor_native_test.odin:60`, `src/bridge/owner_executor_stop_test.odin:18`, and `src/lib/owner_local/review_roles_test.odin:29`. These deterministic fixtures remove their DBs on normal exit; they do not promise an interactive SQL inspection window or retained plaintext state. Managed logs and the pinned source are the review surface. A product UI demonstration requires M4 convergence and a separate deployment proposal.

## 4. Meaningful user checks and missing ingress (REQ-DEP-P2)

| Check | Available observation / pass condition |
|---|---|
| Signed chain/fleet/requirements | Remote fixture executes signed chain.create, task.create, fleet.policy.set, fleet.reserve, requirements.edit, genuine preparation/commit/bootstrap APIs; its original-owner marker must pass. No authority rows are inserted by SQL. |
| Claim/present/ack/submit/review | Full owner suite includes role fixture claim, requirements.present/ack, lease.submit, primary review, two named role votes and human review. State remains in_review until all gates pass; self-author review and stale attempts reject. This is source/API fixture coverage, not an autonomous Codex worker completing a task. |
| Exact cancel/stop | Signed cancellation creates durable executor query then ordinary stop. An empty owner-local daemon refuses remote settlement. After owner/executor DB restart the exact executor alone can acknowledge release. |
| Disconnected endpoint | Signed stopping accepted, actual original PID still live, live-resource count remains 1. Reconnect and exact released receipt then make charge 0. |
| Replacement isolation | Old reservation stop leaves the replacement launch key/PID alive. Replacement is a physical test control, not a new task grant. |
| Replay/lost reply | Durable query bytes repeat identically; transport retry does not manufacture new authority. Existing signed receipts prove past results only. |
| Fail-closed resources | Approved M3c mounted regressions cover catalog disabled, binary changed, directory missing/replaced during unlocked callback: invalid_resources before first spawn. They are recorded evidence, not extra cases silently added to this proposed execution scope. |
| Crash/offline/unknown | Daemon journal loss or unavailable child means unknown/recovery_required/child_unavailable, never trusted absence. Expiry alone does not refund capacity; no automatic retarget or reconstructed partial receipt. |

Existing dedicated ingress does exist: CLI `task-chain owner-local relay --request-file` forwards opaque human-device-signed browser exports; `task-chain owner-local lease --request-file` calls `agent.owner_local.lease`. Instance tokens authenticate transport and cannot generate human signatures/grants. The Bridge denies Wrapper access to that lease route. Sources: `src/ctl/taskv2_cmds.odin:1336`, `src/bridge/owner_local_leases_test.odin:6`, `src/bridge/executor_child.odin:56`.

These dedicated paths do not make ordinary `task-chain`/`lease`/`review` worker commands or normal browser chain creation automatically target an isolated owner. There is no fixture Hub/browser/export signer/paired production account in this candidate. M4 must finish ordinary ingress, worker migration, cutover/restore and repeated-cycle convergence before a normal user deployment can be meaningfully proposed. Do not pass the worker's live token or live signed exports into the candidate to fill that gap.

## 5. Optional existing-profile Linux Codex route

This is a separate, already-authorized one-invocation diagnostic route from M3c, not the private no-auth baseline. No fresh native test was run during preparation. The approved source report records Codex `0.162.0`, model `gpt-6.1-sol`, session `sh_79d0d26107ba8390215cca35652fed86`, 1 pass in 4.69s: real SessionStart hook binding, one notice submission, one typed abort, 66 message bytes, partial/lost-result persistence recovery and signed receipt replay.

Provider executable read-only pin observed during preparation:
`/home/linuxbrew/.linuxbrew/bin/codex` resolves to `/var/home/linuxbrew/.linuxbrew/Caskroom/codex/0.162.0/bin/codex`; SHA256 `50ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38`. Existing inspected invocation-arguments file `/home/tanmay/.cache/heimdall-tests/native-owner-pending-20261107-1017.json` SHA256 is `91fce628cbe0866a93d18e883c20767853927b10bf3e614a03de0c6697a3fac8`.

That argument file requests no alternate screen, read-only sandbox, update checking disabled, and the explicitly authorized invocation-only `--dangerously-bypass-hook-trust`. The reviewed fixture replaces only the SessionStart hook argument with its private script. At `src/bridge/owner_executor_native_test.odin:201` that inspected script records the fixture event and runs exactly `"$HEIMDALL_CTL_BIN" extension hook codex`; it does not install persistent trust/configuration. Verify the script source and hashes before any rerun. No auth export, copied credential, settings edit, alternate provider transport or normalization is allowed.

If an execution task elects this optional diagnostic, use the existing authenticated provider profile as authorized; preserve its current HOME/provider profile rather than falsely claiming a new private provider login. Keep fixture state and compiled output private, and sanitize inherited HEIMDALL_* first as in section 3. Existing provider session/transcript files can be written by Codex in its existing profile; they are outside the fully private baseline and must be recorded as exact session paths, never glob-deleted. Refuse the optional diagnostic if an existing profile would require login, auth refresh/config/trust mutation, or if its outputs cannot be scoped. No new user auth action is needed to complete this preparation.

Exact future diagnostic invocation, inside the pinned source's Nix environment after HEIMDALL_* sanitization:

```bash
env HEIMDALL_NATIVE_CODEX=/home/linuxbrew/.linuxbrew/bin/codex \
  HEIMDALL_NATIVE_MODEL=gpt-6.1-sol \
  HEIMDALL_NATIVE_ARGS=/home/tanmay/.cache/heimdall-tests/native-owner-pending-20261107-1017.json \
  HEIMDALL_NATIVE_CTL=/nix/store/551axj2arhddg3rqi566lhpvc7m54vdz-ham-ctl-0.5.49/bin/ham-ctl \
  HEIMDALL_EXECUTOR_TEST_PTY=/nix/store/8mbr1mz360m9v6ys15hrbfdgyxz4y2am-ham-pty-host-0.5.49/bin/ham-pty-host \
  odin test src/bridge -collection:odin_test=src \
  -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1 \
  -define:EXECUTOR_NATIVE_OWNER=true \
  -define:ODIN_TEST_NAMES=main.test_executor_original_owner_native_notification \
  -out:/home/tanmay/.cache/heimdall-candidates/linux-owner-3d7cd694/bin/native-owner-tests
```

This proposes the newly pinned CLI/PTY rather than silently reusing the older M3b CLI from the recorded run; that exact combination has not been native-rerun here. Record its eventual result separately. Compare provider config SHA256 before/after without printing config or auth. Recorded M3c cleanup `sh_6c03dce5a69d4a3d6116f8359895e022` found PID3304905 absent, no new sockets/locks, and unchanged config SHA256 `d111397be1b38940d9b795a64f8b75dc61a659e98895d6aff0a41ba372aba6cf`; this is historical evidence, not the expected current hash.

Native notification is a typed PTY interrupt/paste/Enter operation with retained exact ticket/receipt, not OS desktop notification. A completed exact receipt can be replayed read-only after journal loss; revocation/expiry still apply. An unfinished partial operation with lost daemon journal must return recovery_required/child_unavailable and retain capacity, not resend a potentially duplicate message. The remote stop scenario above uses a shell child; it does not establish a fresh native-Codex cancellation run or a Claude/Mac claim.

## 6. Failure handling and exact rollback

Rollback affects only candidate-owned processes and state. There is no live service switch to undo and no existing DB backup to restore. Do not clear shared keyrings, stop user services, run killall/pkill, remove global Nix profiles/store objects, or reset the repository.

Before any later execution, the execution holder records a private owned-process manifest containing each test runner, daemon and child PID, /proc PID start-time, executable identity and exact socket/state paths. Capture host /proc PIDs and parent-child ownership at creation/observation, not by matching a process name after a crash. If an inner Nix namespace reports different PIDs, do not substitute those for the host manifest. Native fixture logs the actual child PID; record its exact transcript/session paths without retaining token-bearing argv. Include timestamp and whether an identity was verified. A missing/ambiguous identity is a stop-and-investigate condition.

| Event | Response / rollback |
|---|---|
| Normal return | Reviewed fixture defers close exact instance+launch-key child, kill/wait only its daemon, purge test identities and remove its temporary trees/socket/lock files. Owner unit closes/removes DB/WAL/SHM/writer files. Verify manifest entries absent afterward. |
| Runner still active | Let bounded fixture teardown finish; if aborting a managed run, use `ham-ctl shell kill <that candidate session-id>`. Ctrl-C alone does not stop a managed run. Do not assume stopping the runner proves children absent. |
| Runner/daemon crash | For each manifest PID verify current /proc start-time and executable still equal the recorded values; signal TERM to that exact owned PID, wait, and only if the same identity survives use KILL. A recycled PID must never be signalled. Recheck the exact recorded child even if a restarted daemon reports unknown. |
| Unknown ownership | Leave process and state intact, preserve private evidence and request investigation. Never kill by provider name or refund ledger capacity. |
| Physical daemon offline | Retain charge and durable signed phase. Reconnect/requery exact executor; only correlated signed released proof settles capacity. Manual OS cleanup is test rollback, not authority to forge an executor receipt. |
| Unexpected provider/profile change | Stop optional route, preserve hashes and paths, report discrepancy. No automatic credential/config restore from copied secrets or broad profile deletion. |

After all recorded processes are verified absent, remove only the manifest's exact generated socket/lock and p1c paths (checking ownership and that they were absent before this run). No wildcard /tmp cleanup. Purge only the test identities through fixture teardown; a residual test keyring entry requires exact recorded test scope, never a keyring-wide clear.

For an abnormal exit, the following exact command consumes the privately recorded manifest `evidence/owned-processes.json`, a JSON array of `{"pid":123,"start_ticks":"456","exe":"/absolute/executable","role":"fixture-child"}` records. Values must have been observed while ownership was established; the example numbers are schema examples, not targets. It signals only matching identities, children before daemons before runners. It refuses a mismatch rather than guessing. Run it from the host /proc namespace where the manifest was captured. It uses Linux pidfds so a recycled PID cannot receive a later signal.

```bash
python3 - /home/tanmay/.cache/heimdall-candidates/linux-owner-3d7cd694/evidence/owned-processes.json <<'PY'
import json, os, select, signal, sys
from pathlib import Path

def identity(pid):
    try:
        base = Path("/proc") / str(pid)
        stat = (base / "stat").read_text()
        # comm may contain spaces/parentheses; fields after final ')' start at field 3.
        fields = stat[stat.rfind(")") + 2:].split()
        if fields[0] == "Z":
            return None
        return fields[19], os.readlink(base / "exe"), base.stat().st_uid
    except FileNotFoundError:
        return None

rows = json.loads(Path(sys.argv[1]).read_text())
rank = {"fixture-child": 0, "pty-daemon": 1, "runner": 2}
for row in sorted(rows, key=lambda r: rank[r["role"]]):
    pid = int(row["pid"])
    assert pid > 1 and pid not in (os.getpid(), os.getppid())
    expected = (str(row["start_ticks"]), row["exe"], os.getuid())
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        continue
    try:
        current = identity(pid)
        if current is None:
            continue
        assert current == expected, "PID identity mismatch; preserve state"
        # fd pins this process even if the numeric PID is later reused.
        try:
            signal.pidfd_send_signal(fd, signal.SIGTERM)
        except ProcessLookupError:
            continue
        if not select.select([fd], [], [], 5)[0]:
            try:
                signal.pidfd_send_signal(fd, signal.SIGKILL)
            except ProcessLookupError:
                pass
            assert select.select([fd], [], [], 5)[0], "Owned process remains; investigate"
    finally:
        os.close(fd)
print("Recorded candidate processes absent; this is OS cleanup, not a signed release")
PY
```

Finally detach the candidate checkout and remove its own root, after preserving the small non-secret evidence report:

```bash
set -eu
candidate_root=/home/tanmay/.cache/heimdall-candidates/linux-owner-3d7cd694
# Preconditions: all manifest process identities absent; source checkout clean.
git -C "$candidate_root/source" status --porcelain
git -C /var/home/tanmay/heimdall-agent-manager worktree remove "$candidate_root/source"
# Inspect this literal path and its owned contents before removal:
test "$candidate_root" = /home/tanmay/.cache/heimdall-candidates/linux-owner-3d7cd694
rm -r -- "$candidate_root"
```

Do not execute removal if worktree removal failed, status was dirty, or root ownership is uncertain. Native profile transcripts remain in the existing profile unless an exact recorded fixture-owned path is separately reviewed for cleanup; no provider-wide session deletion. No daemon socket for the ordinary running Bridge is ever an input to these commands.

## 7. Evidence and acceptance map (REQ-DEP-P3)

| Requirement | Deliverable / limitation |
|---|---|
| REQ-DEP-P1 | Approved commit/tree, actual freshly built package/entrypoint/NAR hashes, pinned dependencies, separate identities/HOME/DBs, exact generated socket patterns and commands. No live endpoint or credentials. |
| REQ-DEP-P2 | Reproducible signed ledger + actual shell/PTY scope, exact expected failure/charge behavior and owned-process rollback. Dedicated ingress/M4 and native auth boundaries are explicit. |
| REQ-DEP-P3 | This committed document plus its identical review artifact. No deployment/startup, auth/config/service mutation, installation or push occurred during preparation. Independent and user reviews remain pending. |

Recorded approved M3c results: owner 269, executor 56, encrypted channel 6, contracts 40, required-daemon Bridge 1046, UI 24; typecheck and all three packages passed. Full Bridge suite has existing allocator warnings; no leak-free claim. Historical/native replay proof does not guarantee indefinite transport validity, override revocation, reconstruct unknown physical outcomes, or establish normal M4 ingress. This preparation reran builds and read source/hashes only, not those child-starting suites.

Primary evidence: [M3c repair report](artifact://art_18e5c657a8858a2a), [M3c source hashes and evidence](artifact://art_18e5c63e31f87a5e), committed `docs/m3c-remote-runtime-repair.md` and `docs/evidence/m3c-remote-runtime-repair.json`. This proposal adds no runtime feature and makes no deployment readiness claim beyond the small fixture scope stated above.
