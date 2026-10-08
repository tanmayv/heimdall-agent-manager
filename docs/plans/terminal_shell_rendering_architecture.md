# Architectural Design: Terminal Shell Rendering, Initial Cursor Positioning, and Tab State Persistence

**Document Status:** Design & Improvement Plan  
**Target Systems:**  
- Hub Transport & Shell Stream Handlers (`src/hub/transport/http`: Odin)  
- Bridge Runtime Client & PTY Stream Worker (`src/bridge`: Odin / Rust)  
- Frontend Terminal Components & Stream Hooks (`src/ui`: TypeScript / React)  

---

## 1. Executive Summary

This document specifies the technical design to resolve three critical deficiencies in Heimdall's interactive shell and terminal rendering infrastructure:

1. **Incorrect Initial Cursor Placement (Bottom-of-Screen Cursor):**  
   On startup or initial connection, the terminal cursor frequently appears at the very bottom row of the screen rather than at the active prompt line.
2. **TUI Application Glitches on Launch (e.g., Neovim requiring a tab switch to render):**  
   Full-screen terminal user interface (TUI) programs (such as Neovim or Curses applications) fail to render properly on initial launch and only snap into a usable display after switching away to another tab and switching back.
3. **Loss of Scrollback & Background State on Tab Switch:**  
   When navigating away from an active shell session in the dock or detail pane, the terminal component is unmounted and the WebSocket is disconnected. All accumulated VT100 scrollback history is lost, and background execution output while the tab is hidden is dropped or replaced with an isolated 24-row viewport capture upon return.

This specification details the root causes across the Hub, Bridge, and UI layers, and outlines two complementary architectural patterns (a zero-overhead DOM Keep-Alive model and an industry-standard Client Terminal Store with `@xterm/addon-serialize`) to achieve robust, high-performance terminal rendering.

---

## 2. Root Cause Analysis

### 2.1 Initial Cursor Position at Bottom of Screen

The bottom-of-screen cursor bug is caused by a compound interaction between the Hub's screen snapshot formatting and the UI's scroll enforcement:

```text
Hub Screen Snapshot               CRLF Row Expansion                  xterm.js Processing
───────────────────               ──────────────────                  ───────────────────
Captured Grid (e.g. 24 rows) ───> Rewrites bare '\n' to '\r\n'  ───> Writes 24 lines sequentially
Row 1: prompt                     Includes 23 trailing blank rows     Cursor advances to Row 24
Rows 2-24: blank                  (shell_stream_screen_snapshot.odin) ShellTerminalPane.tsx:
                                                                      scrollToBottom() forces viewport
```

1. **Hub Snapshot Row Padding (`src/hub/transport/http/shell_stream_screen_snapshot.odin:77-98`):**  
   When a viewer attaches and sends an initial geometry frame, the Hub requests a screen capture of the PTY grid from the bridge (`shell_session_get_pane`). The grid is formatted as a single string of rows joined by `\n` (`_shell_screen_lf_to_crlf`). For a typical 24-row terminal where only line 1 has text, lines 2–24 are emitted as blank lines. Each `\r\n` advances the cursor down by one row. By the time the snapshot is fully parsed by `xterm.js`, the cursor is positioned at row 24 (the bottom of the screen).
2. **Omission of Explicit Cursor Restoration (`\x1b[row;colH`):**  
   The Hub prepends `\x1b[2J\x1b[H` (erase screen and home cursor) to the snapshot frame, but does not append the PTY host's actual cursor coordinates at the end of the text. Consequently, the cursor remains wherever the last newline left it.
3. **Unconditional `scrollToBottom()` on Mount (`ShellTerminalPane.tsx:98-101`):**  
   ```typescript
   onOutput: (bytes) => {
     const term = terminalRef.current;
     if (!term) return;
     term.write(bytes);
     if (!userScrolledUpRef.current) {
       term.scrollToBottom();
     }
   }
   ```
   On a newly opened terminal, `userScrolledUpRef.current` is `false`. When the snapshot payload is written, `term.scrollToBottom()` is triggered, forcing the viewport down even if the content has not overflowed the initial viewport.

---

### 2.2 TUI (Neovim) Rendering Glitch on Launch

The failure of TUI applications like Neovim on initial launch stems from a timing race between initial window sizing, alternate screen buffer activation, and snapshot delivery:

1. **Geometry Race on Startup:**  
   When `ShellTerminalPane` mounts:
   - `new Terminal()` defaults in memory to `80x24`.
   - The WebSocket connection to `/api/v1/shells/{id}/stream` connects asynchronously.
   - Neovim starts on the bridge and immediately issues `\x1b[?1049h` (switch to alternate screen buffer) and full-screen cursor addressing.
2. **Snapshot Colliding with Alternate Screen Buffer:**  
   Once the WebSocket opens, `useShellStream.ts:sendGeometry` sends the initial measured geometry. The Hub's `shell_session_stream_handler` responds by triggering `shell_stream_send_shell_screen_snapshot`, which emits `\x1b[2J\x1b[H` (clear normal screen) followed by a captured screen grid. If this grid capture is taken while the PTY host is transitioning between the normal and alternate screen buffers, the snapshot corrupts the TUI frame.
3. **Why a Tab Switch Temporarily "Fixes" It:**  
   When the user switches tabs and returns, the shell session is already running with an established PTY geometry. The newly mounted `ShellTerminalPane` establishes a fresh WebSocket; the Hub calls `shell_session_get_pane`, which captures the stable, already-rendered Neovim alternate buffer at the exact container dimensions, painting it cleanly.

---

### 2.3 Loss of Scrollback and Background State on Tab Switch

The loss of background state across tab switches is directly caused by complete component unmounting:

```text
Current Dock Navigation:
Tab A (Active) ──> Switch to Tab B ──> ShellTerminalPane(A) unmounts
                                       ├── term.dispose() [Canvas & scrollback destroyed]
                                       └── socket.close() [WebSocket severed]

Tab A is now completely disconnected from the browser.
Background jobs continue on Bridge, but browser receives NO chunks.

Return to Tab A ──> ShellTerminalPane(A) mounts fresh
                    ├── new Terminal() [Blank buffer]
                    ├── new WebSocket connects
                    └── Hub sends single 80x24 screen snapshot [All prior history lost]
```

1. **Keyed Remounts in `BottomDock.tsx:545-553`:**  
   The dock renders only the currently active shell:
   ```tsx
   <ShellTerminalPane
     key={activeSession.session_id}
     session={activeSession}
     ...
   />
   ```
   Switching tabs completely unmounts the previous session's pane.
2. **Destruction of `Terminal` and WebSocket:**  
   - `term.dispose()` discards all rendered DOM elements and in-memory VT100 scrollback lines.
   - `useShellStream.ts`'s cleanup effect executes `closeSocket()`. The Hub detaches the viewer (`shell_session_detach`).
   - If the shell was running a long compiler job, test suite, or server process, all intermediate output generated while the user viewed another tab is lost forever. When the user returns, the Hub's `screen` snapshot only restores the current 24-row viewport, leaving the user with zero historical scrollback.

---

## 3. Architecture & Improvement Options

To solve these issues, two complementary architectural approaches are proposed:

---

### Solution 1: DOM Keep-Alive (Immediate, Low Overhead, Recommended for Dock)

Rather than destroying the React component and disconnecting the WebSocket on every tab switch, the bottom dock keeps the mounted `ShellTerminalPane` instances alive in the DOM, toggling visibility via CSS.

```text
┌────────────────────────────────────────────────────────────────────────┐
│ BottomDock Container                                                  │
│                                                                        │
│  ┌───────────────────────┐ ┌───────────────────────┐                  │
│  │ Shell 1 (Active)      │ │ Shell 2 (Inactive)    │                  │
│  │ style="display: block"│ │ style="display: none" │                  │
│  │ WebSocket: OPEN       │ │ WebSocket: OPEN       │                  │
│  │ xterm: LIVE           │ │ xterm: LIVE           │                  │
│  └───────────────────────┘ └───────────────────────┘                  │
└────────────────────────────────────────────────────────────────────────┘
```

#### Implementation Details:
1. **Multi-Session Rendering in `BottomDock.tsx`:**  
   Replace conditional single-pane rendering with a mapped container list:
   ```tsx
   {visibleSessions.map((session) => {
     const isActive = activeTab === session.session_id;
     return (
       <div
         key={session.session_id}
         className="h-full w-full"
         style={{ display: isActive ? 'block' : 'none' }}
         aria-hidden={!isActive}
       >
         <ShellTerminalPane
           session={session}
           isBridgeUnreachable={Boolean(session.bridge_id && !isBridgeReachable(session.bridge_id))}
           onClose={() => handleKillSession(session.session_id)}
         />
       </div>
     );
   })}
   ```
2. **Visibility Resize Re-triggering:**  
   When a pane transitions from `display: none` to `display: block`, `ResizeObserver` automatically detects the container dimension change from $0 \times 0$ to its visible dimensions, invoking `fitAddon.fit()` and refreshing the layout.
3. **Benefits:**
   - **Zero Reconnect Overhead:** Switching between tabs is instantaneous (sub-1ms DOM toggle).
   - **Full Background Continuity:** Background compilations, tests, and logs continue streaming directly into xterm's buffer while viewing other tabs.
   - **Zero Scrollback Loss:** Native scrollback remains intact.
   - **Neovim Continuity:** Neovim never undergoes a disconnect or re-attach cycle during dock navigation.

---

### Solution 2: Client Terminal Store with `@xterm/addon-serialize` (Full Decoupled Architecture)

For views where DOM retention is impractical (e.g., navigating across completely different routes, such as moving from the Dashboard to the Settings page or closing and reopening drawers), adopt the **Snapshot + Delta** pattern.

```text
┌────────────────────────────────────────────────────────────────────────┐
│                       Client Terminal Registry                         │
│       Keeps background WebSocket streams and session state open        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (persists across route changes)
┌───────────────────────────────────▼────────────────────────────────────┐
│                       Session Stream Controller                        │
│   - Holds: active WebSocket connection                                 │
│   - Holds: serializedSnapshot (from @xterm/addon-serialize)            │
│   - Holds: deltaBuffer (incoming bytes received while unmounted)       │
│   - Holds: savedViewportY (scroll position)                            │
└──────────────┬───────────────────────────────────▲─────────────────────┘
  (mount)      │ restores:                         │ saves on
  creates      │ initialData = snapshot + delta    │ unmount
┌──────────────▼───────────────────────────────────┴─────────────────────┐
│                       ShellTerminalPane (UI)                           │
│   - On Mount: instantiates Terminal & SerializeAddon                   │
│   - Replays initialData() before opening live stream writes            │
│   - On Unmount: captures serializer.serialize()                        │
└────────────────────────────────────────────────────────────────────────┘
```

#### Step 1: Package Dependency
Add `@xterm/addon-serialize` to `package.json`:
```json
"dependencies": {
  "@xterm/addon-fit": "^0.11.0",
  "@xterm/addon-serialize": "^0.13.0",
  "@xterm/xterm": "^6.0.0"
}
```

#### Step 2: Unmount Snapshotting in `useXterm` / `ShellTerminalPane`
Before calling `term.dispose()`, capture the exact rendered grid and scrollback:
```typescript
const serializer = new SerializeAddon();
term.loadAddon(serializer);

// On unmount:
return () => {
  if (serializer && isFlushedRef.current) {
    const serializedHistory = serializer.serialize();
    terminalStore.setSnapshot(sessionId, serializedHistory);
    terminalStore.setSavedScrollY(sessionId, term.buffer.active.viewportY);
  }
  term.dispose();
};
```

#### Step 3: Delta Accumulation While Unmounted
While the component is unmounted, the background WebSocket stream remains active in the `TerminalStore`:
```typescript
class TerminalSession {
  private snapshot = '';
  private delta = '';

  onStreamOutput(chunk: string) {
    if (this.isMounted) {
      this.activeTerminal?.write(chunk);
    } else {
      this.delta += chunk;
      if (this.delta.length > MAX_DELTA_BYTES) {
        this.delta = this.delta.slice(this.delta.length - MAX_DELTA_BYTES);
      }
    }
  }

  getInitialData(): string {
    return this.snapshot + this.delta;
  }

  setSnapshot(snapshot: string) {
    this.snapshot = snapshot;
    this.delta = '';
  }
}
```

#### Step 4: Gated Flush on Remount
On remount, prevent duplicate writes by gating incoming stream chunks until the snapshot has been applied:
1. Instantiate new `Terminal`.
2. Open into DOM container and execute initial `fitAddon.fit()`.
3. Flush `getInitialData()` into xterm via `term.write(data, callback)`.
4. Restore scroll offset: `term.scrollToLine(savedViewportY)`.
5. Enable live streaming writes.

---

### 2.4 Fixing Initial Cursor Position (Concrete Steps)

#### 1. Smart Scrollback Pinning (`ShellTerminalPane.tsx`)
Do not scroll to bottom if the buffer has not exceeded the viewport height (`buffer.baseY === 0`):
```typescript
onOutput: (bytes) => {
  const term = terminalRef.current;
  if (!term) return;
  term.write(bytes);

  const buffer = term.buffer.active;
  // Only scroll down if content has pushed lines into the scrollback history
  if (!userScrolledUpRef.current && buffer.baseY > 0) {
    term.scrollToBottom();
  }
}
```

#### 2. Trimming Trailing Blank Lines on Hub Snapshot (`src/hub/transport/http/shell_stream_screen_snapshot.odin`)
Modify `_shell_screen_repaint_text` to strip non-informative trailing blank rows from the snapshot so the cursor does not get pushed to the bottom of the screen:
```odin
_shell_screen_trim_trailing_blank_rows :: proc(s: string) -> string {
    // Strip trailing empty lines (\n, \r\n, spaces) before formatting
    trimmed := strings.trim_right_space(s)
    return strings.clone(trimmed)
}
```

#### 3. Append Explicit Cursor Positioning Escape Sequence
When `vt.rs` captures the PTY grid, query the active cursor coordinates `(cursor_row, cursor_col)` and append an ANSI cursor-position sequence (`\x1b[<row>;<col>H`) to the end of the `screen` frame payload. This guarantees that regardless of how many rows were emitted, the cursor snaps precisely to the prompt location.

---

### 2.5 Fixing TUI / Neovim Initial Launch (Concrete Steps)

#### 1. Geometry-First Initialization Gate
In `ShellTerminalPane.tsx`, withhold sending initial input or consuming live output until the terminal container has been measured and the initial resize frame dispatched:
```typescript
const [isSized, setIsSized] = useState(false);

const dispatchResize = () => {
  if (container.clientWidth > 0 && container.clientHeight > 0) {
    fitAddon.fit();
    term.resize(Math.max(term.cols, 40), term.rows);
    handleResizeRef.current(term.rows, term.cols);
    setIsSized(true);
  }
};
```

#### 2. Synchronous First Resize Frame
Ensure `sendGeometry` in `useShellStream.ts` sends the true container geometry inside `socket.onopen` before any keystrokes or screen captures are processed, allowing the child process (`nvim`) to receive `SIGWINCH` with the exact dimensions before it paints its initial frame.

---

## 4. Verification & Testing Plan

1. **Cursor Position Verification:**
   - Launch a fresh bash/zsh shell session in `BottomDock`.
   - Verify cursor is positioned directly at the end of the first prompt line (e.g. `user@host:~$ █`), NOT at the bottom of the screen.
   - Verify horizontal scrolling and typing work without jumping.
2. **Neovim Launch Verification:**
   - Run `nvim` in an active shell session.
   - Verify Neovim status bar, line numbers, and splash buffer render cleanly on first frame without requiring tab switching.
   - Verify switching tabs in the dock and returning keeps Neovim active, intact, and responsive.
3. **Tab Switch & Background Persistence:**
   - In Shell 1, execute `for i in $(seq 1 100); do echo "count $i"; sleep 0.1; done`.
   - Immediately switch to Shell 2 while Shell 1 is running.
   - Wait 5 seconds, then switch back to Shell 1.
   - Verify that all counts (1 through 100) are visible and preserved in xterm's scrollback history.
   - Verify user can scroll up to the initial command line without history clipping or loss.
4. **Automated Unit & Contract Tests:**
   - Add unit test in `tests/ui_shell_streaming_test.ts` verifying that `BottomDock` preserves mounted panes across tab selection changes.
   - Verify `shellResizeFrame` geometry dispatch order remains intact.
   - Run existing suite (`npm test`) to ensure zero regressions in fleet actions, settings modals, and vault encryption.
