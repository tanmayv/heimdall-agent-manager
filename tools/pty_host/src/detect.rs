//! REQ HOST-2: Config-driven startup detection (auto-enter + blocked) and a
//! content-change (activity) signal — as a **pure, fully-testable** state
//! machine, decoupled from any PTY/IO.
//!
//! This mirrors the Odin `Startup_Detection_Config` (src/lib/config/config.odin)
//! and `startup_probe_agent` (src/wrapper/main.odin) semantics so the bridge can
//! reuse the exact same provider profiles:
//!
//!   * `auto_enter_patterns[]` — when the screen contains one, send that index's
//!     `auto_enter_pre_keys[]` entry (parallel array; space-separated tokens for
//!     multi-key nav like `"Tab Tab"`) followed by Enter.
//!   * `blocked_patterns[]` — when the screen contains one, the agent is blocked
//!     (a login/quota/error prompt we can't auto-dismiss).
//!   * on timeout with no match → Ready, unless `startup_unknown_is_blocked`.
//!
//! Precedence + timing match the Odin probe: auto-enter is checked first (with a
//! 2s cooldown after firing + a probe-window deadline extension so dismissing a
//! prompt doesn't eat the ready budget), then blocked, then keep waiting.
//!
//! The detector is driven by [`Detector::step`], which the daemon calls once per
//! `capture_interval_ms` with the current rendered screen text and a monotonic
//! clock in milliseconds. It returns [`DetectAction`]s the caller performs
//! (send keys, emit an event). No timing or IO lives here, so it is exhaustively
//! unit-tested with scripted screens + a fake clock.

use crate::proto::NamedKey;

/// Startup-detection config, mirroring the Odin `Startup_Detection_Config`.
/// `auto_enter_pre_keys` is parallel to `auto_enter_patterns`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StartupDetectionConfig {
    pub enabled: bool,
    pub startup_probe_seconds: i64,
    pub capture_interval_ms: i64,
    pub blocked_patterns: Vec<String>,
    pub auto_enter_patterns: Vec<String>,
    /// Parallel to `auto_enter_patterns`; each is a space-separated key-token
    /// sequence sent before Enter (e.g. `"Down"`, `"Tab Tab"`). Empty/missing =
    /// just Enter.
    pub auto_enter_pre_keys: Vec<String>,
    pub startup_unknown_is_blocked: bool,
    /// Parallel to `blocked_patterns` by index; `key=human message` entries used
    /// to produce a sanitized diagnostic (see [`safe_diagnostic`]).
    pub sanitized_reason_mapping: Vec<String>,
}

impl StartupDetectionConfig {
    /// Effective probe window (seconds), defaulting like the Odin probe (15).
    pub fn probe_seconds(&self) -> i64 {
        if self.startup_probe_seconds <= 0 {
            15
        } else {
            self.startup_probe_seconds
        }
    }

    /// Effective capture interval (ms), defaulting like the Odin probe (500).
    pub fn interval_ms(&self) -> i64 {
        if self.capture_interval_ms <= 0 {
            500
        } else {
            self.capture_interval_ms
        }
    }

    /// Parse the `detect` JSON blob carried on a `SpawnRequest`. Hand-rolled (no
    /// serde), matching the dproto style + the Odin
    /// `wrapper_bridge_parse_startup_detection` field names. Unknown fields are
    /// ignored; a blank/`None` blob yields a disabled (zero) config.
    pub fn from_json(blob: &str) -> StartupDetectionConfig {
        let mut c = StartupDetectionConfig::default();
        if blob.trim().is_empty() {
            return c;
        }
        c.enabled = json_bool(blob, "enabled").unwrap_or(false);
        c.startup_probe_seconds = json_int(blob, "startup_probe_seconds")
            .or_else(|| json_int(blob, "probe_seconds"))
            .unwrap_or(0);
        c.capture_interval_ms = json_int(blob, "capture_interval_ms").unwrap_or(0);
        c.blocked_patterns = json_string_array(blob, "blocked_patterns");
        c.auto_enter_patterns = json_string_array(blob, "auto_enter_patterns");
        c.auto_enter_pre_keys = json_string_array(blob, "auto_enter_pre_keys");
        c.startup_unknown_is_blocked =
            json_bool(blob, "startup_unknown_is_blocked").unwrap_or(false);
        c.sanitized_reason_mapping = json_string_array(blob, "sanitized_reason_mapping");
        c
    }
}

/// Terminal outcome of startup detection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StartupOutcome {
    /// No blocked pattern matched within the probe window (or unknown allowed).
    Ready,
    /// A blocked pattern matched, or timeout with `startup_unknown_is_blocked`.
    Blocked {
        reason_code: String,
        safe_diagnostic: String,
    },
}

/// One action the caller should perform as a result of [`Detector::step`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DetectAction {
    /// Send this key sequence to the child (pre-keys then Enter get flattened
    /// into a single ordered list; the caller writes each in turn).
    SendKeys(Vec<NamedKey>),
    /// Startup detection finished; emit the corresponding event + stop ticking.
    Finished(StartupOutcome),
}

/// The per-agent startup detector. Pure: no clock, no IO. The daemon calls
/// [`Detector::step`] every `capture_interval_ms` with the current screen text
/// and a monotonic millisecond timestamp.
#[derive(Clone, Debug)]
pub struct Detector {
    cfg: StartupDetectionConfig,
    /// Absolute deadline (ms) after which we give up waiting.
    deadline_ms: i64,
    probe_window_ms: i64,
    /// Don't re-fire auto-enter until this time (ms). Prevents re-triggering on
    /// the same buffered prompt before the TUI repaints.
    cooldown_until_ms: i64,
    /// Once finished we latch and emit nothing further.
    done: bool,
}

/// After firing auto-enter we suppress re-firing for this long (matches Odin 2s).
const AUTO_ENTER_COOLDOWN_MS: i64 = 2000;

impl Detector {
    /// Create a detector armed at `now_ms`. If the config is disabled the
    /// detector immediately reports [`StartupOutcome::Ready`] on the first step.
    pub fn new(cfg: StartupDetectionConfig, now_ms: i64) -> Detector {
        let probe_window_ms = cfg.probe_seconds() * 1000;
        Detector {
            deadline_ms: now_ms + probe_window_ms,
            probe_window_ms,
            cooldown_until_ms: 0,
            cfg,
            done: false,
        }
    }

    pub fn is_done(&self) -> bool {
        self.done
    }

    pub fn is_enabled(&self) -> bool {
        self.cfg.enabled
    }

    /// Advance the detector against the current `screen_text` at `now_ms`.
    /// Returns the actions to perform. Once it returns a `Finished`, subsequent
    /// calls return empty.
    pub fn step(&mut self, screen_text: &str, now_ms: i64) -> Vec<DetectAction> {
        if self.done {
            return Vec::new();
        }
        if !self.cfg.enabled {
            self.done = true;
            return vec![DetectAction::Finished(StartupOutcome::Ready)];
        }

        // 1) auto-enter has precedence (dismiss trust/permission prompts).
        if now_ms >= self.cooldown_until_ms {
            if let Some(idx) = first_matching_pattern(screen_text, &self.cfg.auto_enter_patterns) {
                let mut keys = Vec::new();
                if let Some(pre) = self.cfg.auto_enter_pre_keys.get(idx) {
                    for tok in pre.split_whitespace() {
                        if let Some(k) = key_from_token(tok) {
                            keys.push(k);
                        }
                    }
                }
                keys.push(NamedKey::Enter);
                // Cooldown + extend the deadline by a full probe window so
                // dismissing a prompt doesn't eat the ready budget (Odin parity).
                self.cooldown_until_ms = now_ms + AUTO_ENTER_COOLDOWN_MS;
                self.deadline_ms = now_ms + self.probe_window_ms;
                return vec![DetectAction::SendKeys(keys)];
            }
        }

        // 2) blocked patterns → Blocked outcome.
        if let Some(idx) = first_matching_pattern(screen_text, &self.cfg.blocked_patterns) {
            self.done = true;
            let pattern = &self.cfg.blocked_patterns[idx];
            return vec![DetectAction::Finished(StartupOutcome::Blocked {
                reason_code: reason_code("blocked", idx, pattern),
                safe_diagnostic: safe_diagnostic(
                    &self.cfg.sanitized_reason_mapping,
                    idx,
                    "Startup blocked by configured provider prompt",
                ),
            })];
        }

        // 3) timeout.
        if now_ms > self.deadline_ms {
            self.done = true;
            let outcome = if self.cfg.startup_unknown_is_blocked {
                StartupOutcome::Blocked {
                    reason_code: "no_pattern_matched".into(),
                    safe_diagnostic: "No configured startup pattern matched before timeout".into(),
                }
            } else {
                StartupOutcome::Ready
            };
            return vec![DetectAction::Finished(outcome)];
        }

        Vec::new()
    }
}

/// Strip ANSI escape sequences (CSI, OSC, etc.) from `s`.
pub fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            if let Some(&next) = chars.peek() {
                if next == '[' {
                    chars.next();
                    // CSI sequence: consume parameter and intermediate bytes until final byte 0x40..=0x7E
                    while let Some(&b) = chars.peek() {
                        chars.next();
                        if ('\x40'..='\x7e').contains(&b) {
                            break;
                        }
                    }
                    continue;
                } else if next == ']' {
                    chars.next();
                    // OSC sequence: consume until BEL (\x07) or ST (\x1b\\)
                    while let Some(&b) = chars.peek() {
                        chars.next();
                        if b == '\x07' {
                            break;
                        }
                        if b == '\x1b' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                    continue;
                } else if next == '(' || next == ')' {
                    chars.next();
                    chars.next(); // character set designation
                    continue;
                }
            }
        }
        out.push(c);
    }
    out
}

/// Normalize all consecutive whitespace characters (\n, \r, \t, spaces) into a single space.
pub fn normalize_whitespace(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_ws = false;
    for c in s.chars() {
        if c.is_whitespace() {
            if !in_ws {
                out.push(' ');
                in_ws = true;
            }
        } else {
            out.push(c);
            in_ws = false;
        }
    }
    out
}

/// Index of the first non-empty pattern contained in `text`, or `None`.
/// Matches:
/// 1. Exact raw substring
/// 2. ANSI-stripped raw substring
/// 3. Whitespace-normalized substring (collapses newlines, tabs, and spaces so
///    terminal row-wrapping across cols=80/120 or line breaks do not prevent matches)
/// 4. Newline-stripped substring (handles hard terminal row wraps with no intervening space)
pub fn first_matching_pattern(text: &str, patterns: &[String]) -> Option<usize> {
    // 1. Fast path: exact raw substring match
    for (i, p) in patterns.iter().enumerate() {
        if p.is_empty() {
            continue;
        }
        if text.contains(p.as_str()) {
            return Some(i);
        }
    }

    // 2. Normalized matching: strip ANSI escapes and normalize whitespace / newlines
    let text_clean = strip_ansi(text);
    let text_norm_ws = normalize_whitespace(&text_clean);
    let text_no_nl = text_clean.replace(['\n', '\r'], "");

    for (i, p) in patterns.iter().enumerate() {
        if p.is_empty() {
            continue;
        }
        let p_clean = strip_ansi(p);
        if p_clean.is_empty() {
            continue;
        }
        if text_clean.contains(&p_clean) {
            return Some(i);
        }
        let p_norm_ws = normalize_whitespace(&p_clean).trim().to_string();
        if !p_norm_ws.is_empty() && text_norm_ws.contains(&p_norm_ws) {
            return Some(i);
        }
        let p_no_nl = p_clean.replace(['\n', '\r'], "");
        if !p_no_nl.is_empty() && text_no_nl.contains(&p_no_nl) {
            return Some(i);
        }
    }

    None
}

/// Build a stable, sanitized reason code (`<prefix>_<idx><alnum-of-pattern>`),
/// mirroring Odin `startup_reason_code`: keep [A-Za-z0-9], map space/-/_ to `_`,
/// drop everything else.
pub fn reason_code(prefix: &str, idx: usize, pattern: &str) -> String {
    let mut s = format!("{prefix}_{idx}");
    for ch in pattern.chars() {
        match ch {
            'a'..='z' | 'A'..='Z' | '0'..='9' => s.push(ch),
            ' ' | '-' | '_' => s.push('_'),
            _ => {}
        }
    }
    s
}

/// Resolve a human-safe diagnostic from `sanitized_reason_mapping[idx]`
/// (`key=message` → message, or the raw entry), else `fallback`. Mirrors Odin
/// `startup_safe_diagnostic`.
pub fn safe_diagnostic(mapping: &[String], idx: usize, fallback: &str) -> String {
    if let Some(entry) = mapping.get(idx) {
        if let Some(eq) = entry.find('=') {
            if eq + 1 < entry.len() {
                return entry[eq + 1..].to_string();
            }
        }
        if !entry.is_empty() {
            return entry.clone();
        }
    }
    fallback.to_string()
}

/// Translate a config key token (tmux `send-keys` style) into a [`NamedKey`].
/// Supports the common navigation/control tokens used by provider profiles.
/// Case-insensitive. Unknown tokens are dropped (mirrors best-effort send-keys).
pub fn key_from_token(tok: &str) -> Option<NamedKey> {
    let t = tok.trim();
    if t.is_empty() {
        return None;
    }
    Some(match t.to_ascii_lowercase().as_str() {
        "enter" | "return" | "cr" | "c-m" => NamedKey::Enter,
        "esc" | "escape" => NamedKey::Esc,
        "tab" => NamedKey::Tab,
        "up" => NamedKey::Up,
        "down" => NamedKey::Down,
        "left" => NamedKey::Left,
        "right" => NamedKey::Right,
        "space" => return None, // a literal space isn't a NamedKey; handled as input elsewhere
        "bspace" | "backspace" => NamedKey::Backspace,
        "home" => NamedKey::Home,
        "end" => NamedKey::End,
        "pageup" | "ppage" => NamedKey::PageUp,
        "pagedown" | "npage" => NamedKey::PageDown,
        "delete" | "dc" => NamedKey::Delete,
        "c-c" => NamedKey::CtrlC,
        "c-d" => NamedKey::CtrlD,
        _ => return None,
    })
}

/// A cheap content hash used for the ScreenChanged (activity) dirty signal. FNV-1a
/// over the rendered screen text. Not cryptographic — just needs to change when
/// visible content changes so the bridge can classify activity without polling.
///
/// NOTE (spinner masking): a spinner/clock repainting every frame will change
/// this hash continuously. That is intentional here — HOST-2 only emits the raw
/// dirty signal. Masking a spinner as "not real activity" is a bridge-side
/// concern (ported from pane_activity.odin in BR-3), not the host's job.
pub fn screen_hash(text: &str) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in text.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

// ---- minimal JSON field extractors (no serde) ---------------------------
// Match the hand-rolled style used across this crate + the Odin bridge parser.

fn find_key<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let needle = format!("\"{key}\"");
    let start = json.find(&needle)?;
    let after = &json[start + needle.len()..];
    let colon = after.find(':')?;
    Some(after[colon + 1..].trim_start())
}

fn json_bool(json: &str, key: &str) -> Option<bool> {
    let v = find_key(json, key)?;
    if v.starts_with("true") {
        Some(true)
    } else if v.starts_with("false") {
        Some(false)
    } else {
        None
    }
}

fn json_int(json: &str, key: &str) -> Option<i64> {
    let v = find_key(json, key)?;
    let mut end = 0;
    let bytes = v.as_bytes();
    if bytes.first() == Some(&b'-') {
        end += 1;
    }
    while end < bytes.len() && bytes[end].is_ascii_digit() {
        end += 1;
    }
    if end == 0 || (end == 1 && bytes[0] == b'-') {
        return None;
    }
    v[..end].parse::<i64>().ok()
}

/// Parse a JSON array of strings for `key`. Handles `\"` and `\\` escapes; stops
/// at the matching `]`. Returns empty if absent or not an array.
fn json_string_array(json: &str, key: &str) -> Vec<String> {
    let v = match find_key(json, key) {
        Some(v) => v,
        None => return Vec::new(),
    };
    let bytes = v.as_bytes();
    if bytes.first() != Some(&b'[') {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut i = 1; // past '['
    loop {
        // Skip whitespace + commas.
        while i < bytes.len() && (bytes[i] as char).is_whitespace() || (i < bytes.len() && bytes[i] == b',') {
            i += 1;
        }
        if i >= bytes.len() || bytes[i] == b']' {
            break;
        }
        if bytes[i] != b'"' {
            // Not a string element; bail to stay safe.
            break;
        }
        i += 1; // past opening quote
        let mut s = String::new();
        while i < bytes.len() {
            match bytes[i] {
                b'\\' if i + 1 < bytes.len() => {
                    let e = bytes[i + 1];
                    match e {
                        b'n' => s.push('\n'),
                        b't' => s.push('\t'),
                        b'r' => s.push('\r'),
                        b'"' => s.push('"'),
                        b'\\' => s.push('\\'),
                        b'/' => s.push('/'),
                        other => {
                            s.push('\\');
                            s.push(other as char);
                        }
                    }
                    i += 2;
                }
                b'"' => {
                    i += 1;
                    break;
                }
                b => {
                    s.push(b as char);
                    i += 1;
                }
            }
        }
        out.push(s);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg_auto(patterns: &[&str], pre: &[&str]) -> StartupDetectionConfig {
        StartupDetectionConfig {
            enabled: true,
            startup_probe_seconds: 10,
            capture_interval_ms: 100,
            auto_enter_patterns: patterns.iter().map(|s| s.to_string()).collect(),
            auto_enter_pre_keys: pre.iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        }
    }

    #[test]
    fn disabled_config_reports_ready_immediately() {
        let mut d = Detector::new(StartupDetectionConfig::default(), 0);
        let acts = d.step("anything", 0);
        assert_eq!(acts, vec![DetectAction::Finished(StartupOutcome::Ready)]);
        assert!(d.is_done());
        // Subsequent steps are inert.
        assert!(d.step("more", 10).is_empty());
    }

    #[test]
    fn auto_enter_match_sends_prekeys_then_enter() {
        let mut d = cfg_detector(cfg_auto(
            &["Yes, I trust this folder", "Bypass Permissions mode"],
            &["", "Down"],
        ));
        // First pattern → just Enter.
        let acts = d.step("... Yes, I trust this folder ...", 0);
        assert_eq!(acts, vec![DetectAction::SendKeys(vec![NamedKey::Enter])]);
        // Not finished; still probing.
        assert!(!d.is_done());
    }

    #[test]
    fn auto_enter_prekey_down_then_enter() {
        let mut d = cfg_detector(cfg_auto(&["Bypass Permissions mode"], &["Down"]));
        let acts = d.step("WARNING: ... Bypass Permissions mode", 0);
        assert_eq!(
            acts,
            vec![DetectAction::SendKeys(vec![NamedKey::Down, NamedKey::Enter])]
        );
    }

    #[test]
    fn auto_enter_multi_prekey_tokens() {
        let mut d = cfg_detector(cfg_auto(&["pick one"], &["Tab Tab Down"]));
        let acts = d.step("pick one", 0);
        assert_eq!(
            acts,
            vec![DetectAction::SendKeys(vec![
                NamedKey::Tab,
                NamedKey::Tab,
                NamedKey::Down,
                NamedKey::Enter
            ])]
        );
    }

    #[test]
    fn auto_enter_cooldown_prevents_immediate_refire() {
        let mut d = cfg_detector(cfg_auto(&["trust"], &[""]));
        let a1 = d.step("trust", 0);
        assert_eq!(a1, vec![DetectAction::SendKeys(vec![NamedKey::Enter])]);
        // Same text within cooldown (2s) → no action.
        assert!(d.step("trust", 500).is_empty());
        assert!(d.step("trust", 1999).is_empty());
        // After cooldown, it can fire again.
        let a2 = d.step("trust", 2000);
        assert_eq!(a2, vec![DetectAction::SendKeys(vec![NamedKey::Enter])]);
    }

    #[test]
    fn blocked_pattern_finishes_blocked_with_reason() {
        let mut d = cfg_detector(StartupDetectionConfig {
            enabled: true,
            startup_probe_seconds: 10,
            capture_interval_ms: 100,
            blocked_patterns: vec!["Login required".into(), "quota exceeded".into()],
            sanitized_reason_mapping: vec![
                "login=Provider login required".into(),
                "quota=Usage quota exceeded".into(),
            ],
            ..Default::default()
        });
        let acts = d.step("Error: quota exceeded, try again later", 50);
        match &acts[..] {
            [DetectAction::Finished(StartupOutcome::Blocked {
                reason_code,
                safe_diagnostic,
            })] => {
                assert_eq!(reason_code, "blocked_1quota_exceeded");
                assert_eq!(safe_diagnostic, "Usage quota exceeded");
            }
            other => panic!("expected Blocked, got {other:?}"),
        }
        assert!(d.is_done());
    }

    #[test]
    fn auto_enter_takes_precedence_over_blocked() {
        // A screen containing BOTH an auto-enter pattern and a blocked pattern
        // must auto-enter (try to dismiss) rather than immediately block.
        let mut d = cfg_detector(StartupDetectionConfig {
            enabled: true,
            startup_probe_seconds: 10,
            capture_interval_ms: 100,
            auto_enter_patterns: vec!["trust this folder".into()],
            auto_enter_pre_keys: vec!["".into()],
            blocked_patterns: vec!["Login required".into()],
            ..Default::default()
        });
        let acts = d.step("trust this folder\nLogin required", 0);
        assert_eq!(acts, vec![DetectAction::SendKeys(vec![NamedKey::Enter])]);
        assert!(!d.is_done());
    }

    #[test]
    fn timeout_reports_ready_when_unknown_allowed() {
        let mut d = cfg_detector(StartupDetectionConfig {
            enabled: true,
            startup_probe_seconds: 1, // 1s window
            capture_interval_ms: 100,
            startup_unknown_is_blocked: false,
            ..Default::default()
        });
        assert!(d.step("boring", 0).is_empty());
        let acts = d.step("still boring", 1001);
        assert_eq!(acts, vec![DetectAction::Finished(StartupOutcome::Ready)]);
    }

    #[test]
    fn timeout_reports_blocked_when_unknown_is_blocked() {
        let mut d = cfg_detector(StartupDetectionConfig {
            enabled: true,
            startup_probe_seconds: 1,
            capture_interval_ms: 100,
            startup_unknown_is_blocked: true,
            ..Default::default()
        });
        assert!(d.step("boring", 0).is_empty());
        match &d.step("boring", 1001)[..] {
            [DetectAction::Finished(StartupOutcome::Blocked { reason_code, .. })] => {
                assert_eq!(reason_code, "no_pattern_matched");
            }
            other => panic!("expected Blocked timeout, got {other:?}"),
        }
    }

    #[test]
    fn auto_enter_extends_deadline() {
        // Firing auto-enter at t just before the original deadline must extend
        // the window so a subsequent blocked match is still observed.
        let mut d = cfg_detector(StartupDetectionConfig {
            enabled: true,
            startup_probe_seconds: 1, // 1s window
            capture_interval_ms: 100,
            auto_enter_patterns: vec!["trust".into()],
            auto_enter_pre_keys: vec!["".into()],
            blocked_patterns: vec!["blocked now".into()],
            ..Default::default()
        });
        // Fire auto-enter at 900ms (before 1000ms deadline) → extends to 1900.
        let a = d.step("trust", 900);
        assert_eq!(a, vec![DetectAction::SendKeys(vec![NamedKey::Enter])]);
        // At 1500ms we'd have timed out without the extension; instead we still
        // detect the blocked pattern.
        match &d.step("blocked now", 1500)[..] {
            [DetectAction::Finished(StartupOutcome::Blocked { .. })] => {}
            other => panic!("expected Blocked after deadline extension, got {other:?}"),
        }
    }

    #[test]
    fn screen_hash_changes_on_content_change_and_is_stable() {
        let a = screen_hash("line one\nline two");
        let b = screen_hash("line one\nline two");
        let c = screen_hash("line one\nline TWO");
        assert_eq!(a, b, "same content must hash equal (stable)");
        assert_ne!(a, c, "changed content must hash differently");
    }

    #[test]
    fn reason_code_sanitizes() {
        assert_eq!(reason_code("blocked", 2, "Login required!"), "blocked_2Login_required");
        assert_eq!(reason_code("blocked", 0, "quota-exceeded"), "blocked_0quota_exceeded");
    }

    #[test]
    fn safe_diagnostic_maps_or_falls_back() {
        let m = vec!["a=first".to_string(), "raw entry".to_string()];
        assert_eq!(safe_diagnostic(&m, 0, "fb"), "first");
        assert_eq!(safe_diagnostic(&m, 1, "fb"), "raw entry");
        assert_eq!(safe_diagnostic(&m, 9, "fb"), "fb");
    }

    #[test]
    fn key_token_translation() {
        assert_eq!(key_from_token("Down"), Some(NamedKey::Down));
        assert_eq!(key_from_token("down"), Some(NamedKey::Down));
        assert_eq!(key_from_token("Enter"), Some(NamedKey::Enter));
        assert_eq!(key_from_token("Tab"), Some(NamedKey::Tab));
        assert_eq!(key_from_token("C-c"), Some(NamedKey::CtrlC));
        assert_eq!(key_from_token("bogus"), None);
        assert_eq!(key_from_token(""), None);
    }

    #[test]
    fn json_parse_full_config() {
        let blob = r#"{
            "enabled": true,
            "startup_probe_seconds": 20,
            "capture_interval_ms": 250,
            "blocked_patterns": ["Login required", "quota exceeded"],
            "auto_enter_patterns": ["Yes, I trust this folder", "Bypass Permissions mode"],
            "auto_enter_pre_keys": ["", "Down"],
            "startup_unknown_is_blocked": true,
            "sanitized_reason_mapping": ["login=Login required"]
        }"#;
        let c = StartupDetectionConfig::from_json(blob);
        assert!(c.enabled);
        assert_eq!(c.startup_probe_seconds, 20);
        assert_eq!(c.capture_interval_ms, 250);
        assert_eq!(c.blocked_patterns, vec!["Login required", "quota exceeded"]);
        assert_eq!(
            c.auto_enter_patterns,
            vec!["Yes, I trust this folder", "Bypass Permissions mode"]
        );
        assert_eq!(c.auto_enter_pre_keys, vec!["", "Down"]);
        assert!(c.startup_unknown_is_blocked);
        assert_eq!(c.sanitized_reason_mapping, vec!["login=Login required"]);
    }

    #[test]
    fn json_parse_empty_or_blank_is_disabled() {
        assert!(!StartupDetectionConfig::from_json("").enabled);
        assert!(!StartupDetectionConfig::from_json("   ").enabled);
        let c = StartupDetectionConfig::from_json("{}");
        assert!(!c.enabled);
        assert!(c.auto_enter_patterns.is_empty());
    }

    #[test]
    fn strip_ansi_removes_csi_and_osc() {
        let raw = "\x1b[1mBold\x1b[0m and \x1b[38;2;255;0;0mRed\x1b[39m and \x1b]0;Title\x07Text";
        assert_eq!(strip_ansi(raw), "Bold and Red and Text");
    }

    #[test]
    fn normalize_whitespace_collapses_newlines_and_spaces() {
        let raw = "Hello \n  \t world \r\n across   lines";
        assert_eq!(normalize_whitespace(raw), "Hello world across lines");
    }

    #[test]
    fn first_matching_pattern_matches_wrapped_and_colored_prompts() {
        let patterns = vec![
            "Please confirm: Do you trust the authors of this repository and want to proceed? [Yes/no]".to_string(),
            "Choose your color scheme".to_string(),
        ];
        // 1. Text wrapped across lines with newline and leading space
        let screen_wrapped = "Please confirm: Do you trust the authors of this repository and want to proceed?\n [Yes/no]";
        assert_eq!(first_matching_pattern(screen_wrapped, &patterns), Some(0));

        // 2. Text with ANSI color styling and wrapped lines
        let screen_colored_wrapped = "\x1b[1mPlease confirm:\x1b[0m Do you trust the authors of this repository and want to proceed?\n \x1b[32m[Yes/no]\x1b[0m";
        assert_eq!(first_matching_pattern(screen_colored_wrapped, &patterns), Some(0));

        // 3. Exact single-line match still works
        let screen_exact = "Welcome! Choose your color scheme now";
        assert_eq!(first_matching_pattern(screen_exact, &patterns), Some(1));

        // 4. Non-matching text returns None
        assert_eq!(first_matching_pattern("Random terminal output", &patterns), None);
    }

    /// Build a detector armed at t=0 for tests.
    fn cfg_detector(cfg: StartupDetectionConfig) -> Detector {
        Detector::new(cfg, 0)
    }
}
