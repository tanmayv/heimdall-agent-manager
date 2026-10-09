# Binary pane streaming implementation plan

**Status:** Proposed implementation plan  
**Date:** 2026-10-09  
**Source baseline:** `a55230c4` on `main`  
**Scope:** Agent and shell terminal streams between Bridge, Hub, and browser or Electron UI

Move terminal output and screen snapshots from Base64 inside JSON to binary WebSocket messages. Keep JSON for control messages and retain the existing JSON pane format during a negotiated rollout. The Hub continues to route encrypted terminal data without receiving vault keys or decrypting payloads.

Binary transport reduces wire bytes and encoding work. It does not resolve blocking writes, growing queues, or retained command results. Those scaling defects must be addressed before broad rollout, and transport performance must be measured independently from those fixes.

## Current behavior and scaling constraints

The Bridge reads raw terminal bytes from a dedicated PTY stream worker, optionally encrypts them, Base64 encodes them, and sends `shell_pty_output` JSON over its shared Hub WebSocket. The Hub parses that message and synchronously forwards JSON to attached viewers. The UI decodes Base64 and, for encrypted messages, decrypts before writing bytes to the terminal.

Relevant code:

- [Bridge stream encoding and encryption](../../src/bridge/pty_host_stream_worker.odin)
- [Bridge WebSocket send and application chunking](../../src/bridge/main.odin)
- [Hub Bridge frame dispatch](../../src/hub/transport/http/bridge_handlers.odin)
- [Hub viewer attachment and fan-out](../../src/hub/service/shell_session/shell_session_service.odin)
- [Shell stream UI](../../src/ui/components/shells/useShellStream.ts) and [agent stream UI](../../src/ui/components/chat/useAgentStream.ts)
- [WebSocket readers](../../src/lib/ws/reader.odin), [client transport](../../src/lib/ws/ws.odin), and [server writers](../../src/lib/ws/server_frame.odin)

Encrypted output currently puts the same encrypted record in both `enc_b64` and an armored `data_b64` field. Measure both fields when comparing formats. A single Base64 representation expands binary data by approximately one third; removing it reduces that representation by approximately one quarter. Duplicated ciphertext and additional application chunk encoding can make the actual reduction larger. Report measured complete wire bytes rather than assuming one expansion factor.

Default pane viewing polls at 500 ms when expanded; WebSocket streaming is gated by `streaming_terminal_pane`. This change applies to the streaming path. HTTP pane capture, logs, filesystem messages, and other command responses retain their current contracts initially.

The networking audit identified these rollout prerequisites:

| Constraint | Required change |
| --- | --- |
| Command result ring overwrites allocations without reclaiming them | Define ownership, consume or expire results safely, and bound retained bytes as well as entries |
| One global registry lock covers blocking writes to all bridges | Separate registry bookkeeping from per-connection writers and network I/O |
| Viewer fan-out blocks the Bridge reader | Give each viewer an independent bounded writer queue and deadline |
| TLS pipe writes have no application deadline | Bound pipe writes and close a connection after a partial write failure |
| PTY host and Bridge output queues can grow without a byte limit | Apply explicit limits, observability, and screen resynchronization on overflow |
| Live bridge registry has 128 slots; instance tracking has 256 slots | Use synchronized registries with explicit admission limits and lifecycle cleanup |
| Bridge processes one inbound frame per loop followed by a 25 ms sleep | Drain ready messages within a fairness budget and keep control traffic responsive |

These changes can land separately from the binary protocol. Do not free a cached reply while a waiter still borrows it, or free a connection while a writer still holds it. Preserve reader ownership of socket close, using shutdown to wake readers as documented in [AGENTS.md](../../AGENTS.md).

## Scope and invariants

Implement binary output and screen snapshots for both agent and shell panes. Preserve terminal byte order, catch-up behavior, vault lock behavior, ownership checks, `stream_ready`, `stream_closed`, input, resize, and reconnect behavior.

Keep input and resize in their existing JSON contracts for the first release. Keep the existing vault key distribution and UI unlock workflow. Terminal bytes may contain split UTF-8 sequences, ANSI escapes, and arbitrary byte values; never interpret the transport payload as a JSON string or decode each network chunk as an independent UTF-8 string.

The existing WebSocket parser already recognizes binary opcode `0x2`, but text-oriented helpers discard the opcode. Add a typed message API instead of passing binary data through JSON dispatch. Reuse shared framing and continuation handling rather than introducing another WebSocket implementation. Bridge-to-Hub writes must comply with client masking rules; Hub-to-browser writes use server framing.

## Capability negotiation and compatibility

Introduce a capability named `pane_binary_v1`; keep the existing overall Bridge protocol version unchanged during migration.

1. A new Bridge advertises supported pane encodings and its maximum binary message size in its hello. A new Hub selects an encoding and size in `bridge_ready`.
2. An omitted capability or selection means legacy JSON. A Bridge never emits binary messages before explicit selection.
3. A new UI advertises `pane_binary_v1` on the existing stream URL using an optional query parameter. The Hub returns the selected encoding in its JSON `ready` frame. Until selection, the UI accepts the legacy format.
4. Negotiation is separate on each hop. The Hub records the chosen mode for each Bridge connection and each viewer, rather than assuming every viewer uses the Bridge's format.
5. Selection remains fixed for the connection. An encoding change requires a new connection, a new stream epoch, and a fresh screen snapshot.

Prefer deploying a Hub that supports both formats first, then Bridges and the UI. Verify that old Hubs accept the additional hello fields; if they reject them, deploy the compatible Hub before capability-advertising Bridges.

| Bridge mode | Viewer mode | Hub behavior |
| --- | --- | --- |
| JSON | JSON | Existing relay |
| Binary | Binary | Forward validated routing header and opaque payload |
| JSON | Binary | Decode the relevant Base64 record once, then emit binary |
| Binary | JSON | Encode the record for that viewer only, preserving the existing JSON contract |

Conversions never decrypt terminal data. Keep compatibility conversions out of the binary-to-binary fast path. Cache conversion work per frame when several viewers need the same representation, with explicit buffer ownership and lifetime.

## Proposed binary message format

One binary WebSocket message carries one pane record. The following layout is the proposed `pane_binary_v1` contract; finalize it with shared fixtures before implementation. All integers use network byte order.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 bytes | Magic `HMPN` |
| 4 | 1 byte | Envelope version, initially `1` |
| 5 | 1 byte | Kind: `1` output, `2` screen snapshot part |
| 6 | 2 bytes | Flags, including encrypted payload; unknown flags are invalid |
| 8 | 2 bytes | Total header length, including the session ID |
| 10 | 2 bytes | UTF-8 session ID length |
| 12 | 4 bytes | Payload byte length |
| 16 | 16 bytes | Stream epoch, regenerated on stream replacement or reconnect |
| 32 | 8 bytes | Sequence number within that epoch |
| 40 | 4 bytes | Snapshot part index; zero for output |
| 44 | 4 bytes | Snapshot part count; zero for output |
| 48 | Variable | Session ID, at most 256 bytes |
| Header end | Variable | Raw terminal bytes or encrypted record |

The WebSocket message length must equal header length plus payload length. Reject invalid versions, lengths, flags, snapshot indices, and IDs before allocating payload-sized buffers. Use checked integer arithmetic. The UI represents 64-bit sequence numbers as `bigint`, not JavaScript `number`.

Bind the session ID to the authenticated Bridge connection and to the authorized viewer subscription. The Hub must not route an arbitrary Bridge-provided session ID solely because it appears in a valid header. A viewer socket already belongs to one pane; reject a different session ID on that socket. Drop records from stale connection generations or epochs.

Start with a proposed **8 KiB maximum complete binary message**, including header and payload. Negotiate the minimum supported size at each hop. Validate this budget against the actual proxy path, socat, and the supported TLS fallback; the historical proxy size comments are not a deployment guarantee. Split terminal bytes before encryption so every message contains a complete independently authenticated encrypted record.

Output is ordered by epoch and sequence. A sequence gap, duplicate, invalid snapshot sequence, or authentication failure triggers resynchronization rather than silently continuing a terminal whose state may be corrupted. There is no replay of arbitrary incremental output across a reconnect.

## Vault encryption and screen snapshots

Expose byte-oriented encryption and decryption helpers. Initially preserve the existing encrypted record layout: **12-byte nonce, 16-byte authentication tag, then ciphertext**. Remove Base64 and the textual armor from the binary representation. Keep legacy helpers as wrappers around the byte helpers where compatibility requires them.

The stream epoch is a routing and ordering identifier; it is not the AES nonce. Before rollout, review nonce uniqueness across concurrent workers, multiple Bridges sharing a vault key, reattachments, and process restarts. A random 32-bit worker salt must not be described as a global uniqueness guarantee. If the existing nonce allocation cannot meet the intended scale, specify and review a separate cryptographic change before enabling binary streaming broadly.

The proposed routing header is not authenticated by the existing ciphertext format. Preserve server-side connection and ownership validation, and explicitly test record replay and cross-session routing. Cryptographically authenticating the header would require a versioned encryption change and must not be silently introduced as part of removing Base64.

For an encrypted session, an unavailable key or encryption failure must not fall back to plaintext. Report vault lock state using JSON controls and suspend data delivery until the required unlock and fresh snapshot succeed. The Hub never stores, logs, or decrypts vault keys or terminal ciphertext contents.

A screen repaint may span several binary records. All parts use the same epoch and form one contiguous sequence, with part index and count describing that snapshot. Output for the same pane must not interleave with its snapshot; other panes and control messages may proceed.

The UI decrypts parts in order and applies a complete snapshot as one repaint. Incomplete snapshots expire; they never produce a partial terminal repaint. Proposed initial bounds are 1 MiB per assembled snapshot and a 5-second assembly deadline. A snapshot exceeding the budget produces an explicit resynchronization error, with a bounded capture fallback where available.

## Writers and backpressure

Use one writer owner per Bridge connection and per viewer socket. The reader validates and routes records, then enqueues them; it never performs a potentially blocking viewer write. Share immutable payload buffers where possible, releasing them only when all consumers finish. Do not hold a global registry lock while encoding, enqueueing, or writing a frame.

Proposed starting budgets are 256 KiB of queued incremental data per viewer and per stream, plus an 8 MiB aggregate data budget per Bridge. Account snapshot assembly and pending snapshot delivery separately within the aggregate budget. These are configurable starting values for load testing, not proven production sizing.

A slow viewer exhausting its budget is disconnected with a specific reason. It reconnects and receives a current screen; arbitrary incremental bytes are not silently dropped. If a Bridge stream overruns its budget, detach that stream, discard its obsolete epoch, and reattach with a fresh snapshot once capacity returns. Apply corresponding byte limits to PTY host reply channels so congestion is not merely moved upstream.

Reserve bounded capacity for heartbeats, input, resize, lifecycle, and shutdown controls. Schedule control and pane data fairly; priority must never interleave bytes inside a WebSocket frame or output inside a snapshot for the same pane. Limit bulk filesystem and snapshot work so it cannot monopolize a connection.

A send timeout or partial frame write terminates the affected connection. Retry only through a fresh connection and snapshot. Preserve the socket ownership rules during shutdown. Use one tested transport writer for text and binary, including ping and pong frames.

## Implementation sequence

| Phase | Deliverables | Completion gate |
| --- | --- | --- |
| 1. Bound existing transport | Safe command-result ownership, per-connection writers, bounded queues, deadlines, registry synchronization, and fair inbound draining | Sustained legacy traffic has bounded memory; one slow peer cannot stall other Bridges |
| 2. Define codecs | Shared envelope constants, Odin and TypeScript byte codecs, typed WS message APIs, crypto byte helpers, and negotiated capabilities | Cross-language fixtures round-trip exactly; malformed inputs fail within allocation limits |
| 3. Bridge production and Hub relay | Split output before encryption, emit binary records, validate session ownership, route opaque bytes, and implement mixed-format conversion | Every old/new Bridge and Hub combination follows the negotiated mode without silent data loss |
| 4. UI consumption | Shared binary decoder for agent and shell panes, `binaryType = 'arraybuffer'`, ordered decrypt/render queue, snapshot assembly, and reconnect handling | Identical rendered terminal state for JSON and binary fixtures, including vault and reconnect cases |
| 5. Canary and expansion | Feature flags, metrics, actual proxy verification, and load tests | Resource, latency, correctness, and compatibility gates below pass |

Land the phases as reviewable changes. Phase 2 may proceed while Phase 1 is being implemented, but broad activation depends on both. Binary input, compression, a separate data WebSocket, and removal of legacy JSON are later decisions based on measurements.

## Validation and acceptance criteria

Codec tests must cover empty and arbitrary binary payloads, split UTF-8, ANSI sequences, message boundaries, masked client frames, RFC continuation frames with intervening control frames, malformed headers, oversized records, invalid flags, maximum IDs, and JavaScript sequence numbers above `2^53`.

Encryption tests must cover disabled, locked, and unlocked vault states, byte-for-byte conversion of the existing encrypted record format, tampered ciphertext, failed encryption, stale epochs, and nonce allocation under concurrent streams. Run the same terminal traces through both agent and shell hooks. Check final screen contents, cursor position, ordering, snapshot completeness, lifecycle events, and geometry.

Integration tests must exercise the four negotiated mode combinations through a real isolated Hub and Bridge. Include multiple viewers, a viewer that stops reading, a Bridge that stops reading, bridge reconnect, viewer reconnect, a missed detach, mixed filesystem/LSP traffic, and UI decryption slower than arrival. Use test credentials and independent ports; never restart production services.

Use a workload matrix of 1, 10, 50, and 100 Bridges initially, expanding to 250 only after admission and registry changes. Vary watched panes per Bridge, viewers per pane, idle periods, output rates of 1, 20, and 100 KiB/s, and bounded bursts. Record CPU, RSS, threads, descriptors, ingress and egress wire bytes, allocation rate, queued bytes, pane latency, and control round-trip latency. These are test inputs, not supported-capacity claims.

Release gates:

- No Base64 or JSON terminal payload in the negotiated binary-to-binary path; compatibility conversion is explicit and measured.
- Exact terminal output and complete screen repaint under ordinary delivery; sequence loss causes a diagnosed resynchronization.
- No unauthenticated or cross-Bridge session routing and no plaintext fallback for encrypted sessions.
- Memory plateaus under fixed sustained load and returns to a documented bounded idle baseline after detach; repeated connects do not accumulate workers or descriptors.
- A stalled viewer or Bridge cannot block healthy Bridges; all queues remain within configured byte budgets.
- Proposed healthy-control target: p95 below 250 ms and p99 below 1 second in the declared local test environment. Report network conditions separately from server processing time.
- Report the largest passing workload with its hardware, deployment path, duration, viewer count, and output rates. Do not publish a Bridge-count capacity claim alone.

Expose negotiated modes, input/output bytes, queue high-water marks, write timeouts, slow-consumer disconnects, snapshot assembly failures, and sequence resynchronizations. Avoid per-frame logging of payload contents or successful decrypts in production.

## Rollout and rollback

Add a Hub capability flag independent of the existing terminal-streaming experiment. Keep binary mode disabled by default until compatibility and transport gates pass. Canary selected users and Bridges first, then expand by workload rather than registered Bridge count alone.

Rollback disables new binary selections. Existing binary connections are closed deliberately so they reconnect in legacy mode; never switch encoding halfway through a stream. Preserve JSON readers, writers, and UI decoding for at least one documented release window. The Hub, updated Bridges, and updated UI are all required to achieve the binary-to-binary path; `ham-ctl` needs no change for output-only streaming.

A second Hub replica does not by itself scale this architecture: live connections, viewer subscriptions, and pending command ownership are process-local. Distributed routing or tenant sharding is a separate plan. Keep this rollout scoped to making each Hub's transport efficient, bounded, and isolated under congestion.
