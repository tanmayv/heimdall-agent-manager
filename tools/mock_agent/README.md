# Mock agent for E2E testing

A drop-in replacement for a real agent (pi) process, enabling deterministic E2E
testing of the full Hub → Bridge → wrapper → agent path (**RTE2E-8**).

The mock behaves like a real agent from the wrapper's perspective: it is launched
via `sh -c <agent_command>`, reads stdin (tmux send-keys input), writes stdout,
and handles `TERM`/`INT`/`HUP` signals by logging them and exiting cleanly.

## Files

| File | Purpose |
|------|---------|
| `mock-agent.sh` | The mock agent binary (POSIX sh). Launched by the wrapper via `sh -c`. |
| `replay.default.txt` | Default replay script (start-success → idle). |
| `replay.demo.txt` | 3-command demo with 1s gaps (acceptance criteria). |
| `replay.e2e.txt` | Clean E2E replay: context + shell command + finish. |

## How it works

The thin wrapper supervisor (RTE2E-5) launches the agent via
`sh -c <agent_command>` with a **sanitized** child env that contains only an
allowlist (`PATH`, `HOME`, `USER`, …) plus the three local-endpoint variables:

```
HEIMDALL_BRIDGE_ENDPOINT=<unix:|tcp:>
HEIMDALL_AGENT_TOKEN=<hlat_...>     # Agent-role local token, via --child-agent-token
HEIMDALL_AGENT_INSTANCE_ID=<id>
```

> ⚠️ **The wrapper strips everything else.** `HEIMDALL_MOCK_LOG`,
> `HEIMDALL_MOCK_REPLAY`, and `HAM_CTL` set on the Bridge process are **not**
> propagated to the child. They must be passed **inline inside the
> `--agent-command` string**, which `sh -c` evaluates in the child. This keeps
> the mock a true drop-in: no wrapper or endpoint changes are required.

### Two-token model

For an agent's `agent.*` calls to be accepted by the local endpoint, the child
needs an **Agent-role** local token — distinct from the **Wrapper-role** token
the supervisor itself uses. The real `launch_agent` path (RTE2E-4) issues both
for the same instance and passes the agent one through `--child-agent-token`,
which the supervisor forwards to the child as `HEIMDALL_AGENT_TOKEN`.

```text
supervisor  --agent-token        <wrapper-role hlat_...>   (calls wrapper.*)
            --child-agent-token  <agent-role  hlat_...>    (forwarded to child)
            --agent-command      '...inline mock env... /mock-agent.sh'
```

## Using the mock as the agent command

Because the wrapper runs `sh -c "<agent-command>"`, set the inline env inside the
command string. Example Bridge/`launch_agent` wiring:

```bash
MOCK=/path/to/tools/mock_agent/mock-agent.sh
HAM_CTL=/path/to/ham-ctl
AGENT_CMD="HEIMDALL_MOCK_LOG=/tmp/mock.log \
           HEIMDALL_MOCK_REPLAY=/path/to/replay.e2e.txt \
           HAM_CTL=$HAM_CTL sh $MOCK"

ham-bridge ... --agent-command "$AGENT_CMD"
```

or, when driving the wrapper-supervisor directly (as the integration test does):

```bash
ham-bridge wrapper-supervisor \
  --bridge-endpoint  unix:/run/heimdall/bridge.sock \
  --agent-token      hlat_wrapper_role \
  --child-agent-token hlat_agent_role \
  --agent-instance-id inst_... \
  --cwd /tmp \
  --agent-command 'HEIMDALL_MOCK_LOG=/tmp/mock.log HEIMDALL_MOCK_REPLAY=/x/replay.txt sh /x/mock-agent.sh'
```

## Configuration (env vars read by the mock, in the child)

| Var | Default | Purpose |
|-----|---------|---------|
| `HEIMDALL_MOCK_LOG` | `$PWD/mock-agent.log` | Log file — the deterministic test artifact. |
| `HEIMDALL_MOCK_REPLAY` | `$PWD/replay.txt` | Replay script path. |
| `HAM_CTL` | `ham-ctl` (from PATH) | `ham-ctl` binary used for local-endpoint calls. |

The three `HEIMDALL_*` endpoint/identity vars are provided by the wrapper and
need not be set inline.

If no replay script exists, the mock runs a minimal default loop: calls
`start-success`, then idles until killed (so the wrapper's liveness/exit
detection is still exercised).

## Replay script format

Line-based. Blank lines and `#` comments are ignored. Fields are
space-separated; the first token is the action, the remainder is its argument.

| Action | Effect |
|--------|--------|
| `sleep <seconds>` | Wait (also lets the wrapper observe the process / report liveness). |
| `start-success` | Call `ham-ctl agent start-success`. |
| `context` | Call `ham-ctl agent context` (agent.context.get). |
| `say <text>` | Call `ham-ctl agent chat send --body <text>`. |
| `task-comment <id> <text>` | Call `ham-ctl agent tasks comment --task-id <id> --body <text>`. |
| `task-status <id> <status>` | Call `ham-ctl agent tasks status --task-id <id> --status <status>`. |
| `task-vote <id> <lgtm\|ngtm>` | Call `ham-ctl agent tasks vote --task-id <id> --result <r>`. |
| `run <shell command>` | Run a shell command; stdout is logged under `run_stdout`. |
| `echo <text>` | Log a line (no endpoint call). |
| `done` | Clean exit (return code 0). |

## Log file (test artifact)

The log is deterministic and inspectable. Each structured event is one JSON-ish
line; a test asserts on `kind` + `detail`:

```json
{"ts":"2026-07-24T05:00:00Z","kind":"config","detail":"log=... replay=..."}
{"ts":"...","kind":"env","detail":"endpoint=tcp:127.0.0.1:49324 instance=inst_1 token_set=yes"}
{"ts":"...","kind":"stdin","detail":"<tmux-send-keys input line>"}
{"ts":"...","kind":"replay_step","detail":"line=4 action=context"}
{"ts":"...","kind":"endpoint_call","detail":"method=agent.context.get args=context rc=0"}
  response: {"v":1,"id":"...","ok":true,"data":{"agent_instance_id":"inst_1"}}
{"ts":"...","kind":"run_stdout","detail":"echo mock-e2e-step"}
mock-e2e-step
{"ts":"...","kind":"replay_done","detail":"clean exit"}
{"ts":"...","kind":"signal","detail":"received TERM; shutting down"}
```

### What gets logged (acceptance mapping)

| Acceptance item | Logged as |
|-----------------|-----------|
| Each replay command + its stdout | `replay_step` + `run_stdout` + the raw stdout line(s). |
| All tmux send-keys input (stdin) | `stdin` events (captured in the background). |
| All Bridge notification messages | Every local-endpoint **response** is logged after its `endpoint_call` event (`response: <json>`). In this milestone the local endpoint is request/response JSONL (no server push), so the messages the agent receives from the Bridge are exactly these responses. |
| Signal/exit cause | `signal` / `stopping` / `replay_done` events. |

## Tests

- **Standalone:** `HEIMDALL_MOCK_LOG=/tmp/x.log HEIMDALL_MOCK_REPLAY=$PWD/tools/mock_agent/replay.demo.txt sh ./tools/mock_agent/mock-agent.sh </dev/null`
- **Wrapper integration:** `tests/mock_agent_wrapper_launch_test.odin` proves the
  thin wrapper supervisor launches the mock via the normal child path, the
  sanitized child env carries the local endpoint vars, the lifecycle reaches
  `stopped` through the local endpoint, and the mock log records the replay in
  order with the Bridge response to `agent.context.get`.
