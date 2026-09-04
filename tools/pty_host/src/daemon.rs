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
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};

use crate::detect::{screen_hash, DetectAction, Detector, StartupDetectionConfig, StartupOutcome};
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
    /// HOST-2: per-agent startup detector + activity-signal thread (only present
    /// when the spec carried a `detect` config).
    detector: Option<JoinHandle<()>>,
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
            display_name: self.spec.display_name.clone(),
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
        if let Some(t) = self.detector.take() {
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

/// A registered connection's event sink, before/independent of any Attach.
type Sinks = Arc<Mutex<HashMap<u64, Sender<CtlReply>>>>;

/// The per-machine multi-agent daemon.
#[derive(Clone)]
pub struct Daemon {
    agents: Registry,
    /// Clients that have Attached and are receiving instance-scoped events.
    subs: Subscribers,
    /// All connected clients' sinks (HOST-5): a sink here is NOT subscribed to
    /// any events until the client Attaches; control-only clients live here
    /// only, so they never receive async event frames.
    sinks: Sinks,
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
            sinks: Arc::new(Mutex::new(HashMap::new())),
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
            // The daemon manages explicit agent commands (e.g. `claude`, a
            // wrapper, a shell the caller chose) — NOT login shells. Forcing a
            // login shell (`-l`) is both semantically wrong here and
            // environment-sensitive: a login `sh` re-sources /etc/profile +
            // ~/.profile, which on some machines mutates the injected env,
            // prints banners, or redraws the screen. That made an env-var
            // assertion pass on one machine and fail on another. The caller
            // controls login behavior explicitly via argv (e.g. `-- /bin/zsh -l`).
            login_shell: false,
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

        // HOST-2: per-agent startup detector + activity (ScreenChanged) signal.
        // Only spun up when the spec carried a detect config. It ticks every
        // capture_interval_ms, captures the VT text, dispatches auto-enter keys
        // to the child, and broadcasts StartupReady/StartupBlocked + a
        // ScreenChanged dirty signal on content change. It stops on
        // stop/child-exit and is re-plumbed on restart (build_agent runs again).
        let detector = {
            let cfg = StartupDetectionConfig::from_json(spec.detect.as_deref().unwrap_or(""));
            // Always run the loop (even when disabled/absent) so we still emit
            // the ScreenChanged activity signal; the Detector short-circuits
            // startup to Ready immediately when disabled.
            let subs = Arc::clone(&self.subs);
            let alive = Arc::clone(&alive);
            let stop = Arc::clone(&stop);
            let host = Arc::clone(&host);
            let instance = instance.clone();
            Some(std::thread::spawn(move || {
                run_detector(cfg, host, subs, instance, alive, stop);
            }))
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
            detector,
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
    //
    // HOST-5: a connection is NOT auto-subscribed. Control-only clients
    // (spawn/close/restart/list) never enter the `subs` map, so async events
    // (Output/ScreenChanged/StartupReady/StartupBlocked/ChildExited) — which
    // are delivered ONLY through `subs` — can never be interleaved with a
    // control reply. A subscription is created lazily on the first `Attach` and
    // torn down when the client detaches from its last instance (or drops).

    /// Remember a client's event sink so it can be (re)subscribed on Attach.
    /// Idempotent; does NOT by itself cause any events to be delivered.
    fn register_sink(&self, id: u64, tx: Sender<CtlReply>) {
        self.sinks.lock().unwrap().insert(id, tx);
    }

    /// Drop a client entirely: its sink and any active subscription.
    fn unsubscribe(&self, id: u64) {
        self.subs.lock().unwrap().remove(&id);
        self.sinks.lock().unwrap().remove(&id);
    }

    /// Attach client `id` to `instance`'s output stream. Creates the client's
    /// subscription on first attach. Returns the current screen so the client
    /// renders live state immediately. Does not affect the child. Errors if the
    /// instance does not exist.
    fn attach(&self, id: u64, instance: &str) -> Result<ScreenSnapshot> {
        let snap = self
            .capture(instance)
            .ok_or_else(|| anyhow!("attach: no such instance {instance}"))?;
        // Look up the sink before locking subs to avoid a lock-ordering hazard.
        let tx = self
            .sinks
            .lock()
            .unwrap()
            .get(&id)
            .cloned()
            .ok_or_else(|| anyhow!("attach: connection {id} has no registered sink"))?;
        let mut subs = self.subs.lock().unwrap();
        let sub = subs.entry(id).or_insert_with(|| Subscriber {
            tx,
            instances: HashSet::new(),
        });
        sub.instances.insert(instance.to_string());
        Ok(snap)
    }

    /// Detach client `id` from `instance`. When it has no instances left the
    /// whole subscription is removed so it stops receiving ALL events (returns
    /// to control-only status).
    fn detach(&self, id: u64, instance: &str) {
        let mut subs = self.subs.lock().unwrap();
        if let Some(sub) = subs.get_mut(&id) {
            sub.instances.remove(instance);
            if sub.instances.is_empty() {
                subs.remove(&id);
            }
        }
    }

    /// Stop all agents + drop all subscribers. Idempotent.
    pub fn shutdown(&self) {
        let ids: Vec<String> = self.agents.lock().unwrap().keys().cloned().collect();
        for id in ids {
            let _ = self.close(&id);
        }
        self.subs.lock().unwrap().clear();
        self.sinks.lock().unwrap().clear();
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

/// HOST-2: per-agent startup-detection + activity loop. Runs on its own thread
/// for the life of one child. Ticks every `capture_interval_ms`:
///   1. captures the rendered screen text,
///   2. emits `ScreenChanged{hash}` when the content hash changes (activity
///      signal; spinner masking is bridge-side),
///   3. feeds the text to the [`Detector`]; performs `SendKeys` against the
///      child and broadcasts `StartupReady`/`StartupBlocked` on `Finished`.
/// After the detector finishes it keeps emitting the activity signal until the
/// child exits or the agent is stopped.
fn run_detector(
    cfg: StartupDetectionConfig,
    host: Arc<Mutex<PtyHost>>,
    subs: Subscribers,
    instance: String,
    alive: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
) {
    let interval = Duration::from_millis(cfg.interval_ms().max(1) as u64);
    // Only surface startup events when detection is actually enabled. When it is
    // absent/disabled we still run the loop for the ScreenChanged activity
    // signal (the bridge wants activity for every agent) but stay silent on
    // startup so a no-detect agent doesn't emit a spurious StartupReady.
    let emit_startup = cfg.enabled;
    let start = Instant::now();
    let mut detector = Detector::new(cfg, 0);
    let mut last_hash: Option<u64> = None;

    loop {
        if stop.load(Ordering::SeqCst) || !alive.load(Ordering::SeqCst) {
            return;
        }

        // Render the current screen to a single text blob for matching/hashing.
        let text = {
            let cap = host.lock().unwrap().capture();
            cap.lines.join("\n")
        };

        // Activity (ScreenChanged) dirty signal on content change.
        let h = screen_hash(&text);
        if last_hash != Some(h) {
            last_hash = Some(h);
            broadcast_all(
                &subs,
                &CtlReply::ScreenChanged {
                    instance: instance.clone(),
                    hash: h,
                },
            );
        }

        // Drive the startup detector (no-op once finished).
        if !detector.is_done() {
            let now_ms = start.elapsed().as_millis() as i64;
            for action in detector.step(&text, now_ms) {
                match action {
                    DetectAction::SendKeys(keys) => {
                        let h = host.lock().unwrap();
                        for k in keys {
                            let _ = h.write_input(k.to_bytes());
                        }
                    }
                    DetectAction::Finished(outcome) => {
                        if emit_startup {
                            let reply = match outcome {
                                StartupOutcome::Ready => CtlReply::StartupReady {
                                    instance: instance.clone(),
                                },
                                StartupOutcome::Blocked {
                                    reason_code,
                                    safe_diagnostic,
                                } => CtlReply::StartupBlocked {
                                    instance: instance.clone(),
                                    reason_code,
                                    safe_diagnostic,
                                },
                            };
                            broadcast_all(&subs, &reply);
                        }
                    }
                }
            }
        }

        std::thread::sleep(interval);
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
    // HOST-5: register the sink but do NOT subscribe to events. Async events
    // only flow to clients that later Attach; a control-only client stays out
    // of the `subs` map entirely and thus never sees an event frame.
    daemon.register_sink(id, tx.clone());

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
        CtlMsg::Shutdown => {
            // Ack first so the client learns the daemon accepted the request,
            // then flip the stop flag. The `serve` loop observes it and tears
            // down every agent via `server.shutdown()`; the accept loop and
            // this client's socket close right after.
            let _ = tx.send(CtlReply::ShuttingDown);
            STOP_REQUESTED.store(true, Ordering::SeqCst);
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
            display_name: None,
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

    /// Deterministically drive a freshly-spawned shell: RE-SEND `input` on a
    /// retry loop until `needle` shows up in the capture (or timeout). A single
    /// write after a fixed sleep races the child becoming ready to read on a
    /// slow/loaded machine (the shell may still be sourcing rc files, or the
    /// re-spawned PTY reader may not be plumbed yet); re-sending removes that
    /// race without assuming any timing. Sending `echo ...` more than once is
    /// harmless — it just prints again.
    fn drive_until(d: &Daemon, instance: &str, input: &[u8], needle: &str, timeout: Duration) -> bool {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            if d.write_input(instance, input).is_err() {
                return false;
            }
            let deadline = std::time::Instant::now() + Duration::from_millis(250);
            while std::time::Instant::now() < deadline {
                if let Some(s) = d.capture(instance) {
                    if s.lines.iter().any(|l| l.contains(needle)) {
                        return true;
                    }
                }
                std::thread::sleep(Duration::from_millis(25));
            }
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

        // Drive each independently (retry-until-ready, no fixed-sleep race).
        assert!(drive_until(&d, "a", b"echo AAA111\n", "AAA111", Duration::from_secs(5)));
        assert!(drive_until(&d, "b", b"echo BBB222\n", "BBB222", Duration::from_secs(5)));
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
        // Survivor still drivable (retry-until-ready).
        assert!(d.is_alive("keep"));
        assert!(drive_until(&d, "keep", b"echo STILL_HERE\n", "STILL_HERE", Duration::from_secs(5)));

        d.shutdown();
    }

    /// REQ HOST-1 (env plumbing, deterministic): spawn a ONE-SHOT, NON-LOGIN,
    /// non-interactive `sh -c 'echo MARK:$MARKER_ENV'` with extra_env and assert
    /// the captured output shows the value. This removes interactive-shell,
    /// login-shell (`-l` profile sourcing), and input-timing variables entirely
    /// — if this passes, extra_env genuinely reaches the child's environment.
    /// (Requested by review to disambiguate env plumbing from shell init.)
    #[test]
    fn extra_env_reaches_child_oneshot() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        d.spawn(SpawnRequest {
            instance: "envp".into(),
            argv: vec![sh, "-c".into(), "echo MARK:$MARKER_ENV; sleep 2".into()],
            cwd: None,
            env: vec![("MARKER_ENV".into(), "xyzzy".into())],
            detect: None,
            rows: 10,
            cols: 40,
            display_name: None,
        })
        .unwrap();
        assert!(
            capture_contains(&d, "envp", "MARK:xyzzy", Duration::from_secs(5)),
            "extra_env did not reach the child (one-shot non-login sh)"
        );
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
        // DETERMINISTIC design: the agent's argv itself emits the env marker at
        // startup, then blocks. So every (re)spawn from the remembered spec
        // re-prints `BOOT:xyzzy` with NO interactive input, NO login-shell
        // profile sourcing, and NO input-timing race — the only variables the
        // reviewer flagged. This asserts BOTH that restart reuses the exact
        // spec (same argv/cwd/env) AND that extra_env survives the restart.
        let spec = SpawnRequest {
            instance: "r".into(),
            argv: vec![
                sh.clone(),
                "-c".into(),
                // Print marker once at boot, then stay alive (read blocks).
                "echo BOOT:$MARKER_ENV; while :; do sleep 1; done".into(),
            ],
            cwd: None,
            env: vec![("MARKER_ENV".into(), "xyzzy".into())],
            detect: None,
            rows: 20,
            cols: 60,
            display_name: None,
        };
        d.spawn(spec).unwrap();
        // Marker must appear on the ORIGINAL child (env applied on first spawn).
        assert!(
            capture_contains(&d, "r", "BOOT:xyzzy", Duration::from_secs(5)),
            "env not applied on initial spawn"
        );
        let pid1 = find(&d.list(), "r").unwrap().pid;

        let pid2 = d.restart("r").unwrap();
        // Same id still registered, new child pid, still alive.
        assert_eq!(d.agent_count(), 1);
        assert!(find(&d.list(), "r").is_some());
        assert_ne!(pid1, pid2, "restart should spawn a new child");

        // The re-spawned child (from the remembered spec) re-prints the marker.
        // Its fresh VT model starts blank, so seeing BOOT:xyzzy again proves the
        // remembered argv+env were re-applied on restart.
        assert!(
            capture_contains(&d, "r", "BOOT:xyzzy", Duration::from_secs(5)),
            "remembered spec/env did not survive restart"
        );

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
                display_name: None,
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
    fn shutdown_acks_and_flips_stop_flag() {
        // No PTY needed: Shutdown is a pure control-plane op. Reset the process
        // global first so a prior test/run can't leave it set.
        STOP_REQUESTED.store(false, Ordering::SeqCst);
        let sock = tmp_socket("shutdown");
        let server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        let mut c = UnixStream::connect(&sock).unwrap();
        dproto::write_ctl_msg(&mut c, &CtlMsg::Shutdown).unwrap();

        // We get the ShuttingDown ack...
        let ack = await_reply(&mut c, |r| matches!(r, CtlReply::ShuttingDown), Duration::from_secs(2));
        assert!(matches!(ack, Some(CtlReply::ShuttingDown)), "expected ShuttingDown ack, got {ack:?}");
        // ...and the daemon's serve-loop stop flag is now set.
        assert!(STOP_REQUESTED.load(Ordering::SeqCst), "Shutdown must flip STOP_REQUESTED");

        drop(server);
        STOP_REQUESTED.store(false, Ordering::SeqCst);
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
                    display_name: None,
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

        // Attach + drive "one"; capture reflects it. Re-send input + re-request
        // capture on a loop so a slow/loaded machine can't lose the single
        // write before the shell is ready (mirrors drive_until, over the wire).
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "one".into() }).unwrap();
        let mut sock_ok = false;
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(6) {
            dproto::write_ctl_msg(
                &mut c,
                &CtlMsg::Input {
                    instance: "one".into(),
                    data: b"echo SOCK_OK\n".to_vec(),
                },
            )
            .unwrap();
            std::thread::sleep(Duration::from_millis(200));
            dproto::write_ctl_msg(&mut c, &CtlMsg::Capture { instance: "one".into() }).unwrap();
            if await_reply(
                &mut c,
                |r| matches!(r, CtlReply::Screen { screen, .. } if screen.lines.iter().any(|l| l.contains("SOCK_OK"))),
                Duration::from_millis(500),
            )
            .is_some()
            {
                sock_ok = true;
                break;
            }
        }
        assert!(sock_ok, "capture never showed SOCK_OK");

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
            display_name: None,
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

    // ---- HOST-4: single-agent attach isolation (real PTY) ----------------

    /// The single-agent `attach --instance <id>` client (src/dclient.rs) relies
    /// on the daemon delivering ONLY the attached instance's `Output`. Spawn two
    /// agents, attach to just one, drive both, and assert every `Output` frame
    /// we receive is for the attached instance (never the other). Also proves
    /// the child survives `Detach`.
    #[test]
    fn socket_attach_one_instance_isolates_output() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("h4iso");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        // Spawn both agents via the daemon handle (drive_until needs it).
        let d = server.daemon();
        d.spawn(sh_spec("solo", &sh)).unwrap();
        d.spawn(sh_spec("other", &sh)).unwrap();

        // A wire client that attaches to ONLY "solo".
        let mut c = UnixStream::connect(&sock).unwrap();
        c.set_read_timeout(Some(Duration::from_millis(200))).ok();
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "solo".into() }).unwrap();
        // The Attach ack is a Screen for "solo".
        assert!(
            await_reply(
                &mut c,
                |r| matches!(r, CtlReply::Screen { instance, .. } if instance == "solo"),
                Duration::from_secs(3),
            )
            .is_some(),
            "no Screen ack for solo attach"
        );

        // Drive BOTH agents so each produces output.
        assert!(drive_until(d, "solo", b"echo SOLO_OUT\n", "SOLO_OUT", Duration::from_secs(6)));
        assert!(drive_until(d, "other", b"echo OTHER_OUT\n", "OTHER_OUT", Duration::from_secs(6)));

        // Collect Output frames for ~1s; every one must be for "solo", and we
        // must actually see solo's marker stream through.
        let mut saw_solo = false;
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(2) {
            match dproto::read_ctl_reply(&mut c) {
                Ok(Some(CtlReply::Output { instance, data })) => {
                    assert_eq!(instance, "solo", "leaked output from another instance");
                    if String::from_utf8_lossy(&data).contains("SOLO_OUT") {
                        saw_solo = true;
                    }
                }
                Ok(Some(_)) => {} // Screen/ScreenChanged for solo etc. — fine.
                Ok(None) => break,
                Err(ref e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => break,
            }
        }
        assert!(saw_solo, "never received solo's live output while attached");

        // Detach solo; the child must survive.
        dproto::write_ctl_msg(&mut c, &CtlMsg::Detach { instance: "solo".into() }).unwrap();
        assert!(
            wait_for(|| server.daemon().is_alive("solo"), Duration::from_secs(1)),
            "solo child must survive detach"
        );
        assert!(server.daemon().is_alive("other"));

        server.shutdown();
    }

    // ---- HOST-5: control/event stream separation (real PTY) --------------

    /// Read the NEXT control reply on a control-only connection, mirroring the
    /// CLI's `request()`: async event frames (Output/ChildExited/ScreenChanged/
    /// StartupReady/StartupBlocked) must NEVER reach a client that did not
    /// Attach, so encountering one here is a hard failure (the bug this task
    /// fixes). Screen is only produced in reply to Attach/Capture, so it is
    /// also unexpected on a control-only op.
    fn ctl_reply_strict(c: &mut UnixStream, timeout: Duration) -> CtlReply {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            match dproto::read_ctl_reply(c) {
                Ok(Some(
                    ev @ (CtlReply::Output { .. }
                    | CtlReply::ChildExited { .. }
                    | CtlReply::ScreenChanged { .. }
                    | CtlReply::StartupReady { .. }
                    | CtlReply::StartupBlocked { .. }),
                )) => {
                    panic!("control-only connection received async event: {ev:?}");
                }
                Ok(Some(reply)) => return reply,
                Ok(None) => panic!("daemon closed connection without replying"),
                Err(ref e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(e) => panic!("read error: {e}"),
            }
        }
        panic!("timed out waiting for control reply");
    }

    /// ACCEPTANCE (HOST-5): with an agent ACTIVELY producing output, a
    /// control-only client must be able to run list/restart/close repeatedly
    /// with no "unexpected reply" — i.e. it only ever sees its command's reply,
    /// never an async event frame. Before the fix this failed within a couple
    /// iterations because every connection was auto-subscribed and events were
    /// broadcast to all connections.
    #[test]
    fn control_only_client_never_sees_async_events_under_busy_agent() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("h5ctl");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        // A busy agent that spews output continuously (drives ScreenChanged +
        // Output constantly). Runs a tight echo loop like the task's repro.
        let d = server.daemon();
        d.spawn(SpawnRequest {
            instance: "busy".into(),
            argv: vec![
                sh.clone(),
                "-c".into(),
                "i=0; while :; do echo tick $i; i=$((i+1)); done".into(),
            ],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 20,
            cols: 60,
            display_name: None,
        })
        .unwrap();

        // A SECOND agent used as the restart/close target so the busy one keeps
        // streaming throughout (close removes an agent; we want sustained load).
        // We restart/close/re-spawn "victim" each round while "busy" spews.
        let timeout = Duration::from_secs(4);
        for round in 0..8 {
            // Fresh control-only connection each round (like the CLI's one-shot
            // `request()`), plus one long-lived connection tested below.
            let mut c = UnixStream::connect(&sock).unwrap();
            c.set_read_timeout(Some(Duration::from_millis(100))).ok();

            // list
            dproto::write_ctl_msg(&mut c, &CtlMsg::List).unwrap();
            match ctl_reply_strict(&mut c, timeout) {
                CtlReply::AgentList(_) => {}
                other => panic!("round {round}: list got {other:?}"),
            }

            // spawn a victim, then restart it, then close it — all control ops
            // that must return exactly their own reply despite busy's output.
            let vic = format!("victim{round}");
            dproto::write_ctl_msg(
                &mut c,
                &CtlMsg::Spawn(sh_spec(&vic, &sh)),
            )
            .unwrap();
            match ctl_reply_strict(&mut c, timeout) {
                CtlReply::Spawned { instance, .. } if instance == vic => {}
                other => panic!("round {round}: spawn got {other:?}"),
            }

            dproto::write_ctl_msg(&mut c, &CtlMsg::Restart { instance: vic.clone() }).unwrap();
            match ctl_reply_strict(&mut c, timeout) {
                CtlReply::Restarted { instance, .. } if instance == vic => {}
                other => panic!("round {round}: restart got {other:?}"),
            }

            dproto::write_ctl_msg(&mut c, &CtlMsg::Close { instance: vic.clone() }).unwrap();
            match ctl_reply_strict(&mut c, timeout) {
                CtlReply::Closed { instance } if instance == vic => {}
                other => panic!("round {round}: close got {other:?}"),
            }
        }

        // Also prove a SINGLE long-lived control connection stays clean across
        // many ops (the CLI can reuse a socket).
        let mut c = UnixStream::connect(&sock).unwrap();
        c.set_read_timeout(Some(Duration::from_millis(100))).ok();
        for _ in 0..10 {
            dproto::write_ctl_msg(&mut c, &CtlMsg::List).unwrap();
            match ctl_reply_strict(&mut c, timeout) {
                CtlReply::AgentList(_) => {}
                other => panic!("long-lived list got {other:?}"),
            }
        }

        // The busy agent is still alive and was never disturbed.
        assert!(server.daemon().is_alive("busy"));
        server.shutdown();
    }

    // ---- HOST-2: detector integration over the daemon (real PTY) ---------

    /// A blocked pattern in the child's output must produce a StartupBlocked
    /// event carrying the sanitized reason. The agent argv prints the blocked
    /// text itself, so no interactive input or timing is involved.
    #[test]
    fn detector_emits_startup_blocked_on_pattern() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("blocked");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let mut c = UnixStream::connect(&sock).unwrap();

        let detect = r#"{
            "enabled": true,
            "startup_probe_seconds": 10,
            "capture_interval_ms": 100,
            "blocked_patterns": ["LOGIN_REQUIRED_MARK"],
            "sanitized_reason_mapping": ["login=Provider login required"]
        }"#;
        dproto::write_ctl_msg(
            &mut c,
            &CtlMsg::Spawn(SpawnRequest {
                instance: "b".into(),
                argv: vec![
                    sh.clone(),
                    "-c".into(),
                    "echo LOGIN_REQUIRED_MARK; while :; do sleep 1; done".into(),
                ],
                cwd: None,
                env: vec![],
                detect: Some(detect.into()),
                rows: 20,
                cols: 60,
                display_name: None,
            }),
        )
        .unwrap();
        // HOST-5: events flow only to attached clients — opt in.
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "b".into() }).unwrap();

        let ev = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::StartupBlocked { instance, .. } if instance == "b"),
            Duration::from_secs(6),
        );
        match ev {
            Some(CtlReply::StartupBlocked {
                reason_code,
                safe_diagnostic,
                ..
            }) => {
                assert!(reason_code.starts_with("blocked_0"), "reason: {reason_code}");
                assert_eq!(safe_diagnostic, "Provider login required");
            }
            other => panic!("expected StartupBlocked, got {other:?}"),
        }
        server.shutdown();
    }

    /// Auto-enter: when the child prints a pattern, the detector sends the
    /// configured pre-keys+Enter to the child. We prove the keys ARRIVE by
    /// having the shell `read` a line after printing the prompt and echo a
    /// confirmation once it receives the Enter the detector sends.
    #[test]
    fn detector_auto_enter_sends_keys_to_child() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("autoenter");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let mut c = UnixStream::connect(&sock).unwrap();

        // Print the prompt, then block on `read`; when the detector sends Enter
        // the read completes and we print AUTO_ENTER_OK.
        let detect = r#"{
            "enabled": true,
            "startup_probe_seconds": 10,
            "capture_interval_ms": 100,
            "auto_enter_patterns": ["TRUST_PROMPT_MARK"],
            "auto_enter_pre_keys": [""]
        }"#;
        dproto::write_ctl_msg(
            &mut c,
            &CtlMsg::Spawn(SpawnRequest {
                instance: "ae".into(),
                argv: vec![
                    sh.clone(),
                    "-c".into(),
                    "echo TRUST_PROMPT_MARK; read _x; echo AUTO_ENTER_OK; while :; do sleep 1; done".into(),
                ],
                cwd: None,
                env: vec![],
                detect: Some(detect.into()),
                rows: 20,
                cols: 60,
                display_name: None,
            }),
        )
        .unwrap();
        assert!(await_reply(&mut c, |r| matches!(r, CtlReply::Spawned { .. }), Duration::from_secs(3)).is_some());

        // Attach + poll the capture until AUTO_ENTER_OK appears, proving the
        // detector's Enter reached the child's `read`.
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "ae".into() }).unwrap();
        let mut ok = false;
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(6) {
            dproto::write_ctl_msg(&mut c, &CtlMsg::Capture { instance: "ae".into() }).unwrap();
            if await_reply(
                &mut c,
                |r| matches!(r, CtlReply::Screen { screen, .. } if screen.lines.iter().any(|l| l.contains("AUTO_ENTER_OK"))),
                Duration::from_millis(400),
            )
            .is_some()
            {
                ok = true;
                break;
            }
        }
        assert!(ok, "auto-enter Enter never reached the child (no AUTO_ENTER_OK)");
        server.shutdown();
    }

    /// A clean startup (no blocked/auto-enter patterns, unknown allowed) must
    /// eventually emit StartupReady after the probe window.
    #[test]
    fn detector_emits_startup_ready_on_timeout() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("ready");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let mut c = UnixStream::connect(&sock).unwrap();

        // 1s probe window, nothing matches → Ready.
        let detect = r#"{"enabled": true, "startup_probe_seconds": 1, "capture_interval_ms": 100}"#;
        dproto::write_ctl_msg(
            &mut c,
            &CtlMsg::Spawn(SpawnRequest {
                instance: "r".into(),
                argv: vec![sh.clone()],
                cwd: None,
                env: vec![],
                detect: Some(detect.into()),
                rows: 20,
                cols: 60,
                display_name: None,
            }),
        )
        .unwrap();
        // HOST-5: events flow only to attached clients — opt in.
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "r".into() }).unwrap();

        let ev = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::StartupReady { instance } if instance == "r"),
            Duration::from_secs(5),
        );
        assert!(ev.is_some(), "never received StartupReady");
        server.shutdown();
    }

    /// ScreenChanged fires when the child's rendered content changes. We spawn a
    /// shell, then drive it to print new text and assert we observe at least two
    /// distinct ScreenChanged hashes.
    #[test]
    fn detector_emits_screen_changed_on_content_change() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("changed");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let mut c = UnixStream::connect(&sock).unwrap();

        // detect present so the loop runs; no patterns so it just emits activity.
        let detect = r#"{"enabled": true, "capture_interval_ms": 100}"#;
        dproto::write_ctl_msg(
            &mut c,
            &CtlMsg::Spawn(SpawnRequest {
                instance: "ch".into(),
                argv: vec![sh.clone()],
                cwd: None,
                env: vec![],
                detect: Some(detect.into()),
                rows: 20,
                cols: 60,
                display_name: None,
            }),
        )
        .unwrap();
        assert!(await_reply(&mut c, |r| matches!(r, CtlReply::Spawned { .. }), Duration::from_secs(3)).is_some());
        // HOST-5: events flow only to attached clients — opt in.
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "ch".into() }).unwrap();

        // Collect ScreenChanged hashes while driving new content on a retry loop.
        let mut hashes = std::collections::HashSet::new();
        let start = std::time::Instant::now();
        let mut n = 0u32;
        c.set_read_timeout(Some(Duration::from_millis(150))).unwrap();
        while start.elapsed() < Duration::from_secs(6) && hashes.len() < 2 {
            n += 1;
            dproto::write_ctl_msg(
                &mut c,
                &CtlMsg::Input {
                    instance: "ch".into(),
                    data: format!("echo CHANGE_{n}\n").into_bytes(),
                },
            )
            .unwrap();
            let until = std::time::Instant::now() + Duration::from_millis(400);
            while std::time::Instant::now() < until {
                match dproto::read_ctl_reply(&mut c) {
                    Ok(Some(CtlReply::ScreenChanged { hash, .. })) => {
                        hashes.insert(hash);
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => break,
                    Err(ref e)
                        if e.kind() == std::io::ErrorKind::WouldBlock
                            || e.kind() == std::io::ErrorKind::TimedOut => {}
                    Err(_) => break,
                }
            }
        }
        assert!(
            hashes.len() >= 2,
            "expected >=2 distinct ScreenChanged hashes, got {}",
            hashes.len()
        );
        server.shutdown();
    }
}
