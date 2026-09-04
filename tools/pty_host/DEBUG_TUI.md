# In-app debug TUI (PTYH-3)

`ham-pty-host attach --socket <path> --debug` renders a native split-screen
debug console with **ratatui + crossterm**. There is **no browser, no
websocket, no Heimdall UI** — the sidebar lives entirely inside this binary.

```
+----------------------------------------------------------------+
|  ham-pty-host  debug TUI · focus: PANE  [F2] toggle  [F10] quit |
+-----------------------------+----------------------------------+
| live pane (VT model)        | debug sidebar                    |
|                             |  ┌ Send Keys (Enter=send) ┐      |
|  ~                          |  └────────────────────────┘      |
|  ❯ ls -la | head            |  ┌ Named Key (↑↓, Enter) ┐       |
|  total 2936                 |  │ ▶ Enter                │       |
|  drwxr-x---  147 ...        |  │   Esc / Ctrl-C / Tab   │       |
|  ...                        |  │   Up / Down            │       |
|                             |  └────────────────────────┘      |
|                             |  ┌ Resize ROWSxCOLS ┐            |
|                             |  └──────────────────┘            |
|                             |  ┌ Capture (Enter=snapshot) ┐    |
|                             |  │ #1: 24x80 cur(6,2) 5ln    │    |
|                             |  └───────────────────────────┘    |
+-----------------------------+----------------------------------+
|  status line (last action / child-exit)                        |
+----------------------------------------------------------------+
```

## Controls

| key            | effect |
|----------------|--------|
| **F2**         | toggle focus between **PANE** and **SIDEBAR** |
| **F10**        | detach + quit (child keeps running) |
| Tab / Shift-Tab| (SIDEBAR focus) cycle the active widget |

### PANE focus
Keystrokes are translated to terminal byte sequences and sent to the child as
`Input` — i.e. you drive the program directly, just like the raw `attach`
client. Arrow keys, Ctrl-<letter>, Enter, Esc, Backspace, Home/End, PgUp/PgDn,
Delete are all mapped.

### SIDEBAR focus
- **Send Keys** — type a line, press Enter to send it (with a trailing `\n`) as
  `Input`.
- **Named Key** — ↑/↓ to pick Enter/Esc/Ctrl-C/Tab/Up/Down, Enter to send it as
  a `Key` message (the host expands it to the correct bytes).
- **Resize** — type `ROWSxCOLS` (e.g. `40x120`), Enter to send a `Resize`.
- **Capture** — Enter snapshots the current VT screen (rows/cols/cursor/
  non-blank-line count) into the sidebar history and requests a fresh `Screen`.

## Why the left pane renders from the VT model

The left pane is drawn from **`Screen` frames** (the VT grid captured by the
host), requested on a ~120 ms timer via `Capture`, **not** from the raw `Output`
byte stream. This is deliberate:

- On attach it repaints the full current screen immediately.
- It is immune to the alt-screen "no redraw until the app repaints" limitation
  that the raw-passthrough `attach` client has: because we render the host's
  grid, we always show current state even for full-screen apps.

## Alt-screen / sub-viewport fidelity limits

The VT model in `vt.rs` is a **single primary grid** and covers the common
interactive subset (text, cursor movement, ED/EL erases, SGR colors, scroll,
autowrap, save/restore cursor). Known limitations, to be weighed in the spike
go/no-go:

1. **Alternate screen buffer (`\e[?1049h`)** is not modeled as a separate
   buffer. Full-screen apps (vim, `pi`) that switch to the alt-screen still
   render, because they repaint absolute cells into the same grid, but:
   - switching back from alt-screen does **not** restore the previous primary
     screen contents (we don't keep two buffers);
   - the debug TUI's own timer-driven `Capture` reflects whatever the app last
     painted.
2. **No scrollback** — only the visible viewport is modeled; content scrolled
   off the top is gone (matches a real fixed-size terminal, but there's no
   history buffer).
3. **Styling coverage** — SGR handles 16/256/truecolor + bold; other attributes
   (italic, underline, reverse, blink) are parsed-but-dropped in the grid model.
   The debug TUI's left pane currently renders text without per-cell color (the
   `Screen` wire frame carries rendered *text* lines); the full styled grid is
   available in-process via `capture().cells` and could be added to the frame.
4. **Wide (CJK / emoji) glyphs** occupy one cell in the model, so double-width
   characters can shift alignment by one column.

These are acceptable for a debug/inspection console and are the main items to
resolve if `ham-pty-host` is folded into the Heimdall bridge/wrapper (see
SPIKE.md).
