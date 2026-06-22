# `ham-ctl agent-ready` Plan

## Goal

Replace implicit, pattern-based startup detection with an **explicit self-report** from the agent. When the wrapper-launched agent process is actually alive and accepting work, it calls:

```
ham-ctl --config ./config.toml --token <agent_token> agent-ready
```

The daemon takes this as the canonical signal that the agent has transitioned from `starting` to `running`. The agent is *instructed* to make this call as the first thing it does each session.

This decouples "process launched" (which the wrapper knows) from "agent is responsive and ready to work" (which only the agent itself can attest to).

---

## How this fits into execution state

Each agent has one execution state (managed by the daemon, see `EXECUTION_STATE_PLAN.md` if present, otherwise: `not_running` | `starting` | `running` | `stopping`).

`agent-ready` is the canonical transition `starting → running`. Without it, the agent stays in `starting` until the startup janitor times out and demotes it to `not_running` with detail `no_agent_ready`.

The wrapper's existing tmux-pattern detection (claude `⏵⏵ ` / `Welcome back` matchers) becomes a **fallback only** for providers that cannot reliably exec the CLI, or for backward compatibility. The explicit `agent-ready` call is preferred whenever the agent profile supports it.

---

## CLI shape

```
ham-ctl --config <path> --token <agent_token> agent-ready
```

- `--token` is the existing agent-token authentication mechanism used by every other agent-side CLI command (`tasks ...`, `memory ...`, `chat ...`).
- No additional arguments. The token identifies the calling agent; the daemon already maps `agent_token → agent_instance_id`.
- Idempotent — calling repeatedly is a no-op after the first successful call within a session.

Exit codes:
- `0` — ready signal accepted (state advanced to `running` or already `running`)
- non-zero with error JSON on stdout — token invalid, daemon unreachable, or agent not registered

---

## Daemon endpoint

Two equivalent ways to expose it; pick one:

**A) Top-level route** (matches `/startup`, `/heartbeat`)
- `POST /agent-ready`
- Body: `{"agent_token":"agt_..."}`

**B) Existing agent-rpc multiplexer** (matches `memory_list`, `tasks_next`, etc.)
- `POST /agent-rpc`
- Body: `{"agent_token":"agt_...","action":"agent_ready"}`

Recommend **B** — it reuses the agent-rpc auth + dispatch path already in `src/daemon/agent_rpc.odin` and keeps top-level routes from sprawling. The CLI command translates `agent-ready` to that RPC.

### Behavior

1. Look up the agent by `agent_token`. Reject 401 if unknown.
2. Find the agent's record in the registry.
3. If `execution_state == starting`: transition to `running`. Clear `execution_detail` and `execution_reason`.
4. If `execution_state == running`: no-op, return `{"ok":true,"already":true}`.
5. If `execution_state == not_running` or `stopping`: reject 409 with a body explaining the state. (Means the daemon thinks the agent should not be running but the agent contacted in anyway — likely a race; UI will see the stale state.)
6. Emit an `agent_lifecycle_changed` WS event so the UI repaints immediately.

Response on success:
```json
{"ok":true,"execution_state":"running","agent_instance_id":"claude@myproject"}
```

---

## What instructs the agent to call it

The starter prompt template (in `config.toml`) is the natural place — it is the very first message the agent reads.

### Current starter prompt (claude)
```toml
starter_prompt = "You are {display_name}. Your agent instance id is {instance}. Your token is {token}. Run {ctl_bin} --config ~/heimdall/config.toml --help to get started."
```

### New starter prompt
```toml
starter_prompt = "You are {display_name}. Your agent instance id is {instance}. Your token is {token}. Your VERY FIRST action: run `{ctl_bin} --config ./config.toml --token {token} agent-ready`. Then run `{ctl_bin} --config ./config.toml --help` to see what else you can do."
```

Apply to all three shipped agent commands (`pi`, `claude`, `codex`) in `config.toml`.

### Bootstrap files (AGENTS.md / CLAUDE.md)

The bootstrap-generated `IDENTITY` section already includes "Agent instance" and "Daemon URL". Add a new top-of-file instruction line in the IDENTITY section (in `src/wrapper/main.odin` → `build_agents_md`):

> "FIRST RUN: `./bin/ham-ctl --config ./config.toml --token <your-token> agent-ready` — this tells Heimdall you are alive. Do this before anything else."

The token cannot be inlined here (the wrapper does not have a stable place to embed it in the markdown without leaking via git), so keep it as `<your-token>` and remind the agent the token was given in the starter prompt.

---

## Wrapper-side change

The wrapper currently calls `report_startup_status(..., "ready", ...)` once the tmux pattern matches `Welcome back`. Keep that as a **secondary** signal — when both are present, daemon prefers `agent-ready`. When only the wrapper-side signal is present (agent didn't call agent-ready within the startup window), the daemon still treats the agent as `starting` with detail `awaiting_agent_ready` until either the call comes in or the janitor times out.

Concretely: do **not** change the wrapper's startup probe in this task — it stays as a "process appears responsive" hint. The change is daemon-side.

---

## Failure modes

| Situation | Result |
|---|---|
| Agent calls `agent-ready` immediately | `starting → running`, UI flips to Live |
| Agent ignores the instruction | Stays `starting` until `startup_stale_after_seconds` (config), then `not_running` with detail `no_agent_ready` |
| Agent token wrong / revoked | 401, agent sees error, can retry after re-register |
| Daemon unreachable | non-zero exit, agent sees stderr; agent should retry with backoff or surface the error in its first response |
| Multiple `agent-ready` calls | First wins, subsequent return `{"ok":true,"already":true}` |
| Agent calls `agent-ready` after a stop / crash | 409, agent sees the state, knows to exit cleanly |

---

## Implementation order

1. **Daemon: new RPC action**
   - In `src/daemon/agent_rpc.odin`, add `case "agent_ready":` dispatch to a new `handle_agent_ready` handler.
   - Handler looks up agent by token, advances state to `running`, emits lifecycle event.
   - If execution state is not yet wired (the `EXECUTION_STATE_PLAN.md` work hasn't landed), set `startup_status = "ready"` and `connected = true` as the interim equivalent.

2. **ham-ctl: new command**
   - In `src/ctl/main.odin`, add `agent-ready` dispatch.
   - Build request: `{"agent_token":"<token>","action":"agent_ready"}`.
   - POST to `/agent-rpc`. Print the response body. Non-zero exit on error status.

3. **config.toml: update starter prompts**
   - Update `wrapper.agent-cmd.pi.starter_prompt`, `wrapper.agent-cmd.claude.starter_prompt`, `wrapper.agent-cmd.codex.starter_prompt` to instruct the `agent-ready` call as the very first action.

4. **Bootstrap content**
   - In `src/wrapper/main.odin` → `build_agents_md` (or whichever section builder owns IDENTITY now), prepend a "FIRST RUN" instruction line in the IDENTITY section pointing at `./bin/ham-ctl --token <your-token> agent-ready`.

5. **Wire UI signal** (only if execution state plan has shipped; otherwise skip — current `connected:bool` already flips when agent-ready runs because the RPC will register the live ws session).
   - No change needed for the four-state model — `agent_lifecycle_changed` already triggers `refreshAgents`.

6. **Verify**
   - `nix build .#ham-daemon` and `nix build .#ham-wrapper` clean.
   - Start a claude agent. Watch the tmux pane: claude should run the ham-ctl command on its first turn. Confirm via `curl http://127.0.0.1:49322/agents/list` that the agent shows `connected:true` (and execution_state `running` if that plan has shipped).
   - Manually call the endpoint via `curl` with a valid token to confirm idempotency.

---

## Out of scope

- Periodic re-attestation (an `agent-alive` heartbeat from the agent itself, separate from the wrapper's heartbeat). Could be added later if wrapper heartbeats prove unreliable.
- Per-task ready signals (e.g. agent reports "I'm idle, send me a task"). Different problem.
- Replacing the wrapper's startup pattern matching wholesale — keep as fallback for now.
