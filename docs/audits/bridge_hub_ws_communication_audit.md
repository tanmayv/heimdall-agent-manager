# Bridge-to-Hub WebSocket Communication Layer Audit

**Date:** 2026-09-30  
**Scope:** Bridge-to-Hub & Hub-to-Client WebSocket Framing, Application-Level Chunking, Subsystem Relays (FS, Shell, LSP, Events), Memory Management, Process Transport, Test Coverage, and Empirical Controlled Test Validation  
**Primary Audited Baseline:** `/usr/local/google/home/tanmayvijay/heimdall-agent-manager` (`origin/main` @ `05ffa6cf` / `v0.3.3`)  
**Comparison Pre-`REQ-SHELL-36` Snapshot:** `/usr/local/google/home/tanmayvijay/heimdall-cloudtop` (`feat/cloudtop-single-node` @ `2bb9b48f`)  
**Requirements Covered:** `REQ-WS-AUDIT-1`, `REQ-WS-AUDIT-2`, `REQ-WS-AUDIT-3`, `REQ-WS-AUDIT-4`, `REQ-WS-AUDIT-5`, `REQ-WS-AUDIT-6`, `REQ-WS-AUDIT-7`

---

## Executive Summary & Architecture Overview

Heimdall relies on WebSockets as the real-time backbone connecting autonomous Bridge daemons (`src/bridge`) and browser/desktop clients to the central Hub (`src/hub`). Over this layer flow runtime control commands, filesystem reads/writes, interactive PTY shell streams, Language Server Protocol (LSP) JSON-RPC sessions, and user event broadcasts.

Rather than sharing a single RFC 6455-compliant WebSocket framing and transport library across both client and server roles, the codebase evolved **four distinct WebSocket frame writers** (reduced from six after `REQ-SHELL-33` and `REQ-SHELL-52` `e40a3f54`) and **three distinct WebSocket frame readers** scattered across `src/lib/ws`, `src/hub/transport/http`, and `src/hub/service/bridge_runtime`, plus **two copy-pasted application-layer JSON/Base64 chunking and reassembly engines** (`Bridge_Chunk_Reassembly` in `src/hub/transport/http/bridge_handlers.odin` and `Hub_Command_Reassembly` in `src/bridge/hub_command_reassembly.odin`).

While recent commits on `origin/main` (`05ffa6cf` / `v0.3.3` — specifically `REQ-SHELL-32`, `REQ-SHELL-33`, `REQ-SHELL-36`, `REQ-SHELL-41`, and `REQ-SHELL-52`) remediated several acute symptoms—such as adding 64-bit server-to-browser frame encoding (`server_frame.odin`), freeing outbound frame buffers in `ws.send_text` and `bridge_runtime.write_ws_text_frame`, and introducing Hub $\rightarrow$ Bridge application-level command chunking (`hub_command_chunk.odin` / `hub_command_reassembly.odin`)—**fundamental protocol, memory, and transport defects remain active on `origin/main` (`05ffa6cf`)**.

### Summary of Critical & High Findings on `origin/main` (`05ffa6cf` / `v0.3.3`)

| ID | Severity | Category | Summary (`origin/main` @ `05ffa6cf`) | Primary Locations (`05ffa6cf`) |
| :--- | :--- | :--- | :--- | :--- |
| **WS-01** | **CRITICAL** | Wire Framing (`REQ-WS-AUDIT-1`) | **65,535-byte 16-bit frame ceiling & fatal 64-bit (`payload_len == 127`) drops:** `write_ws_text_frame` (`allow_64bit = false`), `bridge_runtime.write_ws_text_frame`, and `ws.send_text` hard-reject payloads $> 65,535\text{ B}$. Both `bridge_ws_take_frame` and `ws.poll_text` treat RFC 6455 64-bit length frames (`127`) as fatal protocol errors—including on **browser-facing** `/api/v1/shells/{id}/stream` and `/api/v1/agent-instances/{id}/stream` sockets, where pasting $>64\text{ KB}$ kills the terminal session. | `src/lib/ws/server_frame.odin:59,119-125`<br>`src/hub/transport/http/bridge_handlers.odin:2355-2357,2455-2465`<br>`src/hub/service/bridge_runtime/bridge_runtime.odin:132,241-243`<br>`src/lib/ws/ws.odin:215-218,259-262`<br>`src/hub/transport/http/shell_session_handlers.odin:142-148`<br>`src/hub/transport/http/agent_instance_handlers.odin:187-192` |
| **WS-02** | **HIGH** | Duplicated Chunking (`REQ-WS-AUDIT-2`, `REQ-WS-AUDIT-3`) | **Two copy-pasted, asymmetric Base64+JSON chunk engines (`Bridge_Chunk_Reassembly` vs `Hub_Command_Reassembly`) with admission-only TTL sweeps:** Bridge $\rightarrow$ Hub emits 14-field JSON chunks (`45,000\text{ B}` `socat` / `6,000\text{ B}` `s_client`, `12,000\text{ B}` in legacy configs), while Hub $\rightarrow$ Bridge (`REQ-SHELL-36`) emits 8-field JSON chunks (`6,000\text{ B}`). Both inflate wire bytes by **~33–38%** (`1.78x` on binary FS images) and gate their TTL sweeps on `len >= 64` (`BRIDGE_WS_MAX_REASSEMBLIES`), pinning up to 63 abandoned streams indefinitely. | `src/bridge/main.odin:574-600,639-671`<br>`src/hub/transport/http/bridge_handlers.odin:1332-1517,1583-1606`<br>`src/hub/service/bridge_runtime/hub_command_chunk.odin:78-138`<br>`src/bridge/hub_command_reassembly.odin:52-272` |
| **WS-03** | **HIGH** | Subsystem Failure (`REQ-WS-AUDIT-3`) | **Unchecked fire-and-forget relay drops, JSON parser truncation/aliasing, & direct `ws.send_text` bypasses:** `lsp_session_handlers.odin` (`_ = bridge_service.send_lsp_message`) and `shell_session_handlers.odin` ignore command send errors. `bridge_runtime.json_string` truncates strings at escaped quotes (`\"`) and returns uncloned subslices aliasing the input buffer. | `src/hub/service/bridge_runtime/bridge_runtime.odin:132,149-168,285-294`<br>`src/hub/transport/http/lsp_session_handlers.odin:913,984`<br>`src/hub/transport/http/shell_session_handlers.odin:160,167` |
| **WS-04** | **CRITICAL** | Wire Framing (`REQ-WS-AUDIT-1`) | **Broken RFC 6455 fragmentation (`FIN=0` / `opcode == 0x0`) in 2 of 3 readers:** Only `Lsp_WS_Reader` reassembles fragmented frames. `bridge_ws_take_frame` ignores `FIN=0` (delivering truncated JSON) and treats `opcode == 0x0` continuation frames as `fatal = true` (`.Fatal_Frame`). `ws.poll_text` ignores `FIN=0` and silently discards `0x0` continuation frames. | `src/hub/transport/http/bridge_handlers.odin:2340-2347`<br>`src/lib/ws/ws.odin:208,225-233`<br>`src/hub/transport/http/lsp_session_handlers.odin:489-594` |
| **WS-05** | **HIGH** | Stream Integrity (`REQ-WS-AUDIT-1`) | **Mid-frame send failures leave sockets open & desynchronized:** If `bridge_runtime.write_ws_text_frame` (`:257-263`) or `ws.send_all_tcp` (`:319-336`, after the 5s `WRITE_DEADLINE`) fails after writing `> 0` bytes of a frame, neither closes the socket or sets `conn.connected = false`. Subsequent writes inject a new `0x81` header into the unfinished frame payload. | `src/hub/service/bridge_runtime/bridge_runtime.odin:257-263`<br>`src/lib/ws/ws.odin:319-336`<br>`src/lib/ws/server_frame.odin:133-145` |
| **WS-06** | **CRITICAL** | Memory Leaks (`REQ-WS-AUDIT-4`) | **3 active heap memory leak sites on `origin/main` (`05ffa6cf`):** (1) `ws.poll_text` (`:235-239`) overwrites `conn.pending_bytes = remaining` without `delete(conn.pending_bytes)` on every consumed frame; (2) `bridge_hub_runtime_loop` (`hub_runtime_client.odin:308-344`) leaks every inbound `text` and `assembled` string (**~38.9 MiB leaked per 16 MiB chunked command**) plus heartbeat strings; (3) `send_validate_project_path_command` (`bridge_runtime.odin:135-139`) leaks `ws.poll_text` strings to avoid a use-after-free on `parsed.validation_error`. | `src/lib/ws/ws.odin:122,153-165,235-239`<br>`src/bridge/hub_runtime_client.odin:308-344,371`<br>`src/hub/service/bridge_runtime/bridge_runtime.odin:135-139,149-168`<br>`src/hub/transport/http/bridge_handlers.odin:1197-1204,1572` |
| **WS-07** | **HIGH** | Concurrency & Process (`REQ-WS-AUDIT-4`) | **Missing `SO_SNDTIMEO` under global command mutex & unbounded TLS pipe writes (`send_all_file`):** Hub $\rightarrow$ Bridge writes hold global `bridge_runtime_registry_command_lock` across up to 2,797 chunk frames on a socket with no `SO_SNDTIMEO`. Bridge `wss://` (`socat`/`openssl s_client`) writes via `send_all_file` (`ws.odin:283, 342-350`), which has **no `WRITE_DEADLINE`** while holding `conn.send_mu`, and `ws.send_timeouts()` (`:295-312`) is structurally always `0` on TLS. | `src/hub/service/bridge_runtime/bridge_runtime.odin:21-23,37-39,204-234`<br>`src/lib/ws/ws.odin:90-165,283,290-312,342-350` |

---

### Recent `origin/main` (`05ffa6cf` / `v0.3.3`) Changes vs. `feat/cloudtop-single-node` (`2bb9b48f`)

Between the pre-`REQ-SHELL-36` snapshot (`2bb9b48f` in `/usr/local/google/home/tanmayvijay/heimdall-cloudtop`) and current `origin/main` (`05ffa6cf` / `v0.3.3` in `/usr/local/google/home/tanmayvijay/heimdall-agent-manager`), five shell/WS robustness tasks landed:

1. **`REQ-SHELL-33` (`src/lib/ws/server_frame.odin:1-147`)**:
   - Introduced `ws.write_server_text(socket, text, allow_64bit)` (`:119-146`) with 7-bit, 16-bit (`WS_16BIT_MAX_PAYLOAD :: 65535` at `:59`), and 64-bit (`WS_MAX_SERVER_PAYLOAD :: 16 * 1024 * 1024` at `:67`) header encoding (`server_frame_header` at `:91-111`), a `defer delete(frame)` (`:129`), a short-write loop (`:133-145`), and a typed `Text_Write_Result` enum (`.Ok`, `.Too_Large`, `.Peer_Gone`, `.Desynchronised` at `:71-76`).
   - Consolidated three Hub-side server writers onto `ws.write_server_text`:
     - `http.write_ws_text_frame` (`bridge_handlers.odin:2455-2465`, `allow_64bit = false` — keeping the 65,535-byte hard cap on the Bridge control socket) and `http.write_ws_text_frame_browser` (`bridge_handlers.odin:2472-2474`, `allow_64bit = true`).
     - `events.publish_raw_to_user` (`src/hub/service/events/event_bus.odin:82`, `allow_64bit = true`).
     - `shell_session._write_ws_text` (`src/hub/service/shell_session/shell_session_service.odin:1822-1824`, `allow_64bit = true`) and per-session `shell_session_viewer_write_lock` (`:342-367`).
2. **`REQ-SHELL-32` & `REQ-SHELL-52` (`4e4ff21e`, `2712c5ad`, `e40a3f54`)**:
   - Added `BRIDGE_WS_REASSEMBLY_TTL :: 30 * time.Second` (`bridge_handlers.odin:1356`, earlier `60 * time.Second` at `:1405` in pre-rebase drafts) and lazy admission-gate sweep `bridge_chunk_reassembly_sweep` (`bridge_handlers.odin:1362-1371`, called at `:1445` only when `len(reassemblies) >= 64`) + oldest-stream eviction (`:1452-1460`).
   - Added `conn.send_mu` (`src/lib/ws/ws.odin:35, 263-264`), `WRITE_DEADLINE :: 5 * time.Second` (`ws.odin:290`, applied in `send_all_tcp` at `:319-336` only), and `defer delete(frame)` (`ws.odin:273`) in `ws.send_text` (`ws.odin:259-285`).
   - Deleted the unreachable `write_ws_text` procedure from `src/bridge/main.odin` (`e40a3f54`), reducing the total number of distinct outbound `0x81` WebSocket frame writers across the codebase to **4**.
3. **`REQ-SHELL-36` (`f6bf8ce0`, `016e8899`)**:
   - Added `defer delete(frame)` to `bridge_runtime.write_ws_text_frame` (`src/hub/service/bridge_runtime/bridge_runtime.odin:252`), `defer delete(body)` to `send_validate_project_path_command` (`:131`), and conditional `delete(result_json)` in `validate_project_path` (`:115-118`).
   - Added `write_ws_command` (`bridge_runtime.odin:204-234`), `src/hub/service/bridge_runtime/hub_command_chunk.odin:1-139`, and `src/bridge/hub_command_reassembly.odin:1-273` to split Hub $\rightarrow$ Bridge commands exceeding `BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES` (`6,000` bytes, `src/contracts/bridge.odin:120`) into 8-field `kind:"chunk"` frames up to `BRIDGE_WS_MAX_REASSEMBLY_BYTES` (`16 MiB`, `src/contracts/bridge.odin:78`), mapping payloads $> 16\text{ MiB}$ to `.Too_Large` $\rightarrow$ `.Validation_Failed` (`bridge_runtime.odin:220, 273-283`) instead of `.Bridge_Offline`.
4. **`REQ-SHELL-41` (`12e64c80`, `dd5783bb`)**:
   - Added `Bridge_WS_Disconnect_Reason` (`src/hub/transport/http/bridge_ws_lifecycle_log.odin`) and `bridge_ws_read_frame` (`bridge_handlers.odin:2405-2436`) to distinguish `Clean_Close` (`opcode == 0x8` at `:2345` or `recv == 0` at `:2427`), `Fatal_Frame` (other non-`0x1` opcodes at `:2345` or `payload_len == 127` at `:2356`), `Read_Deadline` (`.Would_Block` / `.Timeout` at `:2422-2423`), and `Recv_Error` (`:2425`).

---

### Topology & Framing Mismatch Overview (`origin/main` @ `05ffa6cf`)

```
+-------------------------------------------------------------------------------------------------------+
|                                     BROWSER / ELECTRON CLIENT                                         |
+-------------------------------------------------------------------------------------------------------+
         |                                           |                                         |
         | /api/v1/events/stream                     | /api/v1/shells/{id}/stream              | /api/v1/lsp/{id}/stream
         | (Server -> Client only)                   | /api/v1/agent-instances/{id}/stream     | (Bidirectional WS)
         v                                           v                                         v
+---------------------------------+   +---------------------------------------+   +---------------------------------+
| events.publish_raw_to_user      |   | INBOUND: Bridge_WS_Reader             |   | INBOUND: Lsp_WS_Reader          |
| -> ws.write_server_text(...,    |   |   (shell_session_handlers.odin:142,   |   |   (lsp_session_handlers:422)    |
|    allow_64bit = true)          |   |    agent_instance_handlers.odin:187)  |   |   - 64-bit (127), 32 MiB cap,   |
| - Up to 16 MiB (64-bit arm)     |   |   - <= 65,535B cap! (127 -> FATAL!)   |   |     FIN=0 + 0x0 reassembly      |
| - No SO_SNDTIMEO on socket      |   |   - No FIN=0 / 0x0 fragmentation!     |   | OUTBOUND:                       |
|                                 |   | OUTBOUND: ws.write_server_text(...,   |   |   lsp_write_ws_text_frame_      |
|                                 |   |   allow_64bit = true) under write_mu  |   |   counted (:397, 64-bit arm)    |
+---------------------------------+   +---------------------------------------+   +---------------------------------+
                                                        |                                         |
                                                        +--------------------+--------------------+
                                                                             |
                                                    Hub -> Bridge Runtime Command Channel
                                             (`bridge_runtime.write_ws_command` under command_lock)
                                             - `write_ws_text_frame` (:241): HARD CAP 65,535B (16-bit only)
                                             - `hub_command_chunk_frames`: splits >6,000B into 8-field
                                               Base64 JSON `kind:"chunk"` frames (~37% wire inflation)
                                             - Holds global `command_lock` across all chunks (up to 2,797
                                               frames for 16 MiB) with NO `SO_SNDTIMEO`!
                                                                             |
                                                                             v
+-------------------------------------------------------------------------------------------------------+
|                                       BRIDGE <-> HUB WEBSOCKET                                        |
|                                     (`/api/v1/bridges/runtime/ws`)                                    |
|                                                                                                       |
|   Hub Reader: `Bridge_WS_Reader` (`bridge_handlers.odin:2310-2436`)                                   |
|     - Frame cap: 65,535 bytes (`payload_len == 127` -> `.Fatal_Frame` disconnect at `:2355-2357`)     |
|     - Fragmentation broken: ignores `FIN=0` on `0x1`, rejects `0x0` as `.Fatal_Frame` (`:2340-2346`)  |
|     - Reassembler: `bridge_ws_reassemble_chunk` (`:1396-1497`, 30s TTL, swept only at `len >= 64`)    |
|                                                                                                       |
|   Bridge Client: `ws.Connection` (`src/lib/ws/ws.odin` + `src/bridge/hub_runtime_client.odin`)        |
|     - Reader (`ws.poll_text`): 65,535B cap (`127` -> disconnect `:215`), ignores `FIN=0`, drops `0x0`,|
|       and LEAKS `conn.pending_bytes` backing buffer on every consumed frame (`:235-239`)!             |
|     - Writer (`ws.send_text`): 65,535B cap (`:261`), unmasked client frames, no deadline on TLS pipe  |
|     - Outbound chunker (`bridge_hub_chunk_frames`): 14-field Base64 JSON (`45KB` socat / `6KB` s_cli) |
|     - Inbound reassembler (`hub_command_reassemble`): 30s TTL, swept only at `len >= 64` (`:212`)     |
|     - Runtime loop (`hub_runtime_client.odin:308-344`): LEAKS every `text` and `assembled` string!    |
+-------------------------------------------------------------------------------------------------------+
```

---

## Section 1: Wire Framing & Payload Cap Deficiencies (`REQ-WS-AUDIT-1`)

RFC 6455 §5.2 defines three payload length encodings in the second byte of a WebSocket frame header (`payload_len = byte1 & 0x7f`):
1. **`0..=125`**: 7-bit length in `byte1`.
2. **`126`**: 16-bit unsigned big-endian extended length in bytes `2..4` (maximum **65,535 bytes**).
3. **`127`**: 64-bit unsigned big-endian extended length in bytes `2..10` (most significant bit must be `0`).

### 1.1 The 65,535-Byte (16-Bit) Ceiling in Writers on `origin/main` (`05ffa6cf`)

Even after `REQ-SHELL-33` introduced `ws.write_server_text(socket, text, allow_64bit)` (`src/lib/ws/server_frame.odin:119-146`), the 65,535-byte 16-bit ceiling remains strictly enforced on all Hub $\leftrightarrow$ Bridge frame writers:

1. **`http.write_ws_text_frame` (`src/hub/transport/http/bridge_handlers.odin:2455-2465`) $\rightarrow$ `ws.write_server_text(..., allow_64bit = false)` (`src/lib/ws/server_frame.odin:119-125`)**:
   ```odin
   write_ws_text_frame :: proc(client: net.TCP_Socket, text: string) -> bool {
       result := ws.write_server_text(client, text, false)
       if result == .Too_Large {
           fmt.eprintfln(
               "ham-hub WARN ws control frame exceeds the 16-bit length and was NOT sent bytes=%d limit=%d",
               len(text),
               ws.WS_16BIT_MAX_PAYLOAD,
           )
       }
       return result == .Ok
   }
   ```
   With `allow_64bit = false`, `ws.write_server_text` sets `limit := WS_16BIT_MAX_PAYLOAD` (`65535`, `server_frame.odin:59, 121`) and returns `.Too_Large` (`false`) whenever `len(text) > 65535`.
2. **`bridge_runtime.write_ws_text_frame` (`src/hub/service/bridge_runtime/bridge_runtime.odin:241-264`)**:
   ```odin
   write_ws_text_frame :: proc(socket: net.TCP_Socket, text: string) -> bool {
       n := len(text)
       if n > 65535 do return false
       header_len := 2
       if n > 125 do header_len = 4
   ```
3. **`ws.send_text` (`src/lib/ws/ws.odin:259-285`)**:
   ```odin
   send_text :: proc(conn: ^Connection, text: string) -> bool {
       if !conn.connected do return false
       n := len(text)
       if n > 65535 do return false
   ```
   Every direct caller of `ws.send_text`—including `send_validate_project_path_command` (`src/hub/service/bridge_runtime/bridge_runtime.odin:132`), `bridge_hub_runtime_loop` heartbeats (`src/bridge/hub_runtime_client.odin:308, 371`), and `bridge_ws_upgrade_handler` handshake frames—bypasses application chunking and fails immediately if `len(text) > 65535`.

### 1.2 Fatal Connection Teardown on 64-Bit Inbound Frames (`payload_len == 127`) — Including Browser Terminal Streams

When a peer sends a valid RFC 6455 WebSocket frame with payload $> 65,535\text{ bytes}$ (`payload_len == 127`), two of the three readers immediately treat it as a fatal protocol error and sever the connection:

1. **Hub `Bridge_WS_Reader` (`src/hub/transport/http/bridge_handlers.odin:2351-2358`, `bridge_ws_take_frame`)**:
   ```odin
   if payload_len == 126 {
       if len(b) < 4 do return "", false, false
       payload_len = int(b[2]) << 8 | int(b[3])
       header_len = 4
   } else if payload_len == 127 {
       reader.fatal_reason = .Fatal_Frame
       return "", false, true // 64-bit lengths are not used on this control channel
   }
   ```
   - **Critical Browser Terminal Hazard (`shell_session_handlers.odin:142-148` & `agent_instance_handlers.odin:187-192`)**: Although the comment at `bridge_handlers.odin:2357` claims *"64-bit lengths are not used on this control channel"*, `Bridge_WS_Reader` (`read_ws_text_blocking` $\rightarrow$ `bridge_ws_read_frame` $\rightarrow$ `bridge_ws_take_frame`) is **also** used as the server-side reader for browser WebSocket connections on `/api/v1/shells/{session_id}/stream` (`shell_session_handlers.odin:142-148`) and `/api/v1/agent-instances/{id}/stream` (`agent_instance_handlers.odin:187-192`)! While `REQ-SHELL-33` enabled 64-bit frames *from* the Hub *to* the browser (`write_ws_text_frame_browser`), the inbound reader from the browser was never updated. If a user pastes $> 64\text{ KB}$ into a shell or agent terminal, the browser sends a standard RFC 6455 frame with `payload_len == 127`, and `bridge_ws_take_frame` immediately returns `fatal = true` (`reader.fatal_reason = .Fatal_Frame`), **disconnecting the user's terminal session**.
2. **Bridge Client Reader (`src/lib/ws/ws.odin:211-218`, `ws.poll_text`)**:
   ```odin
   if payload_len == 126 {
       if pos + 4 > len(conn.pending_bytes) do break
       payload_len = int(conn.pending_bytes[pos + 2]) << 8 | int(conn.pending_bytes[pos + 3])
       header_len = 4
   } else if payload_len == 127 {
       conn.connected = false
       return "", false
   }
   ```
3. **LSP Stream Reader (`src/hub/transport/http/lsp_session_handlers.odin:534-556`, `lsp_ws_take_one_frame`)**:
   Properly decodes `case 127:` into a 64-bit `u64`, checks `length > u64(max(int) / 2)`, and enforces `LSP_MAX_MESSAGE_BYTES :: 32 * 1024 * 1024` (`:446, 554`).

### 1.3 Broken FIN Bit (`0x80`) & Continuation Frame (`opcode == 0x0`) Handling

Per RFC 6455 §5.4, any WebSocket sender, browser engine (e.g., Chromium/Electron, as measured in `lsp_session_handlers.odin:463-478`), or intermediate reverse proxy may fragment a logical message into an initial frame (`FIN=0, opcode=0x1`) followed by one or more continuation frames (`FIN=0/1, opcode=0x0`).

- **`Bridge_WS_Reader` (`src/hub/transport/http/bridge_handlers.odin:2340-2347`)**:
  ```odin
  if b[0] & 0x0f != 0x1 {
      reader.fatal_reason = .Clean_Close if b[0] & 0x0f == 0x8 else .Fatal_Frame
      return "", false, true // only text frames are expected
  }
  ```
  - **Bug 1 (Truncated delivery):** `bridge_ws_take_frame` never inspects the `FIN` bit (`b[0] & 0x80`). When a peer or proxy sends an initial fragment (`0x01`: `FIN=0, opcode=0x1`), `bridge_ws_take_frame` immediately returns the partial first fragment as a complete text message (`ok = true, fatal = false`), corrupting the JSON payload handed to the caller.
  - **Bug 2 (Fatal disconnect on continuation):** When the subsequent continuation frame (`0x80`: `FIN=1, opcode=0x0`) arrives, `b[0] & 0x0f != 0x1` evaluates to `true`, sets `reader.fatal_reason = .Fatal_Frame`, and returns `fatal = true`, tearing down the WebSocket connection.
- **`ws.poll_text` (`src/lib/ws/ws.odin:208, 221-233`)**:
  ```odin
  opcode := conn.pending_bytes[pos] & 0x0f
  ...
  if opcode == 0x8 {
      conn.connected = false
      return "", false
  }
  if opcode == 0x1 {
      frame_text := strings.clone(string(conn.pending_bytes[pos + header_len:frame_end]))
      if first_text == "" {
          first_text = frame_text
      } else {
          append(&conn.pending_texts, frame_text)
      }
  }
  pos = frame_end
  ```
  - **Bug 1 (Truncated delivery):** Like `Bridge_WS_Reader`, `ws.poll_text` ignores `FIN=0` on `opcode == 0x1` and returns the truncated first fragment as a complete message.
  - **Bug 2 (Silent data loss):** For all subsequent `opcode == 0x0` continuation frames, `opcode == 0x1` is `false`, so `pos = frame_end` advances past the continuation frame and **silently discards its payload**!

### 1.4 Unhandled Control Frames (`Ping 0x9`, `Pong 0xA`) & Missing RFC 6455 Client Masking

- **Ping (`0x9`) / Pong (`0xA`) Control Frames**:
  - In `Bridge_WS_Reader` (`bridge_handlers.odin:2340-2346`), any opcode other than `0x1` and `0x8`—including standard RFC 6455 Ping (`0x9`) or Pong (`0xA`) frames emitted by reverse proxies or load balancers—sets `reader.fatal_reason = .Fatal_Frame` and kills the connection.
  - In `Lsp_WS_Reader` (`lsp_session_handlers.odin:516-529`), `opcode` values other than `0x1` and `0x0` return `fatal = true`.
  - In `ws.poll_text` (`ws.odin:221-233`), Ping (`0x9`) is silently ignored without replying with a Pong (`0xA`) frame.
- **Missing Client-to-Server Frame Masking in `ws.send_text` (`src/lib/ws/ws.odin:274-282`)**:
  - Per RFC 6455 §5.1, a WebSocket client MUST mask all frames sent to the server (`MASK` bit `0x80` set in byte 1 + 4-byte random masking key), and a compliant server MUST close the connection upon receiving an unmasked client frame (`1002 Protocol Error`).
  - `ws.send_text` acts as a WebSocket client (`connect_with_bearer` at `:42`), yet writes `frame[0] = 0x81` and `frame[1] = byte(n)` / `126` with the mask bit `0x80` cleared (`0`). This works only because the Hub's custom `Bridge_WS_Reader` (`bridge_handlers.odin:2348`) accepts both masked and unmasked frames (`masked := (b[1] & 0x80) != 0`). Any strict RFC 6455 ingress proxy placed in front of the Hub will reject the Bridge's frames.

### 1.5 Partial TCP Sends & Mid-Frame Stream Desynchronization

- **`bridge_runtime.write_ws_text_frame` (`src/hub/service/bridge_runtime/bridge_runtime.odin:256-263`)**:
  ```odin
  sent_bytes := 0
  for sent_bytes < len(frame) {
      n_written, err := net.send_tcp(socket, frame[sent_bytes:])
      if err != nil do return false
      if n_written == 0 do break
      sent_bytes += n_written
  }
  return sent_bytes == len(frame)
  ```
  As documented in `server_frame.odin:18-25` and `lsp_session_handlers.odin:387-396`, Odin's `core/net` `_send_tcp` returns on the first `errno` (such as `EAGAIN` / `.Would_Block`) alongside a **non-zero** `n_written` if part of the buffer was already copied into the kernel socket buffer before the error occurred. In `bridge_runtime.write_ws_text_frame`, if `n_written > 0` and `err != nil`, it immediately returns `false` (`Command_Write_Result.Send_Failed`) **without closing `socket` or unregistering the bridge**. The next command sent to that bridge writes its `0x81` header into the middle of the unfinished frame's payload, permanently desynchronizing the WebSocket stream.
- **`ws.send_all_tcp` (`src/lib/ws/ws.odin:319-336`)**:
  `ws.send_all_tcp` retries `.Would_Block` for up to `WRITE_DEADLINE :: 5 * time.Second` (`:290, 321-329`). However, if the 5-second deadline expires after `sent > 0` bytes of `frame` were already transmitted, `send_all_tcp` increments `_send_timeouts` and returns `false` (`:323-325`) while leaving `conn.connected = true` and the socket open—causing the next `ws.send_text` call (such as the 45-second heartbeat) to concatenate a new `0x81` frame header onto the half-written frame.

---

## Section 2: Code Duplication & Reader/Writer Divergence (`REQ-WS-AUDIT-2`)

### 2.1 Comprehensive Comparison Matrix of All Writers (4) and Readers (3) on `origin/main` (`05ffa6cf`)

On `origin/main` (`05ffa6cf`), `REQ-SHELL-33` consolidated `bridge_handlers.odin`, `event_bus.odin`, and `shell_session_service.odin` onto `ws.write_server_text` (`src/lib/ws/server_frame.odin:119`), and `REQ-SHELL-52` (`e40a3f54`) deleted the dead `write_ws_text` from `src/bridge/main.odin`. However, **four distinct `0x81` frame writers** and **three distinct frame readers** remain in active production use:

#### WebSocket Frame Writers (`origin/main` @ `05ffa6cf`)

| # | Symbol & Location (`05ffa6cf`) | Callers / Subsystem | Max Payload Size | 64-Bit Length (`127`) | Client Masking (`0x80`) | Partial TCP Send / Desync Handling | Heap Buffer (`frame`) Cleanup | Concurrency / Locking |
| :- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **W1** | `ws.write_server_text`<br>`src/lib/ws/server_frame.odin:119-146` | - `http.write_ws_text_frame` (`bridge_handlers.odin:2455`, `allow_64bit = false`)<br>- `http.write_ws_text_frame_browser` (`:2472`, `allow_64bit = true`)<br>- `events.publish_raw_to_user` (`event_bus.odin:82`, `allow_64bit = true`)<br>- `shell_session._write_ws_text` (`shell_session_service.odin:1822`, `allow_64bit = true`) | **`65,535 B`** when `allow_64bit = false` (`WS_16BIT_MAX_PAYLOAD`, `:59`);<br>**`16 MiB`** when `allow_64bit = true` (`WS_MAX_SERVER_PAYLOAD`, `:67`) | Parameterized by `allow_64bit` (`:91-111`) | N/A (Server) | Loops `for sent < len(frame)` (`:134-144`); returns `.Peer_Gone` if `sent == 0` or `.Desynchronised` if `sent > 0` on error (no `.Would_Block` backoff). | Freed via `defer delete(frame)` (`:129`) | - `write_ws_text_frame_locked` locks `command_lock` (`bridge_handlers.odin:2483`).<br>- `shell_session` locks per-session `viewer_write_mu` (`shell_session_service.odin:342-367`).<br>- `event_bus` writes unlocked (`event_bus.odin:80-96`). |
| **W2** | `ws.send_text` + `send_all_tcp` / `send_all_file`<br>`src/lib/ws/ws.odin:259-350` | Bridge $\rightarrow$ Hub client (`bridge_hub_send`, heartbeats) & Hub path-validation client (`bridge_runtime.odin:132`) | **`65,535 B`** (`:262`) | **No** | **No** (violates RFC 6455 §5.1) | TCP (`send_all_tcp`, `:319-336`): retries `.Would_Block` up to `WRITE_DEADLINE = 5s`, but leaves socket open on mid-frame timeout.<br>TLS pipe (`send_all_file`, `:342-350`): blocking `os.write` loop with **NO deadline**. | Freed via `defer delete(frame)` (`:273`, added in `REQ-SHELL-52A` `4e4ff21e`) | Per-connection `conn.send_mu` (`ws.odin:35, 263-264`) + sequence-level `_bridge_hub_send_mu` (`src/bridge/main.odin:637-641`). |
| **W3** | `bridge_runtime.write_ws_text_frame`<br>`src/hub/service/bridge_runtime/bridge_runtime.odin:241-264` | Hub $\rightarrow$ Bridge runtime commands (called by `write_ws_command` at `:210, 231`) | **`65,535 B`** (`:243`) | **No** | N/A (Server) | Loops `for sent_bytes < len(frame)` (`:257-262`), but aborts immediately on `err != nil` (no `.Would_Block` retry; leaves socket open & stream desynced if partial bytes went out). | Freed via `defer delete(frame)` (`:252`, added in `REQ-SHELL-36` `f6bf8ce0`) | Called under global `bridge_runtime_registry_command_lock` (`:21-23, 37-39`). |
| **W4** | `http.lsp_write_ws_text_frame_counted` / `lsp_write_ws_text_frame`<br>`src/hub/transport/http/lsp_session_handlers.odin:336-416` | Hub $\rightarrow$ Browser `/api/v1/lsp/{id}/stream` | **Unlimited** (64-bit `u64`, `:347-355`, no `WS_MAX_SERVER_PAYLOAD` check) | **Yes** (`out[1] = 127`) | N/A (Server) | Single `net.send_tcp(client, frame)` (`:404`, no short-write loop), checks `err == nil && written == len(frame)` (`:410`) and closes socket on partial write. | Freed via `defer delete(frame)` (`:401`) | Serialized under `lsp_sessions` registry mutex with `LSP_SEND_TIMEOUT = 5s` (`:376`). |

#### WebSocket Frame Readers (`origin/main` @ `05ffa6cf`)

| # | Symbol & Location (`05ffa6cf`) | Callers / Subsystem | 64-Bit Length (`127`) | Fragmented Frames (`FIN=0` + `0x0`) | Control Frames (`0x8`, `0x9`, `0xA`) | Max Message / Buffer Cap | Buffer Management & Allocation Discipline |
| :- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **R1** | `ws.poll_text`<br>`src/lib/ws/ws.odin:167-243` | Bridge client (`hub_runtime_client.odin:310`) & Hub path-validation client (`bridge_runtime.odin:135`) | **No:** sets `conn.connected = false` and returns `"", false` (`:215-218`). | **Broken:** ignores `FIN` bit (`:208`), returns truncated `0x1` frame (`:225-232`), silently discards `0x0` frames (`:233`). | `0x8` (Close) disconnects (`:221-224`). `0x9`/`0xA` (Ping/Pong) silently ignored without Pong reply. | **`65,535 B`** per frame. | **ACTIVE LEAK:** overwrites `conn.pending_bytes = remaining` without `delete(conn.pending_bytes)` on every call that consumes bytes (`:235-239`)! |
| **R2** | `http.Bridge_WS_Reader`<br>(`bridge_ws_take_frame` / `bridge_ws_read_frame` / `read_ws_text_blocking`)<br>`src/hub/transport/http/bridge_handlers.odin:2310-2436` | - Hub Bridge runtime WS (`:1186, 1552`)<br>- Browser shell stream WS (`shell_session_handlers.odin:142-148`)<br>- Browser agent stream WS (`agent_instance_handlers.odin:187-192`) | **No:** sets `reader.fatal_reason = .Fatal_Frame` and returns `fatal = true` (`:2355-2357`), killing connection. | **Broken:** ignores `FIN` bit on `0x1`, rejects `opcode == 0x0` with `reader.fatal_reason = .Fatal_Frame` and `fatal = true` (`:2340-2347`). | `0x8` sets `.Clean_Close` and returns `fatal = true` (`:2345`). `0x9`/`0xA` set `.Fatal_Frame` and return `fatal = true`. | **`65,535 B`** per WS frame. (`bridge_ws_runtime_loop` reassembles `kind:"chunk"` up to 16 MiB at `:1411`). | Shifts remaining bytes in-place via `copy(reader.pending[:], reader.pending[frame_end:])` + `resize(&reader.pending, remaining)` (`:2372-2374`). |
| **R3** | `http.Lsp_WS_Reader`<br>(`lsp_ws_take_frame` / `lsp_ws_take_one_frame` / `lsp_read_ws_text_blocking`)<br>`src/hub/transport/http/lsp_session_handlers.odin:422-614` | Hub Browser LSP stream WS (`:893, 975`) | **Yes:** decodes 8-byte big-endian `u64` (`:539-550`) with `length > u64(max(int) / 2)` guard (`:547`). | **Yes:** tracks `fin := (b[0] & 0x80) != 0` (`:513`), `reader.assembling`, and `reader.message` across `0x1` + `0x0` frames (`:516-529, 579-593`). | `0x8`, `0x9`, `0xA` return `fatal = true` (`:524-528`, rejects Ping/Pong). | **`32 MiB`** (`LSP_MAX_MESSAGE_BYTES` at `:446`, enforced at `:554`). | In-place shift on `reader.pending` (`:573-575`) + reusable `reader.message` buffer freed in `lsp_ws_reader_destroy` (`:452-456`). |

---

## Section 3: Subsystem Impact Analysis (`REQ-WS-AUDIT-3`)

### 3.1 Duplicated, Asymmetric Application-Level Chunking (`Bridge_Chunk_Reassembly` vs. `Hub_Command_Reassembly`) & Admission-Only TTL Sweeps

Because both `ws.poll_text` (`src/lib/ws/ws.odin:215-218`) and `bridge_ws_take_frame` (`src/hub/transport/http/bridge_handlers.odin:2355-2357`) treat RFC 6455 64-bit extended length frames (`payload_len == 127`) as fatal errors—and because neither implements RFC 6455 `FIN=0` / `0x0` continuation framing—`origin/main` (`05ffa6cf`) now maintains **two separate, copy-pasted application-layer JSON+Base64 chunking/reassembly engines**:

| Property | Direction 1: Bridge $\rightarrow$ Hub | Direction 2: Hub $\rightarrow$ Bridge (`REQ-SHELL-36`) | Divergence / Hazard |
| :--- | :--- | :--- | :--- |
| **Chunk Splitter** | `bridge_hub_chunk_frames` / `bridge_ws_chunk_json`<br>(`src/bridge/main.odin:574-600, 656-671`) | `hub_command_chunk_frames` / `hub_command_chunk_json`<br>(`src/hub/service/bridge_runtime/hub_command_chunk.odin:78-126`) | Separate implementations; `main.odin` uses `strconv.write_int` + `json_write_string`, while `hub_command_chunk.odin` hand-rolls string builder writes. |
| **Chunk Envelope Schema** | **14 JSON fields** (`version`, `kind`, `frame_id`, `stream_id`, `src_daemon_id`, `dest_daemon_id`, `original_kind`, `idempotency_key`, `chunk_id`, `chunk_index`, `chunk_count`, `total_bytes`, `payload_fragment`, `end_stream`) | **8 JSON fields** (`version`, `kind`, `chunk_id`, `chunk_index`, `chunk_count`, `total_bytes`, `payload_fragment`, `end_stream`) | Asymmetric wire schemas (`hub_command_chunk.odin:25-29`). |
| **Raw Slice Size per Chunk** | **`45,000 B`** (`socat` default, `BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES_SOCAT`) or **`6,000 B`** (`s_client`, `BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES`) (`src/contracts/bridge.odin:86, 99`; `12,000 B` in older configs) | **`6,000 B`** hardcoded (`BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES`, `src/contracts/bridge.odin:120`) | Hub $\rightarrow$ Bridge always uses `6,000 B` chunks even when the Bridge uses `socat`: a 16 MiB command requires **2,797 sequential WS frames** held under the global Hub `command_lock`! |
| **Reassembler State & Proc** | `Bridge_Chunk_Reassembly` & `bridge_ws_reassemble_chunk`<br>(`src/hub/transport/http/bridge_handlers.odin:1332-1497`) | `Hub_Command_Reassembly` & `hub_command_reassemble`<br>(`src/bridge/hub_command_reassembly.odin:52-272`) | ~170 lines of duplicated state-machine code with subtle behavioral drift. |
| **Configured TTL Constant** | `BRIDGE_WS_REASSEMBLY_TTL :: 30 * time.Second` (`bridge_handlers.odin:1356`; was `60 * time.Second` at `:1405` in pre-rebase drafts) | `HUB_COMMAND_REASSEMBLY_TTL :: 30 * time.Second` (`hub_command_reassembly.odin:73`, with comment at `:63` claiming it *"Matches the hub's BRIDGE_WS_REASSEMBLY_TTL"*) | Both measure total age from `started_at_ns` (first chunk arrival) rather than idle time since the last received chunk (`bridge_handlers.odin:1345-1355`, `hub_command_reassembly.odin:62-72`). |
| **TTL Sweep Trigger** | **Admission-gate only:** `if len(reassemblies) >= contracts.BRIDGE_WS_MAX_REASSEMBLIES` (`64`) at `bridge_handlers.odin:1444-1445` (calling `bridge_chunk_reassembly_sweep` at `:1362`) | **Admission-gate only:** `if len(buf) >= contracts.BRIDGE_WS_MAX_REASSEMBLIES` (`64`) at `hub_command_reassembly.odin:212-213` (calling `hub_command_reassembly_sweep` at `:100`) | **Up to 63 abandoned partial streams (up to $63 \times 16\text{ MiB} \approx 1\text{ GiB}$ theoretical ceiling) are NEVER swept by TTL** unless a 64th concurrent stream arrives! |
| **Over-Total First Fragment Cleanup** | **Buggy (`bridge_handlers.odin:1476-1478`):** If chunk 0's decoded length exceeds `total_bytes`, returns `"", false, false` **without removing** the newly appended `Bridge_Chunk_Reassembly` entry! | **Fixed (`hub_command_reassembly.odin:201, 245-251`):** Tracks `created := idx < 0` and calls `if created do hub_command_reassembly_free(buf, idx)`. | Copy-paste divergence: a bug caught and fixed in `hub_command_reassembly.odin` (`:196-201`) remains unfixed in `bridge_handlers.odin` (`:1476-1478`)! |
| **Chunk Frame Discriminator** | `type := json_string(text, "type")` (`type == ""` and `kind == "chunk"`, `bridge_handlers.odin:1575-1585`) | `hub_command_frame_is_chunk` (`extract_json_string(text, "kind", "") == "chunk"` and `extract_json_string(text, "type", "") == ""`, `hub_command_reassembly.odin:146-153`) | Both rely on substring searches (`strings.index`) across the entire JSON text rather than structural top-level parsing. |

### 3.2 Subsystem 1: Bridge Filesystem Read/Write Overhead & Residual Failure Modes

1. **Double Base64 Encoding & Wire Amplification (`33%`–`78%`)**:
   - **Bridge $\rightarrow$ Hub FS Reads (`src/bridge/fs_management.odin:227-260, 661-700`)**:
     - Under `openssl s_client`, file reads are paginated at `8,000` bytes (`BRIDGE_FS_READ_PAGE_BYTES`), requiring **132 sequential round-trip RPCs** for a 1 MiB file.
     - Under `socat` (`131,072` bytes / 128 KiB per page, `BRIDGE_FS_READ_PAGE_BYTES_SOCAT`), `bridge_hub_chunk_frames` Base64-encodes the entire JSON response ($1.33\times$). For binary image previews (`is_image_preview_extension`), the image bytes are Base64-encoded inside the JSON response and then **Base64-encoded a second time** by `bridge_hub_chunk_frames` ($1.33 \times 1.33 = \mathbf{1.78\times}$ wire bloat).
   - **Hub $\rightarrow$ Bridge FS Writes (`src/hub/service/bridge_runtime/bridge_runtime.odin:204-234` & `hub_command_chunk.odin:78-126`)**:
     - On `origin/main` (`05ffa6cf`), `fs_write_file`, `fs_batch_write`, and `vcs_save_file` commands $> 6,000\text{ bytes}$ are chunked by `write_ws_command` into `6,000`-byte slices, Base64-encoded (`4/3` expansion), and wrapped in 8-field JSON chunk envelopes. As proven by Empirical Test **1d** (`audit_claim_hub_to_bridge_large_json_command_dropped`), a `70,000`-byte JSON command is amplified to **12 WebSocket frames totaling $> 94,000\text{ wire bytes}$ (~34.8% overhead)**.
     - Worse, on the receiving Bridge (`src/bridge/hub_runtime_client.odin:310-344`), **every single chunk envelope string (`text`) and the reassembled command string (`assembled`) are permanently leaked on the Bridge heap** (see Section 4.1). Writing a 10 MiB file leaks ~13.5 MiB of chunk strings + 10 MiB of `assembled` command text + 1,748 `conn.pending_bytes` buffers (~23.5+ MiB leaked in a single file save!).
     - Note: In the pre-`REQ-SHELL-36` snapshot (`/usr/local/google/home/tanmayvijay/heimdall-cloudtop` @ `2bb9b48f`), `send_runtime_command` called `write_ws_text_frame` directly without chunking, causing any `fs_write_file` / `vcs_save_file` $> 65,535\text{ bytes}$ to fail outright with `.Bridge_Offline` (`"bridge websocket command send failed"`).

### 3.3 Subsystem 2: Shell Session & Agent Terminal PTY Hazards (`REQ-WS-AUDIT-3`)

1. **Browser $\rightarrow$ Hub Terminal Paste Disconnect (`> 65,535 B` or Fragmented Frames)**:
   - Both `/api/v1/shells/{session_id}/stream` (`src/hub/transport/http/shell_session_handlers.odin:142-148`) and `/api/v1/agent-instances/{id}/stream` (`src/hub/transport/http/agent_instance_handlers.odin:187-192`) read inbound browser frames using `Bridge_WS_Reader` (`read_ws_text_blocking(&reader, 120 * time.Second)`).
   - If a user pastes a large buffer into the terminal causing the browser to emit either a 64-bit extended length frame (`payload_len == 127`, $> 65,535\text{ B}$) or a multi-frame fragmented message (`FIN=0` + `opcode == 0x0`), `bridge_ws_take_frame` (`bridge_handlers.odin:2340, 2355`) immediately returns `fatal = true` (`reader.fatal_reason = .Fatal_Frame`), terminating the handler loop and **disconnecting the terminal stream**.
2. **Ignored `send_shell_input` Failure Return (`src/hub/transport/http/shell_session_handlers.odin:160, 167`)**:
   - `shell_session_stream_handler` calls `bridge_service.send_shell_input(...)` without inspecting the returned `(bool, domain.Domain_Error)`.

### 3.4 Subsystem 3: LSP Relay Asymmetry & Unchecked Drops (`REQ-WS-AUDIT-3`)

1. **Browser $\rightarrow$ Hub (`32 MiB` Cap) vs. Hub $\rightarrow$ Bridge (`16 MiB` Cap) Mismatch**:
   - On `/api/v1/lsp/{session_id}/stream`, `Lsp_WS_Reader` (`src/hub/transport/http/lsp_session_handlers.odin:446, 554`) accepts browser JSON-RPC messages up to **`LSP_MAX_MESSAGE_BYTES :: 32 * 1024 * 1024` (32 MiB)**.
   - However, when `lsp_session_stream_handler` forwards the message to the Bridge via `_ = bridge_service.send_lsp_message(...)` (`lsp_session_handlers.odin:913, 984`), `write_ws_command` (`bridge_runtime.odin:220` $\rightarrow$ `hub_command_is_chunkable` in `hub_command_chunk.odin:135-138`) enforces **`BRIDGE_WS_MAX_REASSEMBLY_BYTES :: 16 * 1024 * 1024` (16 MiB)** on the JSON-escaped `lsp_send` command envelope.
   - Because `_ = bridge_service.send_lsp_message(...)` at `lsp_session_handlers.odin:913` and `:984` **discards the return value**, any message rejected by `write_ws_command` (or failing mid-send) is **silently dropped** without logging an error or notifying the browser client.
   - (In the pre-`REQ-SHELL-36` snapshot `2bb9b48f`, `send_lsp_message` called `bridge_runtime.write_ws_text_frame` directly, silently dropping every `textDocument/didOpen` or `textDocument/didChange` $> 65,535\text{ bytes}$!)

---

## Section 4: Robustness, Memory Leaks & Process Management (`REQ-WS-AUDIT-4`)

### 4.1 Active Heap Memory Leaks on `origin/main` (`05ffa6cf` / `v0.3.3`)

While `REQ-SHELL-52A` (`4e4ff21e`) added `defer delete(frame)` to `ws.send_text` (`src/lib/ws/ws.odin:273`) and `REQ-SHELL-36` (`f6bf8ce0`) added `defer delete(frame)` to `bridge_runtime.write_ws_text_frame` (`src/hub/service/bridge_runtime/bridge_runtime.odin:252`), **three major heap leak sites remain active on `origin/main` (`05ffa6cf`)**:

#### 1. `ws.poll_text` Leaks `conn.pending_bytes` Dynamic Array on Every Consumed Frame (`src/lib/ws/ws.odin:235-239`)
```odin
if pos > 0 {
    remaining := make([dynamic]byte)
    if pos < len(conn.pending_bytes) do append(&remaining, ..conn.pending_bytes[pos:])
    conn.pending_bytes = remaining
}
```
- **Root Cause**: Whenever `ws.poll_text` parses and consumes at least one frame (`pos > 0`), line 236 allocates a brand-new dynamic array `remaining := make([dynamic]byte)` and line 238 overwrites `conn.pending_bytes = remaining` **without calling `delete(conn.pending_bytes)`** on the prior dynamic array!
- **Additional `ws.odin` Leaks**:
  - `connect_tls_with_bearer` (`src/lib/ws/ws.odin:122`) allocates `data := make([dynamic]byte)` for the HTTP 101 handshake response and never calls `delete(data)` on any return path (`:143, 150`).
  - `ws.close` (`src/lib/ws/ws.odin:153-165`) closes the socket/pipes but **never calls `delete(conn.pending_bytes)` or `delete(conn.pending_texts)`** (nor frees queued strings inside `conn.pending_texts`).
- **Empirical Proof**: Proven deterministically under `mem.Tracking_Allocator` by Test **2d** (`audit_claim_ws_poll_text_leaks_pending_bytes_on_consume` in `src/lib/ws/ws_audit_validation_test.odin:175-231`).

#### 2. Bridge Runtime Loop Leaks Every Inbound `text` Frame, Every Reassembled `assembled` Command, and Heartbeat Strings (`src/bridge/hub_runtime_client.odin:306-344, 371`)
```odin
_ = ws.send_text(conn, bridge_hub_heartbeat_json())
for conn.connected {
    if text, got := ws.poll_text(conn); got {
        if hub_command_frame_is_chunk(text) {
            assembled, complete, ok := hub_command_reassemble(&reassemblies, text)
            if ok && complete do bridge_hub_handle_command(conn, assembled)
        } else {
            bridge_hub_handle_command(conn, text)
        }
        // >>> WHY NEITHER `text` NOR `assembled` IS FREED ON THIS LINE. <<<
        // ws.poll_text returns a strings.clone, so `text` has ALWAYS been leaked
        // here, once per inbound frame; `assembled` is a string this loop allocates
        // and is leaked the same way. Both are real leaks and both are filed
        // (REQ-SHELL-58 ...
    }
```
- **Root Cause**:
  1. At lines `308` and `371` (and `243`), `_ = ws.send_text(conn, bridge_hub_heartbeat_json())` passes the heap-allocated string returned by `bridge_hub_heartbeat_json()` directly to `ws.send_text` (which only borrows `text`) and never frees it.
  2. At lines `310-344`, as explicitly documented in the comment at `:322-344` (`REQ-SHELL-58`), **neither `text` (cloned on the heap by `ws.poll_text` at `ws.odin:226`) nor `assembled` (allocated on the heap by `hub_command_reassemble` at `hub_command_reassembly.odin:265-267`) is ever freed**!
  3. **Severe Amplification on Chunked Commands**: Even when `hub_command_frame_is_chunk(text)` is `true` (`:311`)—where `text` is a `"kind":"chunk"` envelope that is consumed *exclusively* by `hub_command_reassemble(&reassemblies, text)` and is **never** passed to `bridge_hub_handle_command`—`text` is still not freed! Consequently, a single 16 MiB chunked command from the Hub (`2,797` chunks at `6,000` bytes/chunk) leaks:
     - All **2,797 `text` chunk envelope strings** (~22.9 MiB of Base64 JSON)
     - The **16 MiB `assembled` command string**
     - **2,797 `conn.pending_bytes` backing buffers** in `ws.poll_text` (`ws.odin:235-239`)
     - Totaling **~38.9+ MiB of permanent heap leaks in the Bridge daemon for a single 16 MiB command**!

#### 3. `send_validate_project_path_command` Leaks `ws.poll_text` Strings & `json_string` Aliases Uncloned Subslices (`src/hub/service/bridge_runtime/bridge_runtime.odin:135-139, 149-168, 285-294`)
```odin
for time.to_unix_nanoseconds(time.now()) < deadline {
    if text, ok := ws.poll_text(&conn); ok {
        if json_string(text, "type") == "project_path_validation_result" && json_string(text, "command_id") == command.command_id {
            return parse_validation_result(command, text), true, domain.Domain_Error{}
        }
    }
    time.sleep(25 * time.Millisecond)
}
```
- **Root Cause (Leak + Aliasing Hazard)**:
  1. `ws.poll_text(&conn)` at line 135 returns a heap-allocated `text` string (`ws.odin:226`) that is **never freed**—neither on non-matching frames nor when the matching `project_path_validation_result` frame is parsed and returned at line 137 (plus `ws.close(&conn)` at `:126` leaks `conn.pending_bytes` and `conn.pending_texts`).
  2. Worse, `bridge_runtime.json_string(body, key)` (`bridge_runtime.odin:285-294`) returns an **uncloned subslice** (`rest[1:i]`) pointing directly into `text`:
     ```odin
     json_string :: proc(body, key: string) -> string {
         needle := strings.concatenate({"\"", key, "\""})
         defer delete(needle)
         idx := strings.index(body, needle); if idx < 0 do return ""
         rest := body[idx + len(needle):]
         colon := strings.index_byte(rest, ':'); if colon < 0 do return ""
         rest = strings.trim_space(rest[colon + 1:]); if len(rest) == 0 || rest[0] != '"' do return ""
         for i := 1; i < len(rest); i += 1 { if rest[i] == '"' do return rest[1:i] }
         return ""
     }
     ```
     `parse_validation_result` (`:149-168`) passes `message := json_string(text, "validation_error")` into `validation_result`, which stores `validation_error = message` (`:164, 167`) directly inside the returned `Project_Path_Validation_Result` struct without cloning! If `send_validate_project_path_command` freed `text` without first cloning `validation_error`, `result.validation_error` would immediately become a **dangling pointer (use-after-free)**.
  3. **Escaped-Quote Truncation Bug in `bridge_runtime.json_string` (`:292`)**: Because `for i := 1; i < len(rest); i += 1 { if rest[i] == '"' do return rest[1:i] }` does not check for backslash escapes (`\"`), any JSON string value containing an escaped quote (e.g., `"invalid path \"/tmp/ws\" here"`) is silently truncated at the first `\"` (yielding `"invalid path \"`).
  4. **Empirical Proof**: Both the escaped-quote truncation and the uncloned subslice aliasing (as well as the `REQ-SHELL-36` `write_ws_text_frame` buffer free on `05ffa6cf`) are proven by Test **1f** (`audit_claim_bridge_runtime_write_ws_text_frame_leaks_frame_buffer` in `src/hub/transport/http/bridge_ws_audit_validation_test.odin:317-360`).

#### 4. Additional Inline Payload Leaks in `bridge_handlers.odin` (`:1197-1204, 1572`)
- In `src/hub/transport/http/bridge_handlers.odin:1197, 1198, 1200, 1204` (`bridge_ws_upgrade_handler`) and `:1572` (`bridge_ws_process_frame`), heap-allocated strings returned by `bridge_ws_error_payload(...)`, `bridge_ready_payload(...)`, and `bridge_connection_replaced_payload()` are passed directly as temporary arguments to `write_ws_text_frame` / `write_ws_text_frame_locked` and never `delete`d.

---

### 4.2 Socket Deadlines, Global Lock Contention & TLS Pipe Hazards

1. **Missing `SO_SNDTIMEO` Under Global `bridge_runtime_registry_command_lock` Across Multi-Chunk Sequences (`src/hub/service/bridge_runtime/bridge_runtime.odin:21-23, 37-39, 204-234`)**:
   - The Hub sets `.Receive_Timeout` (`SO_RCVTIMEO = 120s`) on the Bridge WebSocket (`bridge_handlers.odin:2417`), but **never sets `.Send_Timeout` (`SO_SNDTIMEO`)** on that socket.
   - All Hub $\rightarrow$ Bridge command writes acquire the single global `bridge_runtime_registry_command_lock(registry)` mutex before calling `write_ws_command(socket, command.body_json)`.
   - With `REQ-SHELL-36`, `write_ws_command` holds that global mutex across **all chunks of a large command** (up to `2,797` sequential `net.send_tcp` calls for a 16 MiB command). If a single Bridge connection stalls or its TCP send window fills, `net.send_tcp` blocks in the kernel while holding the global `command_lock`, freezing command dispatch and `heartbeat_ack` writes (`write_ws_text_frame_locked` at `bridge_handlers.odin:2481-2486`) for **every bridge connected to the Hub**.
2. **TLS `send_all_file` Has No Write Deadline & `ws.send_timeouts()` Is Always Zero on `wss://` (`src/lib/ws/ws.odin:283, 290-312, 342-350`)**:
   - In `src/lib/ws/ws.odin:290`, `WRITE_DEADLINE :: 5 * time.Second` bounds only `send_all_tcp` (`conn.secure == false`, plain `ws://`).
   - For all `wss://` connections (`conn.secure == true`, which spawns `socat` or `openssl s_client` in `connect_tls_with_bearer` at `:90-151`), `ws.send_text` calls `send_all_file(conn.stdin_w, frame)` (`:283, 342-350`):
     ```odin
     send_all_file :: proc(file: ^os.File, bytes: []byte) -> bool {
         sent := 0
         for sent < len(bytes) {
             n, err := os.write(file, bytes[sent:])
             if err != nil || n <= 0 do return false
             sent += n
         }
         return true
     }
     ```
   - Because `conn.stdin_w` is a blocking OS pipe (64 KiB kernel buffer on Linux) with no timeout or poll check, if `socat`/`openssl` stops draining `stdin_r` during a network stall, `send_all_file` blocks indefinitely while holding `conn.send_mu` (`:263`) and `_bridge_hub_send_mu` (`main.odin:640`)—starving Bridge heartbeats. Furthermore, as documented at `ws.odin:295-308`, `ws.send_timeouts()` is structurally **always `0`** on every TLS deployment.
3. **Orphaned TLS Child Processes on Close (`src/lib/ws/ws.odin:153-165`)**:
   - `ws.close` sends `SIGTERM` (`os.process_terminate(conn.process)`) and waits `250 * time.Millisecond` (`os.process_wait`), but never escalates to `os.process_kill` (`SIGKILL`) or calls `os.process_close` if the child does not exit within 250ms.
4. **Per-Recv Timeout vs. Frame-Total Deadline (Slowloris) (`bridge_handlers.odin:2417-2435` & `lsp_session_handlers.odin:602-613`)**:
   - `.Receive_Timeout` bounds only a single `net.recv_tcp` syscall inside the `for` loop rather than total elapsed time to assemble a complete frame.

---

## Section 5: Test Coverage Analysis & Gap Matrix (`REQ-WS-AUDIT-5`)

We audited all WebSocket-related test suites in `/usr/local/google/home/tanmayvijay/heimdall-agent-manager` (`origin/main` @ `05ffa6cf`) alongside our 10 controlled empirical validation tests (`REQ-WS-AUDIT-7`, documented in Section 7):

### 5.1 Test Inventory on `origin/main` (`05ffa6cf`) vs. Untested Failure Modes

| Test File & Suite (`05ffa6cf`) | What Is Tested on `origin/main` (`05ffa6cf`) | Residual Untested Gaps (Closed or Exposed by `REQ-WS-AUDIT-7`) |
| :--- | :--- | :--- |
| **`src/lib/ws/server_frame_test.odin`** (`7` tests) & **`send_text_frame_leak_test.odin`** (`3` tests) | - `server_frame_header` 7-bit, 16-bit (`65535`), and 64-bit (`>65535`) header encoding (`REQ-SHELL-33`)<br>- `write_server_text` `.Too_Large` on 16-bit (`allow_64bit = false`) and `> 16 MiB` (`allow_64bit = true`), `.Peer_Gone` on dead socket, and 64-bit browser frame write<br>- `ws.send_text` frees `frame` on success and failure (`REQ-SHELL-52`) | - **Did NOT test `ws.poll_text` at all!**<br>- Missed the active `conn.pending_bytes` heap leak in `ws.poll_text` (`ws.odin:235-239`), the `payload_len == 127` disconnect (`ws.odin:215-218`), and the `FIN=0` truncation / `0x0` continuation drop (`ws.odin:208, 225`) — all 4 now proven by `src/lib/ws/ws_audit_validation_test.odin` (`2a`–`2d`). |
| **`src/hub/transport/http/bridge_ws_reader_test.odin`** (`4` tests) & **`bridge_ws_lifecycle_log_test.odin`** (`7` tests) | - Single/coalesced/partial small masked text frames<br>- `0x8` close opcode $\rightarrow$ `.Clean_Close`<br>- `127` 64-bit length $\rightarrow$ `.Fatal_Frame` (`REQ-SHELL-41`)<br>- Reconnect storm log rate-limiter | - **No test for RFC 6455 fragmented messages (`FIN=0` + `0x0` continuation)** on `Bridge_WS_Reader` (proven by Test **1c**).<br>- **No test for browser shell/agent stream handlers (`shell_session_handlers.odin:142`, `agent_instance_handlers.odin:187`) disconnecting on `>64 KB` browser pastes.** |
| **`src/hub/transport/http/bridge_ws_chunk_reassembly_test.odin`** (`10` tests) | - Bridge $\rightarrow$ Hub `kind:"chunk"` in-order, out-of-order, duplicate, and interleaved heartbeat reassembly<br>- Over-cap rejection & admission-gate expiry/eviction when `len == 64` (`REQ-SHELL-32`) | - **Only tested TTL expiry when `len == 64`!** Did not test that `< 64` expired abandoned streams persist indefinitely across subsequent transfers without being swept (proven by Test **1e**).<br>- Did not test the orphaned entry left when chunk 0's decoded bytes exceed `total_bytes` (`bridge_handlers.odin:1476-1478`). |
| **`src/hub/service/bridge_runtime/hub_command_chunk_test.odin`** (`9` tests) & **`src/bridge/hub_command_reassembly_test.odin`** (`8` tests) | - Hub $\rightarrow$ Bridge `hub_command_chunk_frames` & `hub_command_reassemble` (`REQ-SHELL-36`) round-trip, cap guards, and `.Too_Large` $\rightarrow$ `.Validation_Failed` mapping | - **Tested `hub_command_reassemble` in isolation, NOT inside `bridge_hub_runtime_loop` (`hub_runtime_client.odin:310-344`), where every chunk `text` and `assembled` string is leaked on the heap!**<br>- Did not test `bridge_runtime.json_string` (`:285-294`) escaped-quote (`\"`) truncation or uncloned subslice aliasing (proven by Test **1f**). |
| **`src/hub/transport/http/lsp_session_relay_test.odin`** (`18` tests) | - Browser $\leftrightarrow$ Hub `Lsp_WS_Reader` (64-bit + `FIN=0`/`0x0` fragmentation up to 32 MiB) and `lsp_ws_frame_header` | - Never tests the 32 MiB (Browser $\rightarrow$ Hub) vs. 16 MiB (Hub $\rightarrow$ Bridge) cap mismatch or the ignored return value of `bridge_service.send_lsp_message` (`lsp_session_handlers.odin:913, 984`). |

---

## Section 6: Unified Architecture Recommendations (`REQ-WS-AUDIT-6`)

To eliminate all payload size ceilings, duplicated chunking state machines, protocol violations, and active heap leaks permanently, WebSocket framing and transport should be unified in `src/lib/ws`:

### 6.1 Step 1: Canonical RFC 6455 Reader & Writer in `src/lib/ws`

1. **Extend `src/lib/ws/server_frame.odin` & Unify All 4 Outbound Writers**:
   - Promote `ws.write_server_text` (`server_frame.odin:119`) into a role-aware `ws.write_frame(sink, payload, role, max_payload)`:
     - Support 7-bit (`<= 125`), 16-bit (`126..=65535`), and **64-bit (`127`, 8-byte big-endian `u64`)** lengths across all channels once readers are unified.
     - When `role == .Client` (`ws.send_text`), set `MASK = 0x80` and apply a 4-byte masking key so `src/bridge` is 100% RFC 6455 §5.1 compliant.
     - Replace `bridge_runtime.write_ws_text_frame` (`bridge_runtime.odin:241`) and `lsp_write_ws_text_frame_counted` (`lsp_session_handlers.odin:397`) with calls to the shared `src/lib/ws` writer, eliminating the remaining duplicate `0x81` encoders.
     - If a write fails or times out after `sent > 0` bytes (`.Desynchronised`), **immediately close the socket / mark `conn.connected = false`** so a subsequent frame can never be appended to a partial frame.

2. **Promote `Lsp_WS_Reader` into a Unified `ws.Reader` Replacing `Bridge_WS_Reader` and `ws.poll_text`**:
   - Move `Lsp_WS_Reader` (`src/hub/transport/http/lsp_session_handlers.odin:422-614`) into `src/lib/ws/reader.odin` and use it for:
     - Hub Bridge runtime WS (`bridge_handlers.odin`)
     - Browser Shell & Agent terminal streams (`shell_session_handlers.odin:142` and `agent_instance_handlers.odin:187` — immediately fixing the browser $>64\text{ KB}$ paste disconnect!)
     - Browser LSP streams (`lsp_session_handlers.odin:893, 975`)
     - Bridge client `ws.poll_text` (`src/lib/ws/ws.odin:167-243`)
   - **Fix the `conn.pending_bytes` Heap Leak (`ws.odin:235-239`)**: Compact `pending_bytes` in-place via `copy(conn.pending_bytes[:], conn.pending_bytes[pos:])` + `resize(&conn.pending_bytes, remaining)` (matching `Bridge_WS_Reader` at `bridge_handlers.odin:2372-2374` and `Lsp_WS_Reader` at `lsp_session_handlers.odin:573-575`), and free `pending_bytes` and `pending_texts` in `ws.close` (`ws.odin:153-165`) and `data` in `connect_tls_with_bearer` (`ws.odin:122`).
   - **Handle Control Frames (`0x8`, `0x9`, `0xA`) per RFC 6455 §5.5**: Allow Ping (`0x9`) and Pong (`0xA`) frames (including mid-fragmentation) without treating them as `.Fatal_Frame`.

### 6.2 Step 2: Fix Active Inbound Memory Leaks & Parser Bugs (`REQ-SHELL-58` & `bridge_runtime.odin`)

1. **Free `text` and `assembled` in `bridge_hub_runtime_loop` (`src/bridge/hub_runtime_client.odin:308-344, 371`)**:
   - Immediately free `text` when `hub_command_frame_is_chunk(text)` is `true` (since `hub_command_reassemble` clones `chunk_id` and `decoded_text` and never retains `text`!).
   - Audit `bridge_hub_handle_command` handlers so any handler spawning a background thread clones the fields it retains, and add `defer delete(text)` / `defer delete(assembled)` in `bridge_hub_runtime_loop`, plus free the temporary string from `bridge_hub_heartbeat_json()` at lines `243, 308, 371`.
2. **Fix `bridge_runtime.json_string` Escaped-Quote Truncation & Subslice Aliasing (`src/hub/service/bridge_runtime/bridge_runtime.odin:135-139, 149-168, 285-294`)**:
   - Update `bridge_runtime.json_string` to handle backslash escapes (`\"`, `\\`) properly, clone `validation_error` in `validation_result` (`:164`), and `delete(text)` on every iteration of `send_validate_project_path_command` (`:135-139`).
3. **Deduplicate Chunk Reassembly & Sweep Expired Streams Proactively**:
   - Consolidate `Bridge_Chunk_Reassembly` (`bridge_handlers.odin:1332-1517`) and `Hub_Command_Reassembly` (`hub_command_reassembly.odin:52-272`) into a single shared package (`src/lib/ws/chunk.odin`), refresh `last_chunk_at_ns` on each received chunk (idle timeout), and run the TTL sweep on every chunk admission (or periodic heartbeat) rather than only when `len >= 64`.
   - Once native 64-bit + RFC 6455 `FIN=0`/`0x0` fragmentation is enabled on both readers, replace Base64+JSON application chunking with native WebSocket frame fragmentation (eliminating the 33–78% Base64 wire inflation).

### 6.3 Step 3: Per-Bridge Write Locks, `SO_SNDTIMEO`, and Non-Blocking TLS Pipes

1. **Configure `SO_SNDTIMEO` & Per-Bridge Write Locks**:
   - Set `.Send_Timeout` (`SO_SNDTIMEO = 5 * time.Second`) on Bridge command sockets and browser Shell/Event sockets, and replace the global `bridge_runtime_registry_command_lock` with a per-bridge write mutex so a slow 2,797-chunk transfer to one Bridge cannot block other Bridges.
2. **Enforce `WRITE_DEADLINE` on TLS Pipe Writes (`send_all_file` in `src/lib/ws/ws.odin:342-350`)**:
   - Place `conn.stdin_w` in non-blocking mode (`O_NONBLOCK`) and apply `WRITE_DEADLINE` (`5 * time.Second`) + `_send_timeouts` accounting in `send_all_file` so `ws.send_timeouts()` is accurate on `wss://` deployments and a wedged `socat`/`openssl` child cannot hold `conn.send_mu` forever.

---

## Section 7: Empirical Controlled Test Validation (`REQ-WS-AUDIT-7`)

To empirically validate every static audit claim without modifying a single tracked production `.odin` file (`git status --short`), we authored and executed **10 controlled, deterministic Odin unit tests** across two isolated test suites in `/usr/local/google/home/tanmayvijay/heimdall-agent-manager` (`origin/main` @ `05ffa6cf` / `v0.3.3`):
- **`src/hub/transport/http/bridge_ws_audit_validation_test.odin`** (lines `1–361`, **6 tests**: `1a`–`1f`)
- **`src/lib/ws/ws_audit_validation_test.odin`** (lines `1–232`, **4 tests**: `2a`–`2d`, also synced to `/usr/local/google/home/tanmayvijay/heimdall-cloudtop/src/lib/ws/ws_audit_validation_test.odin`)

All 10 tests run against the unmodified production procedures over loopback TCP socket pairs (`127.0.0.1`) or in-memory state machines, and explicitly clean up any intentionally triggered production heap leaks at teardown so `odin test` exits with code `0` and zero leaked allocations.

### 7.1 Controlled Empirical Test Summary Matrix (`origin/main` @ `05ffa6cf`)

| ID | Test Procedure & File Location (`05ffa6cf`) | Audit Finding / Target Production Code (`05ffa6cf`) | Exact Input Stimulus | Observed Production Behavior on `origin/main` (`05ffa6cf`) | Status |
| :- | :--- | :--- | :--- | :--- | :---: |
| **1a** | `audit_claim_write_ws_text_frame_rejects_over_65535`<br>`src/hub/transport/http/bridge_ws_audit_validation_test.odin:104-122` | **WS-01** (`REQ-WS-AUDIT-1`): `http.write_ws_text_frame` (`bridge_handlers.odin:2455-2465`) $\rightarrow$ `ws.write_server_text(client, text, false)` (`server_frame.odin:119-125`). | Loopback TCP socketpair; call `write_ws_text_frame` with a `65,535`-byte JSON payload followed by a `70,000`-byte JSON payload. | `65,535`-byte payload succeeds (`true`); `70,000`-byte payload returns `false` (`.Too_Large`) and logs `WARN ws control frame exceeds the 16-bit length and was NOT sent bytes=70000 limit=65535`. | **PASS** |
| **1b** | `audit_claim_bridge_ws_take_frame_rejects_64bit_length_as_fatal`<br>`src/hub/transport/http/bridge_ws_audit_validation_test.odin:129-147` | **WS-01** (`REQ-WS-AUDIT-1`): `http.bridge_ws_take_frame` (`bridge_handlers.odin:2355-2357`), also used by browser-facing `shell_session_handlers.odin:142` and `agent_instance_handlers.odin:187`. | Valid RFC 6455 masked text frame (`header[0] = 0x81`, `header[1] = 0x80 \| 127`, 8-byte BE length = `70,000`) appended to `Bridge_WS_Reader.pending`. | `bridge_ws_take_frame` sets `reader.fatal_reason = .Fatal_Frame` and returns `text = ""`, `ok = false`, `fatal = true` (tearing down the connection). | **PASS** |
| **1c** | `audit_claim_bridge_ws_take_frame_corrupts_fragmented_message`<br>`src/hub/transport/http/bridge_ws_audit_validation_test.odin:155-184` | **WS-04** (`REQ-WS-AUDIT-1`): `http.bridge_ws_take_frame` (`bridge_handlers.odin:2340-2347`) ignores `FIN=0` and rejects `opcode == 0x0` continuation frames as fatal. | 2-fragment RFC 6455 message: Frame 1 (`0x01`, `FIN=0, opcode=0x1`, masked `{"type":"bridge_heartbeat","part":1`) + Frame 2 (`0x80`, `FIN=1, opcode=0x0`, masked `,"part2":2}`). | Call 1 ignores `FIN=0` and returns truncated invalid JSON `{"type":"bridge_heartbeat","part":1` (`ok = true, fatal = false`). Call 2 rejects `0x80` (`opcode == 0x0`) with `ok = false, fatal = true`. | **PASS** |
| **1d** | `audit_claim_hub_to_bridge_large_json_command_dropped`<br>`src/hub/transport/http/bridge_ws_audit_validation_test.odin:195-255` | **WS-01 / WS-02 / WS-03** (`REQ-WS-AUDIT-3`): `bridge_runtime.write_ws_text_frame` (`bridge_runtime.odin:241-243`), `hub_command_chunk_frames` (`hub_command_chunk.odin:78-94`), `write_ws_command` (`:204-234`), and `send_runtime_command` (`:15-26`). | (1) `70,000`-byte JSON payload to `write_ws_text_frame`; (2) `70,000`-byte payload to `hub_command_chunk_frames(..., 6000)`; (3) `16 MiB + 1` payload to `write_ws_command` & `send_runtime_command`; (4) closed socket to `send_runtime_command`. | (1) `write_ws_text_frame` returns `false`; (2) `hub_command_chunk_frames` produces `12` frames totaling `> 94,000` wire bytes (>33% inflation); (3) `> 16 MiB` returns `.Too_Large` $\rightarrow$ `.Validation_Failed`; (4) closed socket returns `.Bridge_Offline`. *(Pre-`REQ-SHELL-36` `2bb9b48f`: `70,000` B failed directly with `.Bridge_Offline`.)* | **PASS** |
| **1e** | `audit_claim_abandoned_chunk_streams_persist_below_admission_cap`<br>`src/hub/transport/http/bridge_ws_audit_validation_test.odin:263-304` | **WS-02** (`REQ-WS-AUDIT-2`, `REQ-WS-AUDIT-4`): `bridge_ws_reassemble_chunk` (`bridge_handlers.odin:1356, 1444-1451`) gates `bridge_chunk_reassembly_sweep` on `len(reassemblies) >= 64`. | Feed `chunk_index = 0` of `3` (`chunk_abandoned`), age `started_at_ns` past `2 * BRIDGE_WS_REASSEMBLY_TTL`, then complete a 2-chunk transfer (`chunk_complete_1`). | `chunk_complete_1` reassembles and is removed, while the expired `chunk_abandoned` (`received_chunks = 1, chunk_count = 3`) **remains pinned in `reassemblies`** (`len == 1`) because `len < 64`. | **PASS** |
| **1f** | `audit_claim_bridge_runtime_write_ws_text_frame_leaks_frame_buffer`<br>`src/hub/transport/http/bridge_ws_audit_validation_test.odin:317-360` | **WS-03 / WS-06** (`REQ-WS-AUDIT-4`): `bridge_runtime.write_ws_text_frame` (`bridge_runtime.odin:241-264`), `json_string` (`:285-294`), and `parse_validation_result` (`:149-168`). | (1) `Tracking_Allocator` around `write_ws_text_frame`; (2) `json_string` & `parse_validation_result` on JSON with escaped quotes `"invalid path \"/tmp/ws\" here"`. | (1) `write_ws_text_frame` frees `frame` on `05ffa6cf` (`len(allocation_map) == 0`, whereas pre-`REQ-SHELL-36` `2bb9b48f` leaked `69 B`); (2) `json_string` truncates at `\"` (`"invalid path \"`) AND `parsed.validation_error` aliases `raw_json` directly (`err_ptr` inside `[raw_start, raw_end)`), forcing `send_validate_project_path_command` (`:135-139`) to leak `ws.poll_text` strings. | **PASS** |
| **2a** | `audit_claim_ws_send_text_rejects_over_65535`<br>`src/lib/ws/ws_audit_validation_test.odin:48-67` | **WS-01** (`REQ-WS-AUDIT-1`): Bridge client `ws.send_text` (`src/lib/ws/ws.odin:259-262`) rejects any payload $> 65,535\text{ B}$. | Connected `ws.Connection` over loopback TCP socketpair; call `ws.send_text(&conn, string(payload_70k))` with `70,000` bytes. | `ws.send_text` immediately returns `false` at `if n > 65535 do return false` (`ws.odin:262`). | **PASS** |
| **2b** | `audit_claim_ws_poll_text_disconnects_on_64bit_length`<br>`src/lib/ws/ws_audit_validation_test.odin:73-104` | **WS-01** (`REQ-WS-AUDIT-1`): Bridge client `ws.poll_text` (`src/lib/ws/ws.odin:215-218`) disconnects on any inbound 64-bit length frame (`payload_len == 127`). | `ws.Connection` (`connected = true`) with 64-bit WS header (`0x81, 127` + 8-byte BE `70,000`) in `pending_bytes` + 1 trigger byte on socket. | `ws.poll_text` hits `else if payload_len == 127` (`ws.odin:215`), sets `conn.connected = false`, and returns `"", false`. | **PASS** |
| **2c** | `audit_claim_ws_poll_text_truncates_fragmented_frames_and_drops_continuations`<br>`src/lib/ws/ws_audit_validation_test.odin:112-167` | **WS-04** (`REQ-WS-AUDIT-1`): Bridge client `ws.poll_text` (`src/lib/ws/ws.odin:208, 225-233`) emits truncated `FIN=0` frames and silently discards `0x0` continuation frames. | `ws.Connection` with Frame 1 (`0x01`, `FIN=0`, `{"part":1`) + Frame 2 (`0x80`, `FIN=1, opcode=0x0`, `,"part2":2}`). | Call 1 returns truncated `{"part":1` (`ok1 = true`) and advances `pos` past Frame 2 (`len(pending_bytes) == 0`); Call 2 returns `"", false` (Frame 2 lost). | **PASS** |
| **2d** | `audit_claim_ws_poll_text_leaks_pending_bytes_on_consume`<br>`src/lib/ws/ws_audit_validation_test.odin:175-231` | **WS-06** (`REQ-WS-AUDIT-4`): `ws.poll_text` (`src/lib/ws/ws.odin:235-239`) overwrites `conn.pending_bytes = remaining` without `delete(conn.pending_bytes)`. | Loopback TCP socketpair + scoped `mem.Tracking_Allocator`; send valid 23-byte unmasked WS frame (`0x81`), call `ws.poll_text(&conn)`, and `delete` all caller-reachable buffers. | `len(track.allocation_map) == 1` (`leaked_size >= 25` bytes): proves `ws.poll_text` leaks the prior `conn.pending_bytes` backing buffer on every consumed frame (freed in test teardown so `odin test` reports 0 leaks). | **PASS** |

---

### 7.2 Detailed Per-Test Breakdown (`1a`–`1f` & `2a`–`2d`)

#### Test 1a: `audit_claim_write_ws_text_frame_rejects_over_65535`
- **Test File:** `src/hub/transport/http/bridge_ws_audit_validation_test.odin:104-122`
- **Target Production Code:** `http.write_ws_text_frame` (`src/hub/transport/http/bridge_handlers.odin:2455-2465`) $\rightarrow$ `ws.write_server_text(client, text, false)` (`src/lib/ws/server_frame.odin:119-125`)
- **Stimulus & Assertions:**
  Creates a loopback TCP socketpair via `make_audit_sock_pair(t)` and constructs two valid JSON `fs_write_file` payloads using `make_sized_json_payload`:
  1. `payload_65535` (`65,535` bytes, the exact `ws.WS_16BIT_MAX_PAYLOAD` maximum): `write_ws_text_frame(pair.hub, string(payload_65535))` returns `true`.
  2. `payload_70000` (`70,000` bytes): `write_ws_text_frame(pair.hub, string(payload_70000))` receives `.Too_Large` from `ws.write_server_text(client, text, false)`, prints `ham-hub WARN ws control frame exceeds the 16-bit length and was NOT sent bytes=70000 limit=65535`, and returns `false`.

#### Test 1b: `audit_claim_bridge_ws_take_frame_rejects_64bit_length_as_fatal`
- **Test File:** `src/hub/transport/http/bridge_ws_audit_validation_test.odin:129-147`
- **Target Production Code:** `http.bridge_ws_take_frame` (`src/hub/transport/http/bridge_handlers.odin:2337-2376`)
- **Stimulus & Assertions:**
  Encodes a standard RFC 6455 masked text frame carrying `70,000` bytes (`frame_64bit[0] = 0x81`, `frame_64bit[1] = 0x80 | 127`, followed by the 8-byte big-endian length `0x0000000000011170` and 4-byte mask `{0x12, 0x34, 0x56, 0x78}`) and appends it to `reader.pending`. Calling `bridge_ws_take_frame(&reader)` hits `else if payload_len == 127` at `bridge_handlers.odin:2355-2357`, sets `reader.fatal_reason = .Fatal_Frame`, and returns `ok = false`, `fatal = true`, and `text = ""`.

#### Test 1c: `audit_claim_bridge_ws_take_frame_corrupts_fragmented_message`
- **Test File:** `src/hub/transport/http/bridge_ws_audit_validation_test.odin:155-184`
- **Target Production Code:** `http.bridge_ws_take_frame` (`src/hub/transport/http/bridge_handlers.odin:2340-2347`)
- **Stimulus & Assertions:**
  Splits the JSON message `{"type":"bridge_heartbeat","part":1,"part2":2}` into two valid RFC 6455 fragments:
  - `frag1`: `first_byte = 0x01` (`FIN=0, opcode=0x1` text), masked payload `{"type":"bridge_heartbeat","part":1`
  - `frag2`: `first_byte = 0x80` (`FIN=1, opcode=0x0` continuation), masked payload `,"part2":2}`
  Appends both frames into `reader.pending`:
  - **Call 1 (`bridge_ws_take_frame(&reader)`):** Because `bridge_ws_take_frame` checks only `b[0] & 0x0f != 0x1` (`:2340`) and ignores the `FIN` bit (`0x80`), it returns the truncated first half `{"type":"bridge_heartbeat","part":1` with `ok1 = true, fatal1 = false`.
  - **Call 2 (`bridge_ws_take_frame(&reader)`):** Reads `frag2` (`b[0] & 0x0f == 0x0`), triggers `if b[0] & 0x0f != 0x1` at `bridge_handlers.odin:2340`, sets `reader.fatal_reason = .Fatal_Frame`, and returns `ok2 = false, fatal2 = true`.

#### Test 1d: `audit_claim_hub_to_bridge_large_json_command_dropped`
- **Test File:** `src/hub/transport/http/bridge_ws_audit_validation_test.odin:195-255`
- **Target Production Code:** `bridge_runtime.write_ws_text_frame` (`src/hub/service/bridge_runtime/bridge_runtime.odin:241-264`), `hub_command_chunk_frames` (`src/hub/service/bridge_runtime/hub_command_chunk.odin:78-94`), `write_ws_command` (`bridge_runtime.odin:204-234`), and `send_runtime_command` (`bridge_runtime.odin:15-26`)
- **Stimulus & Assertions (`origin/main` @ `05ffa6cf` vs. Pre-`REQ-SHELL-36` @ `2bb9b48f`):**
  1. **Direct Frame Writer Cap (`bridge_runtime.odin:241-243`):** Proves `bridge_runtime_service.write_ws_text_frame(pair.hub, string(large_body))` still hard-rejects a `70,000`-byte JSON payload (`!direct_wrote`).
  2. **Base64 + JSON Chunk Amplification (`hub_command_chunk.odin:78-126`):** Proves `bridge_runtime_service.hub_command_chunk_frames(string(large_body), contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES)` splits the `70,000`-byte payload (`6,000` B/chunk) into **`12` frames** whose total wire size exceeds **`94,000` bytes** (`> 34%` wire amplification).
  3. **Over-Cap Rejection (`> 16 MiB`):** Proves `write_ws_command` and `send_runtime_command` reject a payload of `contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES + 1` (`16 MiB + 1`) with `Command_Write_Result.Too_Large` $\rightarrow$ `domain.Error_Code.Validation_Failed`.
  4. **Closed Socket Mapping:** Proves that when the command socket is closed, `send_runtime_command` returns `sent_closed = false`, `derr_closed.code = domain.Error_Code.Bridge_Offline`, and `derr_closed.message = "bridge websocket command send failed"`. *(In the pre-`REQ-SHELL-36` snapshot `2bb9b48f` in `heimdall-cloudtop`, `send_runtime_command` had no chunker and returned `.Bridge_Offline` directly for the `70,000`-byte payload on a live socket.)*

#### Test 1e: `audit_claim_abandoned_chunk_streams_persist_below_admission_cap`
- **Test File:** `src/hub/transport/http/bridge_ws_audit_validation_test.odin:263-304`
- **Target Production Code:** `http.bridge_ws_reassemble_chunk` (`src/hub/transport/http/bridge_handlers.odin:1356, 1396-1497`)
- **Stimulus & Assertions:**
  1. Feeds chunk `0` of `3` for `chunk_abandoned` (`total_bytes = 15`) into `bridge_ws_reassemble_chunk(&reassemblies, abandoned_f0)`. Confirms `ok0 = true`, `complete0 = false`, and `len(reassemblies) == 1`.
  2. Ages the abandoned entry well past `BRIDGE_WS_REASSEMBLY_TTL` (`reassemblies[0].started_at_ns -= i64(2 * BRIDGE_WS_REASSEMBLY_TTL)`).
  3. Feeds a complete 2-chunk transfer (`chunk_complete_1`, chunks `0/2` and `1/2`), which reassembles `"complete-payload"` and removes `chunk_complete_1`.
  4. Proves that **even though `chunk_abandoned` is past `2 * BRIDGE_WS_REASSEMBLY_TTL`**, it is **never swept** (`len(reassemblies) == 1`, `reassemblies[0].chunk_id == "chunk_abandoned"`) because `bridge_chunk_reassembly_sweep` (`bridge_handlers.odin:1444-1445`) is gated on `len(reassemblies) >= contracts.BRIDGE_WS_MAX_REASSEMBLIES` (`64`).

#### Test 1f: `audit_claim_bridge_runtime_write_ws_text_frame_leaks_frame_buffer`
- **Test File:** `src/hub/transport/http/bridge_ws_audit_validation_test.odin:317-360`
- **Target Production Code:** `bridge_runtime.write_ws_text_frame` (`src/hub/service/bridge_runtime/bridge_runtime.odin:241-264`), `bridge_runtime.json_string` (`:285-294`), and `bridge_runtime.parse_validation_result` (`:149-168`)
- **Stimulus & Assertions (`origin/main` @ `05ffa6cf` vs. Pre-`REQ-SHELL-36` @ `2bb9b48f`):**
  1. Wraps `bridge_runtime_service.write_ws_text_frame(pair.hub, payload)` (`67`-byte `lsp_send` JSON) in a scoped `mem.Tracking_Allocator` and verifies `len(track.allocation_map) == 0` on `05ffa6cf` (confirming the `REQ-SHELL-36` `defer delete(frame)` fix at `bridge_runtime.odin:252`; in `heimdall-cloudtop` @ `2bb9b48f`, this exact call leaked `69` bytes).
  2. Calls `bridge_runtime_service.json_string(raw_json, "validation_error")` on `raw_json = {"type":"project_path_validation_result","command_id":"cmd_1","ok":false,"validation_error":"invalid path \"/tmp/ws\" here","code":"bad_path"}` and proves it returns the truncated string ``invalid path \`` instead of `invalid path \"/tmp/ws\" here`.
  3. Calls `parsed := bridge_runtime_service.parse_validation_result(cmd, raw_json)` and proves via pointer arithmetic (`err_ptr >= raw_start && err_ptr < raw_end`) that `parsed.validation_error` is an **uncloned subslice aliasing `raw_json`**, demonstrating why `send_validate_project_path_command` (`bridge_runtime.odin:135-139`) leaks the `ws.poll_text` string on the heap to avoid a use-after-free.

#### Test 2a: `audit_claim_ws_send_text_rejects_over_65535`
- **Test File:** `src/lib/ws/ws_audit_validation_test.odin:48-67`
- **Target Production Code:** `ws.send_text` (`src/lib/ws/ws.odin:259-285`)
- **Stimulus & Assertions:**
  Creates a connected `ws.Connection` (`secure = false, connected = true`) over a loopback TCP socketpair and calls `send_text(&conn, string(payload_70k))` with a `70,000`-byte string. Confirms `send_text` returns `false` at `if n > 65535 do return false` (`src/lib/ws/ws.odin:262`).

#### Test 2b: `audit_claim_ws_poll_text_disconnects_on_64bit_length`
- **Test File:** `src/lib/ws/ws_audit_validation_test.odin:73-104`
- **Target Production Code:** `ws.poll_text` (`src/lib/ws/ws.odin:167-243`)
- **Stimulus & Assertions:**
  Populates `conn.pending_bytes` with a 10-byte RFC 6455 64-bit extended length text frame header (`0x81, 127, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x11, 0x70`, representing `70,000` bytes) and writes 1 trigger byte (`'{'`) on `pair.server` so `poll_text`'s `net.recv_tcp` enters the frame parser loop. Proves that `poll_text(&conn)` hits `else if payload_len == 127` (`src/lib/ws/ws.odin:215-218`), returns `text = "", poll_ok = false`, and sets `conn.connected = false`.

#### Test 2c: `audit_claim_ws_poll_text_truncates_fragmented_frames_and_drops_continuations`
- **Test File:** `src/lib/ws/ws_audit_validation_test.odin:112-167`
- **Target Production Code:** `ws.poll_text` (`src/lib/ws/ws.odin:208, 225-239`)
- **Stimulus & Assertions:**
  Queues a two-frame fragmented JSON message into `conn.pending_bytes`:
  - Frame 1: `0x01` (`FIN=0, opcode=0x1` text), payload `{"part":1`
  - Frame 2: `0x80` (`FIN=1, opcode=0x0` continuation), payload `,"part2":2}` (with the final `'}'` delivered via `net.send_tcp` on `pair.server`).
  Proves:
  1. **First `poll_text(&conn)` call:** Ignores `FIN=0` (`ws.odin:208`), returning the truncated first fragment `{"part":1` with `ok1 = true`.
  2. **Silent continuation drop:** In the same loop pass, `ws.poll_text` parses Frame 2 (`opcode == 0x0`), skips `if opcode == 0x1` (`ws.odin:225`), and advances `pos = frame_end` (`ws.odin:233`), discarding `,"part2":2}` (`len(conn.pending_bytes) == 0`, `len(conn.pending_texts) == 0`).
  3. **Second `poll_text(&conn)` call:** Returns `text2 = "", ok2 = false` because Frame 2 was already discarded.

#### Test 2d: `audit_claim_ws_poll_text_leaks_pending_bytes_on_consume`
- **Test File:** `src/lib/ws/ws_audit_validation_test.odin:175-231`
- **Target Production Code:** `ws.poll_text` (`src/lib/ws/ws.odin:235-239`)
- **Stimulus & Assertions:**
  Sends a valid 23-byte unmasked WebSocket text frame (`0x81`, `payload = {"type":"ack","ok":true}`) over a loopback TCP socketpair into `conn.socket`. Inside a scoped `mem.Tracking_Allocator` (`track`), initializes `conn`, calls `text, poll_ok := poll_text(&conn)`, verifies `poll_ok == true` and `text == payload`, and explicitly `delete`s all caller-accessible allocations (`delete(text)`, `delete(conn.pending_bytes)`, `delete(conn.pending_texts)`).
  Proves that:
  1. `len(track.allocation_map) == 1` and `leaked_size >= 2 + len(payload)` (`25` bytes): `ws.poll_text` at `src/lib/ws/ws.odin:236-238` (`remaining := make([dynamic]byte); ... conn.pending_bytes = remaining`) leaked the prior `conn.pending_bytes` dynamic array backing buffer on the heap without calling `delete(conn.pending_bytes)`.
  2. Explicitly frees `leaked_ptr` through `track` at the end of the test so `odin test` exits `0` with `0` leaks.

---

### 7.3 Test Suite Verification Summary & Verbatim Execution Outputs

#### A. Primary Baseline: `/usr/local/google/home/tanmayvijay/heimdall-agent-manager` (`origin/main` @ `05ffa6cf` / `v0.3.3`)

| Package / Test Target (`05ffa6cf`) | Command Executed (`ham-ctl shell run`) | Total Tests | Controlled Audit Tests Included | Pass Rate | Execution Time | Exit Code |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| **`src/lib/ws`** | `nix develop --command bash -c 'odin test src/lib/ws -collection:odin_test=src -define:ODIN_TEST_THREADS=1'` | **14** | **4** (`2a`–`2d` in `ws_audit_validation_test.odin`) + 10 `REQ-SHELL-33`/`52` tests | **100% (14/14)** | `66.669615ms` | `0` |
| **`src/hub/transport/http`** | `nix develop --command bash -c 'odin test src/hub/transport/http -collection:odin_test=src -define:ODIN_TEST_THREADS=1'` | **197** | **6** (`1a`–`1f` in `bridge_ws_audit_validation_test.odin`) + 39 WS/LSP tests | **100% (197/197)** | `14.377756632s` | `0` |
| **`src/bridge`** | `TZ=UTC nix develop --command bash -c 'odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_THREADS=1'` | **372** | 4 outbound chunk tests (`hub_runtime_chunk_test.odin`) + 8 inbound reassembly tests (`hub_command_reassembly_test.odin`) | **100% (372/372)** | `4.458638509s` | `0` |
| **`src/hub/service/bridge_runtime`** | `nix develop --command bash -c 'odin test src/hub/service/bridge_runtime -collection:odin_test=src -define:ODIN_TEST_THREADS=1'` | **11** | 9 Hub $\rightarrow$ Bridge chunk tests (`hub_command_chunk_test.odin`) + 2 cache tests | **100% (11/11)** | `14.494961ms` | `0` |

##### 1. Verbatim Output (`05ffa6cf`): `odin test src/lib/ws` (`exec_id: sh_18da2e332ac96af9`)
Command:
```bash
nix develop --command bash -c 'odin test src/lib/ws -collection:odin_test=src -define:ODIN_TEST_THREADS=1'
```
Output:
```text
[INFO ] --- [2026-09-30 18:56:40] Starting test runner with 1 thread.
[INFO ] --- [2026-09-30 18:56:40] The random seed sent to every test is: 488377988806924. Set with -define:ODIN_TEST_RANDOM_SEED=n.
[INFO ] --- [2026-09-30 18:56:40] Memory tracking is enabled. Tests will log their memory usage if there's an issue.
[INFO ] --- [2026-09-30 18:56:40] < Final Mem/ Total Mem> <  Peak Mem> (#Free/Alloc) :: [package.test_name]
ws  [||||||||||||||          ]    1/  14 :: audit_claim_ws_poll_text_disconnects_on_64bit_length
ws  [||||||||||||||          ]    2/  14 :: audit_claim_ws_poll_text_leaks_pending_bytes_on_consume
ws  [||||||||||||||          ]    3/  14 :: audit_claim_ws_poll_text_truncates_fragmented_frames_and_drops_continuations
ws  [||||||||||||||          ]    4/  14 :: audit_claim_ws_send_text_rejects_over_65535
ws  [||||||||||||||          ]    5/  14 :: req33_16_bit_channel_refuses_oversize_as_too_large_not_peer_gone
ws  [||||||||||||||          ]    6/  14 :: req33_a_dead_socket_is_peer_gone
ws  [||||||||||||||          ]    7/  14 :: req33_browser_channel_writes_a_64_bit_frame_intact
ws  [||||||||||||||          ]    8/  14 :: req33_header_uses_the_16_bit_arm_up_to_65535
ws  [||||||||||||||          ]    9/  14 :: req33_header_uses_the_64_bit_arm_above_65535
ws  [||||||||||||||          ]   10/  14 :: req33_header_uses_the_one_byte_arm_under_126
ws  [||||||||||||||          ]   11/  14 :: req33_the_64_bit_arm_is_bounded
ws  [||||||||||||||          ]   12/  14 :: test_send_text_allocates_nothing_on_the_pre_allocation_refusals
ws  [||||||||||||||          ]   13/  14 :: test_send_text_frees_its_frame_on_the_success_path
ws  [||||||||||||||          ]   13/  14 :: test_send_text_frees_its_frame_when_the_write_fails
ws  [||||||||||||||          ]        14 :: [package done]

Finished 14 tests in 66.669615ms. All tests were successful.
```

##### 2. Verbatim Output (`05ffa6cf`): `odin test src/hub/transport/http` (`exec_id: sh_18da2e3414abcdad`)
Command:
```bash
nix develop --command bash -c 'odin test src/hub/transport/http -collection:odin_test=src -define:ODIN_TEST_THREADS=1'
```
Output (showing runner header, all 6 `audit_claim_*` tests `11/197`–`17/197`, `bridge_ws_*` reader tests `18/197`–`29/197`, and final summary):
```text
[INFO ] --- [2026-09-30 18:56:45] Starting test runner with 1 thread.
[INFO ] --- [2026-09-30 18:56:45] The random seed sent to every test is: 488390377052041. Set with -define:ODIN_TEST_RANDOM_SEED=n.
[INFO ] --- [2026-09-30 18:56:45] Memory tracking is enabled. Tests will log their memory usage if there's an issue.
[INFO ] --- [2026-09-30 18:56:45] < Final Mem/ Total Mem> <  Peak Mem> (#Free/Alloc) :: [package.test_name]
...
http  [||||||||||||||||||||||||]   11/ 197 :: audit_claim_abandoned_chunk_streams_persist_below_admission_cap
http  [||||||||||||||||||||||||]   12/ 197 :: audit_claim_abandoned_chunk_streams_persist_below_admission_cap
http  [||||||||||||||||||||||||]   12/ 197 :: audit_claim_bridge_runtime_write_ws_text_frame_leaks_frame_buffer
http  [||||||||||||||||||||||||]   13/ 197 :: audit_claim_bridge_runtime_write_ws_text_frame_leaks_frame_buffer
http  [||||||||||||||||||||||||]   14/ 197 :: audit_claim_bridge_ws_take_frame_corrupts_fragmented_message
http  [||||||||||||||||||||||||]   14/ 197 :: audit_claim_bridge_ws_take_frame_rejects_64bit_length_as_fatal
http  [||||||||||||||||||||||||]   15/ 197 :: audit_claim_bridge_ws_take_frame_rejects_64bit_length_as_fatal
http  [||||||||||||||||||||||||]   15/ 197 :: audit_claim_hub_to_bridge_large_json_command_dropped
http  [||||||||||||||||||||||||]   16/ 197 :: audit_claim_hub_to_bridge_large_json_command_dropped
http  [||||||||||||||||||||||||]   16/ 197 :: audit_claim_write_ws_text_frame_rejects_over_65535
ham-hub WARN ws control frame exceeds the 16-bit length and was NOT sent bytes=70000 limit=65535
http  [||||||||||||||||||||||||]   17/ 197 :: audit_claim_write_ws_text_frame_rejects_over_65535
http  [||||||||||||||||||||||||]   18/ 197 :: bridge_ws_64bit_length_reads_as_fatal_desync
http  [||||||||||||||||||||||||]   19/ 197 :: bridge_ws_close_frame_reads_as_clean_close
http  [||||||||||||||||||||||||]   20/ 197 :: bridge_ws_log_limiter_bounds_a_reconnect_storm
http  [||||||||||||||||||||||||]   21/ 197 :: bridge_ws_log_limiter_budgets_are_per_bridge
http  [||||||||||||||||||||||||]   22/ 197 :: bridge_ws_log_limiter_survives_more_bridges_than_slots
http  [||||||||||||||||||||||||]   23/ 197 :: bridge_ws_partial_frame_is_not_a_teardown
http  [||||||||||||||||||||||||]   24/ 197 :: bridge_ws_reason_strings_are_distinct
http  [||||||||||||||||||||||||]   25/ 197 :: bridge_ws_successful_read_clears_stale_reason
http  [||||||||||||||||||||||||]   26/ 197 :: bridge_ws_take_frame_decodes_single
http  [||||||||||||||||||||||||]   27/ 197 :: bridge_ws_take_frame_flags_nontext_fatal
http  [||||||||||||||||||||||||]   28/ 197 :: bridge_ws_take_frame_keeps_coalesced_second_frame
http  [||||||||||||||||||||||||]   29/ 197 :: bridge_ws_take_frame_waits_for_partial
...
http  [||||||||||||||||||||||||]       197 :: [package done]

Finished 197 tests in 14.377756632s. All tests were successful.
```

##### 3. Verbatim Output (`05ffa6cf`): `odin test src/bridge` (`exec_id: sh_18da2e50f959c0ab`)
Command:
```bash
TZ=UTC nix develop --command bash -c 'odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_THREADS=1'
```
Output (showing runner header, `hub_chunk_frames_*` and `hub_command_reassemble_*` tests `171/372`–`182/372`, and final summary):
```text
[INFO ] --- [2026-09-30 18:58:50] Starting test runner with 1 thread.
[INFO ] --- [2026-09-30 18:58:50] Memory tracking is enabled. Tests will log their memory usage if there's an issue.
[INFO ] --- [2026-09-30 18:58:50] < Final Mem/ Total Mem> <  Peak Mem> (#Free/Alloc) :: [package.test_name]
...
main  [||||||||||||||||||||||||]  171/ 372 :: hub_chunk_frames_passes_small_through
[WARN ] --- [2026-09-30 18:58:51] <   1.23KiB/   2.62KiB> <   1.42KiB> (   12/   15) :: main.hub_chunk_frames_passes_small_through
        +++ leak        32B @ 0x7FFFF6BFD118 [main.odin:585:bridge_hub_chunk_frames_with_payload()]
main  [||||||||||||||||||||||||]  172/ 372 :: hub_chunk_frames_passes_small_through
main  [||||||||||||||||||||||||]  172/ 372 :: hub_chunk_frames_s_client_payload_stays_under_proxy_cap
[WARN ] --- [2026-09-30 18:58:51] <   8.02KiB/  89.62KiB> <  41.08KiB> (   44/   46) :: main.hub_chunk_frames_s_client_payload_stays_under_proxy_cap
main  [||||||||||||||||||||||||]  173/ 372 :: hub_chunk_frames_s_client_payload_stays_under_proxy_cap
main  [||||||||||||||||||||||||]  173/ 372 :: hub_chunk_frames_socat_payload_stays_under_ws_frame_limit
[WARN ] --- [2026-09-30 18:58:51] <  64.02KiB/ 697.41KiB> < 319.59KiB> (   53/   55) :: main.hub_chunk_frames_socat_payload_stays_under_ws_frame_limit
main  [||||||||||||||||||||||||]  174/ 372 :: hub_chunk_frames_socat_payload_stays_under_ws_frame_limit
main  [||||||||||||||||||||||||]  174/ 372 :: hub_chunk_frames_splits_and_roundtrips
[WARN ] --- [2026-09-30 18:58:51] <   1.27KiB/   8.87KiB> <   4.46KiB> (   60/   72) :: main.hub_chunk_frames_splits_and_roundtrips
main  [||||||||||||||||||||||||]  175/ 372 :: hub_chunk_frames_splits_and_roundtrips
main  [||||||||||||||||||||||||]  176/ 372 :: hub_command_reassemble_accepts_the_bridges_own_chunk_shape
main  [||||||||||||||||||||||||]  177/ 372 :: hub_command_reassemble_conflicting_metadata_keeps_the_stream
main  [||||||||||||||||||||||||]  178/ 372 :: hub_command_reassemble_interrupted_sequence_never_dispatches
main  [||||||||||||||||||||||||]  179/ 372 :: hub_command_reassemble_rejects_malformed_and_over_cap
main  [||||||||||||||||||||||||]  180/ 372 :: hub_command_reassemble_round_trips_in_order
main  [||||||||||||||||||||||||]  181/ 372 :: hub_command_reassemble_tolerates_out_of_order_and_duplicates
...
main  [||||||||||||||||||||||||]       372 :: [package done]

Finished 372 tests in 4.458638509s. All tests were successful.
```

#### B. Comparison Snapshot: `/usr/local/google/home/tanmayvijay/heimdall-cloudtop` (`feat/cloudtop-single-node` @ `2bb9b48f`, Pre-`REQ-SHELL-36`)

In the pre-`REQ-SHELL-36` snapshot (`/usr/local/google/home/tanmayvijay/heimdall-cloudtop` @ `2bb9b48f`), all 4 tests in `src/lib/ws/ws_audit_validation_test.odin` (`2a`–`2d`, `4/4 PASS`) and all 6 tests in `src/hub/transport/http/bridge_ws_audit_validation_test.odin` (`1a`–`1f`, `158/158 PASS`) also pass deterministically with `0` leaks, demonstrating the exact behavioral transition between `2bb9b48f` and `05ffa6cf` on Tests `1d`, `1e`, and `1f`:
- **Test `1d` (`2bb9b48f` vs. `05ffa6cf`)**: On `2bb9b48f`, `send_runtime_command` had no chunker and dropped any `70,000`-byte command with `.Bridge_Offline`; on `05ffa6cf`, `write_ws_command` chunks `70,000` bytes into `12` Base64 JSON frames (`> 94,000` wire bytes) while `write_ws_text_frame` still hard-rejects `> 65,535` bytes and `> 16 MiB` returns `.Too_Large` $\rightarrow$ `.Validation_Failed`.
- **Test `1e` (`2bb9b48f` vs. `05ffa6cf`)**: On `2bb9b48f`, `Bridge_Chunk_Reassembly` had no TTL field at all; on `05ffa6cf`, `BRIDGE_WS_REASSEMBLY_TTL :: 30 * time.Second` exists (`bridge_handlers.odin:1356`), but `bridge_chunk_reassembly_sweep` is gated on `len(reassemblies) >= 64` (`:1444`), so `< 64` expired abandoned streams still persist indefinitely.
- **Test `1f` (`2bb9b48f` vs. `05ffa6cf`)**: On `2bb9b48f`, `bridge_runtime.write_ws_text_frame` leaked every `frame` slice (`69` bytes); on `05ffa6cf`, `write_ws_text_frame` frees `frame` (`:252`), while `bridge_runtime.json_string` (`:285-294`) still truncates at escaped quotes (`\"`) and aliases uncloned subslices into `Project_Path_Validation_Result.validation_error`, forcing `send_validate_project_path_command` (`:135-139`) to leak `ws.poll_text` strings on the heap.
