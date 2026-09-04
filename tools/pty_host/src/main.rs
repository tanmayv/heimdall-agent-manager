//! ham-pty-host CLI entrypoint.
//!
//! Subcommands:
//!   * `run`    — spawn a program under a PTY + host it on a unix socket (PTYH-1/2).
//!   * `attach` — attach to a running host, raw-mode passthrough (PTYH-2).
//!
//! PTYH-3 will add `attach --debug` for the in-app ratatui debug TUI.

use anyhow::{bail, Result};
use clap::{Parser, Subcommand};

use ham_pty_host::client::{attach, AttachOutcome};
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
    /// Attach to a running host over its unix socket (raw passthrough).
    Attach {
        /// Unix socket path of the host to attach to.
        #[arg(long)]
        socket: String,
        /// Render the in-app split-screen debug TUI instead of raw passthrough.
        #[arg(long)]
        debug: bool,
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
        Command::Attach { socket, debug } => run_attach(socket, debug),
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

fn run_attach(socket: String, debug: bool) -> Result<()> {
    let path = std::path::PathBuf::from(&socket);
    if !path.exists() {
        bail!("socket {socket} does not exist (is the host running?)");
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
