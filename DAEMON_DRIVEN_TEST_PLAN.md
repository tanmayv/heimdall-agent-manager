# Daemon-Driven Provider/Tier Test Plan

## Goal

Let the UI trigger a smoke test of a `provider + tier` combination through the daemon. The daemon spawns a wrapper, gives it a temporary test token, hands it a starter prompt that instructs the agent to call `ham-ctl … start-success`, and observes whether that call arrives within the deadline.

**Success criterion is intentionally minimal: agent calls `ham-ctl … start-success` once.** No file creation, no echo handshake, no marker — the inbound RPC is the validation. If the daemon receives `start_success` for the test token, the full pipeline (config → wrapper spawn → tmux launch → agent CLI exec → tier flag honored → agent reads prompt → agent runs shell → ham-ctl reaches daemon) has worked. Anything more is the wrapper-only test's job.

**Test agents are ephemeral.** They never touch the persistent agent_store event log, never appear in the canonical `agents/list` UI, and are cleaned up (tmux window killed, run_dir removed, in-memory record dropped) after the run finishes — success, failure, or timeout.

This complements `ham-wrapper test` (the no-daemon, file-creation-based smoke). Use the wrapper-only test for local config debugging without infrastructure; use this daemon-driven test for "does my provider configuration actually work in our real deployment, end to end."

---

## What the UI sends

```http
POST /agents/test-launch
{
  "provider": "claude",
  "tier": "smart",
  "config_path": ""   // optional; defaults to daemon's server_config_path
}
```

The daemon does everything else. The UI's only inputs are provider and tier; the test framework handles run_id, token, run_dir, prompt, and cleanup.

Response (synchronous, sent before the wrapper finishes):
```json
{
  "ok": true,
  "test_run_id": "tr-2026062100345200-9f1c",
  "test_agent_instance_id": "test-claude-9f1c",
  "result_endpoint": "/agents/test-status?test_run_id=tr-..."
}
```

The UI then polls `result_endpoint` (or subscribes to lifecycle events filtered by `test_run_id`) until terminal state.

---

## Daemon-side flow

```
UI POST /agents/test-launch  (provider, tier)
            │
            ▼
  Validate provider exists in config; resolve tier value.
  If invalid: 400, no test record created.
            │
            ▼
  Allocate test_run_id = "tr-<utc-ts>-<4-char-random>"
  Allocate test_token  = "agt_test_<random>"
  Allocate test_agent_instance_id = "test-<provider>-<short_id>"
  Allocate test_run_dir = "/tmp/ham-daemon-test/<test_run_id>/"
            │
            ▼
  Create in-memory Test_Run record (status = launching)
  Add token to pending_agent_tokens AS A TEST TOKEN (flagged)
            │
            ▼
  Spawn wrapper: ham-wrapper --config <p> --agent <provider>
                              --tier <tier>
                              --agent-token <test_token>
                              --display-name test-<short_id>
                              <test_agent_instance_id>
  (wrapper log → <test_run_dir>/wrapper.log)
            │
            ▼
  Return 200 to UI with test_run_id and result_endpoint
  (UI now polls; daemon's job continues async)
            │
            ▼
  Wrapper registers via /register → daemon recognizes token as test token →
  routes registration into the Test_Run record, NOT into agent_store events
  status = starting
            │
            ▼
  Agent reads its starter prompt (test-specific, see below) and runs
  ham-ctl … start-success → arrives at daemon's /agent-rpc as action="start_success"
            │
            ▼
  Daemon validates the token is a test token tied to this Test_Run,
  marks status = success, captures elapsed time + last pane snapshot
            │
            ▼
  Daemon initiates wrapper teardown (kill tmux window, remove pending token,
  send wrapper a stop signal — wrapper exits)
            │
            ▼
  Test_Run stays in memory (status = success) until reaped (1h TTL)
```

If the agent never calls `start-success` before `--timeout` (default 90s), the daemon transitions the Test_Run to `timed_out` and tears the wrapper down anyway.

---

## In-memory test record

```odin
Test_Run :: struct {
    test_run_id:               string,    // "tr-<ts>-<rand>"
    provider:                  string,
    tier:                      string,
    resolved_model:            string,    // for visibility
    test_agent_instance_id:    string,
    test_token:                string,
    run_dir:                   string,
    status:                    string,    // launching | starting | running | success | failed | timed_out
    reason:                    string,    // human-readable detail on failure
    pane_tail:                 string,    // last 40 lines on terminal state
    started_unix_ms:           i64,
    last_event_unix_ms:        i64,
    completed_unix_ms:         i64,
    wrapper_log_path:          string,
}

test_runs:        [MAX_TEST_RUNS]Test_Run   // ring buffer, ~32 entries
test_run_count:   int
```

`MAX_TEST_RUNS` = 32 (keeps recent history visible in UI). Oldest entry evicted on overflow. After 1h, completed entries are wiped via a janitor sweep.

`Test_Run` lives **only in this array**. There is no event sourced into the agent_store WAL, no `Agent_Instance_Event` emitted, no `agent_instance_records` entry. The lifecycle WS events for a test run carry a `test_run_id` field so the UI can route them to the test panel without polluting the agent list.

---

## Test agent identity vs production agent identity

| Aspect | Production | Test |
|---|---|---|
| `agent_instance_id` format | `<class>@<suffix>` (user-chosen) | `test-<provider>-<short_id>` (daemon-allocated) |
| `agent_token` prefix | `agt_` | `agt_test_` |
| Lives in `agent_instance_records` (WAL-backed) | yes | no |
| Lives in `pending_agent_tokens` | yes (transient) | yes (transient, with `is_test=true` flag) |
| Appears in `agents/list` | yes | no (filtered out by token prefix or `is_test` flag) |
| Appears in `agents/test-status` | no | yes |
| WS lifecycle event payload includes `test_run_id` | no | yes |
| Bootstrap files written | yes (full set) | no (test starter prompt doesn't need them) |

The token prefix `agt_test_` is the cheapest way to distinguish across all daemon code paths. Add a single helper:

```odin
is_test_token :: proc(token: string) -> bool {
    return strings.has_prefix(token, "agt_test_")
}
```

Anywhere the daemon writes to `agent_store_append_event` or filters `agents/list`, check this helper first.

---

## Test starter prompt

Daemon constructs a fixed test prompt (does NOT use the configured `starter_prompt` — that one is daemon-coupled in production but designed for a real working session, not a one-shot test):

```
You are a Heimdall test agent. Your only task:

Run exactly this command:
~/heimdall/bin/<CTL_SYSTEM>/ham-ctl --config <config_path> --token <test_token> start-success

If the command exits 0, you're done — say "TEST OK" and stop.
If it errors, print the error verbatim and stop.

Do not perform any other action. Do not write files. Do not read files.
```

The wrapper substitutes `<CTL_SYSTEM>`, `<config_path>`, and `<test_token>` the same way it substitutes `{ctl_bin}` and `{token}` today, then passes this as the agent's positional prompt arg.

Reasoning: the test is validating "can the daemon spawn a wrapper that launches an agent CLI with the right tier that successfully executes a CLI call back to the daemon." A test-specific prompt makes the success criterion crisp (one command exits cleanly) and the failure surface small (no file IO, no model token economy waste).

---

## `start-success` RPC

New action in `/agent-rpc`, alongside the existing `agent_ready`:

```
POST /agent-rpc
{"agent_token": "agt_test_...", "action": "start_success"}
```

Handler (`handle_start_success`):
1. Look up the token in `pending_agent_tokens`. Reject 401 if unknown.
2. Verify it's a test token (`is_test_token`). If not, reject 400 — `start-success` is test-only.
3. Find the matching `Test_Run` by `test_token`. Reject 404 if no matching run (e.g. already timed out and reaped).
4. If status is already terminal (`success`, `failed`, `timed_out`): return `{"ok":true,"already":true}`.
5. Set `status = success`, `completed_unix_ms = now`, capture `pane_tail` from the wrapper's tmux pane (if accessible via stored pane_id) or wrapper.log tail.
6. Emit lifecycle event with `test_run_id` so UI updates immediately.
7. Schedule wrapper teardown (kill tmux window, drop pending token).
8. Respond `{"ok":true,"test_run_id":"...","status":"success"}`.

CLI command in ham-ctl mirrors `agent-ready`:

```
ham-ctl --config <path> --token <agent_token> start-success
```

Exits 0 on success, non-zero on any failure.

---

## Result polling vs streaming

**Polling** (simpler, picked for v1):
```
GET /agents/test-status?test_run_id=tr-...
→ 200 with full Test_Run JSON
```
UI polls every 1s until `status` ∈ {`success`, `failed`, `timed_out`}.

**Streaming** (REQUIRED for this feature, not optional): the daemon emits two new WS event types so the UI updates without polling:

```json
{ "type": "test_start", "test_run_id": "tr-...", "provider": "claude", "tier": "smart",
  "resolved_model": "claude-opus-4-7", "started_unix_ms": 1750000000000 }
```

```json
{ "type": "test_done", "test_run_id": "tr-...", "status": "success",
  "reason": "", "elapsed_ms": 4831, "pane_tail": "..." }
```

- `test_start` is broadcast immediately after the wrapper is spawned and the Test_Run is allocated (before the HTTP response returns, so the UI can render the in-flight state even if the POST round-trip is slow).
- `test_done` is broadcast once on any terminal transition (`success` | `failed` | `timed_out`). Status field carries the outcome; `reason` is populated for non-success.
- Both ride the existing WS connection; the UI subscribes once and routes by `type` + `test_run_id`.

Polling (`GET /agents/test-status`) remains as a fallback for clients without WS and for history reloads after page refresh.

History endpoint for the test panel:
```
GET /agents/test-history   →   { runs: [ ...last 32 entries... ] }
```

---

## Failure modes and the daemon's responses

| Trigger | Test_Run status | Reason |
|---|---|---|
| Provider not in config | (no run created) | 400 to UI before allocation |
| Tier requested but unconfigured (strict-tier semantics) | (no run created) | 400 to UI before allocation |
| Wrapper spawn fails (binary missing, fork error) | `failed` | "wrapper spawn failed: <stderr tail>" |
| Wrapper exits before `start-success` | `failed` | "wrapper exited unexpectedly; log: <tail>" |
| Agent never calls `start-success` within deadline | `timed_out` | "no start-success received in <Ns>" |
| Agent calls `start-success` with valid test token | `success` | (none) |
| Agent calls `start-success` from a non-test token | rejected | 400 on the RPC itself; doesn't change Test_Run state |
| Daemon restarts mid-test | `failed` on next status check | "daemon restarted during test" (Test_Run is in-memory; janitor seeds with `failed` for any orphan tmux windows matching `ham-test-*` on startup) |

Default deadline: 90s. Configurable later via `--timeout` in the POST body.

---

## Cleanup

When `Test_Run` reaches a terminal state (success | failed | timed_out):
1. Send SIGTERM to the wrapper process (if PID is recorded).
2. `tmux kill-window -t <session>:<window>` for the test agent's window.
3. Remove the token from `pending_agent_tokens`.
4. `rm -rf <run_dir>` (test-specific path under `/tmp/ham-daemon-test/`).
5. Test_Run stays in memory with `pane_tail` populated for UI history; reaped after 1h or on overflow (ring-buffer).

Crash-safe cleanup:
- On daemon startup, sweep tmux sessions matching `ham-test-*` and kill any older than 5 minutes (orphaned by a prior daemon crash).
- Sweep `/tmp/ham-daemon-test/` for entries older than 24h.

---

## Wrapper-side changes

Minimal — almost nothing. The wrapper already accepts:
- `--config`, `--agent`, `--tier`, `--agent-token`, `--display-name`, positional agent_instance_id

The daemon spawn line in `launch_wrapper_detached` (`src/daemon/agents_start.odin`) is already the model. Add a sibling `launch_wrapper_for_test` that:
- Uses the test run_dir as cwd
- Logs to the test wrapper.log
- Passes the test token, test instance id
- Does NOT need any new wrapper flag — wrapper behaves identically

The wrapper's normal bootstrap-file generation will fire. To avoid bootstrap files for test agents (they're not needed and pollute the run_dir), either:
- (preferred) **Wrapper checks token prefix `agt_test_` and skips `generate_bootstrap_files`.** Single-line guard.
- (alternative) Pass a `--no-bootstrap` flag from the daemon, wrapper honors it.

Pick option (a) — `is_test_token` is reusable in the wrapper too; keeps the spawn line clean.

Similarly, the wrapper's heartbeat loop should detect that the agent pane has exited (which it does today) and terminate. After `start-success`, the daemon kills the tmux window, the pane dies, the wrapper sees it gone and exits. No new wrapper-side code path needed.

---

## UI changes

### "Test provider" panel
- A new section on `AgentsPage` (preferred — same page where users configure providers) with:
  - Provider dropdown (populated from existing config the UI already has)
  - Tier radio (cheap/normal/smart)
  - "Run test" button
- On click: POST `/agents/test-launch`, store the returned `test_run_id`.
- **Live state via WS events** — UI listens for `test_start` and `test_done` events matching its `test_run_id` and updates the row in place. No polling needed in the happy path.
- Live state line: `launching → success | failed | timed_out` with elapsed time computed from `started_unix_ms`.
- On `test_done`: show result badge (green check / red x / yellow clock) + a collapsible "pane output" section showing `pane_tail` from the event payload.
- Concurrent runs allowed — UI shows one row per active test_run_id.

### Test history
- A second card listing the last 32 `Test_Run`s from `/agents/test-history`.
- Columns: when, provider, tier, status, elapsed, expand-for-pane-tail.

### Filter test agents out of regular UI
- `chatSlice.mapAgent` and `mergeKnownAndLiveAgents` already operate on what the daemon returns. Daemon must filter test agents out of `agents/list` and `agents/known` (check `is_test_token` on the registry record or skip records whose agent_instance_id starts with `test-`). UI needs no change once daemon filters correctly.

---

## Comparison with `ham-wrapper test` (no-daemon)

| Aspect | `ham-wrapper test` | This (`agents/test-launch`) |
|---|---|---|
| Daemon required | no | yes |
| Trigger | CLI | UI + CLI |
| Success signal | file creation in cwd | RPC from agent back to daemon |
| Real bootstrap files | no | no (skipped via `agt_test_` check) |
| Real starter_prompt from config | no (hardcoded test prompt) | no (hardcoded test prompt) |
| Real registration round-trip | no | yes (full register/ws/heartbeat) |
| Test record persistence | none | in-memory, 1h TTL, ring-buffer of 32 |
| What it actually validates | config + tier + tmux + agent CLI + startup detection + send-keys round-trip | all of the above + daemon spawn pipeline + register handshake + RPC token validation |

Keep both. They are different layers of confidence.

---

## Implementation order

1. **Daemon: `Test_Run` record + ring buffer + `is_test_token` helper.** Pure in-memory plumbing.
2. **Daemon: token-prefix filters in `agent_store_append_event`, `agents/list`, `agents/known`, `agent_lifecycle_emit`.** Verify test agents are invisible to production paths.
3. **Daemon: `handle_start_success` RPC handler.** Mirrors `handle_agent_ready` but updates the Test_Run, not the production agent record.
4. **Daemon: `handle_agents_test_launch` HTTP handler.** Allocates IDs, spawns wrapper, returns Test_Run handle.
5. **Daemon: `handle_agents_test_status` and `handle_agents_test_history`.** Simple read endpoints over the ring buffer.
6. **Daemon: timeout janitor.** Loops every 5s, flips overdue runs to `timed_out`, runs cleanup.
7. **Daemon: startup sweep** of orphan `ham-test-*` tmux sessions and stale `/tmp/ham-daemon-test/` dirs.
8. **Wrapper: `is_test_token` guard** in `generate_bootstrap_files` and anywhere else bootstrap-only state is touched.
9. **ham-ctl: `start-success` command.** Trivial copy of `agent-ready` with action name swapped.
10. **Daemon: emit `test_start` and `test_done` WS events** on the existing client WS broadcast channel. These are the primary UI signals.
11. **UI: TestPanel section in AgentsPage** with launch form, live state driven by `test_start` / `test_done` WS events, and history list (populated from `/agents/test-history` on mount).
12. **Verify**: spin up daemon + electron UI, click "Run test" for `pi/normal` and a deliberately broken `claude/smart` (with `smart=""`), confirm UI sees `test_start` immediately and `test_done` on completion without polling; agent_store WAL untouched, `/agents/list` doesn't show the test instance, history endpoint returns the runs.

---

## Out of scope (deferred)

- Persisting test history across daemon restarts (current design: in-memory ring buffer only). Add when needed.
- Scheduling recurring tests (cron-style "test claude/smart every hour").
- Multi-step test prompts (today: single command, single success signal).
- Cost/latency telemetry per tier (would belong here once the basic test works).
- `start-failure` companion RPC for the agent to self-report failure. Today: no signal → `timed_out`. Future: explicit failure signal with reason.
