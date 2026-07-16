# Federated mesh: transitive federation and distinguishability

> **Scope of this doc.** This is the *identity* model for federating across more than two
> daemons, including the case where two daemons are only reachable **through** a third.
> It deliberately covers **only distinguishability** — how a daemon names, keys, dedupes,
> and attributes remote things across multiple hops. Transport/relay mechanics, retries,
> and security are **out of scope** here (see §9).
>
> **Trust assumption.** Every daemon in the mesh is fully trusted. We are **not** solving
> authentication, forgery, or confidentiality. The only problem is: *can daemon A always
> tell exactly which daemon owns a given agent/task/record, regardless of how many hops
> away it is or how it was reached?*

Related docs:
- `docs/plan/daemon-federation/README.md` — v1 **pairwise** transparent-proxy federation
  (remote reviewer between two directly-linked daemons). This doc is its transitive successor.
- `docs/plan/multi-daemon/PLAN.md` — client-side multi-daemon UI merge; already establishes
  the `(daemon_id, native_id)` namespacing and `/daemon/info` self-id this doc builds on.

---

## 1. The problem in one picture

```
A ── links ── B ── links ── C

A cannot reach C directly. A reaches C only via B.
Goal: A treats B and C as if both are part of A's own fabric.
```

The moment a third daemon appears **behind** a second one, v1's naming breaks — not because
of trust, but because v1 names remote things **relative to the local daemon** and **couples
identity to the route**. Both assumptions fail transitively.

---

## 2. Root cause: v1 uses relative, route-coupled names

The v1 proxy identity is:

```
reviewer-remote@peerB
```

This is **relative to A**. `peerB` is a link label that only means anything from A's seat, and
the identifier smashes together three things that must stay separate once there is a middle
daemon:

| Concept | v1 (conflated) | What it should be |
|---|---|---|
| **origin** — which daemon *owns* the agent/record | implied by `peerB` | absolute `daemon_id` (e.g. C) |
| **route** — how you currently reach it | implied by `peerB` | separate hop list (e.g. `[B]`) |
| **local handle** — the local stand-in instance | `reviewer-remote@peerB` | a purely local id |

Pairwise, origin and route are always the same neighbor, so conflating them is harmless.
Transitively, **origin (C) ≠ route (via B)**, and any id that conflates them becomes
ambiguous.

Every distinguishability failure in §5 is a place where a **relative** or **route-dependent**
name was used as an **identity**.

---

## 3. The fix: absolute identity, separate route

Two rules carry almost the entire model.

### Rule 1 — Identity is absolute and route-independent

- Every daemon has a **stable, globally-unique `daemon_id`**, returned by `/daemon/info`.
  This is **not** its relative peer-link name. (`multi-daemon/PLAN.md` already makes
  `daemon_id` the only backend-provided identity field; reuse it verbatim.)
- Every remote agent/task/chain/record is keyed by:

  ```
  (origin_daemon_id, native_id)
  ```

  never by the bare `native_id`, and never by the peer-link label.
- A bare `agent@scope` (e.g. `reviewer@s-2543dac336a4`) is **never** a mesh map key. The
  `@scope` suffix is locally generated and can collide across daemons; only the pair is unique.

### Rule 2 — Route is separate, mutable metadata

- A remote proxy binds to an **identity** plus a **route**:

  ```
  local_handle : "reviewer-remote@C"          (A-local, display/routing convenience)
  identity     : (origin_daemon_id = "C", native_id = "reviewer@s-123")
  route        : ["B"]                          (ordered next-hops; [] == direct)
  ```

- If C later becomes directly reachable, **identity is unchanged**; only `route` shrinks to
  `[]`. If the path to C changes (via D instead of B), only `route` changes. The proxy, its
  task participation, votes, and history all stay bound to the same identity.

> **Stated as an invariant:** *identity answers "which daemon owns this"; route answers "how
> do I reach it right now." They are independent, and only route may change under a stable
> identity.*

---

## 4. End-to-end origin stamping

For A to attribute anything correctly, the **origin `daemon_id` must travel end-to-end** in
every federation envelope (discovery entries, wake-ups, callbacks, results), and **relays must
pass it through untouched**.

```
Envelope (conceptual)
  origin_daemon_id : "C"          // set by the owner, never rewritten by a relay
  native_id        : "reviewer@s-123"
  route            : ["B"]        // transport metadata; may be rewritten hop-by-hop
  payload          : { ... }
```

- When B forwards C→A, B does **not** relabel the message as coming from B. B is transparent
  at the identity layer; it only touches `route`/transport.
- Because everything is trusted, B *will* pass origin through faithfully — but the field must
  **exist end-to-end**, or A physically cannot tell C's action from B's. Distinguishability is
  a data-model property here, not a trust property.

---

## 5. Where distinguishability breaks (and how the model resolves it)

Every case below has the same root (relative/route-coupled naming) and the same fix (absolute
`(daemon_id, native_id)` + separate route + end-to-end origin stamping).

1. **Relative-label ambiguity.** A's "peerB" and B's "peerB" may be different daemons. A link
   label is not portable across a hop. → Never key on the label; key on absolute `daemon_id`.

2. **Same daemon, two routes.** A links both B and D, and both can relay C. Relative naming
   shows "C's reviewer" as two different agents. → `(C, reviewer@s-123)` is **one** identity
   with two candidate routes; dedupe to one, keep the alternates as fallback routes.

3. **Native-id collision.** `s-2543dac336a4`-style ids are generated locally and can collide
   across daemons. → The pair `(daemon_id, native_id)` is the only unique key; a bare
   `agent@scope` must never be a mesh key.

4. **Return attribution.** A callback arrives A←B←C. A must record "C did this," not "B did
   this." → `origin_daemon_id = C` rides end-to-end; B passes it through.

5. **Self-recognition / loops.** A route could lead back to A. A can distinguish "a remote
   record reached via a loop" from "a genuine local record" **only** if it knows its own
   `daemon_id` and short-circuits when `origin_daemon_id == self`. → Absolute self-id makes
   loops detectable; source-routed explicit paths (§7) make them impossible to form.

6. **Diamond / echo.** A reaches C via B, then later links C directly (or via D). Same origin,
   multiple paths, possibly discovered at different times. → Collapse to **one** identity and
   re-point/extend `route`. Possible only because identity ≠ route.

7. **UI distinguishability.** The picker must show A-local `reviewer`, B's `reviewer`, and C's
   `reviewer` (reached via B) as three distinct, unambiguous options. → Display key is the
   absolute origin (`on C`), with an optional route breadcrumb (`via B`); never the local
   handle.

---

## 6. Discovery: where the naming contract is enforced

Discovery is transitive; the data plane can stay narrow. When A asks B for offerable agents,
B returns **absolute-stamped** entries:

```
GET  peerB/federation/agents
→ [
    { origin_daemon_id: "B", native_id: "reviewer@s-9",  route: [] },     // B's own
    { origin_daemon_id: "C", native_id: "reviewer@s-123", route: ["B"] }, // relayable via B
    ...
  ]
```

- B advertises its own agents (`origin = B`, `route = []`) **and** agents it can relay
  (`origin = C`, `route = [B]`, i.e. B's route to C, prefixed as A will traverse it).
- A merges all discovery responses into one directory **keyed by `(origin_daemon_id,
  native_id)`**, unioning/deduping routes per identity.
- **This response format is the single most important contract in the model.** The instant B
  returns a *relative* name instead of C's absolute `daemon_id`, distinguishability collapses.
  Enforce absolute origin here and most of §5 is free.

Loop/self guard at merge time: A drops any entry whose `origin_daemon_id == self`, and drops
routes whose hop list contains a cycle.

---

## 7. Addressing style: source-routed, not routing tables

Prefer **explicit source routes** over dynamic next-hop routing tables:

- A addresses C as `identity=(C, reviewer@s-123)`, `route=[B]`. The path is finite and
  explicit.
- **Loops are impossible by construction** (the path is enumerated; a hop already in the path
  is rejected). No BGP-style loop prevention, no path-vector convergence.
- Route selection when multiple exist: prefer `[]` (direct) > fewer hops > stable/last-known.
  This is a local policy decision on A; identity is unaffected by the choice.

Routing tables / id-based next-hop resolution are explicitly **deferred**; they buy dynamic
topology at the cost of loops, convergence, and debuggability we don't need yet.

---

## 8. Config shape

A daemon may reference a peer it cannot dial directly by giving it a route instead of an
endpoint:

```toml
# Directly reachable peer (v1 style)
[[peer]]
name     = "B"
endpoint = "http://B-host:49322"
token    = "plk_ab_shared_secret"

# Transitive peer: no direct endpoint, reached through B
[[peer]]
name      = "C"
route_via = "B"                 # ordered next-hop(s); no endpoint because A can't dial C
token     = "plk_ac_shared_secret"
```

Notes:
- `name` here is A's local label; the **identity** used for keying is C's absolute
  `daemon_id` (learned from `/daemon/info` relayed through B at link time), not this label.
- `route_via` may list multiple hops for multi-hop paths (`route_via = ["B", "..."]`).
- Direct vs transitive is just "has `endpoint`" vs "has `route_via`". Discovery can also
  populate transitive peers dynamically; config is the explicit/static form.

---

## 9. Out of scope (deferred to transport/relay design)

This doc is identity-only. The following are acknowledged but **not** designed here:

- **Relay transport mechanics** — how bytes actually traverse A→B→C and back, framing,
  connection reuse.
- **Reliability / store-and-forward** — who owns an in-flight message when C is down; whether
  a relay must durably queue (a possible, scoped relaxation of v1's zero-remote-storage rule).
- **Liveness propagation** — how "C reachable via B" is observed and surfaced; path is only as
  live as its weakest hop.
- **Path-aware timeouts** — A's timeout must exceed the sum of hop timeouts.
- **Artifact byte amplification** — C's blobs traversing C→B→A and caching at each hop.
- **Security** — authentication, forgery prevention, confidentiality, metadata privacy. Under
  the all-trusted assumption these do not block the identity model, but a real deployment
  would need them (see the pairwise doc's §7 invariants for the starting point).

---

## 10. Minimal edits to the existing v1 design

Almost the entire model lands via two changes to `docs/plan/daemon-federation/README.md`'s
proxy binding:

1. **Replace `peer_id` in the remote-proxy binding with an absolute `origin_daemon_id`**, and
   add a separate `route: [daemon_id...]` (empty = direct). Identity keys become
   `(origin_daemon_id, native_id)` everywhere they were `peer_id`-based.
2. **Stamp `origin_daemon_id` end-to-end in every federation envelope** (discovery, wake-up,
   callback, result) and require relays to pass it through untouched.

Everything else — dedup, loop/self detection, diamond collapse, UI labels, transitive
discovery — falls out of those two changes plus the discovery response contract in §6.

---

## 11. The model, compressed

> v1 identified remote things by **"which of my links"** — a relative, route-coupled name that
> only works between two directly-connected daemons. Transitive federation must identify them
> by **"which daemon owns them"** — an absolute `(daemon_id, native_id)` key — and treat
> **route as separate, replaceable metadata**. Trust is assumed; the only real problem is
> naming, and absolute origin-stamped identity solves it.
