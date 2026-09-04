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
| `src/daemon.rs` | HOST-1 | per-machine daemon: agent registry + spawn/close/restart/list |

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
