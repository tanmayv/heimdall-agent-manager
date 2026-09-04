//! Fullscreen agent selector state machine for `ham-pty-host attach --instance`.
//!
//! When the user presses Ctrl-Space while attached to a single agent instance,
//! the client opens a fullscreen selector overlay drawn on the terminal's alternate
//! screen (`ESC[?1049h` / `ESC[?1049l`).
//!
//! This module provides a pure, testable state machine for:
//! - Storing registered agents (instance id, program/command, directory, runtime, pid, alive status)
//! - Maintaining an interactive fuzzy/subsequence filter query
//! - Keyboard navigation (Up/Down, PageUp/PageDown, Home/End)
//! - Selection confirmation (Enter) and cancellation (Esc / Ctrl-C / Ctrl-Space)

use crate::dashboard_tui::Key;

/// One selectable item in the agent selector list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SelectorItem {
    pub instance_id: String,
    pub program: String,
    pub cwd: Option<String>,
    pub runtime_secs: u64,
    pub pid: i32,
    pub alive: bool,
    pub last_activity_secs: u64,
}

impl SelectorItem {
    /// Format runtime in human-readable form (e.g. "12m34s", "2h15m", "45s").
    pub fn format_runtime(&self) -> String {
        let s = self.runtime_secs;
        if s < 60 {
            format!("{s}s")
        } else if s < 3600 {
            format!("{}m{:02}s", s / 60, s % 60)
        } else {
            format!("{}h{:02}m", s / 3600, (s % 3600) / 60)
        }
    }

    /// Format activity idle time (e.g. "active now", "active 2s ago", "idle 5m").
    pub fn format_activity(&self, now: u64) -> String {
        if self.last_activity_secs == 0 || now < self.last_activity_secs {
            return "active".into();
        }
        let diff = now - self.last_activity_secs;
        if diff < 5 {
            "active now".into()
        } else if diff < 60 {
            format!("{diff}s ago")
        } else if diff < 3600 {
            format!("idle {}m", diff / 60)
        } else {
            format!("idle {}h", diff / 3600)
        }
    }
}

/// Outcome of handling a key event in the selector.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SelectorAction {
    /// Keep selector open; state updated (query changed or selection moved).
    None,
    /// Cancel selector and return to the current agent without switching.
    Cancel,
    /// Confirm selection and switch to the chosen agent instance id.
    Switch(String),
}

/// Pure state machine for the fullscreen agent selector.
#[derive(Clone, Debug)]
pub struct SelectorState {
    pub all_items: Vec<SelectorItem>,
    pub filtered_indices: Vec<usize>,
    pub query: String,
    pub selected: usize,
    pub scroll: usize,
    pub current_instance: String,
}

impl SelectorState {
    pub fn new(current_instance: impl Into<String>, items: Vec<SelectorItem>) -> Self {
        let current = current_instance.into();
        let mut state = SelectorState {
            all_items: items,
            filtered_indices: Vec::new(),
            query: String::new(),
            selected: 0,
            scroll: 0,
            current_instance: current,
        };
        state.refilter();
        // Default highlight to the current instance if present, else top item
        if let Some(pos) = state
            .filtered_indices
            .iter()
            .position(|&idx| state.all_items[idx].instance_id == state.current_instance)
        {
            state.selected = pos;
        }
        state
    }

    pub fn set_items(&mut self, items: Vec<SelectorItem>) {
        let prev_selected_inst = self.selected_item().map(|it| it.instance_id.clone());
        self.all_items = items;
        self.refilter();
        if let Some(target) = prev_selected_inst {
            if let Some(pos) = self
                .filtered_indices
                .iter()
                .position(|&idx| self.all_items[idx].instance_id == target)
            {
                self.selected = pos;
            }
        }
    }

    /// Update fuzzy / subsequence search filter based on current `query`.
    pub fn refilter(&mut self) {
        let q = self.query.trim().to_lowercase();
        if q.is_empty() {
            self.filtered_indices = (0..self.all_items.len()).collect();
        } else {
            self.filtered_indices = self
                .all_items
                .iter()
                .enumerate()
                .filter(|(_, item)| item_matches(item, &q))
                .map(|(i, _)| i)
                .collect();
        }

        if self.filtered_indices.is_empty() {
            self.selected = 0;
            self.scroll = 0;
        } else if self.selected >= self.filtered_indices.len() {
            self.selected = self.filtered_indices.len() - 1;
        }
    }

    pub fn selected_item(&self) -> Option<&SelectorItem> {
        if self.filtered_indices.is_empty() || self.selected >= self.filtered_indices.len() {
            None
        } else {
            let actual_idx = self.filtered_indices[self.selected];
            self.all_items.get(actual_idx)
        }
    }

    pub fn ensure_visible(&mut self, viewport_height: usize) -> usize {
        if viewport_height == 0 || self.filtered_indices.is_empty() {
            self.scroll = 0;
            return 0;
        }
        if self.selected < self.scroll {
            self.scroll = self.selected;
        } else if self.selected >= self.scroll + viewport_height {
            self.scroll = self.selected + 1 - viewport_height;
        }
        self.scroll
    }

    /// Handle one key event. Returns [`SelectorAction`].
    pub fn handle_key(&mut self, key: Key) -> SelectorAction {
        match key {
            // Cancellation keys
            Key::Esc | Key::Ctrl('c') | Key::Ctrl(' ') => SelectorAction::Cancel,
            Key::Enter => {
                if let Some(item) = self.selected_item() {
                    SelectorAction::Switch(item.instance_id.clone())
                } else {
                    SelectorAction::None
                }
            }
            Key::Up => {
                if self.selected > 0 {
                    self.selected -= 1;
                }
                SelectorAction::None
            }
            Key::Down => {
                if !self.filtered_indices.is_empty() && self.selected + 1 < self.filtered_indices.len() {
                    self.selected += 1;
                }
                SelectorAction::None
            }
            Key::PageUp => {
                self.selected = self.selected.saturating_sub(10);
                SelectorAction::None
            }
            Key::PageDown => {
                if !self.filtered_indices.is_empty() {
                    self.selected = (self.selected + 10).min(self.filtered_indices.len() - 1);
                }
                SelectorAction::None
            }
            Key::Home => {
                self.selected = 0;
                SelectorAction::None
            }
            Key::End => {
                if !self.filtered_indices.is_empty() {
                    self.selected = self.filtered_indices.len() - 1;
                }
                SelectorAction::None
            }
            Key::Backspace => {
                if self.query.pop().is_some() {
                    self.refilter();
                }
                SelectorAction::None
            }
            Key::Ctrl('u') => {
                if !self.query.is_empty() {
                    self.query.clear();
                    self.refilter();
                }
                SelectorAction::None
            }
            Key::Ctrl('w') => {
                // Delete word
                let trimmed = self.query.trim_end();
                if let Some(last_space) = trimmed.rfind(' ') {
                    self.query.truncate(last_space + 1);
                } else {
                    self.query.clear();
                }
                self.refilter();
                SelectorAction::None
            }
            Key::Char(c) => {
                self.query.push(c);
                self.refilter();
                SelectorAction::None
            }
            _ => SelectorAction::None,
        }
    }
}

/// Check if item matches query (matches against instance_id, program, cwd, or pid).
fn item_matches(item: &SelectorItem, query: &str) -> bool {
    let inst = item.instance_id.to_lowercase();
    let prog = item.program.to_lowercase();
    let cwd = item.cwd.as_deref().unwrap_or("").to_lowercase();
    let pid_str = item.pid.to_string();

    // Check simple substring match first
    if inst.contains(query) || prog.contains(query) || cwd.contains(query) || pid_str.contains(query) {
        return true;
    }

    // Check fuzzy subsequence match against instance_id, program, or cwd
    subsequence_match(&inst, query)
        || subsequence_match(&prog, query)
        || subsequence_match(&cwd, query)
}

/// Case-insensitive fuzzy subsequence search: all query chars must appear in target in order.
fn subsequence_match(target: &str, query: &str) -> bool {
    let mut query_chars = query.chars();
    let mut current_q = match query_chars.next() {
        Some(c) => c,
        None => return true,
    };

    for t in target.chars() {
        if t == current_q {
            match query_chars.next() {
                Some(c) => current_q = c,
                None => return true,
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_items() -> Vec<SelectorItem> {
        vec![
            SelectorItem {
                instance_id: "inst_alpha".into(),
                program: "jetski".into(),
                cwd: Some("/home/user/repo-a".into()),
                runtime_secs: 125,
                pid: 1001,
                alive: true,
                last_activity_secs: 100,
            },
            SelectorItem {
                instance_id: "inst_beta".into(),
                program: "claude".into(),
                cwd: Some("/home/user/repo-b".into()),
                runtime_secs: 3600,
                pid: 1002,
                alive: true,
                last_activity_secs: 90,
            },
            SelectorItem {
                instance_id: "inst_gamma".into(),
                program: "pi".into(),
                cwd: Some("/tmp/workdir".into()),
                runtime_secs: 45,
                pid: 1003,
                alive: false,
                last_activity_secs: 10,
            },
        ]
    }

    #[test]
    fn test_selector_init_and_switch() {
        let items = sample_items();
        let mut state = SelectorState::new("inst_beta", items);
        assert_eq!(state.selected, 1);
        assert_eq!(state.selected_item().unwrap().instance_id, "inst_beta");

        // Move up
        assert_eq!(state.handle_key(Key::Up), SelectorAction::None);
        assert_eq!(state.selected, 0);
        assert_eq!(state.selected_item().unwrap().instance_id, "inst_alpha");

        // Enter triggers switch
        assert_eq!(
            state.handle_key(Key::Enter),
            SelectorAction::Switch("inst_alpha".into())
        );
    }

    #[test]
    fn test_selector_filtering() {
        let items = sample_items();
        let mut state = SelectorState::new("inst_alpha", items);

        // Filter by program "claude"
        for c in "claude".chars() {
            state.handle_key(Key::Char(c));
        }
        assert_eq!(state.filtered_indices.len(), 1);
        assert_eq!(state.selected_item().unwrap().instance_id, "inst_beta");

        // Backspace
        for _ in 0..6 {
            state.handle_key(Key::Backspace);
        }
        assert_eq!(state.filtered_indices.len(), 3);

        // Subsequence filter "gam" -> inst_gamma
        for c in "gam".chars() {
            state.handle_key(Key::Char(c));
        }
        assert_eq!(state.filtered_indices.len(), 1);
        assert_eq!(state.selected_item().unwrap().instance_id, "inst_gamma");
    }

    #[test]
    fn test_selector_cancellation() {
        let items = sample_items();
        let mut state = SelectorState::new("inst_alpha", items);

        assert_eq!(state.handle_key(Key::Esc), SelectorAction::Cancel);
        assert_eq!(state.handle_key(Key::Ctrl('c')), SelectorAction::Cancel);
        assert_eq!(state.handle_key(Key::Ctrl(' ')), SelectorAction::Cancel);
    }

    #[test]
    fn test_format_runtime_and_activity() {
        let item = SelectorItem {
            instance_id: "inst_1".into(),
            program: "agent".into(),
            cwd: None,
            runtime_secs: 75,
            pid: 123,
            alive: true,
            last_activity_secs: 1000,
        };
        assert_eq!(item.format_runtime(), "1m15s");
        assert_eq!(item.format_activity(1002), "active now");
        assert_eq!(item.format_activity(1030), "30s ago");
        assert_eq!(item.format_activity(1300), "idle 5m");
    }
}
