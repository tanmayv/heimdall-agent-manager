# Bridge WebSocket Command Dispatch Hardening

**Design & Implementation Plan**
**Requirement IDs**: `REQ-BDISP-1` … `REQ-BDISP-14`
**Status**: Implemented and locally validated
**Target Subsystems**: `src/bridge/`, `src/hub/service/bridge_runtime/`, `src/hub/transport/http/`, `src/lib/ws/`, `tests/`
**Backward compatibility**: No compatibility layer is required. Hub and Bridge ship as one protocol release.

---

## Implementation checkpoint (2026-10-10)

Implemented:

- terminal-result state replaces accepted acknowledgements, with event-driven Hub waiters;
- Hub result/waiter identity includes the Bridge connection generation, preventing
  a late result from a replaced connection from satisfying new work;
- stable per-Bridge writers and synchronized live-Bridge admission/generation state;
- bounded, per-Bridge-partitioned Hub result retention with owned cache memory;
- bounded Bridge queues, owned command records, keyed FIFO conflict ordering, dedicated
  lifecycle/interactive/background/exclusive/IO/shell workers, and recovery reserve;
- one exhaustive command-spec registry declaring priority, ordering, deadline, cost,
  coalescing, and retry behavior for every accepted reader command;
- generation-tagged result outbox with explicit backpressure failures;
- fast `bridge_busy`, deadline, malformed-command, missing-id, and oversized-command failures;
- bounded inbound frame bursts instead of one frame followed by an unconditional sleep; and
- provider version-process timeout, termination, and reaping;
- filter-keyed provider-discovery single-flight fanout;
- provider-probe and PTY-host circuit breakers with one half-open recovery probe;
- a bounded process runner used by VCS commands and Bridge-update extraction/preflight,
  with output caps plus kill-and-reap deadline handling; and
- a Bridge-wide 16-child-process budget shared by provider probes, bounded subprocesses,
  and long-lived LSP sessions, with process-scope load shedding;
- non-secret heartbeat metrics for saturation, queue/execute latency, stale completions,
  response backpressure, and dependency-breaker activity;
- command-deadline propagation through recursive filesystem traversal and mutation,
  bootstrap manifest/blob reads, and retry/backoff sleeps;
- asynchronously paced shell-kill replay with bounded windows, capped exponential
  backoff, deterministic jitter, terminal feedback, and teardown-safe worker lifetime;
  and
- shell-kill idempotency keys scoped to `(session_id, run_seq)`, so replay deduplicates
  one run without suppressing a legitimate kill after restart.

Local validation evidence:

- a deliberately hung Claude version probe completed at its 2-second provider-local
  deadline while an agent start returned `202` in 1.68 seconds and an unrelated FS
  request returned `200` in 54 ms;
- 50 consecutive discovery requests completed successfully while Bridge
  `last_seen_at` advanced across multiple 45-second heartbeat periods; FS and stop
  requests remained responsive during that load;
- forced Bridge disconnect/reconnect during discovery restored the same Bridge and a
  repeat discovery completed successfully, with stale-generation behavior covered by
  deterministic Hub registry tests;
- per-Bridge writer isolation and result-cache partition tests pass, including a real
  socket send to Bridge B while Bridge A's writer mutex is held;
- focused deadline, child reaping, replay pacing, run-sequence idempotency, and
  process-budget tests pass; and
- `nix build .#ham-bridge .#ham-hub --no-link` passes.

The destructive self-update/restart smoke test is intentionally left to release
rollout; update work is isolated in the exclusive lane and heartbeat control remains
reader-local, both covered by the command-registry regression tests.

---

## 1. Outcome

The Bridge's Hub WebSocket reader will only:

1. read and reassemble frames;
2. validate protocol metadata and command identity;
3. serve a completed idempotency-cache hit or enqueue owned work;
4. drain completed response frames and connection-level events; and
5. own connection teardown.

It will never wait for a process, HTTP request, provider probe, PTY-host startup,
filesystem operation, update drain, or other command execution.

The Hub may still expose a synchronous HTTP API where the product needs one. In that
case the HTTP handler waits for the command's terminal result in Hub memory while the
Bridge continues servicing the WebSocket. "Synchronous API" must no longer mean
"synchronous Bridge reader."

This removes the head-of-line blocking that caused provider discovery to return 504
while reconnect-time agent wakes each spent five seconds waiting for `ham-pty-host`.

---

## 2. Current Failure Model

`bridge_hub_runtime_loop` reads one frame and calls `bridge_hub_handle_command`
inline. That dispatcher invokes handlers which may perform blocking work before it
returns. No later Hub frame is read during that work.

Known blocking paths include:

| Command/path | Current blocking work | Bound |
|---|---|---:|
| `provider_discover` | sequential external `<provider> --version` processes | unbounded |
| `launch_agent`, `launch_provider_test`, `wake_agent` | bootstrap HTTP, disk materialization, PTY-host startup/spawn | 5s PTY startup plus 20s HTTP calls |
| task/message/title/shell notifications | PTY-host startup and sometimes synthetic agent launch | 5s plus launch work |
| `shell_stream_attach` reconnect replay | PTY-host startup before attaching | 5s per replayed attach |
| `capture_agent_pane` and several shell commands | PTY-host startup/request | 5s startup plus request time |
| `bridge_update` | active-run drain, download, hash, extraction, supervisor launch | 60s drain by default plus network/disk |
| filesystem and VCS commands | directory walks, file IO, or subprocesses | operation-dependent |

The Hub's `send_runtime_command_wait` does not hold the socket write lock while it
waits, which is correct. The failure is on the other end: its result cannot arrive
until every earlier Bridge handler returns.

Two related contracts also need correction:

- The Hub command-result cache currently keeps the first frame for a `command_id`.
  An asynchronous command needs `accepted` to advance to a terminal result rather
  than permanently masking it.
- Some Bridge handlers cache `accepted`, later overwrite it with a terminal result,
  and some send only a command-specific terminal frame. Dispatch must make these
  lifecycle rules explicit instead of depending on handler accidents.

---

## 3. Non-Negotiable Invariants

### `REQ-BDISP-1` — Reader never executes blocking command work

After frame parsing, the reader may perform bounded in-memory work only. It must not
call `time.sleep`, `os.process_exec`, Hub HTTP helpers, filesystem traversal,
`bridge_pty_host_ensure_daemon`, update application, or a handler which can reach
those operations.

### `REQ-BDISP-2` — The reader owns connection lifetime

The runtime reader remains the sole owner of WebSocket connection teardown. A worker
must never close the Hub connection or retain a connection pointer past its
generation.

This is required by the repository's socket-lifetime invariant: memory ownership and
fd ownership are separate. Command workers do not participate in either race. They
publish owned result strings to an outbox; the runtime loop decides whether and where
to send them.

Existing PTY/tunnel stream workers are a specialized data plane and may continue to
use the connection's serialized send path during this change. Their existing
shutdown-before-close contract remains mandatory. General command workers do not
copy that exception.

### `REQ-BDISP-3` — Every queued command owns its memory

The inbound WebSocket frame is freed at the end of the reader iteration today. A
queued item therefore owns heap clones of:

- complete command JSON;
- command type and `command_id`;
- ordering key and command class;
- connection generation; and
- enqueue/deadline timestamps.

No queued or in-flight record may retain request-arena, temporary-allocator, stack,
or reassembly-buffer memory.

### `REQ-BDISP-4` — Bounded work and explicit load shedding

Queues, in-flight registries, subprocesses, and response buffers have hard limits.
Admission happens before cloning the full command body or acquiring scarce worker
capacity. The initial defaults are:

- 4 general IO workers;
- 2 lifecycle workers;
- 1 exclusive/update worker;
- 128 queued commands total;
- 32 queued commands per non-control class;
- 16 concurrent child processes across all workers; and
- reserved queue and result-outbox capacity for control traffic.

These are internal constants in the first implementation, not public configuration.
When capacity is exhausted, a command carrying `command_id` receives an immediate
terminal failure with `error_code = "bridge_busy"` and `retryable = true`. Work is
never silently dropped. Fire-and-forget writers must be updated to supply a
`command_id` before they can use the queue.

Admission considers more than item count. It rejects work when any relevant budget
would be exceeded:

- total owned command bytes;
- total queued cost units;
- class queue depth;
- active subprocess slots;
- result-outbox bytes; or
- the command's remaining deadline is shorter than the estimated queue wait.

Expensive operations declare larger cost units, so 128 bridge updates or recursive
filesystem walks cannot fit merely because they are represented by small JSON
requests. Limits are checked under one short admission lock and released before any
handler or response send.

### `REQ-BDISP-5` — Ordering is explicit

Parallel execution must not reorder conflicting mutations. Each command is assigned
an ordering key:

- agent lifecycle/input: `agent:<agent_instance_id>`;
- shell lifecycle/input/stream attachment: `shell:<session_id>`;
- filesystem mutation: `fs:<canonical-root>`;
- VCS mutation: `vcs:<repository-root>`;
- provider discovery: `provider-discovery`;
- bridge update: `bridge-update`;
- independent bounded reads: no resource key.

Commands with the same non-empty key execute FIFO. Different keys may execute in
parallel. `bridge_update` is exclusive against new lifecycle starts, but it does not
stop heartbeat processing, result delivery, or terminal status reporting.

### `REQ-BDISP-6` — Command execution is at-most-once per Bridge process

The Bridge atomically claims a new `command_id` as `queued` before enqueueing it.
Duplicate delivery returns the current state/result and never enqueues a second
execution. State is:

```text
unknown -> queued -> running -> succeeded | failed | cancelled
```

`accepted` is a transport observation of `queued`/`running`, not a terminal cached
result. Terminal results remain in the existing bounded cache for idempotent retry.

### `REQ-BDISP-7` — Hub waits for terminal state, not the first frame

The Hub runtime result registry stores command state, frame type, and terminal JSON,
keyed by `(bridge_id, connection_generation, command_id)`. An `accepted` frame wakes
acknowledgement waiters but not terminal-result waiters. A later terminal result
replaces the non-terminal state exactly once; duplicate terminal frames preserve the
first terminal answer.

`send_runtime_command_wait` becomes event-driven through a waiter/condition registry
instead of polling every 25ms. Its timeout remains an HTTP/API deadline only: it does
not mark the Bridge offline and does not cancel unrelated Bridge work.

### `REQ-BDISP-8` — Completion crosses threads through a response outbox

Workers publish `Bridge_Command_Completion` records containing owned result JSON and
the originating connection generation. The runtime loop drains that outbox and calls
the existing serialized `bridge_hub_send` path.

If the generation no longer matches:

- do not write to the new connection;
- retain a terminal idempotency result when the command completed safely; and
- allow a Hub retry using the same `command_id` to retrieve that result.

Connection-dependent operations such as stream attachment are cancelled or allowed
to fail when their generation ends. Durable/external side effects such as an update
or an already-issued process launch are never blindly repeated.

### `REQ-BDISP-9` — Every external wait has a command budget

Moving work off the reader prevents a global outage but does not make an unbounded
worker safe. Each subprocess/network operation receives a deadline shorter than the
calling API's terminal wait:

- provider `--version`: 2s per provider and 8s total discovery budget;
- PTY-host startup: existing 5s single-flight budget;
- Hub bootstrap reads: existing 20s request budget, with a bounded overall launch
  budget;
- filesystem/VCS subprocesses: command-specific deadline;
- update drain: remains explicit in the update command and runs in its exclusive
  lane.

A timed-out child is terminated, waited/reaped, and reported as a command-local
failure. It cannot consume a worker forever or leave zombies.

### `REQ-BDISP-10` — Reconnect work is small and safe

Actionable-agent wake replay has been removed separately and must not return.
Reconnect may still:

- replay durable shell-kill intents; and
- reattach streams for live viewed shell sessions after inventory convergence.

Kill grace already runs on a background worker. Stream reattachment must be routed
through the shell ordering lane so a missing PTY host cannot hold the WebSocket
reader for five seconds per viewed session.

### `REQ-BDISP-11` — Observable saturation and latency

Bridge logs/telemetry expose bounded, non-secret fields:

- queue depth and active workers by class;
- rejected commands by type and reason;
- queue wait and execution duration;
- command terminal status and timeout stage;
- late completion after Hub HTTP timeout;
- maximum runtime-loop iteration delay; and
- connection generation discarded by a stale completion.

No command body, bearer token, vault key, prompt, file content, or terminal output is
logged.

### `REQ-BDISP-12` — Unknown or malformed work fails closed

Unknown command types, missing command ids for queued work, oversized payloads, and
invalid ordering identifiers produce a bounded protocol error. They are not executed
inline as a fallback. Authentication and ownership remain Hub responsibilities before
a command reaches the Bridge socket.

### `REQ-BDISP-13` — Overload degrades by priority, not arrival order

Commands are assigned an admission priority independent of execution class:

| Priority | Traffic | Overload behavior |
|---|---|---|
| P0 control | heartbeat/ack, terminal results, disconnect and shutdown bookkeeping | never waits behind command work; uses reserved capacity |
| P1 recovery | stop/cancel, vault lock, shell kill, stream detach | reserved command slots; may displace only queued coalescible background work |
| P2 interactive | provider test, launch, shell input, pane capture, bounded user reads | admitted while interactive budget remains; otherwise fast `bridge_busy` |
| P3 background | provider discovery, inventory refresh, reconnect reattach, broad FS/VCS reads | first shed, coalesced where safe, never consumes reserved capacity |

The dispatcher uses weighted fair scheduling between non-empty classes rather than a
single FIFO. This prevents a burst of background discovery from starving lifecycle
or shell control, while per-resource ordering still governs conflicting commands.
Concurrency is partitioned as well as queue capacity: background work cannot occupy
every worker or every child-process slot.

Only commands explicitly marked `coalescible` may share one in-flight execution.
Provider discovery is single-flight: identical requests attach as waiters to the
current scan and receive its result. Mutations, launches, updates, input, and any
operation with uncertain side effects are never coalesced or evicted. A queued
command whose monotonic deadline has expired is completed as `deadline_exceeded`
without execution.

Dependency failures use a small circuit breaker per dependency, initially PTY host
and provider executable probing. Repeated failures open the breaker for a bounded
cooldown, causing dependent commands to fail fast while control traffic and
unrelated commands continue. A single half-open probe tests recovery. Breaker state
is in-memory, observable, and never marks the whole Bridge offline.

`bridge_busy` responses include bounded hints:

```json
{
  "error_code": "bridge_busy",
  "retryable": true,
  "retry_after_ms": 1000,
  "overload_scope": "background|lifecycle|process|global"
}
```

The Hub applies capped exponential backoff with jitter and honors
`retry_after_ms`. It retries only commands whose contract is retry-safe, always with
the same `command_id`. UI-triggered commands surface overload immediately instead of
silently retrying past the user's HTTP deadline. Reconnect does not dump all replay
work at once: the Hub paces replay through the same admission feedback.

### `REQ-BDISP-14` — One Bridge cannot degrade another Bridge

The multi-Bridge transport findings in the binary-pane streaming plan identify two
Hub-wide coupling points which this work must remove before scale testing:

- a single registry mutex currently covers blocking socket writes for every Bridge;
- a single command-result ring allows one noisy Bridge to evict another Bridge's
  pending terminal result.

Use a stable writer mutex per durable `bridge_id`; never move a live mutex during
registry slot compaction and never hold the registry/cache mutex during network IO.
Command results are owned by the cache, keyed by `(bridge_id, command_id)`, and
retained under a per-Bridge quota plus a bounded global capacity. Input frames and
command ids are cloned into an explicit process-wide allocator so eviction never
frees another thread's temporary allocation.

Live-Bridge and writer registries reject new admission explicitly when their stated
capacity is reached. They must not accept a hello while silently omitting the
connection from the runtime registry. Scale tests include one non-reading Bridge and
verify that unrelated Bridges continue to receive heartbeat acknowledgements and
command results within their normal latency budget.

The Bridge reader drains a bounded burst of ready inbound frames per iteration
instead of processing exactly one frame followed by an unconditional 25 ms sleep.
The burst budget preserves time for result-outbox, heartbeat, and data-plane drains.

---

## 4. Command Classification

The first implementation must create one exhaustive registry rather than scattered
string checks:

```odin
Bridge_Command_Spec :: struct {
    type:              string,
    class:             Bridge_Command_Class,
    priority:          Bridge_Command_Priority,
    requires_id:       bool,
    terminal_kind:     Bridge_Command_Terminal_Kind,
    ordering_key_kind: Bridge_Command_Key_Kind,
    timeout_ms:        int,
    cost_units:        int,
    coalescible:       bool,
    retry_safe:        bool,
}
```

Recommended classes:

| Class | Examples | Execution |
|---|---|---|
| inline protocol | `bridge_heartbeat_ack`, chunk assembly, small state acknowledgements | reader, bounded memory only |
| data plane | `tunnel_data`, `proxy_data`, close frames | existing specialized path; separately audited for non-blocking IO |
| general IO | provider discovery, FS reads, VCS reads, path validation, pane capture | bounded general pool |
| keyed mutation | FS/VCS writes, shell commands, stream attach/detach | pool plus FIFO ordering key |
| lifecycle | launch/stop/wake/notification fallback/provider test | lifecycle pool plus agent key |
| exclusive | bridge update | one exclusive lane; progress through outbox |

The registry is also the audit surface: a new command cannot compile into the
dispatcher without declaring its execution class, id requirement, ordering, and
budget, priority, cost, coalescing policy, and retry safety.

---

## 5. Wire Contract

Use the existing `command_id` and `command_result` envelope. Normalize its payload:

```json
{
  "type": "command_result",
  "protocol_version": 1,
  "command_id": "cmd_...",
  "timeout_ms": 15000,
  "payload": {
    "status": "accepted|succeeded|failed|cancelled",
    "error_code": "",
    "retryable": false,
    "retry_after_ms": 0,
    "overload_scope": "",
    "result": {}
  }
}
```

Command-specific terminal frames such as `provider_discovery_report` remain valid;
the Hub command spec declares which frame type is terminal for each command. The Hub
must ignore `accepted` while waiting for that terminal frame.

No automatic retry is added to `send_runtime_command_wait`. A caller may retry only
with the same `command_id`, and only when its operation contract declares retry safe.
Generating a new id for an uncertain side effect is forbidden.

`timeout_ms` is the remaining command budget assigned by the Hub. The Bridge converts
it to a monotonic local deadline on receipt, subtracts queue time before execution,
and clamps it to the command spec's maximum. This avoids depending on synchronized
Hub and Bridge wall clocks.

---

## 6. Bridge Components

Add focused modules rather than expanding `hub_runtime_client.odin` further:

```text
src/bridge/
  hub_command_spec.odin       exhaustive command registry/classification
  hub_command_dispatch.odin   validation, claim, enqueue, backpressure
  hub_command_queue.odin      bounded queues, fair scheduling, keyed FIFO execution
  hub_command_result.odin     state machine, terminal cache, response outbox
  hub_load_shed.odin          admission budgets, coalescing, dependency breakers
  process_deadline.odin       spawn/timeout/terminate/wait helper
```

Existing handler modules keep business logic but change from
`handler(conn, text)` to a worker-safe form returning owned result frames. Handlers
must not know about or retain `ws.Connection`.

The runtime loop initializes a connection generation, drains completions, and on
disconnect retires generation-bound queued work before performing the existing PTY
stream teardown and reader-owned close.

---

## 7. Hub Components

Update:

- `src/hub/service/bridge_runtime/runtime_protocol.odin`
  - replace first-frame-wins with accepted→terminal state transitions;
  - key results/waiters by bridge, generation, and command id;
  - signal waiters on state changes;
  - partition retained results by Bridge and own all cached strings;
- `src/hub/service/bridge_runtime/bridge_runtime.odin`
  - wait for the command spec's terminal frame;
  - distinguish `bridge_busy`, command timeout, Bridge disconnect, and malformed
    response;
  - serialize writes per Bridge rather than under a Hub-wide network lock;
- `src/hub/transport/http/bridge_handlers.odin`
  - apply terminal results only;
  - map retryable saturation to HTTP 503, true deadline expiry to 504, and Bridge
    disconnect to the existing offline response;
- every Hub command writer
  - provide a stable `command_id` and declare whether it waits for acceptance or
    terminal completion;
  - propagate the remaining timeout budget; and
  - honor overload hints only when the command spec permits retry.

Hub reconnect replay uses a bounded producer window and stops producing when the
Bridge reports saturation. It resumes after the advertised delay with jitter, so a
Bridge restart cannot trigger a replay storm.

Business state remains durable in existing Hub repositories. The worker queue and
waiter registry remain in-memory transport state and are rebuilt after restart.

---

## 8. Implementation Sequence

### Phase 1 — Pin the failure with deterministic tests

1. Add a fake slow Bridge command handler controlled by a test barrier.
2. Prove the current reader cannot process a second command or heartbeat while the
   barrier is held.
3. Add provider-process fixtures for success, timeout, and termination/reaping.
4. Inventory every command type accepted by `bridge_hub_handle_command` and fail the
   test if any type lacks a command spec.
5. Add deterministic overload fixtures covering queue count, owned bytes, cost,
   subprocess slots, and deadline expiry.

### Phase 2 — Correct Hub command lifecycle

1. Introduce accepted/terminal state in the Hub result registry.
2. Add waiter notification and remove 25ms result-cache polling.
3. Make provider discovery wait for `provider_discovery_report`, not `accepted`.
4. Preserve first-terminal-wins idempotency.

### Phase 3 — Add the Bridge dispatcher core

1. Add owned command/result records and bounded queues.
2. Add atomic command claim/deduplication.
3. Add keyed FIFO scheduling and worker lifecycle.
4. Add generation-tagged response outbox drained by the runtime loop.
5. Add admission budgets, priority/fair scheduling, saturation responses, and
   metrics.
6. Add provider-discovery single-flight and dependency circuit breakers.

### Phase 4 — Migrate the incident paths first

Move these off the reader before broad migration:

1. provider discovery, including per-process deadline;
2. `task_status_changed_notify`, notification fallbacks, and `wake_agent`;
3. agent/provider-test launch and stop;
4. reconnect shell stream reattachment; and
5. pane capture.

At the end of this phase, a broken PTY host or hung provider CLI cannot delay a
heartbeat or an unrelated provider scan.

### Phase 5 — Migrate remaining command handlers

1. shell lifecycle and control;
2. filesystem commands;
3. VCS commands;
4. LSP commands;
5. vault lock/unseal if any path can block;
6. bridge update in the exclusive lane; and
7. audit tunnel/proxy handlers, retaining inline execution only where every operation
   is proven non-blocking and bounded.

Delete the old inline fallback. A contract-search test must show that the reader's
dispatch call graph contains no known blocking primitive.

### Phase 6 — End-to-end validation and rollout

1. Run local Hub and Bridge with a deliberately unavailable PTY host.
2. Hold one agent launch beyond 10 seconds.
3. During the hold, verify provider discovery, heartbeats, vault status, and a second
   independent command complete normally.
4. Saturate every admission budget and verify bounded 503/`bridge_busy` behavior
   without memory growth, reconnect, or control-traffic delay.
5. Reconnect during queued and running work and verify no stale socket write, double
   execution, leaked thread, or fd reuse.
6. Validate a bridge update while heartbeats and UI status remain live.

---

## 9. Required Tests

### Unit and concurrency

- command classification is exhaustive;
- queue count, owned-byte, cost-unit, process, and per-class limits;
- P0/P1 reserved capacity remains available under P2/P3 saturation;
- weighted scheduling prevents background and lifecycle starvation;
- provider-discovery requests coalesce into one process scan;
- non-coalescible commands are never merged or evicted;
- dependency circuit breaker opens, rejects quickly, half-opens once, and recovers;
- locking one Bridge writer does not block a write lock for another Bridge;
- flooding one Bridge past its result quota does not evict another Bridge's result;
- retry hints are clamped and contain no sensitive state;
- same-key FIFO and different-key parallel execution;
- duplicate id executes once while queued, running, and terminal;
- accepted never masks a later terminal result;
- worker result memory survives the originating reader iteration;
- expired queued command fails without starting;
- provider child is terminated and reaped at deadline;
- stale-generation completion never writes to a new connection;
- disconnect frees queued payloads and does not leak worker threads;
- queue/result locks are never held across network, disk, process, or PTY IO.

### Regression

- a 30-second fake agent launch does not delay provider discovery;
- four consecutive five-second PTY startup failures do not delay a heartbeat;
- replayed shell stream attachment with no PTY host does not block another command;
- update drain does not stop heartbeat processing;
- terminal provider report arriving after `accepted` satisfies the Hub waiter;
- queue saturation returns retryable failure rather than timeout;
- a reconnect replay storm is paced by admission feedback;
- repeated Hub retries use the same command id and exponential backoff with jitter;
- 10,000 rejected commands do not cause proportional retained memory growth;
- saturated background queues do not delay heartbeat, stop, kill, detach, or
  terminal-result delivery;
- socket teardown still stops PTY stream workers before the reader closes the fd.

### Builds and end to end

- focused Bridge dispatcher tests;
- focused Hub runtime registry/waiter tests;
- `nix build .#ham-bridge --no-link`;
- `nix build .#ham-hub --no-link`;
- local enrollment followed by provider scan, provider test, agent launch, shell
  attach, forced reconnect, and repeat scan from the user's UI.

---

## 10. Acceptance Criteria

1. The Bridge reader has no blocking command handler in its call graph.
2. Heartbeats continue within their normal cadence while any command worker is slow.
3. Provider discovery either completes inside its budget or returns a provider-local
   timeout; it does not return 504 because an unrelated command ran first.
4. Queue memory, queued cost, subprocess concurrency, and result buffering are
   strictly bounded.
5. Conflicting commands preserve FIFO ordering; unrelated commands make progress in
   parallel.
6. A duplicate `command_id` never repeats an external side effect.
7. Accepted and terminal command states are distinguishable at both Hub and Bridge.
8. Reconnect cannot make a worker write through a stale connection pointer.
9. Only the reader closes the Hub connection, after the existing stream-worker
   teardown ordering.
10. No child-process timeout leaves a zombie.
11. The Hub maps busy, timeout, malformed result, and disconnect to distinct errors.
12. Local user-flow testing passes from enrollment through provider scanning and
    agent launch under an injected slow command.
13. Under sustained overload, control and recovery traffic remains responsive,
    background work is shed first, and Hub retry behavior converges instead of
    producing a retry storm.
14. A stalled or noisy Bridge cannot block another Bridge's writer, consume its
    retained results, or make the Hub silently exceed its declared registry limits.

---

## 11. Explicit Non-Goals

- Changing enrollment, bearer-token, vault-encryption, or Authentik behavior.
- Persisting the Bridge work queue across process restart.
- Automatically retrying uncertain side effects with a new command id.
- Moving durable business state from Hub repositories to the Bridge.
- Replacing the PTY/tunnel streaming data plane in the first implementation.
- Making every Hub HTTP endpoint asynchronous; synchronous terminal waits remain
  valid when they do not block the Bridge reader.

---

## 12. Recommended Review Gates

Review this change in four independently deployable gates:

1. Hub accepted→terminal result state and waiter registry.
2. Bridge queue/outbox/generation foundation with provider discovery migrated.
3. Lifecycle, notification, and shell replay migration.
4. Remaining FS/VCS/LSP/update handlers plus exhaustive no-inline-blocking audit.

Do not merge a gate that introduces worker execution while workers still retain the
WebSocket connection pointer. The response outbox and generation checks are safety
prerequisites, not cleanup work.
