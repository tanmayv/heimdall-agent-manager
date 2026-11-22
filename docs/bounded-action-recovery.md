The bridge scheduler was removed by the event-driven bot wake and scheduled actions chain.

# Bounded startup and credential recovery

This implements the reviewed design in task `task_18e18418335ffe9e`. No production deployment is included. The historical caller binary, credential identity, and exact old 401/409 reasons remain unproven.

## Retry contract

Startup confirmation, PTY readiness reminders, and credential renewal use at most six attempts and 120 seconds, including the first attempt. Reminders also respect the existing startup timeout. Each HTTP attempt has at most ten seconds, reduced to the remaining operation budget. DNS/connect/TLS/write/read share that monotonic deadline; slow incoming bytes cannot reset it. Unix TLS relays are killed before reaping during teardown. An unsupported bounded transport returns `not_implemented`; the Windows TLS/system-DNS path is deliberately unavailable to these new strict callers until its backend can enforce cancellation. Existing HTTP APIs retain their compatibility behavior.

The outer controller preserves wire error code/class/retry-after. Fatal and recoverable refusals park; only retriable failures receive bounded backoff with up to 20% jitter and the complete server delay floor. Duplicate startup signals, reconnects and local token rotation do not create fresh failed budgets. Same-launch generation rejection remains parked.

Readiness identity uses instance ID, run count and a hash of the authenticated launch assertion. Local bearer rotation transfers that identity. Completion rechecks current launch and stop intent; an old completion cannot mark a stopped or replacement launch ready.

## Local durability and uncertain effects

The per-bridge state directory contains a mode-0600 `retry-journal-v1.json`, atomically replaced with file and directory sync. Reservations are durable before I/O. Its initialization marker distinguishes first use from a journal missing after restart. Invalid schema, unknown version, backwards wall clock, missing initialized journal, persistence failure or capacity exhaustion parks work instead of granting attempts. There are at most 4,096 receipts and two MiB of journal data. Live terminal/unknown fences are never evicted to admit new work; the current implementation conservatively retains receipts rather than guessing that an identity is unreachable.

A rotated credential pair is held in a separate mode-0600 pending-rotation record. Refresh and access replacements commit in that order before adoption. Local commit retries spend the same renewal budget and never repeat an exchange of the spent token. Every rotation has a request id, generated and made durable (`<credential>.refresh-request-v1`) before the first send and sent as `X-Heimdall-Refresh-Request-Id` on every attempt. A lost or malformed post-send refresh response is an unknown outcome and is retried with the same request id; the hub answers a retry of the exact rotation it already performed for up to 10 minutes (`BRIDGE_REFRESH_RETRY_GRACE_SECONDS`, only while no descendant token was redeemed) instead of treating the spent token as stolen. A terminal renewal receipt for a retriable reason (exhausted budget, lost reply, crash mid-request) is reopened with a fresh bounded budget at every start and after a 60-second pause, so it never stops renewal across restarts; a refused refresh token (401) still stops and wipes. A durable pair can resume local commit after restart.

A graced re-grant on the hub (the request-id retry or the 30-second crash grace) is one `BEGIN IMMEDIATE` transaction on the dedicated commit connection: a compare-and-set claim on the spent refresh row (`regrant_claim`), revocation of the never-delivered newer generations, and both new rows. A failure anywhere rolls the claim back, so the next retry still recovers. The grace ends once any newer generation was delivered: its access token authenticated something (`first_used_at`) or its refresh token was redeemed. A presentation that loses the claim race is treated as a second holder of the token, so it revokes the whole family, including the pair the winner just received. This is intentional: a bridge must send its retries one at a time, and one that double-sends a retry loses its enrollment.

Keep the journal, marker and any pending pair together during backup/recovery. On upgrade, legacy action sync and slot receipts are dropped when the journal loads; credential renewal and readiness receipts remain.

## Observability and operator recovery

Heartbeats contain aggregate `operation_recovery` state, attempts and remaining counts, journal failure and capacity state. The hub exposes `heimdall_bridge_recovery_receipts` by bridge, bounded operation/state/code/class labels; it writes no new telemetry rows. Transition logs contain a hashed identity and enums, not credentials or request bodies. The local `start-success` response reports the same receipt and returns a terminal error after exhaustion/rejection.

The compatibility command `ham-bridge recovery resume-sync` prints `nothing to resume: the action scheduler was removed` and exits successfully without changing state.

After re-enrollment/configuration repair, `recovery resume-refresh` starts a new renewal episode for the same bridge identity. It refuses while a pending rotated pair exists, so a spent-token exchange cannot replace local commit recovery.

Refresh recovery takes the service config and hub/bridge scope locks before loading or rewriting the journal and holds them through the durable write. A running service/enrollment prevents recovery. Healthy credentials are not required, but refresh recovery requires the same effective credential-file path used by the service (including `HAM_BRIDGE_TOKEN_FILE`) and refuses any pending pair there. Recovery does not perform enrollment repair before acquiring exclusion.

Refresh recovery exits after updating its controller receipt. Restart the service normally, without retaining this one-shot command in its service configuration. It refuses to clear readiness fences or a corrupt journal. Automatic reconnects do not invoke it.

## Verification and rollout

Build the bridge and run the affected package tests with the flake-pinned toolchain:

```bash
nix develop -c odin build src/bridge -collection:odin_test=src -define:HAM_CURL_VERSION=8.23.0 -out:$HOME/.cache/heimdall-tests/bridge-build-$$
nix develop -c odin test src/bridge -collection:odin_test=src -define:HAM_CURL_VERSION=8.23.0 -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/bridge-$$
nix develop -c odin test src/hub/transport/http -collection:odin_test=src -define:HAM_CURL_VERSION=8.23.0 -define:ODIN_TEST_THREADS=1 -out:$HOME/.cache/heimdall-tests/http-$$
```

The scheduler-removal regressions cover UTC formatting, the ungated prune request, live and revoked probe tokens, dropping legacy receipts, and accepting old heartbeat acknowledgements.

No live load test or deployment is part of this change. Retain local receipt schemas for credential renewal and startup recovery. Unknown newer receipt versions park safely.
