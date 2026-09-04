//! ham-pty-host: a standalone PTY host + VT screen model spike.
//!
//! Modules:
//!   * [`vt`]   — VT parser + screen grid (REQ PTYH-1).
//!   * [`host`] — spawn a child under a PTY and maintain the live screen (REQ PTYH-1).
//!
//! Later tasks add a unix-socket attach/detach protocol (PTYH-2) and an in-app
//! ratatui debug TUI (PTYH-3).

pub mod host;
pub mod vt;

pub use host::{PtyHost, SpawnConfig};
pub use vt::{Capture, Cell, Color, Screen, VtEngine};
