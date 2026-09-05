//! REQ HOST-1: Multi-agent daemon wire protocol.
//!
//! This is the instance-scoped control + data protocol spoken by the per-machine
//! daemon ([`crate::daemon`]). It generalizes the single-agent PTYH-2 protocol
//! ([`crate::proto`]): **every data-plane frame carries an `instance` id**, and
//! there is an explicit control plane (`Spawn` / `Close` / `Restart` / `List`).
//!
//! The framing is identical to PTYH-2 — a `u32` big-endian length prefix followed
//! by a tagged payload — so the two protocols can share [`crate::proto::read_frame`].
//! We deliberately keep the two message sets in separate enums so the legacy
//! single-agent server keeps working unchanged while the daemon layer lands.
//!
//! ## client -> daemon ([`CtlMsg`])
//!
//! | tag  | name    | purpose                                                    |
//! |------|---------|------------------------------------------------------------|
//! | 0x20 | Spawn   | register + launch a new agent under an instance id         |
//! | 0x21 | Close   | SIGTERM->wait->SIGKILL the instance, then unregister        |
//! | 0x22 | Restart | re-spawn the instance from its remembered spec             |
//! | 0x23 | List    | enumerate all registered agents                            |
//! | 0x30 | Attach  | subscribe this client to an instance's output stream       |
//! | 0x31 | Input   | raw bytes -> instance stdin                                 |
//! | 0x32 | Key     | named key -> instance stdin                                |
//! | 0x33 | Resize  | resize an instance's PTY + VT model                        |
//! | 0x34 | Capture | request a one-shot screen snapshot for an instance         |
//! | 0x35 | Detach  | unsubscribe this client from an instance (child survives)  |
//! | 0x36 | Ping    | liveness check                                             |
//! | 0x37 | Shutdown| stop all agents and terminate the daemon process           |
//!
//! ## daemon -> client ([`CtlReply`])
//!
//! | tag  | name        | purpose                                              |
//! |------|-------------|------------------------------------------------------|
//! | 0xA0 | Spawned     | ack Spawn with the child pid                          |
//! | 0xA1 | Closed      | ack Close                                             |
//! | 0xA2 | Restarted   | ack Restart with the new child pid                   |
//! | 0xA3 | AgentList   | response to List                                     |
//! | 0xA4 | Output      | raw PTY bytes for an instance                         |
//! | 0xA5 | Screen      | screen snapshot for an instance                      |
//! | 0xA6 | ChildExited | an instance's child exited (event)                   |
//! | 0xA7 | Pong        | ping reply                                           |
//! | 0xA8 | Error       | an operation failed (instance + message)             |
//! | 0xAC | ShuttingDown| ack Shutdown; daemon is terminating                  |
//! | 0xAD | HostHeartbeat| periodic host liveness digest (roster + alive)      |

use std::io::{self, Read, Write};

use crate::proto::{read_frame, NamedKey, ScreenSnapshot};

/// Everything the daemon needs to (re-)spawn an agent. The daemon stores this so
/// `Restart` re-spawns the exact same command without the caller re-plumbing it.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct SpawnRequest {
    /// Agent-instance id (the registry key). Required + unique.
    pub instance: String,
    /// Program + args to exec. `argv[0]` is the program.
    pub argv: Vec<String>,
    /// Working directory for the child, if any.
    pub cwd: Option<String>,
    /// Extra environment merged over the daemon's filtered env.
    pub env: Vec<(String, String)>,
    /// Opaque startup-detection config (JSON). Stored verbatim in HOST-1; parsed
    /// by the per-agent detector in HOST-2.
    pub detect: Option<String>,
    pub rows: u16,
    pub cols: u16,
    /// Human-readable agent display name (e.g. "default-agent #20").
    pub display_name: Option<String>,
}

/// A row in the `List` response: one registered agent's live state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentInfo {
    pub instance_id: String,
    pub program: String,
    pub pid: i32,
    pub alive: bool,
    pub exit_code: Option<i32>,
    pub rows: u16,
    pub cols: u16,
    /// Unix epoch seconds when the current child was spawned.
    pub started_at: u64,
    /// Unix epoch seconds of the last output activity.
    pub last_activity: u64,
    /// Human-readable agent display name (e.g. "default-agent #20").
    pub display_name: Option<String>,
}

/// client -> daemon.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CtlMsg {
    // control plane
    Spawn(SpawnRequest),
    Close { instance: String },
    Restart { instance: String },
    List,
    // data plane (instance-scoped)
    Attach { instance: String },
    Input { instance: String, data: Vec<u8> },
    Key { instance: String, key: NamedKey },
    Resize { instance: String, rows: u16, cols: u16 },
    Capture { instance: String },
    Detach { instance: String },
    Ping,
    /// Subscribe this connection to host-level async events (HostHeartbeat plus
    /// the per-instance lifecycle signals ChildExited / ScreenChanged /
    /// StartupReady / StartupBlocked) WITHOUT attaching to any instance's raw
    /// Output. The bridge's single long-lived event connection sends this once so
    /// it receives liveness/lifecycle for ALL agents; one-shot control
    /// connections do NOT send it and thus keep clean request/reply streams.
    WatchEvents,
    /// Stop every agent and terminate the daemon process (HOST-1 `stop`).
    Shutdown,
}

/// daemon -> client.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CtlReply {
    Spawned { instance: String, pid: i32 },
    Closed { instance: String },
    Restarted { instance: String, pid: i32 },
    AgentList(Vec<AgentInfo>),
    Output { instance: String, data: Vec<u8> },
    Screen { instance: String, screen: ScreenSnapshot },
    ChildExited { instance: String, code: i32 },
    Pong,
    Error { instance: String, message: String },
    /// HOST-2: startup detection succeeded (no blocked pattern within probe).
    StartupReady { instance: String },
    /// HOST-2: startup detection blocked (login/quota/error prompt, or unknown
    /// with startup_unknown_is_blocked). Carries the sanitized reason.
    StartupBlocked {
        instance: String,
        reason_code: String,
        safe_diagnostic: String,
    },
    /// HOST-2: content-change (activity) dirty signal. `hash` is a cheap content
    /// hash of the rendered screen; the bridge classifies activity from the
    /// change stream without polling (spinner masking is bridge-side).
    ScreenChanged { instance: String, hash: u64 },
    /// Periodic host-level liveness digest broadcast to every connected client
    /// on a fixed cadence. It carries the full agent roster with each child's
    /// alive flag so the bridge can refresh per-instance last_seen from a SINGLE
    /// pushed frame instead of polling `List`. `ChildExited` remains the instant,
    /// authoritative death signal; this digest is only the silent-failure/idle
    /// liveness backstop.
    HostHeartbeat { ts_unix_ms: u64, agents: Vec<HostHeartbeatAgent> },
    /// Ack for [`CtlMsg::Shutdown`]: the daemon accepted the request and is
    /// terminating (all agents stopped). The socket closes right after.
    ShuttingDown,
}

/// One agent's liveness entry inside a [`CtlReply::HostHeartbeat`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostHeartbeatAgent {
    pub instance_id: String,
    pub alive: bool,
}

// ---- tags ---------------------------------------------------------------

const T_SPAWN: u8 = 0x20;
const T_CLOSE: u8 = 0x21;
const T_RESTART: u8 = 0x22;
const T_LIST: u8 = 0x23;
const T_ATTACH: u8 = 0x30;
const T_INPUT: u8 = 0x31;
const T_KEY: u8 = 0x32;
const T_RESIZE: u8 = 0x33;
const T_CAPTURE: u8 = 0x34;
const T_DETACH: u8 = 0x35;
const T_PING: u8 = 0x36;
const T_SHUTDOWN: u8 = 0x37;
const T_WATCH_EVENTS: u8 = 0x38;

const T_SPAWNED: u8 = 0xA0;
const T_CLOSED: u8 = 0xA1;
const T_RESTARTED: u8 = 0xA2;
const T_AGENTLIST: u8 = 0xA3;
const T_OUTPUT: u8 = 0xA4;
const T_SCREEN: u8 = 0xA5;
const T_EXITED: u8 = 0xA6;
const T_PONG: u8 = 0xA7;
const T_ERROR: u8 = 0xA8;
const T_STARTUP_READY: u8 = 0xA9;
const T_STARTUP_BLOCKED: u8 = 0xAA;
const T_SCREEN_CHANGED: u8 = 0xAB;
const T_SHUTTING_DOWN: u8 = 0xAC;
const T_HOST_HEARTBEAT: u8 = 0xAD;

// ---- primitive codecs ---------------------------------------------------

fn put_str(p: &mut Vec<u8>, s: &str) {
    let b = s.as_bytes();
    p.extend_from_slice(&(b.len() as u32).to_be_bytes());
    p.extend_from_slice(b);
}

fn get_str(rest: &[u8], off: &mut usize) -> io::Result<String> {
    if *off + 4 > rest.len() {
        return Err(bad("string len truncated"));
    }
    let len = u32::from_be_bytes([rest[*off], rest[*off + 1], rest[*off + 2], rest[*off + 3]])
        as usize;
    *off += 4;
    if *off + len > rest.len() {
        return Err(bad("string body truncated"));
    }
    let s = String::from_utf8_lossy(&rest[*off..*off + len]).into_owned();
    *off += len;
    Ok(s)
}

fn put_opt_str(p: &mut Vec<u8>, s: &Option<String>) {
    match s {
        Some(v) => {
            p.push(1);
            put_str(p, v);
        }
        None => p.push(0),
    }
}

fn get_opt_str(rest: &[u8], off: &mut usize) -> io::Result<Option<String>> {
    let present = *rest.get(*off).ok_or_else(|| bad("opt-str tag missing"))?;
    *off += 1;
    match present {
        0 => Ok(None),
        1 => Ok(Some(get_str(rest, off)?)),
        _ => Err(bad("bad opt-str tag")),
    }
}

fn put_u16(p: &mut Vec<u8>, v: u16) {
    p.extend_from_slice(&v.to_be_bytes());
}

fn get_u16(rest: &[u8], off: &mut usize) -> io::Result<u16> {
    if *off + 2 > rest.len() {
        return Err(bad("u16 truncated"));
    }
    let v = u16::from_be_bytes([rest[*off], rest[*off + 1]]);
    *off += 2;
    Ok(v)
}

fn put_i32(p: &mut Vec<u8>, v: i32) {
    p.extend_from_slice(&v.to_be_bytes());
}

fn get_i32(rest: &[u8], off: &mut usize) -> io::Result<i32> {
    if *off + 4 > rest.len() {
        return Err(bad("i32 truncated"));
    }
    let v = i32::from_be_bytes([rest[*off], rest[*off + 1], rest[*off + 2], rest[*off + 3]]);
    *off += 4;
    Ok(v)
}

fn put_u64(p: &mut Vec<u8>, v: u64) {
    p.extend_from_slice(&v.to_be_bytes());
}

fn get_u64(rest: &[u8], off: &mut usize) -> io::Result<u64> {
    if *off + 8 > rest.len() {
        return Err(bad("u64 truncated"));
    }
    let mut b = [0u8; 8];
    b.copy_from_slice(&rest[*off..*off + 8]);
    *off += 8;
    Ok(u64::from_be_bytes(b))
}

fn put_screen(p: &mut Vec<u8>, s: &ScreenSnapshot) {
    put_u16(p, s.rows);
    put_u16(p, s.cols);
    put_u16(p, s.cursor_row);
    put_u16(p, s.cursor_col);
    put_u16(p, s.lines.len() as u16);
    for line in &s.lines {
        put_str(p, line);
    }
}

fn get_screen(rest: &[u8], off: &mut usize) -> io::Result<ScreenSnapshot> {
    let rows = get_u16(rest, off)?;
    let cols = get_u16(rest, off)?;
    let cursor_row = get_u16(rest, off)?;
    let cursor_col = get_u16(rest, off)?;
    let n = get_u16(rest, off)? as usize;
    let mut lines = Vec::with_capacity(n);
    for _ in 0..n {
        lines.push(get_str(rest, off)?);
    }
    Ok(ScreenSnapshot {
        rows,
        cols,
        cursor_row,
        cursor_col,
        lines,
    })
}

// ---- CtlMsg codec -------------------------------------------------------

impl CtlMsg {
    pub fn encode(&self) -> Vec<u8> {
        let mut p = Vec::new();
        match self {
            CtlMsg::Spawn(req) => {
                p.push(T_SPAWN);
                put_str(&mut p, &req.instance);
                put_u16(&mut p, req.argv.len() as u16);
                for a in &req.argv {
                    put_str(&mut p, a);
                }
                put_opt_str(&mut p, &req.cwd);
                put_u16(&mut p, req.env.len() as u16);
                for (k, v) in &req.env {
                    put_str(&mut p, k);
                    put_str(&mut p, v);
                }
                put_opt_str(&mut p, &req.detect);
                put_u16(&mut p, req.rows);
                put_u16(&mut p, req.cols);
                put_opt_str(&mut p, &req.display_name);
            }
            CtlMsg::Close { instance } => {
                p.push(T_CLOSE);
                put_str(&mut p, instance);
            }
            CtlMsg::Restart { instance } => {
                p.push(T_RESTART);
                put_str(&mut p, instance);
            }
            CtlMsg::List => p.push(T_LIST),
            CtlMsg::Attach { instance } => {
                p.push(T_ATTACH);
                put_str(&mut p, instance);
            }
            CtlMsg::Input { instance, data } => {
                p.push(T_INPUT);
                put_str(&mut p, instance);
                p.extend_from_slice(data);
            }
            CtlMsg::Key { instance, key } => {
                p.push(T_KEY);
                put_str(&mut p, instance);
                p.push(*key as u8);
            }
            CtlMsg::Resize { instance, rows, cols } => {
                p.push(T_RESIZE);
                put_str(&mut p, instance);
                put_u16(&mut p, *rows);
                put_u16(&mut p, *cols);
            }
            CtlMsg::Capture { instance } => {
                p.push(T_CAPTURE);
                put_str(&mut p, instance);
            }
            CtlMsg::Detach { instance } => {
                p.push(T_DETACH);
                put_str(&mut p, instance);
            }
            CtlMsg::Ping => p.push(T_PING),
            CtlMsg::WatchEvents => p.push(T_WATCH_EVENTS),
            CtlMsg::Shutdown => p.push(T_SHUTDOWN),
        }
        frame(&p)
    }

    fn decode_payload(p: &[u8]) -> io::Result<CtlMsg> {
        let tag = *p.first().ok_or_else(|| bad("empty payload"))?;
        let rest = &p[1..];
        let mut off = 0usize;
        Ok(match tag {
            T_SPAWN => {
                let instance = get_str(rest, &mut off)?;
                let n = get_u16(rest, &mut off)? as usize;
                let mut argv = Vec::with_capacity(n);
                for _ in 0..n {
                    argv.push(get_str(rest, &mut off)?);
                }
                let cwd = get_opt_str(rest, &mut off)?;
                let ne = get_u16(rest, &mut off)? as usize;
                let mut env = Vec::with_capacity(ne);
                for _ in 0..ne {
                    let k = get_str(rest, &mut off)?;
                    let v = get_str(rest, &mut off)?;
                    env.push((k, v));
                }
                let detect = get_opt_str(rest, &mut off)?;
                let rows = get_u16(rest, &mut off)?;
                let cols = get_u16(rest, &mut off)?;
                let display_name = get_opt_str(rest, &mut off)?;
                CtlMsg::Spawn(SpawnRequest {
                    instance,
                    argv,
                    cwd,
                    env,
                    detect,
                    rows,
                    cols,
                    display_name,
                })
            }
            T_CLOSE => CtlMsg::Close {
                instance: get_str(rest, &mut off)?,
            },
            T_RESTART => CtlMsg::Restart {
                instance: get_str(rest, &mut off)?,
            },
            T_LIST => CtlMsg::List,
            T_ATTACH => CtlMsg::Attach {
                instance: get_str(rest, &mut off)?,
            },
            T_INPUT => {
                let instance = get_str(rest, &mut off)?;
                CtlMsg::Input {
                    instance,
                    data: rest[off..].to_vec(),
                }
            }
            T_KEY => {
                let instance = get_str(rest, &mut off)?;
                let code = *rest.get(off).ok_or_else(|| bad("key missing code"))?;
                CtlMsg::Key {
                    instance,
                    key: NamedKey::from_u8(code).ok_or_else(|| bad("bad key code"))?,
                }
            }
            T_RESIZE => {
                let instance = get_str(rest, &mut off)?;
                let rows = get_u16(rest, &mut off)?;
                let cols = get_u16(rest, &mut off)?;
                CtlMsg::Resize { instance, rows, cols }
            }
            T_CAPTURE => CtlMsg::Capture {
                instance: get_str(rest, &mut off)?,
            },
            T_DETACH => CtlMsg::Detach {
                instance: get_str(rest, &mut off)?,
            },
            T_PING => CtlMsg::Ping,
            T_WATCH_EVENTS => CtlMsg::WatchEvents,
            T_SHUTDOWN => CtlMsg::Shutdown,
            _ => return Err(bad("unknown ctl tag")),
        })
    }
}

// ---- CtlReply codec -----------------------------------------------------

impl CtlReply {
    pub fn encode(&self) -> Vec<u8> {
        let mut p = Vec::new();
        match self {
            CtlReply::Spawned { instance, pid } => {
                p.push(T_SPAWNED);
                put_str(&mut p, instance);
                put_i32(&mut p, *pid);
            }
            CtlReply::Closed { instance } => {
                p.push(T_CLOSED);
                put_str(&mut p, instance);
            }
            CtlReply::Restarted { instance, pid } => {
                p.push(T_RESTARTED);
                put_str(&mut p, instance);
                put_i32(&mut p, *pid);
            }
            CtlReply::AgentList(agents) => {
                p.push(T_AGENTLIST);
                put_u16(&mut p, agents.len() as u16);
                for a in agents {
                    put_str(&mut p, &a.instance_id);
                    put_str(&mut p, &a.program);
                    put_i32(&mut p, a.pid);
                    p.push(a.alive as u8);
                    match a.exit_code {
                        Some(c) => {
                            p.push(1);
                            put_i32(&mut p, c);
                        }
                        None => p.push(0),
                    }
                    put_u16(&mut p, a.rows);
                    put_u16(&mut p, a.cols);
                    put_u64(&mut p, a.started_at);
                    put_u64(&mut p, a.last_activity);
                    put_opt_str(&mut p, &a.display_name);
                }
            }
            CtlReply::Output { instance, data } => {
                p.push(T_OUTPUT);
                put_str(&mut p, instance);
                p.extend_from_slice(data);
            }
            CtlReply::Screen { instance, screen } => {
                p.push(T_SCREEN);
                put_str(&mut p, instance);
                put_screen(&mut p, screen);
            }
            CtlReply::ChildExited { instance, code } => {
                p.push(T_EXITED);
                put_str(&mut p, instance);
                put_i32(&mut p, *code);
            }
            CtlReply::Pong => p.push(T_PONG),
            CtlReply::Error { instance, message } => {
                p.push(T_ERROR);
                put_str(&mut p, instance);
                put_str(&mut p, message);
            }
            CtlReply::StartupReady { instance } => {
                p.push(T_STARTUP_READY);
                put_str(&mut p, instance);
            }
            CtlReply::StartupBlocked {
                instance,
                reason_code,
                safe_diagnostic,
            } => {
                p.push(T_STARTUP_BLOCKED);
                put_str(&mut p, instance);
                put_str(&mut p, reason_code);
                put_str(&mut p, safe_diagnostic);
            }
            CtlReply::ScreenChanged { instance, hash } => {
                p.push(T_SCREEN_CHANGED);
                put_str(&mut p, instance);
                put_u64(&mut p, *hash);
            }
            CtlReply::HostHeartbeat { ts_unix_ms, agents } => {
                p.push(T_HOST_HEARTBEAT);
                put_u64(&mut p, *ts_unix_ms);
                put_u16(&mut p, agents.len() as u16);
                for a in agents {
                    put_str(&mut p, &a.instance_id);
                    p.push(a.alive as u8);
                }
            }
            CtlReply::ShuttingDown => p.push(T_SHUTTING_DOWN),
        }
        frame(&p)
    }

    fn decode_payload(p: &[u8]) -> io::Result<CtlReply> {
        let tag = *p.first().ok_or_else(|| bad("empty payload"))?;
        let rest = &p[1..];
        let mut off = 0usize;
        Ok(match tag {
            T_SPAWNED => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::Spawned {
                    instance,
                    pid: get_i32(rest, &mut off)?,
                }
            }
            T_CLOSED => CtlReply::Closed {
                instance: get_str(rest, &mut off)?,
            },
            T_RESTARTED => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::Restarted {
                    instance,
                    pid: get_i32(rest, &mut off)?,
                }
            }
            T_AGENTLIST => {
                let n = get_u16(rest, &mut off)? as usize;
                let mut agents = Vec::with_capacity(n);
                for _ in 0..n {
                    let instance_id = get_str(rest, &mut off)?;
                    let program = get_str(rest, &mut off)?;
                    let pid = get_i32(rest, &mut off)?;
                    let alive = *rest.get(off).ok_or_else(|| bad("alive missing"))? != 0;
                    off += 1;
                    let has_code = *rest.get(off).ok_or_else(|| bad("exit tag missing"))?;
                    off += 1;
                    let exit_code = if has_code == 1 {
                        Some(get_i32(rest, &mut off)?)
                    } else {
                        None
                    };
                    let rows = get_u16(rest, &mut off)?;
                    let cols = get_u16(rest, &mut off)?;
                    let started_at = get_u64(rest, &mut off)?;
                    let last_activity = get_u64(rest, &mut off)?;
                    let display_name = get_opt_str(rest, &mut off)?;
                    agents.push(AgentInfo {
                        instance_id,
                        program,
                        pid,
                        alive,
                        exit_code,
                        rows,
                        cols,
                        started_at,
                        last_activity,
                        display_name,
                    });
                }
                CtlReply::AgentList(agents)
            }
            T_OUTPUT => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::Output {
                    instance,
                    data: rest[off..].to_vec(),
                }
            }
            T_SCREEN => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::Screen {
                    instance,
                    screen: get_screen(rest, &mut off)?,
                }
            }
            T_EXITED => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::ChildExited {
                    instance,
                    code: get_i32(rest, &mut off)?,
                }
            }
            T_PONG => CtlReply::Pong,
            T_ERROR => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::Error {
                    instance,
                    message: get_str(rest, &mut off)?,
                }
            }
            T_SHUTTING_DOWN => CtlReply::ShuttingDown,
            T_STARTUP_READY => CtlReply::StartupReady {
                instance: get_str(rest, &mut off)?,
            },
            T_STARTUP_BLOCKED => {
                let instance = get_str(rest, &mut off)?;
                let reason_code = get_str(rest, &mut off)?;
                let safe_diagnostic = get_str(rest, &mut off)?;
                CtlReply::StartupBlocked {
                    instance,
                    reason_code,
                    safe_diagnostic,
                }
            }
            T_SCREEN_CHANGED => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::ScreenChanged {
                    instance,
                    hash: get_u64(rest, &mut off)?,
                }
            }
            T_HOST_HEARTBEAT => {
                let ts_unix_ms = get_u64(rest, &mut off)?;
                let n = get_u16(rest, &mut off)? as usize;
                let mut agents = Vec::with_capacity(n);
                for _ in 0..n {
                    let instance_id = get_str(rest, &mut off)?;
                    let alive = *rest.get(off).ok_or_else(|| bad("host heartbeat: short alive"))? != 0;
                    off += 1;
                    agents.push(HostHeartbeatAgent { instance_id, alive });
                }
                CtlReply::HostHeartbeat { ts_unix_ms, agents }
            }
            _ => return Err(bad("unknown reply tag")),
        })
    }
}

// ---- framing + IO -------------------------------------------------------

fn frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + payload.len());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

/// Read + decode one [`CtlMsg`]. `Ok(None)` on clean EOF.
pub fn read_ctl_msg<R: Read>(r: &mut R) -> io::Result<Option<CtlMsg>> {
    match read_frame(r)? {
        Some(p) => Ok(Some(CtlMsg::decode_payload(&p)?)),
        None => Ok(None),
    }
}

/// Read + decode one [`CtlReply`]. `Ok(None)` on clean EOF.
pub fn read_ctl_reply<R: Read>(r: &mut R) -> io::Result<Option<CtlReply>> {
    match read_frame(r)? {
        Some(p) => Ok(Some(CtlReply::decode_payload(&p)?)),
        None => Ok(None),
    }
}

/// Write a client control message to `w`.
pub fn write_ctl_msg<W: Write>(w: &mut W, msg: &CtlMsg) -> io::Result<()> {
    w.write_all(&msg.encode())?;
    w.flush()
}

/// Write a daemon reply to `w`.
pub fn write_ctl_reply<W: Write>(w: &mut W, reply: &CtlReply) -> io::Result<()> {
    w.write_all(&reply.encode())?;
    w.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn round_msg(m: CtlMsg) {
        let bytes = m.encode();
        let mut cur = Cursor::new(bytes);
        let got = read_ctl_msg(&mut cur).unwrap().unwrap();
        assert_eq!(got, m);
    }

    fn round_reply(m: CtlReply) {
        let bytes = m.encode();
        let mut cur = Cursor::new(bytes);
        let got = read_ctl_reply(&mut cur).unwrap().unwrap();
        assert_eq!(got, m);
    }

    #[test]
    fn spawn_request_roundtrips_full() {
        round_msg(CtlMsg::Spawn(SpawnRequest {
            instance: "inst_abc".into(),
            argv: vec!["/bin/zsh".into(), "-l".into()],
            cwd: Some("/work/dir".into()),
            env: vec![
                ("HEIMDALL_AGENT_TOKEN".into(), "hlat_x".into()),
                ("FOO".into(), "bar".into()),
            ],
            detect: Some("{\"auto_enter_patterns\":[\"❯\"]}".into()),
            rows: 40,
            cols: 120,
            display_name: Some("default-agent #20".into()),
        }));
    }

    #[test]
    fn spawn_request_roundtrips_minimal() {
        round_msg(CtlMsg::Spawn(SpawnRequest {
            instance: "i".into(),
            argv: vec!["true".into()],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 24,
            cols: 80,
            display_name: None,
        }));
    }

    #[test]
    fn control_msgs_roundtrip() {
        round_msg(CtlMsg::Close { instance: "a".into() });
        round_msg(CtlMsg::Restart { instance: "a".into() });
        round_msg(CtlMsg::List);
        round_msg(CtlMsg::Ping);
        round_msg(CtlMsg::WatchEvents);
        round_msg(CtlMsg::Shutdown);
    }

    #[test]
    fn data_plane_msgs_roundtrip() {
        round_msg(CtlMsg::Attach { instance: "a".into() });
        round_msg(CtlMsg::Input {
            instance: "a".into(),
            data: b"echo hi\n".to_vec(),
        });
        round_msg(CtlMsg::Key {
            instance: "a".into(),
            key: NamedKey::Enter,
        });
        round_msg(CtlMsg::Resize {
            instance: "a".into(),
            rows: 50,
            cols: 200,
        });
        round_msg(CtlMsg::Capture { instance: "a".into() });
        round_msg(CtlMsg::Detach { instance: "a".into() });
    }

    #[test]
    fn replies_roundtrip() {
        round_reply(CtlReply::Spawned {
            instance: "a".into(),
            pid: 4242,
        });
        round_reply(CtlReply::Closed { instance: "a".into() });
        round_reply(CtlReply::Restarted {
            instance: "a".into(),
            pid: 99,
        });
        round_reply(CtlReply::Output {
            instance: "a".into(),
            data: b"\x1b[31mred".to_vec(),
        });
        round_reply(CtlReply::ChildExited {
            instance: "a".into(),
            code: 137,
        });
        round_reply(CtlReply::Pong);
        round_reply(CtlReply::Error {
            instance: "a".into(),
            message: "no such instance".into(),
        });
        round_reply(CtlReply::StartupReady { instance: "a".into() });
        round_reply(CtlReply::StartupBlocked {
            instance: "a".into(),
            reason_code: "blocked_0Login_required".into(),
            safe_diagnostic: "Provider login required".into(),
        });
        round_reply(CtlReply::ScreenChanged {
            instance: "a".into(),
            hash: 0xdead_beef_cafe_1234,
        });
        round_reply(CtlReply::HostHeartbeat {
            ts_unix_ms: 1_788_549_000_123,
            agents: vec![
                HostHeartbeatAgent { instance_id: "inst_a".into(), alive: true },
                HostHeartbeatAgent { instance_id: "inst_b".into(), alive: false },
            ],
        });
        round_reply(CtlReply::HostHeartbeat { ts_unix_ms: 0, agents: vec![] });
        round_reply(CtlReply::ShuttingDown);
    }

    #[test]
    fn agent_list_roundtrips_with_mixed_state() {
        round_reply(CtlReply::AgentList(vec![
            AgentInfo {
                instance_id: "inst_1".into(),
                program: "/bin/zsh".into(),
                pid: 111,
                alive: true,
                exit_code: None,
                rows: 24,
                cols: 80,
                started_at: 1_700_000_000,
                last_activity: 1_700_000_050,
                display_name: Some("default-agent #20".into()),
            },
            AgentInfo {
                instance_id: "inst_2".into(),
                program: "claude".into(),
                pid: 222,
                alive: false,
                exit_code: Some(0),
                rows: 40,
                cols: 120,
                started_at: 1_700_000_100,
                last_activity: 1_700_000_100,
                display_name: None,
            },
        ]));
        round_reply(CtlReply::AgentList(vec![]));
    }

    #[test]
    fn screen_reply_roundtrips() {
        round_reply(CtlReply::Screen {
            instance: "a".into(),
            screen: ScreenSnapshot {
                rows: 3,
                cols: 10,
                cursor_row: 1,
                cursor_col: 2,
                lines: vec!["hello".into(), "".into(), "world".into()],
            },
        });
    }

    #[test]
    fn multiple_frames_in_stream() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&CtlMsg::List.encode());
        buf.extend_from_slice(&CtlMsg::Attach { instance: "x".into() }.encode());
        buf.extend_from_slice(&CtlMsg::Ping.encode());
        let mut cur = Cursor::new(buf);
        assert_eq!(read_ctl_msg(&mut cur).unwrap().unwrap(), CtlMsg::List);
        assert_eq!(
            read_ctl_msg(&mut cur).unwrap().unwrap(),
            CtlMsg::Attach { instance: "x".into() }
        );
        assert_eq!(read_ctl_msg(&mut cur).unwrap().unwrap(), CtlMsg::Ping);
        assert!(read_ctl_msg(&mut cur).unwrap().is_none());
    }
}
