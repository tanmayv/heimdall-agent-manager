# Daemon Federation: Remote Agents via Transparent Proxy

Status: Draft design
Scope: agents + messages/tasks only (v1)
Relationship to `docs/plan/multi-daemon/PLAN.md`: **orthogonal.** That doc is a
*client-side* merge (one UI, many daemons, daemons unaware of each other). This doc is
*server-side* federation (daemons aware of each other, routing requests peer-to-peer so a
reviewer on daemon B can act on a task owned by daemon A).

---

## 1. Goal

Let an agent running on a **remote daemon** participate in local work — primarily as a
**reviewer** — without that agent having local filesystem access and without replicating
databases between daemons.

Concretely: a task chain on daemon **A** can have a reviewer that is really `reviewer@B`
running on daemon **B**. To the chain, votes, participants, and UI on A, the reviewer looks
like a normal local instance.

Non-goals for v1:
- Cross-daemon coordinators, live status streaming, directory auto-sync of agent lists.
- Graceful stale-cache degradation (we accept hard availability coupling; see §9).
- Moving agents between daemons.

---

## 2. Chosen model: transparent proxy, zero remote storage

A remote agent is represented locally as a **dormant proxy instance** that carries a `remote`
block. The local daemon **stores nothing** for it. Two mechanisms only:

1. **Proxy** for state (reads *and* writes): classify by the record's owner daemon, forward the
   HTTP call with the peer token, stream the response back.
2. **Push** for notifications: redirect at the single delivery chokepoint
   `registry_send_ws_text` → `POST peer/federation/inbox`. Metadata only; the remote agent then
   fetches details back through the proxy.

This is the **same "metadata push + fetch durable state" split Heimdall already uses locally**
(WS notifications are metadata-only; agents fetch durable state after). Federation just makes
the "fetch" a reverse-proxy hop. That is why it is the least-invasive option that holds
together.

### 2.1 Exception: inbox message bodies are store-and-forward

"Zero remote storage" protects **owned, mutable records** — tasks, chains, votes, comments —
where replicating creates ownership/consistency problems (two daemons disagreeing on a task's
status). That reasoning does **not** apply to an agent-to-agent **inbox message body**, which
is:

- **immutable** — once sent, the body never changes (no consistency problem), and
- **single-recipient content** — it is addressed *to* the receiver (no shared ownership).

So inbox message bodies are **stored durably on the recipient daemon** at delivery
(store-and-forward, like email), not lazily re-fetched from the origin at read time:

- The body ships on the daemon-to-daemon `POST /federation/inbox` call (plain HTTP, **not** the
  WS channel, so the 3900-byte inline cap does not apply).
- The receiver stores it durably, keyed by the **recipient's** conversation id
  (`conversation_id_for_instance(target)`), matching the local model where a message is keyed
  by the target's conversation. Reads are then fully local and **offline-capable** — they do not
  depend on the origin daemon or the link being up.
- Read receipts still flow back to the origin sender via `POST /federation/callback`, so the
  sender learns when its message was read.

This is the correct application of the invariant, restated precisely:

> **Owned mutable state stays with its owner; immutable delivered content lives with its
> recipient.**

Everything else (task/chain/vote reads and writes) remains proxied/route-by-owner per §2.
(By the same logic, immutable artifact blobs are a future candidate for fetch-through +
durable cache on the recipient; see the artifacts phase.)

### Rejected alternatives
- **Replication / projection store** (each daemon keeps a synced copy): adds dedup, sync,
  staleness, `owner_peer_id` storage keys, reconciliation. Solves problems we don't have yet.
- **Central message daemon**: new infra, SPOF, doesn't match peer daemons.

---

## 3. Identity: the proxy instance is a pointer, never a store

Reuses the **existing dormant-instance create flow**. A remote agent is a dormant local
instance plus a `remote` block. **Zero new identity concepts.**

```
Agent_Instance_Record (local, dormant proxy)
  agent_instance_id      : reviewer-remote@A            (local id, used by tasks/votes/UI)
  kind/flag              : remote_proxy
  remote:
    peer_id              : "peerB"
    peer_url             : "http://B-host:49322"
    remote_agent_instance_id : "reviewer@B"             (B's native id)
```

- Local task routing, participants, votes, and UI use `reviewer-remote@A` unchanged.
- The daemon never launches a wrapper for a `remote_proxy` instance.

---

## 4. Peer link (durable, minimal)

```
Peer_Link_Record
  peer_id     : "peerB"
  peer_url    : "http://B-host:49322"
  peer_token  : bearer (per-link; used server-side only, never leaked to clients)
  status      : linked | unreachable          (see §8 liveness)
```

For v1 the operator configures peer links explicitly. No directory auto-sharing of agent
lists yet (deferred).

### 4.1 Config source: `[[peer]]` in `config.toml`

Peers are configured statically in `config.toml`. Each peer entry carries exactly three
fields — **name, endpoint, token** — and nothing else is persisted. The token is a
long-lived shared secret used for **all** federation calls to that peer; there is **no
separate re-authentication handshake** per request or per session.

```toml
# Peer daemons this daemon can borrow agents from (remote reviewers in v1).
# Repeatable array-of-tables: one [[peer]] block per peer.
[[peer]]
name     = "studio-mini"                       # stable display/link name (peer_id)
endpoint = "http://studio-mini.local:49322"    # peer daemon base URL
token    = "plk_studio_mini_shared_secret"     # bearer used for every call to this peer

[[peer]]
name     = "ci-box"
endpoint = "http://ci-box.local:49322"
token    = "plk_ci_box_shared_secret"
```

Rules:
- **Only these three fields are configured.** No per-peer client id, no issued session
  token, no refresh/expiry, no negotiated credential. The `token` value is the whole auth
  story for that link.
- **No re-authentication.** The same `token` authorizes every federation request in both
  directions (push wake-ups, proxied reads/writes, artifact fetch-through, health poll). A
  peer accepts a call iff the presented bearer matches the `token` it has configured for the
  caller. Rotating a link = editing the `token` on both sides and reloading config.
- **Bidirectional by symmetric config.** For A↔B to work, A lists B under `[[peer]]` and B
  lists A. There is no auto-registration; each side opts in by config. (Tokens may match or
  differ per direction; simplest is one shared secret per link pair.)
- **Config is the source of truth for links.** `Peer_Link_Record.status` (linked |
  unreachable) is **runtime-only** — derived from the health poll (§8), never written back to
  `config.toml`. The durable identity of a peer is its `[[peer]]` block; status is a live
  projection, consistent with Heimdall's "durable state on disk, transport/session state in
  memory" invariant.
- **Token stays server-side.** The `token` is read from `config.toml` by the daemon and is
  never surfaced to the UI/clients (§7.5). The Settings "Peer daemons" pane shows name +
  endpoint + live status only; it does not display the token after entry.

Parser note (implementation detail, not in this doc's scope to build): `[[peer]]` is a
repeatable array-of-tables, parsed like the existing `[[wrapper.agent-cmd.*]]`-style
repeated sections — a new `Peer_Config { name, endpoint, token }` collected into a
`peers: [dynamic]Peer_Config` on the daemon config, with a matching `Section.Peer` and an
`ensure_peer`/`parse_peer_key` pair mirroring `ensure_agent_command`/`parse_agent_command_key`.
The runtime `Peer_Link_Record` is hydrated from these config entries at startup; `status` is
filled by the health poll.

---

## 5. Routing rule: route by record-owner, not by actor

The single correctness rule that keeps proxying coherent:

> A task/chain/conversation is owned by the daemon it was created on. **All reads and writes
> for it forward to the owner daemon, regardless of who acts.**

Consequences:
- A remote reviewer *reads* an A-owned task → B forwards the read to A.
- A remote reviewer *votes/comments* on an A-owned task → the write forwards to A.
- The owner daemon remains the sole source of truth. No local storage of foreign records.

Classification happens by resolving the target instance/record up front: if it resolves to a
`remote_proxy` (or the record's owner is a peer), forward the whole request. One interceptor,
not per-endpoint code.

---

## 6. The two federation surfaces

### 6.1 Push (wake-ups) — notifications
Redirect at the existing chokepoint. Every agent notification (task assign, review_ready,
comments, nudges, chat, inbox) already funnels through `registry_send_ws_text` with a durable
outbox fallback (`task_notify_recipient_delivery`).

```
registry_send_ws_text_or_remote(agent_instance_id, payload):
    if rec, ok := remote_agent_lookup(agent_instance_id); ok:
        return federation_forward(rec, payload)   # POST peer/federation/inbox
    return registry_send_ws_text(agent_instance_id, payload)
```

Because the outbox wraps this call, remote delivery inherits retry/replay **for free** — with
one required change (§7 ACK).

Also wire the **inbox** path: `message_service_send_message` already emits
`.Remote_Route_Required` (currently `message_bus_emit` returns `false` → 404). Handle it so
agent-to-agent DMs to a remote reviewer don't 404 while task pings work.

### 6.2 Proxy (state) — reads/writes
```
POST /federation/inbox        # receive a pushed wake-up for a mapped local agent
GET/POST  <proxied reads/writes forwarded to owner daemon with peer_token>
GET /federation/artifacts/{id}# fetch-through by id (immutable blobs, cacheable)
```

On the remote (B) side, the reviewer is a **normal local agent** talking to **its own daemon**.
It has no idea it is a proxy.

---

## 7. Required invariants (do not skip)

These are the parts that break silently if omitted:

1. **ACK means "remote durably accepted," not "agent saw it."**
   `federation_forward` success must mean B **durably queued** the wake-up (B inserts into its
   own outbox before returning 200). Do **not** mark A's outbox entry delivered on a bare HTTP
   200, or messages vanish between A-thinks-done and B-never-delivered.

2. **Idempotency key on every pushed notification and every write callback.**
   Two hops + retries = duplicates (double votes, double nudges). Origin `event_id` is the key;
   the receiver dedupes by it.

3. **Write/callback authority is scoped.**
   A remote write may only touch tasks/records its mapped instance actually participates in.
   Reject callbacks for tasks where the mapped instance is not a required reviewer/participant.
   Never let the peer token mutate arbitrary state.

4. **Replay trigger for remote instances.**
   Local outbox replay fires on **local WS reconnect** (`task_notifications_flush_queue`). A
   remote proxy never connects a local WS, so queued items would rot. The **peer liveness poll**
   (§8) must trigger `notification_outbox_replay_pending` for remote instances when a peer
   transitions unreachable→linked.

5. **Peer token stays server-side.** The local daemon swaps in peer creds when forwarding;
   clients never see it. Enforce local user → allowed remote agent before using the token.

---

## 8. Liveness: peer connectivity IS the live/dead signal (v1)

We explicitly use **daemon connectivity as the remote agent's live/dead indicator** for now.

- A lightweight periodic health check (`GET peer/health` or `/daemon/info`) sets
  `Peer_Link_Record.status = linked | unreachable`.
- **A remote proxy instance is "online" iff its peer link is `linked`.** No per-agent liveness
  probe in v1.
- On `unreachable → linked` transition: surface recovery and trigger outbox replay (§7.4) for
  that peer's proxy instances.
- Surface `unreachable` into attention/UI so a stuck remote reviewer is visible (a permanently
  down peer would otherwise silently stall an `lgtm_required` gate).

This matches the accepted tradeoff in §9: no cached fallback, so "peer reachable" is a good
enough proxy for "remote agent usable."

---

## 9. Accepted tradeoff: hard availability coupling

Because remote state is proxied (not projected), a **down or slow peer makes remote reads
fail live** — there is no stale cache to fall back on.

Mitigations (v1):
- Timeouts on all forwarded calls.
- `unreachable` surfaced to attention/UI.
- Multi-reviewer gates with a permanently-down remote reviewer must be operator-resolvable
  (manual override / fallback reviewer) so a chain isn't wedged forever.

We accept this for a small set of trusted peers. Graceful stale degradation is a later phase.

---

## 10. Artifacts (FS-free data channel)

Cleanest part of the design:
- Review requests carry **artifact IDs, not FS paths**.
- Remote agent pulls by id → if the artifact is owned remotely, forward
  `GET peer/federation/artifacts/{id}` and stream bytes. Blobs are immutable → cache freely.
- Only **fully-baked, self-contained** artifacts are safe to share. Anything that is a pointer
  into an owner's VCS workspace/FS is **not** shareable (would leak the FS-free promise).
- A review **result** artifact produced by B is owned by B; A stores a **reference** and
  fetch-through-caches the bytes. This is the one accepted ownership asymmetry.

---

## 11. `ham-ctl --daemon-url` positioning

`--daemon-url` already works for every command family (verified). But:

> **Agents always talk to their home daemon.** `--daemon-url` cross-daemon is an
> **operator/read convenience**, not the agent work path.

If a remote agent pointed `--daemon-url` at the origin directly, it would need origin-issued
tokens, bypass its home daemon (no proxy/notification story), and break artifact brokering —
i.e. a second, competing federation mechanism. Don't do that.

---

## 12. Storage answer (settled)

**Not duplicated. Not projected. Just owned.**
Each conversation/task/chain has exactly one home daemon that stores it. Remote daemons store
nothing for foreign records — they proxy. No dedup, no sync, no `owner_peer_id` tables, no
staleness reconciliation. The only owned-elsewhere data is remote-produced artifacts, held as
references + fetch-through cache.

---

## 13. v1 scope checklist

1. `Peer_Link_Record` store + operator config.
2. Dormant `remote_proxy` instance with a `remote` block (reuses existing dormant create).
3. Notification redirect at `registry_send_ws_text` for remote targets.
4. `POST /federation/inbox` (durable-accept before ACK) + record-owner proxy forwarding for
   reads/writes.
5. Wire `.Remote_Route_Required` so inbox DMs to remote reviewers work.
6. Artifact fetch-through by id.
7. Peer liveness poll → link status + outbox replay trigger + attention surfacing.
8. Mandatory: ACK-means-durably-queued, idempotency keys, scoped write authority.

Deferred: directory auto-sharing, live status streaming, remote coordinators, stale-cache
degradation.

---

## 14. Starter scope: remote agents in task-assignment selection only

For the **first** UI milestone we limit the visible entry point to remote agents appearing as
selectable options in the **task assignment / reviewer picker** (Phases 0–1). The **priority
capability**, delivered in **Phase 2**, is **cross-daemon agent-to-agent messaging** — a local
agent can send to and read replies from a remote agent — with task wake-ups riding the same
channel. Full remote review (reading the task + voting back), artifacts, and dead-peer
hardening follow in Phases 3–5.

This keeps the first shippable slices tight: a peer link, a remote proxy instance, the picker
showing it, then the shared `/federation/inbox` channel carrying both agent messages and task
notifications so an assigned remote reviewer can be messaged and pinged.

Setup mock: `docs/plan/daemon-federation/setup-mock.html` (peer link setup + remote agents in
the assignment picker).

---

## 15. Phase-by-phase breakdown (estimates)

Estimates are engineer-days for one engineer familiar with the daemon; they assume the
existing dormant-instance create flow and notification outbox are reused as-is. Ranges reflect
"happy path" → "with the §7 invariants done properly."

### Phase 0 — Peer link plumbing  ·  ~2–3 d
- `[[peer]]` config parsing in `config.toml` (§4.1): `Peer_Config { name, endpoint, token }`
  collected into `peers: [dynamic]Peer_Config`; hydrate runtime `Peer_Link_Record` from it.
  (Three fields only; token is the whole auth story, no re-auth.)
- `GET peer/health` reachability check → `linked | unreachable`.
- `/daemon/info` self-id (already proposed in `multi-daemon/PLAN.md`) so peers key stably.
- **Exit:** two daemons can be linked and show reachable status. No agents yet.

### Phase 1 — Remote proxy identity + picker (starter milestone)  ·  ~3–4 d
- Extend dormant instance with a `remote` block (`peer_id`, `remote_agent_instance_id`).
- Create-remote-proxy flow (reuses dormant create; no wrapper launch).
- Picker: surface linked peers' advertised agents as a **Remote** section; selecting one
  creates/binds the proxy instance and assigns it to the task role.
- **Exit:** an A-owned task can have a remote reviewer selected. (Delivery not wired yet →
  Phase 2.)
- *This is the demoable "remote agent in task assignment" slice, minus live delivery.*

### Phase 2 — Notification push + agent-to-agent messaging  ·  ~6–8 d
**Priority: cross-daemon message send/read between agents is the core of this phase, delivered
alongside task wake-ups since both ride the same `/federation/inbox` channel.**
- `POST /federation/inbox` on the remote; **durable-accept before ACK** (§7.1). Carries two
  payload kinds from day one: `kind="notification"` (task wake-ups) and `kind="inbox_message"`
  (agent-to-agent DMs).
- **Agent-to-agent send (A → B):** wire `.Remote_Route_Required` in
  `message_service_send_message` (currently `message_bus_emit` returns `false` → 404) to push
  the message to `POST peerB/federation/inbox` when the target is a `remote_proxy`. B injects
  it as a normal local inbox message (metadata-only notify; agent fetches the body — identical
  to local inbox semantics).
- **Agent-to-agent read/reply (B → A):** B's agent reads/replies via its normal inbox; B
  forwards the reply back through `POST peerA/federation/callback` (`kind="inbox_message"`),
  A delivers it into the original sender's durable inbox. Read receipts flow the same way.
- `registry_send_ws_text_or_remote` redirect at the chokepoint (reuses the same push path for
  task notifications).
- Idempotency keys (§7.2); peer-token auth swap (§7.5).
- Peer-liveness poll triggers `notification_outbox_replay_pending` for remote instances (§7.4).
- **Exit:** a local agent can DM a remote agent and receive its reply end-to-end; assigning/
  `review_ready` on A also pings `reviewer@B`; both survive a B restart.
- *This is the priority milestone: bidirectional agent messaging across daemons works.*

### Phase 3 — State proxy (reads) + results (writes)  ·  ~5–7 d
- Route-by-owner interceptor: forward reads for remote-owned records.
- Remote reviewer's vote/comment forwards to the owner daemon; scoped write authority (§7.3).
- **Exit:** remote reviewer can read the task and cast a vote that lands durably on A;
  A's chain gate resolves.

### Phase 4 — Artifacts (FS-free channel)  ·  ~3–4 d
- `GET /federation/artifacts/{id}` fetch-through + immutable cache.
- Result-artifact reference from remote (accepted ownership asymmetry).
- **Exit:** remote reviewer reviews a diff artifact and returns a result artifact.

### Phase 5 — Hardening  ·  ~2–4 d
- Attention surfacing for `unreachable` peers / stuck gates; timeouts everywhere.
- Operator override / fallback reviewer for permanently-down peers (§9).
- Replay hygiene on `unreachable → linked` (drains queued wake-ups, callbacks, and messages).
- **Exit:** a dead peer is visible in attention within one poll interval and the operator can
  unblock a wedged gate without editing the DB. (Agent-to-agent DMs already work from Phase 2.)

**Rough total:** ~21–30 engineer-days to full v1. **Priority slice (Phase 0→2):** ~11–15 d gets
cross-daemon **agent-to-agent messaging** working, plus a remote reviewer selectable and
notified.

| Phase | Focus | Est (d) | Cumulative |
|---|---|---|---|
| 0 | Peer link plumbing | 2–3 | 2–3 |
| 1 | Remote proxy + picker | 3–4 | 5–7 |
| 2 | **Notification push + agent-to-agent messaging** | 6–8 | 11–15 |
| 3 | State proxy + results | 5–7 | 16–22 |
| 4 | Artifacts | 3–4 | 19–26 |
| 5 | Hardening | 2–4 | 21–30 |

---

## 16. Phase 2–5 implementation design

Phase 2 delivers the priority capability — **cross-daemon agent-to-agent messaging** — plus
task wake-ups over the same channel. Phases 3–5 let a remote reviewer **do the review
end-to-end** (read the task, vote back), exchange **artifacts** without FS access, and become
**robust** (dead-peer handling). This section is the concrete build plan for each.

### Terminology recap
- **Origin (A):** owns the task/chain/vote. Holds the local proxy instance
  `reviewer-remote@peerB`.
- **Peer (B):** runs the real agent `reviewer@s-r7f42`. B's agent talks only to B.
- **Local proxy id:** `reviewer-remote@peerB` (A-side). **Peer id:** `reviewer@s-r7f42` (B-side).

---

### Phase 2 — Notification push + agent-to-agent messaging (priority)

**Goal:** a local agent can send a message to a remote agent and read its reply, end-to-end;
task wake-ups ride the same channel.

#### 2a. One channel, two payload kinds
`POST /federation/inbox` (on the receiver) accepts a tagged envelope so messaging and
notifications share transport, auth, idempotency, and replay:
```json
{
  "origin_peer_id": "peerA",
  "kind": "inbox_message" | "notification",
  "target_agent_instance_id": "reviewer@s-r7f42",   // receiver-local (peer) id
  "conversation_id": "conv-...",                     // for inbox_message
  "message_id": "msg-...",                            // origin-assigned, dedupe key
  "body_ref": { "origin_peer_id": "peerA", "message_id": "msg-..." },
  "idempotency_key": "peerA:msg:conv-...:msg-..."
}
```
Bodies are **not** shipped inline (mirrors Heimdall's metadata-only notify): the receiver
injects a normal local inbox notification, and the agent fetches the body via a proxied read
(2c).

#### 2b. Send: A → B
- A's agent sends to the local proxy id `reviewer-remote@peerB` via the normal message path.
- `message_service_send_message` currently emits `.Remote_Route_Required` for unregistered
  targets and `message_bus_emit` returns `false` → 404. **Wire it:** if the target is a
  `remote_proxy`, resolve its `{ peer_id, remote_agent_instance_id }` and
  `POST peerB/federation/inbox` with `kind="inbox_message"`, mapping the target to B's peer id.
- B validates the peer token, records the conversation in its runtime **remote-work map**
  (`conversation_id → origin_peer_id`), and injects a metadata-only inbox notification for its
  local agent — identical to a local inbound message.

#### 2c. Read + reply: B → A
- B's agent fetches the message body via a proxied inbox read:
  `GET peerA/federation/messages/{message_id}` (or a conversation fetch), authenticated with
  A's peer token. B stores nothing durably.
- B's agent replies via its normal inbox send; B detects the conversation is origin-owned and
  forwards the reply to `POST peerA/federation/callback` (`kind="inbox_message"`). A stores it
  as a normal durable inbox message in that conversation and notifies the original A-side
  sender.
- **Read receipts** flow the same callback path (`kind="read_receipt"`), so unread counts stay
  correct on both sides. (Consistent with the agent-facing read-receipt model; no user-facing
  read fanout.)

#### 2d. Task wake-ups (same plumbing)
- `registry_send_ws_text_or_remote` redirect at the delivery chokepoint pushes
  `kind="notification"` envelopes for task assign/`review_ready`/nudges to `peerB` instead of a
  local WS. Reuses the durable outbox for retry/replay.

#### 2e. Invariants (MUST)
- **Durable-accept before ACK** (§7.1): B inserts into its own inbox/outbox before returning
  200; A only marks the send delivered on that ACK.
- **Idempotency** (§7.2): dedupe by `message_id` / `idempotency_key`; replays are no-ops.
- **Peer-token auth swap** (§7.5): A and B present the shared `[[peer]]` token; never exposed
  to clients/agents.
- **Replay** (§7.4): on `unreachable → linked`, queued messages and notifications drain in
  order via `notification_outbox_replay_pending`.

#### 2f. Exit criteria
A local agent DMs a remote agent; the remote agent reads the body (proxied) and replies; the
reply lands in A's durable inbox with correct unread/read state. Task wake-ups also reach the
remote reviewer. All of it survives a B restart mid-exchange.

---

### Phase 3 — State proxy (reads) + results (writes)

**Goal:** B's agent can read the A-owned task and cast a vote/comment that lands durably on A.

#### 3a. Route-by-owner read interceptor (on B)
When B's agent asks *its own* daemon for a task that is actually owned by A, B must forward
the read to A instead of looking in its local store.

- **How B knows it's remote:** the wake-up B received in Phase 2 (`/federation/inbox`) carries
  `origin_peer_id` + the origin task/chain ids. B records a lightweight, in-memory
  **remote-work map**: `{ origin_task_id → origin_peer_id }` for tasks its agents were pinged
  about. (Runtime-only; rebuilt from re-pushes on restart — consistent with "no remote
  storage.")
- **Interceptor:** in B's task read handlers (`handle_get_task`, `handle_get_task_comments`,
  `handle_get_task_chain`, `handle_get_task_chains/tasks`), before hitting the local store,
  check the remote-work map. If the id is origin-owned:
  ```
  GET  peerA/tasks/{task_id}            (+ peer_token for A)
  GET  peerA/tasks/{task_id}/comments
  ```
  stream A's response back to B's agent verbatim. B stores nothing.
- **Auth:** B presents A's `peer_token` (the shared secret from B's `[[peer]]` block for A).
  A authorizes because the token matches; A additionally checks the requested task actually
  has `reviewer-remote@peerB` as a participant (scoped read, mirrors §7.3).
- **List reads:** a remote agent's "my tasks" list on B is the **union** of B-local tasks and
  a per-origin `GET peerA/tasks?assignee=<local proxy id>` fan-out across linked peers it has
  remote work on. Keep it lazy: only query peers present in the remote-work map.

#### 3b. Result write forwarding (B → A)
B's agent votes/comments using the **normal** ctl/RPC against B (`tasks vote`, `tasks comment`,
`tasks done`). B detects the target task is origin-owned and forwards the mutation instead of
applying locally.

- **New endpoint on A:** `POST /federation/callback`
  ```json
  {
    "origin_peer_id": "peerB",
    "kind": "vote" | "comment" | "status",
    "task_id": "task-...",            // A's id
    "chain_id": "chain-...",
    "as_agent_instance_id": "reviewer-remote@peerB",  // the LOCAL proxy id on A
    "result": "lgtm" | "ngtm",        // for kind=vote
    "comment": "...",
    "idempotency_key": "peerB:vote:task-...:<hash>"
  }
  ```
- **A translates the callback into the existing durable mutation** — it records a normal
  `Task_LGTM_Vote_State` / `Task_Comment_State` **as the local proxy id**, reusing the same
  store paths as a local reviewer (`task_store` vote/comment append + `task_db_save_vote` /
  `task_db_save_comment`). No new vote model; the chain's `lgtm_required` gate resolves
  exactly as for a local reviewer.
- **Scoped write authority (§7.3, MUST):** A rejects the callback unless `as_agent_instance_id`
  is a `remote_proxy` bound to `origin_peer_id` **and** is a participant/required-reviewer on
  `task_id`. A peer can never vote as an arbitrary instance or on an unrelated task.
- **Idempotency (§7.2, MUST):** A dedupes by `idempotency_key`; a replayed callback is a no-op
  that returns the same result. B retries via its own outbox until A ACKs durably.
- **Timestamps (§11):** A stamps the vote/comment with **A's** clock on ingestion; B's clock is
  ignored to avoid skew reordering.

#### 3c. Exit criteria
Remote reviewer opens the task (proxied read), submits `lgtm`, the vote lands on A as
`reviewer-remote@peerB`, and A's chain gate auto-approves. Survives duplicate callbacks and a
B restart mid-review.

---

### Phase 4 — Artifacts (FS-free review channel)

**Goal:** the remote reviewer reviews a **diff artifact** (never touching A's FS) and returns a
**review-result artifact**.

#### 4a. Fetch-through by id (B pulls A's artifacts)
- The review request / task references artifacts by **id** (e.g. the chain's diff artifact),
  never by path.
- **New endpoint (both daemons):** `GET /federation/artifacts/{artifact_id}` — authenticated
  with the peer token; internally delegates to the existing `handle_get_artifact_content`
  blob-store read.
- On B, when its agent requests artifact `X` that resolves to an origin ref, B forwards
  `GET peerA/federation/artifacts/X`, streams the bytes to its agent, and **caches by id**
  (blobs are immutable → safe to cache indefinitely; key `(origin_peer_id, artifact_id)`).
- **Safety gate:** only **fully-baked, self-contained** artifacts are fetchable. A must refuse
  to serve artifacts that are pointers into a VCS workspace/FS (would leak the FS-free
  promise). Practically: the chain diff is materialized into a standalone artifact blob before
  it's referenced in a remote review request.

#### 4b. Result artifact (B → A, the accepted asymmetry)
- B's agent produces the review as a normal **artifact on B** (its blob store owns the bytes).
- The Phase 3 `/federation/callback` (kind=comment or a new `kind="artifact_ref"`) carries an
  **artifact reference**, not bytes: `{ origin_peer_id, remote_artifact_id }`.
- A stores a **reference** in its artifact metadata (a `remote` origin ref), and when the UI/
  agent opens it, A fetch-throughs `GET peerB/federation/artifacts/<remote_artifact_id>` and
  caches. This is the **one ownership asymmetry** (§10): result artifacts are owned by B,
  referenced from A.
- **Auth for reverse fetch:** A presents B's peer token (A's `[[peer]]` block for B).

#### 4c. Exit criteria
Remote reviewer fetches the chain diff artifact by id (no FS access), writes a review-result
artifact on B, and A can open/read that result via fetch-through. Cached blobs are not
re-fetched.

---

### Phase 5 — Hardening

**Goal:** a dead/slow peer is visible and
operator-resolvable rather than silently wedging a chain.

> Agent-to-agent inbox messaging (send/read/reply/receipts) is delivered in **Phase 2**, not
> here. Phase 5 is purely operational hardening on top of the already-working message and
> notification channels.

#### 5a. Dead-peer handling & attention
- **Liveness feeds attention:** when a peer flips to `unreachable` (§8 health poll), surface a
  derived item in `GET /attention` (mirrors how `merge_lifecycle` derives merge-decision
  items). One item per stuck `lgtm_required` gate that is waiting on a remote reviewer whose
  peer is down.
- **Timeouts everywhere:** all forwarded federation calls get bounded timeouts; a slow peer
  fails fast to `unreachable` rather than blocking A's request threads.
- **Operator override (§9):** an attention item for a wedged remote gate offers: (a) reassign
  the reviewer to a local agent, or (b) drop the remote `lgtm_required` participant so the
  gate can resolve on the remaining reviewers. Both are existing participant/reviewer
  mutations — no new task model.
- **Replay hygiene:** on `unreachable → linked`, the Phase 2 poll triggers
  `notification_outbox_replay_pending` for that peer's proxy instances so queued wake-ups and
  callbacks drain in order.

#### 5b. Exit criteria
Killing a peer surfaces an attention item within one poll interval, and the operator can
unblock the wedged gate without editing the DB. (Agent-to-agent DMs already work from Phase 2.)

---

### Cross-phase invariants (apply to every forwarded call in 3–5)
- **Durable-accept before ACK** (§7.1): every forward — read, callback, artifact ref, inbox —
  is only "done" once the receiver has durably accepted it.
- **Idempotency keys** (§7.2): every write/callback/DM carries one; receivers dedupe.
- **Scoped authority** (§7.3): a peer may only read/write records its mapped instance
  participates in.
- **Owner writes, peer references** (§12): A stays the source of truth for the task/vote; only
  result-artifact bytes are owned by B and referenced from A.
- **No new remote storage:** B's remote-work map and artifact cache are runtime-only and
  rebuildable; nothing durable about A's records is persisted on B.
