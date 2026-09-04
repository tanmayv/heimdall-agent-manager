//! Local-terminal control for the `attach` client (REQ PTYH-2): raw mode + the
//! current window size + SIGWINCH handling. All the libc FFI lives here.

use std::os::unix::io::RawFd;

use anyhow::{Context, Result};

const STDIN_FD: RawFd = 0;

/// RAII guard that puts the terminal in raw mode and restores it on drop.
pub struct RawGuard {
    fd: RawFd,
    original: libc::termios,
    restored: bool,
}

impl RawGuard {
    /// Enable raw mode on stdin. Restores automatically when the guard drops.
    pub fn enable() -> Result<RawGuard> {
        unsafe {
            let mut original: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(STDIN_FD, &mut original) != 0 {
                return Err(std::io::Error::last_os_error())
                    .context("tcgetattr (not a tty?)");
            }
            let mut raw = original;
            libc::cfmakeraw(&mut raw);
            if libc::tcsetattr(STDIN_FD, libc::TCSANOW, &raw) != 0 {
                return Err(std::io::Error::last_os_error()).context("tcsetattr raw");
            }
            Ok(RawGuard {
                fd: STDIN_FD,
                original,
                restored: false,
            })
        }
    }

    pub fn restore(&mut self) {
        if !self.restored {
            unsafe {
                libc::tcsetattr(self.fd, libc::TCSANOW, &self.original);
            }
            self.restored = true;
        }
    }
}

impl Drop for RawGuard {
    fn drop(&mut self) {
        self.restore();
    }
}

/// The current terminal window size as (rows, cols), if stdout is a tty.
pub fn current_winsize() -> Option<(u16, u16)> {
    unsafe {
        let mut ws: libc::winsize = std::mem::zeroed();
        if libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) == 0 && ws.ws_row > 0 {
            Some((ws.ws_row, ws.ws_col))
        } else {
            None
        }
    }
}

// ---- thin FFI shims used by client.rs -----------------------------------

/// SIGWINCH constant.
pub fn libc_sigwinch() -> i32 {
    libc::SIGWINCH
}

/// Install a C signal handler (`signal(sig, handler)`).
///
/// # Safety
/// `handler` must be a valid `extern "C" fn(i32)` cast to `usize`.
pub unsafe fn libc_signal(sig: i32, handler: usize) {
    unsafe {
        libc::signal(sig, handler);
    }
}
