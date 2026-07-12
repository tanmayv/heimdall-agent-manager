# Lifecycle tracker boundaries

This note documents the intended boundary after the lifecycle tracker refactor.

## Tracker-owned mutation paths

These transitions should go through `src/daemon/agent_runtime_tracker.odin` APIs instead of mutating runtime lifecycle fields directly from callers:

- start-success / ready transition
- startup report application
- heartbeat snapshot application
- WebSocket connect / disconnect / stale-close handling
- startup timeout
- heartbeat timeout
- stop request / stop done
- lifecycle/state projections used for daemon decisions

## Allowed direct registry access patterns

The remaining direct lifecycle-adjacent registry access falls into a few intentional buckets:

### Internal helper/storage code
- `src/daemon/registry.odin`
  - owns raw in-memory storage helpers such as `registry_set_ws`, `registry_clear_ws(_if_socket)`, `registry_update_startup`, and `registry_apply_heartbeat_snapshot`
  - these are low-level primitives called by tracker APIs

### Read-only candidate detection / freshness inputs
- `src/daemon/agent_startup_janitor.odin`
  - still reads `startup_status`, `startup_updated_unix_ms`, `connected`, and `last_seen_unix_ms`
  - this is detection only; transition application is delegated to tracker APIs
- `src/daemon/task_nudge_scheduler.odin`
  - still reads `startup_updated_unix_ms` / `last_seen_unix_ms` for idle-shutdown freshness windows
  - this is read-only timing input, not lifecycle mutation
- `src/daemon/guide_rpc.odin`
  - read-only connected/WS counts for guide diagnostics

### Registration-domain lifecycle fanout (not moved in this chain)
- `src/daemon/lifecycle.odin`
  - `handle_register` still emits the `registered` lifecycle event directly
  - registration remains outside the tracker mutation set for now

## Deferred follow-up / intentional leftovers

These are known remaining direct lifecycle-adjacent sites that are acceptable for now but are good future cleanup candidates:

- `registry_send_ws_text` / `registry_mark_ws_stale` still emit `ws_stale` lifecycle directly from registry send-failure handling
- register-time lifecycle fanout in `handle_register`
- raw lifecycle field reads inside tracker projection helpers themselves (expected: tracker is the abstraction boundary)

## Rule of thumb for new code

- If code wants to **change** runtime lifecycle/session state, add or use a tracker API.
- If code only needs a **decision/query/projection**, prefer a tracker helper over peeking at raw `agents[]` fields.
- Keep HTTP parsing, persistent store writes, and UI JSON formatting outside the tracker unless the logic is specifically about runtime lifecycle transitions.
