# Robust Task/Message/Nudge Delivery Audit

Date: 2026-06-29  
Task: `task-19f148cea3c`  
Scope clarification: recommendations in this document are tied to observed behavior, logs, code path analysis, or runnable repro commands. No implementation changes are proposed solely from code inspection.

## Executive summary

A controlled local repro found a concrete restart-loss failure mode for task/nudge delivery:

- Offline task notifications are queued in memory and replayed on agent WebSocket reconnect when the daemon stays up.
- If the daemon restarts before the agent reconnects, the in-memory pending notification queue is lost.
- In the same restart scenario, task state is recovered from SQLite, but task event/log history (`Task_Nudged`) is not recovered because the current task SQLite schema stores projected state tables, not an event journal.
- Therefore an agent can miss an important nudge/task notification across daemon restart, and the daemon lacks durable event history needed to replay or audit that missed notification.

This makes the highest-priority hardening target a durable notification/event outbox or durable task event journal with per-recipient replay cursors.

## Safe repro methodology

### Command

Safe to run: uses temporary data directories and localhost test ports (`49410`, `49411`) and removes temp data unless `KEEP_HEIMDALL_TEST_TMP=1` is set.

```bash
cd /Users/tanmayvijay/heimdall-agent-manager
nix build .#ham-daemon .#ham-wrapper .#ham-ctl
python3 tests/repro_delivery_restart_loss.py
```

### What the repro does

`tests/repro_delivery_restart_loss.py` runs two isolated scenarios:

1. **Baseline no restart**
   - Start isolated daemon.
   - Register a synthetic user and agent.
   - Create a chain/task for the agent.
   - Connect the agent WebSocket once to drain the initial queued `Task_Created` notification.
   - Disconnect the agent.
   - Send a `Task_Nudged` event while the agent is offline.
   - Reconnect the agent and assert the queued `Task_Nudged` frame is delivered.

2. **Restart before reconnect**
   - Same setup and offline nudge.
   - Restart the daemon before the agent reconnects.
   - Re-register the same synthetic agent.
   - Reconnect the agent and observe no queued `Task_Nudged` frame.
   - Confirm task state still exists after restart, but task log contains no `Task_Nudged` event.

### Observed output

Last run output:

```json
{
  "baseline_no_restart": {
    "delivered_on_reconnect": true,
    "drained_before_nudge": ["Task_Created"],
    "restart_before_reconnect": false,
    "task_log_nudge_events_after_reconnect": 1,
    "task_state_recovered_after_restart": true,
    "ws_events": ["Task_Nudged"],
    "ws_frame_count": 1
  },
  "restart_before_reconnect": {
    "delivered_on_reconnect": false,
    "drained_before_nudge": ["Task_Created"],
    "restart_before_reconnect": true,
    "task_log_nudge_events_after_reconnect": 0,
    "task_state_recovered_after_restart": true,
    "ws_events": [],
    "ws_frame_count": 0
  }
}
DELIVERY RESTART REPRO OBSERVED EXPECTED LOSS
```

### Log/code evidence for the root cause

With `KEEP_HEIMDALL_TEST_TMP=1`, the restart-case daemon log showed:

- Before restart: `Task_Nudged` was accepted and notification enqueue attempted.
- Log line: `WARNING: failed to send WS to agent ... Queued notification.`
- After restart: agent WebSocket connected, but no queued nudge frame was delivered.
- `/tasks/log` after restart returned `{"ok":true,"events":[]}` for the task.

Code paths:

- `src/daemon/task_notifications.odin`
  - `pending_notifications` is a process-memory dynamic array.
  - `task_notify_recipient` appends to `pending_notifications` on failed WS send.
  - `task_notifications_flush_queue` flushes only that in-memory queue on `/ws` reconnect.
- `src/daemon/ws.odin`
  - `handle_ws` calls `task_notifications_flush_queue(agent_instance_id)` after WebSocket upgrade.
  - There is no durable read from a persisted outbox on reconnect.
- `src/daemon/task_store.odin`
  - `task_store_append_event` applies events to in-memory event history and persists only the projected relational state via `task_store_persist_projection_for_event`.
  - `Task_Nudged` has no durable projection table case; after restart it is not present in `task_events` memory.
- `src/daemon/task_db_service.odin` / observed SQLite schema
  - Tables include `tasks`, `task_chains`, `task_comments`, `task_lgtm_votes`, `task_participants`.
  - There is no `task_events` table in the observed DB.

## Durability matrix

| Item | Current persistence | Restart behavior observed/derived | Evidence |
| --- | --- | --- | --- |
| Task state (`tasks`, chains, participants, comments, votes) | SQLite projected tables | Recovered after restart | Repro: `task_state_recovered_after_restart: true`; schema inspection of `task.db` |
| Task event log (`Task_Nudged`, status events, created events as events) | In-memory `task_events`; legacy JSONL migrated away/removed | Not recovered after restart in SQLite path | Repro: `task_log_nudge_events_after_reconnect: 0`; no `task_events` table |
| Offline task notification queue | In-memory `pending_notifications` | Lost on daemon restart | Repro: baseline delivered, restart did not; `task_notifications.odin` |
| Agent WebSocket live notification | Best-effort WS send | Lost if send fails unless process-memory queue survives | `registry_send_ws_text`; `task_notify_recipient` |
| User/agent chat messages | SQLite `messages` table | Durable; fetchable after restart | `chat_store.odin`, `message_db_service.odin`; previous task `test_user_inbox_offline_send.py` validated offline user inbox |
| Chat delivery status (`delivered`, `delivery_failed`) | SQLite columns on `messages` | Durable metadata | `chat_store_append_event`, `message_db_update_delivery_failed` |
| Wrapper missed task/nudge recovery | Live WS only plus startup bootstrap instructions | No durable replay of missed task notifications observed | `wrapper/main.odin` handles WS `task_event`; no task event catch-up query on reconnect |
| UI WebSocket reconnect | Re-registers/refetches snapshots in App | Snapshot refresh can recover current task/agent state, but not missed event notification history | `src/ui/components/App.tsx` reconnect effects |

## Current-state analysis

### Task and nudge events

Task state is durable as a projection, but task events are not durably journaled in the current SQLite path. This is visible in `task_store_append_event`: events are applied to in-memory `task_events`, then selected projection tables are persisted. `Task_Nudged` returns `true` from `task_store_persist_projection_for_event` without writing a durable nudge/event row.

Impact observed:

- If the daemon remains alive, pending offline task notification replay works.
- If the daemon restarts before replay, the notification queue and task event history vanish.
- The task still exists, so a polling/snapshot UI may show current state, but an agent pane relying on WS notifications can miss the nudge/start/update.

### Chat/user messages

Chat messages are more robust than task notifications:

- `chat_store_append_message` persists messages into SQLite via `message_db_insert`.
- `chat_append_agent_to_user` records `Delivery_Failed` metadata when no user websocket is present.
- Previous validation (`tests/test_user_inbox_offline_send.py`) showed agent-to-user messages can persist while UI is offline and be fetched later.

Caveat: the live WS notification that a message is available remains best-effort. However, because the message itself is durable and fetch APIs exist, missed notifications are recoverable if clients poll/fetch on reconnect.

### Wrapper reconnect behavior

The wrapper receives task events only over WS (`handle_task_event` in `src/wrapper/main.odin`). It handles reconnect/token refresh but does not query a durable task-event outbox or "what changed since cursor" endpoint. Therefore, even if a task remains queued/in-progress after a missed notification, the wrapper may not surface that event unless a new WS notification occurs or the agent manually runs `tasks next`/`inbox`.

### Overload / chatty update risks

Observed code paths fan out broadly:

- `task_notify_event` fans out task payloads to all UI websocket clients via `user_client_fanout_all_ws_text(payload)` for every task event.
- It also sends recipient-specific WS messages to agents through `task_notify_by_status` / `task_notify_recipient`.
- UI `App.tsx` refreshes snapshots on reconnect and on visibility changes, and task events may trigger `refreshTaskBoard()` when payload lacks embedded task/chain.

No overload failure was reproduced in this pass beyond the restart-loss repro. Treat overload as a risk supported by code path analysis, not yet an observed failure.

## Prioritized recommendations tied to evidence

### Immediate / minimal hardening

1. **Persist a task notification outbox before WS send**
   - Evidence: in-memory `pending_notifications` is lost on restart; repro proves missed nudge after restart.
   - Minimal design: table keyed by `(recipient_agent_instance_id, event_id)` with payload, created time, delivered/acked time.
   - On `task_notify_recipient`, insert pending row before attempting WS.
   - On agent WS connect, replay undelivered rows for that recipient.
   - Mark delivered after successful WS send, or better after wrapper ACK.

2. **Persist task event journal rows, at least for notification-relevant events**
   - Evidence: task log empty after restart even though task state recovered; no `task_events` table.
   - Minimal design: append `task_events` table with event_id/kind/task_id/chain_id/status/body/author/created/interrupt.
   - Rebuild `task_events` memory from this table on startup, or make task-log query use the table directly.

3. **Add wrapper reconnect catch-up**
   - Evidence: wrapper only handles live WS `task_event`; if daemon restart drops pending queue, no catch-up occurs.
   - Minimal design after event/outbox exists: wrapper sends last-seen event cursor/ACK, daemon replays missing agent-directed task events.

4. **Make delivery API semantics honest**
   - Evidence: `/tasks/nudge` returned `sent:true` when notification was only queued in memory (`task_notify_recipient` returns true after enqueue even on WS failure).
   - Minimal design: return `delivery_state: "delivered" | "queued" | "failed"` rather than `sent:true` for in-memory/durable enqueue.

### Medium hardening

5. **Per-recipient ACK and idempotent replay**
   - Evidence: at-least-once replay needs dedupe; current event IDs exist (`taskevt_*`) but are not durably tied to recipient delivery.
   - Design: wrapper ACKs `event_id`; daemon keeps per-recipient cursor/acks.

6. **Coalesce noisy UI broadcasts**
   - Evidence: every task event fans out to all UI clients; no overload failure reproduced, but code path is broad.
   - Design: debounce/coalesce board refreshes and prefer embedded task/chain patch application.

7. **Reconnect backoff and bounded refreshes**
   - Evidence: UI reconnect path can register/refresh repeatedly. No failure reproduced here.
   - Design: exponential backoff with jitter for repeated reconnect failures and explicit max refresh frequency.

### Larger redesign

8. **Snapshot + durable delta model**
   - Evidence: current task system has durable snapshots but not durable deltas/events; notification replay needs both.
   - Design: durable append-only event journal plus snapshot projections; clients maintain cursors and replay deltas after reconnect.

## Suggested follow-up tests

1. Promote `tests/repro_delivery_restart_loss.py` into CI as a regression once a durable outbox/event journal fix is implemented. Expected output should flip for restart case: `delivered_on_reconnect: true` and `task_log_nudge_events_after_reconnect >= 1`.
2. Add a stress test that creates/updates/nudges many tasks with a connected UI WS and measures daemon latency, WS frame count, and reconnect behavior. This should be marked safe only for isolated temp daemons.
3. Add a wrapper-level integration test where an agent wrapper disconnects, a task auto-claim/nudge occurs, daemon restarts, wrapper reconnects, and the agent pane receives either a replayed notification or an explicit catch-up prompt.
4. Add message delivery tests across daemon restart for agent-to-user and user-to-agent paths, verifying durable message fetch and delivery metadata.

## Commands run for this audit

```bash
cd /Users/tanmayvijay/heimdall-agent-manager
nix build .#ham-daemon .#ham-wrapper .#ham-ctl
python3 tests/repro_delivery_restart_loss.py
KEEP_HEIMDALL_TEST_TMP=1 python3 tests/repro_delivery_restart_loss.py
sqlite3 <kept-temp>/data/tasks/task.db '.schema'
sqlite3 <kept-temp>/data/tasks/task.db 'select task_id, chain_id, status, title, assignee_agent_instance_id from tasks; select chain_id,status,title from task_chains;'
```

All commands above are safe for development machines when run as written; they use isolated temporary daemon data and localhost test ports. `KEEP_HEIMDALL_TEST_TMP=1` intentionally leaves temp files for inspection and should be cleaned manually after use.
