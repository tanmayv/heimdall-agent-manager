//! ham-pty-host CLI entrypoint (REQ PTYH-1).
//!
//! For this task the `run` subcommand spawns a program under a PTY, streams its
//! output to our stdout, and forwards our stdin. Later tasks (PTYH-2/3) add the
//! unix-socket attach/detach protocol and the in-app debug TUI.

use std::io::Write;

use anyhow::Result;
use clap::{Parser, Subcommand};

use ham_pty_host::{PtyHost, SpawnConfig};

#[derive(Parser)]
#[command(
    name = "ham-pty-host",
    about = "PTY host + VT screen model spike (PTYH-1..5)"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Spawn a program under a PTY and host its terminal session.
    Run {
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
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Run {
            rows,
            cols,
            no_login,
            argv,
        } => run(rows, cols, !no_login, argv),
    }
}

fn run(rows: u16, cols: u16, login: bool, argv: Vec<String>) -> Result<()> {
    let program = argv[0].clone();
    let args = argv[1..].to_vec();
    let mut host = PtyHost::spawn(SpawnConfig {
        program,
        args,
        rows,
        cols,
        login_shell: login,
        cwd: None,
    })?;

    // Simple passthrough: drain raw output to stdout until the child exits.
    let output_rx = host.take_output_rx().expect("output rx available");
    let printer = std::thread::spawn(move || {
        let mut out = std::io::stdout();
        while let Ok(chunk) = output_rx.recv() {
            let _ = out.write_all(&chunk);
            let _ = out.flush();
        }
    });

    let code = host.wait();
    let _ = printer.join();
    eprintln!("[ham-pty-host] child exited with code {code}");
    std::process::exit(code);
}
