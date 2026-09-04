//! REQ HOST-1: Per-machine multi-agent PTY daemon.
//!
//! Generalizes the single-pane [`crate::server::HostServer`] into a daemon that
//! manages **N agents keyed by agent-instance-id**. Each agent is an independent
//! [`PtyHost`] (own PTY, child, VT model). The daemon exposes:
//!
//!   * a **control plane** — `spawn` / `close` / `restart` / `list`, and
//!   * a **data plane** — per-instance `attach` / `input` / `key` / `resize` /
//!     `capture`, plus `ChildExited` events.
//!
//! The daemon remembers each agent's [`SpawnRequest`] so `restart` re-spawns the
//! exact same command (argv/cwd/env/detect) under the same instance id without
//! the caller re-plumbing anything.
//!
//! This module is transport-agnostic: [`Daemon`] is a plain in-process API
//! (directly unit-tested), and [`serve`] wraps it on a unix socket speaking
//! [`crate::dproto`]. HOST-2 hangs the per-agent startup detector off the pump
//! thread; HOST-3/4 attach TUIs are just [`crate::dproto`] clients.

use std::collections::{HashMap, HashSet};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};

use crate::dproto::{self, AgentInfo, CtlMsg, CtlReply, SpawnRequest};
use crate::host::{PtyHost, SpawnConfig};
use crate::proto::ScreenSnapshot;

/// How long `close`/`restart` wait for a graceful SIGTERM exit before SIGKILL.
const TERM_GRACE: Duration = Duration::from_millis(750);

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// One registered agent: its PTY host + the spec we remember for restart.
struct Agent {
    spec: SpawnRequest,
    host: Arc<Mutex<PtyHost>>,
    alive: Arc<AtomicBool>,
    pid: i32,
    started_at: u64,
    last_activity: Arc<AtomicU64>,
    /// Set on close/restart so this agent's background threads stop.
    stop: Arc<AtomicBool>,
    pump: Option<JoinHandle<()>>,
    exit_watch: Option<JoinHandle<()>>,
}

impl Agent {
    fn info(&self) -> AgentInfo {
        let alive = self.alive.load(Ordering::SeqCst);
        let exit_code = if alive {
            None
        } else {
            self.host.lock().unwrap().exit_code()
        };
        let (rows, cols) = self.host.lock().unwrap().size();
        AgentInfo {
            instance_id: self.spec.instance.clone(),
            program: self.spec.argv.first().cloned().unwrap_or_default(),
            pid: self.pid,
            alive,
            exit_code,
            rows,
            cols,
            started_at: self.started_at,
            last_activity: self.last_activity.load(Ordering::SeqCst),
        }
    }

    /// Stop the child (SIGTERM -> grace -> SIGKILL) and join background threads.
    fn shutdown(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if self.alive.load(Ordering::SeqCst) {
            self.host.lock().unwrap().terminate();
            let dead = self
                .host
                .lock()
                .unwrap()
                .wait_timeout(TERM_GRACE)
                .is_some();
            if !dead {
                self.host.lock().unwrap().kill();
            }
        }
        if let Some(t) = self.pump.take() {
            let _ = t.join();
        }
        if let Some(t) = self.exit_watch.take() {
            let _ = t.join();
        }
    }
}

/// A connected client's event sink + the set of instances it has attached to.
struct Subscriber {
    tx: Sender<CtlReply>,
    instances: HashSet<String>,
}

type Registry = Arc<Mutex<HashMap<String, Agent>>>;
type Subscribers = Arc<Mutex<HashMap<u64, Subscriber>>>;

/// The per-machine multi-agent daemon.
#[derive(Clone)]
pub struct Daemon {
    agents: Registry,
    subs: Subscribers,
}

impl Default for Daemon {
    fn default() -> Self {
        Self::new()
    }
}

impl Daemon {
    pub fn new() -> Self {
        Daemon {
            agents: Arc::new(Mutex::new(HashMap::new())),
            subs: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Number of currently-registered agents.
    pub fn agent_count(&self) -> usize {
        self.agents.lock().unwrap().len()
    }

    /// Register + launch a new agent. Errors if `instance` is empty, `argv` is
    /// empty, or the instance id is already registered.
    pub fn spawn(&self, spec: SpawnRequest) -> Result<i32> {
        if spec.instance.is_empty() {
            return Err(anyhow!("spawn: empty instance id"));
        }
        if spec.argv.is_empty() {
            return Err(anyhow!("spawn: empty argv"));
        }
        {
            let agents = self.agents.lock().unwrap();
            if agents.contains_key(&spec.instance) {
                return Err(anyhow!("spawn: instance {} already exists", spec.instance));
            }
        }
        let agent = self.build_agent(spec)?;
        let pid = agent.pid;
        let instance = agent.spec.instance.clone();
        self.agents.lock().unwrap().insert(instance, agent);
        Ok(pid)
    }

    /// Build + start an [`Agent`] (PTY spawn + pump + exit watcher) from a spec.
    fn build_agent(&self, spec: SpawnRequest) -> Result<Agent> {
        let rows = if spec.rows == 0 { 24 } else { spec.rows };
        let cols = if spec.cols == 0 { 80 } else { spec.cols };
        let program = spec.argv[0].clone();
        let args = spec.argv[1..].to_vec();
        let config = SpawnConfig {
            program,
            args,
            rows,
            cols,
            login_shell: true,
            cwd: spec.cwd.clone(),
            extra_env: spec.env.clone(),
        };
        let mut host = PtyHost::spawn(config)
            .with_context(|| format!("spawn agent {}", spec.instance))?;
        let pid = host.pid();
        let alive = host.alive_flag();
        let output_rx = host.take_output_rx().expect("fresh host has output rx");
        let last_activity = Arc::new(AtomicU64::new(now_secs()));
        let stop = Arc::new(AtomicBool::new(false));
        let host = Arc::new(Mutex::new(host));

        let instance = spec.instance.clone();

        // Pump thread: fan raw output out to subscribers of this instance and
        // stamp last-activity. Ends when the PTY closes (child exit) — the
        // reader thread drops the sender so `recv` returns Err.
        let pump = {
            let subs = Arc::clone(&self.subs);
            let last_activity = Arc::clone(&last_activity);
            let instance = instance.clone();
            std::thread::spawn(move || {
                pump_output(output_rx, subs, instance, last_activity);
            })
        };

        // Exit watcher: when the child dies, broadcast ChildExited to every
        // connected client (dashboards want all exits, not just attachers).
        let exit_watch = {
            let subs = Arc::clone(&self.subs);
            let alive = Arc::clone(&alive);
            let stop = Arc::clone(&stop);
            let host = Arc::clone(&host);
            let instance = instance.clone();
            std::thread::spawn(move || {
                while alive.load(Ordering::SeqCst) {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(30));
                }
                // Suppress the event if we're tearing this agent down (close/
                // restart already accounts for the lifecycle).
                if stop.load(Ordering::SeqCst) {
                    return;
                }
                let code = host.lock().unwrap().exit_code().unwrap_or(-1);
                broadcast_all(
                    &subs,
                    &CtlReply::ChildExited {
                        instance: instance.clone(),
                        code,
                    },
                );
            })
        };

        Ok(Agent {
            spec,
            host,
            alive,
            pid,
            started_at: now_secs(),
            last_activity,
            stop,
            pump: Some(pump),
            exit_watch: Some(exit_watch),
        })
    }

    /// SIGTERM -> wait -> SIGKILL the instance, then unregister it.
    pub fn close(&self, instance: &str) -> Result<()> {
        let mut agent = self
            .agents
            .lock()
            .unwrap()
            .remove(instance)
            .ok_or_else(|| anyhow!("close: no such instance {instance}"))?;
        agent.shutdown();
        Ok(())
    }

    /// Re-spawn `instance` from its remembered spec under the same id. The child
    /// is torn down first; background threads are re-plumbed automatically.
    /// Returns the new child pid.
    pub fn restart(&self, instance: &str) -> Result<i32> {
        // Take the existing agent out, remember its spec, tear it down.
        let mut old = self
            .agents
            .lock()
            .unwrap()
            .remove(instance)
            .ok_or_else(|| anyhow!("restart: no such instance {instance}"))?;
        let spec = old.spec.clone();
        old.shutdown();

        // Re-spawn the same spec + re-register under the same id.
        let agent = self.build_agent(spec)?;
        let pid = agent.pid;
        self.agents
            .lock()
            .unwrap()
            .insert(instance.to_string(), agent);
        Ok(pid)
    }

    /// Enumerate all registered agents (order unspecified).
    pub fn list(&self) -> Vec<AgentInfo> {
        self.agents
            .lock()
            .unwrap()
            .values()
            .map(|a| a.info())
            .collect()
    }

    /// Whether `instance` exists and its child is alive.
    pub fn is_alive(&self, instance: &str) -> bool {
        self.agents
            .lock()
            .unwrap()
            .get(instance)
            .map(|a| a.alive.load(Ordering::SeqCst))
            .unwrap_or(false)
    }

    /// Exit code of `instance` if it exists and has exited.
    pub fn exit_code(&self, instance: &str) -> Option<i32> {
        let agents = self.agents.lock().unwrap();
        let a = agents.get(instance)?;
        if a.alive.load(Ordering::SeqCst) {
            None
        } else {
            a.host.lock().unwrap().exit_code()
        }
    }

    /// Write raw bytes to an instance's stdin.
    pub fn write_input(&self, instance: &str, bytes: &[u8]) -> Result<()> {
        let agents = self.agents.lock().unwrap();
        let a = agents
            .get(instance)
            .ok_or_else(|| anyhow!("input: no such instance {instance}"))?;
        let res = a.host.lock().unwrap().write_input(bytes);
        res
    }

    /// Resize an instance's PTY + VT model.
    pub fn resize(&self, instance: &str, rows: u16, cols: u16) -> Result<()> {
        let agents = self.agents.lock().unwrap();
        let a = agents
            .get(instance)
            .ok_or_else(|| anyhow!("resize: no such instance {instance}"))?;
        let res = a.host.lock().unwrap().resize(rows, cols);
        res
    }

    /// Snapshot an instance's current screen.
    pub fn capture(&self, instance: &str) -> Option<ScreenSnapshot> {
        let agents = self.agents.lock().unwrap();
        let a = agents.get(instance)?;
        let cap = a.host.lock().unwrap().capture();
        Some(ScreenSnapshot {
            rows: cap.rows as u16,
            cols: cap.cols as u16,
            cursor_row: cap.cursor_row as u16,
            cursor_col: cap.cursor_col as u16,
            lines: cap.lines,
        })
    }

    // ---- subscription plumbing (used by the socket server) --------------

    /// Register a client's event sink. Returns nothing; use [`Daemon::attach`]
    /// to start receiving a given instance's output.
    fn subscribe(&self, id: u64, tx: Sender<CtlReply>) {
        self.subs.lock().unwrap().insert(
            id,
            Subscriber {
                tx,
                instances: HashSet::new(),
            },
        );
    }

    fn unsubscribe(&self, id: u64) {
        self.subs.lock().unwrap().remove(&id);
    }

    /// Attach client `id` to `instance`'s output stream. Returns the current
    /// screen so the client renders live state immediately. Does not affect the
    /// child. Errors if the instance does not exist.
    fn attach(&self, id: u64, instance: &str) -> Result<ScreenSnapshot> {
        let snap = self
            .capture(instance)
            .ok_or_else(|| anyhow!("attach: no such instance {instance}"))?;
        if let Some(sub) = self.subs.lock().unwrap().get_mut(&id) {
            sub.instances.insert(instance.to_string());
        }
        Ok(snap)
    }

    fn detach(&self, id: u64, instance: &str) {
        if let Some(sub) = self.subs.lock().unwrap().get_mut(&id) {
            sub.instances.remove(instance);
        }
    }

    /// Stop all agents + drop all subscribers. Idempotent.
    pub fn shutdown(&self) {
        let ids: Vec<String> = self.agents.lock().unwrap().keys().cloned().collect();
        for id in ids {
            let _ = self.close(&id);
        }
        self.subs.lock().unwrap().clear();
    }
}

/// Pump one agent's raw PTY output to its subscribers + stamp activity.
fn pump_output(
    output_rx: Receiver<Vec<u8>>,
    subs: Subscribers,
    instance: String,
    last_activity: Arc<AtomicU64>,
) {
    while let Ok(chunk) = output_rx.recv() {
        last_activity.store(now_secs(), Ordering::SeqCst);
        let map = subs.lock().unwrap();
        for sub in map.values() {
            if sub.instances.contains(&instance) {
                let _ = sub.tx.send(CtlReply::Output {
                    instance: instance.clone(),
                    data: chunk.clone(),
                });
            }
        }
    }
}

/// Broadcast a reply to every connected client (regardless of attachment).
fn broadcast_all(subs: &Subscribers, reply: &CtlReply) {
    let map = subs.lock().unwrap();
    for sub in map.values() {
        let _ = sub.tx.send(reply.clone());
    }
}

// ---- socket server ------------------------------------------------------

/// A running daemon bound to a unix socket, speaking [`crate::dproto`].
pub struct DaemonServer {
    socket_path: std::path::PathBuf,
    daemon: Daemon,
    shutdown: Arc<AtomicBool>,
    accept: Option<JoinHandle<()>>,
}

impl DaemonServer {
    /// Bind `socket_path` and start accepting control/data clients. The daemon
    /// starts with no agents; clients drive it via `Spawn`.
    pub fn start(socket_path: impl Into<std::path::PathBuf>) -> Result<Self> {
        let socket_path = socket_path.into();
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path)
            .with_context(|| format!("bind {socket_path:?}"))?;
        let daemon = Daemon::new();
        let shutdown = Arc::new(AtomicBool::new(false));

        let accept = {
            let daemon = daemon.clone();
            let shutdown = Arc::clone(&shutdown);
            std::thread::spawn(move || accept_loop(listener, daemon, shutdown))
        };

        Ok(DaemonServer {
            socket_path,
            daemon,
            shutdown,
            accept: Some(accept),
        })
    }

    pub fn socket_path(&self) -> &std::path::Path {
        &self.socket_path
    }

    /// Handle to the underlying daemon (for tests / diagnostics).
    pub fn daemon(&self) -> &Daemon {
        &self.daemon
    }

    /// Signal shutdown: stop all agents, unblock the accept loop, join it.
    pub fn shutdown(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        self.daemon.shutdown();
        let _ = UnixStream::connect(&self.socket_path);
        if let Some(t) = self.accept.take() {
            let _ = t.join();
        }
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

impl Drop for DaemonServer {
    fn drop(&mut self) {
        if !self.shutdown.load(Ordering::SeqCst) {
            self.shutdown.store(true, Ordering::SeqCst);
            self.daemon.shutdown();
            let _ = std::fs::remove_file(&self.socket_path);
        }
    }
}

static NEXT_CLIENT_ID: AtomicU64 = AtomicU64::new(1);

fn accept_loop(listener: UnixListener, daemon: Daemon, shutdown: Arc<AtomicBool>) {
    for stream in listener.incoming() {
        if shutdown.load(Ordering::SeqCst) {
            break;
        }
        let stream = match stream {
            Ok(s) => s,
            Err(_) => continue,
        };
        let id = NEXT_CLIENT_ID.fetch_add(1, Ordering::SeqCst);
        handle_client(id, stream, daemon.clone(), Arc::clone(&shutdown));
    }
}

fn handle_client(id: u64, stream: UnixStream, daemon: Daemon, shutdown: Arc<AtomicBool>) {
    let (tx, rx) = std::sync::mpsc::channel::<CtlReply>();
    daemon.subscribe(id, tx.clone());

    let mut write_stream = match stream.try_clone() {
        Ok(s) => s,
        Err(_) => {
            daemon.unsubscribe(id);
            return;
        }
    };
    let mut read_stream = stream;

    // Writer thread: drain this client's reply queue to the socket.
    std::thread::spawn(move || {
        while let Ok(reply) = rx.recv() {
            if dproto::write_ctl_reply(&mut write_stream, &reply).is_err() {
                break;
            }
        }
    });

    // Reader thread: decode control/data messages + act on them.
    std::thread::spawn(move || {
        loop {
            match dproto::read_ctl_msg(&mut read_stream) {
                Ok(Some(msg)) => handle_ctl(&daemon, id, msg, &tx),
                Ok(None) | Err(_) => break,
            }
            if shutdown.load(Ordering::SeqCst) {
                break;
            }
        }
        daemon.unsubscribe(id);
    });
}

fn handle_ctl(daemon: &Daemon, id: u64, msg: CtlMsg, tx: &Sender<CtlReply>) {
    match msg {
        CtlMsg::Spawn(req) => {
            let instance = req.instance.clone();
            match daemon.spawn(req) {
                Ok(pid) => {
                    let _ = tx.send(CtlReply::Spawned { instance, pid });
                }
                Err(e) => {
                    let _ = tx.send(CtlReply::Error {
                        instance,
                        message: e.to_string(),
                    });
                }
            }
        }
        CtlMsg::Close { instance } => match daemon.close(&instance) {
            Ok(()) => {
                let _ = tx.send(CtlReply::Closed { instance });
            }
            Err(e) => {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: e.to_string(),
                });
            }
        },
        CtlMsg::Restart { instance } => match daemon.restart(&instance) {
            Ok(pid) => {
                let _ = tx.send(CtlReply::Restarted { instance, pid });
            }
            Err(e) => {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: e.to_string(),
                });
            }
        },
        CtlMsg::List => {
            let _ = tx.send(CtlReply::AgentList(daemon.list()));
        }
        CtlMsg::Attach { instance } => match daemon.attach(id, &instance) {
            Ok(screen) => {
                let _ = tx.send(CtlReply::Screen { instance, screen });
            }
            Err(e) => {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: e.to_string(),
                });
            }
        },
        CtlMsg::Input { instance, data } => {
            if let Err(e) = daemon.write_input(&instance, &data) {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: e.to_string(),
                });
            }
        }
        CtlMsg::Key { instance, key } => {
            if let Err(e) = daemon.write_input(&instance, key.to_bytes()) {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: e.to_string(),
                });
            }
        }
        CtlMsg::Resize { instance, rows, cols } => {
            if let Err(e) = daemon.resize(&instance, rows, cols) {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: e.to_string(),
                });
            }
        }
        CtlMsg::Capture { instance } => match daemon.capture(&instance) {
            Some(screen) => {
                let _ = tx.send(CtlReply::Screen { instance, screen });
            }
            None => {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: "capture: no such instance".into(),
                });
            }
        },
        CtlMsg::Detach { instance } => daemon.detach(id, &instance),
        CtlMsg::Ping => {
            let _ = tx.send(CtlReply::Pong);
        }
    }
}

/// Bind + run a daemon on `socket_path` until the child of the process is
/// signalled. Convenience entrypoint used by `main`. Blocks forever (until
/// Ctrl-C), serving clients.
pub fn serve(socket_path: impl Into<std::path::PathBuf>) -> Result<()> {
    let mut server = DaemonServer::start(socket_path)?;
    eprintln!(
        "[ham-pty-host] daemon listening on {}",
        server.socket_path().display()
    );
    // Install a SIGINT/SIGTERM handler that flips a flag; park until then.
    install_stop_handler();
    while !STOP_REQUESTED.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(200));
    }
    server.shutdown();
    Ok(())
}

static STOP_REQUESTED: AtomicBool = AtomicBool::new(false);

extern "C" fn stop_handler(_sig: i32) {
    STOP_REQUESTED.store(true, Ordering::SeqCst);
}

fn install_stop_handler() {
    unsafe {
        libc::signal(libc::SIGINT, stop_handler as *const () as usize);
        libc::signal(libc::SIGTERM, stop_handler as *const () as usize);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::tests::{pty_available, resolve, shell};

    macro_rules! require_pty {
        () => {{
            if !pty_available() {
                eprintln!("[skip] no PTY available in this environment");
                return;
            }
        }};
    }

    fn wait_for<F: Fn() -> bool>(pred: F, timeout: Duration) -> bool {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            if pred() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        pred()
    }

    fn sh_spec(instance: &str, sh: &str) -> SpawnRequest {
        SpawnRequest {
            instance: instance.into(),
            argv: vec![sh.into()],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 20,
            cols: 60,
        }
    }

    fn find(list: &[AgentInfo], instance: &str) -> Option<AgentInfo> {
        list.iter().find(|a| a.instance_id == instance).cloned()
    }

    fn capture_contains(d: &Daemon, instance: &str, needle: &str, timeout: Duration) -> bool {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            if let Some(s) = d.capture(instance) {
                if s.lines.iter().any(|l| l.contains(needle)) {
                    return true;
                }
            }
            std::thread::sleep(Duration::from_millis(30));
        }
        false
    }

    #[test]
    fn spawn_two_agents_drive_each_independently() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => {
                eprintln!("[skip] no shell");
                return;
            }
        };
        let d = Daemon::new();
        d.spawn(sh_spec("a", &sh)).unwrap();
        d.spawn(sh_spec("b", &sh)).unwrap();
        assert_eq!(d.agent_count(), 2);
        std::thread::sleep(Duration::from_millis(300));

        d.write_input("a", b"echo AAA111\n").unwrap();
        d.write_input("b", b"echo BBB222\n").unwrap();

        assert!(capture_contains(&d, "a", "AAA111", Duration::from_secs(3)));
        assert!(capture_contains(&d, "b", "BBB222", Duration::from_secs(3)));
        // Cross-check isolation: a's screen must not contain b's marker.
        let a = d.capture("a").unwrap();
        assert!(!a.lines.iter().any(|l| l.contains("BBB222")));

        d.shutdown();
    }

    #[test]
    fn close_one_leaves_the_other() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        d.spawn(sh_spec("keep", &sh)).unwrap();
        d.spawn(sh_spec("drop", &sh)).unwrap();
        std::thread::sleep(Duration::from_millis(200));

        d.close("drop").unwrap();
        assert_eq!(d.agent_count(), 1);
        assert!(find(&d.list(), "drop").is_none());
        // Survivor still drivable.
        assert!(d.is_alive("keep"));
        d.write_input("keep", b"echo STILL_HERE\n").unwrap();
        assert!(capture_contains(&d, "keep", "STILL_HERE", Duration::from_secs(3)));

        d.shutdown();
    }

    #[test]
    fn restart_reuses_spec_and_same_id() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        let mut spec = sh_spec("r", &sh);
        spec.env = vec![("MARKER_ENV".into(), "xyzzy".into())];
        d.spawn(spec).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        let pid1 = find(&d.list(), "r").unwrap().pid;

        let pid2 = d.restart("r").unwrap();
        // Same id still registered, new child pid.
        assert_eq!(d.agent_count(), 1);
        assert!(find(&d.list(), "r").is_some());
        assert_ne!(pid1, pid2, "restart should spawn a new child");
        std::thread::sleep(Duration::from_millis(300));

        // The remembered env spec must survive the restart.
        d.write_input("r", b"echo $MARKER_ENV\n").unwrap();
        assert!(capture_contains(&d, "r", "xyzzy", Duration::from_secs(3)));

        d.shutdown();
    }

    #[test]
    fn list_reflects_state_including_exit() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        d.spawn(sh_spec("live", &sh)).unwrap();
        // A short-lived agent that exits on its own.
        let tru = resolve("true").or_else(|| resolve("/usr/bin/true"));
        if let Some(tru) = tru {
            d.spawn(SpawnRequest {
                instance: "dead".into(),
                argv: vec![tru],
                cwd: None,
                env: vec![],
                detect: None,
                rows: 10,
                cols: 40,
            })
            .unwrap();
        }
        std::thread::sleep(Duration::from_millis(300));

        let live = find(&d.list(), "live").unwrap();
        assert!(live.alive);
        assert!(live.pid > 0);
        assert_eq!(live.exit_code, None);
        assert_eq!(live.program, sh);

        if find(&d.list(), "dead").is_some() {
            assert!(
                wait_for(|| !d.is_alive("dead"), Duration::from_secs(3)),
                "short-lived agent never exited"
            );
            let dead = find(&d.list(), "dead").unwrap();
            assert!(!dead.alive);
            assert_eq!(dead.exit_code, Some(0));
        }

        d.shutdown();
    }

    #[test]
    fn spawn_rejects_duplicate_and_empty() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        d.spawn(sh_spec("dup", &sh)).unwrap();
        assert!(d.spawn(sh_spec("dup", &sh)).is_err(), "duplicate id allowed");
        assert!(
            d.spawn(sh_spec("", &sh)).is_err(),
            "empty instance id allowed"
        );
        let mut noargv = sh_spec("noargv", &sh);
        noargv.argv.clear();
        assert!(d.spawn(noargv).is_err(), "empty argv allowed");
        d.shutdown();
    }

    #[test]
    fn control_ops_on_missing_instance_error() {
        let d = Daemon::new();
        assert!(d.close("nope").is_err());
        assert!(d.restart("nope").is_err());
        assert!(d.write_input("nope", b"x").is_err());
        assert!(d.capture("nope").is_none());
        assert!(!d.is_alive("nope"));
        assert!(d.list().is_empty());
    }

    // ---- socket-level (dproto) end-to-end -------------------------------

    fn tmp_socket(name: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "ham-daemon-{}-{}-{}.sock",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        p
    }

    /// Read frames until a reply matching `pred` (skipping others), or timeout.
    fn await_reply(
        stream: &mut UnixStream,
        pred: impl Fn(&CtlReply) -> bool,
        timeout: Duration,
    ) -> Option<CtlReply> {
        stream
            .set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            match dproto::read_ctl_reply(stream) {
                Ok(Some(r)) => {
                    if pred(&r) {
                        return Some(r);
                    }
                }
                Ok(None) => return None,
                Err(ref e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => return None,
            }
        }
        None
    }

    #[test]
    fn socket_spawn_list_close_over_dproto() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("e2e");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        let mut c = UnixStream::connect(&sock).unwrap();
        // Spawn two agents.
        for inst in ["one", "two"] {
            dproto::write_ctl_msg(
                &mut c,
                &CtlMsg::Spawn(SpawnRequest {
                    instance: inst.into(),
                    argv: vec![sh.clone()],
                    cwd: None,
                    env: vec![],
                    detect: None,
                    rows: 20,
                    cols: 60,
                }),
            )
            .unwrap();
            let got = await_reply(
                &mut c,
                |r| matches!(r, CtlReply::Spawned { instance, .. } if instance == inst),
                Duration::from_secs(3),
            );
            assert!(got.is_some(), "no Spawned ack for {inst}");
        }
        assert_eq!(server.daemon().agent_count(), 2);

        // List shows both.
        dproto::write_ctl_msg(&mut c, &CtlMsg::List).unwrap();
        let list = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::AgentList(_)),
            Duration::from_secs(3),
        );
        match list {
            Some(CtlReply::AgentList(agents)) => assert_eq!(agents.len(), 2),
            _ => panic!("no AgentList reply"),
        }

        // Attach + drive "one"; capture reflects it.
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "one".into() }).unwrap();
        dproto::write_ctl_msg(
            &mut c,
            &CtlMsg::Input {
                instance: "one".into(),
                data: b"echo SOCK_OK\n".to_vec(),
            },
        )
        .unwrap();
        std::thread::sleep(Duration::from_millis(400));
        dproto::write_ctl_msg(&mut c, &CtlMsg::Capture { instance: "one".into() }).unwrap();
        let cap = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::Screen { screen, .. } if screen.lines.iter().any(|l| l.contains("SOCK_OK"))),
            Duration::from_secs(3),
        );
        assert!(cap.is_some(), "capture never showed SOCK_OK");

        // Close "one" leaves "two".
        dproto::write_ctl_msg(&mut c, &CtlMsg::Close { instance: "one".into() }).unwrap();
        let closed = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::Closed { instance } if instance == "one"),
            Duration::from_secs(3),
        );
        assert!(closed.is_some(), "no Closed ack");
        assert!(
            wait_for(|| server.daemon().agent_count() == 1, Duration::from_secs(2)),
            "close did not unregister"
        );
        assert!(server.daemon().is_alive("two"));

        server.shutdown();
    }

    #[test]
    fn socket_spawn_duplicate_returns_error_reply() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("dup");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let mut c = UnixStream::connect(&sock).unwrap();
        let spec = CtlMsg::Spawn(SpawnRequest {
            instance: "x".into(),
            argv: vec![sh.clone()],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 20,
            cols: 60,
        });
        dproto::write_ctl_msg(&mut c, &spec).unwrap();
        assert!(await_reply(
            &mut c,
            |r| matches!(r, CtlReply::Spawned { .. }),
            Duration::from_secs(3)
        )
        .is_some());
        dproto::write_ctl_msg(&mut c, &spec).unwrap();
        let err = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::Error { .. }),
            Duration::from_secs(3),
        );
        assert!(matches!(err, Some(CtlReply::Error { .. })), "expected Error reply");
        server.shutdown();
    }
}
