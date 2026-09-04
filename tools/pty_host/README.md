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
