# Local Cross-Bridge Test Plan (real `pi` agents, claude-opus-4-8)

Goal: prove the cross-bridge auto-promotion + auto-nudge vertical slice end-to-end
on one machine, using **one Hub** and **two Bridges**, with real `pi` agents
running the `claude` provider profile (`smart` tier → `anthropic/claude-opus-4-8`).

This exercises the code shipped so far:
- Hub chain-scoped auto-promotion on the mutation path.
- Hub `GET /api/v1/bridge/actionable-tasks` lean read.
- Bridge scheduler (poll → nudge/wake, local timing, coalescing).
- Cross-bridge cascade: upstream task completes on Bridge A → Hub promotes the
  downstream task whose assignee lives on Bridge B → fan-out wakes B's agent.

---

## 0. Prerequisites (verify once)

- `pi` on PATH (`pi --version` → 0.74.0 confirmed) and authenticated for Anthropic
  (pi-anthropic-oauth) so `anthropic/claude-opus-4-8` actually runs.
- `tmux` on PATH (confirmed).
- `nix` for building the binaries.
- The `claude` provider profile exists in `config.toml`
  (`smart = "anthropic/claude-opus-4-8"`).

Sanity check the model runs at all before wiring Heimdall:
```bash
pi --model anthropic/claude-opus-4-8 "say hi"   # confirms auth + model access
```

---

## 1. Topology

```
                       ┌────────────── Hub (127.0.0.1:8081) ──────────────┐
                       │  durable state + actionable-tasks + fan-out       │
                       └───┬───────────────────────────────────────┬──────┘
     dev-proxy (8080) ─────┘ (trusted-proxy auth for ctl/UI)        │
                                                                    │ bridge-ws
        ┌──────────── Bridge A ────────────┐        ┌──────────── Bridge B ────────────┐
        │ port 49323 / local-ep 49324      │        │ port 49423 / local-ep 49424      │
        │ run-dir /tmp/heimdall-bridge-A   │        │ run-dir /tmp/heimdall-bridge-B   │
        │ tmux session ham-agents-A        │        │ tmux session ham-agents-B        │
        │ hosts: agent "alpha" (pi/claude) │        │ hosts: agent "bravo" (pi/claude) │
        └──────────────────────────────────┘        └──────────────────────────────────┘
```

Two bridges are the crux: each hosts a different agent instance, so a chain with a
dependency across the two agents forces the cross-bridge cascade path.

---

## 2. Bring-up steps

### 2.1 Build
```bash
scripts/dev-stack.sh build   # builds hub, dev-proxy, bridge, ctl, wrapper
```

### 2.2 Start Hub + dev-proxy (reuse dev-stack, but do NOT start its single bridge)
We will start the Hub and proxy from dev-stack, then start two bridges manually so
each gets a distinct port / run-dir / tmux session / config. Simplest path:
extend `dev-stack.sh` with a `start-hub-only` + `bridge A|B` mode (see §6), or run
the commands inline as below.

```bash
ROOT=$(pwd); RUN=$ROOT/.run-logs; mkdir -p $RUN
# Hub
nohup ./result-hub/bin/ham-hub --listen 127.0.0.1:8081 --db $ROOT/hub.db \
  --migrations-dir $ROOT/src/hub/repository/sqlite/migrations \
  --trusted-proxy-cidr 127.0.0.1/32 >$RUN/hub.log 2>&1 & echo $! >$RUN/hub.pid
# dev-proxy (injects trusted-proxy user "tanmay")
nohup ./result-devproxy/bin/ham-dev-proxy --listen 127.0.0.1:8080 \
  --hub-url http://127.0.0.1:8081 --default-user tanmay >$RUN/dev-proxy.log 2>&1 & echo $! >$RUN/devproxy.pid
curl -s http://127.0.0.1:8081/api/v1/health   # expect {"ok":true,...}
```

### 2.3 Mint a user token (for direct ctl calls to the hub)
Through the proxy (trusted-proxy auth), issue a bearer token:
```bash
USER_TOKEN=$(curl -s -X POST http://127.0.0.1:8080/api/v1/me/tokens \
  -H 'content-type: application/json' -d '{"label":"cross-bridge-test"}' \
  | sed -E 's/.*"token":"([^"]+)".*/\1/')
echo "$USER_TOKEN"   # hut_...
```

### 2.4 Enroll two bridges
Create two enrollment tokens (via proxy), then enroll each bridge to get its own
`bridge_id` + `bridge_token` written to a per-bridge config.
```bash
enroll_token() { curl -s -X POST http://127.0.0.1:8080/api/v1/bridge-enrollments \
  -H 'content-type: application/json' -d "{\"label\":\"$1\",\"expires_in_seconds\":3600}" \
  | sed -E 's/.*"enrollment_token":"([^"]+)".*/\1/'; }

ETA=$(enroll_token bridge-A); ETB=$(enroll_token bridge-B)

./result-bridge/bin/ham-bridge enroll --hub http://127.0.0.1:8081 \
  --enrollment-token "$ETA" --bridge-token-file $RUN/bridge-A.token
./result-bridge/bin/ham-bridge enroll --hub http://127.0.0.1:8081 \
  --enrollment-token "$ETB" --bridge-token-file $RUN/bridge-B.token
```

### 2.5 Write per-bridge configs
Copy `config.toml` twice (A/B), setting the `claude` profile as an agent-cmd and
distinct data/run dirs. Key differences per bridge:
- `[daemon].bridge_token` = contents of the token file
- distinct `port`, `bridge_url` (local endpoint), `data_dir`
- nudge tuned SHORT for testing (see §4)

### 2.6 Start both bridges
```bash
start_bridge() { # $1=A/B $2=port $3=localep $4=runsdir $5=tokenfile $6=session
  HEIMDALL_HAM_WRAPPER_BIN=$ROOT/result-wrapper/bin/ham-wrapper \
  HEIMDALL_HAM_CTL_BIN=$ROOT/result-ctl/bin/ham-ctl \
  nohup ./result-bridge/bin/ham-bridge --config $RUN/bridge-$1.toml \
    --bind-host 127.0.0.1 --port $2 --hub http://127.0.0.1:8081 \
    --local-endpoint-port $3 --local-run-dir $4 \
    --bridge-token-file $5 >$RUN/bridge-$1.log 2>&1 & echo $! >$RUN/bridge-$1.pid
}
start_bridge A 49323 49324 /tmp/heimdall-bridge-A $RUN/bridge-A.token
start_bridge B 49423 49424 /tmp/heimdall-bridge-B $RUN/bridge-B.token
```

### 2.7 Verify both bridges online + providers registered
```bash
H="ham-ctl hub --hub-url http://127.0.0.1:8081 --user-token $USER_TOKEN"
$H bridges list          # expect 2 bridges, status online, claude capability present
```
(If a `bridges list` subcommand isn't exposed on ctl, query the API directly:
`curl -s http://127.0.0.1:8080/api/v1/bridges`.)

---

## 3. Create the cross-bridge scenario

### 3.1 Two durable agents, one per bridge
```bash
$H agents create --name alpha --tier smart      # will run on Bridge A
$H agents create --name bravo --tier smart      # will run on Bridge B
# Launch each pinned to its bridge (claude provider, smart -> opus-4-8):
$H launch --agent-id alpha --bridge-id <BRIDGE_A_ID> --provider claude --tier smart
$H launch --agent-id bravo --bridge-id <BRIDGE_B_ID> --provider claude --tier smart
```
Record the resulting `agent_instance_id`s: `INST_A`, `INST_B`.

### 3.2 A chain with a cross-bridge dependency
```bash
CHAIN=$($H task-chains create --title 'Cross-bridge cascade' | jq -r .chain_id)
# upstream assigned to alpha (Bridge A), downstream assigned to bravo (Bridge B)
UP=$($H tasks create   --chain-id $CHAIN --title 'upstream (alpha)'   --assignee-instance $INST_A | jq -r .task_id)
DOWN=$($H tasks create --chain-id $CHAIN --title 'downstream (bravo)' --assignee-instance $INST_B --depends-on $UP | jq -r .task_id)
$H task-chains publish --chain-id $CHAIN
```
(Confirm the exact `tasks create` flags for assignee/depends-on with
`ham-ctl hub tasks --help`; add them if missing.)

---

## 4. Nudge config for fast iteration

In both bridge configs, shrink the timers so the sweep is observable in seconds:
```toml
[daemon]
nudge_enabled = true
nudge_interval_seconds = 5
nudge_ready_after_seconds = 10
nudge_review_after_seconds = 10
nudge_working_stale_after_seconds = 15
nudge_cooldown_seconds = 20
nudge_restart_grace_seconds = 2
```

---

## 5. What to observe (the assertions)

### T1 — Same-bridge auto-promotion + claim
After publish, upstream (`UP`, alpha on A) should auto-promote `assigned →
in_progress` without manual start, and Bridge A should wake/keep alpha running.
```bash
$H tasks list --chain-id $CHAIN            # UP=in_progress, DOWN=assigned (blocked)
tmux ls; tmux capture-pane -t ham-agents-A -p | tail   # alpha alive, working
grep -i "actionable-tasks\|scheduler\|wake\|nudge" .run-logs/bridge-A.log | tail
```

### T2 — Downstream blocked while upstream open
`DOWN` must stay `assigned` (deps unmet). The Bridge B scheduler must NOT wake
bravo for `DOWN` yet (deps_satisfied=false in the actionable-tasks read).
```bash
curl -s http://127.0.0.1:8080/api/v1/bridge/... # (via bridge token) actionable-tasks shows DOWN deps_satisfied:false
grep -i "wake\|nudge" .run-logs/bridge-B.log | tail   # no wake for DOWN
```

### T3 — Cross-bridge cascade on completion (the headline)
Drive `UP` to terminal via alpha (or via ctl to simulate): `in_progress →
in_validation → validated_good → completed`. On `completed`:
- Hub auto-promotes `DOWN` to `in_progress` (chain-scoped recompute).
- Hub fans out `task_status_changed_notify` to **Bridge B**.
- Bridge B wakes **bravo** (was idle/stopped) so it can pick up `DOWN`.
```bash
$H tasks status --chain-id $CHAIN --task-id $UP --status completed   # or let alpha do it
sleep 3
$H tasks list --chain-id $CHAIN            # DOWN now in_progress
grep -i "task_status_changed_notify\|woke local target" .run-logs/bridge-B.log | tail
tmux capture-pane -t ham-agents-B -p | tail   # bravo now running/working DOWN
```
Expected log line on B: `bridge task_status_changed_notify woke local target <INST_B>`.

### T4 — Auto-nudge of a stale actionable task
Let `DOWN` sit `in_progress` past `nudge_working_stale_after_seconds` without
bravo moving it. Bridge B's scheduler should deliver a scheduled nudge (wrapper
push if live, else coalesced wake).
```bash
grep -i "notify_task_nudge\|scheduled" .run-logs/bridge-B.log | tail
tmux capture-pane -t ham-agents-B -p | tail   # nudge text delivered to bravo pane
```

### T5 — Coalescing / no wake for live agents
Confirm repeated sweeps do NOT relaunch a live agent (no duplicate tmux windows,
wake coalesced within 30s) and cooldown suppresses nudge spam.
```bash
grep -c "launch_agent\|woke local" .run-logs/bridge-B.log   # bounded, not per-tick
tmux list-windows -t ham-agents-B                            # single window per agent
```

---

## 6. Tooling to add (small, optional)

To make this repeatable, extend `scripts/dev-stack.sh`:
- `start-hub` : hub + dev-proxy only (no bridge).
- `bridge A|B`: enroll (if no token file) + start a named bridge with the right
  port/run-dir/session/config.
- `scenario` : mint token, create agents, launch on each bridge, create+publish
  the cross-bridge chain, print `CHAIN/UP/DOWN/INST_A/INST_B`.
- `assert`   : poll `tasks list` + grep bridge logs to check T1–T5, print PASS/FAIL.

This keeps the manual curl/ctl dance out of the loop and gives a one-command
regression: `dev-stack.sh start-hub && dev-stack.sh bridge A && dev-stack.sh
bridge B && dev-stack.sh scenario && dev-stack.sh assert`.

---

## 7. Teardown
```bash
for p in hub devproxy bridge-A bridge-B; do kill $(cat .run-logs/$p.pid) 2>/dev/null || true; done
tmux kill-session -t ham-agents-A 2>/dev/null; tmux kill-session -t ham-agents-B 2>/dev/null
# keep hub.db to inspect durable state, or rm to reset
```

---

## 8. Risks / things to confirm during first run

1. **ctl flag surface**: `tasks create --assignee-instance/--depends-on` and
   `launch --provider/--bridge-id` flags need confirming; add if absent.
2. **Provider registration**: a freshly enrolled bridge may need a
   `providers/refresh` before the Hub knows it can run `claude`. Verify via
   `bridges list` capabilities; call refresh if empty.
3. **Assignee ref shape**: tasks must carry an `agent_instance` assignee ref (not
   a user ref) for the scheduler to target a bridge — confirm `tasks create`
   produces that.
4. **Opus availability/cost**: opus-4-8 is slow/expensive; for pure
   orchestration checks, `normal` tier (sonnet) is cheaper and exercises the same
   cascade. Use opus only for the "real agent" confidence pass.
5. **Two bridges, one host**: distinct tmux sessions + run dirs + local-endpoint
   ports are mandatory to avoid collisions (baked into §2).
```
