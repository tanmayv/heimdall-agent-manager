# Shared browser profile

`HEIMDALL_BROWSER_PROFILE_DIR` is the bridge's absolute browser data directory
for its current registration. Agent launches and managed shell sessions inherit
the same path. A restart leaves it in place. A different registration uses a
different directory, even with the same configured data root. If the value is
empty or absent, report **profile unavailable** and stop. Don't substitute the
user's regular profile or a temporary profile. The bridge rejects symlinks in
the configured data root itself and the managed directories below it, as well
as junctions and unsafe permissions. On Unix, a root-owned alias in a protected
parent above the data root, such as Fedora Atomic's `/home`, is resolved and the
resulting path is checked before use.

## Launch and reuse

- Use an installed compatible browser, the advertised directory and the same
  OS account, browser family and cookie encryption backend used for setup.
  Chromium calls this directory its **user data directory**, not its individual
  `Default` profile directory. Check the application's signed-in account before
  reusing its session.
- Launch headed when the child has a working graphical session. On Linux,
  verify a connection to its inherited Wayland or X11 session. A nonempty
  `DISPLAY` or `WAYLAND_DISPLAY` is not a connection check. macOS needs an active
  Aqua login for the launch user. Windows needs an interactive desktop in the
  same user session. Don't copy or synthesize another user's session credentials.
- On Linux, the bridge forwards nonempty desktop and session-bus variables.
  Explicit shell session values take precedence, including an explicit empty
  value. Absent or empty bridge values leave the launch environment alone.
- Without a usable desktop, use the browser's supported headless mode on the
  **same** profile only for already-authenticated work. If interactive sign-in
  is needed, report **display required**. Don't attempt sign-in in a disposable
  profile. Report any graphical initialization failure that led to this check.
- Keep the original unlocked OS cookie store reachable. On Linux this means the
  same Secret Service or KWallet backend and matching DBus session. On macOS
  keep the login Keychain accessible. On Windows retain the original
  user/DPAPI context. If the backend is unavailable, report **session
  unavailable** and ask for it to be restored. Don't switch password-store
  backends or overwrite the profile to recover access.

## Busy and cleanup

Let the browser enforce its native exclusive profile lock. Treat both a
lock/in-use error and a launch that hands off to an existing browser process as
**busy**. A zero exit status after handoff doesn't establish ownership. Require
a new browser instance owned by this operation before navigating to a target or
interacting with any window or tab. Launch with a blank page when probing for
ownership. A launcher crash doesn't release a still-running browser's
lock. Never delete native lock files, copy cookies, or attach to a browser
owned by another invocation. Close only the browser you launched.

Agents on one registration share authenticated access as the same OS account.
Never attach the profile, cookies or diagnostics containing session data to an
artifact, transcript or agent-shared backup. Browser logout or owner cleanup
revokes local reuse independently of the credential vault.
