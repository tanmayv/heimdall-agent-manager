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

### 5.1 Sessions (bidirectional, multiplexed)

- A **session** is a persistent connection between two bridges. **Whoever can dial, dials** (spoke
  dials hub; A or B dials each other). Once up it is symmetric: either end initiates streams.
- Carries multiplexed logical streams: request/response (proxied reads/writes), push frames
  (wake-ups/callbacks), keepalive.
- v1 transport: long-lived connection with length-prefixed frames (or WebSocket). Return traffic to
  a NATed spoke rides **down the session the spoke dialed** — this is what makes one-way reachability
  work.
- **Liveness = session presence.** No separate health poll. `status linked` iff the whole path's
  sessions are up.

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

Two phases. **Phase 1 is a pure lift-and-shift**: create the bridge and move the existing
direct-link transport out of the daemon behind the loopback seam, with **no topology/behavior
change** (still direct links only, still bidirectional-reachability assumption). Phase 2 adds the
routed overlay (relay, multi-hop, announced reachability) that the motivating topology needs.

## Phase 1 — Extract the bridge (behavior-preserving)

**Outcome:** `ham-bridge` binary exists; the daemon no longer dials peers directly; direct A↔B
federation works exactly as it does today, but through the bridge. No relaying yet.

### What moves OUT of the daemon → into `src/bridge/`

- `src/daemon/federation_transport.odin` outbound half: `federation_forward`,
  `federation_forward_start`, `post_with_timeout` peer dials, the delivery-outbox *transport* loop
  (~15 outbound-dial sites).
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

- Loopback server: `/bridge/send`, `/bridge/request`, `/bridge/reachable`, `/bridge/health`.
- Bridge config: `[[peer]]` (name, endpoint, token) — the direct links, moved from the daemon.
- One persistent session per configured peer (dial out; accept inbound). Deliver inbound to the
  local daemon's `/federation/*`. Transit outbox for a temporarily-down direct peer.
- Reachability = just the directly-configured peers with live/dead session status (no multi-hop yet).

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
- **BR-3** `GET /federation/peers` lists direct peers with live status sourced from the bridge.
- **BR-4** ACK-means-durably-accepted, idempotency dedupe, and scoped write authority preserved
  (reuse existing daemon handlers + outbox).
- **BR-5** No bridge configured ⇒ daemon runs local-only with federation disabled; no regressions.

## Phase 2 — Routed overlay (relay + multi-hop + announced reachability)

**Outcome:** the motivating topology works (A↔B, B→VPS, C→VPS, A cannot reach VPS; all talk to all).

- **BR-6** Bridge envelope `{src,dest,kind,idempotency_key,ttl,hops,payload,sig?}`; forward
  `if dest != self`; TTL drop.
- **BR-7** Distance-vector reachability propagation across sessions; `GET /bridge/reachable` returns
  `direct` + `relayed` entries with `via`/`hops`/end-to-end `status`.
- **BR-8** Per-hop transit store-and-forward with bounded queue + TTL; flush on session reconnect.
- **BR-9** Return traffic to a non-dialable spoke rides down the session the spoke dialed (one-way
  reachability works); VPS never dials B or C.
- **BR-10** End-to-end ACK + idempotency verified across 2 relay hops (A→B→VPS→C and back).
- **BR-11** Daemon `/federation/peers` + UI Settings pane show indirect daemons with their path
  (e.g. `B → VPS → C`) and live end-to-end status; `federation_reachability_changed` updates the UI
  live.
- **BR-12** Replay-on-reconnect driven by bridge reachability transitions across relayed paths.

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
