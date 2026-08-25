# Plan: Port Task Auto-Promotion + Nudge from `ham-daemon` to `ham-hub` / `ham-bridge`

## Implementation status (living)

Done (compiling + tested via `nix develop --command odin`):
- Hub auto-promotion core (`src/hub/service/taskchain/promotion.odin`) wired into
  `publish_chain`, `change_task_status` (terminal/paused/validated_good),
  `evaluate_task_quorum`.
- Hub nudge decision logic (`src/hub/service/taskchain/nudge_decision.odin`).
- Hub lean read `GET /api/v1/bridge/actionable-tasks`
  (`src/hub/service/taskchain/actionable.odin` + bridge handler/route).
- Bridge scheduler thread (`src/bridge/task_scheduler.odin`): polls actionable
  tasks, local-observation staleness timing, cooldown, wake coalescing, wrapper
  nudge push / tmux wake. Config sourced from daemon nudge_* keys; default off.
- Tests: `tests/hub_task_promotion_nudge_test.odin`,
  `tests/hub_actionable_tasks_test.odin`, `tests/bridge_task_scheduler_test.odin`.
- Fixed stale pre-existing tests: `hub_m2_taskchain_http_test`,
  `bridge_runtime_launch_test`; added missing `unblocks_dependents` to
  `write_task_detail_json`.

Cross-bridge vertical slice (DONE, online path):
- Hub cascade already works: `recompute_chain_promotions` is chain-scoped and
  assignee/bridge-agnostic, so completing an upstream task on bridge A promotes a
  downstream task whose assignee lives on bridge B, then `notify_task_status_change`
  fans out to B. Proven end-to-end through the mutation path in
  `tests/hub_task_promotion_nudge_test.odin::test_cross_bridge_cascade`.
- Receiving-bridge gap fixed: `task_status_changed_notify` now wakes a local,
  non-live target (coalesced) instead of dropping it when the wrapper is offline
  (`bridge_task_status_notify_wake_local`). Non-local targets are refused (another
  bridge owns them). Covered by `bridge_task_scheduler_test::test_cross_bridge_locality`.

Orphan replay (DONE, verified live):
- Hub `replay_bridge_actionable_notifications` (in `actionable.odin`) re-fires
  `task_status_changed_notify` for every deps-satisfied actionable task targeting
  a reconnecting bridge's instances. Wired into `bridge_ws_upgrade_handler` right
  after `bridge_ready`, so a cascade dropped while the bridge was offline is
  recovered on its next connect.
- Receiving-bridge fix: `bridge_task_status_notify_wake_local` no longer gates on
  the in-memory runtime registry (empty right after restart). The Hub routes each
  notify only to the hosting bridge, so the target is authoritative; the bridge
  wakes it directly. This was the missing piece that made reconnect-replay wake a
  freshly-restarted bridge's agent.
- Tests: `tests/hub_orphan_replay_test.odin`.
- Live proof: killed Bridge B, completed upstream on A (cascade to B dropped),
  restarted B (empty registry) -> reconnect replay logged
  `task_status_changed_notify woke local target <inst_b>` and bravo autonomously
  picked up the promoted downstream task.

Remaining:
- Bridge-initiated `system_auto` promotion write (currently the Hub promotes on
  its own mutation path; the Bridge scheduler only wakes/nudges).
- Config keys surfaced under a bridge-specific namespace (currently reuses
  `daemon.nudge_*`).
- tmux session collision: both local bridges share the hardcoded `heimdall-bridge`
  tmux server, causing inherited-FD port reuse (`Address_In_Use`) when one bridge
  restarts. Bridge tmux session should be bridge-scoped.


## 1. Goal & division of labor

Bring back the task lifecycle automation the deprecated `ham-daemon` provided —
**auto-promotion** (dependency-cleared tasks advance; a free assignee auto-claims
its next task) and **auto-nudge** (periodically re-ping / wake the responsible
actor for stale actionable tasks).

**Chosen architecture: Bridge does the heavy lifting; Hub stays lean.**

- **Bridge = the scheduler/brain.** It runs the periodic sweep, owns the timing
  wheel (thresholds, cooldowns, coalescing), decides *who* to nudge and *when*,
  and — because it already owns tmux — wakes/launches agents directly with **zero
  extra Hub round-trips** for live-agent decisions.
- **Hub = lean durable store + validator.** It persists task/chain state, applies
  mutations (promotion status writes) when the Bridge asks, and fans out the
  authoritative task snapshot. It does **not** run a scheduler thread, does not
  track "last nudged at", and does not compute staleness.

Why this fits the codebase: the Bridge *already* has everything a scheduler
needs — an HTTP client + `bridge_token`, the `task_status_changed_notify` stream
with full assignee/reviewer/coordinator lists, a local instance registry with
liveness, tmux launch control (`bridge_runtime_launch_agent`), and wrapper push
(`bridge_wrapper_push_task_nudge`). The Hub already fans out task context via the
bootstrap/context endpoints.

**Cross-bridge chains are a first-class case.** A single chain can have its
assignee on bridge A, reviewer on bridge B, and coordinator on bridge C, and a
task on one bridge can depend on a task on another. Each bridge only sees/acts on
tasks whose *current target instance* is local to it, so a single bridge can never
compute the whole chain. When work crosses bridges, **it is fine to involve the
Hub** to (a) resolve dependency satisfaction across the global graph, (b) cascade
a promotion to a downstream task living on a different bridge, and (c) wake a
target whose home bridge is online but which no bridge is currently polling for.
The Hub does this **event-driven on the mutation path** (no scheduler thread, no
timers), so "Hub stays lean" still holds.

---

## 2. Reference: how `ham-daemon` did it (single process)

The daemon owned durable state **and** runtime, so promotion/nudge/launch were
all in-process calls. Splitting responsibilities means deciding which side runs
each piece; below is what needs to move where.

### 2.1 Auto-promotion (`src/daemon/task_queries.odin`)
- `task_recompute_promotions(author)` runs after most mutations. Promotes
  `Planning`/dep-blocked `Blocked` → `Queued` when `task_dependencies_satisfied`
  and `task_chain_allows_execution`, emitting `Task_Status_Changed` with markers
  (`system_auto:deps_cleared`, `system_queue:assignee_busy:<task>`).
- `task_service_auto_claim` moves `Queued`→`In_Progress` when the assignee slot
  is free, then reconciles runtime.
- `task_best_ready_task_for_assignee` serializes one active task per assignee
  (priority → created_at → task_id).

### 2.2 Nudge scheduler (`src/daemon/task_nudge_scheduler.odin`)
- Background thread; per-status thresholds (`nudge_ready/review/working_stale`),
  `nudge_cooldown_seconds`, `nudge_restart_grace_seconds`.
- Resolves target via `task_nudge_target_for_status`; if target not live
  (`registry_agent_live`) it relaunches, then appends `Task_Nudged`.
- Also ran `task_autoscaler_tick` (reconcile active chains, chain-terminal
  cleanup) with in-memory chain boot-leases / launch trackers for coalescing.

### 2.3 Config (`src/lib/config`)
`nudge_enabled`, `nudge_interval_seconds`, `nudge_ready_after_seconds`,
`nudge_review_after_seconds`, `nudge_need_improvements_after_seconds`,
`nudge_working_stale_after_seconds`, `nudge_cooldown_seconds`,
`nudge_restart_grace_seconds`, `nudge_send_escape_prefix`.

---

## 3. Current hub/bridge state

### 3.1 Hub (`src/hub/service/taskchain/taskchain_service.odin`)
- Statuses: `Assigned, In_Progress, In_Validation, Validated_Good,
  Validated_Not_Good, Paused, Completed, Cancelled`.
- Only automation today: `evaluate_task_quorum` (vote → validated) and
  user-triggered `manual_nudge`. Dependency gating is **reactive** (rejects a
  start via `change_task_status`), never proactively promotes.
- `notify_task_status_change` already builds and sends `task_status_changed_notify`
  runtime commands to the distinct bridges hosting the actors — **this is the fan-out
  the Bridge scheduler will consume.**

### 3.2 Bridge (`src/bridge/hub_runtime_client.odin`, `wrapper_endpoint.odin`)
- Handles `launch_agent`, `stop_agent`, `notify_agent_message`,
  `notify_task_nudge`, `task_status_changed_notify` (already computes downstream
  targets and pushes nudges to local wrappers), pane capture, provider tests.
- `bridge_runtime_instances` = local instance registry with per-instance
  runtime/activity status (liveness is known locally without asking the Hub).
- `bridge_runtime_launch_agent` launches via tmux; `bridge_wrapper_push_task_nudge`
  delivers to a connected wrapper (returns false ⇒ not subscribed/live).
- Sends `bridge_heartbeat` every 2s with `active_instance_ids`; has an HTTP client
  and relays agent task actions to `/api/v1/agent-actions/tasks/*`.

### 3.3 Gaps for a Bridge-driven design
- Bridge has no persistent view of the *task graph* (deps, statuses, assignees)
  beyond the momentary `task_status_changed_notify` — it needs a way to pull the
  current actionable set for its local instances.
- Bridge has no timing wheel / cooldown store for nudges.
- Hub has no single "apply an auto-promotion decision" mutation entry point that
  the Bridge can call (today promotion logic lives nowhere; quorum is the only
  auto-write).
- Hub does not expose a compact "actionable tasks for these local instances"
  read the Bridge can poll cheaply.

---

## 4. Target design (Bridge-driven)

### 4.1 Responsibility split

| Concern | Runs on | Notes |
|--------|---------|-------|
| Periodic sweep / timer loop | **Bridge** | one thread per bridge process |
| Staleness thresholds, cooldown, coalescing | **Bridge** | in-memory timing wheel keyed by task/agent |
| "Is the agent live?" | **Bridge** | reads local `bridge_runtime_instances`, no Hub call |
| Wake/launch a local agent | **Bridge** | direct `bridge_runtime_launch_agent` (tmux) |
| Deliver nudge to wrapper | **Bridge** | direct `bridge_wrapper_push_task_nudge` |
| Decide promotion (deps clear, assignee free) | **Bridge** | computed from the task snapshot it pulls |
| Persist promotion status write | **Hub** | Bridge calls a task-status/promote endpoint |
| Cross-bridge dep satisfaction | **Hub** | owns global graph; sets `deps_satisfied` |
| Cross-bridge promotion cascade | **Hub** | recompute dependents on terminal write, fan out to other bridges |
| Orphan target (home bridge offline) | **Hub** | durable outbox + replay on bridge reconnect |
| Durable task/chain/dep/vote state | **Hub** | unchanged source of truth |
| Validation/authz of writes | **Hub** | rejects illegal transitions |
| Fan-out task snapshot to bridges | **Hub** | existing `task_status_changed_notify` + a pull endpoint |

### 4.2 Data the Bridge needs, and how it gets it (lean Hub)

The Bridge scheduler only cares about tasks whose actors are **local instances on
this bridge**. Two complementary channels:

1. **Push (already exists):** `task_status_changed_notify` keeps the Bridge's
   in-memory task view fresh on every mutation, with assignee/reviewer/coordinator
   lists. Extend the Bridge to *cache* these into a local task table (not just
   react once).
2. **Pull (one new lean Hub endpoint):** `GET /api/v1/bridge/actionable-tasks`
   (bridge-authed). Returns a compact array for all non-terminal published tasks
   whose assignee/reviewer/coordinator instance is hosted on the calling bridge:
   `{task_id, chain_id, status, target_instance_id, target_role, updated_at,
   deps_satisfied}`. The Hub computes `deps_satisfied` (it owns the dep graph);
   everything else is a projection it already has. The Bridge polls this on its
   sweep interval (e.g. every 30–60s) — **one request per bridge per tick**, not
   per task. This is the only new steady-state Hub traffic, and it replaces the
   daemon's global in-memory scan.

This keeps the Hub lean: no scheduler, no timers, no nudge bookkeeping — just a
read projection + the write endpoints below.

### 4.3 Writes the Bridge issues to the Hub

- **Promotion:** reuse/extend `POST /api/v1/task-chains/*/tasks/*/status` (or a
  dedicated `.../promote`) with a `system_auto` reason so the Hub records
  `Assigned→In_Progress`. The Hub validates deps/assignee just like a manual
  change and is the final arbiter (prevents double-claim races between bridges).
- **Nudge audit (optional):** if we want durable nudge history/UI, add
  `POST .../nudge` with `origin=scheduled`. If we don't need durability, the
  Bridge can keep nudge delivery entirely local (Hub never sees scheduled nudges)
  — **leanest option; recommended for v1.**

### 4.4 Coalescing / dedup (all on the Bridge)

Port the daemon's in-memory coalescing to the Bridge:
- Per-agent wake window (~30s): don't relaunch an agent just woken.
- Per-(task,target) nudge cooldown (`nudge_cooldown_seconds`): in-memory map.
- Optional chain boot-lease if a chain tries to wake multiple agents per tick.

Because this is per-bridge and in-memory, it's simple and adds **zero** Hub load
for the common case where a task's current target lives on the polling bridge.

### 4.5 Cross-bridge chains (Hub mediates, still event-driven)

A bridge only holds/acts on tasks whose **current target instance is local**. The
following cases cross bridges and are delegated to the Hub on the mutation path:

1. **Cross-bridge dependency satisfaction.** The `deps_satisfied` flag in
   `actionable-tasks` is computed by the **Hub**, which owns the whole dep graph
   regardless of where parents run. So bridge B never needs to know about a parent
   on bridge A — it just sees `deps_satisfied=true` once the Hub observes the
   parent reach a terminal status. No cross-bridge chatter; the Hub already has
   the data.
2. **Cross-bridge promotion cascade.** When a task completes on bridge A and
   unblocks a downstream task whose assignee lives on bridge B, the Hub — inside
   the same `change_task_status` write that A already calls — recomputes affected
   dependents and, for any that become actionable, fires the existing
   `task_status_changed_notify` to **bridge B**. Bridge B wakes its local assignee.
   This reuses the fan-out that already exists; the only addition is a
   dependent-recompute step on terminal transitions. This is event-driven, not a
   sweep, so the Hub gains no timer.
3. **Orphan targets (no live bridge polling the task).** If a task's target
   instance's home bridge is offline, no bridge will act. The Hub detects this on
   the mutation path (target bridge not in the live runtime registry) and:
   - persists the intent in the existing durable outbox / instance `needed` flag
     (mirrors the daemon's notification outbox), and
   - replays a `task_status_changed_notify` / wake command to that bridge as soon
     as it reconnects (bridge heartbeat/hello is the trigger — already handled).
   No Hub scheduler is required; reconnection is the event.

Coalescing stays per-bridge and in-memory. Cross-bridge correctness comes from the
Hub owning the global graph and reusing its existing per-bridge fan-out — the Hub
is touched only when a mutation actually crosses a bridge boundary.

### 4.6 Status/target mapping (daemon → hub)

| daemon | hub | nudge target |
|--------|-----|--------------|
| queued | Assigned (published, deps clear, not started) | assignee |
| in_progress | In_Progress | assignee |
| review_ready | In_Validation | reviewer |
| approved | Validated_Good | coordinator |
| blocked | Paused / dep-blocked | assignee |

The Bridge already computes downstream targets in `task_status_changed_notify`;
`nudge_target_for_status` on the Hub matches this table and can be mirrored on the
Bridge.

---

## 5. Work breakdown

### Phase 0 — Contracts & docs (contracts-first)
- Define the `actionable-tasks` response schema and the promote/status write
  contract in `docs/teams-v1/03-lifecycle.md` + `08-http-and-cli.md`.
- Decide v1 nudge durability (recommend: **local-only scheduled nudges**, no Hub
  write) and whether promotion goes through existing `.../status` or a new
  `.../promote`.
- Config: nudge knobs move to the **Bridge** config namespace (the Bridge owns
  the loop), not the Hub.

### Phase 1 — Hub: lean read + promotion write
Files: `src/hub/service/taskchain/taskchain_service.odin`,
`src/hub/repository/iface/taskchain_repo.odin`,
`src/hub/repository/sqlite/taskchain_repo_sqlite.odin`,
`src/hub/transport/http/{taskchain_handlers,bridge_handlers}.odin`,
`src/hub/app/wiring.odin`.

1. Add a repo query: actionable published non-terminal tasks joined with
   dependency-satisfaction, filtered by a set of `agent_instance_id`s.
2. Add `GET /api/v1/bridge/actionable-tasks` (bridge-authed via `bridge_handlers`)
   returning the compact projection scoped to the bridge's hosted instances.
3. Ensure `change_task_status` accepts a `system_auto` reason and enforces:
   deps terminal + assignee-slot-free for `Assigned→In_Progress`; keep it the
   authoritative gate so two bridges can't both claim.
4. **Cross-bridge cascade (event-driven):** in `change_task_status`, on any
   terminal transition (`Completed`/`Cancelled`), recompute the tasks that
   depended on it; for any that become actionable and whose target lives on a
   *different, live* bridge, fire the existing `task_status_changed_notify` to
   that bridge. If the target's bridge is offline, record durable intent (outbox /
   instance `needed` flag) and replay on the bridge's next hello/heartbeat.
5. Keep `evaluate_task_quorum` as-is (validated promotion stays server-side —
   it's a pure function of votes the Hub already has).

*No scheduler, no timers, no nudge state added to the Hub — the cross-bridge
cascade runs inline on the mutation that caused it.*

### Phase 2 — Bridge: task-view cache + scheduler thread
Files: new `src/bridge/task_scheduler.odin`, `src/bridge/hub_runtime_client.odin`,
`src/bridge/main.odin`, bridge config.

1. **Local task cache.** Extend `task_status_changed_notify` handling to upsert a
   `bridge_local_tasks` map (task_id → status, target instance/role, updated_at).
   Seed/refresh it from the `actionable-tasks` poll.
2. **Scheduler thread.** Spawn on bridge start (gated on `nudge_enabled`): after
   `nudge_restart_grace_seconds`, loop every `nudge_interval_seconds`:
   - Poll `actionable-tasks`; merge into the cache.
   - **Promotion pass:** for each cached `Assigned` task whose deps are satisfied
     and whose assignee (local instance) slot is free, POST the promotion status
     write to the Hub; on success, wake the assignee locally if not live.
   - **Nudge pass:** for each cached actionable task past its per-status
     threshold and past cooldown, resolve target; if the target instance is a
     local live wrapper, `bridge_wrapper_push_task_nudge`; if not live,
     `bridge_runtime_launch_agent` (coalesced), then push. Update in-memory
     cooldown/wake maps.
3. **Coalescing maps** (Section 4.4) live here.
4. **Config** parses the nudge knobs on the Bridge side.

### Phase 3 — Bridge: liveness + wake correctness
- Use `bridge_runtime_instances` status to avoid killing a healthy agent: only
  `launch_agent` when the local instance is not `active`/running.
- Reconcile after wrapper exit/subscribe so a freshly-woken agent gets the queued
  nudge push.

### Phase 4 — Tests & validation
- Bridge unit: threshold/cooldown/coalescing math with a fake clock; promotion
  decision (deps clear → promote; assignee busy → hold; one-active-per-assignee).
- Hub unit: `actionable-tasks` projection + `deps_satisfied` correctness;
  `system_auto` status write authz (rejects illegal promotion, prevents double
  claim).
- Integration: fake Hub HTTP + fake wrapper socket; assert (a) one poll per tick,
  (b) no `launch_agent` for a live agent, (c) coalescing suppresses duplicate
  wakes, (d) promotion write is idempotent under retry.
- **Cross-bridge integration:** two fake bridges A/B; a task on A completing and
  unblocking a dependent whose assignee is on B triggers exactly one
  `task_status_changed_notify` to B (not A); with B offline, the intent is
  persisted and replayed on B's reconnect; `deps_satisfied` for B's task flips
  only after A's parent is terminal.
- Regression: `evaluate_task_quorum` and `manual_nudge` unchanged.

---

## 6. Hub↔Bridge traffic budget

| Event | Decided on | Hub call | Frequency |
|-------|-----------|----------|-----------|
| Sweep tick | Bridge | `GET actionable-tasks` | 1× per bridge per interval |
| Task changed | Hub→Bridge push | `task_status_changed_notify` | on mutation (already exists) |
| Promotion (target local) | Bridge decides, Hub persists | `POST .../status system_auto` | only when a task actually promotes |
| Promotion cascade (target on another bridge) | Hub, inline on terminal write | reuse `task_status_changed_notify` to other bridge | only when a mutation crosses a bridge |
| Orphan target (home bridge offline) | Hub | durable outbox + replay on reconnect | on reconnect event |
| Nudge (live local agent) | Bridge | **none** (local wrapper push) | as needed |
| Nudge (dead local agent) | Bridge | **none to Hub** (local tmux launch) | coalesced |
| Liveness check | Bridge | **none** (local registry) | every tick |

Steady-state new Hub load = **one lightweight GET per bridge per interval**, plus
a status write only on real promotions. Cross-bridge cascades add work only on the
mutation that crosses a boundary (reusing existing fan-out), and orphan replays
ride the existing reconnect path. Everything timing-related stays off the Hub.

---

## 7. Open questions
1. **Actionable-tasks scoping cost.** Confirm an index-friendly query for
   "published non-terminal tasks whose actor instance ∈ bridge's instances".
   Alternative: Hub pushes deltas only (no poll), but a poll is simpler and
   self-healing across bridge restarts.
2. **Double-claim race.** A task's target lives on one bridge at a time, but
   confirm the Hub's `system_auto` status write is the authoritative gate anyway
   (guards target reassignment / bridge migration mid-promotion).
3. **Cross-bridge cascade cost.** Recomputing dependents on every terminal write
   is O(dependents); confirm it's bounded/indexed and reuses the existing
   per-bridge `task_status_changed_notify` rather than a broadcast.
4. **Orphan replay source of truth.** Decide whether orphan wake intent rides the
   existing durable notification outbox or a lightweight instance `needed` flag,
   and confirm the bridge hello/heartbeat handler already triggers replay.
5. **`Assigned` vs explicit `Queued`.** Keep overloading `Assigned` (no enum
   migration) — recommended — vs. add `Queued` for parity.
4. **Scheduled-nudge durability.** v1 local-only (leanest) vs. persist for UI/audit.
5. **Config ownership.** Nudge knobs live in Bridge config since the Bridge owns
   the loop; confirm no Hub-side config is needed beyond enabling the endpoint.
