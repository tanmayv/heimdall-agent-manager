# Alternate-buffer handling plan

Status: planned; implementation has not started.

## Goal

Support alternate terminal buffers through live streaming, late joins, reconnects,
and pane remounts. A viewer must see the current Neovim screen correctly, and
quitting Neovim must restore the primary shell screen and cursor without disturbing
other viewers or sessions.

## Current gaps

- The PTY host VT model has one grid and ignores private alternate-buffer modes.
- Screen snapshots carry rows, columns, cursor position, and lines, but no buffer
  identity or terminal modes.
- Snapshot capture and output subscription use separate boundaries, allowing
  output or a buffer switch to be lost between them.
- Bridge and Hub snapshot repaint sequences cannot restore both buffers or the
  active mode. Agent-pane reconnect resets also discard terminal state.
- xterm supports alternate buffers already. Its live-byte path works, but the
  snapshot and reconnect paths need to preserve the same state.

## Implementation sequence

### REQ-ALT-1: Define a versioned snapshot contract

Represent the active buffer, primary and alternate grids, cursor state, relevant
terminal modes, and a snapshot sequence number. Define compatibility or capability
negotiation so an older PTY host can coexist with a newer bridge during upgrades.
Update binary protocol writers and readers together.

### REQ-ALT-2: Implement PTY buffer state

Handle DEC private modes `?47`, `?1047`, `?1048`, and `?1049` with their distinct
buffer-switch, clear, and cursor-save/restore semantics. Preserve both buffers
across resize and restore the primary buffer on exit.

Before extending the current minimal VT model, evaluate an established VT engine.
Neovim also depends on scroll regions and editing operations that the current
model does not fully implement; buffer switching alone cannot guarantee faithful
snapshots.

### REQ-ALT-3: Make attachment consistent

Capture the snapshot and establish the output subscription at a consistent
sequence boundary. Deliver subsequent output in order without losing a buffer
switch. Send the initial snapshot only to the joining viewer, so an attachment
does not repaint existing viewers.

### REQ-ALT-4: Carry state through Bridge and Hub

Update Rust encoding, Odin decoding, and shell/agent snapshot responses together.
Preserve buffer state, modes, and sequence ordering through encryption and
chunking. Prevent stale snapshots from overwriting newer streamed output.

### REQ-ALT-5: Restore state in the UI

Restore both buffers and the active mode through xterm-compatible sequences or a
suitable state restoration mechanism. Align agent-pane reconnect handling and
shell-pane serialized restoration. Preserve input-relevant modes such as mouse
reporting, application cursor keys, and bracketed paste.

### REQ-ALT-6: Validate and release

Add focused protocol and VT regression tests, then verify with actual Neovim:

- Enter and exit each supported alternate-buffer mode, including repeated switches.
- Resize in the alternate buffer and restore the primary screen and cursor.
- Join late, reconnect, and remount a pane while Neovim is active.
- Exercise scroll regions and screen editing used by Neovim.
- Verify two viewers of one session and two independent sessions remain isolated.
- Verify compatibility behavior during mixed-version upgrades.

Release compatible Bridge/PTY-host, Hub, and UI versions together, documenting
any required upgrade ordering.

## Affected areas

- PTY host: VT model, snapshot protocol, daemon capture and attach paths.
- Bridge: PTY-host snapshot decoding and stream snapshot delivery.
- Hub: shell/agent snapshot transport and repaint generation.
- UI: shell terminal and agent pane restoration/reconnect handling.

## Acceptance criteria

A fresh or reconnected viewer shows the active Neovim screen correctly. Exiting
Neovim restores the original shell buffer and cursor. Ordered output continues
without lost transitions, and other viewers and sessions are unaffected.

## Estimate

Allow 2–4 days for buffer-aware snapshots and end-to-end restoration using the
existing VT model. Allow 4–7 days if replacing the VT engine is necessary for
faithful Neovim rendering. Confirm the implementation approach after evaluating
the VT engine and snapshot compatibility requirements.
