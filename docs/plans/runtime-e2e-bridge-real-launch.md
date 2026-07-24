# Runtime E2E Bridge real launch_agent notes

## Scope

This note records the RTE2E-4 Bridge `launch_agent` implementation boundary for the runtime E2E slice.

## Implemented contract

- `launch_agent` is no longer a fake status-only path. The Bridge now:
  - acknowledges the command idempotently;
  - fetches and materializes bootstrap files with the Bridge token;
  - ensures a local Bridge endpoint is running; the endpoint descriptor handed to the wrapper is the live transport selected per §12.0.2 (Unix-domain socket 0600 primary, loopback TCP fallback), so the wrapper never receives a descriptor for a transport that is not listening;
  - issues separate local `hlat_...` tokens for the wrapper supervisor and child agent;
  - launches `ham-bridge wrapper-supervisor` in tmux with materialized cwd, endpoint, wrapper token, child agent token, instance id, and agent command;
  - records the active launch (session/window/pane/run dir/tokens) for stop/restart handling;
  - reports status with monotonic `state_seq` and includes active instances in heartbeat digests;
  - emits a final command result only after the wrapper launch path succeeds or fails.
- `stop_agent` now targets the recorded tmux wrapper window, removes launch state, and converges runtime state to `stopped`.
- Restart/reconfigure Hub commands reuse the same `launch_agent` command type; duplicate active launch for an instance is stopped before replacement.

## RTE2E-9 preservation

This work is contained in new Bridge rewrite code under `src/bridge`. It does not migrate or modify old current-daemon `src/wrapper` or old/current `src/ctl` behavior.
