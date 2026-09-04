//! REQ HOST-3: ratatui/crossterm runtime for the multi-agent dashboard.
//!
//! Thin I/O shell around the pure [`crate::dashboard_tui::Dashboard`] state
//! machine: owns the alternate screen, connects to the **daemon** socket,
//! translates crossterm key + mouse + resize events, drives a background reader
//! that feeds [`crate::dproto::CtlReply`] frames into the app, periodically
//! refreshes the agent `List` and the attached agent's `Capture`, and renders
//! the split layout (sidebar | selected-agent pane + debug widgets).
//!
//! Responsiveness: a terminal resize (`Event::Resize`) recomputes the right-pane
//! geometry and calls [`Dashboard::on_pane_resize`], which emits an
//! instance-scoped `Resize` so the contained process's PTY reflows to match.

use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use crossterm::event::{
    self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEventKind,
};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph, Wrap};
use ratatui::Terminal;

use crate::dashboard_tui::{key_to_bytes, AgentRow, Dashboard, Field, Focus, Key, NAMED_KEY_CHOICES};
use crate::dproto::{self, AgentInfo, CtlMsg, CtlReply};

// Keep the debug widgets from being flagged unused by the reused imports.
#[allow(unused_imports)]
use crate::dashboard_tui::parse_resize;

/// Run the dashboard TUI attached to the daemon at `socket_path`.
pub fn run(socket_path: &std::path::Path) -> Result<()> {
    let stream = UnixStream::connect(socket_path)
        .with_context(|| format!("connect to daemon socket {socket_path:?}"))?;
    let write_stream = stream.try_clone().context("clone socket")?;
    let read_stream = stream;

    // Background reader: daemon -> app frames.
    let (frame_tx, frame_rx) = mpsc::channel::<CtlReply>();
    let reader_done = Arc::new(AtomicBool::new(false));
    {
        let reader_done = Arc::clone(&reader_done);
        let mut rs = read_stream;
        std::thread::spawn(move || loop {
            match dproto::read_ctl_reply(&mut rs) {
                Ok(Some(msg)) => {
                    if frame_tx.send(msg).is_err() {
                        break;
                    }
                }
                Ok(None) | Err(_) => {
                    reader_done.store(true, Ordering::SeqCst);
                    break;
                }
            }
        });
    }

    let mut app = Dashboard::new();
    let write_stream = Arc::new(Mutex::new(write_stream));
    // Prime an initial agent list.
    send(&write_stream, &CtlMsg::List);

    let mut term = setup_terminal().context("setup terminal")?;
    let res = event_loop(&mut term, &mut app, &frame_rx, &write_stream, &reader_done);
    restore_terminal(&mut term).ok();
    res
}

type Backend = ratatui::backend::CrosstermBackend<std::io::Stdout>;

fn setup_terminal() -> Result<Terminal<Backend>> {
    crossterm::terminal::enable_raw_mode()?;
    let mut stdout = std::io::stdout();
    crossterm::execute!(
        stdout,
        crossterm::terminal::EnterAlternateScreen,
        crossterm::event::EnableMouseCapture
    )?;
    let backend = ratatui::backend::CrosstermBackend::new(stdout);
    Ok(Terminal::new(backend)?)
}

fn restore_terminal(term: &mut Terminal<Backend>) -> Result<()> {
    crossterm::terminal::disable_raw_mode()?;
    crossterm::execute!(
        term.backend_mut(),
        crossterm::terminal::LeaveAlternateScreen,
        crossterm::event::DisableMouseCapture
    )?;
    term.show_cursor()?;
    Ok(())
}

fn send(write_stream: &Arc<Mutex<UnixStream>>, msg: &CtlMsg) {
    if let Ok(mut w) = write_stream.lock() {
        let _ = dproto::write_ctl_msg(&mut *w, msg);
    }
}

fn send_all(write_stream: &Arc<Mutex<UnixStream>>, msgs: &[CtlMsg]) {
    if msgs.is_empty() {
        return;
    }
    if let Ok(mut w) = write_stream.lock() {
        for m in msgs {
            let _ = dproto::write_ctl_msg(&mut *w, m);
        }
    }
}

/// Where the sidebar/pane split lives, so mouse hit-testing matches drawing.
/// The sidebar is a fixed-width left column; the pane fills the rest.
const SIDEBAR_WIDTH: u16 = 32;

fn event_loop(
    term: &mut Terminal<Backend>,
    app: &mut Dashboard,
    frame_rx: &Receiver<CtlReply>,
    write_stream: &Arc<Mutex<UnixStream>>,
    reader_done: &Arc<AtomicBool>,
) -> Result<()> {
    let mut last_list = std::time::Instant::now();
    let mut last_capture = std::time::Instant::now();
    let mut last_pane_geom: (u16, u16) = (0, 0);

    loop {
        // Drain daemon frames into app state.
        while let Ok(msg) = frame_rx.try_recv() {
            match msg {
                CtlReply::AgentList(list) => app.update_agents(to_rows(list)),
                CtlReply::Screen { instance, screen } => app.on_screen(&instance, screen),
                CtlReply::StartupBlocked {
                    instance,
                    safe_diagnostic,
                    ..
                } => {
                    app.status = format!("{instance} blocked: {safe_diagnostic}");
                }
                CtlReply::StartupReady { instance } => {
                    app.status = format!("{instance} ready");
                }
                CtlReply::ChildExited { instance, code } => {
                    app.status = format!("{instance} exited ({code})");
                }
                _ => {}
            }
        }

        // Compute the right-pane geometry from the current terminal size and
        // notify the app so it can resize the attached agent's PTY to match.
        let full = term.size()?;
        let pane_geom = pane_geometry(Rect::new(0, 0, full.width, full.height));
        if pane_geom != last_pane_geom {
            last_pane_geom = pane_geom;
            let msgs = app.on_pane_resize(pane_geom.0, pane_geom.1).messages;
            send_all(write_stream, &msgs);
        }

        term.draw(|f| draw(f, app))?;

        // Refresh the agent list periodically (cheap; drives sidebar liveness).
        if last_list.elapsed() >= Duration::from_millis(500) {
            send(write_stream, &CtlMsg::List);
            last_list = std::time::Instant::now();
        }
        // Refresh the attached agent's screen.
        if last_capture.elapsed() >= Duration::from_millis(120) {
            if let Some(inst) = app.attached.clone() {
                send(write_stream, &CtlMsg::Capture { instance: inst });
            }
            last_capture = std::time::Instant::now();
        }

        // Input: keys, mouse, resize.
        if event::poll(Duration::from_millis(60))? {
            match event::read()? {
                Event::Key(ke) => {
                    if ke.kind == KeyEventKind::Press || ke.kind == KeyEventKind::Repeat {
                        if let Some(key) = translate_key(ke) {
                            let out = app.handle_key(key);
                            send_all(write_stream, &out.messages);
                        }
                    }
                }
                Event::Mouse(me) => {
                    if let MouseEventKind::Down(MouseButton::Left) = me.kind {
                        if let Some(row) = sidebar_hit_row(term, me.column, me.row)? {
                            let out = app.handle_click_row(row);
                            send_all(write_stream, &out.messages);
                        }
                    }
                }
                Event::Resize(_, _) => {
                    // Recomputed at the top of the loop via term.size(); nothing
                    // else needed here — this just wakes the poll immediately.
                }
                _ => {}
            }
        }

        if app.should_quit {
            break;
        }
        if reader_done.load(Ordering::SeqCst) {
            app.status = "disconnected from daemon".into();
            term.draw(|f| draw(f, app))?;
            std::thread::sleep(Duration::from_millis(300));
            break;
        }
    }
    Ok(())
}

fn to_rows(list: Vec<AgentInfo>) -> Vec<AgentRow> {
    list.into_iter()
        .map(|a| AgentRow {
            instance_id: a.instance_id,
            program: a.program,
            alive: a.alive,
            last_activity: a.last_activity,
            bridge_label: None,
        })
        .collect()
}

/// The (rows, cols) available to the selected-agent pane given the full window.
/// Mirrors the draw layout: 1-row banner + 1-row status, sidebar column of
/// `SIDEBAR_WIDTH`, and the pane inside a bordered block (−2 each dimension).
fn pane_geometry(full: Rect) -> (u16, u16) {
    let body_h = full.height.saturating_sub(2); // banner + status
    let pane_w = full.width.saturating_sub(SIDEBAR_WIDTH);
    // Inside the pane's bordered Block.
    let rows = body_h.saturating_sub(2);
    let cols = pane_w.saturating_sub(2);
    (rows.max(1), cols.max(1))
}

/// Map a mouse click to a sidebar row index (0-based, within the visible list),
/// or None if the click is outside the sidebar's row area.
fn sidebar_hit_row(
    term: &mut Terminal<Backend>,
    col: u16,
    row: u16,
) -> Result<Option<usize>> {
    let full = term.size()?;
    // Sidebar is the left column, below the banner (row 0), inside its border
    // (top border at body row 0). Body starts at y=1 (after banner). The list
    // block border occupies 1 row at top, so first row is y = 1 + 1 = 2.
    if col >= SIDEBAR_WIDTH {
        return Ok(None);
    }
    let first_list_y = 2u16;
    let body_bottom = full.height.saturating_sub(1); // status line row
    if row < first_list_y || row >= body_bottom {
        return Ok(None);
    }
    Ok(Some((row - first_list_y) as usize))
}

/// Translate a crossterm key event into our abstract [`Key`].
fn translate_key(ke: KeyEvent) -> Option<Key> {
    match ke.code {
        KeyCode::F(2) => return Some(Key::ToggleFocus),
        KeyCode::F(10) => return Some(Key::Quit),
        _ => {}
    }
    let ctrl = ke.modifiers.contains(KeyModifiers::CONTROL);
    Some(match ke.code {
        KeyCode::Char(c) if ctrl => Key::Ctrl(c),
        KeyCode::Char(c) => Key::Char(c),
        KeyCode::Enter => Key::Enter,
        KeyCode::Esc => Key::Esc,
        KeyCode::Tab => Key::Tab,
        KeyCode::BackTab => Key::BackTab,
        KeyCode::Backspace => Key::Backspace,
        KeyCode::Up => Key::Up,
        KeyCode::Down => Key::Down,
        KeyCode::Left => Key::Left,
        KeyCode::Right => Key::Right,
        KeyCode::Home => Key::Home,
        KeyCode::End => Key::End,
        KeyCode::Delete => Key::Delete,
        KeyCode::PageUp => Key::PageUp,
        KeyCode::PageDown => Key::PageDown,
        _ => Key::Other,
    })
}

// ---- rendering ----------------------------------------------------------

fn draw(f: &mut ratatui::Frame, app: &mut Dashboard) {
    let size = f.area();
    let vert = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1), // banner
            Constraint::Min(0),    // body
            Constraint::Length(1), // status
        ])
        .split(size);
    draw_banner(f, vert[0], app);
    draw_status(f, vert[2], app);

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(SIDEBAR_WIDTH), Constraint::Min(0)])
        .split(vert[1]);
    draw_sidebar(f, cols[0], app);
    draw_pane(f, cols[1], app);
}

fn draw_banner(f: &mut ratatui::Frame, area: Rect, app: &Dashboard) {
    let focus = match app.focus {
        Focus::List => "LIST",
        Focus::Pane => "PANE",
        Focus::Debug => "DEBUG",
    };
    let banner = Line::from(vec![
        Span::styled(
            " ham-pty-host ",
            Style::default()
                .fg(Color::Black)
                .bg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" dashboard · focus: "),
        Span::styled(
            focus,
            Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        ),
        Span::raw("  [F2] cycle focus  [Enter] switch  [F10] quit"),
    ]);
    f.render_widget(Paragraph::new(banner), area);
}

fn draw_status(f: &mut ratatui::Frame, area: Rect, app: &Dashboard) {
    f.render_widget(
        Paragraph::new(Line::from(Span::styled(
            app.status.clone(),
            Style::default().fg(Color::DarkGray),
        ))),
        area,
    );
}

fn draw_sidebar(f: &mut ratatui::Frame, area: Rect, app: &mut Dashboard) {
    let focused = app.focus == Focus::List;
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" agents ")
        .border_style(border_style(focused));
    let inner = block.inner(area);
    f.render_widget(block, area);

    let height = inner.height as usize;
    let scroll = app.ensure_visible(height);
    let attached = app.attached.clone();

    let items: Vec<ListItem> = app
        .agents
        .iter()
        .enumerate()
        .skip(scroll)
        .take(height)
        .map(|(i, a)| {
            let selected = i == app.selected;
            let is_attached = attached.as_deref() == Some(a.instance_id.as_str());
            let marker = if selected { "▶ " } else if is_attached { "• " } else { "  " };
            let dot = if a.alive { "●" } else { "○" };
            let label = a
                .bridge_label
                .clone()
                .unwrap_or_else(|| a.program.clone());
            let text = format!("{marker}{dot} {} · {}", a.instance_id, label);
            let style = if selected && focused {
                Style::default().fg(Color::Black).bg(Color::Yellow)
            } else if selected {
                Style::default().add_modifier(Modifier::BOLD)
            } else if a.alive {
                Style::default()
            } else {
                Style::default().fg(Color::DarkGray)
            };
            ListItem::new(Line::from(Span::styled(text, style)))
        })
        .collect();

    f.render_widget(List::new(items), inner);
}

fn draw_pane(f: &mut ratatui::Frame, area: Rect, app: &Dashboard) {
    // Right side: selected agent's screen on top, debug widgets below.
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(4), Constraint::Length(9)])
        .split(area);
    draw_screen(f, rows[0], app);
    draw_debug(f, rows[1], app);
}

fn draw_screen(f: &mut ratatui::Frame, area: Rect, app: &Dashboard) {
    let focused = app.focus == Focus::Pane;
    let title = match app.attached.as_deref() {
        Some(inst) => format!(" {inst} "),
        None => " (no agent attached — Enter to attach) ".into(),
    };
    let block = Block::default()
        .borders(Borders::ALL)
        .title(title)
        .border_style(border_style(focused));
    let text: Vec<Line> = match &app.latest {
        Some(s) => s.lines.iter().map(|l| Line::from(l.clone())).collect(),
        None => vec![Line::from(Span::styled(
            "waiting for screen…",
            Style::default().fg(Color::DarkGray),
        ))],
    };
    f.render_widget(Paragraph::new(text).block(block), area);
}

fn draw_debug(f: &mut ratatui::Frame, area: Rect, app: &Dashboard) {
    let focused = app.focus == Focus::Debug;
    let outer = Block::default()
        .borders(Borders::ALL)
        .title(" debug (F2 to focus · Tab cycles) ")
        .border_style(border_style(focused));
    let inner = outer.inner(area);
    f.render_widget(outer, area);

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage(40),
            Constraint::Percentage(30),
            Constraint::Percentage(30),
        ])
        .split(inner);

    // Send Keys.
    let sk_active = focused && app.field == Field::SendKeys;
    let sk = if sk_active {
        format!("{}\u{2588}", app.send_buf)
    } else {
        app.send_buf.clone()
    };
    f.render_widget(
        Paragraph::new(sk).block(
            Block::default()
                .borders(Borders::ALL)
                .title(" SendKeys ")
                .border_style(field_style(sk_active)),
        ),
        cols[0],
    );

    // Named Keys.
    let nk_active = focused && app.field == Field::NamedKeys;
    let items: Vec<ListItem> = NAMED_KEY_CHOICES
        .iter()
        .enumerate()
        .map(|(i, (_, label))| {
            let sel = i == app.named_sel;
            let marker = if sel { "▶ " } else { "  " };
            let style = if sel && nk_active {
                Style::default().fg(Color::Black).bg(Color::Yellow)
            } else if sel {
                Style::default().add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            ListItem::new(Line::from(Span::styled(format!("{marker}{label}"), style)))
        })
        .collect();
    f.render_widget(
        List::new(items).block(
            Block::default()
                .borders(Borders::ALL)
                .title(" NamedKey ")
                .border_style(field_style(nk_active)),
        ),
        cols[1],
    );

    // Resize + Capture stacked.
    let rc = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(0)])
        .split(cols[2]);
    let rz_active = focused && app.field == Field::Resize;
    let rz = if rz_active {
        format!("{}\u{2588}", app.resize_buf)
    } else if app.resize_buf.is_empty() {
        "40x120".into()
    } else {
        app.resize_buf.clone()
    };
    f.render_widget(
        Paragraph::new(rz).block(
            Block::default()
                .borders(Borders::ALL)
                .title(" Resize ")
                .border_style(field_style(rz_active)),
        ),
        rc[0],
    );
    let cap_active = focused && app.field == Field::Capture;
    f.render_widget(
        Paragraph::new("Enter=snapshot")
            .wrap(Wrap { trim: true })
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .title(" Capture ")
                    .border_style(field_style(cap_active)),
            ),
        rc[1],
    );

    // Silence unused import in non-test builds.
    let _ = key_to_bytes;
}

fn border_style(focused: bool) -> Style {
    if focused {
        Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(Color::DarkGray)
    }
}

fn field_style(active: bool) -> Style {
    if active {
        Style::default().fg(Color::Yellow)
    } else {
        Style::default().fg(Color::DarkGray)
    }
}
