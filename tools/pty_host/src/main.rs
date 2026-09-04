//! ham-pty-host CLI entrypoint.
//!
//! Subcommands:
//!   * `run`    — spawn a program under a PTY + host it on a unix socket (PTYH-1/2).
//!   * `attach` — attach to a running host, raw-mode passthrough (PTYH-2).
//!   * `daemon` — run the multi-agent per-machine daemon (HOST-1).
//!   * `spawn`/`close`/`restart`/`list` — control-plane clients for the daemon (HOST-1).
//!
//! `attach --debug` renders the in-app ratatui debug TUI (PTYH-3).

use std::os::unix::net::UnixStream;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};

use ham_pty_host::client::{attach, AttachOutcome};
use ham_pty_host::daemon;
use ham_pty_host::dproto::{self, CtlMsg, CtlReply, SpawnRequest};
use ham_pty_host::server::HostServer;
use ham_pty_host::SpawnConfig;

#[derive(Parser)]
#[command(
    name = "ham-pty-host",
    about = "PTY host + attach/detach + debug TUI spike (PTYH-1..5)"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Spawn a program under a PTY and host it on a unix socket.
    Run {
        /// Unix socket path to listen on.
        #[arg(long)]
        socket: String,
        /// Terminal rows.
        #[arg(long, default_value_t = 24)]
        rows: u16,
        /// Terminal cols.
        #[arg(long, default_value_t = 80)]
        cols: u16,
        /// Disable login-shell (`-l`) behavior for shells.
        #[arg(long)]
        no_login: bool,
        /// Program to run, followed by its arguments.
        #[arg(required = true, trailing_var_arg = true)]
        argv: Vec<String>,
    },
    /// Attach to a running host/daemon over its unix socket.
    ///
    /// Modes:
    ///   * `--socket <daemon>` (no `--instance`, no `--debug`) -> HOST-3 multi
    ///     agent DASHBOARD: agent sidebar + selected agent's live pane.
    ///   * `--socket <host> --debug` -> PTYH-3 single-host split debug TUI.
    ///   * otherwise -> PTYH-2 raw passthrough against a single host.
    Attach {
        /// Unix socket path of the host/daemon to attach to.
        #[arg(long)]
        socket: String,
        /// Render the in-app split-screen debug TUI (single-host, PTYH-3).
        #[arg(long)]
        debug: bool,
        /// Attach to a specific daemon agent by instance id (HOST-4). Absent =>
        /// the multi-agent dashboard (HOST-3).
        #[arg(long)]
        instance: Option<String>,
    },
    /// Run the multi-agent per-machine daemon (HOST-1). Manages N agents keyed
    /// by instance id; clients drive it with spawn/close/restart/list.
    Daemon {
        /// Unix socket path to listen on.
        #[arg(long)]
        socket: String,
    },
    /// Register + launch an agent on a running daemon (HOST-1).
    Spawn {
        #[arg(long)]
        socket: String,
        /// Agent-instance id (registry key).
        #[arg(long)]
        instance: String,
        /// Working directory for the child.
        #[arg(long)]
        cwd: Option<String>,
        /// Extra env var(s), repeatable: --env KEY=VALUE.
        #[arg(long = "env", value_name = "KEY=VALUE")]
        env: Vec<String>,
        /// Startup-detection config as JSON (stored verbatim; parsed in HOST-2).
        #[arg(long)]
        detect: Option<String>,
        #[arg(long, default_value_t = 24)]
        rows: u16,
        #[arg(long, default_value_t = 80)]
        cols: u16,
        /// Program to run, followed by its arguments.
        #[arg(required = true, trailing_var_arg = true)]
        argv: Vec<String>,
    },
    /// Close (SIGTERM->SIGKILL) + unregister an agent on the daemon (HOST-1).
    Close {
        #[arg(long)]
        socket: String,
        #[arg(long)]
        instance: String,
    },
    /// Restart an agent from its remembered spec (HOST-1).
    Restart {
        #[arg(long)]
        socket: String,
        #[arg(long)]
        instance: String,
    },
    /// List all agents registered on the daemon (HOST-1).
    List {
        #[arg(long)]
        socket: String,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Run {
            socket,
            rows,
            cols,
            no_login,
            argv,
        } => run(socket, rows, cols, !no_login, argv),
        Command::Attach {
            socket,
            debug,
            instance,
        } => run_attach(socket, debug, instance),
        Command::Daemon { socket } => daemon::serve(socket),
        Command::Spawn {
            socket,
            instance,
            cwd,
            env,
            detect,
            rows,
            cols,
            argv,
        } => ctl_spawn(socket, instance, cwd, env, detect, rows, cols, argv),
        Command::Close { socket, instance } => ctl_close(socket, instance),
        Command::Restart { socket, instance } => ctl_restart(socket, instance),
        Command::List { socket } => ctl_list(socket),
    }
}

// ---- daemon control-plane clients (HOST-1) -----------------------------

fn connect(socket: &str) -> Result<UnixStream> {
    UnixStream::connect(socket)
        .with_context(|| format!("connect to daemon socket {socket} (is `daemon` running?)"))
}

/// Send one control message + await the next reply frame.
fn request(socket: &str, msg: &CtlMsg) -> Result<CtlReply> {
    let mut stream = connect(socket)?;
    dproto::write_ctl_msg(&mut stream, msg).context("send control msg")?;
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(10)))
        .ok();
    // Skip async Output/ChildExited frames; wait for a control reply.
    loop {
        match dproto::read_ctl_reply(&mut stream)? {
            Some(CtlReply::Output { .. }) | Some(CtlReply::ChildExited { .. }) => continue,
            Some(reply) => return Ok(reply),
            None => bail!("daemon closed the connection without replying"),
        }
    }
}

fn parse_env(pairs: Vec<String>) -> Result<Vec<(String, String)>> {
    pairs
        .into_iter()
        .map(|kv| {
            let (k, v) = kv
                .split_once('=')
                .ok_or_else(|| anyhow::anyhow!("--env expects KEY=VALUE, got {kv:?}"))?;
            Ok((k.to_string(), v.to_string()))
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn ctl_spawn(
    socket: String,
    instance: String,
    cwd: Option<String>,
    env: Vec<String>,
    detect: Option<String>,
    rows: u16,
    cols: u16,
    argv: Vec<String>,
) -> Result<()> {
    let req = SpawnRequest {
        instance: instance.clone(),
        argv,
        cwd,
        env: parse_env(env)?,
        detect,
        rows,
        cols,
    };
    match request(&socket, &CtlMsg::Spawn(req))? {
        CtlReply::Spawned { instance, pid } => {
            println!("spawned {instance} (pid {pid})");
            Ok(())
        }
        CtlReply::Error { message, .. } => bail!("spawn failed: {message}"),
        other => bail!("unexpected reply: {other:?}"),
    }
}

fn ctl_close(socket: String, instance: String) -> Result<()> {
    match request(&socket, &CtlMsg::Close { instance })? {
        CtlReply::Closed { instance } => {
            println!("closed {instance}");
            Ok(())
        }
        CtlReply::Error { message, .. } => bail!("close failed: {message}"),
        other => bail!("unexpected reply: {other:?}"),
    }
}

fn ctl_restart(socket: String, instance: String) -> Result<()> {
    match request(&socket, &CtlMsg::Restart { instance })? {
        CtlReply::Restarted { instance, pid } => {
            println!("restarted {instance} (pid {pid})");
            Ok(())
        }
        CtlReply::Error { message, .. } => bail!("restart failed: {message}"),
        other => bail!("unexpected reply: {other:?}"),
    }
}

fn ctl_list(socket: String) -> Result<()> {
    match request(&socket, &CtlMsg::List)? {
        CtlReply::AgentList(agents) => {
            if agents.is_empty() {
                println!("(no agents)");
            }
            for a in agents {
                let state = if a.alive {
                    "alive".to_string()
                } else {
                    format!("exited({})", a.exit_code.unwrap_or(-1))
                };
                println!(
                    "{:<24} pid={:<7} {:<12} {}x{} {}",
                    a.instance_id, a.pid, state, a.rows, a.cols, a.program
                );
            }
            Ok(())
        }
        other => bail!("unexpected reply: {other:?}"),
    }
}

fn run(
    socket: String,
    rows: u16,
    cols: u16,
    login: bool,
    argv: Vec<String>,
) -> Result<()> {
    let program = argv[0].clone();
    let args = argv[1..].to_vec();
    let config = SpawnConfig {
        program,
        args,
        rows,
        cols,
        login_shell: login,
        cwd: None,
        extra_env: Vec::new(),
    };
    let mut server = HostServer::start(&socket, config)?;
    eprintln!(
        "[ham-pty-host] listening on {} (attach with: ham-pty-host attach --socket {})",
        socket, socket
    );
    let code = server.wait();
    server.shutdown();
    eprintln!("[ham-pty-host] child exited with code {code}");
    std::process::exit(code);
}

fn run_attach(socket: String, debug: bool, instance: Option<String>) -> Result<()> {
    let path = std::path::PathBuf::from(&socket);
    if !path.exists() {
        bail!("socket {socket} does not exist (is the host/daemon running?)");
    }
    // HOST-3: no --instance + no --debug => the multi-agent dashboard against
    // the daemon (agent sidebar + selected agent's live pane).
    if instance.is_none() && !debug {
        ham_pty_host::dashboard_ui::run(&path)?;
        eprintln!("[ham-pty-host] dashboard exited (agents still running)");
        return Ok(());
    }
    if debug {
        // PTYH-3: in-app ratatui split-screen debug TUI.
        ham_pty_host::debug_ui::run(&path)?;
        eprintln!("[ham-pty-host] debug TUI exited (child still running unless it exited)");
        return Ok(());
    }
    match attach(&path)? {
        AttachOutcome::Detached => {
            eprintln!("[ham-pty-host] detached (child still running)");
            Ok(())
        }
        AttachOutcome::ChildExited(code) => {
            eprintln!("[ham-pty-host] child exited with code {code}");
            std::process::exit(code);
        }
        AttachOutcome::Disconnected => {
            eprintln!("[ham-pty-host] disconnected from host");
            Ok(())
        }
    }
}
