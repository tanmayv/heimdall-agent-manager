//! REQ HOST-3: Dashboard attach TUI — pure state machine.
//!
//! `ham-pty-host attach` (with **no** `--instance`) renders a multi-agent
//! dashboard against the daemon:
//!
//! ```text
//! +---------------------------+-------------------------------+
//! | LEFT: agent sidebar       | RIGHT: selected agent's live  |
//! |  scrollable + clickable   |  VT screen (Screen frames)    |
//! |  inst-id / program /      |                               |
//! |  alive / activity /       |  (+ debug widgets: Send Keys, |
//! |  optional bridge label    |   Named Keys, Resize, Capture |
//! |  > selected row           |   driving the focused agent)  |
//! +---------------------------+-------------------------------+
//! ```
//!
//! Focus cycles **List → Pane → Debug** with **F2**:
//!   * **List**  — Up/Down move the selection; Enter switches to that agent.
//!                 A mouse click on a row selects + switches directly.
//!   * **Pane**  — keystrokes are translated to bytes and sent to the *selected*
//!                 agent's child (`Input`).
//!   * **Debug** — the PTYH-3 widgets (Send Keys / Named Keys / Resize / Capture)
//!                 extended to the *selected* agent.
//!
//! **F10** detaches + quits. Every host message this produces is **instance-
//! scoped** ([`crate::dproto::CtlMsg`]); switching agents emits `Detach{old}` +
//! `Attach{new}` so only the visible agent streams output. This module is pure
//! (no IO/ratatui) so selection/focus/switch/widget logic is unit-tested; the
//! ratatui runtime lives in `dashboard_ui.rs`.

use crate::dproto::CtlMsg;
use crate::proto::{NamedKey, ScreenSnapshot};

// Reuse the tested key abstraction + widget field enum + helpers from the
// single-agent debug TUI so behavior stays identical.
pub use crate::debug_tui::{key_to_bytes, parse_resize, Field, Key, NAMED_KEY_CHOICES};

/// One row in the sidebar, derived from a daemon `AgentList` entry (+ optional
/// bridge-supplied label).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentRow {
    pub instance_id: String,
    pub program: String,
    pub alive: bool,
    /// Unix epoch seconds of last output activity (for an "active Ns ago" hint).
    pub last_activity: u64,
    /// Optional human label the bridge may attach (e.g. "claude · repoX").
    pub bridge_label: Option<String>,
}

/// Which region currently receives keystrokes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Focus {
    /// The agent sidebar: Up/Down select, Enter switches.
    List,
    /// The selected agent's pane: keys drive its child.
    Pane,
    /// The debug widgets, scoped to the selected agent.
    Debug,
}

/// Messages to send to the daemon as a result of handling one event.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Outcome {
    pub messages: Vec<CtlMsg>,
}

impl Outcome {
    fn none() -> Outcome {
        Outcome::default()
    }
    fn one(m: CtlMsg) -> Outcome {
        Outcome { messages: vec![m] }
    }
}

/// All mutable dashboard state that isn't the terminal itself.
pub struct Dashboard {
    pub agents: Vec<AgentRow>,
    /// Index into `agents` of the highlighted/selected row.
    pub selected: usize,
    /// The instance currently *attached* (streaming). `None` until first switch.
    pub attached: Option<String>,
    pub focus: Focus,
    // -- debug widgets (scoped to the selected agent) --
    pub field: Field,
    pub send_buf: String,
    pub named_sel: usize,
    pub resize_buf: String,
    /// Latest screen snapshot for the attached agent (right pane).
    pub latest: Option<ScreenSnapshot>,
    /// Vertical scroll offset into the sidebar (first visible row).
    pub scroll: usize,
    /// Last (rows, cols) we told the attached agent to size its PTY to. Used to
    /// suppress redundant Resize frames and to size a newly-attached agent.
    pub pane_size: Option<(u16, u16)>,
    /// Whether the Debug widget panel is shown. Hidden by default; toggled with
    /// F3. When hidden, the F2 focus cycle skips Debug and the pane gets the
    /// full right column.
    pub debug_visible: bool,
    pub status: String,
    pub should_quit: bool,
}

impl Default for Dashboard {
    fn default() -> Self {
        Dashboard {
            agents: Vec::new(),
            selected: 0,
            attached: None,
            focus: Focus::List,
            field: Field::SendKeys,
            send_buf: String::new(),
            named_sel: 0,
            resize_buf: String::new(),
            latest: None,
            scroll: 0,
            pane_size: None,
            debug_visible: false,
            status: "F2 focus · F3 debug · Enter switch · F10 quit".into(),
            should_quit: false,
        }
    }
}

impl Dashboard {
    pub fn new() -> Dashboard {
        Dashboard::default()
    }

    /// Instance id of the selected row, if any.
    pub fn selected_instance(&self) -> Option<&str> {
        self.agents.get(self.selected).map(|a| a.instance_id.as_str())
    }

    /// Merge a fresh agent list from the daemon, preserving the current
    /// selection *by instance id* across reorders/additions/removals. Keeps the
    /// selection index in range and the scroll window sane.
    pub fn update_agents(&mut self, agents: Vec<AgentRow>) {
        let prev = self.selected_instance().map(|s| s.to_string());
        self.agents = agents;
        if let Some(prev) = prev {
            if let Some(i) = self.agents.iter().position(|a| a.instance_id == prev) {
                self.selected = i;
            } else if self.selected >= self.agents.len() {
                self.selected = self.agents.len().saturating_sub(1);
            }
        } else if self.selected >= self.agents.len() {
            self.selected = self.agents.len().saturating_sub(1);
        }
    }

    /// Store a screen snapshot iff it belongs to the attached agent (drops
    /// late frames from a previously-attached agent after a switch).
    pub fn on_screen(&mut self, instance: &str, screen: ScreenSnapshot) {
        if self.attached.as_deref() == Some(instance) {
            self.latest = Some(screen);
        }
    }

    /// Handle one key event, mutating state + returning any daemon messages.
    pub fn handle_key(&mut self, key: Key) -> Outcome {
        match key {
            Key::Quit => {
                self.should_quit = true;
                // Detach from whatever we're viewing so the daemon stops
                // streaming to us; the child stays alive.
                return match self.attached.take() {
                    Some(inst) => Outcome::one(CtlMsg::Detach { instance: inst }),
                    None => Outcome::none(),
                };
            }
            Key::ToggleFocus => {
                // Cycle List -> Pane -> (Debug if shown) -> List.
                self.focus = match self.focus {
                    Focus::List => Focus::Pane,
                    Focus::Pane if self.debug_visible => Focus::Debug,
                    Focus::Pane => Focus::List,
                    Focus::Debug => Focus::List,
                };
                self.set_focus_status();
                return Outcome::none();
            }
            Key::ToggleDebug => {
                self.toggle_debug();
                return Outcome::none();
            }
            _ => {}
        }

        match self.focus {
            Focus::List => self.handle_list_key(key),
            Focus::Pane => self.handle_pane_key(key),
            Focus::Debug => self.handle_debug_key(key),
        }
    }

    /// Show/hide the debug panel (F3). Hidden by default. When hiding while it
    /// held focus, focus falls back to the pane so keystrokes stay meaningful.
    pub fn toggle_debug(&mut self) {
        self.debug_visible = !self.debug_visible;
        if !self.debug_visible && self.focus == Focus::Debug {
            self.focus = Focus::Pane;
        }
        self.status = if self.debug_visible {
            "debug panel shown (F3 to hide)".into()
        } else {
            "debug panel hidden (F3 to show)".into()
        };
    }

    /// Directly focus a section (used by header clicks). Focusing Debug also
    /// reveals it if it was hidden, so a click on the (hidden) debug header via
    /// its toggle affordance still works.
    pub fn focus_section(&mut self, section: Focus) {
        if section == Focus::Debug {
            self.debug_visible = true;
        }
        self.focus = section;
        self.set_focus_status();
    }

    fn set_focus_status(&mut self) {
        self.status = match self.focus {
            Focus::List => "LIST focus: Up/Down select · Enter switches".into(),
            Focus::Pane => "PANE focus: keys drive the selected agent".into(),
            Focus::Debug => "DEBUG focus: Tab cycles widgets".into(),
        };
    }

    /// LIST focus: navigate + switch agents.
    fn handle_list_key(&mut self, key: Key) -> Outcome {
        match key {
            Key::Up => {
                if self.selected > 0 {
                    self.selected -= 1;
                }
                Outcome::none()
            }
            Key::Down => {
                if self.selected + 1 < self.agents.len() {
                    self.selected += 1;
                }
                Outcome::none()
            }
            Key::Home => {
                self.selected = 0;
                Outcome::none()
            }
            Key::End => {
                self.selected = self.agents.len().saturating_sub(1);
                Outcome::none()
            }
            Key::Enter => self.switch_to_selected(),
            _ => Outcome::none(),
        }
    }

    /// Switch the attached/streaming agent to the current selection. Emits
    /// `Detach{old}` (if any) + `Attach{new}`. No-op if already attached to it
    /// or if there is no selection.
    pub fn switch_to_selected(&mut self) -> Outcome {
        let target = match self.selected_instance() {
            Some(s) => s.to_string(),
            None => return Outcome::none(),
        };
        if self.attached.as_deref() == Some(target.as_str()) {
            return Outcome::none();
        }
        let mut msgs = Vec::new();
        if let Some(old) = self.attached.take() {
            msgs.push(CtlMsg::Detach { instance: old });
        }
        // New agent: clear the stale screen so we don't show the old one.
        self.latest = None;
        self.attached = Some(target.clone());
        self.status = format!("attached {target}");
        msgs.push(CtlMsg::Attach { instance: target.clone() });
        // Immediately size the newly-attached agent to the current right-pane
        // geometry so its TUI reflows to what we're actually showing.
        if let Some((rows, cols)) = self.pane_size {
            msgs.push(CtlMsg::Resize { instance: target, rows, cols });
        }
        Outcome { messages: msgs }
    }

    /// Notify the dashboard that the RIGHT PANE (the area showing the selected
    /// agent's screen) now measures `rows` x `cols`. Called on terminal resize
    /// (SIGWINCH -> crossterm `Resize`) and once after each attach. When the
    /// geometry actually changes we emit an instance-scoped `Resize` so the
    /// contained process's PTY (and thus its rendered TUI) resizes to match —
    /// keeping the dashboard responsive. Redundant calls are suppressed.
    pub fn on_pane_resize(&mut self, rows: u16, cols: u16) -> Outcome {
        if rows == 0 || cols == 0 {
            return Outcome::none();
        }
        if self.pane_size == Some((rows, cols)) {
            return Outcome::none();
        }
        self.pane_size = Some((rows, cols));
        match &self.attached {
            Some(inst) => Outcome::one(CtlMsg::Resize {
                instance: inst.clone(),
                rows,
                cols,
            }),
            None => Outcome::none(),
        }
    }

    /// Handle a mouse click on sidebar row `row` (0-based, already adjusted for
    /// scroll by the caller): select + switch to it.
    pub fn handle_click_row(&mut self, row: usize) -> Outcome {
        let idx = self.scroll + row;
        if idx >= self.agents.len() {
            return Outcome::none();
        }
        self.selected = idx;
        self.focus = Focus::List;
        self.switch_to_selected()
    }

    /// PANE focus: translate the key to bytes + send as Input to the selected.
    fn handle_pane_key(&mut self, key: Key) -> Outcome {
        let inst = match self.selected_instance() {
            Some(s) => s.to_string(),
            None => return Outcome::none(),
        };
        match key_to_bytes(&key) {
            Some(bytes) => Outcome::one(CtlMsg::Input {
                instance: inst,
                data: bytes,
            }),
            None => Outcome::none(),
        }
    }

    /// DEBUG focus: drive the active widget against the selected agent.
    fn handle_debug_key(&mut self, key: Key) -> Outcome {
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
        let inst = match self.selected_instance() {
            Some(s) => s.to_string(),
            None => return Outcome::none(),
        };
        match self.field {
            Field::SendKeys => self.handle_send_keys(key, inst),
            Field::NamedKeys => self.handle_named_keys(key, inst),
            Field::Resize => self.handle_resize(key, inst),
            Field::Capture => self.handle_capture(key, inst),
        }
    }

    fn handle_send_keys(&mut self, key: Key, inst: String) -> Outcome {
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
                let mut bytes = self.send_buf.clone().into_bytes();
                bytes.push(b'\n');
                self.status = format!("sent {} bytes to {inst}", bytes.len());
                self.send_buf.clear();
                Outcome::one(CtlMsg::Input {
                    instance: inst,
                    data: bytes,
                })
            }
            _ => Outcome::none(),
        }
    }

    fn handle_named_keys(&mut self, key: Key, inst: String) -> Outcome {
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
                let (nk, label): (NamedKey, &str) = NAMED_KEY_CHOICES[self.named_sel];
                self.status = format!("sent {label} to {inst}");
                Outcome::one(CtlMsg::Key {
                    instance: inst,
                    key: nk,
                })
            }
            _ => Outcome::none(),
        }
    }

    fn handle_resize(&mut self, key: Key, inst: String) -> Outcome {
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
                    self.status = format!("resize {inst} -> {rows}x{cols}");
                    self.resize_buf.clear();
                    Outcome::one(CtlMsg::Resize {
                        instance: inst,
                        rows,
                        cols,
                    })
                }
                None => {
                    self.status = "resize: type ROWSxCOLS e.g. 40x120".into();
                    Outcome::none()
                }
            },
            _ => Outcome::none(),
        }
    }

    fn handle_capture(&mut self, key: Key, inst: String) -> Outcome {
        match key {
            Key::Enter => {
                self.status = format!("requested capture of {inst}");
                Outcome::one(CtlMsg::Capture { instance: inst })
            }
            _ => Outcome::none(),
        }
    }

    /// Recompute the scroll window so the selected row is visible given a
    /// viewport that can show `height` rows. Returns the (possibly updated)
    /// scroll offset. Called by the renderer before drawing.
    pub fn ensure_visible(&mut self, height: usize) -> usize {
        if height == 0 {
            return self.scroll;
        }
        if self.selected < self.scroll {
            self.scroll = self.selected;
        } else if self.selected >= self.scroll + height {
            self.scroll = self.selected + 1 - height;
        }
        self.scroll
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(ids: &[&str]) -> Vec<AgentRow> {
        ids.iter()
            .map(|id| AgentRow {
                instance_id: (*id).into(),
                program: "/bin/zsh".into(),
                alive: true,
                last_activity: 0,
                bridge_label: None,
            })
            .collect()
    }

    fn dash(ids: &[&str]) -> Dashboard {
        let mut d = Dashboard::new();
        d.update_agents(rows(ids));
        d
    }

    #[test]
    fn debug_hidden_by_default_and_f2_cycles_list_pane_only() {
        let mut d = dash(&["a"]);
        assert!(!d.debug_visible, "debug must be hidden by default");
        assert_eq!(d.focus, Focus::List);
        d.handle_key(Key::ToggleFocus);
        assert_eq!(d.focus, Focus::Pane);
        // With debug hidden, F2 skips Debug and wraps back to List.
        d.handle_key(Key::ToggleFocus);
        assert_eq!(d.focus, Focus::List);
    }

    #[test]
    fn f3_toggles_debug_and_f2_then_includes_it() {
        let mut d = dash(&["a"]);
        d.handle_key(Key::ToggleDebug);
        assert!(d.debug_visible);
        // Now the cycle includes Debug.
        d.handle_key(Key::ToggleFocus); // Pane
        d.handle_key(Key::ToggleFocus); // Debug
        assert_eq!(d.focus, Focus::Debug);
        d.handle_key(Key::ToggleFocus); // List
        assert_eq!(d.focus, Focus::List);
        // Hiding again returns to hidden.
        d.handle_key(Key::ToggleDebug);
        assert!(!d.debug_visible);
    }

    #[test]
    fn hiding_debug_while_focused_falls_back_to_pane() {
        let mut d = dash(&["a"]);
        d.focus_section(Focus::Debug);
        assert_eq!(d.focus, Focus::Debug);
        assert!(d.debug_visible);
        d.toggle_debug(); // hide
        assert!(!d.debug_visible);
        assert_eq!(d.focus, Focus::Pane, "focus must leave the now-hidden debug");
    }

    #[test]
    fn focus_section_sets_focus_and_reveals_debug() {
        let mut d = dash(&["a"]);
        d.focus_section(Focus::Pane);
        assert_eq!(d.focus, Focus::Pane);
        assert!(!d.debug_visible);
        // Focusing Debug via a header click reveals it.
        d.focus_section(Focus::Debug);
        assert_eq!(d.focus, Focus::Debug);
        assert!(d.debug_visible);
        d.focus_section(Focus::List);
        assert_eq!(d.focus, Focus::List);
    }

    #[test]
    fn list_up_down_moves_selection_clamped() {
        let mut d = dash(&["a", "b", "c"]);
        assert_eq!(d.selected, 0);
        d.handle_key(Key::Up); // clamp at 0
        assert_eq!(d.selected, 0);
        d.handle_key(Key::Down);
        assert_eq!(d.selected, 1);
        d.handle_key(Key::Down);
        assert_eq!(d.selected, 2);
        d.handle_key(Key::Down); // clamp at last
        assert_eq!(d.selected, 2);
        d.handle_key(Key::Up);
        assert_eq!(d.selected, 1);
    }

    #[test]
    fn home_end_jump_selection() {
        let mut d = dash(&["a", "b", "c", "d"]);
        d.handle_key(Key::End);
        assert_eq!(d.selected, 3);
        d.handle_key(Key::Home);
        assert_eq!(d.selected, 0);
    }

    #[test]
    fn enter_switches_and_emits_attach() {
        let mut d = dash(&["a", "b"]);
        d.handle_key(Key::Down); // select b
        let out = d.handle_key(Key::Enter);
        assert_eq!(
            out.messages,
            vec![CtlMsg::Attach { instance: "b".into() }]
        );
        assert_eq!(d.attached.as_deref(), Some("b"));
    }

    #[test]
    fn switching_agent_detaches_old_then_attaches_new() {
        let mut d = dash(&["a", "b"]);
        // Attach a.
        let out = d.handle_key(Key::Enter);
        assert_eq!(out.messages, vec![CtlMsg::Attach { instance: "a".into() }]);
        // Move to b + switch.
        d.handle_key(Key::Down);
        let out = d.handle_key(Key::Enter);
        assert_eq!(
            out.messages,
            vec![
                CtlMsg::Detach { instance: "a".into() },
                CtlMsg::Attach { instance: "b".into() },
            ]
        );
        assert_eq!(d.attached.as_deref(), Some("b"));
    }

    #[test]
    fn re_selecting_attached_agent_is_noop() {
        let mut d = dash(&["a", "b"]);
        d.handle_key(Key::Enter); // attach a
        let out = d.handle_key(Key::Enter); // enter again on a
        assert!(out.messages.is_empty());
        assert_eq!(d.attached.as_deref(), Some("a"));
    }

    #[test]
    fn switch_clears_stale_screen() {
        let mut d = dash(&["a", "b"]);
        d.handle_key(Key::Enter); // attach a
        d.on_screen(
            "a",
            ScreenSnapshot {
                rows: 1,
                cols: 1,
                cursor_row: 0,
                cursor_col: 0,
                lines: vec!["A".into()],
            },
        );
        assert!(d.latest.is_some());
        d.handle_key(Key::Down);
        d.handle_key(Key::Enter); // switch to b
        assert!(d.latest.is_none(), "stale screen must be cleared on switch");
    }

    #[test]
    fn on_screen_ignores_non_attached_instance() {
        let mut d = dash(&["a", "b"]);
        d.handle_key(Key::Enter); // attach a
        d.on_screen(
            "b",
            ScreenSnapshot {
                rows: 1,
                cols: 1,
                cursor_row: 0,
                cursor_col: 0,
                lines: vec!["B".into()],
            },
        );
        assert!(d.latest.is_none(), "late frame from non-attached agent must be dropped");
    }

    #[test]
    fn click_row_selects_switches_and_focuses_list() {
        let mut d = dash(&["a", "b", "c"]);
        d.focus = Focus::Pane;
        let out = d.handle_click_row(2); // click 3rd row
        assert_eq!(d.selected, 2);
        assert_eq!(d.focus, Focus::List);
        assert_eq!(out.messages, vec![CtlMsg::Attach { instance: "c".into() }]);
    }

    #[test]
    fn click_respects_scroll_offset() {
        let mut d = dash(&["a", "b", "c", "d", "e"]);
        d.scroll = 2; // rows c,d,e visible
        let out = d.handle_click_row(1); // -> index 3 = d
        assert_eq!(d.selected, 3);
        assert_eq!(out.messages, vec![CtlMsg::Attach { instance: "d".into() }]);
    }

    #[test]
    fn click_out_of_range_is_noop() {
        let mut d = dash(&["a", "b"]);
        let out = d.handle_click_row(9);
        assert!(out.messages.is_empty());
    }

    #[test]
    fn pane_focus_sends_instance_scoped_input() {
        let mut d = dash(&["a", "b"]);
        d.handle_key(Key::Down); // select b
        d.focus = Focus::Pane;
        let out = d.handle_key(Key::Char('x'));
        assert_eq!(
            out.messages,
            vec![CtlMsg::Input { instance: "b".into(), data: b"x".to_vec() }]
        );
    }

    #[test]
    fn debug_send_keys_scoped_to_selected() {
        let mut d = dash(&["a", "b"]);
        d.handle_key(Key::Down); // select b
        d.focus = Focus::Debug; // SendKeys active
        for c in "ls".chars() {
            d.handle_key(Key::Char(c));
        }
        let out = d.handle_key(Key::Enter);
        assert_eq!(
            out.messages,
            vec![CtlMsg::Input { instance: "b".into(), data: b"ls\n".to_vec() }]
        );
    }

    #[test]
    fn debug_tab_cycles_widgets_and_named_key_scoped() {
        let mut d = dash(&["a"]);
        d.focus = Focus::Debug;
        assert_eq!(d.field, Field::SendKeys);
        d.handle_key(Key::Tab);
        assert_eq!(d.field, Field::NamedKeys);
        let out = d.handle_key(Key::Enter); // named_sel 0 = Enter
        assert_eq!(
            out.messages,
            vec![CtlMsg::Key { instance: "a".into(), key: NamedKey::Enter }]
        );
    }

    #[test]
    fn debug_resize_scoped_to_selected() {
        let mut d = dash(&["a"]);
        d.focus = Focus::Debug;
        d.handle_key(Key::Tab);
        d.handle_key(Key::Tab); // -> Resize
        assert_eq!(d.field, Field::Resize);
        for c in "40x120".chars() {
            d.handle_key(Key::Char(c));
        }
        let out = d.handle_key(Key::Enter);
        assert_eq!(
            out.messages,
            vec![CtlMsg::Resize { instance: "a".into(), rows: 40, cols: 120 }]
        );
    }

    #[test]
    fn debug_capture_scoped_to_selected() {
        let mut d = dash(&["a"]);
        d.focus = Focus::Debug;
        d.handle_key(Key::Tab);
        d.handle_key(Key::Tab);
        d.handle_key(Key::Tab); // -> Capture
        assert_eq!(d.field, Field::Capture);
        let out = d.handle_key(Key::Enter);
        assert_eq!(out.messages, vec![CtlMsg::Capture { instance: "a".into() }]);
    }

    #[test]
    fn quit_detaches_attached_and_sets_flag() {
        let mut d = dash(&["a"]);
        d.handle_key(Key::Enter); // attach a
        let out = d.handle_key(Key::Quit);
        assert!(d.should_quit);
        assert_eq!(out.messages, vec![CtlMsg::Detach { instance: "a".into() }]);
    }

    #[test]
    fn quit_without_attach_emits_nothing() {
        let mut d = dash(&["a"]);
        let out = d.handle_key(Key::Quit);
        assert!(d.should_quit);
        assert!(out.messages.is_empty());
    }

    #[test]
    fn update_agents_preserves_selection_by_id() {
        let mut d = dash(&["a", "b", "c"]);
        d.handle_key(Key::Down); // select b
        assert_eq!(d.selected_instance(), Some("b"));
        // Reorder: b moves to the front.
        d.update_agents(rows(&["b", "a", "c"]));
        assert_eq!(d.selected_instance(), Some("b"), "selection must follow the id");
        assert_eq!(d.selected, 0);
    }

    #[test]
    fn update_agents_handles_removed_selection() {
        let mut d = dash(&["a", "b", "c"]);
        d.handle_key(Key::Down);
        d.handle_key(Key::Down); // select c (idx 2)
        d.update_agents(rows(&["a", "b"])); // c removed
        assert!(d.selected < d.agents.len());
        assert_eq!(d.selected, 1);
    }

    #[test]
    fn update_agents_from_empty_to_populated() {
        let mut d = Dashboard::new();
        assert_eq!(d.selected_instance(), None);
        d.update_agents(rows(&["a", "b"]));
        assert_eq!(d.selected, 0);
        assert_eq!(d.selected_instance(), Some("a"));
    }

    #[test]
    fn ensure_visible_scrolls_window() {
        let mut d = dash(&["a", "b", "c", "d", "e", "f"]);
        // Viewport of 3 rows. Select last -> scroll so it shows.
        d.selected = 5;
        let s = d.ensure_visible(3);
        assert_eq!(s, 3); // rows d,e,f
        // Select first -> scroll back to top.
        d.selected = 0;
        let s = d.ensure_visible(3);
        assert_eq!(s, 0);
    }

    #[test]
    fn pane_resize_emits_instance_scoped_resize() {
        let mut d = dash(&["a", "b"]);
        d.handle_key(Key::Enter); // attach a
        let out = d.on_pane_resize(40, 120);
        assert_eq!(
            out.messages,
            vec![CtlMsg::Resize { instance: "a".into(), rows: 40, cols: 120 }]
        );
        // Redundant same-size call is suppressed.
        assert!(d.on_pane_resize(40, 120).messages.is_empty());
        // A different size resizes again.
        let out = d.on_pane_resize(50, 200);
        assert_eq!(
            out.messages,
            vec![CtlMsg::Resize { instance: "a".into(), rows: 50, cols: 200 }]
        );
    }

    #[test]
    fn pane_resize_without_attach_records_but_emits_nothing() {
        let mut d = dash(&["a"]);
        let out = d.on_pane_resize(30, 100);
        assert!(out.messages.is_empty(), "no attach yet -> nothing to resize");
        assert_eq!(d.pane_size, Some((30, 100)));
    }

    #[test]
    fn attach_after_known_pane_size_resizes_new_agent() {
        let mut d = dash(&["a", "b"]);
        // Terminal geometry learned before any attach.
        assert!(d.on_pane_resize(45, 160).messages.is_empty());
        // Attaching a now also sizes it to the known geometry.
        let out = d.handle_key(Key::Enter);
        assert_eq!(
            out.messages,
            vec![
                CtlMsg::Attach { instance: "a".into() },
                CtlMsg::Resize { instance: "a".into(), rows: 45, cols: 160 },
            ]
        );
    }

    #[test]
    fn switching_agent_sizes_the_new_agent_too() {
        let mut d = dash(&["a", "b"]);
        d.on_pane_resize(40, 120);
        d.handle_key(Key::Enter); // attach a (+resize a)
        d.handle_key(Key::Down);
        let out = d.handle_key(Key::Enter); // switch to b
        assert_eq!(
            out.messages,
            vec![
                CtlMsg::Detach { instance: "a".into() },
                CtlMsg::Attach { instance: "b".into() },
                CtlMsg::Resize { instance: "b".into(), rows: 40, cols: 120 },
            ]
        );
    }

    #[test]
    fn bridge_label_is_carried() {
        let mut d = Dashboard::new();
        d.update_agents(vec![AgentRow {
            instance_id: "a".into(),
            program: "claude".into(),
            alive: true,
            last_activity: 123,
            bridge_label: Some("claude · repoX".into()),
        }]);
        assert_eq!(
            d.agents[0].bridge_label.as_deref(),
            Some("claude · repoX")
        );
    }
}
