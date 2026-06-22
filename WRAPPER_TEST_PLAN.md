# `ham-wrapper test` Plan

## Goal

A self-contained, no-daemon smoke test driven by `ham-wrapper` itself. Walks through every prerequisite the daemon-managed start path depends on — config parsing, tmux availability, agent CLI exec, tier flag wiring, startup detection, prompt round-trip, and file creation — and prints a step-by-step report.

Reliability is the explicit design priority. The test should produce **the same outcome every run** for a given config + provider + tier, fail loudly with diagnostics when it doesn't, and never leave abandoned tmux sessions or temp dirs behind.

Use case: after editing `config.toml`, swapping providers, or upgrading the agent CLI, run one command to verify the whole launch chain works *before* involving the daemon, UI, or any persistent state.

---

## Command shape

```
ham-wrapper test \
  --config <path> \
  --provider <name> \
  --tier <cheap|normal|smart> \
  [--keep <on-failure|always|never>] \
  [--timeout <seconds>] \
  [--step-timeout <seconds>] \
  [--strict-tier] \
  [--verbose] \
  [--dry-run]
```

- `--config` defaults to the same `--config` resolution `ham-wrapper` already uses.
- `--provider` required.
- `--tier` defaults to `normal`.
- `--keep` defaults to `on-failure`: cleanup happens on success, but the cwd + tmux session are preserved on failure so the user can inspect. `always` keeps everything. `never` always cleans (use in CI).
- `--timeout` is the overall test deadline (default `120s`). After this, kill everything and report.
- `--step-timeout` per-step deadline (default `30s`, raised for step 7 to `--timeout-step-7` if needed).
- `--strict-tier` (default on): if `--tier smart` is given but `models.smart == ""` in config, fail step 1 hard instead of silently skipping. Silent skip would let a misconfigured tier produce a green PASS.
- `--verbose`: stream pane snapshots and intermediate state to stderr.
- `--dry-run`: run steps 1–2 only (config + tmux availability), skip everything that actually spawns a process.

No daemon contact. No registration. No agent-token. No bootstrap file generation.

---

## Output format

One line per step, prefixed `[N/7]`, aligned columns, plain ASCII (no color codes). Final `PASS`/`FAIL` with total elapsed.

```
ham-wrapper test  run_id=t-2026062023154800-a3f1
              cwd=/tmp/ham-wrapper-test-t-2026062023154800-a3f1
              tmux=ham-test-a3f1:smoke

[1/7] config parse                                 OK   3 agent-cmds; tier=normal → sonnet
[2/7] tmux available + functional                  OK   tmux 3.4; session create/kill round-trip 12ms
[3/7] launch agent process                         OK   pane=%87 model=sonnet stayed-up 2.0s
[4/7] restart with starter prompt                  OK   pane=%88 prompt=247 chars
[5/7] startup detection                            OK   matched "⏵⏵ " after 1.4s
[6/7] echo handshake + send test prompt            OK   echo seen 0.6s after send
[7/7] verify test_file created + DONE marker       OK   /tmp/.../test_file (0 bytes); DONE at 18.4s

PASS  total 22.1s
cleanup OK
```

On failure (here, step 5 timed out):

```
[5/7] startup detection                            FAIL no ready_pattern matched in 15.0s; pane last lines:
        > Welcome to claude
        > Tip: …
        > [trust prompt visible]
  run_id=t-2026062023154800-a3f1 preserved
  cwd=/tmp/ham-wrapper-test-t-2026062023154800-a3f1
  tmux=ham-test-a3f1:smoke   (attach: `tmux attach -t ham-test-a3f1`)
  per-step pane snapshots: /tmp/.../pane-step-1.log … pane-step-5.log
FAIL  total 16.3s
```

**Exit codes**: `0` pass · `1` test step failed · `2` invocation error (bad flags, missing config file) · `3` environment error (tmux missing, cwd unwritable).

---

## Step-by-step

### Run-ID and isolation

Before step 1 runs, allocate a unique `run_id` of the form `t-<utc-timestamp>-<4-char-random>`. Derive:
- cwd: `/tmp/ham-wrapper-test-<run_id>/`
- tmux session: `ham-test-<random-suffix>`
- per-step pane log: `<cwd>/pane-step-N.log`

Pid is **not** used in any name — pid can collide on reuse; timestamp+random cannot.

### [1/7] Config parse + provider check
- `cfg_lib.load(path)` — exit code 2 on parse failure.
- Confirm a `[wrapper.agent-cmd.<provider>]` exists; on miss, list available cmds and exit 1.
- Confirm `command` non-empty (or wrapper-level fallback) and `starter_prompt` non-empty.
- **Templating dry-run**: expand the configured `starter_prompt` via `template_string` with placeholder values (any non-empty strings — the test never sends this prompt; just confirms templating doesn't crash and the result is non-empty). Catches malformed templates and `{unknown_placeholder}` typos early.
- Resolve tier via `resolve_model_value(agent_cmd.models, tier)`.
  - If `models.flag == ""`: warn, set `tier_skipped=true`. **If `--strict-tier`: fail step 1.**
  - If resolved value `== ""`: warn, set `tier_skipped=true`. **If `--strict-tier`: fail step 1.**
- Detail line: agent-cmd count, resolved model name (or `tier_skipped: reason`), templated starter_prompt length.

### [2/7] tmux available + functional
- Run `tmux -V`; capture stdout; non-zero exit → exit code 3 (environment).
- Round-trip test: create a one-off session `ham-test-probe-<random>`, send `pwd`, capture, kill. Confirms not just version but actual session management.
- Detail: parsed version + round-trip ms.

### [3/7] launch agent process (no starter prompt)
- `mkdir -p <cwd>`; `mkdir` failure → exit 3.
- Build argv: `[command..., yolo_flags..., models.flag, model_value]` (skip flag if tier_skipped).
- Open tmux session+window, launch via `tmux.ensure_agent_window`.
- **Stayed-up check**: snapshot pane immediately, wait 2.0s, snapshot again, check `pane_exists`. If pane vanished (process exited quickly): FAIL with the last 30 lines of pane output as the reason (almost always a CLI error like "unknown flag" or "auth required").
- Detail: pane id, resolved model, observed "stayed-up Ns".

### [4/7] restart with starter prompt
- `tmux.kill_pane(pane_id)` from step 3.
- Build argv again with a **hardcoded test starter prompt** appended as final positional arg. The configured `starter_prompt` from config.toml is **not** used here — it is daemon-coupled (instructs `agent-ready`, references `{token}`/`{daemon_url}`) and exercising it would conflate config testing with daemon-handshake testing, which is explicitly out of scope.

  Test starter prompt (fixed string):
  ```
  You are a test agent. Wait for a follow-up message; when you receive it, follow its instructions. Reply only with what the message asks for.
  ```

- This confirms the agent CLI accepts a positional prompt arg and the wrapper's argv construction is correct (the actual purpose of step 4). The configured `starter_prompt`'s validity was already checked in step 1 via the templating dry-run.
- Detail: new pane id, prompt char length.

### [5/7] startup detection
- Reuse `startup_probe_agent(agent_cmd.startup_detection, pane_id)` with bounded deadline (`startup_probe_seconds` from config, or `--step-timeout`, whichever is smaller).
- If `startup_detection.enabled == false`: skip with detail `disabled by config; ready_on_launch=%v`. Do not infer success — the rest of the test is still meaningful.
- During the poll: also check `pane_exists` every 500ms. If pane exits during startup detection, fail fast with the last 30 lines.
- On `startup_blocked` or `startup_failed`: print the reason_code + safe_diagnostic and proceed to step 6 anyway (soft fail; the agent may still respond). Only `pane_exited` is hard-fatal.
- Detail: which pattern matched and elapsed time, OR reason_code on soft fail.

### [6/7] echo handshake + send test prompt
- After a 1s settle (let post-startup output flush), generate a unique marker: `HAM_TEST_MARKER_<run_id>`.
- Send the test prompt as one line via `tmux.send_line`:
  ```
  Use your shell tool to run `touch test_file` in the current working directory. After the command succeeds, write exactly the line: HAM_TEST_MARKER_<run_id>
  ```
- Echo-poll the pane every 250ms for up to 5s: confirm the marker substring appears anywhere in the pane (proves send-keys landed in an input area, not into a dialog or menu).
- If marker not seen after 5s of polling, fail step 6 with "send-keys did not reach input area".
- Detail: elapsed seconds between send and first echo.

### [7/7] verify test_file created + DONE marker
- Two signals required for success:
  1. `<cwd>/test_file` exists AND is a regular file (`stat`-style check, not just exists).
  2. The pane has emitted a line containing exactly `HAM_TEST_MARKER_<run_id>` **after** the send timestamp (not just the echo from step 6 — the marker the agent itself produced as confirmation).
- Poll every 1s for up to 60s (`--timeout-step-7`). Each poll: snapshot pane, check file, check marker.
- **Tail watcher**: during the poll, scan new pane output for early-failure signals: lines matching `cannot create`, `permission denied`, `error:`, `I (do not|don't|cannot)`. On hit, fail step 7 fast with the matching line as the reason — saves 50s of waiting.
- Detail on success: file path + size + elapsed-to-DONE. On failure: which of the two signals is missing.

### Cleanup (always runs, success or failure)
- If `--keep=always`, or `--keep=on-failure` + last step failed: leave cwd and tmux session. Print attach instructions, cwd path, snapshot log paths.
- Otherwise: `tmux.kill_session(session_name)`, then `rm -rf <cwd>`.
- Signal trap: install SIGINT/SIGTERM handler at the top of the test command so Ctrl-C still runs cleanup. Otherwise abandoned tmux sessions accumulate.
- At start of each test run, also sweep `/tmp/ham-wrapper-test-t-*` directories older than 24h and matching tmux sessions older than 24h. Prevents disk creep from forgotten `--keep` runs.

---

## Per-step pane snapshots

At the entry of every step ≥ 3, snapshot the current pane to `<cwd>/pane-step-N.log`. On success the files exist but go unused (cleaned up unless `--keep`). On failure they are the primary diagnostic — the failure summary prints their paths and tails the failing step's snapshot.

This is cheaper than streaming logs and is the single change that makes failures debuggable without re-running.

---

## What this test covers (and what it doesn't)

**In scope** — wrapper-side configuration and launch mechanics:
- `config.toml` parses and contains the expected provider + tier
- Tier flag wires through to the agent argv correctly
- The agent CLI binary actually exists and accepts that argv
- tmux is functional on this host
- The agent's startup detection patterns match the agent's real output
- The agent CLI accepts a positional starter-prompt argument
- The agent reaches an input prompt and obeys a follow-up shell instruction

**Explicitly out of scope** — assumed to work, never validated:
- Whether the daemon is running, reachable, or correctly configured
- Whether `agent-ready` / `register` / `heartbeat` round-trips succeed
- Anything that lives in the daemon's agent_store, registry, or RPC handlers
- The behavior coded into the configured `starter_prompt` (templating is checked in step 1; full content is not exercised, because most of it is daemon handshake instructions)

The test deliberately does not contact the daemon, and the agent it spawns is never told a daemon URL or token. If you suspect a daemon problem, that's a different test (use the actual production launch path against a running daemon).

---

## Implementation notes

### Where it lives
- New file `src/wrapper/test_command.odin` (~300 lines).
- Entry: in `main.odin`, detect `os.args[1] == "test"` and dispatch to `run_test_command(os.args)` before the existing flag handling. `test` is a subcommand, not a flag.

### Reused code
- `cfg_lib.load` — config parsing.
- `tmux.ensure_agent_window`, `tmux.kill_pane`, `tmux.pane_exists`, `tmux.send_line`, `tmux.capture_pane_text` — present.
- `startup_probe_agent` — reuse verbatim.
- `template_string` — for starter prompt expansion (existing proc, no test-specific copy needed; the test just passes its placeholder values in).
- `resolve_model_value` — extract from `build_agent_command` into `cfg_lib` so both production and test paths share it.

### New helpers
- `tmux.version() -> (string, bool)`.
- `tmux.kill_session(name)`.
- `tmux.create_throwaway_session(name) -> bool` for the step-2 round-trip.
- A small `step_logger` struct that aligns columns, records start times, captures pane on entry, and formats success/failure lines uniformly.

### Anti-coupling
- The test path must not import any daemon package or `http_client`. Enforce by code review (Odin has no module visibility primitives to do this automatically).

### Concurrency
- Run-id randomness makes concurrent test invocations safe. No locking needed.

---

## Out of scope (deferred)

- **`ham-ctl report success` integration** — future post-step where the agent itself calls a CLI to attest success, replacing the file-existence check.
- **Matrix mode** — `--matrix` iterates all providers × all tiers.
- **Multiple test prompts** — today one fixed "create test_file"; later, a list of prompt-and-verifier pairs.
- **Hooks** — pre/post-step user-defined commands.
- **JSON output mode** — `--format json` for CI consumers.
- **Daemon-side test history** — POST results to daemon for a dashboard. Out of scope; the test deliberately doesn't talk to the daemon.

---

## Implementation order

1. **Subcommand dispatch + flag parsing + step_logger** — get the output shape and exit codes right first.
2. **Steps 1–2** — config + tmux. Validate `--strict-tier` works.
3. **Cleanup path + signal trap** — implement before step 3 so iteration doesn't leave junk behind.
4. **Steps 3–4** — process launch + restart with starter prompt. Verify the 2s stayed-up check catches a deliberately broken command.
5. **Step 5** — startup detection wrapper with pane-exit watchdog.
6. **Step 6** — echo handshake. Test by sending a marker and confirming echo polling works.
7. **Step 7** — file + marker dual signal with tail watcher for fast fail.
8. **`--keep` paths and failure summary** — print attach instructions and snapshot paths.
9. **Verify** — `nix build .#ham-wrapper`, run the test against pi/normal, claude/normal, and a deliberately broken config (e.g. unknown provider, missing model in models block) to confirm failures look sane.
