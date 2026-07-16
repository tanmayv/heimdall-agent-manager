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

For the **first** milestone we deliberately limit the surface to **one entry point**: remote
agents appear as selectable options in the **task assignment / reviewer picker**. Everything
else (chat, inbox DMs, coordinator, artifacts) is added in later phases.

This keeps the first shippable slice tiny: a peer link, a remote proxy instance, the picker
showing it, and the notification redirect so an assigned remote reviewer actually gets pinged.

Setup mock: `docs/plan/daemon-federation/setup-mock.html` (peer link setup + remote agents in
the assignment picker).

---

## 15. Phase-by-phase breakdown (estimates)

Estimates are engineer-days for one engineer familiar with the daemon; they assume the
existing dormant-instance create flow and notification outbox are reused as-is. Ranges reflect
"happy path" → "with the §7 invariants done properly."

### Phase 0 — Peer link plumbing  ·  ~2–3 d
- `Peer_Link_Record` durable store + operator config (add/remove/list peer).
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

### Phase 2 — Notification push (wake-ups)  ·  ~4–6 d
- `registry_send_ws_text_or_remote` redirect at the chokepoint.
- `POST /federation/inbox` on the remote; **durable-accept before ACK** (§7.1).
- Idempotency keys (§7.2); peer-token auth swap (§7.5).
- Peer-liveness poll triggers `notification_outbox_replay_pending` for remote instances (§7.4).
- **Exit:** assigning/`review_ready` on A actually pings `reviewer@B`; survives B restart.

### Phase 3 — State proxy (reads) + results (writes)  ·  ~5–7 d
- Route-by-owner interceptor: forward reads for remote-owned records.
- Remote reviewer's vote/comment forwards to the owner daemon; scoped write authority (§7.3).
- **Exit:** remote reviewer can read the task and cast a vote that lands durably on A;
  A's chain gate resolves.

### Phase 4 — Artifacts (FS-free channel)  ·  ~3–4 d
- `GET /federation/artifacts/{id}` fetch-through + immutable cache.
- Result-artifact reference from remote (accepted ownership asymmetry).
- **Exit:** remote reviewer reviews a diff artifact and returns a result artifact.

### Phase 5 — Inbox DMs + hardening  ·  ~3–5 d
- Wire `.Remote_Route_Required` so agent-to-agent DMs to remote agents work.
- Attention surfacing for `unreachable` peers / stuck gates; timeouts everywhere.
- Operator override / fallback reviewer for permanently-down peers (§9).
- **Exit:** coordinator can DM the remote reviewer; a dead peer is visible and resolvable.

**Rough total:** ~20–29 engineer-days to full v1. **Starter demo (Phase 0→2):** ~9–13 d gets a
remote reviewer selectable *and* actually notified.

| Phase | Focus | Est (d) | Cumulative |
|---|---|---|---|
| 0 | Peer link plumbing | 2–3 | 2–3 |
| 1 | Remote proxy + picker (starter) | 3–4 | 5–7 |
| 2 | Notification push | 4–6 | 9–13 |
| 3 | State proxy + results | 5–7 | 14–20 |
| 4 | Artifacts | 3–4 | 17–24 |
| 5 | Inbox DMs + hardening | 3–5 | 20–29 |
