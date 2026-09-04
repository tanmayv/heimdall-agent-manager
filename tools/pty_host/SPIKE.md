# ham-pty-host — spike report (PTYH-1..5)

A standalone Rust binary that hosts a child process under a PTY, maintains a live
VT screen model, serves attach/detach clients over a unix socket, and ships an
in-app split-screen debug TUI. **No Heimdall integration in this spike** — it is
a self-contained probe to decide whether to fold PTY hosting into the Heimdall
bridge/wrapper.

- Crate: `tools/pty_host/` (kept **out** of the Odin build tree).
- ~3.4k lines Rust, 38 unit/integration tests.
- Branch: `feat/pty-host`.

## TL;DR recommendation: **GO** (with scoped follow-ups)

The approach is sound and maps cleanly onto Heimdall's needs: a persistent host
process owning the PTY + VT model, with thin attach clients that can come and go
without disturbing the child. `portable-pty` + `vte` + `ratatui` are the right
building blocks. The main gaps before production are (1) alternate-screen buffer
modeling, (2) per-cell style on the wire, and (3) hardening the socket protocol
(auth/limits). None are blockers for the concept; all are well-understood work.

---

## Chosen crates + why

| Crate | Version | Role | Why |
|-------|---------|------|-----|
| `portable-pty` | 0.9 | PTY master/slave, spawn, resize, kill | Cross-platform (macOS/Linux/Windows-ConPTY), maintained (wezterm), exposes `clone_killer()` needed for clean shutdown of interactive children. |
| `vte` | 0.15 | VT/ANSI parser | Small, fast, `Perform` trait lets us own the screen model + capture format. Chosen over `alacritty_terminal` to keep the dependency surface small and control the exact `Capture`/`Screen` representation. Trade-off: we hand-write the grid (cursor, erase, SGR, scroll, autowrap) — done and tested — whereas `alacritty_terminal` would give a full grid + alt-screen for free but pulls a much larger dep tree. |
| `ratatui` + `crossterm` | 0.30 / 0.29 | In-app debug TUI | The task mandated ratatui+crossterm. crossterm gives raw mode + key events + alt-screen; ratatui gives the split layout/widgets. Clean, portable, no curses. |
| `clap` | 4 | CLI | Standard. |
| `anyhow` | 1 | Errors | Ergonomic for a spike/tool. |
| `libc` | 0.2 | termios raw mode, winsize, SIGWINCH | Only in the `attach` client's local-terminal control. |

**Considered but not used:** `alacritty_terminal` (heavier; would resolve the
alt-screen gap — see follow-ups), `tokio` (the host is naturally thread-per-role;
blocking std threads kept it simple and dependency-light), `serde`/`bincode`
(the wire protocol is hand-rolled and fully explicit — see PROTOCOL.md).

---

## Architecture

```
                        ham-pty-host run --socket S -- <argv>
   +---------------------------------------------------------------+
   |  HostServer (server.rs)                                        |
   |                                                               |
   |   PtyHost (host.rs) ── portable-pty ── child (zsh / pi / ...) |
   |     │  reader thread: PTY bytes ─▶ VtEngine (vt.rs)  ─▶ Screen|
   |     │  wait thread:  reap child ─▶ exit code                   |
   |     ▼                                                          |
   |   fan-out thread ── raw Output ─▶ every attached client       |
   |   accept loop ── per client: reader+writer threads            |
   +----------------------────────────────────────────────────────+
                          ▲ unix socket (framed protocol, proto.rs)
            ┌─────────────┴───────────────┐
     attach client (client.rs)       debug TUI (debug_ui.rs + debug_tui.rs)
     raw passthrough, Ctrl-\ detach  split view from Screen frames
```

Design choices that paid off:
- **Pure state machine for the TUI** (`debug_tui.rs`): all key→action logic is
  unit-tested without a terminal; `debug_ui.rs` is a thin crossterm/ratatui shell.
- **Shared `VtEngine` behind a mutex**: `capture()` is available to the socket
  server, the passthrough client, and the TUI uniformly.
- **`clone_killer()` for shutdown**: an interactive child keeps the PTY open
  forever, which would deadlock the fan-out join on `recv()`. Killing the child
  on `shutdown()` closes the PTY → reader hits EOF → sender drops → join returns.

---

## The protocol

Length-prefixed binary frames over a unix socket; first payload byte is a tag.
Full spec in [PROTOCOL.md](./PROTOCOL.md). Summary:

- **client→host**: Attach, Input{bytes}, Key{named}, Resize{rows,cols}, Capture, Detach, Ping
- **host→client**: Output{bytes}, Screen{grid,cursor}, ChildExited{code}, Pong

Named keys (Enter/Esc/Ctrl-C/Tab/arrows/…) are expanded host-side to xterm byte
sequences so terminal apps see exactly what a real keyboard produces.

---

## How to run

```bash
# from tools/pty_host (dev): a Rust toolchain is provided by `nix develop`
nix develop            # gives cargo/rustc/rustfmt/clippy
cargo build
cargo test -- --test-threads=1     # server tests bind sockets; run serially

# or the packaged binary:
nix build .#ham-pty-host

# 1) host a shell
./target/debug/ham-pty-host run --socket /tmp/ham.sock -- /bin/zsh -l

# 2a) attach (raw passthrough); Ctrl-\ detaches, child survives
./target/debug/ham-pty-host attach --socket /tmp/ham.sock

# 2b) attach with the in-app split-screen debug TUI
./target/debug/ham-pty-host attach --socket /tmp/ham.sock --debug
#     F2 toggles PANE<->SIDEBAR focus; F10 detaches+quits.
```

See [DEBUG_TUI.md](./DEBUG_TUI.md) for the TUI layout + controls.

---

## What worked (evidence)

**cargo test: 38 passed** (11 vt · 4 host · 5 proto · 5 server · 13 debug_tui).

**zsh smoke** (`evidence/smoke_zsh.txt`) — send-keys / capture / detach → survive → re-attach:
```
[1] send-keys+capture OK: 'ZSH_ONE' visible
[2] detaching client #1 (Ctrl-\ equivalent)...
[3] re-attaching as client #2 to same live zsh...
[3a] state restored on re-attach: prior 'ZSH_ONE' still present
[3b] re-attached client drives child OK: 'ZSH_TWO' visible
[4] child exit broadcast: ChildExited(0)
```

**pi smoke** (`evidence/smoke_pi.txt`) — full-screen TUI under the host:
```
[1] pi TUI rendered in Capture: 27 non-blank lines
    | pi v0.74.0
    | escape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ! bash · ctrl+o more
    ...
    | $0.000 (sub) 0.0%/1.0M (auto)   (anthropic) claude-opus-4-8 • high
[2] pi responded to Input (typed text visible in TUI): True
    | hello pi from ham-pty-host
[3] detached from pi (child left running)
```

**debug TUI** (`evidence/debug_tui_capture.txt`) — live split view driving zsh
via both pane focus and the sidebar Send-Keys/Capture widgets.

**nix** — `nix build .#ham-pty-host` produces a self-contained binary (macOS
linkage: only `libiconv` + `libSystem`); `nix develop` provides rustc/cargo 1.95.

---

## Edge cases & gotchas learned

- **Interactive-child shutdown deadlock** — fixed via `clone_killer()` (above).
  Any design that hosts a long-lived shell must have an explicit kill path;
  waiting on EOF alone hangs.
- **Alt-screen re-attach** — a raw-passthrough client only receives *new* bytes
  on re-attach, so a full-screen app (vim, pi) doesn't repaint until an event
  makes it redraw. Two mitigations, both demonstrated: send a Resize (SIGWINCH)
  to force a repaint, or use the **debug TUI**, whose left pane renders from the
  **VT model** (Screen frames) and therefore always shows current state.
- **Resize must update PTY *and* model together** — `PtyHost::resize()` does
  both; updating only the PTY leaves the grid stale.
- **Login shell** — argv `-l` matters for zsh to source the user's profile
  (PATH, prompt). We pass `-l` for `*sh` when no args are given.
- **Env hygiene** — we drop `TERM_PROGRAM`, `COLUMNS`, `LINES`, `TMUX*`, `STY`
  and force `TERM=xterm-256color` + `COLORTERM=truecolor` so children behave as
  on a fresh terminal.
- **Exit codes** — signal deaths surface as 128+signal (e.g. Ctrl-C → 130); the
  host broadcasts `ChildExited(code)` and `run` exits with it.
- **Nix sandbox has no PTY / no `/bin/sh`** — PTY/shell tests skip gracefully via
  a real end-to-end probe so `cargo test` is green both locally and hermetically.
- **Server tests need `--test-threads=1`** — they bind sockets + spawn shells;
  parallel runs contend. crane is configured accordingly.
- **`vte` params** — SGR `38;5;n` / `38;2;r;g;b` must be parsed as a single run
  across sub-params; the parser looks ahead rather than treating each as a param.

---

## Known fidelity limits (VT model)

Single **primary** grid covering the common interactive subset: text, cursor
moves (CUU/CUD/CUF/CUB/CHA/VPA/CUP), ED/EL erases, SGR 16/256/truecolor + bold,
scroll, autowrap, DECSC/DECRC, IND/RI, RIS. Not yet modeled:

1. **Alternate screen buffer** (`\e[?1049h`) — not a separate buffer, so
   switching back from a full-screen app doesn't restore the prior primary
   screen. Full-screen apps still render (they repaint absolute cells).
2. **Scrollback** — only the visible viewport; scrolled-off lines are gone.
3. **Style on the wire** — the `Screen` frame carries rendered *text* lines; the
   full styled cell grid exists in-process (`capture().cells`) but isn't yet
   serialized. Italic/underline/reverse/blink are parsed-but-dropped.
4. **Wide glyphs** — CJK/emoji count as one cell (possible 1-col misalignment).

---

## Go/No-Go for folding into the Heimdall bridge/wrapper

**Recommendation: GO.** The spike proves the core: a persistent host owning the
PTY + VT model with detachable clients, driving real interactive programs
(`zsh`, `pi`) correctly, packaged hermetically via Nix.

Fit with Heimdall: the wrapper already manages agent processes under tmux; a
`ham-pty-host`-style host could replace/augment that with a first-class VT model
and a documented socket protocol the bridge/UI can consume (Screen frames map
naturally to a web/electron pane view — without a browser dependency in the host
itself).

**Before production, scope these follow-ups (rough order):**
1. **Alternate-screen buffer** — either add a second grid + swap on `?1049h/l`,
   or adopt `alacritty_terminal`'s grid to get alt-screen + scrollback for free.
   Biggest fidelity win for full-screen agents.
2. **Serialize per-cell style** in the `Screen` frame (fg/bg/attrs) so remote
   renderers show color; the data already exists in-process.
3. **Protocol hardening** — socket auth/permissions (0600 + peer-cred check),
   frame-rate/backpressure limits, versioning handshake.
4. **Lifecycle integration** — map host start/stop, child exit, and re-attach to
   the wrapper's activity-status + supervision model; decide ownership vs tmux.
5. **Windows/ConPTY** — `portable-pty` supports it, untested here.
6. **Diff-based Screen updates** — send row diffs instead of full snapshots for
   large/fast screens (the ~120ms full-capture refresh is fine for a debug TUI,
   not for many concurrent production panes).
