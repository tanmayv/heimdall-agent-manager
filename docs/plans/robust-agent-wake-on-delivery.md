# Plan: Robust Agent Wake-Up (fuse boot into the delivery layer)

Status: Draft
Owner: TBD
Scope: Make "start the agent when it is needed" a property of the notification/
delivery layer instead of a caller responsibility. No schema change.

## 1. Problem

"Ensure the target agent is running" is currently the **caller's** responsibility,
scattered across ~15 call sites using 3+ different entry functions
(`task_autoscaler_ensure_agent`, `task_autoscaler_ensure_chain_coordinator`,
`task_runtime_reconcile_task`, `task_runtime_reconcile_all_active`). Every new
scenario that needs to reach an agent — chat message, scheduled nudge, task
assignment, review-ready, @mention, auto-claim, chain create/activate — must
**remember** to call the right boot function.

Concrete failure: `handle_chat_send_to_coordinator` (`src/daemon/chat_http.odin`)
appends the message, fans out, and calls `agent_chat_notify_user_message` (a WS
send that **silently no-ops when the agent is offline**), but never calls any
ensure/boot function and hardcodes `"coordinator_boot_requested":false`. So
messaging an idle-shut-down coordinator drops the message into storage without
waking it. Compare `agent_rpc.odin:140`, which *does* call
`ensure_chain_coordinator`. The asymmetry is the bug class: a new notify path was
added and the boot call was forgotten. This will keep recurring.

## 2. Key Insight

Two facts make a clean fix possible:

1. **Every "reach the agent" path already funnels through one primitive.**
   `task_notify_recipient_delivery` (`src/daemon/task_notifications.odin:388`) is
   the single delivery choke point: it inserts a durable outbox row, attempts a
   live `registry_send_ws_text`, and (on failure) leaves the message queued for
   replay on reconnect (`task_notifications_flush_queue`, invoked from
   `src/daemon/ws.odin:31`). What it does NOT do today is **boot an offline
   recipient**.

2. **The boot path is already idempotent and self-throttling.**
   `task_autoscaler_ensure_agent` (`src/daemon/task_nudge_scheduler.odin:220`)
   guards every launch with:
   - team boot leases (rate/priority throttle),
   - a launch tracker `agent_runtime_tracker_try_begin_launch` that **coalesces**
     concurrent/duplicate boot requests,
   - skip reasons for already-connected / recently-booted agents.
   So calling it unconditionally on every delivery is safe — extra calls become
   no-ops.

Conclusion: the real defect is that **delivery and wake-up are two concerns that
callers must manually pair**. Fuse them at the one choke point everyone already
uses.

## 3. Design

### 3.1 Make delivery boot-aware (the core change)

Extend `task_notify_recipient_delivery` so that when the live WS send fails
(recipient offline) and the message was durably queued, it triggers a boot for
that recipient:

```
task_notify_recipient_delivery(agent, payload):
    event_id = notification_outbox_insert_pending(agent, payload)   # existing
    ok       = registry_send_ws_text(agent, payload)                # existing
    mark_attempt(agent, event_id, ok)                               # existing
    if not ok and queued:                                           # NEW
        ensure_agent_by_id(agent, reason = "notify_wake")           # idempotent
    return delivery
```

Because `ensure_agent` is idempotent, this cannot cause boot storms; duplicate
triggers coalesce in the launch tracker / lease system. Any code path that
notifies an agent — chat, nudge, assignment, review, mention, auto-claim — now
wakes it automatically. Callers no longer need to know about booting.

### 3.2 New primitive: `ensure_agent_by_id(agent_instance_id, reason)`

Today boot entry points require context the delivery layer does not have
(`ensure_agent` needs a `Task_Chain_State`; `ensure_chain_coordinator` needs a
`chain_id`). Add a resolver that boots from just the agent id:

- `chain_for_agent(agent_instance_id) -> (Task_Chain_State, ok)`:
  - if the agent is a chain's `coordinator_agent_instance_id` of a non-terminal
    chain → that chain;
  - else if the agent is an assignee/reviewer participant of a task in a
    non-terminal chain → that task's chain;
  - generalizes logic that already exists piecemeal
    (`task_autoscaler_agent_is_active_chain_coordinator`, participant lookups).
- If a non-terminal chain is found → delegate to existing
  `task_autoscaler_ensure_agent(chain, agent, task_id, priority, now, reason)`.
- If none (guide/memory-auditor singletons) → fall back to their dedicated
  launchers or skip (never crash).

`ensure_agent_by_id` becomes the single, context-free boot entry point.

### 3.3 Chat handler: also boot proactively (latency)

Keep an explicit `ensure_chain_coordinator` in
`handle_chat_send_to_coordinator` and return the real
`coordinator_boot_requested` value (not hardcoded `false`). With 3.1 in place
this is a **latency optimization** (boot before the first message rather than
after a failed delivery), not a correctness requirement.

## 4. Complementary Hardening (secondary)

1. **Idle-shutdown vs `in_progress` contradiction.** A coordinator was observed
   `shutting_down` while its chain was `in_progress`, even though
   `task_autoscaler_agent_is_active_chain_coordinator` is supposed to exempt
   coordinators of non-terminal chains. Audit every caller of
   `task_autoscaler_stop_chain_agents` and the idle-shutdown reaper so a
   non-terminal chain can never stop its own coordinator. With 3.1, even a wrong
   stop self-heals on the next message — defense in depth.

2. **Proactive `ensure_*` calls stay** at chain create/activate/status for boot
   latency, but become optimizations layered on top of the delivery-layer
   guarantee.

## 5. Why This Is Robust (not another patch)

| Property | Mechanism |
|---|---|
| Can't forget to boot | Boot fused into the delivery primitive everyone already uses; no caller opt-in |
| Safe to over-call | `ensure_agent` already coalesces via boot leases + launch tracker |
| Covers all scenarios | chat / nudge / assignment / review / mention / auto-claim all pass through `task_notify_recipient` |
| Durable + live unified | Outbox persistence + reconnect flush already exist; boot closes the "offline → never returns" gap |
| No new race | Wake fires only on confirmed delivery failure; tracker dedupes concurrent triggers |

## 6. Phased Delivery

Each phase is an independent, reviewed task; tree stays green between phases.
Smart-tier agents only; no cheap coder.

### Phase 1 — `ensure_agent_by_id` + `chain_for_agent` resolver
- Add `chain_for_agent(agent_instance_id)` and `ensure_agent_by_id(agent, reason)`
  in `task_nudge_scheduler.odin`, delegating to existing `ensure_agent`.
- No call-site changes yet. Unit-test the resolver mapping (coordinator, assignee,
  reviewer, singleton fallthrough, terminal-chain skip).
- Exit: builds; resolver covered by tests; behavior unchanged.

### Phase 2 — Fuse boot into delivery
- Call `ensure_agent_by_id(agent, "notify_wake")` from
  `task_notify_recipient_delivery` when live send fails and the message is queued.
- Exit: builds; a test proves an offline recipient with a queued notification
  triggers exactly one (coalesced) boot; connected recipients trigger none.

### Phase 3 — Chat handler correctness + proactive boot
- In `handle_chat_send_to_coordinator`, call `ensure_chain_coordinator` and return
  the real `coordinator_boot_requested`.
- Regression test: messaging an idle-shut-down coordinator wakes it.
- Exit: the reported chat bug is fixed at the handler and via the delivery layer.

### Phase 4 — Idle-shutdown guard audit
- Ensure no non-terminal chain stops its own coordinator via
  `task_autoscaler_stop_chain_agents` / idle reaper.
- Test: coordinator of an `in_progress` chain is never idle-reaped; a wrongly
  stopped coordinator self-revives on next notification.
- Exit: builds; guard tests pass.

### Phase 5 — (optional) Converge scattered call sites
- Migrate the ~15 scattered `ensure_*` / `reconcile_*` call sites to
  `ensure_agent_by_id` where appropriate, keeping proactive latency boots.
- Exit: fewer bespoke boot entry points; all existing tests green.

### Phase 6 — Verification
- `nix build .#ham-daemon` + `tsc` + affected python tests green.
- Keep the Phase 2/3 regression tests as permanent guards.

## 7. Acceptance Criteria
- Sending a chat/nudge/assignment/review/mention/auto-claim to an **offline**
  agent that belongs to a non-terminal chain reliably starts it, without the
  caller invoking any boot function.
- Duplicate/concurrent triggers do not cause multiple launches (coalesced).
- Coordinator of an `in_progress` chain is not idle-reaped; if stopped, the next
  notification revives it.
- No schema change. Daemon builds; existing + new tests pass; no cheap-tier
  agents used in the chain.

## 8. Touchpoint Index
- Delivery choke point: `src/daemon/task_notifications.odin`
  (`task_notify_recipient_delivery`).
- Boot/resolver: `src/daemon/task_nudge_scheduler.odin`
  (`task_autoscaler_ensure_agent`, new `ensure_agent_by_id`, `chain_for_agent`,
  `task_autoscaler_agent_is_active_chain_coordinator`, idle-shutdown reaper,
  `task_autoscaler_stop_chain_agents`).
- Chat handler: `src/daemon/chat_http.odin` (`handle_chat_send_to_coordinator`).
- Reconnect flush (existing, reused): `src/daemon/ws.odin`,
  `notification_outbox_*`.
- Reference correct pattern: `src/daemon/agent_rpc.odin:140`.
