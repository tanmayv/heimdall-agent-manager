# RCA: `stop` command does not stop a running agent

**Task:** task_18d199a09e6f7912
**Author:** coder (inst_18d199931bfc16bd)
**Date:** 2026-09-02
**Environment:** LOCAL hub + LOCAL bridge (NOT prod hub.mundus.in)

---

## Summary

The `stop` command is **not universally broken**. On the happy path (a running
agent whose launch was recorded by the *currently running* bridge process), stop
works correctly: it kills the tmux window and the wrapper/agent process.

The bug reproduces reliably in one concrete scenario: **the bridge process
restarts between launch and stop**. Because the bridge's launch registry
(`bridge_runtime_launches`) is **in-memory only** and is never rehydrated with
the tmux session/window/pane after a restart, a subsequent `stop`:

1. reports **success** to the caller (HTTP 202, command result `succeeded`,
   runtime `stopped`),
2. but **kills nothing** — the tmux window and the `ham-wrapper` + `pi` agent
   process keep running,
3. and the instance's `runtime_status` is promptly **resurrected to `running`**
   by the surviving wrapper's next liveness/subscribe signal.

Net effect from the operator's perspective: "I pressed stop, it said OK, but the
agent is still alive and shows as running."

---

## Reproduction (local hub + bridge)

### Stack brought up
```
scripts/dev-stack.sh start
# hub    127.0.0.1:8081
# proxy  127.0.0.1:8080  (default-user tanmay)
# bridge 127.0.0.1:49323, local-endpoint 49324
# tmux session: heimdall-bridge-49324
# bridge.log: "bridge hub runtime ready"
```
(The prod bridge on hub.mundus.in / ports 49333-49334 was left untouched;
dev-stack `stop` only targets local-hub processes.)

### Baseline — happy path stop WORKS
```
POST /api/v1/agent-instances  {agent_id, bridge_id, provider:claude, tier:cheap}
  -> inst_18d199c61765afc0, runtime_status=launching
# tmux window agent-inst_18d199c61765afc0 (@42 %43), wrapper pid 35967

POST /api/v1/agent-instances/inst_18d199c61765afc0/stop
  -> runtime_status=stopping
# AFTER: tmux window GONE, wrapper process GONE  ✅
```

### Bug repro — stop AFTER a bridge restart FAILS
```
POST /api/v1/agent-instances  -> inst_18d199ce59d6bea0
# tmux window agent-inst_18d199ce59d6bea0 (@43 %44), wrapper pid 37165

# 1) Kill ONLY the bridge process (simulating a bridge crash/restart):
kill $(cat .run-logs/bridge.pid)
#    wrapper pid 37165 STILL ALIVE, tmux window STILL ALIVE (they outlive the bridge)

# 2) Relaunch the bridge (same dev-stack args) -> "bridge hub runtime ready"
#    In-memory bridge_runtime_launches starts EMPTY.

# 3) Stop the instance:
POST /api/v1/agent-instances/inst_18d199ce59d6bea0/stop {reason:"rca-bug-repro"}
  -> HTTP data runtime_status: stopping        (looks fine)
  bridge-restart.log: "bridge hub runtime command stop_agent"   (received)

# AFTER (observed vs expected):
tmux window still there?   -> agent-inst_18d199ce59d6bea0   ❌ (expected: gone)
wrapper process still alive?-> 37165                        ❌ (expected: gone)
hub.db runtime_status      -> running (activity active)     ❌ (expected: stopped)
pane capture               -> pi agent still interactive, watchdog counting
```

`ps` confirms the whole tree survived the "stop":
```
37154 zsh -l -c cd '.../inst_18d199ce59d6bea0' && ( ham-wrapper bridge-runtime ... )
37165  └─ ham-wrapper bridge-runtime --agent-instance-id inst_18d199ce59d6bea0 ...
pane %44 pane_pid 37154
```

Manual `tmux kill-window -t @43` afterward cleanly removed the window and the
process tree — proving the processes were killable; the bridge simply never
issued the kill.

---

## Root cause (evidence-backed)

The failure is in the **bridge**, specifically the interaction between the
in-memory launch registry and the stop handler.

### 1. The launch registry is in-memory and non-persistent
`src/bridge/hub_runtime_client.odin`
```
81:  bridge_runtime_launches: [dynamic]Bridge_Runtime_Launch   // process-lifetime only
94:  bridge_runtime_launches = make([dynamic]Bridge_Runtime_Launch)
```
`bridge_runtime_record_launch` / `get_launch` / `remove_launch` (L863-885) only
ever touch this slice. There is **no disk persistence and no rehydrate-on-start**
of the tmux session/window/pane for an instance. (Confirmed: grep for
`restore|reconcile|rehydrate|load.*launch|persist.*launch` finds nothing that
repopulates launches.)

### 2. `stop_agent` silently no-ops when the registry has no entry
`src/bridge/hub_runtime_client.odin:526`
```odin
bridge_runtime_stop_agent :: proc(instance_id: string) -> bool {
    if strings.trim_space(instance_id) == "" do return false
    bridge_runtime_set_status(instance_id, "stopping", "idle")
    stopped := false
    if launch, ok := bridge_runtime_get_launch(instance_id); ok {
        stopped = tmux.kill_window(launch.tmux_session, launch.tmux_window)
        bridge_runtime_remove_launch(instance_id)
    } else {
        stopped = true          // <-- BUG: no launch record => claim success, kill NOTHING
    }
    bridge_runtime_set_status(instance_id, "stopped", "idle")
    return stopped
}
```
After a bridge restart `get_launch` misses (empty registry), so the `else` branch
runs, `stopped = true`, and the function returns success **without ever calling
`tmux.kill_window`**. The command dispatcher (L213-228) then reports
`succeeded` / runtime `stopped` back to the hub.

This is the exact layer/line where stop fails: **`hub_runtime_client.odin:533`
(`else { stopped = true }`)**, enabled by the missing rehydrate of the launch
registry.

### 3. A second, compounding defect: status is resurrected to `running`
Even though `stop_agent` sets status to `stopped`, the surviving wrapper's next
signal flips it back. `wrapper_endpoint.odin` handles
`wrapper.liveness.ping` and `wrapper.notifications.subscribe` by calling
`bridge_runtime_note_wrapper_signal` (L266-284), which reaches
`bridge_runtime_note_activity_signal` (`hub_runtime_client.odin:983`). For an
instance that has already seen start-success, that path does:
```
bridge_runtime_set_status_with_source_locked(instance_id, "running", ...)
```
So the still-alive wrapper (which the stop failed to kill) drives the instance
straight back to `running` — matching the observed `hub.db runtime_status=running`.
This means even if stop had *tried* to kill by pane and missed, the living
wrapper would mask the failure.

### Why the reported hypotheses shake out
- **command never sent (bridge-live gate)** — NO. Hub `stop_instance`
  (`agent_service.odin:695`) passed the live gate and sent the command; the
  bridge logged `bridge hub runtime command stop_agent`.
- **command not received** — NO. Received and logged post-restart.
- **tmux window/session name mismatch so kill_window is a no-op** — Not the
  trigger here; `kill_window` was **never called** because `get_launch` returned
  `ok=false`. (Name mismatch is a *latent* secondary risk in `kill_window`/
  `window_id_for_window` if a launch record existed but the window name drifted,
  but that is not what fired in this repro.)
- **child detached from the window and survives window kill** — NO; manual
  `kill-window` cleanly reaped the whole tree, so window kill is sufficient when
  it actually runs.
- **subsequent liveness/status report resurrects runtime_status** — YES,
  confirmed as a compounding factor (defect #3).

**Primary root cause:** the bridge loses its in-memory launch registry on
restart and `bridge_runtime_stop_agent` treats "no launch record" as success
instead of attempting to locate and kill the still-running tmux window/process.
**Compounding cause:** a surviving wrapper's liveness/subscribe signal
resurrects `runtime_status` to `running`, so the false-success stop is
immediately un-done in the UI/DB.

---

## Recommended fix direction (do NOT implement yet)

1. **Make stop authoritative even without a launch record.** In
   `bridge_runtime_stop_agent`, when `get_launch` misses, reconstruct the
   deterministic target and kill it: `session = bridge_runtime_tmux_session()`,
   `window = bridge_runtime_tmux_window(instance_id)` (both are pure functions of
   config + instance_id) and call `tmux.kill_window(session, window)`. Return
   success based on the actual kill / window-absence, not an unconditional
   `stopped = true`.

2. **Rehydrate the launch registry after restart.** Either persist launch
   records (session/window/pane/tokens) to disk and reload on boot, or rebuild
   them by enumerating existing `agent-<instance>` windows in the bridge tmux
   session on startup, so `get_launch` succeeds again and normal stop/pane ops
   work.

3. **Don't let a stop be silently resurrected.** After an explicit stop, either
   (a) mark the instance as intentionally-stopped so the next wrapper
   liveness/subscribe does not flip it back to `running`, or (b) ensure the
   wrapper is actually terminated so no signal arrives. Killing the window
   correctly (fix #1) largely addresses this, but the resurrection path in
   `note_activity_signal` should be reviewed so a stop cannot race a late
   liveness ping.

4. **Harden `kill_window` name matching** (defensive): `window_id_for_window`
   matches on `window_name_base`; if a status prefix other than the known
   `[Starting] `/`[Blocked] ` set is ever applied, the match fails and
   `kill_window` returns false. Consider killing by recorded `pane_id`
   (`tmux kill-window -t %pane`) as the primary, with name lookup as fallback.

The minimal, highest-value fix is **#1 + #2**: reconstruct the kill target from
`instance_id` and/or rehydrate the registry, so stop is correct regardless of
bridge restarts.

---

## Artifacts / evidence pointers
- Repro logs: `.run-logs/bridge.log` (initial), `.run-logs/bridge-restart.log`
  (post-restart stop shows only `stop_agent` received, no TMUX kill trace).
- Code: `src/bridge/hub_runtime_client.odin:526` (`bridge_runtime_stop_agent`),
  `:81`/`:863-885` (in-memory registry), `:973-1017` (status resurrection);
  `src/bridge/wrapper_endpoint.odin:266-284` (liveness/subscribe -> signal);
  `src/hub/service/agent/agent_service.odin:695` (`stop_instance`).
- Baseline instance: inst_18d199c61765afc0 (stopped correctly).
- Bug instance: inst_18d199ce59d6bea0 (survived stop; manually cleaned up).

---

## FIX — token-invalidation stop (task_18d19c4c6cd02caf, supersedes the tmux approach)

The first fix attempt (reconstruct-and-kill tmux windows + tmux-window-name
rehydrate on boot) was rejected as over-engineered/fragile. The shipped fix is a
simpler **token-invalidation** design with **ZERO tmux involvement by the bridge**.

Implemented in `src/bridge/hub_runtime_client.odin` + `src/wrapper/bridge_runtime.odin`
(`src/lib/tmux/tmux.odin` reverted to original — no diff):

- **STOP = invalidate the instance's local token only.**
  `bridge_runtime_stop_agent` now: marks stop intent, sets `stopping`, calls
  `bridge_agent_token_invalidate_instance(instance_id)` (already persisted to
  `local-tokens.jsonl` on invalidate), drops any in-memory launch record, sets
  `stopped`. It runs **no** `tmux.kill_window`/`kill_pane`/`window_exists`.
- **Wrapper self-reaps.** The ham-wrapper's ~1s `wrapper.liveness.ping` reads the
  bridge response; on an auth failure (token invalidated) it kills its child agent
  and exits (existing H7 restart-reap). It now also closes its **own** tmux pane
  (`tmux.kill_pane(cfg.pane_id)`) so the hosting login shell's
  "Press Enter to close" `read` doesn't leave an empty window behind. This is
  wrapper-side cleanup of its own pane — still zero bridge tmux.
- **Survives bridge restart.** Because token invalidation is persisted, a stop
  issued after a bridge restart still invalidates the (reloaded) token, so the
  superseded wrapper self-terminates within ~1s. No tmux enumeration/rehydrate —
  `bridge_runtime_rehydrate_launches` was removed. Live-agent knowledge comes from
  wrapper heartbeats, not tmux.
- **No resurrection.** A time-boxed stop-intent tombstone (`stopped_intent_unix_ms`,
  15s TTL) set at stop start and checked at the top of
  `bridge_runtime_note_activity_signal` prevents a late/duplicate wrapper signal
  (racing the ~1s self-reap) from flipping the instance back to running/starting.
  Cleared by a genuine (re)launch.

**Verification (local stack; prod hub.mundus.in untouched):**
- Happy path: launch → `/stop` → within ~1s the wrapper self-reaps (child + wrapper
  gone, window gone as a consequence of the wrapper closing its pane), hub.db
  `stopped` and stays stopped. Bridge log shows `invalidated local tokens ...
  (wrapper will self-reap)` and **no** tmux kill.
- Bridge-restart repro: launch → kill only the bridge (wrapper survives) → relaunch
  bridge (no rehydrate line) → `/stop` → persisted token invalidation → wrapper
  self-reaps within ~1s → process tree + window gone, hub.db `stopped`, stays
  stopped +6s. Zero tmux kill by the bridge.
- `nix build .#ham-bridge` and `.#ham-wrapper` green. No process/window leaks.
