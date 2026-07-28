# Heimdall Dev Proxy — Identity Manager

`ham-dev-proxy` is a **local-development-only** reverse proxy that sits between
the UI/Electron app and `ham-hub`. It lets a developer switch which dev user
identity is forwarded to the Hub without running a real Authentik instance: it
injects the selected user's trusted-proxy headers (`X-authentik-*`) on every
proxied request.

> ⚠️ **Local development only.** This tool intentionally spoofs trusted
> identity headers. The entire `/_dev/` management surface is a hard security
> boundary that is served **only on a loopback bind** (see
> [Loopback-only boundary](#loopback-only-boundary)).

## Dev-run order

```
UI / Electron  →  ham-dev-proxy (127.0.0.1:8080)  →  ham-hub (--trusted-proxy-cidr 127.0.0.1/32)
```

1. **Hub** — run with the loopback trusted-proxy CIDR so it accepts the
   spoofed `X-authentik-*` headers coming from the dev proxy:
   ```sh
   ham-hub --trusted-proxy-cidr 127.0.0.1/32
   ```
2. **Dev proxy** — bind on loopback and forward to the Hub:
   ```sh
   ham-dev-proxy --listen 127.0.0.1:8080 --hub-url http://127.0.0.1:8081
   ```
   Flags: `--listen <host:port>`, `--hub-url <url>`, `--default-user <name>`.
3. **UI / Electron** — point the app at the dev proxy address
   (`http://127.0.0.1:8080`), not at the Hub directly.

## Managing dev users

There are two equivalent ways to manage dev users; both hit the same loopback
management API.

### Web UI

Open <http://127.0.0.1:8080/_dev/> in a browser. From there you can:

- **List** the current dev users (the active one is highlighted with a badge).
- **Use** a user — makes it the active identity (sets the `ham_dev_user`
  cookie and persists the selection across restarts).
- **Create** a new dev user via the form (username is required).
- **Delete** a user (deleting the active user also clears the selection).

The page is a single self-contained HTML document (inline CSS/JS, no external
dependencies, no build step).

### JSON API

| Method | Path                       | Body                                            | Effect                                                          |
|--------|----------------------------|-------------------------------------------------|-----------------------------------------------------------------|
| GET    | `/_dev/api/users`          | —                                               | Returns `{ "users": [...], "active": "<name>" \| null }`.       |
| POST   | `/_dev/api/users`          | `{ "username", "display_name", "email" }`       | Creates a user. `409` on duplicate/empty username.              |
| DELETE | `/_dev/api/users/<name>`   | —                                               | Removes a user (`204`). Clears active if it was selected.       |
| POST   | `/_dev/api/active`         | `{ "username": "<name>" }`                      | Sets the active user + sets the `ham_dev_user` cookie.          |
| GET    | `/_dev/login?user=<name>`  | —                                               | Legacy cookie login (sets `ham_dev_user`). `400` if unknown.    |
| GET    | `/_dev/logout`             | —                                               | Clears the `ham_dev_user` cookie.                               |

Example:

```sh
# create a dev user, then select it
curl -X POST http://127.0.0.1:8080/_dev/api/users \
  -H 'Content-Type: application/json' \
  -d '{"username":"erin","display_name":"Erin","email":"erin@example.com"}'
curl -X POST http://127.0.0.1:8080/_dev/api/active \
  -H 'Content-Type: application/json' -d '{"username":"erin"}'
```

### Default users

A fresh store ships with two seeded dev users (see `src/dev_proxy/users.odin`):

| username  | display_name    | email                  |
|-----------|-----------------|------------------------|
| `tanmay`  | Tanmay Vijay    | tanmay@example.com     |
| `reviewer`| Reviewer User   | reviewer@example.com   |

The default active user is `tanmay` unless changed.

## How identity selection works

For each proxied request, the dev proxy selects the dev user by precedence:

1. `X-Dev-User` request header (highest priority)
2. `ham_dev_user` cookie
3. persisted active user
4. `default-user` config (fallback: `tanmay`)

The selected user's `X-authentik-username` / `X-authentik-name` /
`X-authentik-email` are then **injected** into the forwarded request.

## Loopback-only boundary

The `/_dev/` management surface (UI, `/_dev/api/*`, `/_dev/login`,
`/_dev/logout`) is served **only when `--listen` is a loopback address**
(`127.0.0.1` or `::1`). On any other bind (e.g. `0.0.0.0`), every `/_dev/*`
route returns `404 Not Found` and the management routes are entirely disabled.
This is enforced before any handler runs, so the management API cannot be
reached remotely regardless of request shape.

## Forwarding invariants (DP-6)

The dev proxy preserves the following on every forwarded request:

- **Bearer tokens pass through unchanged.** `Authorization: Bearer hut_…` /
  `hbr_…` / `hbe_…` are forwarded exactly as received.
- **Spoofable trusted headers are stripped.** Any client-supplied
  `X-authentik-username`, `X-authentik-name`, `X-authentik-email`, or
  `X-Dev-User` is removed — only the selected dev user's real fields are
  injected (HBR-6). A client cannot impersonate an arbitrary user by setting
  these headers.
- **Management paths are never forwarded.** `/_dev/`, `/_dev/api/*`,
  `/_dev/login`, and `/_dev/logout` are answered locally and never reach the
  Hub.

These invariants are locked in by
`tests/test_ham_dev_proxy_forwarding_invariants.py`.
