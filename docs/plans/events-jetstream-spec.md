# Spec: task-chain events over NATS JetStream (agents and bots follow chains)

Status: approved by the user on 2026-11-19 (plan task `task_18e95fd5dde4e59a`, chain `chain_18e8df0145a5f4ad`).
Integration branch: `feat/events` (off `main` v0.5.60). Earlier design: comments on `task_18e8df0a464c4feb` (revision 2 chose NATS JetStream with a transactional outbox).

## 1. Problem

- `effect_notify_coordinator` (`src/hub/service/taskv2/service.odin:516`) only notifies the coordinator.
- `flush_effects` (`service.odin:441-497`) delivers those `[taskv2]` lines as fire-and-forget bridge runtime commands:
  - the result is discarded,
  - nothing is retried or replayed,
  - the line is typed into the agent's terminal.
- Workers get nudges through the same path (`effect_nudge_instance`).
- The UI bus (`src/hub/service/events/event_bus.odin`) is in-memory only.
- The bot (`src/templates/bot.md`) has no subscription at all. It polls `task-chain list/show`, so it cannot tell the user what happened.

## 2. Decisions

| # | Decision |
|---|---|
| D1 | NATS JetStream is the queue engine. **NATS is required** for every deployment, self-hosting included. There is no SQLite fallback. |
| D2 | **Transactional outbox.** Events are written to `event_outbox` in the same SQLite transaction as the state change. A relay publishes them to JetStream. |
| D3 | **Only the hub talks to NATS.** Bridges and agents use `ham-ctl events …` through the hub API and never get NATS credentials. |
| D4 | Subscriptions belong to durable identities (`agt_…`), not instances. A restarted or relaunched instance resumes where its identity left off. |
| D5 | **Pull plus nudge, never push-typing.** Agents pull with `ham-ctl events next` and ack. The terminal gets at most one coalesced nudge line, and only when the agent is idle. |
| D6 | **Events carry no end-to-end-encrypted content** (vault rule). The envelope holds ids, enums and versions only. Consumers render their own wording. |
| D7 | Start with the **minimal catalog in section 4**. Other `[taskv2]` triggers stay on the old path and move over later, one at a time. |

## 3. Architecture

```
taskv2 state change ──same tx──▶ event_outbox ──relay──▶ JetStream stream HEIM_EVENTS
                                                          subjects: ev.<owner>.chain.<chain_id>.<type>
                                                                    ev.<owner>.task.<task_id>.<type>
                                                                    ev.<owner>.task.<task_id>.state   (rollup)
                                                                    ev.<owner>.chain.<chain_id>.state (rollup)
                                   durable pull consumer per subscription (subscriber agt_ id + chain scope)
                                                          │
                                         hub Agent Inbox service (the only NATS client)
                         ┌──────────────────┬─────────────┴───────┬───────────────────────┐
                 ham-ctl events next/ack   nudge / wake        UI bus + MCP           bot (agent) → Telegram
```

### 3.1 Envelope (JSON, CloudEvents-style names)

| Field | Meaning |
|---|---|
| `event_id` | hub-minted id. Also used as `Nats-Msg-Id` for publish dedupe. Consumers dedupe on it. |
| `type` | e.g. `task.state`, `task.review_requested_from_user` |
| `class` | `state`, `resolvable` or `occurrence` (section 5) |
| `owner_user_id` | tenant |
| `chain_id`, `task_id` | ids; `task_id` is empty for chain events |
| `topic_key` | resolvable events only, e.g. `task.<id>.review_request` |
| `entity_version` | the task's or chain's revision at the time of the event |
| `data` | small enum fields only, e.g. `{"state":"done"}` or `{"verdict":"request_changes","role":"reviewer"}` |
| `actor` | `user`, `agt_…` or `hub` |
| `occurred_at` | RFC 3339 |

### 3.2 Stream

`HEIM_EVENTS`:
- file storage, limits retention, `max_age` 14 days, `duplicate_window` 2 minutes;
- `allow_rollup_hdrs: true`, replicas 1 by default.

The hub creates or updates the stream idempotently at boot.

### 3.3 Hub config and startup (REQ-EVA-9)

- **Settings:**
  - `--nats-url` / `HEIMDALL_NATS_URL` (required),
  - `--nats-creds-file` / `HEIMDALL_NATS_CREDS_FILE` (optional),
  - `--nats-ca-file` / `HEIMDALL_NATS_CA_FILE` (optional).
- **Without a URL** the hub refuses to start, with a clear error.
- **When NATS is unreachable at runtime:**
  - the hub keeps serving;
  - the outbox buffers events;
  - `/health` shows `"events":{"status":"degraded","outbox_backlog":N}`;
  - the relay drains the backlog in order once NATS is back.
- **Relay:** one thread. It publishes rows in `outbox_seq` order, marks each row published after the PubAck, retries with backoff, and prunes published rows after 24 hours.

### 3.4 Subscriptions (REQ-EVA-2)

- **Table:** `event_subscriptions(subscription_id, owner_user_id, subscriber_agent_id, chain_id, task_id NULL, source role_default|explicit, filter_subjects, wake_policy, consumer_name, created_at)`.
- Each row maps 1:1 to a durable JetStream pull consumer.
- **Role defaults** are created and removed automatically by the hub:
  - coordinator: on chain membership;
  - worker: on lease grant, removed when the lease ends;
  - bot: on watch.

### 3.5 Agent API (REQ-EVA-3)

`ham-ctl events` verbs:

| Verb | Behaviour |
|---|---|
| `next [--wait 30s] [--limit 20]` | Hub long-poll. Returns live events after the freshness filter (section 5). |
| `ack <event_id…>` | Acknowledge events. |
| `watch --chain <id>` / `unwatch --chain <id>` | Add or remove an explicit watch. |
| `subscriptions` | List the caller's subscriptions. |

Delivery semantics:
- Delivery is at-least-once.
- An unacked event is redelivered after `ack_wait` (5 minutes).
- After `max_deliver` (10) attempts the event goes to subject `ev.dlq.<owner>…`. NATS has no built-in dead-letter queue, so the hub republishes on the max-deliveries advisory.

### 3.6 Nudge and wake (REQ-EVA-4)

- When live events are waiting for an agent whose instance is idle, the hub sends **one** nudge line through the existing notice command path: `[events] N new event(s) — run ham-ctl events next`. Nudges are coalesced to at most one per subscriber per 30 seconds.
- If the instance is stopped and an event's type is wake-worthy (section 4), the hub wakes it through the existing restart path.
- The freshness filter runs **before** any nudge or wake.

## 4. Event catalog v1 (minimal; user-approved table)

"Bot" means the user's bot, only for chains it watches. It watches automatically the chains it creates or forwards a request to, and any chain after `ham-ctl events watch`.

| # | Event | Written when (same tx) | Class | Notified by default | Wakes a stopped agent |
|---|---|---|---|---|---|
| 1 | `chain.state` | a chain becomes active, completed, failed or archived | state | coordinator, bot | bot: on completed or failed |
| 2 | `task.state` | a task's state changes (ready, in_progress, in_review, done, cancelled) | state | coordinator | no (pull only, no nudge) |
| 3 | `task.review_requested_from_user` | a task passes its review gate and is waiting for the user | resolvable | coordinator, bot | yes |
| 4 | `task.blocked_on_human` | `lease block --waiting-on user` | resolvable | coordinator, bot | yes |
| 5 | `task.requirements_changed` | a requirements amendment is committed | occurrence | worker holding the lease | yes |
| 6 | `task.review_verdict` | a reviewer or the user posts lgtm or request_changes | occurrence | coordinator | no |
| 7 | `task.merge_conflict` | merge-back of a done task fails with a conflict | resolvable | coordinator | yes |
| 8 | `chain.work_finished` | work batch finished, workflow run succeeded, or workflow run failed | occurrence | coordinator, bot | yes |

**Not in v1** (these stay on today's `[taskv2]` path): `agent_not_running`, `ready_unclaimed`, `budget_exhausted`, `oscillation`, `hold_stale`, `review_stalled`, `dependency_stalled`, `summary_overflow`, `proposal_decided`, `gate_rejected`, `workflow_budget`, `workflow_trigger_failed`, `solo_task_ready`, and the checkpoint and connection-restored nudges.

**Migration (dual-run).** For #3, #4, #5, #7 and #8, the old `[taskv2]` line stays enabled next to the event until the staging check (E7) shows parity. After that the old line is removed for those triggers only (E5b).

## 5. Supersession (REQ-EVA-11)

- **state:**
  - Published on `ev.<owner>.task.<id>.state` or `ev.<owner>.chain.<id>.state` with the header `Nats-Rollup: sub`.
  - NATS keeps only the latest message on that subject, so a subscriber that was away sees only the current state.
- **resolvable:**
  - Each event carries a `topic_key`.
  - The hub records resolutions in `event_topic_resolutions(owner_user_id, topic_key, resolved_at, resolved_by_event_id)`:
    - #3 is resolved by the user's verdict;
    - #4 is resolved when the block is answered or the task is unblocked;
    - #7 is resolved by a later successful merge or by cancellation.
  - At pull time, `events next` acks and skips any resolvable event whose topic is resolved, or whose `entity_version` is older than the entity's current version.
  - It also returns one `resolved` notice that refers to the earlier `event_id` when that event had already been delivered.
- **occurrence:** never collapsed.
- **Audit:** `task_events` and `workflow_run_events` stay the complete history. Supersession affects delivery only.

## 6. Requirements index

| ID | Summary | Phase |
|---|---|---|
| REQ-EVA-1 | catalog v1 producers write `event_outbox` in the same tx; the relay publishes with `Nats-Msg-Id` | E1 |
| REQ-EVA-2 | subscriptions plus role defaults ↔ durable consumers | E2 |
| REQ-EVA-3 | `ham-ctl events` verbs, hub pull API, at-least-once, DLQ | E2 |
| REQ-EVA-4 | coalesced, idle-aware nudge; wake for wake-worthy events | E3 |
| REQ-EVA-5 | dual-run then retire the old `[taskv2]` lines for #3, #4, #5, #7, #8 | E5 |
| REQ-EVA-6 | bot template uses events; proactive updates to the user | E4 |
| REQ-EVA-7 | UI bus and MCP `events.wait` replay from the stream | E6 |
| REQ-EVA-8 | metrics: consumer lag, redeliveries, DLQ, nudges, outbox backlog | E6 |
| REQ-EVA-9 | config, startup and degraded health | E0b |
| REQ-EVA-10 | packaging: NixOS module, SELF_HOSTING, CI nats-server harness | E0c |
| REQ-EVA-11 | supersession | E1 (class/topic), E2 (pull filter) |

## 7. Engineering rules

- **Odin binding to `nats.c`** (Apache-2.0):
  - Use only **synchronous** APIs: connect, `js_Publish` with msg-id, pull-subscribe fetch, ack/nak/term, and stream/consumer add/update/delete.
  - No async subscriptions, so no `nats.c` thread ever calls into Odin.
- **Static linking:** the Linux hub is a fully static musl binary (`flake.nix` `mkStaticLinuxOdin`). `nats.c` must link statically in that build. Build it without libsodium and with TLS through the OpenSSL already used for curl, or with TLS disabled if a localhost-only deployment is chosen. Record the decision in the E0a handoff.
- **Memory:** every `nats*_Destroy`, `natsMsg_Destroy` and `jsPubAck_Destroy` is called on every path. Reviewers check this explicitly. Tests use the tracking allocator.
- **No network I/O inside a transaction** (`src/hub/repository/sqlite/tx.odin:24-26`). Publishing happens only in the relay.
- **Tests:** run against a real `nats-server -js`. The test harness starts it on an ephemeral port with a temp store dir. In Nix, `pkgs.nats-server` is added to the dev shell and checks.
