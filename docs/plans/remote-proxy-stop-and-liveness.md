# Plan: Forward stop for remote proxies + real liveness + UI de-dup

Follow-up to commit `df2c891` ("ui: show remote proxy agents as chatable instances").

## Problem recap

`df2c891` made `agentHasLiveSession()` return `true` for any non-archived remote
proxy. That correctly lit up the chat composer (chat send **is** federation-aware
via `federation_user_chat_send_to_remote_proxy`), but it also:

1. Exposed **Stop / restart / delete-stop** buttons that hit the local stop path
   (`agent_runtime_tracker_request_stop`), which does `registry_find_agent` and
   returns **404** for proxies (they can't register locally — `lifecycle.odin:63`).
   Start is forwarded (`agents_start.odin:424`); Stop is not — an asymmetry.
2. Reported proxies as "live" based only on `!archived/missing/deleted`, never on
   whether the **real** agent on the owning peer is actually up.
3. Duplicated the `agentRemoteInfo` / `isRemoteProxyAgent` / `agentHasLiveSession`
   helpers across `App.tsx`, `chat/ChatWorkBanner.tsx`, and `AgentPicker.tsx`, with
   minor divergence.

## Goals

- **G1** Stopping a remote proxy forwards to the owning peer and stops the real agent.
- **G2** Proxy liveness in the UI reflects the real remote instance's live state,
  not just "not archived".
- **G3** Remove the triplicated UI helpers; single shared source of truth.

---

## Part A — Backend: forward stop (G1)

Mirror the existing forwarded-start design. Start is the reference implementation:
`federation_forward_start` (`federation_transport.odin:188`) +
`handle_post_federation_start` (`federation_transport.odin:1578`) over the
synchronous `bridge_request` path on route `contracts.ROUTE_FEDERATION_START`.

### A1. New federation route constant
- `src/contracts/bridge.odin`: add `ROUTE_FEDERATION_STOP :: "/federation/stop"`.
- Add it to the authenticated-route match arm alongside `ROUTE_FEDERATION_START`
  (the `case ROUTE_FEDERATION_INBOX, ... ROUTE_FEDERATION_START, ...` block ~line 82).

### A2. Sender side: `federation_forward_stop`
- `src/daemon/federation_transport.odin`: add `federation_forward_stop(peer_id,
  remote_agent_instance_id: string, time_in_sec: int) -> (bool, int, string)`,
  modeled almost exactly on `federation_forward_start`:
  - `federation_direct_peer_lookup` → require `PEER_STATUS_LINKED`, else 503.
  - JSON body `{"agent_instance_id": <remote_agent_instance_id>, "time_in_sec": N}`.
  - `bridge_request(dest_daemon_id, POST, ROUTE_FEDERATION_STOP, payload,
    federation_idempotency_key("stop", server_daemon_id, remote_agent_instance_id),
    FEDERATION_HTTP_TIMEOUT_MS)`.
  - Return `(resp.status == 200, resp.status, clone(resp.body))`.

### A3. Receiver side: `handle_post_federation_stop`
- `src/daemon/federation_transport.odin`: add `handle_post_federation_stop`,
  modeled on `handle_post_federation_start`:
  - `federation_peer_id_for_context(ctx)` auth guard (401 on failure).
  - Require `agent_instance_id`; `agent_record_index_by_instance` → 404 if missing.
  - Refuse if target is itself a remote proxy (no relay-onward), same as start.
  - Delegate to the normal local stop path. Prefer refactoring
    `handle_agents_stop` so the socket-writing wrapper and the core
    `agents_stop_request(agent_instance_id, time_in_sec)` are cleanly separable
    (core already exists at `agents_stop.odin:36`). Call `agents_stop_request`
    and write its `(ok, status, msg)` back to the peer.
- `src/daemon/rest_router.odin`: dispatch `ROUTE_FEDERATION_STOP` →
  `handle_post_federation_stop` (mirror the `ROUTE_FEDERATION_START` case ~line 361).

### A4. Local stop entry point detects proxy and forwards
- `src/daemon/agents_stop.odin` (`agents_stop_request`, ~line 36): before the
  registry lookup, detect proxy exactly like start does in `agents_start.odin:424`:
  ```
  if idx := agent_record_index_by_instance(agent_instance_id);
     idx >= 0 && agent_record_is_remote_proxy(agent_instance_records[idx]) {
      peer, remote_id, ok := agent_remote_proxy_lookup(agent_instance_id)
      // -> federation_forward_stop(peer, remote_id, time_in_sec); return its result
  }
  ```
  Keep the existing local behavior for non-proxy agents unchanged.

### A5. Tests
- Unit/integration around `federation_forward_stop` payload shape + status
  passthrough, and the proxy-detection branch in `agents_stop_request`
  (dispatch to forward vs local). Follow whatever pattern the start-forward tests use.

---

## Part B — Backend: real liveness propagation (G2)

Today the proxy record has no live state from the origin; `agent_instance_record_json`
(`agents_start.odin:523`) only fills `connected`/`connection_state`/`last_seen`
from the **local** registry, which a proxy never has. So the UI must infer.

Reuse the existing origin→proxy **callback** channel (`FEDERATION_ROUTE_CALLBACK`,
`handle_post_federation_callback` ~line 1603) rather than inventing a new transport.

### B0. Edge-triggered, NOT heartbeat-driven — hard requirement

The origin daemon must **not** forward raw wrapper heartbeats to the peer. Wrappers
heartbeat every few seconds; relaying each one would flood the peer link and the
callback outbox. Propagate only **status transitions** — a coalesced view of the
agent's live status (idle / working / starting / stopping / stopped / blocked).

The machinery for this already exists locally: `registry_apply_heartbeat_snapshot`
returns `(runtime_changed, lifecycle_changed)` edge flags, and
`agent_runtime_tracker_apply_heartbeat_snapshot` (`agent_runtime_tracker.odin:358`)
only calls `agent_lifecycle_emit` / `agent_runtime_emit` when those flags flip.
Heartbeats that don't change status already produce **no** local emit. We piggyback
federation propagation on exactly those same edges — never on the raw heartbeat.

Define a small, stable **federation status** enum derived from the agent's existing
projection fields (the same ones the local UI already uses):
- `starting`             — `startup_status == "starting"`
- `idle`                 — connected + ready, `activity_status` idle
- `working`              — `activity_status == "active"` or `current_task_id` set
- `stopping`             — stop requested / `startup_status == "stopping"`
- `stopped` / `offline`  — disconnected / stopped / heartbeat timeout
- `startup_blocked` / `startup_failed` — surface as-is (non-live)

Propagate to the peer **only when this derived status value changes** vs the
last-sent status for that proxy subscriber. Consequences:
- A burst of heartbeats while the agent stays `working` → **zero** callbacks.
- `idle → working → idle` → exactly two callbacks.
- Carry `updated_unix_ms` for ordering, but last_seen churn alone is not a change.

### B1. New callback envelope: agent status
- Add `FEDERATION_ENVELOPE_AGENT_STATUS :: "agent_status"` in
  `federation_transport.odin`.
- On the **origin** daemon, add `federation_propagate_agent_status(agent_instance_id)`
  that (a) resolves the derived status (B0), (b) looks up proxy subscribers, and
  (c) for each subscriber whose last-sent status differs, enqueues a callback and
  updates its last-sent status. If status is unchanged it no-ops.
- Call it from the **same edge points that already gate local emits**, so it inherits
  their change-detection instead of adding a new firehose:
  - `agent_runtime_tracker_apply_heartbeat_snapshot` — only inside the existing
    `if !was_live || lifecycle_changed` and `if runtime_changed` branches
    (`agent_runtime_tracker.odin:362-365`). Never call it unconditionally per heartbeat.
  - stop-request / stop-done / start-success / heartbeat-timeout / register
    transitions (`registry_update_startup` sites at lines 255, 271, 282, 371, 436).
  - Because the function re-checks last-sent status, extra call sites are cheap/safe.
  - Need a reverse index: "which peers hold a proxy for this local agent_instance_id".
    The origin already receives proxy binds (`federation_remote_proxy_bind`,
    `federation_peers.odin:829`); persist/derive the set of `(peer_id,
    proxy_agent_instance_id, last_sent_status)` subscribers per local agent so the
    origin knows whom to notify and can suppress unchanged pushes. A minimal
    in-memory version keyed off existing bind records is acceptable (transport/
    liveness projection per AGENTS.md).
  - Payload carries `proxy_agent_instance_id`, `status` (derived enum),
    `connection_state`, optional `current_task_id`, `reason`, `updated_unix_ms`.
  - Route via the existing delivery outbox (`federation_delivery_outbox_insert_pending`
    + `bridge_send`) so it is retryable, exactly like inbox/callback traffic.
  - On peer link (re)connect, send **one** current-status snapshot per subscriber so
    the peer re-syncs after any missed transitions; steady state stays transition-only.

### B2. Proxy side: store remote status
- Extend the proxy's live projection with `remote_status` (the derived enum),
  `remote_connection_state`, `remote_current_task_id`, and
  `remote_last_seen_unix_ms`. A small in-memory map keyed by
  `proxy_agent_instance_id`, updated on callback, is sufficient (transport/liveness
  state, per the in-memory-projection invariant in AGENTS.md).
- `handle_post_federation_callback`: handle `FEDERATION_ENVELOPE_AGENT_STATUS`.
  Validate the callback is authorized for this proxy exactly like the existing
  cases (`agent_remote_proxy_lookup(proxy_agent_instance_id)` must map to the
  calling `peer_id`). Apply the status; drop stale/out-of-order updates using
  `updated_unix_ms`. When the stored status actually changes, emit the **local**
  UI events (`agent_lifecycle_emit` / `agent_runtime_emit`) for the proxy so the
  peer's own UI updates live — again only on transition, never per callback.

### B3. Expose remote status in agent JSON
- `agent_instance_record_json` (`agents_start.odin:523`): inside the
  `if agent_record_is_remote_proxy(rec)` block, extend the emitted `remote` object
  with `"status"`, `"connection_state"`, `"connected"`, `"current_task_id"`, and
  `"last_seen_unix_ms"` from the stored remote status (B2). These are the fields the
  UI needs to render real liveness plus idle/working/starting/stopped badges.
- Reachability fallback: if the **peer link itself** is unreachable
  (`PEER_STATUS != LINKED`), report the proxy as not-live / `offline` regardless of
  last-known remote status (peer state already tracked in `federation_peers.odin`).

### B4. Tests
- **Transition-only propagation (core requirement):** N heartbeats with unchanged
  status ⇒ 0 callbacks; a genuine `idle→working→idle` ⇒ exactly 2 callbacks.
- Callback authorization (wrong peer rejected), status apply, stale-drop by
  `updated_unix_ms`, and JSON exposure.
- Peer-unreachable overrides last-known status to `offline`.
- Reconnect snapshot: exactly one status push per subscriber on link re-establish.

---

## Part C — UI (G1 + G2 + G3)

### C1. Shared helpers module (G3) — do this first
Create `src/ui/api/agentRemote.ts` exporting:
- `agentRemoteInfo(agent): { peerId; originDaemonId; remoteAgentInstanceId } | null`
  (superset shape — the full three-field version currently in `App.tsx`/`AgentPicker`).
- `isRemoteProxyAgent(agent): boolean`
- `remoteProxyContext(agent): string`
- `remoteAgentIsLive(agent): boolean` — reads the new `remote.status` /
  `remote.connection_state` / `remote.connected` / peer-reachability fields from B3.
- `remoteAgentStatus(agent): 'idle'|'working'|'starting'|'stopping'|'stopped'|'offline'|'blocked'|''`
  — normalizes `remote.status` (from B3) for badge/label rendering (see C3).

Then delete the local copies and import the shared ones in:
- `src/ui/components/App.tsx` (drop the 3 helpers added by `df2c891` at lines 340–364).
- `src/ui/components/chat/ChatWorkBanner.tsx` (drop its `agentRemoteInfo` +
  `isRemoteProxyAgent`).
- `src/ui/components/AgentPicker.tsx` (drop `agentRemote` + `isRemoteProxyAgent`,
  keep its local `agentKind` or move that too).

Prefer `agentCatalog.ts` co-location if that file is the natural home; a dedicated
`agentRemote.ts` keeps it focused. Either way: **one** definition.

### C2. De-duplicate `agentHasLiveSession`
- `ChatWorkBanner.tsx` currently forks `agentHasLiveSession`. Export the canonical
  one from `App.tsx` (already exported) or, better, move it into a shared
  `agentLiveness.ts` and have both `App.tsx` and `ChatWorkBanner.tsx` import it.
  This removes the second place the `df2c891` remote branch had to be patched.

### C3. Liveness uses real remote state (G2)
In the shared `agentHasLiveSession`, replace the `df2c891` branch:
```
if (isRemoteProxyAgent(agent)) return !['archived','missing','deleted'].includes(...)
```
with:
```
if (isRemoteProxyAgent(agent)) return remoteAgentIsLive(agent);
```
where `remoteAgentIsLive` returns true only when the peer link is reachable **and**
the origin's last-sent `remote.status` is a live value (`idle`/`working`/`starting`).
It falls back to `false` when status is `stopped`/`offline`/`blocked`/unknown or the
peer is unreachable (so a proxy to a stopped/unreachable agent reads as stopped, not
falsely live).
- Update `agentCatalog.ts` (~line 78) to map the new `remote.status` /
  `remote.connection_state` / `remote.connected` / `remote.current_task_id` /
  `remote.last_seen_unix_ms` fields.
- Wire the existing WS handlers (`wsInvalidation.ts` / `handleUserWsEvent`) so the
  `agent_lifecycle_changed` / `agent_runtime_changed` events the proxy daemon now
  emits for proxies (B2) refresh the cached agent — proxy status updates live in the
  UI on transition, matching local agents.

### C4. Buttons now backed — keep them, but correct semantics
- Stop button (`agent-detail-stop-btn`, `App.tsx:3385`) can stay visible for a live
  proxy because Stop is now forwarded (Part A). Verify `stopAgent` (line 3232)
  surfaces forwarded errors sensibly.
- Runtime restart / delete-stop already `.catch()` the stop; with A4 the stop now
  actually forwards, so restart of a proxy performs a real remote stop+start. Confirm
  this is the desired semantics for proxies (a remote restart) or gate restart off
  for proxies if not.
- Status indicator (`agentStatusIndicator`, `App.tsx:489`): the flat "Remote" badge
  should now reflect the propagated status. Prefer showing the real state
  (`Working`/`Idle`/`Starting`/`Stopped`) via `remoteAgentStatus(agent)`, optionally
  suffixed/tinted to signal it is remote, rather than a single static "Remote" label.
  Fall back to `Offline` styling when `remoteAgentIsLive` is false / peer unreachable.
- `remoteProxyContext` can append the live status (e.g. `Remote · working · <id> via
  <daemon>`) so hover/subtitle text is informative.

### C5. `tsc -b` must stay green; no `data-debug-id`s change (no new elements).

---

## Sequencing

1. **C1 + C2** (UI de-dup) — safe, standalone, unblocks clean edits. Ship-able alone.
2. **A1–A5** (forward stop) — makes the already-visible Stop button correct.
3. **B0–B4** (status propagation) — the largest piece; edge-triggered callback envelope
   + subscriber index + change-suppression. This is where the "no heartbeat firehose"
   requirement lives.
4. **C3–C4** (UI consumes real status) — depends on B3 field shape and B2's proxy-side
   WS emits.

C1/C2 and Part A are low-risk and independently valuable; Part B is the substantive
new backend work and should be reviewed on its own.

## Risk / design notes

- **No heartbeat firehose (the load-bearing constraint).** The origin must never
  forward per-heartbeat traffic. Propagation is strictly transition-triggered off the
  existing `runtime_changed`/`lifecycle_changed` edges plus discrete lifecycle events,
  and `federation_propagate_agent_status` self-suppresses when the derived status is
  unchanged. A steady `working` or `idle` agent generates zero cross-daemon traffic.
- Keep origin→peer status fanout on the **existing** retryable callback/outbox path —
  do not add a new synchronous hot path in `agent_lifecycle_emit`. Emission there
  should be enqueue-only.
- Debounce consideration: activity detection can flap idle↔working rapidly. If that
  proves noisy, add a short min-interval/coalesce per proxy subscriber on the origin
  (still transition-based, just rate-limited). Start without it; add only if measured.
- Reverse subscriber index (which peers proxy a given local agent) is the main new
  state. Confirm whether bind records already give this cheaply before adding a table.
- Respect the AGENTS.md invariant: durable business state on disk, transport/liveness
  state may stay in-memory projection (B2 remote-status cache qualifies).
