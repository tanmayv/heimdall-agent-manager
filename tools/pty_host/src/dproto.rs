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
//! | 0x38 | WatchEvents | subscribe to host-level events (heartbeat + lifecycle) |
//! | 0x39 | Signal  | POSIX signal to a shell's process group                    |
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
//! | 0xAE | StreamReady | stream attached and ready to accept input/output     |
//! | 0xAF | StreamClosed| stream closed (child exited or teardown)             |
//! | 0xB0 | AlreadyExited| Signal target had already exited (instance + code)  |
//! | 0x3B | StartupLaunch | query actual live child by immutable spawn key   |
//! | 0xB2 | StartupLaunch | reply with matching live pid, or 0 if absent     |
//! | 0x3A | StartupInput | launch-fenced, idempotent startup instruction       |
//! | 0xB1 | StartupInputDone | startup bytes written (instance + pid + key)   |

use std::io::{self, Read, Write};

use crate::proto::{NamedKey, ScreenSnapshot};

/// Everything the daemon needs to (re-)spawn an agent. The daemon stores this so
/// `Restart` re-spawns the exact same command without the caller re-plumbing it.
// serde_json::Value is PartialEq but not Eq (f64 NaN), so Eq is not derived here.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SpawnMode { #[default] Pty, Pipe }

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PipeInfo {
    pub instance: String,
    pub generation: String,
    pub pid: i32,
    pub alive: bool,
    pub exit_code: Option<i32>,
    pub meta: Option<serde_json::Value>,
}

pub const MAX_CTL_FRAME: usize = 4 * 1024 * 1024;
pub const MAX_PIPE_DATA: usize = 64 * 1024;

#[derive(Clone, Debug, PartialEq, Default)]
pub struct SpawnRequest {
    pub mode: SpawnMode,
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
    /// Session kind: "run" | "shell" | "server".
    ///
    /// PURE PASSTHROUGH. The daemon never branches on this value — the only use of the
    /// field in the whole Rust tree is the `put_opt_str` that re-serializes it — so
    /// nothing about PTY-vs-pipe behaviour depends on it. Kept as a free-form
    /// `Option<String>` rather than an enum for exactly that reason: the hub owns the
    /// vocabulary and validates it, and this side must not acquire a second opinion that
    /// could drift. The spellings above are documentation of what the hub currently sends,
    /// not a contract enforced here.
    pub kind: Option<String>,
    /// Human label for the session.
    pub label: Option<String>,
    /// Opaque metadata bag (arbitrary JSON).
    pub meta: Option<serde_json::Value>,
    /// Absolute path to tee output file; None = no tee.
    pub tee_path: Option<String>,
    /// Maximum lifetime of the child process in seconds. `None` means no
    /// deadline. A restart starts a fresh timeout from the new child spawn.
    pub timeout_seconds: Option<u64>,
}

impl SpawnRequest {
    pub fn instance_id(&self) -> &str {
        &self.instance
    }

    pub fn shell_id(&self) -> &str {
        &self.instance
    }
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

impl AgentInfo {
    pub fn instance_id(&self) -> &str {
        &self.instance_id
    }

    pub fn shell_id(&self) -> &str {
        &self.instance_id
    }
}

/// A row in the shell listing: one registered shell's live state.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct ShellInfo {
    pub shell_id: String,
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
    /// Human-readable display name (e.g. "default-agent #20").
    pub display_name: Option<String>,
    /// TCP port bound by this shell session; None when unknown (Phase 1: always None).
    pub bound_port: Option<u16>,
}

impl ShellInfo {
    pub fn shell_id(&self) -> &str {
        &self.shell_id
    }

    /// Backward-compatible instance_id accessor.
    pub fn instance_id(&self) -> &str {
        &self.shell_id
    }
}

/// A registered shell session entity in ham-pty-host.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Shell {
    pub shell_id: String,
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
    /// Human-readable display name (e.g. "default-agent #20").
    pub display_name: Option<String>,
    /// TCP port bound by this shell session; None when unknown (Phase 1: always None).
    pub bound_port: Option<u16>,
}

impl Shell {
    pub fn shell_id(&self) -> &str {
        &self.shell_id
    }

    /// Backward-compatible instance_id accessor.
    pub fn instance_id(&self) -> &str {
        &self.shell_id
    }

    pub fn info(&self) -> ShellInfo {
        ShellInfo {
            shell_id: self.shell_id.clone(),
            program: self.program.clone(),
            pid: self.pid,
            alive: self.alive,
            exit_code: self.exit_code,
            rows: self.rows,
            cols: self.cols,
            started_at: self.started_at,
            last_activity: self.last_activity,
            display_name: self.display_name.clone(),
            bound_port: self.bound_port,
        }
    }
}

impl From<Shell> for ShellInfo {
    fn from(s: Shell) -> Self {
        s.info()
    }
}

impl From<ShellInfo> for Shell {
    fn from(info: ShellInfo) -> Self {
        Self {
            shell_id: info.shell_id,
            program: info.program,
            pid: info.pid,
            alive: info.alive,
            exit_code: info.exit_code,
            rows: info.rows,
            cols: info.cols,
            started_at: info.started_at,
            last_activity: info.last_activity,
            display_name: info.display_name,
            bound_port: info.bound_port,
        }
    }
}

impl From<AgentInfo> for ShellInfo {
    fn from(a: AgentInfo) -> Self {
        Self {
            shell_id: a.instance_id,
            program: a.program,
            pid: a.pid,
            alive: a.alive,
            exit_code: a.exit_code,
            rows: a.rows,
            cols: a.cols,
            started_at: a.started_at,
            last_activity: a.last_activity,
            display_name: a.display_name,
            bound_port: None,
        }
    }
}

impl From<ShellInfo> for AgentInfo {
    fn from(s: ShellInfo) -> Self {
        Self {
            instance_id: s.shell_id,
            program: s.program,
            pid: s.pid,
            alive: s.alive,
            exit_code: s.exit_code,
            rows: s.rows,
            cols: s.cols,
            started_at: s.started_at,
            last_activity: s.last_activity,
            display_name: s.display_name,
        }
    }
}

impl From<AgentInfo> for Shell {
    fn from(a: AgentInfo) -> Self {
        ShellInfo::from(a).into()
    }
}

impl From<Shell> for AgentInfo {
    fn from(s: Shell) -> Self {
        s.info().into()
    }
}

/// Signal request: send a POSIX signal to a shell's process group.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignalRequest {
    pub shell_id: String,
    /// POSIX signal number (e.g. 15=SIGTERM, 2=SIGINT, 9=SIGKILL).
    pub signal: u8,
}

/// client -> daemon.
// SpawnRequest contains serde_json::Value (not Eq), so Eq is not derived.
#[derive(Clone, Debug, PartialEq)]
pub enum CtlMsg {
    Capabilities,
    SpawnPipe(SpawnRequest),
    ListPipes,
    AttachPipe { instance: String, generation: String, after_seq: u64 },
    PipeInput { instance: String, generation: String, delivery_id: String, data: Vec<u8> },
    PipeAck { instance: String, generation: String, through_seq: u64 },
    PipeDetach { instance: String, generation: String },
    // control plane
    Spawn(SpawnRequest),
    Close { instance: String },
    Restart { instance: String },
    List,
    // data plane (instance-scoped)
    Attach { instance: String },
    Input { instance: String, data: Vec<u8> },
    /// REQ-START-3: exactly one startup instruction per child. A repeated request
    /// returns its receipt; a different launch key/pid is rejected before input.
    StartupInput { instance: String, pid: i32, launch_key: String, data: Vec<u8> },
    /// Confirm a successfully spawned, still-live child by its immutable spawn key.
    /// Unlike bridge token issuance, this evidence survives a bridge restart.
    StartupLaunch { instance: String, launch_key: String },
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
    /// Send a POSIX signal to a shell's process group (tag 0x39).
    Signal(SignalRequest),
}

/// daemon -> client.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CtlReply {
    Capabilities { piped_spawn_v1: bool },
    PipeList(Vec<PipeInfo>),
    PipeReady { instance: String, generation: String, first_seq: u64, last_seq: u64 },
    PipeOutput { instance: String, generation: String, seq: u64, stream: u8, data: Vec<u8> },
    PipeInputDone { instance: String, generation: String, delivery_id: String },
    PipeGap { instance: String, generation: String, first_seq: u64 },
    StartupInputDone { instance: String, pid: i32, launch_key: String },
    /// pid=0 means no live child was spawned with the requested key.
    StartupLaunch { instance: String, pid: i32, launch_key: String },
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
    /// REQ-STREAM-EVENT-2: stream attached and ready to accept input/output.
    StreamReady { instance: String },
    /// REQ-STREAM-EVENT-2: stream closed (child exited or teardown).
    StreamClosed { instance: String, code: Option<i32> },
    /// REQ-PTY-1: reply to [`CtlMsg::Signal`] when the target's child has
    /// already exited (its tombstone is still registered). Distinct from
    /// `Error` so the caller can finalize the session with `code` instead of
    /// treating the refused signal as a failure. The daemon never signals a
    /// reaped pid, since its process group id may have been reused.
    AlreadyExited { instance: String, code: i32 },
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
const T_SIGNAL: u8 = 0x39;
const T_STARTUP_INPUT: u8 = 0x3A;
const T_STARTUP_LAUNCH: u8 = 0x3B;
const T_STARTUP_LAUNCH_REPLY: u8 = 0xB2;

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
pub const T_STREAM_READY: u8 = 0xAE;
pub const T_STREAM_CLOSED: u8 = 0xAF;
pub const T_ALREADY_EXITED: u8 = 0xB0;
const T_STARTUP_INPUT_DONE: u8 = 0xB1;

fn put_bytes(p: &mut Vec<u8>, data: &[u8]) {
    p.extend_from_slice(&(data.len() as u32).to_be_bytes()); p.extend_from_slice(data);
}
fn get_u32(rest: &[u8], off: &mut usize) -> io::Result<u32> { Ok(get_i32(rest, off)? as u32) }
fn get_bytes(rest: &[u8], off: &mut usize) -> io::Result<Vec<u8>> {
    let n = get_u32(rest, off)? as usize;
    if n > MAX_PIPE_DATA || n > rest.len().saturating_sub(*off) { return Err(bad("invalid pipe data length")); }
    let data = rest[*off..*off+n].to_vec(); *off += n; Ok(data)
}
fn get_bool(rest: &[u8], off: &mut usize) -> io::Result<bool> {
    let b = *rest.get(*off).ok_or_else(|| bad("missing boolean"))?; *off += 1;
    match b { 0 => Ok(false), 1 => Ok(true), _ => Err(bad("invalid boolean")) }
}

/// Read daemon frames with a stricter allocation bound than the terminal protocol.
fn read_frame<R: Read>(r: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut prefix = [0; 4];
    match r.read(&mut prefix[..1]) { Ok(0) => return Ok(None), Ok(_) => (), Err(e) => return Err(e) }
    r.read_exact(&mut prefix[1..])?;
    let n = u32::from_be_bytes(prefix) as usize;
    if n > MAX_CTL_FRAME { return Err(bad("oversized control frame")); }
    let mut p = vec![0; n]; r.read_exact(&mut p)?; Ok(Some(p))
}

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

fn put_opt_u64(p: &mut Vec<u8>, v: Option<u64>) {
    match v {
        Some(value) => {
            p.push(1);
            put_u64(p, value);
        }
        None => p.push(0),
    }
}

fn get_opt_u64(rest: &[u8], off: &mut usize) -> io::Result<Option<u64>> {
    let present = *rest.get(*off).ok_or_else(|| bad("opt-u64 tag missing"))?;
    *off += 1;
    match present {
        0 => Ok(None),
        1 => Ok(Some(get_u64(rest, off)?)),
        _ => Err(bad("bad opt-u64 tag")),
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
    pub fn shell_id(&self) -> Option<&str> {
        match self {
            CtlMsg::Spawn(req) | CtlMsg::SpawnPipe(req) => Some(&req.instance),
            CtlMsg::AttachPipe { instance, .. } | CtlMsg::PipeInput { instance, .. } |
            CtlMsg::PipeAck { instance, .. } | CtlMsg::PipeDetach { instance, .. } => Some(instance),
            CtlMsg::Close { instance } => Some(instance),
            CtlMsg::Restart { instance } => Some(instance),
            CtlMsg::Attach { instance } => Some(instance),
            CtlMsg::Input { instance, .. } => Some(instance),
            CtlMsg::StartupInput { instance, .. } => Some(instance),
            CtlMsg::StartupLaunch { instance, .. } => Some(instance),
            CtlMsg::Key { instance, .. } => Some(instance),
            CtlMsg::Resize { instance, .. } => Some(instance),
            CtlMsg::Capture { instance } => Some(instance),
            CtlMsg::Detach { instance } => Some(instance),
            CtlMsg::Signal(req) => Some(&req.shell_id),
            _ => None,
        }
    }

    pub fn instance_id(&self) -> Option<&str> {
        self.shell_id()
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut p = Vec::new();
        match self {
            CtlMsg::Capabilities => p.push(0x40),
            CtlMsg::ListPipes => p.push(0x42),
            CtlMsg::AttachPipe { instance, generation, after_seq } => {
                p.push(0x43); put_str(&mut p, instance); put_str(&mut p, generation); put_u64(&mut p, *after_seq);
            }
            CtlMsg::PipeInput { instance, generation, delivery_id, data } => {
                p.push(0x44); put_str(&mut p, instance); put_str(&mut p, generation); put_str(&mut p, delivery_id);
                put_bytes(&mut p, data);
            }
            CtlMsg::PipeAck { instance, generation, through_seq } => {
                p.push(0x45); put_str(&mut p, instance); put_str(&mut p, generation); put_u64(&mut p, *through_seq);
            }
            CtlMsg::PipeDetach { instance, generation } => {
                p.push(0x46); put_str(&mut p, instance); put_str(&mut p, generation);
            }
            CtlMsg::Spawn(req) | CtlMsg::SpawnPipe(req) => {
                p.push(if matches!(self, CtlMsg::SpawnPipe(_)) { 0x41 } else { T_SPAWN });
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
                // Backward-compat appended fields (absent on old clients → None).
                put_opt_str(&mut p, &req.kind);
                put_opt_str(&mut p, &req.label);
                let meta_str = req.meta.as_ref().map(|v| v.to_string());
                put_opt_str(&mut p, &meta_str);
                put_opt_str(&mut p, &req.tee_path);
                put_opt_u64(&mut p, req.timeout_seconds);
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
            CtlMsg::StartupInput { instance, pid, launch_key, data } => {
                p.push(T_STARTUP_INPUT);
                put_str(&mut p, instance);
                put_i32(&mut p, *pid);
                put_str(&mut p, launch_key);
                p.extend_from_slice(data);
            }
            CtlMsg::StartupLaunch { instance, launch_key } => {
                p.push(T_STARTUP_LAUNCH);
                put_str(&mut p, instance);
                put_str(&mut p, launch_key);
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
            CtlMsg::Signal(req) => {
                p.push(T_SIGNAL);
                put_str(&mut p, &req.shell_id);
                p.push(req.signal);
            }
        }
        frame(&p)
    }

    fn decode_payload(p: &[u8]) -> io::Result<CtlMsg> {
        let tag = *p.first().ok_or_else(|| bad("empty payload"))?;
        let rest = &p[1..];
        let mut off = 0usize;
        let result = match tag {
            T_SPAWN | 0x41 => {
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
                // Optional shell metadata precedes the required timeout option.
                let kind = if off < rest.len() { get_opt_str(rest, &mut off)? } else { None };
                let label = if off < rest.len() { get_opt_str(rest, &mut off)? } else { None };
                let meta_str = if off < rest.len() { get_opt_str(rest, &mut off)? } else { None };
                let meta = if tag == 0x41 {
                    meta_str.map(|s| serde_json::from_str(&s).map_err(|_| bad("invalid pipe metadata"))).transpose()?
                } else { meta_str.and_then(|s| serde_json::from_str(&s).ok()) };
                let tee_path = if off < rest.len() { get_opt_str(rest, &mut off)? } else { None };
                let timeout_seconds = get_opt_u64(rest, &mut off)?;
                let req = SpawnRequest {
                    mode: if tag == 0x41 { SpawnMode::Pipe } else { SpawnMode::Pty },
                    instance,
                    argv,
                    cwd,
                    env,
                    detect,
                    rows,
                    cols,
                    display_name,
                    kind,
                    label,
                    meta,
                    tee_path,
                    timeout_seconds,
                };
                if tag == 0x41 { CtlMsg::SpawnPipe(req) } else { CtlMsg::Spawn(req) }
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
            T_STARTUP_INPUT => {
                let instance = get_str(rest, &mut off)?;
                let pid = get_i32(rest, &mut off)?;
                let launch_key = get_str(rest, &mut off)?;
                CtlMsg::StartupInput { instance, pid, launch_key, data: rest[off..].to_vec() }
            }
            T_STARTUP_LAUNCH => CtlMsg::StartupLaunch {
                instance: get_str(rest, &mut off)?,
                launch_key: get_str(rest, &mut off)?,
            },
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
            T_SIGNAL => {
                let shell_id = get_str(rest, &mut off)?;
                let signal = *rest.get(off).ok_or_else(|| bad("signal byte missing"))?;
                CtlMsg::Signal(SignalRequest { shell_id, signal })
            }
            0x40 => CtlMsg::Capabilities,
            0x42 => CtlMsg::ListPipes,
            0x43 => CtlMsg::AttachPipe { instance: get_str(rest, &mut off)?, generation: get_str(rest, &mut off)?, after_seq: get_u64(rest, &mut off)? },
            0x44 => CtlMsg::PipeInput { instance: get_str(rest, &mut off)?, generation: get_str(rest, &mut off)?, delivery_id: get_str(rest, &mut off)?, data: get_bytes(rest, &mut off)? },
            0x45 => CtlMsg::PipeAck { instance: get_str(rest, &mut off)?, generation: get_str(rest, &mut off)?, through_seq: get_u64(rest, &mut off)? },
            0x46 => CtlMsg::PipeDetach { instance: get_str(rest, &mut off)?, generation: get_str(rest, &mut off)? },
            _ => return Err(bad("unknown ctl tag")),
        };
        if (0x40..=0x46).contains(&tag) && off != rest.len() { return Err(bad("trailing pipe request data")); }
        Ok(result)
    }
}

// ---- CtlReply codec -----------------------------------------------------

impl CtlReply {
    pub fn shell_id(&self) -> Option<&str> {
        match self {
            CtlReply::PipeReady { instance, .. } | CtlReply::PipeOutput { instance, .. } |
            CtlReply::PipeInputDone { instance, .. } | CtlReply::PipeGap { instance, .. } => Some(instance),
            CtlReply::Spawned { instance, .. } => Some(instance),
            CtlReply::Closed { instance } => Some(instance),
            CtlReply::Restarted { instance, .. } => Some(instance),
            CtlReply::Output { instance, .. } => Some(instance),
            CtlReply::Screen { instance, .. } => Some(instance),
            CtlReply::ChildExited { instance, .. } => Some(instance),
            CtlReply::Error { instance, .. } => Some(instance),
            CtlReply::StartupReady { instance } => Some(instance),
            CtlReply::StartupBlocked { instance, .. } => Some(instance),
            CtlReply::ScreenChanged { instance, .. } => Some(instance),
            CtlReply::StreamReady { instance } => Some(instance),
            CtlReply::StreamClosed { instance, .. } => Some(instance),
            CtlReply::AlreadyExited { instance, .. } => Some(instance),
            CtlReply::StartupInputDone { instance, .. } => Some(instance),
            CtlReply::StartupLaunch { instance, .. } => Some(instance),
            _ => None,
        }
    }

    pub fn instance_id(&self) -> Option<&str> {
        self.shell_id()
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut p = Vec::new();
        match self {
            CtlReply::Capabilities { piped_spawn_v1 } => { p.push(0xC0); p.push(*piped_spawn_v1 as u8); }
            CtlReply::PipeList(rows) => {
                p.push(0xC1); p.extend_from_slice(&(rows.len() as u32).to_be_bytes());
                for row in rows {
                    put_str(&mut p, &row.instance); put_str(&mut p, &row.generation);
                    put_i32(&mut p, row.pid); p.push(row.alive as u8);
                    match row.exit_code { Some(code) => { p.push(1); put_i32(&mut p, code); }, None => p.push(0) }
                    put_opt_str(&mut p, &row.meta.as_ref().map(|v| v.to_string()));
                }
            }
            CtlReply::PipeReady { instance, generation, first_seq, last_seq } => {
                p.push(0xC2); put_str(&mut p, instance); put_str(&mut p, generation); put_u64(&mut p, *first_seq); put_u64(&mut p, *last_seq);
            }
            CtlReply::PipeOutput { instance, generation, seq, stream, data } => {
                p.push(0xC3); put_str(&mut p, instance); put_str(&mut p, generation); put_u64(&mut p, *seq); p.push(*stream); put_bytes(&mut p, data);
            }
            CtlReply::PipeInputDone { instance, generation, delivery_id } => {
                p.push(0xC4); put_str(&mut p, instance); put_str(&mut p, generation); put_str(&mut p, delivery_id);
            }
            CtlReply::PipeGap { instance, generation, first_seq } => {
                p.push(0xC5); put_str(&mut p, instance); put_str(&mut p, generation); put_u64(&mut p, *first_seq);
            }
            CtlReply::StartupInputDone { instance, pid, launch_key } => {
                p.push(T_STARTUP_INPUT_DONE);
                put_str(&mut p, instance);
                put_i32(&mut p, *pid);
                put_str(&mut p, launch_key);
            }
            CtlReply::StartupLaunch { instance, pid, launch_key } => {
                p.push(T_STARTUP_LAUNCH_REPLY);
                put_str(&mut p, instance);
                put_i32(&mut p, *pid);
                put_str(&mut p, launch_key);
            }
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
            CtlReply::StreamReady { instance } => {
                p.push(T_STREAM_READY);
                put_str(&mut p, instance);
            }
            CtlReply::StreamClosed { instance, code } => {
                p.push(T_STREAM_CLOSED);
                put_str(&mut p, instance);
                match code {
                    Some(c) => {
                        p.push(1);
                        put_i32(&mut p, *c);
                    }
                    None => p.push(0),
                }
            }
            CtlReply::AlreadyExited { instance, code } => {
                p.push(T_ALREADY_EXITED);
                put_str(&mut p, instance);
                put_i32(&mut p, *code);
            }
        }
        frame(&p)
    }

    fn decode_payload(p: &[u8]) -> io::Result<CtlReply> {
        let tag = *p.first().ok_or_else(|| bad("empty payload"))?;
        let rest = &p[1..];
        let mut off = 0usize;
        let result = match tag {
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
            T_STREAM_READY => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::StreamReady { instance }
            }
            T_STREAM_CLOSED => {
                let instance = get_str(rest, &mut off)?;
                let has_code = *rest.get(off).ok_or_else(|| bad("stream closed: code flag missing"))?;
                off += 1;
                let code = if has_code == 1 {
                    Some(get_i32(rest, &mut off)?)
                } else {
                    None
                };
                CtlReply::StreamClosed { instance, code }
            }
            T_ALREADY_EXITED => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::AlreadyExited {
                    instance,
                    code: get_i32(rest, &mut off)?,
                }
            }
            T_STARTUP_LAUNCH_REPLY => CtlReply::StartupLaunch {
                instance: get_str(rest, &mut off)?,
                pid: get_i32(rest, &mut off)?,
                launch_key: get_str(rest, &mut off)?,
            },
            T_STARTUP_INPUT_DONE => CtlReply::StartupInputDone {
                instance: get_str(rest, &mut off)?,
                pid: get_i32(rest, &mut off)?,
                launch_key: get_str(rest, &mut off)?,
            },
            0xC0 => CtlReply::Capabilities { piped_spawn_v1: get_bool(rest, &mut off)? },
            0xC1 => {
                let n = get_u32(rest, &mut off)? as usize;
                if n > rest.len() / 15 { return Err(bad("pipe list count too large")); }
                let mut rows = Vec::with_capacity(n);
                for _ in 0..n {
                    let instance = get_str(rest, &mut off)?;
                    let generation = get_str(rest, &mut off)?;
                    let pid = get_i32(rest, &mut off)?;
                    let alive = get_bool(rest, &mut off)?;
                    let exit_code = if get_bool(rest, &mut off)? { Some(get_i32(rest, &mut off)?) } else { None };
                    let meta = get_opt_str(rest, &mut off)?.map(|v| serde_json::from_str(&v).map_err(|_| bad("invalid pipe metadata"))).transpose()?;
                    rows.push(PipeInfo { instance, generation, pid, alive, exit_code, meta });
                }
                CtlReply::PipeList(rows)
            }
            0xC2 => CtlReply::PipeReady { instance: get_str(rest, &mut off)?, generation: get_str(rest, &mut off)?, first_seq: get_u64(rest, &mut off)?, last_seq: get_u64(rest, &mut off)? },
            0xC3 => {
                let instance = get_str(rest, &mut off)?; let generation = get_str(rest, &mut off)?;
                let seq = get_u64(rest, &mut off)?;
                let stream = *rest.get(off).ok_or_else(|| bad("stream missing"))?; off += 1;
                if !matches!(stream, 1 | 2) || (stream == 2 && seq != 0) || (stream == 1 && seq == 0) { return Err(bad("invalid pipe stream/sequence")); }
                CtlReply::PipeOutput { instance, generation, seq, stream, data: get_bytes(rest, &mut off)? }
            }
            0xC4 => CtlReply::PipeInputDone { instance: get_str(rest, &mut off)?, generation: get_str(rest, &mut off)?, delivery_id: get_str(rest, &mut off)? },
            0xC5 => CtlReply::PipeGap { instance: get_str(rest, &mut off)?, generation: get_str(rest, &mut off)?, first_seq: get_u64(rest, &mut off)? },
            _ => return Err(bad("unknown reply tag")),
        };
        if (0xC0..=0xC5).contains(&tag) && off != rest.len() { return Err(bad("trailing pipe reply data")); }
        Ok(result)
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

    #[test]
    fn startup_launch_query_roundtrip() {
        round_msg(CtlMsg::StartupLaunch { instance: "inst".into(), launch_key: "spawn-key".into() });
        for pid in [0, 42] {
            round_reply(CtlReply::StartupLaunch { instance: "inst".into(), pid, launch_key: "spawn-key".into() });
        }
    }

    #[test]
    fn startup_input_wire_roundtrips_and_truncation_is_rejected() {
        let msg = CtlMsg::StartupInput { instance: "inst".into(), pid: 42, launch_key: "launch".into(), data: b"confirm\r".to_vec() };
        round_msg(msg.clone());
        round_reply(CtlReply::StartupInputDone { instance: "inst".into(), pid: 42, launch_key: "launch".into() });
        let encoded = msg.encode();
        assert_eq!(encoded[4], 0x3A);
        // Fixed prefix ends after the launch key; missing fields fail parsing.
        let payload = &encoded[4..];
        let prefix_len = payload.len() - b"confirm\r".len();
        for n in 0..prefix_len {
            assert!(CtlMsg::decode_payload(&payload[..n]).is_err());
        }
    }

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
    fn pipe_variants_roundtrip_and_reject_truncation_or_trailing_data() {
        let requests = vec![
            CtlMsg::Capabilities, CtlMsg::ListPipes,
            CtlMsg::SpawnPipe(SpawnRequest { mode: SpawnMode::Pipe, instance: "i".into(), argv: vec!["cat".into()], ..Default::default() }),
            CtlMsg::AttachPipe { instance: "i".into(), generation: "g".into(), after_seq: 9 },
            CtlMsg::PipeInput { instance: "i".into(), generation: "g".into(), delivery_id: "d".into(), data: vec![0, 255, 10] },
            CtlMsg::PipeAck { instance: "i".into(), generation: "g".into(), through_seq: 10 },
            CtlMsg::PipeDetach { instance: "i".into(), generation: "g".into() },
        ];
        for req in requests {
            let bytes = req.encode();
            round_msg(req);
            for n in 0..bytes.len()-4 { assert!(CtlMsg::decode_payload(&bytes[4..4+n]).is_err(), "truncated request {n}"); }
            let mut extra = bytes[4..].to_vec(); extra.push(0);
            assert!(CtlMsg::decode_payload(&extra).is_err());
        }
        let replies = vec![
            CtlReply::Capabilities { piped_spawn_v1: true },
            CtlReply::PipeList(vec![PipeInfo { instance: "i".into(), generation: "g".into(), pid: 42, alive: false, exit_code: Some(-9), meta: Some(serde_json::json!({"provider":"claude"})) }]),
            CtlReply::PipeReady { instance: "i".into(), generation: "g".into(), first_seq: 1, last_seq: 10 },
            CtlReply::PipeOutput { instance: "i".into(), generation: "g".into(), seq: 1, stream: 1, data: vec![0,255,10] },
            CtlReply::PipeOutput { instance: "i".into(), generation: "g".into(), seq: 0, stream: 2, data: b"diag".to_vec() },
            CtlReply::PipeInputDone { instance: "i".into(), generation: "g".into(), delivery_id: "d".into() },
            CtlReply::PipeGap { instance: "i".into(), generation: "g".into(), first_seq: 2 },
        ];
        for reply in replies {
            let bytes = reply.encode(); round_reply(reply);
            for n in 0..bytes.len()-4 { assert!(CtlReply::decode_payload(&bytes[4..4+n]).is_err(), "truncated reply {n}"); }
            let mut extra = bytes[4..].to_vec(); extra.push(0);
            assert!(CtlReply::decode_payload(&extra).is_err());
        }
        // Golden vectors shared with the Odin tests.
        assert_eq!(CtlMsg::AttachPipe { instance: "i".into(), generation: "g".into(), after_seq: 9 }.encode(),
            vec![0,0,0,19,0x43,0,0,0,1,b'i',0,0,0,1,b'g',0,0,0,0,0,0,0,9]);
        assert_eq!(CtlReply::Capabilities { piped_spawn_v1: true }.encode(), vec![0,0,0,2,0xC0,1]);
    }

    #[test]
    fn pipe_codecs_bound_allocations_and_validate_discriminants() {
        let oversized = ((MAX_CTL_FRAME + 1) as u32).to_be_bytes();
        assert!(read_ctl_msg(&mut Cursor::new(oversized)).is_err());
        assert!(read_ctl_reply(&mut Cursor::new(oversized)).is_err());
        let input = CtlMsg::PipeInput { instance: "i".into(), generation: "g".into(), delivery_id: "d".into(), data: vec![0; MAX_PIPE_DATA + 1] };
        assert!(read_ctl_msg(&mut Cursor::new(input.encode())).is_err());
        for stream in [0, 3, 255] {
            let reply = CtlReply::PipeOutput { instance: "i".into(), generation: "g".into(), seq: 1, stream, data: vec![] };
            assert!(read_ctl_reply(&mut Cursor::new(reply.encode())).is_err());
        }
        assert!(CtlReply::decode_payload(&[0xC0,2]).is_err());
        assert!(CtlMsg::decode_payload(&[0x47]).is_err());
        assert!(CtlReply::decode_payload(&[0xC1,255,255,255,255]).is_err());
    }

    #[test]
    fn spawn_request_roundtrips_full() {
        round_msg(CtlMsg::Spawn(SpawnRequest {
            mode: SpawnMode::Pty,
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
            kind: Some("run".into()),
            label: Some("my-worker".into()),
            meta: Some(serde_json::json!({"project": "acme", "priority": 1})),
            tee_path: Some("/var/log/agent_abc.log".into()),
            timeout_seconds: Some(120),
        }));
    }

    #[test]
    fn spawn_request_roundtrips_minimal() {
        round_msg(CtlMsg::Spawn(SpawnRequest {
            mode: SpawnMode::Pty,
            instance: "i".into(),
            argv: vec!["true".into()],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 24,
            cols: 80,
            display_name: None,
            kind: None,
            label: None,
            meta: None,
            tee_path: None,
            timeout_seconds: None,
        }));
    }

    #[test]
    fn spawn_request_with_all_optional_fields_absent_roundtrips() {
        let request = CtlMsg::Spawn(SpawnRequest {
            mode: SpawnMode::Pty,
            instance: "old".into(),
            argv: vec!["sh".into()],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 24,
            cols: 80,
            display_name: None,
            kind: None,
            label: None,
            meta: None,
            tee_path: None,
            timeout_seconds: None,
        });
        let bytes = request.encode();
        let mut cur = std::io::Cursor::new(bytes);
        let decoded = read_ctl_msg(&mut cur).unwrap().unwrap();
        assert_eq!(decoded, request);
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
    fn signal_msg_roundtrips() {
        round_msg(CtlMsg::Signal(SignalRequest { shell_id: "sh_1".into(), signal: 15 }));
        round_msg(CtlMsg::Signal(SignalRequest { shell_id: "sh_2".into(), signal: 9 }));
        round_msg(CtlMsg::Signal(SignalRequest { shell_id: "sh_3".into(), signal: 2 }));
        // shell_id accessor
        let msg = CtlMsg::Signal(SignalRequest { shell_id: "target".into(), signal: 15 });
        assert_eq!(msg.shell_id(), Some("target"));
        assert_eq!(msg.instance_id(), Some("target"));
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
        round_reply(CtlReply::StreamReady { instance: "sh_ready".into() });
        round_reply(CtlReply::StreamClosed { instance: "sh_closed".into(), code: Some(0) });
        round_reply(CtlReply::StreamClosed { instance: "sh_closed_nocode".into(), code: None });
        round_reply(CtlReply::AlreadyExited { instance: "sh_done".into(), code: 0 });
        round_reply(CtlReply::AlreadyExited { instance: "sh_killed".into(), code: -1 });
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

    #[test]
    fn shell_and_shell_info_accessors_and_conversions() {
        let shell = Shell {
            shell_id: "shell_123".into(),
            program: "/bin/bash".into(),
            pid: 456,
            alive: true,
            exit_code: None,
            rows: 25,
            cols: 80,
            started_at: 1_700_000_000,
            last_activity: 1_700_000_010,
            display_name: Some("test shell".into()),
            bound_port: None,
        };

        assert_eq!(shell.shell_id(), "shell_123");
        assert_eq!(shell.instance_id(), "shell_123");

        let info = shell.info();
        assert_eq!(info.shell_id(), "shell_123");
        assert_eq!(info.instance_id(), "shell_123");
        assert_eq!(info.program, "/bin/bash");
        assert_eq!(info.pid, 456);
        assert!(info.alive);
        assert_eq!(info.rows, 25);
        assert_eq!(info.cols, 80);

        // Conversion roundtrips
        let from_info: Shell = info.clone().into();
        assert_eq!(from_info, shell);

        let agent_info: AgentInfo = info.clone().into();
        assert_eq!(agent_info.instance_id(), "shell_123");
        assert_eq!(agent_info.shell_id(), "shell_123");

        let back_to_shell_info: ShellInfo = agent_info.clone().into();
        assert_eq!(back_to_shell_info, info);

        let back_to_shell: Shell = agent_info.into();
        assert_eq!(back_to_shell, shell);
    }

    #[test]
    fn ctl_msg_and_reply_shell_id_accessors() {
        let msg = CtlMsg::Input {
            instance: "sh_abc".into(),
            data: b"ls\n".to_vec(),
        };
        assert_eq!(msg.shell_id(), Some("sh_abc"));
        assert_eq!(msg.instance_id(), Some("sh_abc"));

        let resize_msg = CtlMsg::Resize {
            instance: "sh_def".into(),
            rows: 30,
            cols: 100,
        };
        assert_eq!(resize_msg.shell_id(), Some("sh_def"));
        assert_eq!(resize_msg.instance_id(), Some("sh_def"));

        let ping_msg = CtlMsg::Ping;
        assert_eq!(ping_msg.shell_id(), None);

        let reply = CtlReply::Spawned {
            instance: "sh_1".into(),
            pid: 999,
        };
        assert_eq!(reply.shell_id(), Some("sh_1"));
        assert_eq!(reply.instance_id(), Some("sh_1"));

        let err_reply = CtlReply::Error {
            instance: "sh_err".into(),
            message: "failed".into(),
        };
        assert_eq!(err_reply.shell_id(), Some("sh_err"));
        assert_eq!(err_reply.instance_id(), Some("sh_err"));

        let ready_reply = CtlReply::StreamReady { instance: "sh_ready".into() };
        assert_eq!(ready_reply.shell_id(), Some("sh_ready"));
        assert_eq!(ready_reply.instance_id(), Some("sh_ready"));

        let closed_reply = CtlReply::StreamClosed { instance: "sh_closed".into(), code: Some(1) };
        assert_eq!(closed_reply.shell_id(), Some("sh_closed"));
        assert_eq!(closed_reply.instance_id(), Some("sh_closed"));
    }
}
