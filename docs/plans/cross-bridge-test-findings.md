# Cross-Bridge Local Test — Findings

## Environment
- Fresh debug binaries built locally via `odin build ... -debug` into `.run-logs/bin/`.
- Fresh `hub.db`. One Hub (8081) + dev-proxy (8080) + two enrolled bridges A/B.
- The production **mundus** bridge was left untouched throughout.

## What works (verified against real hub + 2 real bridges)
1. Two bridges enroll, connect ("bridge hub runtime ready"), show `online`, and
   advertise the `claude` provider with `smart` tier (→ `anthropic/claude-opus-4-8`).
2. User token mint via dev-proxy; agent identity create; instance launch API all
   return 200 and create durable instances bound to the chosen bridge.
3. **NEW endpoint `GET /api/v1/bridge/actionable-tasks`** responds 200 with the
   compact projection using a real bridge token (returned `{"tasks":[]}` when no
   tasks target that bridge's instances).

## RESOLVED: launch crash was a pre-existing http-client double-free

**Root cause found + fixed.** `src/lib/http_client/http_client.odin::parse_response_bytes`
returned `Response.body` as a **slice into the transient recv buffer** (its
pointer landed right after the `\r\n\r\n` header terminator — hence the freed
pointer bytes `0d 0a 0d 0a`). Any caller doing `delete(resp.body)` (e.g. the
bridge bootstrap materializer's `defer delete(post_resp.body)`) then freed a
mid-buffer pointer → invalid free → SIGABRT. Fix: clone the body in
`parse_response_bytes` so `Response.body` is always independently heap-allocated
and safe to delete. After the fix, agent launch succeeds and a real
`claude-opus-4-8` pi agent boots, reports startup, and works tasks.

### Live cross-bridge result (2 bridges, real opus agents)
- Bridge A hosts alpha (coordinator), Bridge B hosts bravo (worker) — different bridges.
- `actionable-tasks` scoping verified: A sees only the upstream task
  (deps_satisfied=true); B sees only the downstream task (deps_satisfied=false).
- Drove upstream (alpha/A) to `completed` → **downstream (bravo/B) auto-promoted
  to `in_progress`** via the Hub chain-scoped cascade, and B's `actionable-tasks`
  flipped to deps_satisfied=true.
- bravo (opus-4-8 on B) received the cross-bridge nudge and began working the task
  (`Heimdall: working · thinking`). Full vertical slice confirmed end-to-end.

---

## (original blocker writeup, now resolved)
Launching an agent crashed the bridge with `SIGABRT` (`Abort trap: 6`):

```
malloc: *** error for object 0xa0d0a0d30303620: pointer being freed was not allocated
thread #N, stop reason = signal SIGABRT
  frame: runtime::delete_string
  frame: main::bridge_bootstrap_fetch_manifest_and_materialize + 6336
  frame: main::bridge_runtime_launch_agent + 1756
  frame: main::bridge_hub_handle_command
  frame: main::bridge_hub_runtime_loop
```

- It is a **double-free / invalid-free** in `bridge_bootstrap_fetch_manifest_and_materialize`
  (the protocol-2 manifest bootstrap path). The freed pointer's bytes are
  `0d 0a 0d 0a` (`\r\n\r\n`), i.e. a slice into an HTTP response buffer is being
  `delete()`d as though owned.
- **Confirmed pre-existing**: reproduces identically on the untouched **baseline
  bridge binary** (nix store, built Aug 13, before any of this work). My changes
  to `src/bridge/` are only `task_scheduler.odin` (new), `main.odin` (scheduler
  wiring), and the `hub_runtime_client.odin` notify-handler wake — none touch the
  bootstrap path. The lldb backtrace shows my scheduler thread merely sleeping.
- tmux itself works on this box (verified `tmux new-session`), so it is not a
  tmux/environment issue — it is a memory-ownership bug in the manifest
  materializer.

## Impact on this task
The launch crash prevents a *live agent* end-to-end run on this machine. It is
orthogonal to the cross-bridge auto-promotion/nudge feature and should be fixed
as its own bug. The feature itself is validated at the Hub state + HTTP layer
(see the API-level cross-bridge validation), which does not require a live agent
process.

## Suggested next step for the blocker (separate fix)
Instrument `bridge_bootstrap_fetch_manifest_and_materialize` to find the exact
`delete` on a non-owned slice (candidates: a `delete()` on a
`bridge_provider_json_extract_*` result that in some path aliases `resp.body`, or
a body freed both via `defer delete(post_resp.body)` and an element delete).
A quick mitigation is to prefer the protocol-1 fallback
(`bridge_bootstrap_fetch_and_materialize`) until the manifest path is fixed.
