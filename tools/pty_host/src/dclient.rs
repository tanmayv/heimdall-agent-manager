//! REQ HOST-4: single-agent `attach --instance <id>` — raw passthrough to ONE
//! daemon agent, no sidebar, for dropping into a tmux pane and tiling manually.
//!
//! This is the daemon (dproto) analogue of the single-host [`crate::client`]:
//! it `Attach{instance}`es, streams that instance's `Output` to stdout, forwards
//! stdin as `Input{instance}`, tracks SIGWINCH -> `Resize{instance}` so the
//! contained process reflows to the pane, and **detaches on Ctrl-\ without
//! killing the child**. Async events for OTHER instances (or control replies)
//! are ignored so multiple single-agent panes can share one daemon.
//!
//! Fullscreen Selector Overlay (Ctrl-Space):
//! When attached, pressing Ctrl-Space enters the fullscreen selector overlay.
//! The overlay switches into the terminal's alternate screen buffer (`ESC[?1049h`),
//! draws a fuzzy-searchable list of all registered agents (name, dir, runtime, etc.)
//! rendered via ratatui, and on exit switches back (`ESC[?1049l`).
//! The underlying screen content and colors remain completely uncorrupted.
//! Selecting an agent performs `Detach{old}` + `Attach{new}` + `Resize`.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use ratatui::layout::{Constraint, Direction, Layout};

use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph};
use ratatui::Terminal;

use crate::client::AttachOutcome;
use crate::dashboard_tui::Key;
use crate::dproto::{self, AgentInfo, CtlMsg, CtlReply};
use crate::selector::{SelectorAction, SelectorItem, SelectorState};
use crate::termios::{current_winsize, RawGuard};

/// Byte that triggers a clean detach (Ctrl-\, aka FS / 0x1c).
const DETACH_BYTE: u8 = 0x1c;

/// Byte that triggers the agent selector overlay (Ctrl-Space / NUL / 0x00).
const SELECTOR_BYTE: u8 = 0x00;

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Attach to a single daemon agent `instance` at `socket_path`, driving the
/// local terminal until the user detaches (Ctrl-\) or the child exits.
pub fn attach_instance(socket_path: &std::path::Path, instance: &str) -> Result<AttachOutcome> {
    let stream = UnixStream::connect(socket_path)
        .with_context(|| format!("connect to daemon socket {socket_path:?}"))?;
    let write_stream = stream.try_clone().context("clone socket")?;
    let read_stream = stream;

    // Raw mode so keystrokes pass through untouched.
    let _raw = RawGuard::enable().context("enable raw mode")?;

    let current_instance = instance.to_string();
    let current_inst_arc = Arc::new(Mutex::new(current_instance.clone()));
    let write_stream = Arc::new(Mutex::new(write_stream));

    // Attach + initial Resize to match our window.
    {
        let mut ws = write_stream.lock().unwrap();
        dproto::write_ctl_msg(&mut *ws, &CtlMsg::Attach { instance: current_instance.clone() })?;
        if let Some((rows, cols)) = current_winsize() {
            dproto::write_ctl_msg(
                &mut *ws,
                &CtlMsg::Resize {
                    instance: current_instance.clone(),
                    rows,
                    cols,
                },
            )?;
        }
    }

    let child_exit = Arc::new(AtomicI32::new(i32::MIN));
    let done = Arc::new(AtomicBool::new(false));
    let agent_list = Arc::new(Mutex::new(Vec::<AgentInfo>::new()));
    let in_selector = Arc::new(AtomicBool::new(false));

    install_sigwinch_handler();

    // Reader thread: daemon -> stdout / handle control frames.
    let reader = {
        let child_exit = Arc::clone(&child_exit);
        let done = Arc::clone(&done);
        let current_inst_arc = Arc::clone(&current_inst_arc);
        let agent_list = Arc::clone(&agent_list);
        let in_selector = Arc::clone(&in_selector);
        let mut read_stream = read_stream;
        std::thread::spawn(move || {
            let mut out = std::io::stdout();
            loop {
                match dproto::read_ctl_reply(&mut read_stream) {
                    Ok(Some(CtlReply::Output { instance, data })) => {
                        let cur = current_inst_arc.lock().unwrap().clone();
                        // Only pass through output when matching the currently attached agent
                        // and not currently suppressed by the selector overlay.
                        if instance == cur && !in_selector.load(Ordering::SeqCst) {
                            let _ = out.write_all(&data);
                            let _ = out.flush();
                        }
                    }
                    Ok(Some(CtlReply::ChildExited { instance, code })) => {
                        let cur = current_inst_arc.lock().unwrap().clone();
                        if instance == cur {
                            child_exit.store(code, Ordering::SeqCst);
                            done.store(true, Ordering::SeqCst);
                            break;
                        }
                    }
                    Ok(Some(CtlReply::AgentList(list))) => {
                        *agent_list.lock().unwrap() = list;
                    }
                    Ok(Some(_)) => {}
                    Ok(None) | Err(_) => {
                        done.store(true, Ordering::SeqCst);
                        break;
                    }
                }
            }
        })
    };

    // stdin reader thread -> channel (portable non-blocking).
    let mut stdin = std::io::stdin();
    let mut buf = [0u8; 4096];
    let (in_tx, in_rx) = std::sync::mpsc::channel::<Vec<u8>>();
    {
        let done = Arc::clone(&done);
        std::thread::spawn(move || loop {
            if done.load(Ordering::SeqCst) {
                break;
            }
            match stdin.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if in_tx.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        });
    }

    let outcome = loop {
        if done.load(Ordering::SeqCst) {
            let code = child_exit.load(Ordering::SeqCst);
            if code != i32::MIN {
                break AttachOutcome::ChildExited(code);
            }
            break AttachOutcome::Disconnected;
        }

        // Pending resize from SIGWINCH.
        if take_sigwinch() {
            if let Some((rows, cols)) = current_winsize() {
                let inst = current_inst_arc.lock().unwrap().clone();
                let mut ws = write_stream.lock().unwrap();
                let _ = dproto::write_ctl_msg(
                    &mut *ws,
                    &CtlMsg::Resize {
                        instance: inst,
                        rows,
                        cols,
                    },
                );
            }
        }

        match in_rx.recv_timeout(Duration::from_millis(100)) {
            Ok(chunk) => {
                // Check if chunk contains Ctrl-\ (detach)
                if let Some(pos) = chunk.iter().position(|&b| b == DETACH_BYTE) {
                    let inst = current_inst_arc.lock().unwrap().clone();
                    let mut ws = write_stream.lock().unwrap();
                    if pos > 0 {
                        let _ = dproto::write_ctl_msg(
                            &mut *ws,
                            &CtlMsg::Input {
                                instance: inst.clone(),
                                data: chunk[..pos].to_vec(),
                            },
                        );
                    }
                    let _ = dproto::write_ctl_msg(&mut *ws, &CtlMsg::Detach { instance: inst });
                    break AttachOutcome::Detached;
                }

                // Check if chunk contains Ctrl-Space (0x00)
                if let Some(pos) = chunk.iter().position(|&b| b == SELECTOR_BYTE) {
                    let inst = current_inst_arc.lock().unwrap().clone();
                    // Forward any pending bytes before Ctrl-Space
                    if pos > 0 {
                        let mut ws = write_stream.lock().unwrap();
                        let _ = dproto::write_ctl_msg(
                            &mut *ws,
                            &CtlMsg::Input {
                                instance: inst.clone(),
                                data: chunk[..pos].to_vec(),
                            },
                        );
                    }

                    // Request fresh agent list
                    {
                        let mut ws = write_stream.lock().unwrap();
                        let _ = dproto::write_ctl_msg(&mut *ws, &CtlMsg::List);
                    }

                    // Enter alternate screen overlay
                    in_selector.store(true, Ordering::SeqCst);
                    let switch_target = run_selector_overlay(
                        &in_rx,
                        &done,
                        &agent_list,
                        &current_inst_arc,
                        &write_stream,
                    );
                    in_selector.store(false, Ordering::SeqCst);

                    if let Some(new_inst) = switch_target {
                        let old_inst = current_inst_arc.lock().unwrap().clone();
                        if new_inst != old_inst {
                            let mut ws = write_stream.lock().unwrap();
                            let _ = dproto::write_ctl_msg(
                                &mut *ws,
                                &CtlMsg::Detach { instance: old_inst },
                            );
                            let _ = dproto::write_ctl_msg(
                                &mut *ws,
                                &CtlMsg::Attach { instance: new_inst.clone() },
                            );
                            if let Some((rows, cols)) = current_winsize() {
                                // Micro-resize nudge: send cols - 1 then cols to guarantee
                                // child process receives an actual winsize delta and emits a full redraw.
                                let _ = dproto::write_ctl_msg(
                                    &mut *ws,
                                    &CtlMsg::Resize {
                                        instance: new_inst.clone(),
                                        rows,
                                        cols: cols.saturating_sub(1),
                                    },
                                );
                                std::thread::sleep(Duration::from_millis(20));
                                let _ = dproto::write_ctl_msg(
                                    &mut *ws,
                                    &CtlMsg::Resize {
                                        instance: new_inst.clone(),
                                        rows,
                                        cols,
                                    },
                                );
                            }
                            *current_inst_arc.lock().unwrap() = new_inst;
                        } else {
                            // If reselecting same agent, nudge resize to restore display
                            if let Some((rows, cols)) = current_winsize() {
                                let mut ws = write_stream.lock().unwrap();
                                let _ = dproto::write_ctl_msg(
                                    &mut *ws,
                                    &CtlMsg::Resize {
                                        instance: old_inst.clone(),
                                        rows,
                                        cols: cols.saturating_sub(1),
                                    },
                                );
                                std::thread::sleep(Duration::from_millis(20));
                                let _ = dproto::write_ctl_msg(
                                    &mut *ws,
                                    &CtlMsg::Resize {
                                        instance: old_inst,
                                        rows,
                                        cols,
                                    },
                                );
                            }
                        }
                    } else {
                        // Cancelled: restore primary screen and nudge resize
                        if let Some((rows, cols)) = current_winsize() {
                            let inst = current_inst_arc.lock().unwrap().clone();
                            let mut ws = write_stream.lock().unwrap();
                            let _ = dproto::write_ctl_msg(
                                &mut *ws,
                                &CtlMsg::Resize {
                                    instance: inst.clone(),
                                    rows,
                                    cols: cols.saturating_sub(1),
                                },
                            );
                            std::thread::sleep(Duration::from_millis(20));
                            let _ = dproto::write_ctl_msg(
                                &mut *ws,
                                &CtlMsg::Resize {
                                    instance: inst,
                                    rows,
                                    cols,
                                },
                            );
                        }
                    }
                    continue;
                }

                // Normal raw passthrough input
                let inst = current_inst_arc.lock().unwrap().clone();
                let mut ws = write_stream.lock().unwrap();
                let _ = dproto::write_ctl_msg(
                    &mut *ws,
                    &CtlMsg::Input {
                        instance: inst,
                        data: chunk,
                    },
                );
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                if done.load(Ordering::SeqCst) {
                    let code = child_exit.load(Ordering::SeqCst);
                    if code != i32::MIN {
                        break AttachOutcome::ChildExited(code);
                    }
                }
                break AttachOutcome::Disconnected;
            }
        }
    };

    done.store(true, Ordering::SeqCst);
    let _ = reader.join();
    Ok(outcome)
}

/// Run the interactive fullscreen agent selector overlay on the alternate screen buffer.
/// Returns `Some(target_instance_id)` if an agent was chosen, or `None` if cancelled.
fn run_selector_overlay(
    in_rx: &std::sync::mpsc::Receiver<Vec<u8>>,
    done: &Arc<AtomicBool>,
    agent_list: &Arc<Mutex<Vec<AgentInfo>>>,
    current_inst_arc: &Arc<Mutex<String>>,
    write_stream: &Arc<Mutex<UnixStream>>,
) -> Option<String> {
    let current_inst = current_inst_arc.lock().unwrap().clone();
    let initial_items = to_selector_items(&agent_list.lock().unwrap());
    let mut state = SelectorState::new(current_inst, initial_items);

    // 1. Enter alternate screen buffer (ESC[?1049h)
    let mut stdout = std::io::stdout();
    let _ = crossterm::execute!(stdout, crossterm::terminal::EnterAlternateScreen);
    let _ = stdout.flush();

    let backend = ratatui::backend::CrosstermBackend::new(stdout);
    let mut terminal = match Terminal::new(backend) {
        Ok(t) => t,
        Err(_) => {
            let mut out = std::io::stdout();
            let _ = crossterm::execute!(out, crossterm::terminal::LeaveAlternateScreen);
            let _ = out.flush();
            return None;
        }
    };

    let mut last_list_poll = std::time::Instant::now();
    let mut chosen_instance: Option<String> = None;

    loop {
        if done.load(Ordering::SeqCst) {
            break;
        }

        // Periodically refresh agent list while selector is open
        if last_list_poll.elapsed() >= Duration::from_millis(500) {
            if let Ok(mut ws) = write_stream.lock() {
                let _ = dproto::write_ctl_msg(&mut *ws, &CtlMsg::List);
            }
            last_list_poll = std::time::Instant::now();
        }

        // Update items from background reader
        {
            let list = agent_list.lock().unwrap();
            let items = to_selector_items(&list);
            state.set_items(items);
        }

        let _ = terminal.draw(|f| draw_selector(f, &mut state));

        match in_rx.recv_timeout(Duration::from_millis(50)) {
            Ok(chunk) => {
                let keys = parse_keys_from_bytes(&chunk);
                let mut should_exit = false;
                for key in keys {
                    match state.handle_key(key) {
                        SelectorAction::None => {}
                        SelectorAction::Cancel => {
                            chosen_instance = None;
                            should_exit = true;
                            break;
                        }
                        SelectorAction::Switch(target) => {
                            chosen_instance = Some(target);
                            should_exit = true;
                            break;
                        }
                    }
                }
                if should_exit {
                    break;
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    // 2. Exit alternate screen buffer (ESC[?1049l)
    let _ = crossterm::execute!(
        terminal.backend_mut(),
        crossterm::terminal::LeaveAlternateScreen
    );
    let _ = terminal.show_cursor();
    let _ = terminal.backend_mut().flush();

    chosen_instance
}

fn to_selector_items(list: &[AgentInfo]) -> Vec<SelectorItem> {
    let now = now_secs();
    list.iter()
        .map(|a| {
            let runtime = if a.started_at > 0 && now >= a.started_at {
                now - a.started_at
            } else {
                0
            };
            let cwd = resolve_instance_cwd(&a.instance_id);
            SelectorItem {
                instance_id: a.instance_id.clone(),
                program: a.program.clone(),
                cwd,
                runtime_secs: runtime,
                pid: a.pid,
                alive: a.alive,
                last_activity_secs: a.last_activity,
                display_name: a.display_name.clone(),
            }
        })
        .collect()
}

/// Helper to inspect the working directory or project for an instance from bootstrap.
fn resolve_instance_cwd(instance_id: &str) -> Option<String> {
    let base = format!("/tmp/heimdall-bridge-local/instances/{instance_id}/AGENTS.md");
    if let Ok(content) = std::fs::read_to_string(&base) {
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with("- Path:") {
                let p = trimmed.trim_start_matches("- Path:").trim();
                if !p.is_empty() {
                    return Some(p.to_string());
                }
            }
        }
    }
    None
}

/// Render the fullscreen agent selector TUI.
fn draw_selector(f: &mut ratatui::Frame, state: &mut SelectorState) {
    let size = f.area();
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3), // Search bar
            Constraint::Min(0),    // Agents list
            Constraint::Length(1), // Footer status / shortcuts
        ])
        .split(size);

    // Search bar
    let search_block = Block::default()
        .borders(Borders::ALL)
        .title(" Switch Agent (Ctrl-Space) · Fuzzy Filter ")
        .border_style(Style::default().fg(Color::Cyan));
    let search_text = format!("🔍 {}", state.query);
    let search_p = Paragraph::new(Line::from(Span::styled(
        search_text,
        Style::default().fg(Color::White).add_modifier(Modifier::BOLD),
    )))
    .block(search_block);
    f.render_widget(search_p, chunks[0]);

    // Agents list
    let total = state.filtered_indices.len();
    let list_title = format!(" Agents ({}/{}) ", total, state.all_items.len());
    let list_block = Block::default()
        .borders(Borders::ALL)
        .title(list_title)
        .border_style(Style::default().fg(Color::White));
    let inner = list_block.inner(chunks[1]);
    f.render_widget(list_block, chunks[1]);

    let height = inner.height as usize;
    let scroll = state.ensure_visible(height);
    let now = now_secs();

    let list_items: Vec<ListItem> = state
        .filtered_indices
        .iter()
        .skip(scroll)
        .take(height)
        .enumerate()
        .map(|(rel_idx, &actual_idx)| {
            let item = &state.all_items[actual_idx];
            let is_selected = (scroll + rel_idx) == state.selected;
            let is_current = item.instance_id == state.current_instance;

            let marker = if is_selected {
                "▶ "
            } else if is_current {
                "• "
            } else {
                "  "
            };

            let dot = if item.alive { "●" } else { "○" };
            let dot_style = if item.alive {
                Style::default().fg(Color::Green)
            } else {
                Style::default().fg(Color::DarkGray)
            };

            let cwd_str = item.cwd.as_deref().unwrap_or("-");
            let runtime_str = item.format_runtime();
            let activity_str = item.format_activity(now);

            let (primary_label, id_label) = if let Some(ref d) = item.display_name {
                (d.clone(), format!("({})", item.instance_id))
            } else {
                (item.instance_id.clone(), String::new())
            };

            let row_spans = vec![
                Span::styled(marker, Style::default().add_modifier(Modifier::BOLD)),
                Span::styled(dot, dot_style),
                Span::raw(" "),
                Span::styled(
                    format!("{:<22}", primary_label),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!("{:<26}", id_label),
                    Style::default().fg(Color::DarkGray),
                ),
                Span::styled(format!("{:<10} ", item.program), Style::default().fg(Color::Yellow)),
                Span::styled(format!("dir: {:<24} ", cwd_str), Style::default().fg(Color::Cyan)),
                Span::styled(format!("up: {:<8} ", runtime_str), Style::default().fg(Color::Magenta)),
                Span::styled(format!("activity: {:<12}", activity_str), Style::default().fg(Color::DarkGray)),
            ];

            let row_style = if is_selected {
                Style::default().fg(Color::Black).bg(Color::Cyan)
            } else if is_current {
                Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
            } else if item.alive {
                Style::default().fg(Color::Gray)
            } else {
                Style::default().fg(Color::DarkGray)
            };

            ListItem::new(Line::from(row_spans)).style(row_style)
        })
        .collect();

    f.render_widget(List::new(list_items), inner);

    // Footer
    let footer_text = Line::from(vec![
        Span::styled(" [Enter] ", Style::default().fg(Color::Black).bg(Color::Cyan).add_modifier(Modifier::BOLD)),
        Span::raw(" Switch  "),
        Span::styled(" [↑/↓] ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" Select  "),
        Span::styled(" [Esc/Ctrl-C] ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" Cancel  "),
        Span::styled(" [Ctrl-U] ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" Clear search"),
    ]);
    f.render_widget(Paragraph::new(footer_text), chunks[2]);
}

/// Parse raw terminal input bytes into [`Key`] events for the selector.
fn parse_keys_from_bytes(bytes: &[u8]) -> Vec<Key> {
    let mut keys = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == 0x1b {
            // Escape sequences
            if i + 1 >= bytes.len() {
                keys.push(Key::Esc);
                i += 1;
                continue;
            }
            if bytes[i + 1] == b'[' {
                if i + 2 < bytes.len() {
                    match bytes[i + 2] {
                        b'A' => {
                            keys.push(Key::Up);
                            i += 3;
                            continue;
                        }
                        b'B' => {
                            keys.push(Key::Down);
                            i += 3;
                            continue;
                        }
                        b'C' => {
                            keys.push(Key::Right);
                            i += 3;
                            continue;
                        }
                        b'D' => {
                            keys.push(Key::Left);
                            i += 3;
                            continue;
                        }
                        b'H' => {
                            keys.push(Key::Home);
                            i += 3;
                            continue;
                        }
                        b'F' => {
                            keys.push(Key::End);
                            i += 3;
                            continue;
                        }
                        b'3' if i + 3 < bytes.len() && bytes[i + 3] == b'~' => {
                            keys.push(Key::Delete);
                            i += 4;
                            continue;
                        }
                        b'5' if i + 3 < bytes.len() && bytes[i + 3] == b'~' => {
                            keys.push(Key::PageUp);
                            i += 4;
                            continue;
                        }
                        b'6' if i + 3 < bytes.len() && bytes[i + 3] == b'~' => {
                            keys.push(Key::PageDown);
                            i += 4;
                            continue;
                        }
                        _ => {}
                    }
                }
            }
            keys.push(Key::Esc);
            i += 1;
            continue;
        }

        match b {
            0x00 => keys.push(Key::Ctrl(' ')),
            0x03 => keys.push(Key::Ctrl('c')),
            0x08 | 0x7f => keys.push(Key::Backspace),
            0x09 => keys.push(Key::Tab),
            0x0d | 0x0a => keys.push(Key::Enter),
            0x15 => keys.push(Key::Ctrl('u')),
            0x17 => keys.push(Key::Ctrl('w')),
            b if b >= 0x20 && b <= 0x7e => keys.push(Key::Char(b as char)),
            _ => keys.push(Key::Other),
        }
        i += 1;
    }
    keys
}

// ---- SIGWINCH plumbing (shares the FFI in termios.rs) -------------------

static SIGWINCH_FLAG: AtomicBool = AtomicBool::new(false);

extern "C" fn sigwinch_handler(_sig: i32) {
    SIGWINCH_FLAG.store(true, Ordering::SeqCst);
}

fn install_sigwinch_handler() {
    unsafe {
        libc_signal(libc_sigwinch(), sigwinch_handler as *const () as usize);
    }
}

fn take_sigwinch() -> bool {
    SIGWINCH_FLAG.swap(false, Ordering::SeqCst)
}

use crate::termios::{libc_signal, libc_sigwinch};
