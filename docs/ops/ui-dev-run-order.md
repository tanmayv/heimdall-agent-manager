# UI dev-run order: `ham-hub` ← `ham-dev-proxy` ← UI dev server / Electron

How to run the rewritten Heimdall UI in dev so that it obtains trusted-proxy
identity the same (and only) way the Hub permits it for browsers — from
`ham-dev-proxy`, the reverse proxy running inside the Hub's
`--trusted-proxy-cidr`. Satisfies **UI-19** / **HBR-5** / **HBR-6** (task
`task-19f97da6817`).

> Invariant: the UI (renderer **and** Electron main) MUST NOT set
> `X-authentik-username` / `-name` / `-email` headers itself. Only the proxy
> inside the trusted CIDR may inject them; otherwise any client could spoof a
> Hub identity and defeat HBR-5. The previous Electron
> `session.defaultSession.webRequest.onBeforeSendHeaders` injection hack has
> been removed for this reason.

## Topology

```
ham-hub (127.0.0.1:8081, --trusted-proxy-cidr 127.0.0.1/32)
   ▲
   │ forwards X-authentik-* (server-side) from selected dev user
   │
ham-dev-proxy (127.0.0.1:8080, hub_url=http://127.0.0.1:8081)
   ▲
   │ Vite dev-server proxy: /api/v1, /_dev/login, /_dev/logout
   │
UI dev server (Vite, 127.0.0.1:5173)  ◄── renderer + Electron load this origin
```

- **ham-hub** listens on `127.0.0.1:8081` (default; override with
  `--listen <host:port>` or `--port <n>`). It trusts the loopback CIDR by
  default (`trusted_proxy_cidrs = ["127.0.0.1/32"]`).
- **ham-dev-proxy** listens on `127.0.0.1:8080` (default; `--listen`), forwards
  to `hub_url = http://127.0.0.1:8081`, and rewrites client headers into
  `X-authentik-*` from the selected dev user (`tanmay` / `reviewer` by default).
  Bearer `Authorization` is passed through unchanged.
- **Vite dev server** on `127.0.0.1:5173` proxies the trusted-proxy surface to
  `ham-dev-proxy` (see `vite.config.js` `server.proxy`). Override the upstream
  proxy with `HEIMDALL_DEV_PROXY_URL` if your `ham-dev-proxy` listens elsewhere.
- The renderer's rewrite `/api/v1` requests use **relative** paths
  (`/api/v1/...`) with `credentials: 'include'`, so in dev they resolve to the
  Vite origin and are forwarded to the proxy with the `ham_dev_user` cookie
  attached (same-origin).

> The **legacy** daemon session (the old `49322` daemon via `daemonApi`) is a
> separate, absolute-URL path and is unaffected by this routing; its UI default
> remains `http://127.0.0.1:49322`.

## Start order

From the worktree root, in three terminals (or a process manager):

```bash
# 1. Hub — bind loopback, trust loopback proxy CIDR, provision dev users.
nix run .#hub -- --listen 127.0.0.1:8081 \
                 --db ./hub.db \
                 --trusted-proxy-cidr 127.0.0.1/32
# (--migrations-dir is injected automatically by the `hub` app wrapper.)

# 2. Dev proxy — inside the trusted CIDR; injects trusted headers server-side.
nix run .#dev-proxy   # listens 127.0.0.1:8080, forwards to 127.0.0.1:8081

# 3. UI — Vite dev server (proxies /api/v1 + /_dev/* to :8080) + Electron.
npm run dev
```

`npm run dev` builds the Electron main (`build:electron`), starts Vite on
`127.0.0.1:5173`, and launches Electron against the Vite origin once it is up.
The renderer's relative `/api/v1` traffic is proxied by Vite to
`ham-dev-proxy`, which adds `X-authentik-*` from the active dev user.

> Browser-only dev (no Electron): `npm run dev` still works; open
> `http://127.0.0.1:5173` in a browser. Packaged-mode (`npm run build`) loads
> `dist/index.html` and is out of scope for this dev harness.

## Switching the dev user (dev login)

Dev login is driven by the proxy's `/_dev/login` cookie flow (HBR-6), not by
any client-side header. To act as a different user, set the `ham_dev_user`
cookie via the proxy:

```bash
# Select 'reviewer' (must be a known dev user; default roster: tanmay, reviewer).
curl -i http://127.0.0.1:8080/_dev/login?user=reviewer
# → Set-Cookie: ham_dev_user=reviewer; Path=/; SameSite=Lax
```

From the SPA/Electron renderer (same-origin through the Vite proxy), navigate
or fetch:

```bash
# Through Vite (renderer origin 5173, same-origin cookie):
curl -i --cookie-jar /tmp/c.txt http://127.0.0.1:5173/_dev/login?user=reviewer
curl -s --cookie /tmp/c.txt http://127.0.0.1:5173/api/v1/me
```

To log out (clears the cookie):

```bash
curl -i http://127.0.0.1:8080/_dev/logout
# (or via Vite origin: http://127.0.0.1:5173/_dev/logout)
```

Per-request override: `ham-dev-proxy` honors an `X-Dev-User` header or the
`ham_dev_user` cookie over the default user, but only the proxy may translate
those into `X-authentik-*`. An unauthenticated hit against the Hub **directly**
(bypassing the proxy) returns the unauthenticated state — there is no auto-`admin`
identity without the proxy.

## Smoke check

```bash
# Direct Hub hit (no proxy) → unauthenticated.
curl -s http://127.0.0.1:8081/api/v1/me | head   # no trusted headers → not authenticated

# Through the proxy → authenticated as the active dev user.
curl -s --cookie-jar /tmp/c.txt http://127.0.0.1:8080/_dev/login?user=tanmay
curl -s --cookie /tmp/c.txt http://127.0.0.1:8080/api/v1/me   # authenticated as tanmay
```

## Notes / gotchas

- **CIDR must stay narrow.** `127.0.0.1/32` only. A broad CIDR (e.g.
  `0.0.0.0/0`) lets any client spoof `X-authentik-*` headers.
- **Bearer passthrough is intact.** `ham-dev-proxy` forwards `Authorization`
  unchanged, so `ham-ctl hub` / `ham-ctl agent` (CLI) are unaffected.
- **Offline dev-server work.** Vite at `5173` still starts without the
  proxy/Hub for renderer-only work; only `/api/v1` traffic requires the proxy.
- **RTE2E-9.** This dev harness touches `src/ui/electron/main.cts`,
  `vite.config.js`, `src/ui/store/chatSlice.ts`, and this doc only. The old
  current-daemon `src/wrapper` and `src/ctl` are untouched.
