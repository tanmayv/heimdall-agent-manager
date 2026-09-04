# ham-pty-host attach/detach protocol (PTYH-2)

The host (`ham-pty-host run --socket <path> -- <argv>`) spawns a child under a
PTY and serves attach clients over a **unix domain socket**. Multiple clients
may attach concurrently; the host fans raw child output out to all of them and
multiplexes their input into the single PTY.

## Framing

Every message is a length-prefixed frame:

```
+----------------+-----------------------------+
| u32 len (BE)   | payload (len bytes)         |
+----------------+-----------------------------+
```

The **first payload byte is a tag**; remaining bytes are that tag's fields. All
integers are **big-endian**. Frames larger than 64 MiB are rejected. A clean EOF
at a frame boundary is a normal disconnect.

This is a hand-rolled binary format (no serde) so it can be reimplemented from
any language trivially.

## client → host

| tag  | name    | fields                                   | effect |
|------|---------|------------------------------------------|--------|
| 0x01 | Attach  | —                                        | register this client; host replies with a `Screen` snapshot of current state |
| 0x02 | Input   | raw bytes                                | written verbatim to the child's PTY (stdin) |
| 0x03 | Key     | u8 named-key code                        | host expands to the terminal's byte sequence, then writes it |
| 0x04 | Resize  | u16 rows, u16 cols                       | resizes PTY winsize + VT model together |
| 0x05 | Capture | —                                        | host replies with a `Screen` snapshot |
| 0x06 | Detach  | —                                        | host drops this client; **child keeps running** |
| 0x07 | Ping    | —                                        | host replies `Pong` |

### Named keys (0x03 Key)

| code | key            | bytes sent          |
|------|----------------|---------------------|
| 1    | Enter          | `\r`                |
| 2    | Esc            | `\x1b`              |
| 3    | Ctrl-C         | `\x03`              |
| 4    | Tab            | `\t`                |
| 5    | Up             | `\x1b[A`            |
| 6    | Down           | `\x1b[B`            |
| 7    | Left           | `\x1b[D`            |
| 8    | Right          | `\x1b[C`            |
| 9    | Backspace      | `\x7f`              |
| 10   | Ctrl-D         | `\x04`              |
| 11   | Ctrl-\         | `\x1c`              |
| 12   | Home           | `\x1b[H`            |
| 13   | End            | `\x1b[F`            |
| 14   | PageUp         | `\x1b[5~`           |
| 15   | PageDown       | `\x1b[6~`           |
| 16   | Delete         | `\x1b[3~`           |

## host → client

| tag  | name        | fields                                   |
|------|-------------|------------------------------------------|
| 0x81 | Output      | raw PTY output bytes (broadcast)         |
| 0x82 | Screen      | serialized screen snapshot (see below)   |
| 0x83 | ChildExited | i32 exit code                            |
| 0x84 | Pong        | —                                        |

### Screen payload (0x82)

```
u16 rows, u16 cols, u16 cursor_row, u16 cursor_col,
u16 n_lines,
n_lines × ( u32 line_len, utf8 line_bytes )
```

Lines are the *rendered* screen rows (trailing blanks trimmed) — the same model
`capture()` produces in PTYH-1.

## Lifecycle & guarantees

- **Attach** streams live `Output` immediately; the initial `Screen` lets a
  re-attaching client repaint current state without waiting for new output.
- **Detach (0x06) or socket drop** removes only that client. The child and all
  other clients are unaffected. (`attach` binds Ctrl-\ / 0x1c to send Detach.)
- **Re-attach** connects a fresh socket and drives the same live child.
- **Child exit** → host broadcasts `ChildExited(code)` to every client, flushes,
  then shuts the socket down. The `run` process exits with the child's code.

## `attach` client behavior (PTYH-2)

`ham-pty-host attach --socket <path>`:

1. Puts the local terminal in **raw mode** (restored on exit via RAII guard).
2. Sends `Attach` + an initial `Resize` matching the local window.
3. Streams `Output` → stdout, forwards stdin → `Input`.
4. On **SIGWINCH**, sends `Resize` with the new size.
5. On **Ctrl-\** (0x1c) sends `Detach` and exits **without** killing the child.
6. On `ChildExited`, restores the terminal and exits with the child's code.
