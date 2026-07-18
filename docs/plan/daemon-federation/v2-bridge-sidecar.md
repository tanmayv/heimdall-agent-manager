# Federation v2: `ham-bridge` sidecar + routed overlay

This supersedes the **transport/routing/liveness** of v1 (`README.md`). It keeps v1's
**semantics** intact: ownership, transparent proxy instances, metadata-push + fetch-durable-state,
store-and-forward inbox bodies, idempotency, scoped write authority. Only *how bytes reach another
daemon* changes.

## 1. Goal

- A separate binary `ham-bridge` owns **all** cross-daemon connection + routing logic. The daemon
  keeps records/business logic and speaks **one** federation dependency: loopback to its own bridge.
- Support **relayed / multi-hop** topologies, so any daemon can reach any other as long as a path of
  bridges exists — even when a daemon cannot dial the peer directly.
- The daemon lists **both direct and indirect** reachable daemons (from the bridge), routes purely by
  `dest_daemon_id`, and re-exposes reachability to UI/`ham-ctl`.

### Motivating topology (the hard case we must support)

```
[daemon A] <-> [daemon B] --> [VPS] <-- [daemon C]
   A<->B: bidirectional
   B->VPS: one-way (B dials VPS)
   C->VPS: one-way (C dials VPS)
   A cannot reach VPS at all (only reaches B)
```

Requirement: A, B, C all talk to each other. A→C path is `A -> B -> VPS -> C` (two relay hops).
This forces: every bridge can relay, multi-hop routing, per-hop store-and-forward, and delivery
that rides the connection the far side dialed.

## 2. Architecture

```
Heimdall UI / ham-ctl / agents ──HTTP/WS──> ham-daemon ──loopback──> ham-bridge ⇄ bridge mesh ⇄ other bridges ──loopback──> other daemons
        (records only)                       (owns records)          (transport + routing only; opaque envelopes)
```

- **One bridge per daemon.** Local-only daemons run no bridge (zero overhead).
- **The UI/ctl/agents never talk to the bridge.** Their only server is their daemon (see §7).
- **The bridge never parses business objects.** It routes opaque envelopes keyed by
  `dest_daemon_id` + `idempotency_key`.

### Client boundary (invariant)

> UI / `ham-ctl` / agents → **daemon only**. Daemon ↔ bridge over **loopback**. Bridge ↔ bridge over
> the **overlay**. Any federation state a client needs (remote records, peer liveness) is surfaced by
> the daemon over connections the client already has.

## 3. The seam: daemon ↔ bridge contract (loopback)

Dumb, stable, business-agnostic. Loopback HTTP (v1 of the sidecar; unix socket optional later),
authenticated by a shared loopback token both processes get at launch.

### Daemon → bridge

```
POST /bridge/send      { dest_daemon, kind, idempotency_key, payload }
                       # async push or proxied write. Returns 202 once the bridge has DURABLY
                       # queued it (bridge inserts into its transit outbox before 202).
POST /bridge/request   { dest_daemon, method, path, body, timeout_ms }
                       # synchronous proxied READ. Bridge routes to dest, streams response back.
GET  /bridge/reachable # current reachable-daemon snapshot (see §4).
POST /bridge/health    # liveness/version handshake.
```

### Bridge → daemon (bridge delivers inbound traffic into the local daemon's EXISTING endpoints)

```
POST /federation/inbox      (UNCHANGED daemon endpoint — a pushed wake-up for a local agent)
POST /federation/callback   (UNCHANGED — a read receipt / write result for a local record)
GET/POST <proxied reads/writes> → daemon's normal REST, bridge injects the federation identity header
POST /federation/reachability  (NEW — bridge pushes a reachability snapshot on topology change)
```

Rules:
- `payload`/`body` are **opaque bytes** to the bridge. Only `dest_daemon` + `idempotency_key` +
  `kind` are read by the bridge.
- **`send` = durably accepted by MY bridge**, not delivered end-to-end. End-to-end delivery is
  confirmed by the destination daemon's ACK flowing back as a callback (§6).
- The daemon's existing `/federation/inbox` and `/federation/callback` handlers are **reused
  verbatim**; the bridge just becomes the local caller instead of a remote daemon.

## 4. Reachability: how the daemon lists direct + indirect daemons

The bridge runs the routing protocol (§5) and hands the daemon a **flat, annotated list**. The
daemon never computes hops.

### `GET /bridge/reachable` (bridge → daemon)

```jsonc
{
  "self": "daemon_A",
  "reachable": [
    { "daemon_id": "daemon_B",   "reach": "direct",  "next_hop": "daemon_B", "hops": 1, "status": "linked",      "via": [] },
    { "daemon_id": "daemon_VPS", "reach": "relayed", "next_hop": "daemon_B", "hops": 2, "status": "linked",      "via": ["daemon_B"] },
    { "daemon_id": "daemon_C",   "reach": "relayed", "next_hop": "daemon_B", "hops": 3, "status": "linked",      "via": ["daemon_B","daemon_VPS"] },
    { "daemon_id": "daemon_D",   "reach": "relayed", "next_hop": "daemon_B", "hops": 3, "status": "unreachable", "via": ["daemon_B","daemon_VPS"] }
  ]
}
```

- `reach: direct | relayed` → the "list both direct and indirect" requirement.
- `next_hop`/`hops`/`via` are **display + diagnostics**; the daemon routes solely by `dest_daemon`.
- `status` is **end-to-end** (every hop on the path is up).
- **No URLs, no tokens** cross this seam.

### Daemon-side projection (replaces URL-based `Peer_Link_Record` for reachability)

```odin
Reachable_Daemon :: struct {
    daemon_id: string,
    reach:     string,   // "direct" | "relayed"
    next_hop:  string,
    hops:      int,
    status:    string,   // "linked" | "unreachable"
    via:       []string, // display path
    last_seen_unix_ms: i64,
}
reachable_daemons: [dynamic]Reachable_Daemon  // in-memory projection, rebuilt from bridge snapshots
```

Runtime-only (like the live agent registry). Durable records reference `owner_daemon_id`;
reachability is a live projection. Refresh = bridge **push on change** (`POST /federation/reachability`)
+ slow daemon poll (`GET /bridge/reachable`) as backstop. On change the daemon fans a compact
`federation_reachability_changed` event on `/user-ws` so the UI updates live.

## 5. Bridge internals (transport + routing only)

### 5.1 Sessions (WebSocket, single-dial, bidirectional message flow)

- A **session** is a **persistent WebSocket** between two bridges. **Only one side dials** — whoever
  can reach the other (spoke dials hub; in a mutually reachable pair either side may dial, but a
  single session is enough). **We do NOT require both sides to be able to dial each other.**
- Once the WS is open it is **fully bidirectional**: either end sends frames over the same socket.
  This is the core property that removes any bidirectional-reachability requirement — return traffic
  to a non-dialable/NATed bridge rides **down the WebSocket that bridge dialed**. The dialer and the
  destination of a message are independent.
- The WS multiplexes logical streams by a per-frame `stream_id` + `kind`: request/response (proxied
  reads/writes), push frames (wake-ups/callbacks), route announcements, keepalive.
- **Reconnect is the dialer's job**: the side that dialed owns reconnect with backoff; the accepting
  side just waits to be re-dialed. (Reuses the wrapper/user-WS reconnect discipline already in the
  codebase.)
- **Liveness = session presence.** No separate health poll. `status linked` iff every WS on the
  path is currently open.

### 5.2 Routing table + forwarding

```
routing_table: daemon_id -> { next_hop_session, hops, via[] }
```

Envelope on the wire between bridges:

```
{ src_daemon, dest_daemon, kind, idempotency_key, ttl, hops, payload, sig? }
```

Forwarding: `if dest_daemon == self -> deliver to local daemon; else lookup next_hop -> forward`,
decrement `ttl` (drop at 0; loop/blackhole guard).

### 5.3 Reachability propagation (distance-vector)

Each bridge advertises, over every session, the set of `daemon_id`s it can reach + hop distance.
Neighbors add themselves as next hop and re-advertise. Link down → withdraw routes learned via that
session (poison/timeout). Example for the motivating topology:

```
C attaches to VPS  -> VPS: C (hop1 direct)
VPS <-> B          -> VPS advertises {C hop2} to B;  B advertises {A hop2} to VPS
B <-> A            -> B advertises {VPS hop2, C hop3} to A
=> A routing_table: { B: direct, VPS: via B, C: via B }
```

v1 may seed routes from static config (`default_route = <hub>`); the announced/dynamic form is the
target. TTL is mandatory regardless.

### 5.4 Transit store-and-forward (per hop)

If the next-hop session is down when an envelope arrives to be forwarded, the bridge **queues it**
(bounded size + TTL) and flushes on session (re)establishment. This is best-effort transport
buffering — **not** the durable source of truth (that stays in the daemon's outbox, §6).

## 6. Durability & invariants (kept from v1, hardened for relaying)

1. **End-to-end ACK.** The *destination daemon* acks by `idempotency_key`; the ack is relayed back
   to the source daemon as a callback. A bridge forwarding a frame is **not** an ack. The daemon's
   delivery outbox entry is marked delivered only on the end-to-end ack.
2. **Idempotency across hops.** Origin `event_id` is the key; the destination daemon dedupes
   regardless of path, so relay retries can't double-vote/double-nudge.
3. **Durable source of truth stays in the daemon.** The daemon keeps its existing
   `federation_delivery_outbox`; the bridge's transit queue is transient. Daemon replays its outbox
   when the bridge reports the destination `unreachable -> linked`.
4. **Replay trigger = reachability change.** Bridge pushes reachability; on a daemon becoming
   `linked`, the daemon fires `notification_outbox_replay_pending` for remote instances owned there
   (v1 §7.4, now driven by bridge signal instead of a health poll).
5. **Scoped write authority unchanged.** A remote write/callback may only touch records its mapped
   instance participates in. The daemon enforces this on inbound `/federation/*` exactly as today.
6. **TTL / loop protection.** Every envelope carries `ttl`; bridges decrement and drop at 0.
7. **(Future) end-to-end signing.** Envelope reserves `sig`. A relay can forward but must not be able
   to **forge** a mutation. v1 leaves it unused (trusted operator-owned hub + per-link bearer); the
   field exists from day one so E2E-auth is additive.

## 7. Security / trust

- **Loopback seam** authenticated by a shared token minted at co-launch; bridge binds loopback only.
- **Per-session bearer** between bridges (the v1 `[[peer]]` token concept, moved into the bridge).
- **Relay sees plaintext it forwards** (accepted for v1, trusted hub). §6.7 signing is the mitigation
  path for untrusted relays later.
- **Peer tokens leave the daemon entirely** — they live in bridge config now (§8), never surfaced to
  UI/clients.

---

# Migration plan

Two phases. **Phase 1** creates the bridge, moves all cross-daemon transport out of the daemon
behind the loopback seam, **and replaces the direct request/response HTTP dials with a persistent
WebSocket session** between bridges. This removes the bidirectional-reachability requirement in
Phase 1 itself: a single dialed WS carries traffic **both** directions, so a bridge that cannot be
dialed (NAT/one-way) still receives pushes/callbacks down the WS it dialed. Phase 2 adds the routed
overlay (relay, multi-hop, announced reachability) for indirect paths (A→B→VPS→C).

## Phase 1 — Extract the bridge onto a WebSocket session

**Outcome:** `ham-bridge` binary exists; the daemon no longer dials peers directly; bridges connect
over a **persistent bidirectional WebSocket**; and direct federation (A↔B, and one-way A→B where
only one side can dial) works through the bridge. No multi-hop relaying yet.

**Reachability requirement dropped:** Phase 1 no longer assumes both peers can dial each other. Only
one side needs to be able to open the WS; all message flow (including B→A pushes/callbacks) rides
that single socket.

### What moves OUT of the daemon → into `src/bridge/`

- `src/daemon/federation_transport.odin` outbound half: `federation_forward`,
  `federation_forward_start`, `post_with_timeout` peer dials, the delivery-outbox *transport* loop
  (~15 outbound-dial sites). These per-call HTTP dials are **replaced** by frames over the persistent
  bridge↔bridge WebSocket, not merely relocated.
- `src/daemon/federation_peers.odin` link/session management: `Peer_Link_Record` URL+token+status,
  `peer_link_find/create/update/remove`, health poll → become bridge-owned session/link state.
- `[[peer]]` parsing (`src/lib/config/config.odin` `Peer_Config`, `ensure_peer`, `parse_peer_key`)
  → moves to bridge config.

### What STAYS in the daemon (semantics)

- `/federation/inbox`, `/federation/callback`, proxied `/federation/*` read handlers, `/federation/start`,
  `proxies/bind` — unchanged (now called by the local bridge).
- The **durable** `federation_delivery_outbox` (source of truth) + idempotency + scoped-write checks.
- `remote_proxy` instance identity, route-by-owner classification.

### What CHANGES in the daemon (thin client)

- Replace `federation_forward(peer_id, route_kind, payload, key)` call sites (in
  `message_service.odin`, `task_http.odin`, `artifact_http.odin`, `merge_lifecycle.odin`) with
  `bridge_send(dest_daemon, kind, key, payload)` → `POST loopback/bridge/send`.
- Replace direct proxied-read dials with `bridge_request(dest_daemon, method, path, body)` →
  `POST loopback/bridge/request`.
- Replace `Peer_Link_Record[]`/health-poll status with the `Reachable_Daemon` projection hydrated
  from `GET /bridge/reachable` + `POST /federation/reachability`.
- `GET /federation/peers` now returns the reachable list (direct-only in phase 1).

### New: `ham-bridge` (phase 1 scope)

- Loopback server (from its daemon): `/bridge/send`, `/bridge/request`, `/bridge/reachable`,
  `/bridge/health`.
- **Bridge↔bridge WebSocket**: a WS server endpoint (`/bridge-ws`, peer-token authed) that accepts
  inbound sessions, **and** a WS client that dials each configured peer's endpoint. Exactly one
  persistent WS per peer pair is enough; whichever side can dial owns it (with reconnect+backoff).
- Frame the multiplexed streams over the WS (`stream_id` + `kind`): request/response, push,
  keepalive. Inbound frames are delivered into the local daemon's existing `/federation/*` endpoints;
  responses/callbacks are sent back over the **same** WS.
- Reuse `src/lib/ws` (wrapper/user-WS client) for the dialer and the codebase's WS server plumbing
  for the acceptor.
- Bridge config: `[[peer]]` (name, endpoint, token) — the direct links, moved from the daemon.
- Transit outbox for a temporarily-disconnected peer WS; flush on reconnect.
- Reachability = the directly-configured peers with live/dead **WS session** status (no multi-hop yet).

### Build / launch

- `flake.nix`: `ham-bridge = mkOdinPackage pkgs odin "ham-bridge" "src/bridge";` + `apps.bridge`.
- New `apps.daemon-with-bridge` (mirror `daemon-with-wrapper`): launches daemon + bridge, passes the
  bridge its store path, peer config, and a shared loopback token; rewrites daemon config with
  `bridge_url`/`bridge_token`.
- Daemon config gains `bridge_url` + `bridge_token`; if unset, federation is simply disabled (no
  bridge = local-only, as today with no peers).

### Phase 1 acceptance (REQ-IDs BR-1..)

- **BR-1** Daemon contains no outbound peer HTTP dials or `peer_url`/`peer_token`; all cross-daemon
  traffic goes daemon→loopback→bridge.
- **BR-2** Existing direct A↔B flows (remote reviewer wake-up, proxied task read, vote callback,
  inbox DM store-and-forward, artifact fetch-through) pass unchanged through the bridge.
- **BR-3** `GET /federation/peers` lists direct peers with live status sourced from the bridge’s WS
  session state.
- **BR-4** ACK-means-durably-accepted, idempotency dedupe, and scoped write authority preserved
  (reuse existing daemon handlers + outbox).
- **BR-5** No bridge configured ⇒ daemon runs local-only with federation disabled; no regressions.
- **BR-6** Bridges connect over a **persistent bidirectional WebSocket**; per-call HTTP dials are
  gone. The dialer owns reconnect+backoff; `linked` status tracks WS presence.
- **BR-7** **One-way reachability works for a direct pair**: with only A able to dial B (B cannot
  dial A), B→A pushes/callbacks are delivered down the WS A dialed. Verified with a directional
  test (block B→A dials, confirm a B-owned callback still reaches A).

## Phase 2 — Routed overlay (relay + multi-hop + announced reachability)

**Outcome:** the motivating topology works (A↔B, B→VPS, C→VPS, A cannot reach VPS; all talk to all).

- **BR-8** Bridge envelope `{src,dest,kind,idempotency_key,ttl,hops,payload,sig?}`; forward
  `if dest != self`; TTL drop.
- **BR-9** Distance-vector reachability propagation across WS sessions; `GET /bridge/reachable`
  returns `direct` + `relayed` entries with `via`/`hops`/end-to-end `status`.
- **BR-10** Per-hop transit store-and-forward with bounded queue + TTL; flush on session reconnect.
- **BR-11** Return traffic to a non-dialable spoke rides down the WS the spoke dialed; VPS never
  dials B or C.
- **BR-12** End-to-end ACK + idempotency verified across 2 relay hops (A→B→VPS→C and back).
- **BR-13** Daemon `/federation/peers` + UI Settings pane show indirect daemons with their path
  (e.g. `B → VPS → C`) and live end-to-end status; `federation_reachability_changed` updates the UI
  live.
- **BR-14** Replay-on-reconnect driven by bridge reachability transitions across relayed paths.

## Non-goals (v2)

- End-to-end encryption (sign-only reserved, not built).
- Dynamic mesh/gossip beyond distance-vector; >2 relay hops may work via TTL but are not a v2
  guarantee.
- Moving agents between daemons; cross-daemon coordinators (still v1 non-goals).

## Open questions

- Long-poll frames vs. WebSocket vs. raw-TCP mux for the bridge↔bridge session — pick in BR-6 spike.
- Loopback transport: HTTP now; unix-domain socket later for tighter local trust.
- Where relayed inbox **bodies** (store-and-forward, immutable) get durably stored when the recipient
  is multi-hop away — confirm they land on the recipient daemon (per v1 §2.1), buffered in transit
  bridges only.
