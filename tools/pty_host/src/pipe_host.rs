//! Daemon-owned stdio transport. Stdout is a bounded, acknowledged log; neither
//! socket writes nor disconnects consume it. No terminal machinery lives here.
use std::collections::{HashMap, VecDeque};
use std::hash::BuildHasher;
use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
#[cfg(test)]
use std::time::Instant;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::daemon::ReplySink;
use crate::dproto::{CtlReply, SpawnRequest, MAX_PIPE_DATA};
use anyhow::{anyhow, Context, Result};

const REPLAY_BYTES: usize = 16 * 1024 * 1024;
// At most 65,536 entries. Charge allocation capacity (minimum 256 bytes)
// plus a separate entry cap: retained payload capacity <=16 MiB and deque
// slots <=2 MiB on 64-bit targets (18 MiB total, excluding allocator metadata).
const REPLAY_ENTRY_CHARGE: usize = 256;
const REPLAY_ENTRIES: usize = REPLAY_BYTES / REPLAY_ENTRY_CHARGE;
const STDIN_BYTES: usize = 4 * 1024 * 1024;
const STDERR_BYTES: usize = 64 * 1024;
const RECEIPTS: usize = 65_536;
const TICK: Duration = Duration::from_millis(5);

// PDEATHSIG is tied to the thread that forked, not the thread group.
// Spawn on one permanent parent thread so closing a control socket doesn't
// signal the child when that socket's reader thread exits.
#[cfg(target_os = "linux")]
fn spawn_pipe_child(cmd: Command) -> std::io::Result<Child> {
    use std::sync::{mpsc, OnceLock};
    type Work = (Command, mpsc::SyncSender<std::io::Result<Child>>);
    static PARENT: OnceLock<std::io::Result<mpsc::Sender<Work>>> = OnceLock::new();
    let parent = PARENT.get_or_init(|| {
        let (send, receive) = mpsc::channel::<Work>();
        std::thread::Builder::new()
            .name("pipe-child-parent".into())
            .spawn(move || {
                while let Ok((mut command, result)) = receive.recv() {
                    let _ = result.send(command.spawn());
                }
            })?;
        Ok(send)
    }).as_ref().map_err(|err| std::io::Error::new(err.kind(), err.to_string()))?;
    let (send, receive) = mpsc::sync_channel(1);
    parent.send((cmd, send)).map_err(std::io::Error::other)?;
    receive.recv().map_err(std::io::Error::other)?
}
#[cfg(not(target_os = "linux"))]
fn spawn_pipe_child(mut cmd: Command) -> std::io::Result<Child> {
    cmd.spawn()
}

struct Owner {
    id: u64,
    sink: ReplySink,
    cursor: u64,
    stderr_cursor: usize,
    ready: bool,
}
struct Receipt {
    hash: [u64; 2],
    done: bool,
}
struct PendingInput {
    id: String,
    data: Vec<u8>,
}
struct State {
    stdout: VecDeque<(u64, Vec<u8>)>,
    stdout_bytes: usize,
    stdout_charge: usize,
    published: u64,
    last: u64,
    acked: u64,
    stderr: VecDeque<u8>,
    stderr_dropped: usize,
    input: VecDeque<PendingInput>,
    input_bytes: usize,
    receipts: HashMap<String, Receipt>,
    owner: Option<Owner>,
    unusable: bool,
}
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
    stop: AtomicBool,
    alive: Arc<AtomicBool>,
    code: AtomicI32,
    child: Mutex<Child>,
    pid: i32,
    instance: String,
    generation: String,
    activity: Arc<AtomicU64>,
    #[cfg(unix)]
    cancel_read: std::os::unix::net::UnixStream,
    #[cfg(unix)]
    cancel_write: std::os::unix::net::UnixStream,
    hashers: [std::collections::hash_map::RandomState; 2],
    #[cfg(windows)]
    job: crate::job::Job,
}

impl Shared {
    fn signal(&self, signal: u8) -> Result<()> {
        // Serializes reaping and signalling: never target a reused process id.
        let _child = self.child.lock().unwrap();
        #[cfg(unix)]
        if !self.alive.load(Ordering::SeqCst) {
            return Ok(());
        }
        #[cfg(unix)]
        if unsafe { libc::killpg(self.pid, signal as i32) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        #[cfg(windows)]
        match signal {
            0 => (),
            1 | 2 | 9 | 15 => self.job.terminate()?,
            _ => return Err(anyhow!("unsupported pipe signal")),
        }
        Ok(())
    }
    fn reply(&self, seq: u64, stream: u8, data: Vec<u8>) -> CtlReply {
        CtlReply::PipeOutput {
            instance: self.instance.clone(),
            generation: self.generation.clone(),
            seq,
            stream,
            data,
        }
    }
    fn done(&self, id: &str) -> CtlReply {
        CtlReply::PipeInputDone {
            instance: self.instance.clone(),
            generation: self.generation.clone(),
            delivery_id: id.into(),
        }
    }
}

pub struct PipeHost {
    shared: Arc<Shared>,
    threads: Vec<JoinHandle<()>>,
    #[cfg(all(test, target_os = "linux"))]
    tids: Arc<Mutex<Vec<i32>>>,
}

impl PipeHost {
    pub fn spawn(spec: &SpawnRequest, activity: Arc<AtomicU64>) -> Result<Self> {
        let mut cmd = Command::new(&spec.argv[0]);
        cmd.args(&spec.argv[1..])
            .env_clear()
            .envs(
                crate::host::build_child_env()
                    .into_iter()
                    .filter(|(key, _)| {
                        !matches!(
                            key.as_str(),
                            "HEIMDALL_AGENT_TOKEN" | "HEIMDALL_STARTUP_KEY"
                        )
                    }),
            )
            .envs(spec.env.iter().cloned());
        if let Some(cwd) = &spec.cwd {
            cmd.current_dir(cwd);
        }
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            cmd.process_group(0);
            #[cfg(target_os = "linux")]
            {
                let daemon = unsafe { libc::getpid() };
                // Install before exec, then close the fork/prctl window. The
                // child must not run provider code if its daemon already died.
                unsafe {
                    cmd.pre_exec(move || {
                        if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                            return Err(std::io::Error::last_os_error());
                        }
                        if libc::getppid() != daemon {
                            return Err(std::io::Error::from_raw_os_error(libc::ESRCH));
                        }
                        Ok(())
                    });
                }
            }
        }
        #[cfg(unix)]
        let (cancel_read, cancel_write) = std::os::unix::net::UnixStream::pair()?;
        let mut child = spawn_pipe_child(cmd).context("spawn piped child")?;
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        #[cfg(windows)]
        let job = {
            use std::os::windows::io::AsRawHandle;
            match crate::job::Job::assign(child.as_raw_handle() as _) {
                Ok(job) => job,
                Err(e) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(e.into());
                }
            }
        };
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            for fd in [stdin.as_raw_fd(), stdout.as_raw_fd(), stderr.as_raw_fd()] {
                if unsafe { libc::fcntl(fd, libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(std::io::Error::last_os_error().into());
                }
            }
        }
        let random = std::collections::hash_map::RandomState::new();
        let generation = format!("{:016x}{:016x}", random.hash_one(0u8), random.hash_one(1u8));
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                stdout: VecDeque::new(),
                stdout_bytes: 0,
                stdout_charge: 0,
                published: 0,
                last: 0,
                acked: 0,
                stderr: VecDeque::new(),
                stderr_dropped: 0,
                input: VecDeque::new(),
                input_bytes: 0,
                receipts: HashMap::new(),
                owner: None,
                unusable: false,
            }),
            changed: Condvar::new(),
            stop: AtomicBool::new(false),
            alive: Arc::new(AtomicBool::new(true)),
            code: AtomicI32::new(-1),
            pid: child.id() as i32,
            child: Mutex::new(child),
            instance: spec.instance.clone(),
            generation,
            activity,
            #[cfg(unix)]
            cancel_read,
            #[cfg(unix)]
            cancel_write,
            hashers: [
                std::collections::hash_map::RandomState::new(),
                std::collections::hash_map::RandomState::new(),
            ],
            #[cfg(windows)]
            job,
        });
        let mut host = Self {
            shared,
            threads: Vec::new(),
            #[cfg(all(test, target_os = "linux"))]
            tids: Arc::new(Mutex::new(Vec::new())),
        };
        // Each failed thread start drops host, stopping/reaping the child and
        // joining workers already started. No orphan on resource exhaustion.
        let s = host.shared.clone();
        host.start(move || read_output(s, stdout, false))?;
        let s = host.shared.clone();
        host.start(move || read_output(s, stderr, true))?;
        let s = host.shared.clone();
        host.start(move || write_input(s, stdin))?;
        let s = host.shared.clone();
        host.start(move || dispatch(s))?;
        let s = host.shared.clone();
        host.start(move || wait_child(s))?;
        Ok(host)
    }
    fn start(&mut self, f: impl FnOnce() + Send + 'static) -> Result<()> {
        #[cfg(all(test, target_os = "linux"))]
        let tids = self.tids.clone();
        self.threads
            .push(std::thread::Builder::new().spawn(move || {
                #[cfg(all(test, target_os = "linux"))]
                tids.lock()
                    .unwrap()
                    .push(unsafe { libc::syscall(libc::SYS_gettid) as i32 });
                f();
            })?);
        Ok(())
    }
    pub fn generation(&self) -> &str {
        &self.shared.generation
    }
    pub fn pid(&self) -> i32 {
        self.shared.pid
    }
    pub fn alive_flag(&self) -> Arc<AtomicBool> {
        self.shared.alive.clone()
    }
    pub fn exit_code(&self) -> Option<i32> {
        (!self.shared.alive.load(Ordering::SeqCst)).then(|| self.shared.code.load(Ordering::SeqCst))
    }
    pub fn signal(&self, signal: u8) -> Result<()> {
        self.shared.signal(signal)
    }
    pub fn terminate(&self) {
        let _ = self.signal(15);
    }
    pub fn kill(&self) {
        let _ = self.signal(9);
    }
    pub fn wait_timeout(&self, timeout: Duration) -> Option<i32> {
        let state = self.shared.state.lock().unwrap();
        let _guard = self
            .shared
            .changed
            .wait_timeout_while(state, timeout, |_| self.shared.alive.load(Ordering::SeqCst))
            .unwrap();
        self.exit_code()
    }
    fn check_generation(&self, generation: &str) -> Result<()> {
        if generation != self.generation() {
            return Err(anyhow!("stale_pipe_generation"));
        }
        Ok(())
    }
    pub(crate) fn attach(
        &self,
        id: u64,
        generation: &str,
        after: u64,
        sink: ReplySink,
    ) -> Result<Option<CtlReply>> {
        self.check_generation(generation)?;
        sink.mark_pipe();
        let mut s = self.shared.state.lock().unwrap();
        if after > s.last {
            return Err(anyhow!("pipe_cursor_ahead"));
        }
        if after < s.acked {
            // The control reader queues this after releasing host/state locks.
            // Waiting for socket capacity here could stall the liveness roster.
            return Ok(Some(CtlReply::PipeGap {
                instance: self.shared.instance.clone(),
                generation: generation.into(),
                first_seq: s.acked + 1,
            }));
        }
        if let Some(old) = s.owner.take() {
            if old.id != id {
                old.sink.fence();
            }
        }
        s.published = s.published.max(after);
        s.owner = Some(Owner {
            id,
            sink,
            cursor: after,
            stderr_cursor: 0,
            ready: false,
        });
        self.shared.changed.notify_all();
        Ok(None)
    }
    pub fn detach(&self, id: u64, generation: &str) -> Result<()> {
        self.check_generation(generation)?;
        let mut s = self.shared.state.lock().unwrap();
        if s.owner.as_ref().is_some_and(|o| o.id == id) {
            s.owner = None;
        }
        self.shared.changed.notify_all();
        Ok(())
    }
    pub fn ack(&self, id: u64, generation: &str, through: u64) -> Result<()> {
        self.check_generation(generation)?;
        let mut s = self.shared.state.lock().unwrap();
        let owner = s
            .owner
            .as_ref()
            .filter(|o| o.id == id)
            .ok_or_else(|| anyhow!("pipe_owner_fenced"))?;
        if through > owner.cursor {
            return Err(anyhow!("pipe_ack_ahead"));
        }
        while s.stdout.front().is_some_and(|(seq, _)| *seq <= through) {
            let (_, bytes) = s.stdout.pop_front().unwrap();
            s.stdout_bytes -= bytes.len();
            s.stdout_charge -= bytes.capacity().max(REPLAY_ENTRY_CHARGE);
        }
        s.acked = s.acked.max(through);
        self.shared.changed.notify_all();
        Ok(())
    }
    pub fn input(&self, id: u64, generation: &str, delivery: String, data: Vec<u8>) -> Result<()> {
        self.check_generation(generation)?;
        if data.len() > MAX_PIPE_DATA || delivery.is_empty() || delivery.len() > 4096 {
            return Err(anyhow!("invalid_pipe_input"));
        }
        let hash = [
            self.shared.hashers[0].hash_one(&data),
            self.shared.hashers[1].hash_one(&data),
        ];
        let mut s = self.shared.state.lock().unwrap();
        s.owner
            .as_ref()
            .filter(|o| o.id == id)
            .ok_or_else(|| anyhow!("pipe_owner_fenced"))?;
        if let Some(receipt) = s.receipts.get(&delivery) {
            if receipt.hash != hash {
                return Err(anyhow!("pipe_delivery_mismatch"));
            }
            if receipt.done {
                // Dispatcher emits receipts without risking overflow/disconnect.
                if !s.input.iter().any(|p| p.id == delivery) {
                    s.input.push_back(PendingInput {
                        id: delivery,
                        data: Vec::new(),
                    });
                }
                self.shared.changed.notify_all();
            }
            return Ok(());
        }
        if s.unusable || !self.shared.alive.load(Ordering::SeqCst) {
            return Err(anyhow!("pipe_generation_unusable"));
        }
        if s.receipts.len() >= RECEIPTS {
            return Err(anyhow!("pipe_receipts_exhausted"));
        }
        if data.len() > STDIN_BYTES - s.input_bytes {
            return Err(anyhow!("pipe_input_queue_full_retryable"));
        }
        s.input_bytes += data.len();
        s.receipts
            .insert(delivery.clone(), Receipt { hash, done: false });
        s.input.push_back(PendingInput { id: delivery, data });
        self.shared.changed.notify_all();
        Ok(())
    }
    pub fn stop_io(&self) {
        self.shared.stop.store(true, Ordering::SeqCst);
        #[cfg(unix)]
        let _ = self.shared.cancel_write.shutdown(std::net::Shutdown::Both);
        if let Some(owner) = self.shared.state.lock().unwrap().owner.take() {
            owner.sink.fence();
        }
        self.shared.changed.notify_all();
    }
}

impl Drop for PipeHost {
    fn drop(&mut self) {
        self.stop_io();
        self.kill();
        // Reap here as well if the wait thread could not be started.
        let _ = self.shared.child.lock().unwrap().wait();
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

// Wait without reaping so signal() remains serialized with the actual reap:
// a PID cannot be reused between its alive check and killpg.
fn wait_child(s: Arc<Shared>) {
    #[cfg(unix)]
    unsafe {
        let mut info: libc::siginfo_t = std::mem::zeroed();
        loop {
            if libc::waitid(
                libc::P_PID,
                s.pid as _,
                &mut info,
                libc::WEXITED | libc::WNOWAIT,
            ) == 0
            {
                break;
            }
            if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                break;
            }
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        let handle = s.child.lock().unwrap().as_raw_handle();
        unsafe {
            windows_sys::Win32::System::Threading::WaitForSingleObject(handle as _, u32::MAX);
        }
    }
    let mut child = s.child.lock().unwrap();
    if let Ok(status) = child.wait() {
        #[cfg(unix)]
        {
            use std::os::unix::process::ExitStatusExt;
            s.code.store(
                status
                    .code()
                    .unwrap_or_else(|| 128 + status.signal().unwrap_or(0)),
                Ordering::SeqCst,
            );
        }
        #[cfg(windows)]
        s.code.store(status.code().unwrap_or(-1), Ordering::SeqCst);
    }
    let _state = s.state.lock().unwrap();
    s.alive.store(false, Ordering::SeqCst);
    s.changed.notify_all();
}

#[cfg(unix)]
trait PipeRead: Read + std::os::fd::AsRawFd {}
#[cfg(unix)]
impl<T: Read + std::os::fd::AsRawFd> PipeRead for T {}
#[cfg(not(unix))]
trait PipeRead: Read {}
#[cfg(not(unix))]
impl<T: Read> PipeRead for T {}

// Only the owning reader closes its descriptor. Shutdown wakes poll through a
// separate cancellation socket, including when descendants retain stdout.
fn read_output(s: Arc<Shared>, mut reader: impl PipeRead, stderr: bool) {
    let mut buf = [0; MAX_PIPE_DATA];
    loop {
        if s.stop.load(Ordering::SeqCst) {
            return;
        }
        if !stderr {
            let mut state = s.state.lock().unwrap();
            while (state.stdout_charge > REPLAY_BYTES - MAX_PIPE_DATA
                || state.stdout.len() >= REPLAY_ENTRIES)
                && !s.stop.load(Ordering::SeqCst)
            {
                state = s.changed.wait(state).unwrap();
            }
            if s.stop.load(Ordering::SeqCst) {
                return;
            }
        }
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let mut fds = [
                libc::pollfd {
                    fd: reader.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: s.cancel_read.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            let rc = unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) };
            if s.stop.load(Ordering::SeqCst) || fds[1].revents != 0 {
                return;
            }
            if rc < 0 {
                if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return;
            }
        }
        match reader.read(&mut buf) {
            Ok(0) => return,
            Ok(n) => {
                s.activity.store(
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs(),
                    Ordering::SeqCst,
                );
                let mut state = s.state.lock().unwrap();
                if stderr {
                    let excess = (state.stderr.len() + n).saturating_sub(STDERR_BYTES);
                    for _ in 0..excess {
                        state.stderr.pop_front();
                    }
                    state.stderr_dropped += excess;
                    state.stderr.extend(&buf[..n]);
                } else {
                    append_stdout(&mut state, &buf[..n]);
                }
                s.changed.notify_all();
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => (),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => (),
            Err(_) => return,
        }
    }
}

// Never mutate a published sequence: reconnect must replay identical bytes.
fn append_stdout(state: &mut State, data: &[u8]) {
    let published = state.published;
    if let Some((seq, tail)) = state.stdout.back_mut() {
        if *seq > published && tail.len() + data.len() <= MAX_PIPE_DATA {
            let old = tail.capacity().max(REPLAY_ENTRY_CHARGE);
            tail.extend_from_slice(data);
            state.stdout_charge += tail.capacity().max(REPLAY_ENTRY_CHARGE) - old;
            state.stdout_bytes += data.len();
            return;
        }
    }
    state.last += 1;
    let chunk = data.to_vec();
    state.stdout_charge += chunk.capacity().max(REPLAY_ENTRY_CHARGE);
    state.stdout_bytes += chunk.len();
    state.stdout.push_back((state.last, chunk));
}

// One attempt only. Even a failure after a successful prefix poisons the
// generation; the caller must never create a receipt or retry the remainder.
fn write_pending(s: &Shared, writer: &mut impl Write, data: &[u8]) -> bool {
    let mut offset = 0;
    while offset < data.len() {
        if s.stop.load(Ordering::SeqCst) {
            return false;
        }
        match writer.write(&data[offset..]) {
            Ok(n) if n > 0 => offset += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => (),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(TICK),
            _ => {
                s.state.lock().unwrap().unusable = true;
                let _ = s.signal(9);
                return false;
            }
        }
    }
    true
}

fn write_input(s: Arc<Shared>, mut writer: impl Write) {
    loop {
        let mut state = s.state.lock().unwrap();
        while state.input.is_empty() && !s.stop.load(Ordering::SeqCst) {
            state = s.changed.wait(state).unwrap();
        }
        if s.stop.load(Ordering::SeqCst) {
            return;
        }
        let pending = state.input.pop_front().unwrap();
        let already_done = state.receipts[&pending.id].done;
        drop(state);
        if !already_done && !write_pending(&s, &mut writer, &pending.data) {
            return;
        }
        let mut state = s.state.lock().unwrap();
        state.input_bytes -= pending.data.len();
        state.receipts.get_mut(&pending.id).unwrap().done = true;
        // A completed receipt is retained even with no socket. Retrying the
        // persisted id after reattachment returns it without writing again.
        loop {
            if s.stop.load(Ordering::SeqCst) {
                return;
            }
            let Some(owner) = &state.owner else {
                break;
            };
            if !owner.ready {
                state = s.changed.wait(state).unwrap();
                continue;
            }
            match owner.sink.try_send_pipe(s.done(&pending.id)) {
                Ok(true) | Err(()) => break,
                Ok(false) => {
                    state = s.changed.wait_timeout(state, TICK).unwrap().0;
                }
            }
        }
    }
}

fn dispatch(s: Arc<Shared>) {
    loop {
        let mut state = s.state.lock().unwrap();
        if s.stop.load(Ordering::SeqCst) {
            return;
        }
        if let Some(owner) = &state.owner {
            let reply = if !owner.ready {
                Some(CtlReply::PipeReady {
                    instance: s.instance.clone(),
                    generation: s.generation.clone(),
                    first_seq: state.acked + 1,
                    last_seq: state.last,
                })
            } else if let Some((seq, data)) = state.stdout.front().and_then(|(front, _)| {
                owner
                    .cursor
                    .checked_add(1)?
                    .checked_sub(*front)
                    .and_then(|index| usize::try_from(index).ok())
                    .and_then(|index| state.stdout.get(index))
            }) {
                Some(s.reply(*seq, 1, data.clone()))
            } else if owner.stderr_cursor < state.stderr_dropped {
                Some(
                    s.reply(
                        0,
                        2,
                        format!(
                            "[ham-pty-host: stderr truncated {} bytes]\n",
                            state.stderr_dropped - owner.stderr_cursor
                        )
                        .into_bytes(),
                    ),
                )
            } else if owner.stderr_cursor < state.stderr_dropped + state.stderr.len() {
                let skip = owner.stderr_cursor - state.stderr_dropped;
                Some(s.reply(0, 2, state.stderr.iter().skip(skip).copied().collect()))
            } else {
                None
            };
            if let Some(reply) = reply {
                match owner.sink.try_send_pipe(reply.clone()) {
                    Ok(true) => {
                        match reply {
                            CtlReply::PipeReady { .. } => {
                                state.owner.as_mut().unwrap().ready = true;
                                s.changed.notify_all();
                            }
                            CtlReply::PipeOutput { seq, stream: 1, .. } => {
                                state.owner.as_mut().unwrap().cursor = seq;
                                state.published = state.published.max(seq);
                            }
                            _ => {
                                // Retain the diagnostic tail independently of
                                // socket delivery. Each new owner sees it once.
                                let cursor = state.owner.as_ref().unwrap().stderr_cursor;
                                let through = if cursor < state.stderr_dropped {
                                    state.stderr_dropped
                                } else {
                                    state.stderr_dropped + state.stderr.len()
                                };
                                state.owner.as_mut().unwrap().stderr_cursor = through;
                            }
                        }
                        continue;
                    }
                    Err(()) => {
                        state.owner = None;
                    }
                    Ok(false) => {
                        // Only a full subscriber queue needs a timed retry.
                        // Idle dispatchers wait indefinitely below.
                        drop(s.changed.wait_timeout(state, TICK).unwrap());
                        continue;
                    }
                }
            }
        }
        drop(s.changed.wait(state).unwrap());
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::daemon::reply_channel;
    use crate::dproto::{read_ctl_reply, SpawnMode};
    use std::io::Cursor;

    fn spawn(script: &str) -> PipeHost {
        PipeHost::spawn(
            &SpawnRequest {
                instance: "pipe-unit".into(),
                mode: SpawnMode::Pipe,
                argv: vec!["sh".into(), "-c".into(), script.into()],
                ..Default::default()
            },
            Arc::new(AtomicU64::new(0)),
        )
        .unwrap()
    }
    fn wait(pred: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(8);
        while !pred() {
            assert!(Instant::now() < deadline, "condition timed out");
            std::thread::sleep(TICK);
        }
    }

    #[test]
    fn pipe_one_byte_unacked_replay_has_bounded_allocations_and_coalesces() {
        let h = spawn("exec cat");
        let mut state = h.shared.state.lock().unwrap();
        for _ in 0..MAX_PIPE_DATA {
            append_stdout(&mut state, b"x");
        }
        assert_eq!(state.stdout.len(), 1);
        assert_eq!(state.stdout[0].1.len(), MAX_PIPE_DATA);
        // Published chunks must be immutable, even after detaching.
        state.published = state.last;
        while state.stdout_charge <= REPLAY_BYTES - MAX_PIPE_DATA
            && state.stdout.len() < REPLAY_ENTRIES
        {
            append_stdout(&mut state, b"x");
            state.published = state.last;
        }
        assert_eq!(state.stdout[0].1.len(), MAX_PIPE_DATA);
        assert!(state.stdout.len() <= REPLAY_ENTRIES);
        assert!(state.stdout_charge <= REPLAY_BYTES);
        let payload_capacity: usize = state.stdout.iter().map(|(_, v)| v.capacity()).sum();
        let slots = state.stdout.capacity() * std::mem::size_of::<(u64, Vec<u8>)>();
        assert!(payload_capacity + slots <= 18 * 1024 * 1024);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn pipe_idle_workers_have_no_periodic_wakeups() {
        let h = spawn("exec cat");
        let (sink, rx) = reply_channel(None);
        h.attach(1, h.generation(), 0, sink).unwrap();
        drop(rx.recv_timeout(Duration::from_secs(3)).unwrap());
        wait(|| h.tids.lock().unwrap().len() == 5);
        // Let startup and attach notifications finish before measuring.
        std::thread::sleep(Duration::from_millis(100));
        let switches = || {
            h.tids
                .lock()
                .unwrap()
                .iter()
                .map(|tid| {
                    let status =
                        std::fs::read_to_string(format!("/proc/self/task/{tid}/status")).unwrap();
                    status
                        .lines()
                        .filter(|line| line.contains("ctxt_switches:"))
                        .map(|line| {
                            line.split_whitespace()
                                .last()
                                .unwrap()
                                .parse::<u64>()
                                .unwrap()
                        })
                        .sum::<u64>()
                })
                .collect::<Vec<_>>()
        };
        let before = switches();
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(before, switches(), "idle pipe workers must remain blocked");
    }

    #[test]
    fn pipe_full_replay_pauses_then_delivers_every_byte_and_keeps_exit_tail() {
        let h = spawn("printf '%131072s' d >&2; i=0; while test \"$i\" -lt 5120; do printf '%4096s' x; i=$((i+1)); done");
        wait(|| h.shared.state.lock().unwrap().stdout_charge > REPLAY_BYTES - MAX_PIPE_DATA);
        {
            let s = h.shared.state.lock().unwrap();
            assert!(s.stdout_bytes <= REPLAY_BYTES);
            assert_eq!(s.stderr.len(), STDERR_BYTES);
            assert!(s.stderr_dropped > 0);
        }
        assert!(h.exit_code().is_none(), "child must block, not lose output");
        let (sink, rx) = reply_channel(None);
        h.attach(1, h.generation(), 0, sink.clone()).unwrap();
        wait(|| sink.queue_state().0 > 512 * 1024);
        assert!(sink.queue_state().0 <= 1024 * 1024);
        assert!(
            !sink.queue_state().1,
            "full pipe subscription must stay connected"
        );
        let frame = rx.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(matches!(
            read_ctl_reply(&mut Cursor::new(&frame.bytes)).unwrap(),
            Some(CtlReply::PipeReady { .. })
        ));
        drop(frame);
        let mut bytes = 0;
        let mut last = 0;
        while bytes < 5120 * 4096 {
            let frame = rx.recv_timeout(Duration::from_secs(5)).unwrap();
            match read_ctl_reply(&mut Cursor::new(&frame.bytes))
                .unwrap()
                .unwrap()
            {
                CtlReply::PipeOutput {
                    seq,
                    stream: 1,
                    data,
                    ..
                } => {
                    assert_eq!(seq, last + 1);
                    last = seq;
                    bytes += data.len();
                    h.ack(1, h.generation(), seq).unwrap();
                }
                CtlReply::PipeOutput {
                    seq: 0, stream: 2, ..
                } => (),
                r => panic!("{r:?}"),
            }
        }
        assert_eq!(bytes, 20 * 1024 * 1024);
        wait(|| h.exit_code().is_some());
        assert_eq!(h.exit_code(), Some(0));
        assert_eq!(h.shared.state.lock().unwrap().stdout_bytes, 0);
    }

    #[test]
    fn pipe_stderr_retains_diagnostic_tail_and_truncation_across_reattach() {
        let h = spawn("printf '%131072s' d >&2; exec cat");
        wait(|| h.shared.state.lock().unwrap().stderr_dropped == STDERR_BYTES);
        for id in [1, 2] {
            let (sink, rx) = reply_channel(None);
            h.attach(id, h.generation(), 0, sink).unwrap();
            let mut diagnostic = Vec::new();
            while diagnostic.len() < STDERR_BYTES {
                let frame = rx.recv_timeout(Duration::from_secs(3)).unwrap();
                match read_ctl_reply(&mut Cursor::new(&frame.bytes))
                    .unwrap()
                    .unwrap()
                {
                    CtlReply::PipeReady { .. } => (),
                    CtlReply::PipeOutput {
                        seq: 0,
                        stream: 2,
                        data,
                        ..
                    } => {
                        diagnostic.extend(data);
                    }
                    r => panic!("{r:?}"),
                }
            }
            assert!(diagnostic.starts_with(b"[ham-pty-host: stderr truncated 65536 bytes]\n"));
            assert_eq!(
                diagnostic.len(),
                STDERR_BYTES + b"[ham-pty-host: stderr truncated 65536 bytes]\n".len()
            );
            assert_eq!(*diagnostic.last().unwrap(), b'd');
            h.detach(id, h.generation()).unwrap();
            assert_eq!(h.shared.state.lock().unwrap().stderr.len(), STDERR_BYTES);
        }
    }

    #[test]
    fn pipe_owner_fencing_receipt_exhaustion_and_input_budget_are_atomic() {
        let h = spawn("sleep 60");
        let (sink, _rx) = reply_channel(None);
        h.attach(1, h.generation(), 0, sink).unwrap();
        let (sink2, _rx2) = reply_channel(None);
        h.attach(2, h.generation(), 0, sink2).unwrap();
        assert!(h
            .input(1, h.generation(), "stale".into(), vec![1])
            .unwrap_err()
            .to_string()
            .contains("fenced"));
        assert!(h.ack(1, h.generation(), 0).is_err());
        assert!(h.attach(3, "wrong", 0, reply_channel(None).0).is_err());
        assert!(h
            .attach(3, h.generation(), 1, reply_channel(None).0)
            .is_err());
        {
            let mut s = h.shared.state.lock().unwrap();
            s.input_bytes = STDIN_BYTES;
        }
        assert!(h
            .input(2, h.generation(), "full".into(), vec![1])
            .unwrap_err()
            .to_string()
            .contains("retryable"));
        assert!(!h.shared.state.lock().unwrap().receipts.contains_key("full"));
        {
            let mut s = h.shared.state.lock().unwrap();
            s.input_bytes = 0;
            for n in 0..RECEIPTS {
                s.receipts.insert(
                    n.to_string(),
                    Receipt {
                        hash: [0, 0],
                        done: true,
                    },
                );
            }
        }
        assert!(h
            .input(2, h.generation(), "exhausted".into(), vec![1])
            .unwrap_err()
            .to_string()
            .contains("exhausted"));
    }

    #[test]
    fn pipe_blocked_stdin_counts_inflight_bytes_and_rejects_overflow_without_receipt() {
        let h = spawn("sleep 60");
        let (sink, _rx) = reply_channel(None);
        h.attach(1, h.generation(), 0, sink).unwrap();
        // No child reads stdin. The first write blocks in the OS pipe and must
        // continue counting toward the combined queued + in-flight input bound.
        let mut overflow = None;
        // The kernel can consume some complete chunks before it blocks; its
        // capacity varies across systems and is separate from our 4 MiB bound.
        for n in 0..1024 {
            let delivery = n.to_string();
            if let Err(error) = h.input(
                1,
                h.generation(),
                delivery.clone(),
                vec![b'x'; MAX_PIPE_DATA],
            ) {
                assert!(error.to_string().contains("retryable"), "{error}");
                overflow = Some(delivery);
                break;
            }
        }
        let overflow = overflow.expect("unread stdin must eventually apply backpressure");
        let state = h.shared.state.lock().unwrap();
        assert_eq!(state.input_bytes, STDIN_BYTES);
        assert!(!state.receipts.contains_key(&overflow));
    }

    #[test]
    fn pipe_partial_stdin_failure_kills_generation_and_never_receipts() {
        let h = spawn("sleep 60");
        let (sink, _rx) = reply_channel(None);
        h.attach(1, h.generation(), 0, sink).unwrap();
        struct Partial {
            wrote: bool,
        }
        impl Write for Partial {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                if !self.wrote {
                    self.wrote = true;
                    Ok(1)
                } else {
                    Err(std::io::ErrorKind::BrokenPipe.into())
                }
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        h.shared.state.lock().unwrap().receipts.insert(
            "partial".into(),
            Receipt {
                hash: [0, 0],
                done: false,
            },
        );
        assert!(!write_pending(
            &h.shared,
            &mut Partial { wrote: false },
            b"abc"
        ));
        wait(|| h.exit_code().is_some());
        assert!(h.shared.state.lock().unwrap().unusable);
        assert!(!h.shared.state.lock().unwrap().receipts["partial"].done);
        assert!(h.input(1, h.generation(), "new".into(), vec![1]).is_err());
    }
}
