//! REQ PTYH-3: In-app split-screen debug TUI (ratatui + crossterm).
//!
//! `ham-pty-host attach --debug` connects to a running host over its unix socket
//! and renders a native two-pane TUI:
//!
//! ```text
//! +---------------------------+-------------------------+
//! | LEFT: live pane view      | RIGHT: debug sidebar    |
//! | (VT grid rendered from    |  - Send Keys input line |
//! |  Screen/Capture frames)   |  - Send Named Key list  |
//! |                           |  - Resize control       |
//! |                           |  - Capture snapshot      |
//! +---------------------------+-------------------------+
//! ```
//!
//! Focus toggles between **PANE** (keystrokes drive the child) and **SIDEBAR**
//! (keystrokes drive the debug widgets) with **F2**. **F10** detaches + quits
//! (the child keeps running).
//!
//! The left pane renders from the host's **VT screen model** (Screen frames
//! requested via Capture on a timer), NOT the raw Output byte stream. That is
//! deliberate: it means the debug view repaints correctly on attach and is
//! immune to the alt-screen "no redraw until the app repaints" limitation that
//! the raw-passthrough `attach` client has (see SPIKE.md).
//!
//! There is **no browser, no websocket, no Heimdall UI** — the sidebar lives
//! entirely inside this binary.

use crate::proto::{ClientMsg, NamedKey, ScreenSnapshot};

/// Which half of the TUI currently receives keystrokes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Focus {
    /// Keystrokes are translated to bytes and sent to the child as Input.
    Pane,
    /// Keystrokes drive the debug sidebar widgets.
    Sidebar,
}

/// The active sidebar sub-widget (cycled with Tab / BackTab in Sidebar focus).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Field {
    SendKeys,
    NamedKeys,
    Resize,
    Capture,
}

impl Field {
    pub const ALL: [Field; 4] = [Field::SendKeys, Field::NamedKeys, Field::Resize, Field::Capture];

    fn next(self) -> Field {
        let i = Field::ALL.iter().position(|f| *f == self).unwrap();
        Field::ALL[(i + 1) % Field::ALL.len()]
    }

    fn prev(self) -> Field {
        let i = Field::ALL.iter().position(|f| *f == self).unwrap();
        Field::ALL[(i + Field::ALL.len() - 1) % Field::ALL.len()]
    }
}

/// The named keys offered as sidebar shortcuts (REQ PTYH-3 lists
/// Enter/Esc/Ctrl-C/Tab/Up/Down).
pub const NAMED_KEY_CHOICES: [(NamedKey, &str); 6] = [
    (NamedKey::Enter, "Enter"),
    (NamedKey::Esc, "Esc"),
    (NamedKey::CtrlC, "Ctrl-C"),
    (NamedKey::Tab, "Tab"),
    (NamedKey::Up, "Up"),
    (NamedKey::Down, "Down"),
];

/// A saved capture (snapshot) kept in the sidebar's history.
#[derive(Clone, Debug)]
pub struct SavedCapture {
    pub rows: u16,
    pub cols: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub nonblank_lines: usize,
}

/// All mutable TUI state that isn't the terminal itself.
pub struct AppState {
    pub focus: Focus,
    pub field: Field,
    /// Text buffer for the Send Keys line.
    pub send_buf: String,
    /// Selected index in the named-key list.
    pub named_sel: usize,
    /// Text buffer for the Resize control ("ROWSxCOLS").
    pub resize_buf: String,
    /// History of captured snapshots.
    pub captures: Vec<SavedCapture>,
    /// Latest screen snapshot received from the host (for the left pane).
    pub latest: Option<ScreenSnapshot>,
    /// Set when the host reports the child exited.
    pub child_exit: Option<i32>,
    /// Transient status line message.
    pub status: String,
    /// Set when the user asks to quit/detach.
    pub should_quit: bool,
}

impl Default for AppState {
    fn default() -> Self {
        AppState {
            focus: Focus::Pane,
            field: Field::SendKeys,
            send_buf: String::new(),
            named_sel: 0,
            resize_buf: String::new(),
            captures: Vec::new(),
            latest: None,
            child_exit: None,
            status: "F2 toggles focus · F10 detaches+quits".into(),
            should_quit: false,
        }
    }
}

/// Messages to send to the host as a result of handling one input event.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Outcome {
    pub messages: Vec<ClientMsg>,
}

impl Outcome {
    fn one(m: ClientMsg) -> Outcome {
        Outcome { messages: vec![m] }
    }
    fn none() -> Outcome {
        Outcome::default()
    }
}

/// Abstract key input, decoupled from crossterm for testability.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Key {
    Char(char),
    Enter,
    Esc,
    Tab,
    BackTab,
    Backspace,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    Delete,
    PageUp,
    PageDown,
    /// Ctrl + a printable char.
    Ctrl(char),
    /// Toggle focus (F2).
    ToggleFocus,
    /// Detach + quit (F10).
    Quit,
    /// A function/other key we don't translate.
    Other,
}

impl AppState {
    /// Handle one key event, mutating state + returning any host messages.
    pub fn handle_key(&mut self, key: Key) -> Outcome {
        // Global keys regardless of focus.
        match key {
            Key::Quit => {
                self.should_quit = true;
                return Outcome::one(ClientMsg::Detach);
            }
            Key::ToggleFocus => {
                self.focus = match self.focus {
                    Focus::Pane => Focus::Sidebar,
                    Focus::Sidebar => Focus::Pane,
                };
                self.status = match self.focus {
                    Focus::Pane => "PANE focus: keys drive the child".into(),
                    Focus::Sidebar => "SIDEBAR focus: Tab cycles fields".into(),
                };
                return Outcome::none();
            }
            _ => {}
        }

        match self.focus {
            Focus::Pane => self.handle_pane_key(key),
            Focus::Sidebar => self.handle_sidebar_key(key),
        }
    }

    /// PANE focus: translate the key to bytes and send as Input.
    fn handle_pane_key(&mut self, key: Key) -> Outcome {
        match key_to_bytes(&key) {
            Some(bytes) => Outcome::one(ClientMsg::Input(bytes)),
            None => Outcome::none(),
        }
    }

    /// SIDEBAR focus: drive the active widget.
    fn handle_sidebar_key(&mut self, key: Key) -> Outcome {
        // Tab / BackTab cycle the active field (works from any field).
        match key {
            Key::Tab => {
                self.field = self.field.next();
                return Outcome::none();
            }
            Key::BackTab => {
                self.field = self.field.prev();
                return Outcome::none();
            }
            _ => {}
        }

        match self.field {
            Field::SendKeys => self.handle_send_keys(key),
            Field::NamedKeys => self.handle_named_keys(key),
            Field::Resize => self.handle_resize(key),
            Field::Capture => self.handle_capture(key),
        }
    }

    fn handle_send_keys(&mut self, key: Key) -> Outcome {
        match key {
            Key::Char(c) => {
                self.send_buf.push(c);
                Outcome::none()
            }
            Key::Backspace => {
                self.send_buf.pop();
                Outcome::none()
            }
            Key::Enter => {
                if self.send_buf.is_empty() {
                    return Outcome::none();
                }
                // Send the typed text followed by a newline so commands run.
                let mut bytes = self.send_buf.clone().into_bytes();
                bytes.push(b'\n');
                self.status = format!("sent {} bytes as Input", bytes.len());
                self.send_buf.clear();
                Outcome::one(ClientMsg::Input(bytes))
            }
            _ => Outcome::none(),
        }
    }

    fn handle_named_keys(&mut self, key: Key) -> Outcome {
        match key {
            Key::Up => {
                if self.named_sel > 0 {
                    self.named_sel -= 1;
                }
                Outcome::none()
            }
            Key::Down => {
                if self.named_sel + 1 < NAMED_KEY_CHOICES.len() {
                    self.named_sel += 1;
                }
                Outcome::none()
            }
            Key::Enter => {
                let (nk, label) = NAMED_KEY_CHOICES[self.named_sel];
                self.status = format!("sent named key: {label}");
                Outcome::one(ClientMsg::Key(nk))
            }
            _ => Outcome::none(),
        }
    }

    fn handle_resize(&mut self, key: Key) -> Outcome {
        match key {
            Key::Char(c) if c.is_ascii_digit() || c == 'x' || c == 'X' => {
                self.resize_buf.push(c.to_ascii_lowercase());
                Outcome::none()
            }
            Key::Backspace => {
                self.resize_buf.pop();
                Outcome::none()
            }
            Key::Enter => match parse_resize(&self.resize_buf) {
                Some((rows, cols)) => {
                    self.status = format!("resize -> {rows}x{cols}");
                    self.resize_buf.clear();
                    Outcome::one(ClientMsg::Resize { rows, cols })
                }
                None => {
                    self.status = "resize: type ROWSxCOLS e.g. 40x120".into();
                    Outcome::none()
                }
            },
            _ => Outcome::none(),
        }
    }

    fn handle_capture(&mut self, key: Key) -> Outcome {
        match key {
            Key::Enter => {
                // Snapshot the latest known screen + request a fresh one.
                if let Some(s) = &self.latest {
                    let nonblank = s.lines.iter().filter(|l| !l.trim().is_empty()).count();
                    self.captures.push(SavedCapture {
                        rows: s.rows,
                        cols: s.cols,
                        cursor_row: s.cursor_row,
                        cursor_col: s.cursor_col,
                        nonblank_lines: nonblank,
                    });
                    self.status = format!(
                        "captured #{}: {}x{} cursor=({},{}) {} non-blank lines",
                        self.captures.len(),
                        s.rows,
                        s.cols,
                        s.cursor_row,
                        s.cursor_col,
                        nonblank
                    );
                } else {
                    self.status = "no screen yet to capture".into();
                }
                Outcome::one(ClientMsg::Capture)
            }
            _ => Outcome::none(),
        }
    }
}

/// Translate an abstract key into the bytes a real terminal would send.
pub fn key_to_bytes(key: &Key) -> Option<Vec<u8>> {
    let v: Vec<u8> = match key {
        Key::Char(c) => {
            let mut b = [0u8; 4];
            c.encode_utf8(&mut b).as_bytes().to_vec()
        }
        Key::Enter => b"\r".to_vec(),
        Key::Esc => b"\x1b".to_vec(),
        Key::Tab => b"\t".to_vec(),
        Key::Backspace => b"\x7f".to_vec(),
        Key::Up => b"\x1b[A".to_vec(),
        Key::Down => b"\x1b[B".to_vec(),
        Key::Right => b"\x1b[C".to_vec(),
        Key::Left => b"\x1b[D".to_vec(),
        Key::Home => b"\x1b[H".to_vec(),
        Key::End => b"\x1b[F".to_vec(),
        Key::Delete => b"\x1b[3~".to_vec(),
        Key::PageUp => b"\x1b[5~".to_vec(),
        Key::PageDown => b"\x1b[6~".to_vec(),
        Key::Ctrl(c) => {
            // Ctrl-A..Ctrl-Z -> 0x01..0x1a etc.
            let up = c.to_ascii_uppercase();
            if up.is_ascii_alphabetic() {
                vec![(up as u8) - b'A' + 1]
            } else {
                match up {
                    '@' => vec![0],
                    '[' => vec![0x1b],
                    '\\' => vec![0x1c],
                    ']' => vec![0x1d],
                    _ => return None,
                }
            }
        }
        Key::BackTab | Key::ToggleFocus | Key::Quit | Key::Other => return None,
    };
    Some(v)
}

/// Parse a "ROWSxCOLS" string (e.g. "40x120") into (rows, cols).
pub fn parse_resize(s: &str) -> Option<(u16, u16)> {
    let (r, c) = s.split_once('x')?;
    let rows: u16 = r.trim().parse().ok()?;
    let cols: u16 = c.trim().parse().ok()?;
    if rows == 0 || cols == 0 {
        return None;
    }
    Some((rows, cols))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn focus_toggles_with_f2() {
        let mut app = AppState::default();
        assert_eq!(app.focus, Focus::Pane);
        app.handle_key(Key::ToggleFocus);
        assert_eq!(app.focus, Focus::Sidebar);
        app.handle_key(Key::ToggleFocus);
        assert_eq!(app.focus, Focus::Pane);
    }

    #[test]
    fn pane_focus_sends_input_bytes() {
        let mut app = AppState::default();
        let out = app.handle_key(Key::Char('a'));
        assert_eq!(out.messages, vec![ClientMsg::Input(b"a".to_vec())]);
        let out = app.handle_key(Key::Enter);
        assert_eq!(out.messages, vec![ClientMsg::Input(b"\r".to_vec())]);
        let out = app.handle_key(Key::Ctrl('c'));
        assert_eq!(out.messages, vec![ClientMsg::Input(vec![0x03])]);
    }

    #[test]
    fn pane_arrow_keys_send_escape_sequences() {
        let mut app = AppState::default();
        assert_eq!(
            app.handle_key(Key::Up).messages,
            vec![ClientMsg::Input(b"\x1b[A".to_vec())]
        );
    }

    #[test]
    fn sidebar_tab_cycles_fields() {
        let mut app = AppState::default();
        app.handle_key(Key::ToggleFocus); // -> Sidebar
        assert_eq!(app.field, Field::SendKeys);
        app.handle_key(Key::Tab);
        assert_eq!(app.field, Field::NamedKeys);
        app.handle_key(Key::Tab);
        assert_eq!(app.field, Field::Resize);
        app.handle_key(Key::Tab);
        assert_eq!(app.field, Field::Capture);
        app.handle_key(Key::Tab);
        assert_eq!(app.field, Field::SendKeys);
        app.handle_key(Key::BackTab);
        assert_eq!(app.field, Field::Capture);
    }

    #[test]
    fn send_keys_line_builds_and_sends_with_newline() {
        let mut app = AppState::default();
        app.handle_key(Key::ToggleFocus); // Sidebar, SendKeys active
        for c in "echo hi".chars() {
            app.handle_key(Key::Char(c));
        }
        assert_eq!(app.send_buf, "echo hi");
        app.handle_key(Key::Backspace);
        assert_eq!(app.send_buf, "echo h");
        app.handle_key(Key::Char('i'));
        let out = app.handle_key(Key::Enter);
        assert_eq!(out.messages, vec![ClientMsg::Input(b"echo hi\n".to_vec())]);
        assert!(app.send_buf.is_empty());
    }

    #[test]
    fn named_keys_select_and_send() {
        let mut app = AppState::default();
        app.handle_key(Key::ToggleFocus);
        app.handle_key(Key::Tab); // -> NamedKeys
        assert_eq!(app.field, Field::NamedKeys);
        // default selection 0 = Enter
        let out = app.handle_key(Key::Enter);
        assert_eq!(out.messages, vec![ClientMsg::Key(NamedKey::Enter)]);
        // move down twice -> Ctrl-C
        app.handle_key(Key::Down);
        app.handle_key(Key::Down);
        assert_eq!(app.named_sel, 2);
        let out = app.handle_key(Key::Enter);
        assert_eq!(out.messages, vec![ClientMsg::Key(NamedKey::CtrlC)]);
    }

    #[test]
    fn named_keys_selection_is_clamped() {
        let mut app = AppState::default();
        app.handle_key(Key::ToggleFocus);
        app.handle_key(Key::Tab);
        app.handle_key(Key::Up); // already at 0
        assert_eq!(app.named_sel, 0);
        for _ in 0..20 {
            app.handle_key(Key::Down);
        }
        assert_eq!(app.named_sel, NAMED_KEY_CHOICES.len() - 1);
    }

    #[test]
    fn resize_field_parses_and_sends() {
        let mut app = AppState::default();
        app.handle_key(Key::ToggleFocus);
        app.handle_key(Key::Tab);
        app.handle_key(Key::Tab); // -> Resize
        assert_eq!(app.field, Field::Resize);
        for c in "40x120".chars() {
            app.handle_key(Key::Char(c));
        }
        let out = app.handle_key(Key::Enter);
        assert_eq!(out.messages, vec![ClientMsg::Resize { rows: 40, cols: 120 }]);
    }

    #[test]
    fn resize_invalid_input_does_not_send() {
        let mut app = AppState::default();
        app.handle_key(Key::ToggleFocus);
        app.handle_key(Key::Tab);
        app.handle_key(Key::Tab);
        for c in "abc".chars() {
            // non digit/x chars are ignored by the field
            app.handle_key(Key::Char(c));
        }
        assert_eq!(app.resize_buf, "");
        let out = app.handle_key(Key::Enter);
        assert!(out.messages.is_empty());
    }

    #[test]
    fn capture_snapshots_latest_and_requests_new() {
        let mut app = AppState::default();
        app.latest = Some(ScreenSnapshot {
            rows: 24,
            cols: 80,
            cursor_row: 3,
            cursor_col: 5,
            lines: vec!["hello".into(), "".into(), "world".into()],
        });
        app.handle_key(Key::ToggleFocus);
        app.handle_key(Key::Tab);
        app.handle_key(Key::Tab);
        app.handle_key(Key::Tab); // -> Capture
        assert_eq!(app.field, Field::Capture);
        let out = app.handle_key(Key::Enter);
        assert_eq!(out.messages, vec![ClientMsg::Capture]);
        assert_eq!(app.captures.len(), 1);
        assert_eq!(app.captures[0].nonblank_lines, 2);
        assert_eq!(app.captures[0].cursor_row, 3);
    }

    #[test]
    fn quit_sets_flag_and_detaches() {
        let mut app = AppState::default();
        let out = app.handle_key(Key::Quit);
        assert!(app.should_quit);
        assert_eq!(out.messages, vec![ClientMsg::Detach]);
    }

    #[test]
    fn parse_resize_variants() {
        assert_eq!(parse_resize("40x120"), Some((40, 120)));
        assert_eq!(parse_resize("24x80"), Some((24, 80)));
        assert_eq!(parse_resize("0x80"), None);
        assert_eq!(parse_resize("abc"), None);
        assert_eq!(parse_resize("40"), None);
    }

    #[test]
    fn key_to_bytes_covers_common_keys() {
        assert_eq!(key_to_bytes(&Key::Char('z')), Some(b"z".to_vec()));
        assert_eq!(key_to_bytes(&Key::Enter), Some(b"\r".to_vec()));
        assert_eq!(key_to_bytes(&Key::Esc), Some(b"\x1b".to_vec()));
        assert_eq!(key_to_bytes(&Key::Tab), Some(b"\t".to_vec()));
        assert_eq!(key_to_bytes(&Key::Backspace), Some(b"\x7f".to_vec()));
        assert_eq!(key_to_bytes(&Key::Ctrl('a')), Some(vec![1]));
        assert_eq!(key_to_bytes(&Key::Ctrl('c')), Some(vec![3]));
        assert_eq!(key_to_bytes(&Key::Left), Some(b"\x1b[D".to_vec()));
        assert_eq!(key_to_bytes(&Key::ToggleFocus), None);
    }
}
