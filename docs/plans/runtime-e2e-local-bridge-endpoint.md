# Runtime E2E local Bridge endpoint notes

## Scope

This note records the RTE2E-3 local Bridge endpoint implementation boundary for the runtime E2E slice.

## Implemented contract

- Local agent tokens are Bridge-managed `hlat_...` credentials, hashed at rest in Bridge memory, and map to exactly one `agent_instance_id` plus role (`Agent` or `Wrapper`).
- Token rotation invalidates the previous token; invalidated tokens fail verification.
- The local endpoint accepts JSONL-style request envelopes with `v`, `id`, `token`, `method`, and `params`.
- Wrapper methods are strictly allowlisted: `wrapper.startup.report`, `wrapper.activity.report`, `wrapper.liveness.ping`, `wrapper.exited`.
- Agent methods are strictly allowlisted: `agent.chat.send_to_user`, `agent.tasks.comment`, `agent.tasks.status`, `agent.tasks.vote`, `agent.tasks.nudge`, `agent.artifacts.create`, `agent.memory.propose`, `agent.context.get`, `agent.start_success`.
- Local params containing spoofable identity or credential fields (`owner_user_id`, `sender_agent_instance_id`, `agent_instance_id`, `hub_url`, `Authorization`, `token`, etc.) are rejected.
- Agent relays use the Bridge-held instance token; wrapper/agent local clients never receive Hub credentials.
- Hub instance-token relay routes are available under `/api/v1/agent-actions/...` for chat send-to-user, task comment/status/vote/nudge, artifact create, memory propose, and start-success; task comments persist a real Hub `task_comments` row with the Bridge-resolved `author_agent_instance_id`.
- The Bridge exposes CLI flags for local endpoint smoke: `--local-endpoint-port` and `--local-run-dir`.

## Transport implementation

Protocol §12.0.2 defines Unix domain socket `0600` as the primary transport with loopback TCP fallback. This slice now implements both endpoint start paths:

- Unix socket: `unix:${run_dir}/bridge.sock`, parent directory preparation, stale socket unlink before bind, listener start, JSONL client handling, and `chmod` to owner read/write (`0600`) via POSIX mode bits.
- Loopback fallback: `tcp:127.0.0.1:<port>`, same JSONL request handling.
- JSONL parser accepts normal JSON member whitespace for `v/id/token/method/params` and always emits syntactically valid response envelopes.

The wrapper launch/supervisor task will decide the per-instance endpoint env passed to the wrapper and agent (`HEIMDALL_BRIDGE_ENDPOINT`, `HEIMDALL_AGENT_TOKEN`, `HEIMDALL_AGENT_INSTANCE_ID`) and own lifecycle cleanup around the supervised process.

## RTE2E-9 preservation

This work is new Bridge rewrite code under `src/bridge`; it does not migrate or modify old current-daemon `src/wrapper` or `src/ctl` behavior.
