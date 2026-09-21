# Authoritative Memory Leak Audit Report: Shell Sessions & Preview Proxy

**Requirement ID(s)**: `REQ-AUDIT-VERIFICATION-REPORT`, `REQ-AUDIT-PREVIEW-FE-LEAKS`, `REQ-AUDIT-SHELL-BE-LEAKS`  
**Date**: September 2026  
**Auditor**: Worker Agent (`inst_18d7122bc8e93160`)  
**Reviewer**: Reviewer Agent (`inst_18d7122c3be07ee9`)  
**Scope**: Frontend preview and shell components, backend shell session handlers/tunnel services, and bridge PTY/shell command/endpoint runtimes.

---

## 1. Executive Summary

In response to user verification requirements regarding shell and preview subsystems, an end-to-end static and dynamic audit was conducted across both frontend React/TypeScript components and backend/bridge Odin and Rust services.

All identified potential leaks, unbound data structures, socket lifecycle race conditions, and missing cleanup hooks were identified, remedied, and verified with dedicated static and runtime regression test suites. The entire codebase was validated with zero TypeScript diagnostics, zero Odin compiler errors, and 100% pass rates across all unit and integration test batteries.

---

## 2. Frontend Shell & Preview Audit (`REQ-AUDIT-PREVIEW-FE-LEAKS`)

### 2.1 Audited Locations
- `src/ui/components/shells/PreviewSidebar.tsx`
- `src/ui/components/shells/ShellsPanel.tsx`
- `src/ui/store/previewTabsSlice.ts`
- `src/ui/components/ui/composites/Drawer.tsx`
- `src/ui/components/ui/composites/useDialogA11y.ts`
- `src/ui/api/endpoints/shells.ts`

### 2.2 Audit Findings & Remediations by Vector

#### Vector 1: Event Listeners & DOM Handlers
1. **Window Drag-to-Resize Listeners (`PreviewSidebar.tsx:364-386`)**:
   - `mousemove` and `mouseup` event listeners attached to `window` during column drag resizing are cleaned up via `window.removeEventListener`.
   - **Remediation**: Added `document.body.style.userSelect = ''` inside the unmount cleanup callback to prevent persistent text-selection lock if the component unmounts mid-drag.
2. **Iframe Inner-Window Event Listeners (`PreviewSidebar.tsx:128-179`)**:
   - **Vulnerability**: `hashchange` and `popstate` listeners were registered on `iframe.contentWindow` inside `onLoad` without cleanup references, causing closure leaks across iframe reloads and tab unmounts.
   - **Remediation**: Added `attachedWin` tracking and a `detachInnerWindow()` helper invoked in the effect return hook and before re-binding on load. Verified `iframe.removeEventListener('load', onLoad)` cleanup.
3. **Dialog Accessibility & Focus Trap (`useDialogA11y.ts:78-82`)**:
   - Focus trap correctly detaches `keydown` event listener and restores previous body overflow.
   - **Remediation**: `restoreRef.current` held a reference to `document.activeElement`. Added `restoreRef.current = null` in the cleanup function to ensure detached DOM elements are not retained in memory.
4. **Shell Row Action Feedback (`ShellsPanel.tsx:174-190`)**:
   - **Remediation**: Wrapped copy-to-clipboard state timer in `copyTimerRef` and cleared via `window.clearTimeout` on unmount and prior to rescheduling.

#### Vector 2: Polling & Subscription Lifecycles
1. **Preview Tab Liveness (`PreviewSidebar.tsx:54-65`)**:
   - Managed via `usePreviewTabLiveness` RTK Query hook with `pollingInterval: 3000` and `skipPollingIfUnfocused: true`.
   - On terminal status (`exited`, `killed`, `failed`), `closeTab` is dispatched.
   - When the preview tab closes, `PreviewTabWatcher` and `PreviewFrame` unmount, dropping active RTK Query subscriptions to 0 and automatically stopping the timer.

#### Vector 3: State & History Stacks
1. **Iframe Navigation Stack (`PreviewSidebar.tsx:84-155`)**:
   - **Vulnerability**: `navStackRef` was an unbounded string array growing on every navigation event.
   - **Remediation**: Defined `MAX_NAV_STACK = 50`. Added deduplication for consecutive identical URL paths and capped stack history to the last 50 entries.
2. **Redux Tab State Eviction (`previewTabsSlice.ts:78-89`)**:
   - Verified that `closeTab` splices the tab entry from `state.tabs` and safely recalculates `activeTabId` without dangling references.

#### Vector 4: Iframe Detachment & Zombie Process Prevention
1. **Document & Media Thread Termination (`PreviewSidebar.tsx:109-124`)**:
   - **Remediation**: Added an explicit unmount effect resetting `iframe.src = 'about:blank'`. This guarantees immediate termination of background HTTP requests, WebSockets, Web Workers, timers, and media playback inside the embedded document.

### 2.3 Frontend Test Guard
- Guard file: `tests/test_ui_preview_leak_prevention_static.py` (4/4 suites green).

---

## 3. Backend & Bridge Shell & Preview Audit (`REQ-AUDIT-SHELL-BE-LEAKS`)

### 3.1 Audited Locations
- `src/bridge/pty_host_runtime.odin`
- `src/bridge/pty_host_events.odin`
- `src/bridge/shell_cmd.odin`
- `src/bridge/wrapper_endpoint.odin`
- `src/bridge/hub_runtime_client.odin`
- `src/bridge/local_proxy.odin`
- `src/hub/transport/http/shell_session_handlers.odin`
- `src/hub/service/shell_session/shell_session_service.odin`
- `tools/pty_host/src/daemon.rs`
- `tools/pty_host/src/host.rs`

### 3.2 Audit Findings & Remediations by Vector

#### Vector 1: Heap Allocations & Long-Lived Loops
1. **Hub Shell Handlers (`shell_session_handlers.odin:57, 219`)**:
   - In raw WebSocket upgrade routes (`shell_session_stream_handler` and `shell_session_preview_proxy_handler`), `session` was retrieved from repository on persistent heap (15 heap strings in `domain.Shell_Session`).
   - **Remediation**: Added `defer domain.shell_session_destroy(session)` at top of both handlers to guarantee complete deallocation upon connection termination.
2. **Hub Tunnel Service (`shell_session_service.odin:660-716`)**:
   - Data chunks and tunnel streams are allocated using `runtime.heap_allocator()`.
   - **Remediation**: In `shell_session_tunnel_unregister` and `shell_session_tunnel_deliver`, explicit deallocations using the heap allocator (`delete(k, heap)`, `delete(chunk, heap)`, `free(stream, heap)`) were implemented to ensure allocator consistency across thread contexts.
3. **Bridge PTY Host Socket Path Caching (`pty_host_runtime.odin:65, 87-92`)**:
   - **Vulnerability**: `pty_host_socket_path()` was invoked repeatedly on polling loops and keystrokes, allocating a new string on each invocation.
   - **Remediation**: Cached `pty_host_daemon_socket` under `pty_host_daemon_lock` to eliminate allocation churn.
4. **Bridge PTY Host Event Worker Reconnection (`pty_host_events.odin:111`)**:
   - Added `delete(socket)` in `bridge_pty_host_events_worker` reconnection loop.
5. **Bridge Shell Command Execution & Path Helpers (`shell_cmd.odin:74, 76, 85, 438, 444-446`)**:
   - Added defer cleanups for `session_id`, `output_path`, and `start_time` in `bridge_shell_cmd_exec`.
   - Added explicit deallocation of `data_dir` in `bridge_shell_jobs_dir` and `jobs_dir` in `bridge_shell_output_path`.
6. **Bridge Wrapper Endpoint Client Workers (`wrapper_endpoint.odin:129-131, 185-187, 616`)**:
   - Added `defer delete(needle)` in `bridge_local_extract_json_object`.
   - Added `defer delete(resp)` and `defer delete(resp_line)` in Unix and TCP client thread loops.

#### Vector 2: Socket & FD Lifecycle Invariants (Commit `db0db5c3`)
1. **Preview Proxy Pump Thread Lifecycle (`shell_session_handlers.odin:280-281`)**:
   - `pump_thread` is explicitly joined (`thread.join(pump_thread)`, `thread.destroy(pump_thread)`) before the handler returns (`defer net.close(client)`), preventing concurrent read/close races.
2. **Tunnel Stream Socket Shutdown (`hub_runtime_client.odin:780-798`)**:
   - `bridge_hub_handle_tunnel_close` issues `net.shutdown(stream.tcp_conn, .Receive)` to safely unblock reader threads, delegating final `net.close(local_tcp_conn)` to `bridge_tunnel_tcp_to_ws_worker`.
3. **Local Proxy Client Wakeup (`local_proxy.odin:110-140`)**:
   - `bridge_proxy_wake_client` shuts down read only; server worker threads own the client socket with `defer net.close(client)`.

#### Vector 3: PTY Process & Child Lifecycle
1. **Child Process Reaping (`tools/pty_host/src/host.rs:183`)**:
   - Dedicated `wait_thread` invokes `child.wait()` (waitpid), immediately reaping exited processes and preventing zombies.
2. **Graceful Termination Escalation (`tools/pty_host/src/daemon.rs:168-191`)**:
   - `Agent::shutdown()` issues `SIGTERM`, waits 1s (`TERM_GRACE`), escalates to `SIGKILL`, joins worker threads, and closes master/writer descriptors.
3. **Process Group Signals (`src/bridge/shell_cmd.odin:90-100`)**:
   - Uses `setsid` so spawned shells become process group leaders, allowing clean group termination with `kill(-pgid, SIGKILL)` on timeout.
4. **PID Reuse Prevention (`src/bridge/bridge_shell_session.odin:416-445, 472-526`)**:
   - Orphan kill worker verifies executable name and `lstart` within 5s before `SIGTERM` and re-verifies before `SIGKILL`.

### 3.3 Backend Test Guard
- Guard file: `tests/test_backend_shell_leak_prevention_static.py` (7/7 suites green).

---

## 4. Comprehensive Verification Battery Results

All tests executed cleanly with zero failures:

| Test Suite | Command | Result |
| :--- | :--- | :--- |
| **Frontend Typecheck** | `npm run typecheck` (`tsc -b`) | **PASS** (0 diagnostics) |
| **UI Native Select Guard** | `python3 tests/ui_no_native_select_test.py` | **PASS** |
| **UI Mobile Layout Guard** | `python3 tests/test_ui_preview_mobile_layout_static.py` | **PASS** |
| **UI Preview Leak Guard** | `python3 tests/test_ui_preview_leak_prevention_static.py` | **PASS** (4/4 suites) |
| **Backend Shell Leak Guard** | `python3 tests/test_backend_shell_leak_prevention_static.py` | **PASS** (7/7 suites) |
| **Fig CitC Bridge Relay** | `python3 tests/test_fig_bridge_citc_relay.py` | **PASS** |
| **Fig Frontend & Picker** | `python3 tests/test_fig_frontend.py` | **PASS** |
| **Fig Workspace Integration** | `python3 tests/test_fig_workspace_integration.py` | **PASS** (REQ-FIG-8) |
| **Cloudtop Edge Gateway** | `python3 tests/test_cloudtop_edge_gateway_uberproxy.py` | **PASS** (CT-7) |
| **Cloudtop Proxy LOAS & Trust** | `python3 tests/test_cloudtop_proxy_loas_and_trust.py` | **PASS** (CT-3, CT-4) |
| **Cloudtop Audit Mode Static** | `python3 tests/test_cloudtop_audit_mode_and_proxy_static.py` | **PASS** (CT-3, CT-4) |
| **Cloudtop Auto-Pair Security** | `python3 tests/test_cloudtop_auto_pair_security_static.py` | **PASS** (CT-1, CT-2) |
| **Cloudtop Port Conflict & IPv6** | `python3 tests/test_cloudtop_port_conflict_and_dual_stack.py` | **PASS** (CT-17) |
| **Cloudtop Jetski Auto-Enroll** | `python3 tests/test_cloudtop_jetski_auto_enroll.py` | **PASS** (CT-10) |
| **Local Directory Picker** | `python3 tests/test_local_directory_picker.py` | **PASS** (CT-13) |
| **Odin Hub Check** | `odin check src/hub -collection:odin_test=src` | **PASS** |
| **Odin Bridge Check** | `odin check src/bridge -collection:odin_test=src` | **PASS** |
| **Odin Dev Proxy Check** | `odin check src/dev_proxy -collection:odin_test=src` | **PASS** |
| **Odin Control CLI Check** | `odin check src/ctl -collection:odin_test=src` | **PASS** |
| **Odin Hub Transport Tests** | `odin test src/hub/transport/http` | **PASS** (67/67 tests) |
| **Odin Bridge Tests** | `odin test src/bridge -define:ODIN_TEST_THREADS=1` | **PASS** (251/251 tests) |

---

## 5. Conclusion & Invariant Summary

The shell sessions and preview proxy subsystems now satisfy all architectural invariants:
1. No unmanaged event listeners on `window` or embedded `iframe.contentWindow`.
2. Explicit capping on in-memory history stacks (`MAX_NAV_STACK = 50`).
3. Complete termination of iframe execution context (`about:blank`) on unmount.
4. Guaranteed cleanup of heap-allocated session domain entities on handler return.
5. Strict socket closure ownership conforming to commit `db0db5c3`.
6. Complete reaping of child processes in PTY host and shell command workers.
