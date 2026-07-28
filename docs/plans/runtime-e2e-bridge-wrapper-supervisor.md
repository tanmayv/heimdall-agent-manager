# Runtime E2E Bridge-local wrapper supervisor notes

## Scope

This note records the RTE2E-5 thin wrapper implementation boundary for the runtime E2E slice.

## Implemented contract

- The new wrapper lives in the Bridge rewrite path as `src/bridge/wrapper_supervisor.odin` and is selected with `ham-bridge wrapper-supervisor` (or `--bridge-wrapper-supervisor`).
- The wrapper reads only local Bridge endpoint context:
  - `HEIMDALL_BRIDGE_ENDPOINT` / `--bridge-endpoint`
  - `HEIMDALL_AGENT_TOKEN` / `--agent-token`
  - `HEIMDALL_AGENT_INSTANCE_ID` / `--agent-instance-id`
- The wrapper launches the configured child agent command with `--agent-command` and `--cwd` using a sanitized child environment. It does not bulk-forward the Bridge parent process environment; it carries only a small non-credential process allowlist (`PATH`, `HOME`, user/shell/locale/temp basics) plus the local endpoint env needed by agent-mode tooling.
- The wrapper reports only to the local Bridge endpoint using runtime protocol §12.0.2 JSONL methods:
  - `wrapper.startup.report`
  - `wrapper.activity.report`
  - `wrapper.liveness.ping`
  - `wrapper.exited`
- The wrapper supports both `unix:<path>` and `tcp:127.0.0.1:<port>` local endpoint descriptors.
- The wrapper exits when the supervised child process exits, after sending `wrapper.exited`.

## Credential boundary

The wrapper supervisor has no Hub URL, no Hub/Bridge bearer credential, no `/api/v1` route knowledge, and no `Authorization` header handling. It sends the Bridge-managed local agent token only inside the local JSONL envelope required by §12.0.2, and it does not propagate parent Hub/daemon/Bridge credential environment variables to the child agent process.

## RTE2E-9 preservation

This work is new Bridge rewrite code under `src/bridge`; it does not migrate or modify old current-daemon `src/wrapper` behavior or old/current `src/ctl` behavior.
