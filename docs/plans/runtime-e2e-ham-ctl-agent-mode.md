# Runtime E2E: ham-ctl agent mode (local Bridge endpoint) — RTE2E-7

## Objective

Implement `ham-ctl` **agent mode**: the CLI surface an agent uses after the
wrapper/env path exists. Agent mode talks **only** to the local Bridge endpoint
over JSONL v1 using the local agent token. It never holds or sends a Hub URL or
Hub credential — the Bridge is the sole runtime process with Hub access and
relays agent actions on the agent's behalf.

Satisfies **RTE2E-7** and preserves **RTE2E-9**.

## Scope / non-goals

- In scope:
  - env/config discovery of `HEIMDALL_BRIDGE_ENDPOINT` and `HEIMDALL_AGENT_TOKEN`,
  - JSONL v1 local endpoint client (Unix primary + loopback fallback),
  - chat / task / artifact / memory / start_success / context methods,
  - clear relay/offline errors.
- Out of scope: direct Hub fallback from agent mode.

## Design

Agent mode is config-free and dispatched early (before loading any daemon
config), parallel to the existing `hub` user mode:

```
ham-ctl agent --bridge-endpoint <unix:|tcp:> --agent-token <hlat_...> <resource> ...
ham-ctl agent <resource> ...   # endpoint/token from env
```

Discovery precedence:
- Endpoint: `--bridge-endpoint` → `HEIMDALL_BRIDGE_ENDPOINT`.
- Token: `--agent-token` → `HEIMDALL_AGENT_TOKEN`.

### Wire protocol

JSONL v1, one request line → one response line:

```json
{"v":1,"id":"ham-ctl-agent","token":"<hlat_>","method":"<agent.method>","params":{...}}
```

Response handling passes the endpoint's JSON body straight through to stdout;
if the endpoint is unreachable it prints a clear offline error and exits non-zero.

### Transports

- `unix:<path>` — primary, AF_UNIX stream socket (§12.0.2 socket 0600 endpoint).
- `tcp:<host>:<port>` — fallback, loopback TCP.

### Method surface (maps 1:1 to the Bridge local endpoint allowlist)

| CLI | local method | Hub relay path |
|-----|--------------|----------------|
| `agent context` | `agent.context.get` | (local, no Hub relay) |
| `agent start-success` | `agent.start_success` | `/api/v1/agent-actions/start-success` |
| `agent chat send --body` | `agent.chat.send_to_user` | `/api/v1/agent-actions/chat/send-to-user` |
| `agent tasks comment` | `agent.tasks.comment` | `/api/v1/agent-actions/tasks/comment` |
| `agent tasks status` | `agent.tasks.status` | `/api/v1/agent-actions/tasks/status` |
| `agent tasks vote` | `agent.tasks.vote` | `/api/v1/agent-actions/tasks/vote` |
| `agent tasks nudge` | `agent.tasks.nudge` | `/api/v1/agent-actions/tasks/nudge` |
| `agent artifacts create` | `agent.artifacts.create` | `/api/v1/agent-actions/artifacts/create` |
| `agent memory propose` | `agent.memory.propose` | `/api/v1/agent-actions/memory/propose` |

### No-Hub-credential invariant

The agent-mode code block contains no `HEIMDALL_HUB_URL`, `HEIMDALL_USER_TOKEN`,
Hub Authorization header, or `http.*` Hub calls. Verified by the static test by
slicing the agent-mode source region.

## RTE2E-9 preservation

Old current-daemon `src/wrapper` and old/current `src/ctl` behavior are
untouched. Agent mode is added as new parallel dispatch in `src/ctl/main.odin`
alongside the existing `hub` user mode; it does not load or mutate daemon
config and does not alter any existing command path.

## Validation

- `python3 tests/test_ham_ctl_agent_mode_static.py` — dispatch wiring, env
  discovery, no-Hub-coupling region assertions, JSONL envelope, both transports,
  full method surface, offline error string.
- `python3 tests/test_ham_ctl_agent_mode_integration.py` — builds `ham-ctl`,
  stands up a mock JSONL v1 TCP endpoint, drives the real binary through
  `context.get` and `start_success`, verifies the on-the-wire envelope
  (`v=1`, token, method, params), env discovery, success passthrough, and the
  clear offline error path.

## Dependency context

Depends on `task-19f8f1837b1` (thin Bridge-local wrapper supervisor, approved),
which depends on the local endpoint + `agent_token_store` + relay (RTE2E-3).
The agent-mode CLI is the last consumer of the local endpoint contract before
the final E2E smoke (task 8R).
