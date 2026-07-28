# ham-wrapper Bridge Runtime Migration

## Goal

Move per-agent runtime ownership out of `ham-bridge wrapper-supervisor` and into the existing `ham-wrapper` binary. `ham-bridge` remains the launcher/router/provider-config owner; `ham-wrapper` runs inside the tmux pane and owns all agent terminal interaction.

## Target Runtime Split

- `ham-hub`: durable state, messages, task/chat/memory APIs, bridge command routing.
- `ham-bridge`: provider configuration/capabilities, bootstrap materialization, local endpoint, local token minting, and tmux pane launch/stop.
- `ham-wrapper bridge-runtime`: per-agent runtime process inside tmux; launches the provider command as a child process, reports liveness/startup/activity/exited, subscribes to notifications, and is the only component allowed to inject text into the agent terminal.
- Agent provider process: child of `ham-wrapper` in the tmux pane.

## Invariants

1. `ham-bridge` must not call tmux send-keys for agent interaction or notifications.
2. Provider configuration remains bridge-local and continues to drive command, flags, model tiers, prompt delivery, startup/activity config, run dir, and skill dir.
3. Bootstrap still happens before launch/restart and rewrites `AGENTS.md`, `.heimdall/bin/ham-ctl`, and provider-specific skills.
4. UI provider settings continue to call the existing bridge provider APIs; no UI migration should be required for this step.
5. Wrapper local endpoint communication uses existing bridge-local JSONL methods and tokens.

## Phases

### Phase 1 — Introduce ham-wrapper bridge runtime

Status: done.

- Added `ham-wrapper bridge-runtime` subcommand.
- Accepts bridge local endpoint, wrapper token, child agent token, instance id, run dir, provider/tier metadata, and child command after `--`.
- Runs inside tmux and launches provider command as a child process with Heimdall env.
- Reports startup/liveness/activity/exited through bridge local endpoint.
- Subscribes to `wrapper.notifications.subscribe` with retry/backoff.
- Delivers notifications from wrapper only.

### Phase 2 — Switch bridge launch path

Status: done.

- Replaced `ham-bridge wrapper-supervisor` launch with tmux launch of `ham-wrapper bridge-runtime`.
- Resolves wrapper binary from `HEIMDALL_HAM_WRAPPER_BIN`, then PATH.
- Continues using bridge provider store to build provider argv.
- Keeps stop/restart semantics at tmux window level.

### Phase 3 — Remove wrapper-supervisor path

Status: done for code path.

- Removed old supervisor code/tests.
- Kept a small CLI guard that errors if someone invokes the removed `ham-bridge wrapper-supervisor` mode.
- Provider skill dir preservation remains in bridge provider store/config.

### Phase 4 — Hardening

- Add observable subscription status to bridge runtime state.
- Make failed notification pushes visible in hub/bridge logs and metrics.
- Add retry/replay queue if live notification delivery fails.
- Optionally replace tmux send-keys in wrapper with PTY mediation for stronger child-process ownership.
