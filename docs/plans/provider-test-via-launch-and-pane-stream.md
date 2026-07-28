# Provider Testing via Real Agent Launch + Pane Frame Streaming — Plan

Status: Phase 1 implemented (real synchronous launch test + owner-scoped WS status/frame relay); routed test page, poll/cancel REST, and full pane viewer remain follow-up.
Scope: A provider "test" that launches a **real** agent through the normal
launch path, waits for the agent to report `start-success` via `ham-ctl`, tracks
`in_progress → passed/failed/timeout`, and streams captured tmux pane frames to
the UI for live rendering. Test-only, opt-in.
Related: `docs/plans/ui-onboarding-implementation-plan.md` (§3 provider store,
D1), `docs/plans/hub-bridge-runtime-protocol.md` (§9 commands, §10 events).

---

## 1. Rationale

The stubbed `test_provider` (§ui-onboarding 3.1) tried to invent a bespoke probe.
The most honest test is: **launch the provider the exact way a real instance is
launched, and see if the agent boots and calls
`ham-ctl agent start-success`.** If it does, the command/model/flags/starter
prompt/env are all correct — that is precisely the success condition we care
about. This plan replaces the bespoke probe with a real, bounded, observable
launch.

It also adds an **opt-in pane frame stream** so the operator can watch the agent
start in the UI (the runtime protocol forbids streaming raw transcripts *by
default*; this is an explicit, test-scoped, operator-initiated exception).

---

## 2. What exists today (ground truth)

- **Launch path works**: hub `launch_agent` → bridge `bridge_runtime_launch_agent`
  → `tmux.ensure_agent_window` creates a window and returns a `pane_id` → wrapper
  supervisor runs the resolved provider command
  (`bridge_runtime_shell_command_for_profile`) and injects
  `HEIMDALL_BRIDGE_ENDPOINT/AGENT_TOKEN/AGENT_INSTANCE_ID`.
- **start-success works**: agent runs `ham-ctl agent start-success` → bridge
  local endpoint → hub `/api/v1/agent-actions/start-success` →
  `mark_instance_start_success` sets `runtime_status=running,
  startup_status=ready`.
- **Bridge already tracks the pane id** per launch
  (`Bridge_Runtime_Launch.pane_id`), so `tmux capture-pane -t <pane_id> -p` is
  directly available.
- **`test_provider` is a stub** returning `status:"unknown"`.
- **User WS fanout exists** (`/api/v1/user-ws`) for pushing lightweight events to
  the UI.

---

## 3. Design overview

A provider test is a **throwaway agent instance** launched on the target bridge
with a dedicated `purpose = "provider_test"`, tracked by a **test session** with
a bounded lifetime, that:

1. resolves and launches the provider command (real launch path),
2. optionally starts a **pane frame capture loop** (test-only),
3. waits (bounded timeout) for that instance's `start-success`,
4. resolves to `passed | failed | timeout`, then **tears down** the throwaway
   instance (kill tmux window, delete the test instance record),
5. streams `test_status` + `pane_frame` events to the UI over the user WS.

Result semantics:

```
passed  = start-success received before timeout
failed  = process exited / launch error / wrapper reported startup_failed
timeout = no start-success within the deadline (process may still be alive → killed)
```

---

## 4. States and lifecycle

```
requested
  -> launching        (bridge accepted launch_agent for the test instance)
  -> in_progress      (wrapper reported "starting"/"ready"; awaiting start-success)
  -> passed | failed | timeout   (terminal)
  -> torn_down        (test instance killed + record removed; frames stop)
```

Timeouts (config, sensible defaults):
- `launch_deadline` (default 20s): bridge must accept + wrapper must report
  `starting` — else `failed` (bad command / binary not found).
- `start_success_deadline` (default 60s): from `starting` to `start-success`
  — else `timeout`.
- `hard_deadline` (default 90s): absolute cap; always tear down after this.

A test session is single-flight per (bridge, provider): starting a new test for
the same provider cancels/tears down the previous one.

---

## 5. Data model (Hub)

`ProviderTest` (ephemeral runtime record; may live in memory + a short-lived
row, not long-term durable):

```ts
ProviderTest {
  test_id: string            // ptest_...
  owner_user_id: string
  bridge_id: string
  provider: string
  tier: string               // resolved tier used for the test
  test_instance_id: string   // the throwaway agent_instance_id
  status: "requested" | "launching" | "in_progress" | "passed" | "failed" | "timeout" | "torn_down"
  message?: string
  started_at: string
  updated_at: string
  finished_at?: string
  capture_frames: boolean    // whether pane streaming is on
}
```

The throwaway instance is a normal `AgentInstance` flagged `purpose:"provider_test"`
so it is excluded from normal instance lists and auto-torn-down.

---

## 6. API (Hub REST, cookie-auth)

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/bridges/{id}/providers/{name}/test` | Start a test (replaces the stub). Body: `{ "tier"?: string, "capture_frames"?: bool, "launch_deadline_ms"?: number, "start_success_deadline_ms"?: number, "hard_deadline_ms"?: number, "frame_interval_ms"?: number }` (timeouts optional, see §15). Returns the `ProviderTest`. |
| GET | `/api/v1/provider-tests/{test_id}` | Poll test status (fallback to WS). |
| POST | `/api/v1/provider-tests/{test_id}/cancel` | Cancel + tear down. |

Start response `200`:
```json
{ "data": { "test_id": "ptest_1", "bridge_id": "brg_1", "provider": "pi", "tier": "normal",
            "status": "launching", "capture_frames": true, "started_at": "..." } }
```

Errors: `bridge_offline` (409) if the bridge WS is down; `not_found` (404) if the
provider/bridge is not owned by the caller; `validation_failed` (422) if the
provider has no runnable command.

---

## 7. Hub ↔ Bridge protocol additions (runtime protocol §9/§10)

### 7.1 `start_provider_test` (Hub → Bridge command)
```json
{
  "type": "start_provider_test",
  "protocol_version": 1,
  "command_id": "cmd_ptest_1",
  "payload": {
    "test_id": "ptest_1",
    "provider": "pi",
    "tier": "normal",
    "test_instance_id": "inst_test_1",
    "capture_frames": true,
    "frame_interval_ms": 500,
    "launch_deadline_ms": 20000,
    "start_success_deadline_ms": 60000,
    "hard_deadline_ms": 90000
  }
}
```
Bridge replies `command_result accepted`, then drives the launch + capture +
timers locally, emitting events (7.3/7.4). The bridge owns the timers so it can
tear down even if the Hub link blips.

### 7.2 `cancel_provider_test` (Hub → Bridge command)
```json
{ "type": "cancel_provider_test", "command_id": "cmd_ptest_cancel_1", "payload": { "test_id": "ptest_1" } }
```
Bridge kills the test window, stops capture, replies `command_result succeeded`.

### 7.3 `provider_test_status` (Bridge → Hub event)
```json
{
  "type": "provider_test_status",
  "protocol_version": 1,
  "payload": {
    "test_id": "ptest_1",
    "status": "in_progress",
    "phase": "starting",           // launching|starting|awaiting_start_success|done
    "message": "wrapper reported starting",
    "at": "..."
  }
}
```
Terminal statuses `passed|failed|timeout` include a `message` and, on failure, a
bounded sanitized `diagnostics` string (last N lines of pane, redacted).

### 7.4 `provider_test_frame` (Bridge → Hub event, test-only)
```json
{
  "type": "provider_test_frame",
  "protocol_version": 1,
  "payload": {
    "test_id": "ptest_1",
    "seq": 12,                     // monotonic per test
    "at": "...",
    "rows": 40,
    "cols": 120,
    "format": "ansi",             // raw `tmux capture-pane -e -p` output (ANSI preserved)
    "content": "<escaped pane snapshot>"
  }
}
```
- The Bridge runs `tmux capture-pane -t <pane_id> -p -e` every `frame_interval_ms`
  and emits a frame **only if the content changed** (dedupe on hash) to bound
  volume.
- Frames are **bounded**: max size per frame, max frames per test; capture stops
  at terminal status or `hard_deadline`.
- Capture is **only** enabled when `capture_frames=true` (operator opt-in). This
  is the explicit exception to "no raw transcript streaming by default"; it is
  test-scoped, time-bounded, and torn down.

### 7.5 Offline behavior
All three commands are `fail_if_offline` (no durable queue). A bridge that goes
offline mid-test → Hub marks the test `failed` (bridge lost) after the WS drops.

---

## 8. Bridge implementation

1. **`start_provider_test`** handler:
   - resolve provider profile + tier → argv (reuse
     `bridge_runtime_shell_command_for_profile`); if empty command →
     `provider_test_status failed` immediately.
   - launch via the **normal** path into a **dedicated test window**
     (`session=heimdall-bridge-test`, `window=ptest-<test_id>`), capture `pane_id`.
   - start three timers (launch/start-success/hard) and, if `capture_frames`, a
     capture loop thread.
   - map wrapper signals: `starting`→phase starting; `startup_failed`→failed;
     `exited` before start-success→failed.
2. **start-success correlation**: the test instance's `start-success` (already
   flowing to the Hub) is the pass signal. The Hub tells the Bridge, or the
   Bridge learns via its own local endpoint that the test instance reported
   start-success (the local endpoint sees `agent.start_success` for that
   `agent_instance_id`) → emit `passed`.
3. **Teardown** on any terminal status or cancel: stop capture loop, `tmux
   kill-window`, drop the launch record, emit final `provider_test_status`.
4. **Resource caps**: one active test per provider; global cap on concurrent
   tests; frame size/rate caps.

### 8.1 tmux capture
`tmux capture-pane -t <pane_id> -p -e` (or `-pJ` to join wrapped lines). `-e`
preserves ANSI SGR so the UI can render color. Diff against last frame hash;
skip unchanged.

---

## 9. Hub implementation

- **Replace** `test_bridge_provider_handler` to create a `ProviderTest`, create
  the throwaway `test_instance_id` (purpose=provider_test, excluded from normal
  lists), send `start_provider_test`, and return the record.
- **Consume** `provider_test_status` / `provider_test_frame` from the bridge WS;
  update the `ProviderTest` and **fan out to the owner's user WS** as
  `provider_test_status` / `provider_test_frame` events (owner-scoped).
- On terminal status: persist `last_test` onto the provider view (so the
  Providers list shows the ✓/✗ + time), then send `cancel_provider_test`/teardown
  to remove the throwaway instance.
- Enforce owner scoping: frames/status for a test only go to the owning user's WS.

---

## 10. UI implementation

### 10.0 Routing (consistent with onboarding §3.8 N2: big surfaces are routed pages)

- **Test is a routed page**, not a modal, since it hosts a live pane viewer:
  `/settings/providers/{name}/test`.
- Reached from a **Test** button on the provider row (`/settings/providers`) and
  from the provider editor page (`/settings/providers/{name}/edit`).
- Breadcrumb (per §3.8 N3): `Settings / Providers / {name} / Test`.
- The test page reads `{name}` from the route and the active bridge from the
  Providers surface's selected bridge (carry `bridgeId` via route/query if
  needed). On start it calls `POST /api/v1/bridges/{bridgeId}/providers/{name}/test`.
- Advanced controls on the page expose the optional **timeouts** (§15:
  launch/start-success/hard deadlines, frame interval) with the built-in
  defaults prefilled, plus the **capture-screen** toggle (default on).

### 10.1 Test page contents

- **Test** button → `POST .../test` (with capture toggle + optional timeout
  overrides).
- **Test panel**:
  - status pill: `launching → in progress → passed/failed/timeout` with a spinner
    and elapsed timer counting toward the deadline.
  - **Pane viewer**: renders `provider_test_frame` content. Since frames are full
    snapshots (ANSI), render the latest frame in a terminal-style `<pre>` with an
    ANSI-to-HTML converter; keep a small ring buffer so the operator can scrub
    recent frames (frame `seq` as the timeline) — "render as frames".
  - on `passed`: green ✓ + "agent booted and reported start-success in Xs".
  - on `failed/timeout`: red ✗ + the sanitized `diagnostics` tail.
  - **Cancel** button → `POST .../cancel`.
- Subscribes to the user WS `provider_test_status` / `provider_test_frame` events
  (test_id filter). Falls back to `GET /provider-tests/{id}` polling if WS drops.
- Debug ids: `provider-test-page`, `provider-test-start-btn`,
  `provider-test-capture-toggle`, `provider-test-launch-deadline-input`,
  `provider-test-start-success-deadline-input`, `provider-test-hard-deadline-input`,
  `provider-test-frame-interval-input`, `provider-test-status`,
  `provider-test-elapsed`, `provider-test-pane`, `provider-test-frame-scrubber`,
  `provider-test-cancel-btn`, `provider-test-diagnostics`,
  `provider-test-result-${status}`. Providers-list entry: `providers-test-btn-${name}`.

---

## 11. Frame rendering approach (UI detail)

- Each `provider_test_frame.content` is a **full pane snapshot** (not a diff), so
  rendering is stateless per frame: convert ANSI → styled spans, drop into a
  fixed rows×cols `<pre>`.
- Keep the last K frames (e.g. 60) in a client ring buffer keyed by `seq`; a
  slider scrubs them; "live" pins to the latest. This gives a frame-by-frame
  playback of the agent starting without ever storing an unbounded transcript.
- No persistence of frames server-side beyond the in-flight test; on teardown the
  buffer is cleared.

---

## 12. Safety / invariants

- Capture is **opt-in, test-only, time-bounded, owner-scoped**, and torn down —
  consistent with the protocol's "no raw transcript streaming by default".
- Diagnostics on failure are **sanitized + bounded** (last N lines), matching
  `agent_instance_log_summary` discipline.
- The throwaway test instance never joins a real chain/conversation and is always
  removed; it must not leak into agent/instance lists.
- All test commands are `fail_if_offline`; offline mid-test → `failed`.
- One active test per (bridge, provider); global concurrency + frame-rate caps.

---

## 13. Build order

1. **DONE — Bridge real-launch test on existing `test_provider` relay** — reuses the wrapper-supervisor launch path, dedicated `heimdall-bridge-test` tmux session/window, bridge-local start-success correlation, timeout/fail/pass teardown, one active test per provider, bounded diagnostics, and optional change-only pane snapshots. Phase commit: `39577ad`.
2. **DONE — Hub owner-scoped status/frame relay** — existing provider-test REST route now waits for the final bridge command result; bridge WS consumes `provider_test_status` / `provider_test_frame` and fans out raw events to the owning user's `/user-ws`. Phase commit: `39577ad`.
3. **DONE — UI provider list result semantics** — existing Providers row test button renders `passed`/`timeout` in addition to legacy `ok`/`failed`. Phase commit: `39577ad`.
4. Follow-up: add first-class `start_provider_test` / `cancel_provider_test` command names and `GET/POST /provider-tests/{id}` poll/cancel REST records.
5. Follow-up: routed `/settings/providers/{name}/test` page with advanced timeout/capture controls, pane viewer, frame scrubber, and cancel button.
6. Follow-up: persist/display Bridge `last_test` in provider profile reports.

Steps 1–3 deliver a working real-launch test through the existing Providers list button; 4–6 add the fully routed visual test surface.

---

## 14. Resolved decisions

- D1 — **Pass detection is bridge-local.** When the bridge's local endpoint sees
  `agent.start_success` for the test instance, the bridge immediately resolves
  the test `passed` and emits `provider_test_status passed`. It does not wait for
  a Hub round-trip. (The Hub still updates its `ProviderTest` from that event.)
- D2 — **Frames go over the bridge WS** with strict size/rate caps (no side
  channel).
- D3 — **Test never changes provider `enabled`.** A `passed` result updates
  `last_test` only; enabling stays an explicit user action.

## 15. Configurable timeouts

All three deadlines are **configurable**, not hardcoded, resolved most-specific
wins:

```
deadline = request override (test API body)
       ?? bridge config (config.toml [bridge.provider_test])
       ?? built-in default
```

- Built-in defaults: `launch_deadline_ms=20000`,
  `start_success_deadline_ms=60000`, `hard_deadline_ms=90000`,
  `frame_interval_ms=500`.
- The test API body (§6) accepts optional `launch_deadline_ms`,
  `start_success_deadline_ms`, `hard_deadline_ms`, `frame_interval_ms`.
- The bridge reads `[bridge.provider_test]` overrides from `config.toml` for
  machine-level defaults.
- The Hub passes the resolved values in `start_provider_test` (§7.1); the Bridge
  owns the timers using those values. Invalid/absent values fall back to the next
  level. Enforce sane bounds (e.g. hard cap max 300s, frame_interval min 200ms).
