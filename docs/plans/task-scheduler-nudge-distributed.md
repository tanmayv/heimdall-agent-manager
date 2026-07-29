# Bridge-Owned Task Policy Engine (Nudge / Auto-Claim) — Plan

## Goal

Move the **task policy engine** — nudge delivery, staleness-based auto-nudge,
and auto-claim/auto-start — **onto the Bridge**. The **Hub is responsible for
durable task-chain state, authorization, serialization, and compact propagation**
to the bridges that host a chain's members. The Bridge runs the loop and makes /
delivers decisions for the instances it owns.

Explicitly **drop "auto-complete chain when all tasks are terminal"**
(coordinator completes chains manually).

Two key refinements are part of this plan:
1. **Task comments notify agents**: every new task comment generates a
   version-gated, body-free notification to the task assignee and reviewers.
2. **Hub↔Bridge payloads stay small**: full chain snapshots are only for initial
   sync / catch-up. Normal mutations use versioned deltas; heartbeats never carry
   full chain/task/comment state.

## Why this split works

The only inputs a nudge/auto-claim decision needs are:
1. **The chain's current state** (tasks, statuses, assignees, reviewers, deps,
   coordinator) — durable, owned by the Hub.
2. **The local instance's runtime reality** (live? idle how long? busy?) — only
   the Bridge knows this, per instance it hosts.

If the Hub propagates **compact, ordered chain changes** to every bridge hosting
a member, each bridge has enough state to decide + deliver for **its own**
instances. No bridge needs another bridge's runtime state; it only acts on the
instances it runs. The Hub becomes a durable store + propagation bus; the Bridge
becomes the policy engine + local delivery.

Benefits:
- Idle/activity detection is exactly where the runtime is (accurate, no guessing).
- Delivery (tmux/wrapper push) is local (already the Bridge's job).
- Hub stays request/response + event propagation; no Hub scheduler thread.
- Naturally multi-bridge: each bridge nudges only its own agents.
- Scale-friendly: mutation fan-out sends deltas, not full chain details.

## Audit Recap (today)

- **Nudge computed, never delivered** (`manual_nudge` appends to in-memory
  `service.nudges`, consumed by nobody).
- **No Hub scheduler**; `nudge_*` config knobs unused.
- **No auto-claim / auto-start.** Vote quorum auto-promotion works.
- **Task events don't notify agents.** Only chat notifies via
  `notify_agent_message` (Hub → bridge command → wrapper push → tmux). This plan
  intentionally adds live task-comment notifications for assignees/reviewers.
- **Bridge already**: tracks per-instance `activity_status`/`last_seen`, has a
  heartbeat loop to the Hub, delivers `notify_agent_message`/`startup_prompt`
  pushes to the wrapper, and receives `launch_agent`/`stop_agent`. It does **not**
  currently retain the `chain_id` from `launch_agent`, and has no task state.
- **Legacy daemon** had a single-thread scheduler + auto-claim + auto-complete;
  we are redistributing the first two to the Bridge and dropping auto-complete.

## Responsibility Split

### Hub (durable state + compact propagation only)
- Source of truth for chains/tasks/members/votes/deps/comments (unchanged).
- On any task/chain mutation (create/update/status/vote/comment/member/publish),
  bump monotonic `chain_version` and propagate a **minimal `task_chain_delta`** to
  every bridge in the affected chain's routing set.
- Send a **full `task_chain_snapshot`** only on bridge connect/reconnect,
  instance launch, missing-version/gap recovery, or explicit bridge resync
  request. Do **not** send a full chain snapshot on every mutation.
- On task comment create, compute post-mutation recipients (assignee + reviewers)
  and send **per-bridge `task_comment_notify`** commands only to bridges that host
  target recipients. The notification contains IDs/version metadata only; agents
  fetch the durable comment body through REST/RPC/CLI.
- Accept **decision reports** from bridges (auto-claim requests, nudge-delivered
  acks, notification-delivered acks) and **apply them as normal authenticated
  mutations**, then re-propagate.
- Validate authorization exactly as for any bridge-relayed instance action
  (bridge token + instance assertion); the Bridge never bypasses Hub
  authorization.
- **No scheduling, no timers, no nudge/claim policy** in the Hub.

### Bridge (policy engine + delivery)
- Maintains a local **chain state cache** keyed by `chain_id`, updated by
  `task_chain_snapshot` + `task_chain_delta` from the Hub. Retains `chain_id` per
  instance (from `launch_agent`).
- Tracks last-seen `chain_version` per chain; applies deltas only when their
  `base_chain_version` matches the cache. If a delta is missing/out-of-order, the
  bridge requests a snapshot resync.
- Delivers version-gated task notifications via existing wrapper push → tmux.
  `task_comment_notify` is delivered only after the local cache has reached at
  least the notification's `chain_version`.
- Runs a **policy tick** inside its existing heartbeat loop: for each live
  instance it hosts, using (chain cache + local activity/idle + thresholds):
  - **Nudge**: if the instance's current task is stale-for-its-status beyond the
    threshold and past cooldown, deliver a tmux nudge locally.
  - **Manual nudge**: when the Hub relays a manual nudge delta/notification,
    deliver immediately.
  - **Comment notify**: when a new comment notification targets a local assignee
    or reviewer, deliver immediately after the version gate passes; do not wait
    for the staleness timer.
  - **Auto-claim**: if a queued task assigned to a local instance is
    dependency-satisfied and the instance is free, request the claim from the Hub
    (status → in_progress) and, on ack/sync, nudge the agent to start.
  - **Auto-start**: if a local-owned assignee instance is not running and a task
    needs it, the Bridge can (re)launch it locally (it already owns launch),
    subject to grace/cooldown, then nudge on start-success.
- Reports outcomes to the Hub (claim requests, delivered acks) so durable state,
  cooldown bookkeeping, and notification replay stay correct.

## Minimal Payload & Sync Model

### Full snapshots are catch-up only

`task_chain_snapshot` is the only full-ish chain payload. It is sent on:
- bridge connect/reconnect, including bridge process restart with a new
  `bridge_boot_id`;
- instance launch / member moved to a new bridge;
- explicit bridge `task_chain_resync_request`;
- Hub-detected gap recovery.

A bridge process restart is treated as **total cache loss**, even if the local
wrappers/tmux sessions survived. The restarted bridge starts with no trusted
chain cache, reports the active instances it recovered locally, and waits for Hub
snapshots before making task policy decisions.

Snapshots use a **compact chain projection**, not the UI chain-detail response:
- include chain identity/status/coordinator;
- include members/assignee/reviewer refs needed for routing and policy;
- include tasks with status/deps/assignee/reviewers/update timestamps;
- include votes only if needed for reviewer policy;
- include non-null `last_nudge_at` entries;
- **exclude comment bodies**, chat bodies, artifacts, full descriptions when not
  needed for policy, and any UI-only expansion fields.

### Normal mutations use deltas

Every applied mutation produces one monotonically-versioned `task_chain_delta`:

```text
chain_version N   + mutation   =>   chain_version N+1 + delta(base=N, version=N+1)
```

A delta contains only changed fields/ops, for example:
- `task_created` with the new compact task row;
- `task_status_changed` with `{task_id, status, updated_at}`;
- `task_assignee_changed` / `task_reviewers_changed`;
- `vote_upserted` / `vote_removed`;
- `comment_added` with `{task_id, comment_id, author_agent_instance_id,
  created_at, comment_count}` and **no comment body**;
- `member_added` / `member_removed`;
- `last_nudge_at_changed` for the one affected task.

Bridge apply rules:
- If `base_chain_version == last_seen_version`, apply and advance.
- If `chain_version <= last_seen_version`, ack succeeded and ignore (duplicate).
- If `base_chain_version != last_seen_version`, do not guess; request snapshot
  resync and hold version-gated notifications until caught up.

### Policy is versioned separately

Nudge/claim thresholds are Hub-configured but sent as `task_policy_sync` with a
`policy_version`:
- sent on bridge connect/reconnect;
- sent only when policy changes;
- referenced by snapshots/deltas as `policy_version` if needed.

Do **not** piggyback the full policy block on every heartbeat or every task
delta.

### Heartbeats stay runtime-only

`bridge_heartbeat` must remain small and runtime-focused:
- bridge identity, `bridge_boot_id` (stable for one bridge process), heartbeat
  sequence/time;
- capabilities only on connect or when changed (or a compact capabilities hash on
  periodic heartbeats);
- active instance IDs / changed instance rows;
- per-instance runtime/activity status and `idle_seconds` if available.

Heartbeats must **not** include chain snapshots, task arrays, comments, votes, or
full policy blocks. If the Hub needs sync confirmation, use compact watermarks
only when requested, e.g. `known_chain_versions: [{chain_id, chain_version}]`, or
prefer command acks/resync requests over periodic watermark spam.

## Task Comment Notifications

Task comments are durable records owned by the Hub. Live Bridge notifications are
metadata-only hints that tell agents to fetch the durable comment.

### Recipients

On `comment_added`, the Hub computes recipients from the **post-mutation** task
state:
- the task assignee (if any);
- explicit reviewer refs;
- task participants in reviewer roles (`lgtm_required`, `lgtm_optional`) and any
  chain default reviewer that is currently an effective reviewer;
- exclude the comment author by default to avoid self-echo, unless a future
  config explicitly asks for echo notifications.

Coordinator/subscriber UI notifications can still happen through existing durable
UI/task event paths, but the new wrapper/tmux task-comment push targets
assignee/reviewers.

### Payload discipline

`task_comment_notify` contains only routing/version metadata:
- `notification_id` for dedupe/replay;
- `chain_id`, `task_id`, `comment_id`;
- `chain_version` that contains the comment;
- `author_agent_instance_id`;
- per-bridge `recipient_agent_instance_ids` (only recipients local to that
  bridge);
- timestamps/reason enum.

It must not include the comment body, markdown, artifact blobs, full task detail,
or full chain snapshot. The wrapper line should tell the agent to fetch the task
comments through `ham-ctl` / REST.

### Version gate and dedupe

`task_comment_notify` is version-gated by both bridge capability and chain state:
- Hub sends it only to bridges advertising `task_comment_notify_v1` (older
  bridges fall back to snapshot-only/no live comment push, depending on rollout
  policy).
- Bridge delivers it only after local `chain_cache[chain_id].chain_version >=
  notify.chain_version`.
- If the bridge receives the notification before the delta, it stores it briefly
  as pending; if the version gap is not resolved, it requests `task_chain_snapshot`.
- Bridge dedupes by `notification_id` (and optionally recipient ID) so duplicate
  command delivery cannot double-push tmux.
- Hub records only small notification markers (`notification_id`, IDs, version,
  delivered_at`) for retry/replay; never copy comment bodies into the notification
  outbox.

## Cross-Bridge Sharing & State Sync

A task chain is **shared**: its members (coordinator, assignees, reviewers) can
run on **different bridges**. Every bridge that hosts a member must converge on
the same chain state, and concurrent decisions on different bridges must not
corrupt it. Bridges **never talk to each other** — the **Hub is the single
serialization point and fan-out hub**. This gives a star topology, not a mesh.

### Membership → bridge routing set

- The Hub stores chain members (`task_chain_members`, each with
  `agent_instance_id`); each instance maps to a `bridge_id`.
- For any chain, the Hub computes the **routing set** = the distinct set of
  **online** bridges hosting at least one member instance.
- Every chain mutation fans out `task_chain_delta` to **all bridges in the
  routing set** (not just the actor's bridge).
- Comment notifications are narrower: `task_comment_notify` goes only to bridges
  hosting the assignee/reviewer recipients for that comment, with the recipient
  list scoped to that bridge.

### Single-writer, total order (the Hub serializes)

- Bridges are **not** allowed to mutate durable chain state. They only send
  **proposals** (`task_claim_request`, status/comment/vote via the normal
  bridge-asserted instance mutation path). The Hub applies them **one at a time**
  (single writer), producing a **total order** of chain revisions.
- Every chain carries a monotonic **`chain_version`** (integer, bumped on every
  applied mutation). Each snapshot/delta/notification includes the relevant
  version.
- Bridges keep the last-seen `chain_version` per chain and ignore stale/duplicate
  messages. Deltas are applied only from the expected base version.

### Concurrency resolution (examples)

- **Double auto-claim** (two agents race to claim the same queued task from two
  bridges): both send `task_claim_request`; the Hub applies the first (status →
  in_progress, assignee pinned), rejects the second with a conflict; both bridges
  then receive the higher-version delta/snapshot and converge — the loser stops
  trying to claim.
- **Vote quorum vs. concurrent status change**: votes are proposals applied in
  Hub order; quorum evaluation runs inside the same single-writer apply, so the
  promotion is deterministic. Bridges just reflect the resulting synced state.
- **Comment notify vs. role change**: the Hub computes comment recipients from
  the post-comment task state and tags the notification with that `chain_version`;
  Bridges deliver only after reaching that version, preventing stale-role pushes.
- **Nudge while state changes**: a bridge may deliver a nudge based on a slightly
  stale cache; harmless (worst case an extra ping). The next delta/snapshot
  corrects the cache; cooldown (`last_nudge_at`, Hub-durable) prevents storms.

### Delivery guarantees & reconnect (catch-up)

- `task_chain_delta` and `task_comment_notify` are **at-least-once**; version and
  notification-ID guards make duplicates safe.
- On **bridge (re)connect**, the Hub sends compact snapshots for chains the
  reconnecting bridge hosts a member of, plus pending metadata-only notifications
  relevant to local active instances.
- On **instance launch**, the Hub sends that instance's chain snapshot so the new
  agent's bridge is immediately in sync.
- If a member moves/relaunches to a **different bridge**, the routing set changes;
  the Hub starts syncing the new bridge and stops the old (which no longer hosts
  the member).
- If a bridge detects a missing delta (`base_chain_version` gap), it sends
  `task_chain_resync_request`; the Hub answers with a snapshot at the current
  version.

### Bridge process restart (cache reconstruction)

A bridge restart is a special reconnect where the bridge's in-memory task cache,
pending notification queue, and dedupe set may be gone while wrappers/tmux panes
may still be alive. Correctness rules:

1. On process start, the Bridge generates a new `bridge_boot_id`, clears all
   task-chain cache state, marks task policy `not_ready`, and rebuilds only the
   local runtime inventory it can prove (active wrappers/tmux sessions and their
   `agent_instance_id`s).
2. The first bridge hello/heartbeat includes `bridge_boot_id`, `cold_start:true`,
   and the recovered active instance IDs. This is still runtime metadata only —
   no task payloads.
3. The Hub treats `cold_start` / unknown `bridge_boot_id` as cache loss. It
   reconciles active instances, recomputes which chains are hosted by that bridge,
   sends `task_policy_sync`, then sends `task_chain_snapshot` for every hosted
   chain at the current durable `chain_version`.
4. The Hub sends `task_sync_complete` for that `bridge_boot_id` after the initial
   snapshot batch. Until then, the Bridge does **not** run auto-claim/auto-start
   and does not deliver version-gated task notifications except by first applying
   the required snapshot.
5. Any deltas racing with restart are either ordered after the snapshot on the WS
   stream or rejected by the Bridge's base-version check, causing a resync. The
   Bridge never applies a delta against an unknown/stale base.
6. Pending comment notifications are replayed from Hub metadata markers after the
   snapshot batch. Duplicate delivery after crash-before-ack is acceptable
   at-least-once behavior; duplicate command delivery within a boot is deduped by
   `notification_id`.

### What the bridge caches

Per `chain_id`: `{ chain_version, compact chain fields, compact tasks[],
members[], votes[], deps[], last_nudge_at[], policy_version }`. The cache is
**advisory-but-fresh**: it is only ever a projection of Hub truth at a known
`chain_version`. Decisions are made against the cache; **durable effects always
go back through the Hub** (which re-serializes and re-fans-out).

The Bridge also keeps a small pending-notification/dedupe cache:
`{ notification_id, chain_id, required_chain_version, recipient_ids, reason }`.
A bridge with no cache entry for a chain (missing sync) **defers** all decisions
and notifications for that chain until the next snapshot arrives.

### Failure modes

- **Hub down**: no propagation, no durable mutations; bridges keep running agents
  but make no new claim/status decisions (proposals fail → retried on reconnect).
  Local nudge delivery may continue from cache but is best-effort.
- **One bridge partitioned**: other bridges keep converging via the Hub; the
  partitioned bridge catches up via snapshot on reconnect (version guard discards
  anything it already had).
- **Duplicate/reordered delta/notify**: discarded or deferred by the
  `chain_version` / `notification_id` guards.
- **Bridge has a gap**: request snapshot; do not try to apply deltas against an
  unknown base.

## Thresholds / Config

Thresholds are **policy the Bridge applies**, but remain **Hub-configured** and
sent through `task_policy_sync` (so operators tune them in one place):
- Reuse `nudge_enabled`, `nudge_interval_seconds`, `nudge_ready_after_seconds`,
  `nudge_review_after_seconds`, `nudge_need_improvements_after_seconds`,
  `nudge_working_stale_after_seconds`, `nudge_cooldown_seconds`,
  `nudge_restart_grace_seconds`, `nudge_send_escape_prefix`.
- New: `auto_claim_enabled`, `auto_start_enabled` (default off until validated).
- Add `policy_version`; snapshots/deltas may reference it, but heartbeats do not
  resend the full policy.

## Explicitly Removed

- **Auto-complete chain when all tasks terminal.** Do NOT port
  `task_service_try_auto_complete_chain`. When all tasks are terminal, the Bridge
  may nudge the **coordinator** ("all tasks done — review and complete the
  chain"), but **no side changes chain status automatically**. Completion is a
  manual coordinator action.

## Protocol Changes

### Hub → Bridge (WS commands)

- `task_chain_snapshot` `{ command_id, bridge_id, chain_id, chain_version,
  snapshot: <compact chain projection>, policy_version }`
  - Sent only on bridge (re)connect, instance launch/member move, resync request,
    and gap recovery.
  - Snapshot is compact and excludes comment bodies/full UI detail.
- `task_chain_delta` `{ command_id, bridge_id, chain_id, base_chain_version,
  chain_version, mutation_id, ops[] }`
  - Sent on every applied mutation to all bridges in the chain routing set.
  - Contains only changed fields/ops.
- `task_comment_notify` `{ command_id, notification_id, chain_id, task_id,
  comment_id, chain_version, author_agent_instance_id,
  recipient_agent_instance_ids, reason }`
  - Sent after `comment_added` only to target recipient bridges.
  - Body-free, version-gated, deduped by `notification_id`.
- `task_policy_sync` `{ policy_version, policy }`
  - Sent on connect or when policy changes.
- `task_sync_complete` `{ bridge_id, bridge_boot_id, chain_ids[],
  max_chain_version }`
  - Sent after the initial snapshot batch for a bridge boot/reconnect so the
    Bridge can mark task policy ready for that boot.
- (reuse) `launch_agent` when the Hub itself needs to start something; most
  (re)launch decisions are local to the owning bridge.

### Bridge → Hub (over the bridge WS / relay)

- Extend the bridge hello / first heartbeat with `{ bridge_boot_id, cold_start,
  active_instance_ids[] }`. `cold_start:true` means the bridge has discarded task
  caches and needs snapshots before policy decisions.
- `task_chain_resync_request` `{ bridge_id, chain_id, have_chain_version,
  reason }` → Hub responds with `task_chain_snapshot`.
- `task_claim_request` `{ agent_instance_id, task_id, seen_chain_version }` → Hub
  validates against current version; applies if still claimable (single writer),
  else returns conflict. Either way the Hub re-propagates a delta/snapshot to the
  whole routing set.
- `task_nudge_delivered` `{ agent_instance_id, task_id, delivered_at,
  seen_chain_version }` → Hub records `last_nudge_at` durably; subsequent deltas
  include the changed cooldown entry.
- `task_notification_delivered` `{ notification_id, agent_instance_id,
  delivered_at }` → Hub marks the metadata-only notification marker delivered for
  retry/replay bookkeeping.
- `seen_chain_version` on proposals lets the Hub detect stale-cache decisions and
  reject them cleanly (optimistic concurrency).

### Wrapper push (reuse)

Add a new line type on the existing wrapper push socket (same path as
`"push":"agent_message"` / `"push":"startup_prompt"`):

```jsonc
{ "push": "task_notify",
  "task_id": "task_18c6…",
  "chain_id": "chain_18c6…",
  "comment_id": "cmt_18c6…",              // present for comment notifications
  "status": "review_ready",              // optional task status hint from cache
  "reason": "comment_added",             // comment_added | manual_nudge | stale_nudge | review_ready | auto_claimed
  "interrupt": false }
```

Wrapper renders a tmux line without embedding comment bodies, e.g.:
`Task task_18c6 has a new comment (comment_added). Run ./.heimdall/bin/ham-ctl agent tasks comments task_18c6.`

### REST (unchanged — the actor's own mutation still enters here)

Manual nudge, status change, vote, comment, claim etc. keep entering through the
**existing REST task-chain routes** (`POST /api/v1/task-chains/{id}/tasks/{tid}/
status|vote|nudge|comments`, etc.). The change is that after the Hub applies any
such mutation it:
1. bumps `chain_version`;
2. emits a compact `task_chain_delta` to the routing set;
3. for comments, emits metadata-only `task_comment_notify` to assignee/reviewer
   recipient bridges.

Response shapes are exactly those in
`docs/plans/ctl-unify-tasks-and-auth-parity.md` (task summary / detail / comment
/ vote / member / nudge), unchanged by this work. Responses may include
`chain_version` for clients that want optimistic concurrency.

### Example: compact snapshot

```jsonc
{
  "type": "task_chain_snapshot",
  "protocol_version": 1,
  "command_id": "cmd_18c6…",
  "payload": {
    "bridge_id": "brg_A…",
    "chain_id": "chain_18c6…",
    "chain_version": 9,
    "policy_version": 3,
    "snapshot": {
      "chain": {
        "chain_id": "chain_18c6…",
        "status": "active",
        "publish_state": "published",
        "coordinator_agent_instance_id": "inst_coord…"
      },
      "members": [
        { "agent_instance_id": "inst_A…", "role": "assignee", "bridge_id": "brg_A…" },
        { "agent_instance_id": "inst_B…", "role": "reviewer", "bridge_id": "brg_B…" }
      ],
      "tasks": [
        { "task_id": "task_18c6…", "status": "in_progress",
          "assignee_agent_instance_id": "inst_A…",
          "reviewer_agent_instance_ids": ["inst_B…"],
          "depends_on": ["task_18c5…"], "updated_at": "2026-07-29T…Z" }
      ],
      "votes": [],
      "last_nudge_at": [
        { "task_id": "task_18c6…", "at": "2026-07-29T18:20:00Z" }
      ]
    }
  }
}
```

### Example: mutation delta

```jsonc
{
  "type": "task_chain_delta",
  "protocol_version": 1,
  "command_id": "cmd_18c7…",
  "payload": {
    "bridge_id": "brg_B…",
    "chain_id": "chain_18c6…",
    "base_chain_version": 9,
    "chain_version": 10,
    "mutation_id": "evt_18c7…",
    "ops": [
      { "op": "comment_added", "task_id": "task_18c6…",
        "comment_id": "cmt_18c7…", "author_agent_instance_id": "inst_A…",
        "created_at": "2026-07-29T18:26:00Z", "comment_count": 4 }
    ]
  }
}
```

### Example: version-gated comment notification

```jsonc
{
  "type": "task_comment_notify",
  "protocol_version": 1,
  "command_id": "cmd_18c8…",
  "payload": {
    "notification_id": "notif_cmt_18c7_brgB",
    "chain_id": "chain_18c6…",
    "task_id": "task_18c6…",
    "comment_id": "cmt_18c7…",
    "chain_version": 10,
    "author_agent_instance_id": "inst_A…",
    "recipient_agent_instance_ids": ["inst_B…"],
    "reason": "comment_added",
    "created_at": "2026-07-29T18:26:00Z"
  }
}
```

The Bridge may receive this before the `task_chain_delta`. It must wait until
its local cache reaches `chain_version >= 10`, then deliver to `inst_B…` if still
local/running. If not caught up, request a snapshot.

### Bridge heartbeat (minimal `bridge_heartbeat`)

Existing shape already carries liveness. Keep it compact; add `idle_seconds` per
changed instance if useful:

```jsonc
{
  "type": "bridge_heartbeat",
  "protocol_version": 1,
  "bridge_id": "brg_A…",
  "bridge_boot_id": "boot_18c6…",
  "cold_start": false,                  // true only on first heartbeat after process start
  "heartbeat_seq": 42,
  "active_instance_ids": ["inst_A…"],
  "instances": [
    { "agent_instance_id": "inst_A…", "state_seq": 4,
      "runtime_status": "running", "activity_status": "idle",
      "idle_seconds": 420 }
  ],
  "capabilities_hash": "sha256:…"
}
```

No chain/task/comment/policy payloads in heartbeat. If the Hub needs a bridge's
chain watermarks, it sends an explicit lightweight request or relies on command
acks/resync requests.

### Bridge → Hub: `task_claim_request` (auto-claim proposal)

```jsonc
{
  "type": "task_claim_request",
  "protocol_version": 1,
  "command_id": "cmd_18c6…",
  "payload": {
    "bridge_id": "brg_A…",
    "agent_instance_id": "inst_A…",
    "task_id": "task_18c6…",
    "seen_chain_version": 9
  }
}
```

Hub applies (single writer). Result comes back as a normal `command_result`, then
a fresh delta/snapshot to the whole routing set:

```jsonc
// success
{ "type":"command_result","command_id":"cmd_18c6…",
  "payload": { "status":"succeeded",
               "result": { "task_id":"task_18c6…", "status":"in_progress",
                           "chain_version": 10 } } }
// conflict (someone else claimed, or stale version)
{ "type":"command_result","command_id":"cmd_18c6…",
  "payload": { "status":"failed",
               "error": { "code":"conflict",
                          "message":"task already claimed",
                          "current_chain_version": 10 } } }
```

### Bridge → Hub: `task_nudge_delivered` (cooldown bookkeeping)

```jsonc
{
  "type": "task_nudge_delivered",
  "protocol_version": 1,
  "command_id": "cmd_18c6…",
  "payload": {
    "bridge_id": "brg_A…",
    "agent_instance_id": "inst_A…",
    "task_id": "task_18c6…",
    "seen_chain_version": 10,
    "delivered_at": "2026-07-29T18:25:00Z"
  }
}
```

Hub persists `last_nudge_at[task_id] = delivered_at`, emits a tiny delta with the
changed cooldown entry, and acks:
`{ "type":"command_result","command_id":"cmd_…","payload":{"status":"succeeded"} }`.

## Bridge-Side State & Loop

```text
bridge process start/restart:
  generate bridge_boot_id
  clear task chain cache + pending notification dedupe
  recover active local wrappers/tmux instances only
  connect/heartbeat with cold_start:true + active_instance_ids
  wait for task_policy_sync + task_chain_snapshot batch + task_sync_complete

launch_agent(chain_id) ──────► store instance→chain_id
task_policy_sync ────────────► upsert policy[policy_version]
task_chain_snapshot ─────────► replace chain cache[chain_id] @ version
task_chain_delta ────────────► apply only if base version matches; else resync
task_comment_notify ─────────► hold until cache version >= notification version, then push

task_sync_complete ──────────► mark task policy ready for this bridge_boot_id

heartbeat loop (existing) + policy tick (new):
  send runtime-only heartbeat
  for inst in local live instances:
     if !task_policy_ready_for_boot: skip (await initial snapshots)
     chain = cache[inst.chain_id]; if none, skip (await snapshot)
     task  = current task for inst (assignee == inst, workable)
     idle_s = now - inst.last_activity
     if pending_comment_notify_ready(inst): deliver task_notify + ack delivered
     if manual_nudge_pending(inst): deliver + ack
     else if nudge_due(task.status, idle_s, cooldown): deliver + ack
     if auto_claim_enabled and claimable(task): task_claim_request → Hub
     if auto_start_enabled and assignee_offline(task): local relaunch (+grace)
```

Cooldown: Bridge times locally; Hub holds the durable `last_nudge_at` and emits
small `last_nudge_at_changed` deltas so restarted bridges don't re-storm.

## Durable Safety

- Hub keeps a small **pending notification / claim / nudge marker outbox** only
  for correctness across restarts and reconnects. This is not a scheduler — just
  retry/replay of decision reports and metadata-only task notifications.
- Bridge task caches are explicitly **not durable or trusted after restart**.
  Correct task state after a bridge restart comes from Hub snapshots keyed by the
  restarted bridge's active instance inventory and new `bridge_boot_id`.
- Comment notification outbox rows store IDs/version/recipient/delivery state
  only, never comment bodies.
- If a bridge is offline, its instances usually are not running there anyway →
  nothing to nudge; on reconnect/launch, snapshot + pending notification markers
  catch it up.

## Tasks & Sequencing

1. **Hub: versioned chain state + routing set.**
   - Add monotonic `chain_version` (bump on every applied mutation; single writer
     already — mutations go through the service).
   - Compute chain routing set from online bridges hosting member instances.
2. **Hub: compact snapshot + delta sync.**
   - Add compact chain projection writer for `task_chain_snapshot`.
   - Add `task_chain_delta` builders for create/update/status/vote/comment/member
     /publish/nudge mutations.
   - Fan out deltas on mutation; snapshots only on connect/launch/resync/gap.
   - Add `task_chain_resync_request` handling.
   - Treat a new `bridge_boot_id` / `cold_start:true` as cache loss: send policy,
     snapshots for all hosted chains, pending notification markers, and
     `task_sync_complete` before Bridge policy is enabled.
3. **Hub: version-gated task comment notifications.**
   - On `comment_added`, compute assignee/reviewer recipients from post-mutation
     state.
   - Send body-free per-bridge `task_comment_notify` only to target recipient
     bridges.
   - Add metadata-only notification marker/outbox and delivered ack handling.
4. **Bridge: chain cache + retain chain_id.**
   - Store `chain_id` per instance from `launch_agent`.
   - Handle `task_chain_snapshot` replace and `task_chain_delta` apply/gap
     detection.
5. **Bridge: comment notification queue + `task_notify` wrapper push.**
   - Gate pending notifications by `chain_version`.
   - Deduplicate by `notification_id`; deliver to local recipient instances;
     send `task_notification_delivered`.
6. **Bridge: nudge delivery + `task_notify` wrapper push.**
   - Deliver manual + stale nudges via wrapper push → tmux;
     `task_nudge_delivered` ack to Hub.
7. **Bridge: policy tick (staleness + cooldown).**
   - Add the tick to the heartbeat loop using cache + local idle + policy.
   - Keep heartbeat runtime-only and compact.
8. **Bridge: auto-claim → Hub `task_claim_request`; Hub applies + re-syncs.**
9. **Bridge: auto-start (local relaunch, guarded by grace/cooldown).**
10. **Coordinator "all-done" nudge (config-gated), no status change.**
11. **Config plumbing (`task_policy_sync`), durable claim/nudge bookkeeping,
    tests.**

## Validation

- `odin build src/hub`, `src/bridge`, `src/wrapper`.
- Assign a task to a live local agent → tmux nudge appears (event-driven delta +
  bridge deliver).
- Add a task comment as a non-recipient → assignee and reviewers receive
  `task_notify` on their owning bridges.
- Add a task comment as the assignee → reviewers are notified; assignee does not
  receive a self-echo unless configured.
- Confirm comment notification payloads contain IDs/version only: no comment body,
  markdown, artifacts, or full chain/task detail crosses Hub↔Bridge WS.
- Deliver `task_comment_notify` before its `task_chain_delta` in a test → Bridge
  defers until cache reaches the required `chain_version`, then delivers once.
- Replay duplicate `task_comment_notify` → one tmux push due to `notification_id`
  dedupe.
- Idle an assigned task past threshold → exactly one staleness nudge, cooldown
  respected; restart bridge → no re-storm (Hub-held `last_nudge_at`).
- Auto-claim: queued task + free local assignee → bridge requests claim → Hub
  flips to in_progress → agent nudged. Auto-start off by default; on → offline
  assignee relaunched then nudged.
- Multi-bridge: two members on two bridges → each bridge nudges/notifies only its
  own local recipients.
- **Cross-bridge convergence**: mutate the chain from Bridge A (status/comment);
  assert Bridge B receives the new `task_chain_delta` and its cache reaches the
  same `chain_version`.
- **Double-claim race**: two bridges send `task_claim_request` for the same queued
  task → exactly one wins, the other gets a conflict, both converge.
- **Reconnect catch-up**: take Bridge B offline, mutate the chain N times, bring B
  back → snapshot brings it to the latest `chain_version`, followed by pending
  metadata-only notifications as needed.
- **Bridge process restart with wrappers still alive**: restart Bridge B without
  killing local wrappers/tmux panes → first heartbeat has a new `bridge_boot_id`
  and `cold_start:true`; no auto-claim/auto-start/comment delivery occurs until
  policy + snapshots + `task_sync_complete`; cache reaches Hub's latest
  `chain_version` before decisions resume.
- **Gap handling**: drop one delta, deliver the next → Bridge requests snapshot
  and does not apply against the wrong base.
- **Heartbeat payload discipline**: assert heartbeats do not contain chains,
  tasks, votes, comments, or policy blocks; capabilities/policy are hashed or
  sent only when changed.
- Confirm **no** chain auto-completes; coordinator only nudged.

## Risks / Notes

- **Hub remains the authorization + durability boundary.** Bridge decisions are
  *proposals* (`task_claim_request`) the Hub validates and applies; the Bridge
  cannot mutate durable state directly. This keeps ownership/authz centralized
  even though policy runs on the Bridge.
- **Propagation fan-out**: a chain with members on N bridges → N small
  `task_chain_delta` sends per mutation. Full snapshots are bounded to
  connect/resync/gap; debounce/coalesce deltas per (chain, routing-set) within a
  short window if needed.
- **Comment notification fan-out** is narrower than chain delta fan-out: only
  bridges hosting assignee/reviewer recipients get `task_comment_notify`.
- **Serialization = Hub single writer.** Never let a bridge mutate durable state
  directly; all changes are proposals applied in Hub order → one total order, one
  `chain_version` sequence. Bridges never peer-to-peer.
- **Optimistic concurrency**: proposals carry `seen_chain_version`; the Hub
  rejects stale ones, and the resulting resync converges the loser. No locks.
- **Stale/missing bridge cache**: ignore duplicate versions, request snapshot for
  gaps, and defer all decisions/notifications for a chain with no cache entry
  until sync arrives. Hub is source of truth; bridge cache is advisory-but-fresh.
- **Bridge restart correctness**: a new `bridge_boot_id` invalidates all prior
  in-memory task state on that bridge; the Hub must resnapshot hosted chains from
  durable state before the Bridge resumes task policy.
- **Cooldown is Hub-durable** (`last_nudge_at` in snapshot/delta) so multi-bridge
  and restarts share one cooldown clock and don't double-nudge.
- **No full comments over bridge WS**: task comment bodies remain durable REST/RPC
  records; bridge notifications are fetch hints only.
- **No auto-complete** of chains — explicit removal.
- **Auto-start opt-in + guarded** (grace, cooldown, one active task/assignee) to
  avoid launch loops.
- Reuse existing transport (bridge WS commands, wrapper push, heartbeat); do not
  invent a new channel.
