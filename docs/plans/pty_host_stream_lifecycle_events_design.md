# Architectural Design: PTY Host `stream_ready` and `stream_closed` WebSocket Lifecycle Events

**Document Status:** Final Design Specification  
**Requirement ID:** REQ-STREAM-EVENT-1  
**Target Systems:**  
- PTY Host Daemon (`tools/pty_host`: Rust)  
- Bridge Runtime Client & Stream Worker (`src/bridge`: Odin)  
- Hub Transport & Shell Session Service (`src/hub`: Odin)  
- Frontend Terminal Hooks & Composer UI (`src/ui`: TypeScript / React)  

---

## 1. Executive Summary & Problem Statement

Currently, the terminal streaming infrastructure across Heimdall relies on passive, data-driven heuristics to infer stream lifecycle state:
1. **Premature WebSocket Ready Acks:** When the browser connects to `/api/v1/agent-instances/{id}/stream` or `/api/v1/shells/{id}/stream`, the Hub immediately sends `{"type":"ready"}` upon the HTTP WebSocket upgrade (`shell_session_handlers.odin:135`, `agent_instance_handlers.odin:167`). This frame merely indicates that the browser-to-hub TCP/WS socket is open; it does **not** signify that the bridge has attached, that `ham-pty-host` has allocated the PTY master/slave pair, or that the target child process is running and receptive to input.
2. **Dropped Initial Keystrokes (`KEY_EVENTS`):** In both `useShellStream.ts:522` and `useAgentStream.ts:387`, `sendInput()` immediately discards any keystrokes, escape sequences, or carriage returns if the WebSocket state is not `WebSocket.OPEN` or if emitted before the child PTY is interactive. Even when the socket is `OPEN`, typing before the process has initialized termios leads to dropped or misordered characters.
3. **Fragile UI Preview Popups:** In `ConversationThreadPage.tsx:640` and `AgentPaneComposerPanel.tsx:155`, the startup preview popup triggers only upon receiving the first raw output bytes (`onOutput -> handleStreamOutput`). If an agent process is silent on startup (e.g., standard CLI awaiting input without an initial banner), the preview popup never appears. Conversely, if an agent exits prematurely or fails to start, the UI has no explicit `stream_closed` event to cleanly tear down the preview.

This design establishes a reliable, bidirectional lifecycle signaling pipeline:
- **`stream_ready`**: Emitted end-to-end once the PTY master/slave pair is open, the child process is forked and spawned, the streaming socket is attached, and the input pipeline is ready to consume keystrokes.
- **`stream_closed`**: Emitted end-to-end when the session terminates (normal exit, signal, or explicit stop), unblocking cleanup and triggering UI teardown.
- **KEY_EVENTS Guaranteed Delivery**: An in-memory queue on the frontend/bridge that safely buffers initial keystrokes until `stream_ready` arrives, flushing them in strict FIFO sequence.

---

## 2. PTY Host Lifecycle & Hook Points (`tools/pty_host`)

### 2.1 Code Path Trace: Process Spawn

The PTY Host daemon is driven by control messages received over its local domain socket:

```text
Bridge (Odin)                DaemonServer (Rust)                 PtyHost (Rust)
  |                                 |                                  |
  |-- CtlMsg::Spawn(req) ---------->|                                  |
  |   (dproto.rs:288)               |-- daemon.spawn(spec)             |
  |                                 |   (daemon.rs:250)                |
  |                                 |-- PtyHost::spawn(config) ------->|
  |                                 |   (host.rs:95)                   |-- openpty()
  |                                 |                                  |-- pair.slave.spawn_command()
  |                                 |                                  |-- drop(pair.slave)
  |                                 |                                  |-- reader & wait threads
  |                                 |<-- PtyHost instance -------------|
  |                                 |-- spawn pump_output thread       |
  |                                 |-- spawn exit_watch thread        |
  |<-- CtlReply::Spawned { pid } ---|
```

1. **Control Message Dispatch (`tools/pty_host/src/daemon.rs:991`):**  
   `handle_ctl` matches `CtlMsg::Spawn(req)` and executes `daemon.spawn(req)`.
2. **Registration Check (`tools/pty_host/src/daemon.rs:250-268`):**  
   Validates non-empty `instance` and `argv`, verifies that `instance` is not already registered in `self.agents`, and delegates to `self.build_agent(spec)`.
3. **PTY & Process Allocation (`tools/pty_host/src/host.rs:95-150`):**
   - **Line 97–104:** `NativePtySystem::default().openpty(...)` opens the operating system pseudo-terminal pair (`pair.master` and `pair.slave`).
   - **Line 126–129:** `pair.slave.spawn_command(cmd)` forks and execs the program (`config.program`, `config.args`, environment variables, and `config.cwd`). The child process inherits the PTY slave as its controlling terminal (`stdin`, `stdout`, `stderr`).
   - **Line 133:** `drop(pair.slave)` explicitly drops the host's copy of the slave descriptor. The child process remains the sole holder of the slave, ensuring EOF will be detected on the master reader when the child exits.
   - **Line 140–146:** Master handles are extracted: `pair.master.take_writer()` yields `Box<dyn Write + Send>` for stdin, and `pair.master.try_clone_reader()` yields the reader handle.
   - **Line 153–178:** Reader thread starts, reading bytes from `reader.read(&mut buf)`, feeding `VtEngine`, and forwarding raw chunks over `output_tx`.
   - **Line 180–192:** Wait thread starts, blocking on `child.wait()` to record exit code and flip `child_alive`.
4. **Daemon Threads (`tools/pty_host/src/daemon.rs:307–350`):**
   - `pump_output` (lines 307–315, 698–731): Receives bytes from `output_rx`, updates `last_activity`, writes to `tee_path` file, and sends `CtlReply::Output` to all matching subscribers in `self.subs`.
   - `exit_watch` (lines 317–350): Loops every 30ms watching `alive.load(Ordering::SeqCst)`. Upon child termination, broadcasts `CtlReply::ChildExited { instance, code }` to all connections registered in `self.watchers`.

### 2.2 Code Path Trace: Client Stream Attach

When a consumer connects to stream output:

1. **Attach Request (`tools/pty_host/src/daemon.rs:1030`):**  
   `handle_ctl` matches `CtlMsg::Attach { instance }` and calls `daemon.attach(id, &instance)`.
2. **Subscription Attachment (`tools/pty_host/src/daemon.rs:608-633`):**
   - **Line 609–611:** Validates existence of `shell_id` in `self.agents` and captures initial screen state via `self.capture(shell_id)`.
   - **Line 613–619:** Retrieves the client connection's sink channel from `self.sinks`.
   - **Line 622–625:** **Pre-queues catchup snapshot:** Sends `CtlReply::Screen` onto `tx` *before* registering into `self.subs`. This guarantees FIFO sequencing so the client receives current screen text before subsequent incremental output chunks.
   - **Line 626–631:** Inserts `shell_id` into `self.subs` for client `id`.

### 2.3 Readiness Spectrum: When is the Stream Truly Ready?

It is vital to distinguish between four distinct phases:
1. **PTY Allocation & Process Spawn Ready:** `PtyHost::spawn` has executed `openpty()` and `spawn_command()`. The child PID exists, and the PTY master writer is ready to receive bytes.
2. **Data-Plane Stream Attached:** The Bridge's dedicated streaming connection has dialed `ham-pty-host` and sent `CtlMsg::Attach`. PTY Host has registered the subscriber in `self.subs`.
3. **Stream Ready Event:** Emitted immediately upon successful `Attach` registration (accompanied by or following the initial `Screen` frame). It tells the Bridge, Hub, and Frontend: **the input/output pipeline is connected, PTY master is active, and keystrokes sent now will reach the child process.**
4. **First Output Arrival:** The child process emits its first byte to stdout. This may take 5ms for `sh`, or 1500ms for heavy runtimes (Node.js, Python, Claude CLI). Waiting for first output to consider the stream "ready" is an anti-pattern that drops early interactive input.

---

## 3. End-to-End Event Schemas & Wire Protocols

### 3.1 Layer 1: PTY Host Daemon Wire Protocol (`tools/pty_host/src/dproto.rs`)

The daemon protocol uses big-endian length-prefixed framing: `[u32 len][payload]`, where payload byte 0 is the tag.

#### New Reply Tags
- `T_STREAM_READY: u8 = 0xAE`
- `T_STREAM_CLOSED: u8 = 0xAF`

#### Rust Message Definitions (`dproto.rs`)
```rust
pub enum CtlReply {
    // ... existing variants ...
    /// REQ-STREAM-EVENT-1: Emitted to attached streaming subscribers when the
    /// PTY stream is fully attached and ready to accept input/emit output.
    StreamReady {
        instance: String,
        pid: i32,
    },
    /// REQ-STREAM-EVENT-1: Emitted to attached streaming subscribers when the
    /// stream has closed (child exited or explicitly torn down).
    StreamClosed {
        instance: String,
        exit_code: Option<i32>,
        reason: String, // "exited" | "closed" | "error"
    },
}
```

#### Wire Encoding Details
- **`StreamReady` (Tag `0xAE`):**
  `[0xAE][u32 instance_len][instance bytes][i32 pid (BE)]`
- **`StreamClosed` (Tag `0xAF`):**
  `[0xAF][u32 instance_len][instance bytes][u8 has_exit_code][i32 exit_code (if 1)][u32 reason_len][reason bytes]`

---

### 3.2 Layer 2: Bridge to Hub WebSocket Runtime Client (`src/bridge`)

The Bridge relays PTY Host stream lifecycle frames over the primary WebSocket runtime link to the Hub:

#### `shell_pty_stream_ready`
Emitted by `pty_host_stream_worker.odin` immediately when `CtlReply::StreamReady` is decoded, or upon `bridge_pty_stream_worker_start` confirmation.
```json
{
  "type": "shell_pty_stream_ready",
  "session_id": "sh_18dba91e710162e7",
  "shell_id": "sh_18dba91e710162e7",
  "agent_instance_id": "inst_18dbaae8be265355",
  "pid": 48291
}
```

#### `shell_pty_stream_closed`
Emitted when `CtlReply::StreamClosed` is decoded, or when the stream worker shuts down upon child process exit or session teardown.
```json
{
  "type": "shell_pty_stream_closed",
  "session_id": "sh_18dba91e710162e7",
  "shell_id": "sh_18dba91e710162e7",
  "agent_instance_id": "inst_18dbaae8be265355",
  "exit_code": 0,
  "reason": "exited"
}
```

---

### 3.3 Layer 3: Hub to Frontend WebSocket Client (`src/hub` -> `src/ui`)

Dispatched by `src/hub/transport/http/bridge_handlers.odin` and `shell_session_service.odin` to all connected browser WebSockets on `/api/v1/shells/{id}/stream` and `/api/v1/agent-instances/{id}/stream`.

#### `stream_ready`
```json
{
  "type": "stream_ready",
  "session_id": "sh_18dba91e710162e7",
  "agent_instance_id": "inst_18dbaae8be265355",
  "pid": 48291
}
```
*(Note: Distinct from the legacy `{"type":"ready"}` frame which only acknowledges the HTTP WebSocket upgrade).*

#### `stream_closed`
```json
{
  "type": "stream_closed",
  "session_id": "sh_18dba91e710162e7",
  "agent_instance_id": "inst_18dbaae8be265355",
  "exit_code": 0,
  "reason": "exited"
}
```

---

## 4. `KEY_EVENTS` Delivery Guarantee & Buffering Mechanism

### 4.1 Root Cause of Dropped Keystrokes
1. **Frontend Drop on `!WebSocket.OPEN`:** In `useShellStream.ts:522`, `sendInput()` immediately logs a warning and returns when the socket is in `CONNECTING` or before `stream_ready`.
2. **Race Condition on Process Initialization:** Even if the WebSocket connection is open, the child process may still be executing dynamic linker operations or configuring termios raw/echo modes. Keystrokes written to the PTY master during this sub-100ms window can either be flushed by a child `tcsetattr` call or interpreted incorrectly by standard canonical mode line buffering.

### 4.2 Two-Stage Buffering Architecture

```text
[ User Keystroke / Action ]
            |
            v
+------------------------------------------+
| Frontend Stage 1 Queue                   |
| (useShellStream / useAgentStream)        |
| - KeyEvents buffer (FIFO array)          |
| - Gated on `stream_ready` boolean flag    |
+------------------------------------------+
            |
            | (Flushed in order upon `stream_ready`)
            v
[ Encrypted/Plaintext WebSocket Frame ]
            |
            v
+------------------------------------------+
| Hub Transport & Bridge Stage 2 Relay     |
| (pty_host_stream_worker / hub_runtime)   |
| - Session input promise chain            |
| - Settle guard (termios init window)     |
+------------------------------------------+
            |
            v
+------------------------------------------+
| PTY Master Writer (ham-pty-host)         |
| -> Child Process Stdin                   |
+------------------------------------------+
```

### 4.3 Detailed Frontend Buffer Implementation (`useShellStream.ts`, `useAgentStream.ts`)

1. **State & Ref Definitions:**
   ```typescript
   const isStreamReadyRef = useRef<boolean>(false);
   const [isStreamReady, setIsStreamReady] = useState<boolean>(false);
   const pendingKeyEventsRef = useRef<Array<{ data: string; timestamp: number }>>([]);
   ```
2. **Queueing Strategy in `sendInput`:**
   ```typescript
   const sendInput = useCallback((data: string) => {
     if (!isStreamReadyRef.current) {
       console.log('[useStream] Buffering early input before stream_ready:', { length: data.length });
       pendingKeyEventsRef.current.push({ data, timestamp: Date.now() });
       return;
     }
     _dispatchInputFrame(data);
   }, []);
   ```
3. **Draining upon `stream_ready`:**
   When the `stream_ready` message arrives:
   ```typescript
   case 'stream_ready': {
     isStreamReadyRef.current = true;
     setIsStreamReady(true);
     onStreamReadyRef.current?.({ pid: msg.pid, sessionId: msg.session_id });
     
     // Drain buffered initial KEY_EVENTS in strict sequential order
     if (pendingKeyEventsRef.current.length > 0) {
       const queued = [...pendingKeyEventsRef.current];
       pendingKeyEventsRef.current = [];
       console.log(`[useStream] Flushing ${queued.length} buffered key events post stream_ready`);
       
       inputQueueRef.current = queued.reduce((chain, item) => {
         return chain.then(() => _dispatchInputFrame(item.data));
       }, inputQueueRef.current);
     }
     break;
   }
   ```
4. **Buffer Invalidation on Stream Teardown / Error:**
   When `stream_closed`, `socket.onclose`, or an error occurs:
   - Clear `pendingKeyEventsRef.current = []`.
   - Set `isStreamReadyRef.current = false; setIsStreamReady(false);`.
   - Prevents stale keystrokes from leaking into a subsequent session run.

---

## 5. UI Integration & Composer Preview Lifecycle

### 5.1 Architecture in `AgentPaneComposerPanel.tsx` & `ConversationThreadPage.tsx`

Currently, `handleStreamOutput` in `ConversationThreadPage.tsx:640` auto-expands the terminal pane when the first output bytes arrive. This creates an uncoordinated UX:

```text
Current Flow:
Agent Launch -> Wait... -> First stdout bytes -> Surprise expansion of pane -> Agent calls ready -> Auto-collapse
```

With `stream_ready` and `stream_closed`, the lifecycle becomes deterministic and intentional:

```text
New Flow:
Agent Start -> Connecting... (Composer shows subtle spinner)
                 |
                 v
           `stream_ready` received
                 |
                 +---> 1. Flush buffered initial KEY_EVENTS
                 +---> 2. Trigger preview stream popup / expand composer terminal
                 |
           Agent Running / User Interacting with Terminal Preview
                 |
                 v
           Agent Stop / Process Exited (`stream_closed` received)
                 |
                 +---> 1. Show brief terminal exit state ("Exited code 0" / "Stopped")
                 +---> 2. Cleanly collapse / tear down preview stream popup
```

### 5.2 Transition Logic Specification

#### In `ConversationThreadPage.tsx`:
```typescript
// 1. Handlers for explicit stream lifecycle events
const handleStreamReady = useCallback((info: { pid: number; sessionId: string }) => {
  // Only auto-expand if the user hasn't manually collapsed the pane
  if (!userManuallyToggledPaneRef.current) {
    setIsPaneExpanded(true);
  }
}, []);

const handleStreamClosed = useCallback((info: { exitCode?: number; reason?: string }) => {
  // When the agent process stops or session ends, smoothly tear down the composer preview
  if (!userManuallyToggledPaneRef.current) {
    // Optional: add a 500ms delay if exitCode != 0 so the user sees the error before closing
    setIsPaneExpanded(false);
  }
}, []);
```

#### In `AgentPaneComposerPanel.tsx`:
- Pass `onStreamReady={handleStreamReady}` and `onStreamClosed={handleStreamClosed}` to `useAgentStream`.
- Render a streamlined status chip in the header:
  - Connecting / Spawning: Pulse icon + "Allocating PTY..."
  - Stream Ready: Green dot + `PID ${pid}` + Live Stream
  - Stream Closed: Gray dot + `Process Exited (${exitCode})`

---

## 6. Edge Cases, Fault Tolerance & Alternatives

### 6.1 Process Crash Before `stream_ready`
- **Scenario:** The command executable does not exist (`ENOENT`), permissions are denied (`EACCES`), or an invalid library causes immediate failure.
- **Handling:** `PtyHost::spawn` forks and execs, but the child dies within microseconds. The daemon's wait thread captures the exit code immediately. Instead of emitting `CtlReply::StreamReady`, the daemon emits `CtlReply::StreamClosed { instance, exit_code: Some(127), reason: "spawn_error" }`.
- **UI Behavior:** Frontend receives `stream_closed` without ever seeing `stream_ready`. Any buffered `KEY_EVENTS` are discarded, and an error notification ("Process failed to start with code 127") is rendered without popping open an empty terminal preview.

### 6.2 Bridge / Hub WebSocket Reconnects
- **Scenario:** Network transient disconnects or Hub reload occurs while the process continues running on `ham-pty-host`.
- **Handling:**
  1. `useAgentStream` reconnects with exponential backoff (1s -> 2s -> 4s).
  2. Hub receives new viewer connection, sends `shell_stream_attach` to Bridge.
  3. Bridge dials PTY Host and sends `CtlMsg::Attach`.
  4. PTY Host sends current `CtlReply::Screen` catchup snapshot, followed immediately by `CtlReply::StreamReady`.
  5. UI receives `stream_ready`, resyncs terminal dimensions via `sendResize`, and flushes any inputs entered during the brief disconnect.

### 6.3 Multi-Tab & Viewer Deduplication
- **Scenario:** Multiple browser tabs view the same agent session.
- **Handling:**
  - The Hub's `shell_session_service.odin` tracks viewer count (`prev_count`). Only the 0->1 viewer transition triggers `shell_stream_attach` to the Bridge.
  - When Tab 2 connects (1->2 viewer transition), the Hub broadcasts `stream_ready` directly to Tab 2 along with the latest screen snapshot, allowing Tab 2 to render the preview immediately without disturbing Tab 1 or restarting the stream.

### 6.4 Backwards Compatibility & Graceful Degradation
- If a client or older Hub does not recognize `stream_ready`:
  - The JSON parser safely ignores unrecognized `type: "stream_ready"` / `type: "stream_closed"` messages.
  - A fallback timer (750ms post-`socket.onopen`) marks `isStreamReadyRef.current = true` if no explicit `stream_ready` is received, preserving functionality against older daemon versions.

---

## 7. Implementation Roadmap & Verification Plan

### Phase 1: PTY Host Rust Daemon & Protocol
- Add `T_STREAM_READY` and `T_STREAM_CLOSED` to `tools/pty_host/src/dproto.rs`.
- Update `Daemon::attach` in `tools/pty_host/src/daemon.rs` to emit `CtlReply::StreamReady`.
- Update `Agent::shutdown` and `pump_output` to broadcast `CtlReply::StreamClosed`.
- Verify: `cargo test --manifest-path tools/pty_host/Cargo.toml`.

### Phase 2: Bridge Runtime & Stream Worker (Odin)
- Update `src/bridge/pty_host_stream_worker.odin` to decode `CtlReply::StreamReady` and `StreamClosed`.
- Relay `shell_pty_stream_ready` and `shell_pty_stream_closed` via `conn: ^ws.Connection` in `bridge_pty_stream_reader_worker`.
- Verify: `odin check src/bridge -collection:odin_test=src` and unit tests in `src/bridge/pty_host_runtime_test.odin`.

### Phase 3: Hub Dispatch & Service Layer (Odin)
- Add handlers for `shell_pty_stream_ready` and `shell_pty_stream_closed` in `src/hub/transport/http/bridge_handlers.odin`.
- Add `shell_session_broadcast_stream_ready` and `broadcast_stream_closed` in `src/hub/service/shell_session/shell_session_service.odin`.
- Verify: `odin test src/hub -collection:odin_test=src`.

### Phase 4: Frontend UI Hooks & Components (TypeScript)
- Update `useShellStream.ts` and `useAgentStream.ts` with `stream_ready`/`stream_closed` handlers and `pendingKeyEventsRef` FIFO buffer.
- Update `AgentPaneComposerPanel.tsx` and `ConversationThreadPage.tsx` to mount composer preview popup on `stream_ready` and tear down on `stream_closed`.
- Verify: `npx tsc --noEmit` and component tests.
