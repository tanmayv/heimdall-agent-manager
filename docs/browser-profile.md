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
- Launch headless by default so the shared browser does not depend on desktop
  focus or a graphical session. A step that requires direct desktop interaction
  needs a working display and the owner's coordination. Do not replace an
  already-running shared browser to switch modes.
- On Linux, the bridge forwards nonempty desktop and session-bus variables.
  Explicit shell session values take precedence, including an explicit empty
  value. Absent or empty bridge values leave the launch environment alone.
- If direct desktop interaction is needed without a usable display, report
  **display required**. Don't attempt sign-in in a disposable profile or copy
  another user's desktop session credentials.
- Keep the original unlocked OS cookie store reachable. On Linux this means the
  same Secret Service or KWallet backend and matching DBus session. On macOS
  keep the login Keychain accessible. On Windows retain the original
  user/DPAPI context. If the backend is unavailable, report **session
  unavailable** and ask for it to be restored. Don't switch password-store
  backends or overwrite the profile to recover access.

## Attach, launch, and reuse

`HEIMDALL_BROWSER_CDP_PORT` is fixed per bridge. By default it is derived from
the profile path, and the bridge can override it with `browser_cdp_port`. Never
assume a common port such as 9222. The endpoint must stay local to the bridge.

1. Probe `http://127.0.0.1:$HEIMDALL_BROWSER_CDP_PORT/json/version`. On the
   browser WebSocket at the same address and port, call
   `Browser.getBrowserCommandLine`. Require exactly one `--user-data-dir`
   argument matching `HEIMDALL_BROWSER_PROFILE_DIR`. If the listener exists
   but cannot be verified, stop without attaching or launching.
2. If no listener exists, start Chromium with a blank tab, `--headless=new`,
   `--enable-automation`, `--remote-debugging-address=127.0.0.1`,
   `--remote-debugging-port="$HEIMDALL_BROWSER_CDP_PORT"` and
   `--user-data-dir="$HEIMDALL_BROWSER_PROFILE_DIR"`.
3. If the profile is busy or Chromium hands off to an existing process,
   retry the probe and profile check on the same endpoint. A zero launch exit
   after handoff does not establish ownership. If the configured endpoint
   cannot be verified, report the blocker. Never remove lock files.
4. Configure the agent's MCP server to run pinned
   `npx -y @playwright/mcp@0.0.86 --cdp-endpoint` with the verified endpoint
   as its next argument. Expand the bridge port in the configuration. No
   launcher helper or global install is needed.

Use only your own tab. Leave the shared browser running, including when you
launched it. Never close another tab or the shared browser. For confidential
input, use the secure-form script in the [credential and browser skill](../src/prompts/skills/credential-and-browser-use/SKILL.md).
Do not type or fill secrets through Playwright MCP.

Agents on one registration share authenticated access as the same OS account.
Never attach the profile, cookies or diagnostics containing session data to an
artifact, transcript or agent-shared backup. Browser logout or owner cleanup
revokes local reuse independently of the credential vault.
