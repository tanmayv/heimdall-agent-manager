//! REQ HOST-4: single-agent `attach --instance <id>` — raw passthrough to ONE
//! daemon agent, no sidebar, for dropping into a tmux pane and tiling manually.
//!
//! This is the daemon (dproto) analogue of the single-host [`crate::client`]:
//! it `Attach{instance}`es, streams that instance's `Output` to stdout, forwards
//! stdin as `Input{instance}`, tracks SIGWINCH -> `Resize{instance}` so the
//! contained process reflows to the pane, and **detaches on Ctrl-\ without
//! killing the child**. Async events for OTHER instances (or control replies)
//! are ignored so multiple single-agent panes can share one daemon.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;

use anyhow::{Context, Result};

use crate::client::AttachOutcome;
use crate::dproto::{self, CtlMsg, CtlReply};
use crate::termios::{current_winsize, RawGuard};

/// Byte that triggers a clean detach (Ctrl-\, aka FS / 0x1c).
const DETACH_BYTE: u8 = 0x1c;

/// Attach to a single daemon agent `instance` at `socket_path`, driving the
/// local terminal until the user detaches (Ctrl-\) or the child exits.
pub fn attach_instance(socket_path: &std::path::Path, instance: &str) -> Result<AttachOutcome> {
    let stream = UnixStream::connect(socket_path)
        .with_context(|| format!("connect to daemon socket {socket_path:?}"))?;
    let mut write_stream = stream.try_clone().context("clone socket")?;
    let read_stream = stream;

    // Raw mode so keystrokes pass through untouched.
    let _raw = RawGuard::enable().context("enable raw mode")?;

    // Attach + initial Resize to match our window.
    dproto::write_ctl_msg(&mut write_stream, &CtlMsg::Attach { instance: instance.into() })?;
    if let Some((rows, cols)) = current_winsize() {
        dproto::write_ctl_msg(
            &mut write_stream,
            &CtlMsg::Resize { instance: instance.into(), rows, cols },
        )?;
    }

    let child_exit = Arc::new(AtomicI32::new(i32::MIN));
    let done = Arc::new(AtomicBool::new(false));

    install_sigwinch_handler();

    // Reader thread: daemon -> stdout / handle control frames, filtered to our
    // instance. Screen frames + other instances' events are ignored (raw
    // passthrough relies on Output).
    let reader = {
        let child_exit = Arc::clone(&child_exit);
        let done = Arc::clone(&done);
        let mut read_stream = read_stream;
        let want = instance.to_string();
        std::thread::spawn(move || {
            let mut out = std::io::stdout();
            loop {
                match dproto::read_ctl_reply(&mut read_stream) {
                    Ok(Some(CtlReply::Output { instance, data })) if instance == want => {
                        let _ = out.write_all(&data);
                        let _ = out.flush();
                    }
                    Ok(Some(CtlReply::ChildExited { instance, code })) if instance == want => {
                        child_exit.store(code, Ordering::SeqCst);
                        done.store(true, Ordering::SeqCst);
                        break;
                    }
                    // Screen/StartupReady/StartupBlocked/ScreenChanged/other
                    // instances / control replies: ignore in raw passthrough.
                    Ok(Some(_)) => {}
                    Ok(None) | Err(_) => {
                        done.store(true, Ordering::SeqCst);
                        break;
                    }
                }
            }
        })
    };

    // stdin reader thread -> channel (portable non-blocking).
    let mut stdin = std::io::stdin();
    let mut buf = [0u8; 4096];
    let (in_tx, in_rx) = std::sync::mpsc::channel::<Vec<u8>>();
    {
        let done = Arc::clone(&done);
        std::thread::spawn(move || loop {
            if done.load(Ordering::SeqCst) {
                break;
            }
            match stdin.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if in_tx.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        });
    }

    let outcome = loop {
        if done.load(Ordering::SeqCst) {
            let code = child_exit.load(Ordering::SeqCst);
            if code != i32::MIN {
                break AttachOutcome::ChildExited(code);
            }
            break AttachOutcome::Disconnected;
        }
        // Pending resize from SIGWINCH.
        if take_sigwinch() {
            if let Some((rows, cols)) = current_winsize() {
                let _ = dproto::write_ctl_msg(
                    &mut write_stream,
                    &CtlMsg::Resize { instance: instance.into(), rows, cols },
                );
            }
        }
        match in_rx.recv_timeout(std::time::Duration::from_millis(100)) {
            Ok(chunk) => {
                if let Some(pos) = chunk.iter().position(|&b| b == DETACH_BYTE) {
                    // Forward bytes before the detach byte, then detach.
                    if pos > 0 {
                        let _ = dproto::write_ctl_msg(
                            &mut write_stream,
                            &CtlMsg::Input {
                                instance: instance.into(),
                                data: chunk[..pos].to_vec(),
                            },
                        );
                    }
                    let _ = dproto::write_ctl_msg(
                        &mut write_stream,
                        &CtlMsg::Detach { instance: instance.into() },
                    );
                    break AttachOutcome::Detached;
                }
                let _ = dproto::write_ctl_msg(
                    &mut write_stream,
                    &CtlMsg::Input { instance: instance.into(), data: chunk },
                );
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                if done.load(Ordering::SeqCst) {
                    let code = child_exit.load(Ordering::SeqCst);
                    if code != i32::MIN {
                        break AttachOutcome::ChildExited(code);
                    }
                }
                break AttachOutcome::Disconnected;
            }
        }
    };

    done.store(true, Ordering::SeqCst);
    let _ = reader.join();
    Ok(outcome)
}

// ---- SIGWINCH plumbing (shares the FFI in termios.rs) -------------------

static SIGWINCH_FLAG: AtomicBool = AtomicBool::new(false);

extern "C" fn sigwinch_handler(_sig: i32) {
    SIGWINCH_FLAG.store(true, Ordering::SeqCst);
}

fn install_sigwinch_handler() {
    unsafe {
        libc_signal(libc_sigwinch(), sigwinch_handler as *const () as usize);
    }
}

fn take_sigwinch() -> bool {
    SIGWINCH_FLAG.swap(false, Ordering::SeqCst)
}

use crate::termios::{libc_signal, libc_sigwinch};
