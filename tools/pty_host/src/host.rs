//! REQ PTYH-1: Host core — spawn a child under a PTY and maintain a live VT
//! screen model from its output.
//!
//! `PtyHost` owns:
//!   * the platform PTY pair (via `portable-pty`),
//!   * the child process,
//!   * a reader thread pumping PTY bytes into a shared `VtEngine`,
//!   * a writer handle for sending input to the child.
//!
//! The screen model is shared behind a `Mutex` so callers (and, in later tasks,
//! socket clients / the TUI) can `capture()` at any time and write input.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use anyhow::{Context, Result};
use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};

use crate::vt::{Capture, VtEngine};

/// Environment we hand to the child. We start from a filtered copy of our own
/// env and force interactive-terminal defaults (REQ PTYH-1).
fn build_child_env() -> HashMap<String, String> {
    // Variables that would confuse an interactive child or leak host tooling.
    const DROP: &[&str] = &[
        "TERM",         // we set our own
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "COLUMNS",
        "LINES",
        "TMUX",
        "TMUX_PANE",
        "STY",          // screen
        "NO_COLOR",     // service/automation preference; interactive panes support color
    ];
    let mut env: HashMap<String, String> = std::env::vars()
        .filter(|(k, _)| !DROP.contains(&k.as_str()))
        .collect();
    env.insert("TERM".into(), "xterm-256color".into());
    // Signal to well-behaved programs that they're on a color-capable terminal.
    env.entry("COLORTERM".into()).or_insert_with(|| "truecolor".into());
    env
}

/// Configuration for spawning a child under the host.
#[derive(Clone, Debug)]
pub struct SpawnConfig {
    pub program: String,
    pub args: Vec<String>,
    pub rows: u16,
    pub cols: u16,
    /// If true and the program is a shell, launch it as a login shell.
    pub login_shell: bool,
    pub cwd: Option<String>,
    /// Extra environment variables merged over the filtered base env. Used by
    /// the multi-agent daemon (HOST-1) to inject HEIMDALL_* per instance.
    pub extra_env: Vec<(String, String)>,
}

impl SpawnConfig {
    pub fn new(program: impl Into<String>, args: Vec<String>) -> Self {
        SpawnConfig {
            program: program.into(),
            args,
            rows: 24,
            cols: 80,
            login_shell: true,
            cwd: None,
            extra_env: Vec::new(),
        }
    }
}

/// Handle to a running PTY-hosted child + its live screen model.
pub struct PtyHost {
    engine: Arc<Mutex<VtEngine>>,
    /// PTY master write half and the master itself. Each holds its own
    /// `/dev/ptmx` fd; both become `None` once [`PtyHost::release_pty`] frees
    /// them after the child exits (REQ-PTY-1).
    writer: Arc<Mutex<Option<Box<dyn Write + Send>>>>,
    master: Option<Box<dyn portable_pty::MasterPty + Send>>,
    killer: Arc<Mutex<Box<dyn portable_pty::ChildKiller + Send + Sync>>>,
    child_alive: Arc<AtomicBool>,
    exit_code: Arc<AtomicI32>,
    pid: i32,
    reader_thread: Option<JoinHandle<()>>,
    wait_thread: Option<JoinHandle<()>>,
    /// Broadcast raw PTY output chunks to interested consumers (sockets/TUI).
    output_rx: Option<Receiver<Vec<u8>>>,
    size: (u16, u16),
    notification_pending: bool,
}

impl PtyHost {
    /// Guarded Darwin substrate: inspect/revalidate before opening a PTY or
    /// executing a pathname. No unproved candidate may become an ordinary-spawn
    /// fallback here. The general spawn API remains a separate authority.
    #[cfg(unix)]
    pub fn spawn_darwin_candidate(config: SpawnConfig, candidate: &crate::darwin_image::Candidate) -> Result<Self> {
        if std::path::Path::new(&config.program)!=candidate.path() {
            anyhow::bail!("darwin_image: spawn_path_mismatch");
        }
        candidate.authorize_activation()?;
        Self::spawn(config)
    }

    /// Spawn `config.program` under a fresh PTY.
    pub fn spawn(config: SpawnConfig) -> Result<Self> {
        let pty_system = NativePtySystem::default();
        let pair = pty_system
            .openpty(PtySize {
                rows: config.rows,
                cols: config.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("openpty failed")?;

        let mut cmd = CommandBuilder::new(&config.program);
        // CommandBuilder otherwise inherits even variables removed by our filter.
        cmd.env_clear();
        // Login shell: many shells treat argv[0] starting with '-' as login.
        let is_shellish = config.program.ends_with("sh");
        if config.login_shell && is_shellish && config.args.is_empty() {
            cmd.arg("-l");
        }
        for a in &config.args {
            cmd.arg(a);
        }
        for (k, v) in build_child_env() {
            cmd.env(k, v);
        }
        // Per-instance overrides win over the filtered base env (HOST-1).
        for (k, v) in &config.extra_env {
            cmd.env(k, v);
        }
        if let Some(cwd) = &config.cwd {
            cmd.cwd(cwd);
        }

        let mut child = pair
            .slave
            .spawn_command(cmd)
            .context("failed to spawn child under PTY")?;
        let pid = child.process_id().map(|p| p as i32).unwrap_or(-1);
        let killer = child.clone_killer();
        // Windows: the session's tree lives in a job, killed as one (HOST-1).
        #[cfg(windows)]
        let killer = crate::job::job_killer(&*child, killer);
        // Slave is owned by the child now; drop our handle so EOF propagates.
        drop(pair.slave);

        let engine = Arc::new(Mutex::new(VtEngine::new(
            config.rows as usize,
            config.cols as usize,
        )));
        let writer = pair
            .master
            .take_writer()
            .context("failed to take PTY writer")?;
        let writer = Arc::new(Mutex::new(Some(writer)));
        let mut reader = pair
            .master
            .try_clone_reader()
            .context("failed to clone PTY reader")?;

        let child_alive = Arc::new(AtomicBool::new(true));
        let exit_code = Arc::new(AtomicI32::new(-1));
        let (output_tx, output_rx) = mpsc::sync_channel::<Vec<u8>>(64);

        // Reader thread: pump PTY bytes into the VT engine + broadcast raw bytes.
        // A thread that cannot be created kills the child and fails the spawn
        // rather than panicking the caller (REQ-PTY-3).
        let reader_thread = {
            let engine = Arc::clone(&engine);
            #[cfg(windows)]
            let writer = Arc::clone(&writer);
            std::thread::Builder::new().spawn(move || {
                // ConPTY opens with a cursor-position request (DSR, `ESC[6n`)
                // and holds all output until it is answered.
                #[cfg(windows)]
                let mut dsr_answered = false;
                let mut buf = [0u8; 8192];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) => break, // EOF: child closed the PTY
                        Ok(n) => {
                            {
                                let mut eng = engine.lock().unwrap();
                                eng.feed(&buf[..n]);
                                #[cfg(windows)]
                                if !dsr_answered && buf[..n].windows(4).any(|w| w == b"\x1b[6n") {
                                    dsr_answered = true;
                                    let cap = eng.capture();
                                    let reply = format!("\x1b[{};{}R", cap.cursor_row + 1, cap.cursor_col + 1);
                                    if let Some(w) = writer.lock().unwrap().as_mut() {
                                        let _ = w.write_all(reply.as_bytes());
                                        let _ = w.flush();
                                    }
                                }
                            }
                            // Best-effort broadcast; ignore if no consumer.
                            if output_tx.send(buf[..n].to_vec()).is_err() { break; }
                        }
                        Err(e) => {
                            // Notification dispatch temporarily makes the shared
                            // PTY open-file description nonblocking. A cloned
                            // reader can observe EAGAIN during that short window.
                            if e.kind() == std::io::ErrorKind::WouldBlock {
                                std::thread::sleep(std::time::Duration::from_millis(1));
                                continue;
                            }
                            if e.kind() == std::io::ErrorKind::Interrupted {
                                continue;
                            }
                            break;
                        }
                    }
                }
            })
        };
        let reader_thread = match reader_thread {
            Ok(t) => t,
            Err(e) => {
                let _ = killer.clone_killer().kill();
                return Err(e).context("failed to start PTY reader thread");
            }
        };

        // Wait thread: reap the child + record its exit status.
        let wait_thread = {
            let child_alive = Arc::clone(&child_alive);
            let exit_code = Arc::clone(&exit_code);
            std::thread::Builder::new().spawn(move || {
                if let Ok(status) = child.wait() {
                    exit_code.store(status.exit_code() as i32, Ordering::SeqCst);
                }
                child_alive.store(false, Ordering::SeqCst);
            })
        };
        let wait_thread = match wait_thread {
            Ok(t) => t,
            Err(e) => {
                let _ = killer.clone_killer().kill();
                return Err(e).context("failed to start child wait thread");
            }
        };

        Ok(PtyHost {
            engine,
            writer,
            master: Some(pair.master),
            killer: Arc::new(Mutex::new(killer)),
            child_alive,
            exit_code,
            pid,
            reader_thread: Some(reader_thread),
            wait_thread: Some(wait_thread),
            output_rx: Some(output_rx),
            size: (config.rows, config.cols),
            notification_pending: false,
        })
    }

    /// Send raw bytes to the child's stdin (via the PTY).
    pub fn write_input(&self, bytes: &[u8]) -> Result<()> {
        if self.notification_pending { return Err(anyhow::anyhow!("input: notification delivery is incomplete")); }
        let mut guard = self.writer.lock().unwrap();
        let w = guard
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("write to PTY failed: session has exited"))?;
        w.write_all(bytes).context("write to PTY failed")?;
        w.flush().ok();
        Ok(())
    }

    /// Startup input keeps byte progress across retries. `Write::write` reports
    /// the bytes accepted before an error, so resuming never retypes a prefix.
    pub fn write_startup_input(&self, bytes: &[u8], written: &mut usize) -> Result<()> {
        if self.notification_pending { return Err(anyhow::anyhow!("startup input: notification delivery is incomplete")); }
        let mut guard = self.writer.lock().unwrap();
        let w = guard.as_mut().ok_or_else(|| anyhow::anyhow!("startup input: session has exited"))?;
        write_startup_remaining(w, bytes, written).context("startup input: PTY write failed")
    }

    pub fn notification(&mut self, deliveries: &mut crate::delivery::Deliveries, intent: &crate::delivery::Delivery, mode: u8, ticket: &str) -> Result<crate::delivery::Receipt> {
        if cfg!(windows) { return Err(anyhow::anyhow!("notification: unsupported_not_delivered")); }
        let mut guard = self.writer.lock().unwrap();
        let w = guard.as_mut().ok_or_else(|| anyhow::anyhow!("notification: child writer unavailable"))?;
        // Verify the actual target's DEC2004 advertisement, not its provider
        // name. Keep the local VT-mode observation stable through this write.
        let runtime = if mode == crate::delivery::DISPATCH { Some(self.engine.lock().unwrap()) } else { None };
        if let Some(runtime)=&runtime {
            let previous=deliveries.apply(intent,crate::delivery::QUERY,ticket,w).map_err(|e| anyhow::anyhow!(e))?;
            if previous.status != crate::delivery::PARTIAL { return Ok(previous); }
            if !runtime.bracketed_paste_enabled() {
                if deliveries.started(&intent.delivery_id) { return Ok(deliveries.recover(&intent.delivery_id)); }
                return Err(anyhow::anyhow!("notification: literal_paste_unsupported_not_delivered"));
            }
            // Disabling and re-enabling paste between retries can reset the
            // target editor's partial delimiter state even if it is enabled now.
            if !deliveries.bind_paste_generation(&intent.delivery_id,runtime.bracketed_paste_generation()) {
                return Ok(deliveries.recover(&intent.delivery_id));
            }
        }
        #[cfg(unix)]
        let _nonblocking = if mode == crate::delivery::DISPATCH {
            let fd = self.master.as_ref().and_then(|m| m.as_raw_fd()).ok_or_else(|| anyhow::anyhow!("notification: no PTY descriptor"))?;
            Some(NotificationNonblocking::new(fd)?)
        } else { None };
        let result = deliveries.apply(intent, mode, ticket, w).map_err(|e| anyhow::anyhow!(e));
        self.notification_pending = deliveries.pending();
        result
    }

    /// Snapshot the current rendered screen.
    pub fn capture(&self) -> Capture {
        self.engine.lock().unwrap().capture()
    }

    /// Shared engine handle (used by socket server / TUI in later tasks).
    pub fn engine(&self) -> Arc<Mutex<VtEngine>> {
        Arc::clone(&self.engine)
    }

    /// Take the raw-output receiver (single consumer). Later tasks fan this out.
    pub fn take_output_rx(&mut self) -> Option<Receiver<Vec<u8>>> {
        self.output_rx.take()
    }

    /// Resize the PTY window + the VT model together (REQ PTYH-1 winsize).
    /// After [`PtyHost::release_pty`] only the VT model is resized.
    pub fn resize(&mut self, rows: u16, cols: u16) -> Result<()> {
        if let Some(master) = &self.master {
            master
                .resize(PtySize {
                    rows,
                    cols,
                    pixel_width: 0,
                    pixel_height: 0,
                })
                .context("PTY resize failed")?;
        }
        self.engine
            .lock()
            .unwrap()
            .resize(rows as usize, cols as usize);
        self.size = (rows, cols);
        Ok(())
    }

    pub fn size(&self) -> (u16, u16) {
        self.size
    }

    pub fn is_alive(&self) -> bool {
        self.child_alive.load(Ordering::SeqCst)
    }

    /// OS process id of the child (or -1 if unknown).
    pub fn pid(&self) -> i32 {
        self.pid
    }

    /// Send SIGTERM to the child for a graceful shutdown (HOST-1 close path).
    /// Falls back to no-op if the pid is unknown. The hard SIGKILL fallback is
    /// [`PtyHost::kill`]. Windows has no SIGTERM: the session's job is killed.
    pub fn terminate(&self) {
        #[cfg(unix)]
        if self.pid > 0 {
            unsafe {
                libc::kill(self.pid, libc::SIGTERM);
            }
        }
        #[cfg(windows)]
        self.kill();
    }

    /// Windows stand-in for `killpg(pid, signum)` (HOST-1 `Signal`): SIGINT
    /// writes Ctrl-C (0x03) into the ConPTY input; SIGHUP/SIGKILL/SIGTERM kill
    /// the session's job (the whole tree); 0 only probes. Others are refused.
    #[cfg(windows)]
    pub fn signal(&self, signum: u8) -> Result<()> {
        const SIGHUP: u8 = 1;
        const SIGINT: u8 = 2;
        const SIGKILL: u8 = 9;
        const SIGTERM: u8 = 15;
        match signum {
            0 => Ok(()),
            SIGINT => self.write_input(&[0x03]),
            SIGHUP | SIGKILL | SIGTERM => {
                self.killer.lock().unwrap().kill().context("terminate job")
            }
            _ => Err(anyhow::anyhow!("signal {signum} is not supported on Windows")),
        }
    }

    /// Forcibly terminate the child (SIGKILL). Used for host shutdown so the
    /// PTY closes and the reader/fan-out threads can exit. No-op if already
    /// dead. Safe to call from any thread via the shared killer handle.
    pub fn kill(&self) {
        let _ = self.killer.lock().unwrap().kill();
    }

    /// Shared killer handle for shutting the child down from another thread.
    pub fn killer(&self) -> Arc<Mutex<Box<dyn portable_pty::ChildKiller + Send + Sync>>> {
        Arc::clone(&self.killer)
    }

    /// Exit code if the child has exited, else `None`.
    pub fn exit_code(&self) -> Option<i32> {
        if self.is_alive() {
            None
        } else {
            Some(self.exit_code.load(Ordering::SeqCst))
        }
    }

    /// REQ-PTY-1: close this host's PTY master fds once the child has exited.
    ///
    /// The reader thread holds its own fd (closed at EOF), so a straggler that
    /// still has the slave open only keeps that one fd, never these two. Callers
    /// wait for [`PtyHost::reader_done`] first so the child's last output is
    /// already in the VT model. Afterwards `capture` keeps answering from the VT
    /// model while `write_input` errors. No-op while the child is alive;
    /// idempotent.
    pub fn release_pty(&mut self) {
        if self.is_alive() {
            return;
        }
        // portable-pty's Unix writer Drop writes LF+VEOF. A full input buffer
        // can otherwise block teardown even after the child exited. The same
        // nonblocking bound is needed when retiring a partial notification.
        #[cfg(unix)]
        let flags = self.master.as_ref().and_then(|m| m.as_raw_fd()).and_then(|fd| NotificationNonblocking::new(fd).ok());
        self.writer.lock().unwrap().take();
        #[cfg(unix)]
        drop(flags);
        self.master.take();
    }

    /// Whether the reader thread has hit EOF (all child output is consumed).
    pub fn reader_done(&self) -> bool {
        self.reader_thread.as_ref().map_or(true, |t| t.is_finished())
    }

    /// Whether [`PtyHost::release_pty`] has closed the master fds.
    pub fn pty_released(&self) -> bool {
        self.master.is_none()
    }

    pub fn alive_flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.child_alive)
    }

    /// Shared exit-code cell (used by the daemon's per-agent exit watcher).
    pub fn exit_code_arc(&self) -> Arc<AtomicI32> {
        Arc::clone(&self.exit_code)
    }

    /// Block until the child exits, then join background threads.
    pub fn wait(&mut self) -> i32 {
        if let Some(t) = self.wait_thread.take() {
            let _ = t.join();
        }
        if let Some(t) = self.reader_thread.take() {
            let _ = t.join();
        }
        self.exit_code.load(Ordering::SeqCst)
    }

    /// Block until the child exits or `timeout` elapses. Returns exit code if it
    /// exited. Used by tests + graceful shutdown.
    pub fn wait_timeout(&self, timeout: std::time::Duration) -> Option<i32> {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            if !self.is_alive() {
                return Some(self.exit_code.load(Ordering::SeqCst));
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        None
    }
}

impl Drop for PtyHost {
    fn drop(&mut self) {
        if self.notification_pending && !self.is_alive() { self.release_pty(); }
    }
}

// The writer and reader are dup()s of the same open file description. Hold the
// host/writer locks while toggling its flags; restore them before ordinary I/O.
#[cfg(unix)]
struct NotificationNonblocking { fd: std::os::fd::RawFd, original: libc::c_int }
#[cfg(unix)]
impl NotificationNonblocking {
    fn new(fd: std::os::fd::RawFd) -> Result<Self> {
        let original=unsafe { libc::fcntl(fd,libc::F_GETFL) };
        if original < 0 || unsafe { libc::fcntl(fd,libc::F_SETFL,original | libc::O_NONBLOCK) } < 0 {
            return Err(anyhow::anyhow!("notification: nonblocking PTY unavailable"));
        }
        Ok(Self { fd,original })
    }
}
#[cfg(unix)]
impl Drop for NotificationNonblocking {
    fn drop(&mut self) { unsafe { libc::fcntl(self.fd,libc::F_SETFL,self.original); } }
}

fn write_startup_remaining<W: std::io::Write + ?Sized>(writer: &mut W, bytes: &[u8], written: &mut usize) -> std::io::Result<()> {
    if *written > bytes.len() {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid startup input progress"));
    }
    while *written < bytes.len() {
        match writer.write(&bytes[*written..]) {
            Ok(0) => return Err(std::io::ErrorKind::WriteZero.into()),
            Ok(n) => *written += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    // A failed flush can be retried too, without writing the bytes again.
    writer.flush()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn startup_input_resumes_partial_write_and_failed_flush() {
        struct Flaky { bytes: Vec<u8>, fail_write: bool, fail_flush: bool }
        impl std::io::Write for Flaky {
            fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
                if self.bytes.len() == 3 && self.fail_write {
                    self.fail_write = false;
                    return Err(std::io::ErrorKind::BrokenPipe.into());
                }
                let n = if self.bytes.is_empty() { 3.min(data.len()) } else { data.len() };
                self.bytes.extend_from_slice(&data[..n]);
                Ok(n)
            }
            fn flush(&mut self) -> std::io::Result<()> {
                if self.fail_flush {
                    self.fail_flush = false;
                    return Err(std::io::ErrorKind::Interrupted.into());
                }
                Ok(())
            }
        }
        let bytes = b"startup command\r";
        let mut writer = Flaky { bytes: vec![], fail_write: true, fail_flush: true };
        let mut written = 0;
        assert!(write_startup_remaining(&mut writer, bytes, &mut written).is_err());
        assert_eq!(written, 3);
        assert!(write_startup_remaining(&mut writer, bytes, &mut written).is_err());
        assert_eq!(written, bytes.len());
        write_startup_remaining(&mut writer, bytes, &mut written).unwrap();
        assert_eq!(writer.bytes, bytes, "retry must never retype an accepted prefix");
    }

    #[cfg(unix)]
    #[test]
    fn notification_partial_excludes_raw_and_startup_writers() {
        if !pty_available() { eprintln!("[skip] no PTY available"); return; }
        let Some(sh)=shell() else { return };
        let mut host=PtyHost::spawn(SpawnConfig::new(sh,vec!["-c".into(),"printf FIXTURE_READY; sleep 30".into()])).unwrap();
        assert!(wait_for(||host.capture().lines.join("\n").contains("FIXTURE_READY"),Duration::from_secs(3)));
        host.engine.lock().unwrap().feed(b"\x1b[?2004h");
        struct Flaky { bytes: Vec<u8>, fail: bool }
        impl std::io::Write for Flaky {
            fn write(&mut self,data:&[u8])->std::io::Result<usize> {
                if self.bytes.len()==1 && self.fail { self.fail=false; return Err(std::io::ErrorKind::WouldBlock.into()); }
                self.bytes.extend_from_slice(data); Ok(data.len())
            }
            fn flush(&mut self)->std::io::Result<()> { Ok(()) }
        }
        *host.writer.lock().unwrap()=Some(Box::new(Flaky { bytes:vec![],fail:true }));
        let intent=crate::delivery::tests::intent();
        let mut deliveries=crate::delivery::tests::store();
        let p=host.notification(&mut deliveries,&intent,crate::delivery::PREPARE,"").unwrap();
        let partial=host.notification(&mut deliveries,&intent,crate::delivery::DISPATCH,&p.ticket).unwrap();
        assert!(partial.esc_written && !partial.enter_written);
        assert!(host.write_input(b"raw").is_err());
        assert!(host.write_startup_input(b"startup",&mut 0).is_err());
        let queried=host.notification(&mut deliveries,&intent,crate::delivery::QUERY,&p.ticket).unwrap();
        assert_eq!((queried.esc_written,queried.message_written,queried.enter_written,queried.status),(partial.esc_written,partial.message_written,partial.enter_written,partial.status));
        assert!(queried.retry_after_ms<=partial.retry_after_ms);
        std::thread::sleep(Duration::from_millis(110));
        host.notification(&mut deliveries,&intent,crate::delivery::DISPATCH,&p.ticket).unwrap();
        assert_eq!(host.notification(&mut deliveries,&intent,crate::delivery::DISPATCH,&p.ticket).unwrap().status,crate::delivery::DELIVERED);
        assert!(host.write_input(b"raw after completion").is_ok());
        host.kill(); host.wait_timeout(Duration::from_secs(3));
    }

    #[cfg(unix)]
    #[test]
    fn notification_runtime_paste_gate_and_lost_mode_are_fail_closed() {
        if !pty_available() { eprintln!("[skip] no PTY available"); return; }
        let Some(sh)=shell() else { return };
        let mut host=PtyHost::spawn(SpawnConfig::new(sh,vec![])).unwrap();
        struct Sink(Arc<Mutex<(Vec<u8>,usize)>>);
        impl std::io::Write for Sink {
            fn write(&mut self,data:&[u8])->std::io::Result<usize> {
                let mut state=self.0.lock().unwrap();
                if state.1==0 { return Err(std::io::ErrorKind::WouldBlock.into()); }
                let n=data.len().min(state.1); state.0.extend_from_slice(&data[..n]); state.1-=n; Ok(n)
            }
            fn flush(&mut self)->std::io::Result<()> { Ok(()) }
        }
        let state=Arc::new(Mutex::new((vec![],2)));
        *host.writer.lock().unwrap()=Some(Box::new(Sink(state.clone())));
        let mut deliveries=crate::delivery::tests::store(); let intent=crate::delivery::tests::intent();
        let p=host.notification(&mut deliveries,&intent,crate::delivery::PREPARE,"").unwrap();
        let error=host.notification(&mut deliveries,&intent,crate::delivery::DISPATCH,&p.ticket).unwrap_err();
        assert_eq!(error.to_string(),"notification: literal_paste_unsupported_not_delivered");
        assert!(state.lock().unwrap().0.is_empty());
        host.engine.lock().unwrap().feed(b"\x1b[?2004h");
        let partial=host.notification(&mut deliveries,&intent,crate::delivery::DISPATCH,&p.ticket).unwrap();
        assert_eq!(partial.status,crate::delivery::PARTIAL);
        assert_eq!(state.lock().unwrap().0,b"\x1b");
        host.engine.lock().unwrap().feed(b"\x1b[?2004l");
        host.engine.lock().unwrap().feed(b"\x1b[?2004h");
        state.lock().unwrap().1=999;
        let recovery=host.notification(&mut deliveries,&intent,crate::delivery::DISPATCH,&p.ticket).unwrap();
        assert_eq!(recovery.status,crate::delivery::RECOVERY_REQUIRED);
        host.engine.lock().unwrap().feed(b"\x1b[?2004h");
        assert_eq!(host.notification(&mut deliveries,&intent,crate::delivery::DISPATCH,&p.ticket).unwrap().status,crate::delivery::RECOVERY_REQUIRED);
        assert_eq!(state.lock().unwrap().0,b"\x1b");
        assert!(host.write_input(b"cannot splice").is_err());
        host.kill(); host.wait_timeout(Duration::from_secs(3));
    }

    #[cfg(unix)]
    #[test]
    fn notification_full_pty_buffer_is_bounded_and_reader_survives() {
        if !pty_available() { eprintln!("[skip] no PTY available"); return; }
        let Some(sh)=shell() else { return };
        let mut config=SpawnConfig::new(sh,vec!["-c".into(),"stty raw -echo; printf '\\033[?2004hBUFFER_READY'; sleep 1; printf 'READER_SURVIVED'; sleep 30".into()]);
        config.login_shell=false;
        let mut host=PtyHost::spawn(config).unwrap();
        assert!(wait_for(|| host.capture().lines.join("\n").contains("BUFFER_READY"),Duration::from_secs(3)));
        let fd=host.master.as_ref().unwrap().as_raw_fd().unwrap();
        let original=unsafe { libc::fcntl(fd,libc::F_GETFL) };
        {
            let mut guard=host.writer.lock().unwrap();
            let writer=guard.as_mut().unwrap();
            let _flags=NotificationNonblocking::new(fd).unwrap();
            let mut filled=false;
            for _ in 0..1024 {
                match writer.write(&[b'x';4096]) {
                    Ok(_) => {},
                    Err(e) if e.kind()==std::io::ErrorKind::WouldBlock => { filled=true; break; },
                    Err(e) => panic!("{e}"),
                }
            }
            assert!(filled,"input buffer did not reach backpressure");
        }
        let mut intent=crate::delivery::tests::intent();
        intent.message=vec![b'n';16384];
        let mut deliveries=crate::delivery::tests::store();
        let p=host.notification(&mut deliveries,&intent,crate::delivery::PREPARE,"").unwrap();
        let start=std::time::Instant::now();
        let partial=host.notification(&mut deliveries,&intent,crate::delivery::DISPATCH,&p.ticket).unwrap();
        assert!(start.elapsed()<Duration::from_millis(500));
        assert_eq!(partial.status,crate::delivery::PARTIAL);
        assert!(!partial.enter_written);
        assert_eq!(unsafe { libc::fcntl(fd,libc::F_GETFL) } & libc::O_NONBLOCK,original & libc::O_NONBLOCK);
        assert!(host.write_input(b"cannot splice").is_err());
        assert!(wait_for(|| host.capture().lines.join("\n").contains("READER_SURVIVED"),Duration::from_secs(3)));
        host.kill(); host.wait_timeout(Duration::from_secs(3));
    }

    #[test]
    fn startup_input_zero_write_keeps_progress_retryable() {
        struct Zero;
        impl std::io::Write for Zero {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> { Ok(0) }
            fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
        }
        let mut written = 0;
        assert_eq!(write_startup_remaining(&mut Zero, b"x", &mut written).unwrap_err().kind(), std::io::ErrorKind::WriteZero);
        assert_eq!(written, 0);
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

    /// Resolve a program by absolute path or via $PATH. Returns None if it
    /// cannot be found, so tests can skip in a minimal sandbox (e.g. the nix
    /// build sandbox, which has no /bin/sh). Keeps `cargo test` green both
    /// locally and hermetically (PTYH-4).
    pub(crate) fn resolve(prog: &str) -> Option<String> {
        if prog.contains('/') {
            return if std::path::Path::new(prog).exists() {
                Some(prog.to_string())
            } else {
                None
            };
        }
        for dir in std::env::var("PATH").unwrap_or_default().split(':') {
            if dir.is_empty() {
                continue;
            }
            let cand = std::path::Path::new(dir).join(prog);
            if cand.exists() {
                return cand.to_str().map(|s| s.to_string());
            }
        }
        None
    }

    /// Resolve a POSIX shell for tests, or None to skip.
    pub(crate) fn shell() -> Option<String> {
        resolve("sh").or_else(|| resolve("/bin/sh")).or_else(|| resolve("bash"))
    }

    /// True if this environment can actually spawn a child under a PTY. The nix
    /// build sandbox has no /dev/pts, so even when openpty() half-succeeds the
    /// fork/exec into the slave fails; PTY-dependent tests skip when this is
    /// false (they still run locally + in CI where a real PTY exists). We probe
    /// with a real end-to-end spawn of `true` so the check matches production.
    pub(crate) fn pty_available() -> bool {
        let prog = match resolve("true").or_else(|| resolve("/usr/bin/true")) {
            Some(p) => p,
            None => {
                assert!(std::env::var("HEIMDALL_NOTIFICATION_REQUIRE_PTY").as_deref() != Ok("1"),
                    "required notification PTY probe executable is unavailable");
                return false;
            }
        };
        let available = PtyHost::spawn(SpawnConfig {
            program: prog,
            args: vec![],
            rows: 24,
            cols: 80,
            login_shell: false,
            cwd: None,
            extra_env: Vec::new(),
        })
        .is_ok();
        assert!(available || std::env::var("HEIMDALL_NOTIFICATION_REQUIRE_PTY").as_deref() != Ok("1"),
            "real notification PTY evidence was required");
        available
    }

    macro_rules! skip_if_none {
        ($opt:expr, $name:literal) => {
            match $opt {
                Some(v) => v,
                None => {
                    eprintln!("[skip] {} unavailable in this environment", $name);
                    return;
                }
            }
        };
    }

    #[test]
    fn spawn_echo_and_capture_rendered_output() {
        if !pty_available() {
            eprintln!("[skip] no PTY available in this environment");
            return;
        }
        // `echo hi` should render "hi" in the grid, not raw bytes.
        let echo = skip_if_none!(resolve("echo").or_else(|| resolve("/bin/echo")), "echo");
        let host = PtyHost::spawn(SpawnConfig {
            program: echo,
            args: vec!["hi".into()],
            rows: 10,
            cols: 40,
            login_shell: false,
            cwd: None,
            extra_env: Vec::new(),
        })
        .unwrap();
        host.wait_timeout(Duration::from_secs(5));
        // Give the reader a moment to drain final bytes.
        wait_for(|| host.capture().lines[0].contains("hi"), Duration::from_secs(2));
        let cap = host.capture();
        assert!(
            cap.lines.iter().any(|l| l.contains("hi")),
            "expected 'hi' in capture, got: {:?}",
            cap.lines
        );
        assert_eq!(host.exit_code(), Some(0));
    }

    #[test]
    fn write_input_to_shell_is_reflected_in_capture() {
        if !pty_available() {
            eprintln!("[skip] no PTY available in this environment");
            return;
        }
        let sh = skip_if_none!(shell(), "sh");
        let host = PtyHost::spawn(SpawnConfig {
            program: sh,
            args: vec![],
            rows: 20,
            cols: 60,
            login_shell: false,
            cwd: None,
            extra_env: Vec::new(),
        })
        .unwrap();
        // Let the shell come up.
        std::thread::sleep(Duration::from_millis(300));
        host.write_input(b"echo marker123\n").unwrap();
        let ok = wait_for(
            || {
                host.capture()
                    .lines
                    .iter()
                    .any(|l| l.contains("marker123"))
            },
            Duration::from_secs(3),
        );
        assert!(ok, "capture did not reflect echoed marker: {:?}", host.capture().lines);
        // Child should still be alive (interactive shell).
        assert!(host.is_alive());
        host.write_input(b"exit\n").unwrap();
        host.wait_timeout(Duration::from_secs(3));
    }

    #[test]
    fn interactive_child_drops_inherited_no_color_but_allows_explicit_override() {
        if !pty_available() {
            return;
        }
        let sh = skip_if_none!(shell(), "sh");
        for (extra_env, expected) in [
            (Vec::new(), "color-default=unset"),
            (vec![("NO_COLOR".into(), "1".into())], "color-default=1"),
        ] {
            let mut config = SpawnConfig::new(
                sh.clone(),
                vec!["-c".into(), "printf 'color-default=%s' \"${NO_COLOR-unset}\"".into()],
            );
            config.login_shell = false;
            config.extra_env = extra_env;
            let host = PtyHost::spawn(config).unwrap();
            assert!(wait_for(
                || host.capture().lines.iter().any(|line| line.contains(expected)),
                Duration::from_secs(3),
            ), "child environment did not match {expected}: {:?}", host.capture().lines);
        }
    }

    #[test]
    fn color_output_records_rendition() {
        if !pty_available() {
            eprintln!("[skip] no PTY available in this environment");
            return;
        }
        // printf a red 'R' then reset; capture must record fg color on the cell.
        let sh = skip_if_none!(shell(), "sh");
        let host = PtyHost::spawn(SpawnConfig {
            program: sh,
            args: vec!["-c".into(), "printf '\\033[31mR\\033[0m'".into()],
            rows: 5,
            cols: 20,
            login_shell: false,
            cwd: None,
            extra_env: Vec::new(),
        })
        .unwrap();
        host.wait_timeout(Duration::from_secs(5));
        wait_for(|| host.capture().lines[0].contains('R'), Duration::from_secs(2));
        let cap = host.capture();
        let cell = cap.cell_at(0, 0).unwrap();
        assert_eq!(cell.c, 'R');
        assert_eq!(cell.fg, crate::vt::Color::Indexed(1));
    }

    #[test]
    fn resize_updates_model() {
        if !pty_available() {
            eprintln!("[skip] no PTY available in this environment");
            return;
        }
        let sh = skip_if_none!(shell(), "sh");
        let mut host = PtyHost::spawn(SpawnConfig {
            program: sh,
            args: vec![],
            rows: 24,
            cols: 80,
            login_shell: false,
            cwd: None,
            extra_env: Vec::new(),
        })
        .unwrap();
        std::thread::sleep(Duration::from_millis(200));
        host.resize(30, 100).unwrap();
        let cap = host.capture();
        assert_eq!(cap.rows, 30);
        assert_eq!(cap.cols, 100);
        host.write_input(b"exit\n").unwrap();
        host.wait_timeout(Duration::from_secs(3));
    }
}
