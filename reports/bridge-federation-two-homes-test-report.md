# Daemon Federation via Bridge — Test Report

**Date:** 2026-07-19
**Scope:** Two independent Heimdall daemons (each with its own heimdall home / `data_dir`)
federated through the `ham-bridge` sidecar mesh. Connect/disconnect + eventual-consistency
behavior.

**Binaries under test:** `result-daemon/bin/ham-daemon`, `result-bridge/bin/ham-bridge`
(rebuilt from current `src/` at test time; source was ahead of the committed `result*`
symlinks, so a fresh `nix build` was required).

---

## 1. Test strategy

### Topology (Phase-1 direct link, one bridge per daemon)

```
UI/ctl/agents ─HTTP─> daemon A (home-a) ─loopback─> bridge A ⇄WS⇄ bridge B <─loopback─ daemon B (home-b)
                         (owns records)              (transport + routing only)         (owns records)
```

- Each daemon has a **distinct `data_dir`** (`heimdall-home-a` / `heimdall-home-b`) → truly
  independent homes, no shared storage.
- `[[peer]]` links live in **bridge** config (v2 architecture); daemon config only carries
  `bridge_url` + `bridge_token` (loopback seam).
- Neither daemon dials the peer directly; all cross-daemon traffic rides
  daemon → own bridge → peer bridge → peer daemon.

### What we verify

Two automated E2E suites were added:

**A. `tests/test_bridge_federation_two_homes_e2e.py` — steady-state federation (7 checks)**

| ID | Check |
|----|-------|
| S0 | Two daemons boot healthy from two distinct homes |
| S1 | Both sides report peer `linked`, held stable, sourced from live bridge WS session |
| S2 | A binds a dormant `remote_proxy` pointing at a real agent on B (no wrapper launch) |
| S3 | A→B inbox DM is store-and-forwarded into B's durable inbox (metadata push + durable fetch) |
| S4 | B→A reply is forwarded back into A's originating conversation |
| S5 | Read receipt propagates B→A; origin sender observes `read=true` |
| S6 | Homes are independent — owner-only storage, no cross-home replication |

**B. `tests/test_bridge_federation_disconnect_recovery_e2e.py` — connect/disconnect eventual consistency (7 checks)**

| ID | Check |
|----|-------|
| D0 | Link established; `remote_proxy` bound |
| D1 | Kill bridge B → A observes peer `unreachable` (liveness = session presence) |
| D2 | Send DM while peer down → durably **accepted/queued** on A (not lost, not hard-failed) |
| D3 | Restart bridge B → A observes peer `linked` again |
| D4 | Queued DM **eventually delivered** to B after reconnect, with no manual retry |
| D5 | Kill **daemon B entirely**, send a 2nd DM, restart daemon B + bridge B → 2nd DM eventually lands |
| D6 | Exactly one copy of each message on B (idempotency across retries) |

### How to run

```bash
nix build .#ham-daemon -o result-daemon
nix build .#ham-bridge  -o result-bridge
python3 tests/test_bridge_federation_two_homes_e2e.py
python3 tests/test_bridge_federation_disconnect_recovery_e2e.py
# KEEP_LOGS=1 keeps the temp dir (daemon/bridge logs + sqlite homes) for inspection.
```

---

## 2. Results

**After the fix in this report, both suites pass reliably (7/7 each, repeated runs).**

- Steady-state suite: **7/7**, stable across 4+ consecutive runs.
- Disconnect/recovery suite: **7/7**, stable across 3 consecutive runs.
- Eventual consistency confirmed for **both** a transport-only outage (bridge down) and a
  **full peer-daemon restart** mid-exchange, with **no message loss and no duplicates**.

---

## 3. Issues found

### ISSUE-1 (product bug, fixed) — federation outbox had no periodic replay; a callback dropped during a link bounce was stranded forever

**Severity:** High (silent, permanent message loss under a common race).

**Symptom:** In the steady-state suite, the B→A reply (S4) failed **intermittently, then
consistently**. The read receipt (S5, same callback path, sent milliseconds later) always
succeeded, which is what made it look like a flake.

**Root cause (evidenced from `federation_delivery_outbox` on B):**

```
peer_id | route_kind | idempotency_key            | delivered_unix_ms | attempts
home-a  | callback   | read:home-b:msg_...        | 178...(set)       | 2   <- delivered
home-a  | callback   | reply:home-b:msg_...       | 0                 | 1   <- STUCK forever
```

The reply was forwarded exactly during the **startup dual-dial race**: both bridges dial
each other, one duplicate WS session is torn down (`bridge ws disconnected`), and
`federation_forward` (which by design always returns `false` and relies on a later
delivery-ack + replay, per BR-4) left the row pending. It was then **never retried** because:

1. **Replay is transition-only.** `reachable_daemon_apply_entry_locked` enqueues an outbox
   replay only on an `unreachable→linked` flip **or** a change in `last_seen_unix_ms`.
2. **`last_seen_unix_ms` only advances on session connect/disconnect** in the bridge
   (`bridge_peer_state_set` / `_connected`), **not** on each `/bridge/reachable` poll. So
   while the link stays continuously `linked`, the daemon sees no edge and never replays.
3. **The daemon's 30s poll didn't help.** In bridge mode `peer_link_records` is empty
   (peers live in **bridge** config), so `peer_link_probe_all`'s replay loop iterated zero
   records.

Net: any federation callback/notification that lands in the outbox undelivered while the link
is briefly bounced — and no status edge follows — is **stranded indefinitely**. This is a
real eventual-consistency hole, not just a test artifact.

**Fix (minimal, in `src/daemon/`):**

- Added `federation_delivery_outbox_replay_all_pending()`
  (`federation_transport.odin`): scans `SELECT DISTINCT peer_id ... WHERE delivered_unix_ms
  = 0` and replays each. `federation_forward_transport_accepted` is already a no-op for
  peers that aren't currently linked, so this is cheap and self-limiting.
- Called it from the existing poll worker `peer_link_probe_all()`
  (`federation_peers.odin`) as a **periodic safety net**, independent of any status edge.
- Reduced the poll interval `30s → 10s` (`PEER_LINK_POLL_INTERVAL`) so eventual consistency
  is reached in ~10s instead of ~30s.

This is what makes D4/D5 (and the previously-flaky S4) pass deterministically.

### ISSUE-2 (test-harness bug in the new suite, fixed) — `wait_for` predicate returned too early

The first draft of the S4 assertion polled `fetch_messages(...).get("messages")` and treated
any non-empty list as success. Since A's conversation already contained the *outbound*
message, the predicate returned immediately and the daemon was torn down (~2s) before the
reply could arrive — masking ISSUE-1 as a pure flake. Fixed the predicate to wait
specifically for the reply body. (Documented so future authors don't reintroduce it.)

### ISSUE-3 (startup robustness, observed, not fixed) — bridge dual-dial race on symmetric links

With A and B both configured to dial each other, startup logs show:

```
bridge ws dial failed ... backoff_ms 250
bridge ws accepted ...
bridge ws linked ...
bridge ws disconnected         <- duplicate session collapsed
```

Both sides open a WS, one is discarded. This is the trigger that first stranded the reply in
ISSUE-1. It is self-healing for **liveness** (a session survives), but it is the exact window
where an in-flight forward can be dropped. ISSUE-1's periodic replay now *compensates*, but
the race itself is still worth removing (see recommendations).

### ISSUE-4 (pre-existing, not mine) — two stale federation tests fail against v2 bridge

Verified by rebuilding the **original** (pre-change) binary — these fail identically without
my changes:

- `tests/test_federation_transport_e2e.py` — drives the removed
  `POST /federation/peers/reconnect` endpoint, now `410 "peer reconnect moved to ham-bridge
  websocket dialer"`.
- `tests/test_federation_peer_backend_static.py` — asserts `parse_peer_key(...)` exists in the
  **daemon** config parser, but `[[peer]]` config moved to the **bridge** in v2.

They are architectural drift, not regressions. They should be updated or retired.

---

## 4. Recommendations

### Code / robustness

1. **Keep the periodic outbox safety-net replay (ISSUE-1 fix).** Even after fixing the
   dial race, a periodic drain is the correct backstop for "durable-accept-before-ack" —
   any transport that can drop an in-flight frame needs a time-based retry, not only an
   edge-based one. Consider a modest backoff/attempt cap surfaced in the row so a
   permanently-bad payload doesn't replay hot forever (currently `attempts` is incremented
   but not used to throttle).

2. **Advance `last_seen_unix_ms` on every successful reachability poll**, not only on
   session state changes. That would make the existing transition-driven replay fire on its
   own and is a cheap belt-and-suspenders alongside recommendation 1.

3. **Deterministic single-dialer for symmetric links (ISSUE-3).** Pick the dialer by a
   stable rule (e.g. lexicographically smaller `daemon_id` dials; the other only accepts) so
   two bridges never both establish a session that must then be torn down. Removes the
   drop window entirely rather than relying on replay to paper over it.

4. **Make the replay/poll cadence configurable** (`[daemon]` or bridge config) instead of a
   compile-time constant, so operators can trade convergence latency vs. load.

### Testing / CI

5. **Adopt both new suites into CI** as the canonical bridge-federation E2Es. They are
   stdlib-only and self-contained (spawn their own daemons/bridges on free ports).

6. **Update or retire the stale tests (ISSUE-4)** so a green federation test run actually
   means something.

7. **Add a directional/one-way-reachability case (BR-7).** The design explicitly promises
   that if only A can dial B, B→A pushes still ride the WS A dialed. Worth an explicit test
   (block one dial direction, confirm a B-owned callback still reaches A).

### Architecture notes (validated by these tests — no change needed)

- **Owner-only storage holds:** S6 confirms no cross-home replication; the proxy on A and the
  native agent on B never leak into each other's durable stores.
- **Store-and-forward inbox bodies + durable-accept-before-ack hold:** D2/D5 show sends during
  an outage are queued durably on the sender and delivered after recovery.
- **Idempotency holds:** D6 confirms retries across reconnect/restart produce exactly one copy.
- **Liveness = session presence holds:** D1/D3 show peer status tracks the WS session.

---

## 5. Files

- `tests/test_bridge_federation_two_homes_e2e.py` — steady-state suite (new).
- `tests/test_bridge_federation_disconnect_recovery_e2e.py` — disconnect/recovery suite (new).
- `src/daemon/federation_transport.odin` — `federation_delivery_outbox_replay_all_pending()` (new).
- `src/daemon/federation_peers.odin` — periodic safety-net replay call + `PEER_LINK_POLL_INTERVAL` 30s→10s.
