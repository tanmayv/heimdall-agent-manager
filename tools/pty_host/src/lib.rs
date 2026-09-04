//! ham-pty-host: a standalone PTY host + VT screen model spike.
//!
//! Modules:
//!   * [`vt`]      — VT parser + screen grid (REQ PTYH-1).
//!   * [`host`]    — spawn a child under a PTY and maintain the live screen (PTYH-1).
//!   * [`proto`]   — framed attach/detach wire protocol (PTYH-2).
//!   * [`server`]  — unix-socket host server, multi-client fan-out (PTYH-2).
//!   * [`client`]  — raw-mode `attach` client (PTYH-2).
//!   * [`termios`] — local terminal raw mode + winsize FFI (PTYH-2).
//!   * [`debug_tui`] — pure state machine for the in-app debug TUI (PTYH-3).
//!   * [`debug_ui`]  — ratatui/crossterm runtime for the debug TUI (PTYH-3).

pub mod client;
pub mod debug_tui;
pub mod debug_ui;
pub mod host;
pub mod proto;
pub mod server;
pub mod termios;
pub mod vt;

pub use host::{PtyHost, SpawnConfig};
pub use proto::{ClientMsg, HostMsg, NamedKey, ScreenSnapshot};
pub use server::HostServer;
pub use vt::{Capture, Cell, Color, Screen, VtEngine};
