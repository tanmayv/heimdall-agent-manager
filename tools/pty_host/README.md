# ham-pty-host

A standalone Rust spike (chain: PTY host + attach/detach + in-app debug TUI).
Hosts a child process under a PTY, maintains a live VT screen model, serves
attach/detach clients over a unix socket, and ships an in-app split-screen debug
TUI. **Kept out of the Odin build tree; no Heimdall integration in this spike.**

## Docs
- [SPIKE.md](./SPIKE.md) — spike report: crate choices, architecture, what
  worked, gotchas, go/no-go recommendation.
- [PROTOCOL.md](./PROTOCOL.md) — the framed attach/detach wire protocol.
- [DEBUG_TUI.md](./DEBUG_TUI.md) — the in-app debug TUI layout + controls.

## Quick start
```bash
nix develop                 # provides cargo/rustc (or: nix build .#ham-pty-host)
cargo build
cargo test -- --test-threads=1

# host a shell, then attach from another terminal
./target/debug/ham-pty-host run    --socket /tmp/ham.sock -- /bin/zsh -l
./target/debug/ham-pty-host attach --socket /tmp/ham.sock            # raw passthrough
./target/debug/ham-pty-host attach --socket /tmp/ham.sock --debug    # split debug TUI
```

Ctrl-\ detaches the passthrough client (child survives); F10 quits the debug TUI.

## Layout
| file | REQ | role |
|------|-----|------|
| `src/vt.rs` | PTYH-1 | VT parser + screen grid/cursor + `capture()` |
| `src/host.rs` | PTYH-1 | spawn child under PTY, pump output into the VT model |
| `src/proto.rs` | PTYH-2 | framed wire protocol (encode/decode) |
| `src/server.rs` | PTYH-2 | unix-socket host, multi-client fan-out |
| `src/client.rs` + `src/termios.rs` | PTYH-2 | raw-mode `attach` client |
| `src/debug_tui.rs` | PTYH-3 | pure TUI state machine (tested) |
| `src/debug_ui.rs` | PTYH-3 | ratatui/crossterm runtime |
| `src/dproto.rs` | HOST-1 | instance-scoped multi-agent daemon protocol |
| `src/daemon.rs` | HOST-1/2 | per-machine daemon: agent registry + spawn/close/restart/list; per-agent detector thread |
| `src/detect.rs` | HOST-2 | pure config-driven startup detector (auto-enter/blocked) + activity hash |
| `src/dashboard_tui.rs` | HOST-3 | pure multi-agent dashboard state machine (selection/focus/switch/resize) |
| `src/dashboard_ui.rs` | HOST-3 | ratatui/crossterm dashboard runtime (sidebar + selected pane + debug widgets) |
| `src/dclient.rs` | HOST-4 | single-agent `attach --instance` raw passthrough (no sidebar) |

## Multi-agent daemon (HOST-1)
```bash
# start the per-machine daemon
./target/debug/ham-pty-host daemon --socket /tmp/ham-daemon.sock

# from anywhere, drive it by agent-instance-id
./target/debug/ham-pty-host spawn   --socket /tmp/ham-daemon.sock --instance inst_a \
    --cwd /work --env HEIMDALL_AGENT_TOKEN=hlat_x --detect '{"auto_enter_patterns":["❯"]}' -- /bin/zsh -l
./target/debug/ham-pty-host list    --socket /tmp/ham-daemon.sock
./target/debug/ham-pty-host restart --socket /tmp/ham-daemon.sock --instance inst_a  # re-spawn same spec
./target/debug/ham-pty-host close   --socket /tmp/ham-daemon.sock --instance inst_a  # SIGTERM->SIGKILL
```
The daemon manages N agents keyed by instance id; `restart` reuses the remembered
argv/cwd/env/detect. `--detect` is stored verbatim in HOST-1 and consumed by the
per-agent startup detector in HOST-2.

## Config-driven startup detection + activity signal (HOST-2)
Each agent may carry a `--detect` JSON blob reusing the Heimdall
`Startup_Detection_Config` shape:
```json
{
  "enabled": true,
  "startup_probe_seconds": 20,
  "capture_interval_ms": 500,
  "auto_enter_patterns": ["Yes, I trust this folder", "Bypass Permissions mode"],
  "auto_enter_pre_keys": ["", "Down"],
  "blocked_patterns": ["Login required", "quota exceeded"],
  "startup_unknown_is_blocked": false,
  "sanitized_reason_mapping": ["login=Provider login required"]
}
```
A per-agent detector ticks every `capture_interval_ms` against the live VT model:
- **auto-enter** (checked first): when the screen contains `auto_enter_patterns[i]`,
  the detector sends `auto_enter_pre_keys[i]` (space-separated key tokens like
  `Down` or `Tab Tab`, translated to named keys) followed by **Enter**, then
  cools down 2s + extends the probe deadline (so dismissing a prompt doesn't eat
  the ready budget) — matching the Odin `startup_probe_agent`.
- **blocked**: when the screen contains `blocked_patterns[i]`, emits
  `StartupBlocked{instance, reason_code, safe_diagnostic}` (sanitized reason).
- **timeout**: no match within the probe window emits `StartupReady{instance}`,
  unless `startup_unknown_is_blocked` (then `StartupBlocked`).

Separately, the daemon emits `ScreenChanged{instance, hash}` whenever an agent's
rendered content changes — a cheap dirty signal so the bridge classifies activity
**without polling**. This runs for every agent (even without a `detect` config);
agents with no/disabled detection stay silent on startup events but still emit
activity.

> **Spinner masking is bridge-side.** A spinner/clock repainting every frame will
> change the content hash continuously, so `ScreenChanged` fires steadily. The
> host emits the raw dirty signal only; deciding that a lone spinner is *not*
> real activity (masking) is the bridge's job (ported from `pane_activity.odin`
> in BR-3), not the host's.

## Multi-agent dashboard (HOST-3)
```bash
# attach with NO --instance => the dashboard against the daemon
./target/debug/ham-pty-host attach --socket /tmp/ham-daemon.sock
```
```text
+----------------------+--------------------------------------+
| agents (sidebar)     | selected agent's live VT screen       |
|  > inst_a  claude    |                                       |
|    inst_b  /bin/zsh  |  (debug widgets below: SendKeys /     |
|    inst_c  (dead)    |   NamedKey / Resize / Capture)        |
+----------------------+--------------------------------------+
```
- **F2** cycles focus **List -> Pane -> (Debug, when shown) -> List**.
- **F3** toggles the Debug panel. It is **hidden by default**; when hidden the
  selected-agent pane gets the full right column. Hiding it while it holds focus
  falls back to Pane focus.
- **List**: Up/Down/Home/End move the selection; **Enter** (or a mouse **click**
  on a row) switches the attached agent — emitting `Detach{old}` + `Attach{new}`
  so only the visible agent streams output.
- **Pane**: keystrokes drive the selected agent's child.
- **Debug**: the PTYH-3 widgets (Send Keys / Named Keys / Resize / Capture)
  scoped to the selected agent.
- **Click a section header** (agents / pane / debug) to focus that section; a
  click on the debug header also reveals it if hidden.
- **F10** detaches + quits (agents keep running).

**Responsive by design:** a terminal resize (SIGWINCH -> crossterm `Resize`)
recomputes the right-pane geometry and sends an instance-scoped `Resize`, so the
contained process's PTY reflows to the pane. Newly-attached/switched agents are
also sized to the current geometry immediately. (Verified: attaching in a 40x120
terminal resized the agent PTY from 24x80 to the pane's 36x86.)

## Single-agent attach (HOST-4)

```bash
# raw passthrough to ONE agent, no sidebar — ideal for tiling one agent per
# tmux pane and laying them out manually.
./target/debug/ham-pty-host attach --socket /tmp/ham-daemon.sock --instance agent-alpha
```

Streams only that instance's live `Output` to stdout and forwards stdin as
`Input{instance}`; async events for other agents (and control replies) are
filtered out so many single-agent panes can share one daemon. SIGWINCH sends an
instance-scoped `Resize` so the child reflows to the pane. **Ctrl-\ detaches
without killing the child**; if the child exits, the client restores the terminal
and exits with the child's code.

Verified live (real PTY harness, 30x100 window): live `LIVE_LINE_N` output
streamed through, Ctrl-\ detached, and `list` showed the child still `alive` at
`30x100`. Isolation is also covered by an automated real-PTY test
(`socket_attach_one_instance_isolates_output`): with two agents driven
concurrently, every `Output` frame the attached client receives is for the
attached instance only.
