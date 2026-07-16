# Task-event WS payloads: tiered inlining follow-up

## Status

- **Correctness fix:** shipped in `eedac2a` (`fix(ui): live task status/comment updates in
  chain view`). Chain-view task status/comment updates now work reliably.
- **This doc:** an *optimization* follow-up. Not urgent. ~1–2 hours. Do it next time someone
  is in `task_notifications.odin` / `wsInvalidation.ts`.

## Problem

`task_notification_json` (`src/daemon/task_notifications.odin`) builds a `task_event` WS
payload by appending **both** the full `task` and the full `chain` JSON, then checks the total
against `WS_INLINE_PAYLOAD_LIMIT` (3900 bytes, `src/daemon/chat_events.odin:6`). If the
combined payload is too big it drops **both** inline records and emits the compact
`fetch_required` form.

The chain JSON alone exceeds the budget for any real chain, so in practice **every** task
event (status change, comment, etc.) falls back to `fetch_required` — even though the `task`
object by itself is almost always small enough to inline.

### Evidence (live WS probe against the running daemon)

Posting a comment via `/user-rpc` on a task in a real chain produced:

```
TASK_EVENT {"event":"Task_Comment","task_id":"...","chain_id":"...",
            "status":"...","has_task":false,"has_chain":false,
            "fetch_required":true,"size":454}
```

`has_task:false, has_chain:false, fetch_required:true` at only ~450 bytes → the all-or-nothing
size check dropped the small task along with the large chain, forcing a REST refetch for a
trivial status change.

## Goal

Restore the zero-refetch fast path for the common case (status change / comment) by inlining
the **task** even when the **chain** is too big to inline.

## Design: tiered (graceful) inlining

Replace the single all-or-nothing size check with three tiers that degrade one step at a time.

In `task_notification_json`:

1. **Tier 1 — task + chain inline** (current happy path)
   Build `base + ,"task":<task> + ,"chain":<chain>`. If `len <= WS_INLINE_PAYLOAD_LIMIT`,
   return it. Unchanged behavior.

2. **Tier 2 — task inline, chain fetch-required** (NEW)
   Build `base + ,"task":<task> + ,"chain_fetch_required":true,"fetch_chain_id":"<id>"`.
   If `len <= WS_INLINE_PAYLOAD_LIMIT`, return it. This covers the overwhelmingly common case
   where only the chain object blows the budget.

3. **Tier 3 — compact fetch_required** (current fallback, unchanged)
   `base + ,"fetch_required":true,"fetch_kind":"task",...`. Only reached when the task alone
   does not fit. Correctness for this tier is guaranteed by the `forceRefetch` fix already in
   `eedac2a`.

### Sketch

```odin
task_notification_json :: proc(event: Task_Event, status: string) -> string {
    // Resolve task/chain once.
    task_state, has_task := (event.task_id != "") ? store_get_task_in_chain(event.task_id, event.chain_id) : ({}, false)
    chain_state, has_chain := (event.chain_id != "") ? store_get_chain(event.chain_id) : ({}, false)

    // Tier 1: task + chain
    b1 := build_base(event, status)
    if has_task  { append task_write_state_json(b1, task_state) }
    if has_chain { append task_write_chain_json(b1, chain_state) }
    p1 := finish(b1)
    if len(p1) <= WS_INLINE_PAYLOAD_LIMIT do return p1
    delete(p1)

    // Tier 2: task inline, chain fetch-required
    if has_task {
        b2 := build_base(event, status)
        append task_write_state_json(b2, task_state)
        if has_chain {
            append `,"chain_fetch_required":true,"fetch_chain_id":"` + event.chain_id + `"`
        }
        p2 := finish(b2)
        if len(p2) <= WS_INLINE_PAYLOAD_LIMIT do return p2
        delete(p2)
    }

    // Tier 3: compact fetch_required (unchanged)
    return build_compact_fetch_required(event, status)
}
```

Keep the field names already used by the UI:
- `task` — full task object (already consumed by `handleTaskEvent`).
- `chain` — full chain object.
- `fetch_required` / `fetch_kind` / `fetch_task_id` / `fetch_chain_id` — Tier 3 compact form.
- `chain_fetch_required` / `fetch_chain_id` — **new**, Tier 2 signal.

## UI side (pairs with Tier 2)

`handleTaskEvent` in `src/ui/api/wsInvalidation.ts` already has an `if (payload.task)` branch
that patches `fetchTask` and `fetchChainTasks` caches directly — so **Tier 2 payloads take the
existing fast path automatically** (task inline). The only addition:

- When `payload.chain_fetch_required` (and a `chainId` is present), lazily refresh the chain:
  `dispatch(heimdallApi.util.invalidateTags([{ type: 'ChainState'|'Chain', id: chainId }]))`
  (use whichever tag the chain query provides). This only fires when the daemon actually
  signals the chain changed, so it is cheap.

Do **not** remove the `forceRefetch: true` on the Tier-3 `fetch_required` branch — that is the
correctness guard for genuinely oversized tasks and must stay.

## Non-goals / rejected alternatives

- **Raise `WS_INLINE_PAYLOAD_LIMIT`.** Rejected: the ~4090-byte WS frame ceiling is real; 3900
  is a deliberate safety margin. Do not push against it.
- **Trim/summarize the chain to force a fit.** Rejected: partial objects that look complete
  cause subtle UI bugs (missing fields read as defaults). Explicit "fetch this" is safer than
  a lossy inline copy.
- **Split into two WS messages (task event + chain event).** Rejected: more frames, ordering
  concerns, and the UI would need to correlate them. A lazy tag invalidation is simpler.

## Acceptance / verification

1. Re-run the raw `user-ws` probe used for the original diagnosis: post a `task_comment` and a
   `task_status` change via `/user-rpc` on a task in a real (large) chain.
   - **Expect:** `has_task:true`, and `chain_fetch_required:true` instead of the bare
     `fetch_required:true` compact form. Payload still `<= WS_INLINE_PAYLOAD_LIMIT`.
2. In the UI, change a task status / add a comment in a real chain and confirm the chain-view
   list and task-detail update **without** an observable REST `fetchTask` round-trip (Tier 2
   should patch from the inline `task`).
3. Construct/force a task large enough to exceed the limit on its own (Tier 3) and confirm it
   still updates (relies on the shipped `forceRefetch` fix).
4. `npm run typecheck`, `nix build .#ham-daemon --no-link`, `git diff --check`.

## Files

- `src/daemon/task_notifications.odin` — `task_notification_json` tiering; add the Tier 2
  branch and a `chain_fetch_required` marker.
- `src/ui/api/wsInvalidation.ts` — `handleTaskEvent`: handle `chain_fetch_required` with a
  lazy chain tag invalidation; keep the Tier-3 `forceRefetch` fix.

## Priority

Nice-to-have, not urgent. The correctness fix (`eedac2a`) already makes the UI update
reliably; this only removes one REST round-trip per task event. Schedule opportunistically.
