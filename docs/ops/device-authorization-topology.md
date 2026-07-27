# Device authorization deployment topology

This document describes the production topology for the Electron device-authorization flow (ELDA-7) and the security invariants tested by the device-auth matrix (ELDA-6).

## Actors and trust boundary

- **Electron app** is a public client. Before login it has no Hub bearer token and must not be sent through an interactive Authentik/outpost redirect.
- **Hub API** serves `/api/v1/...` and validates either public device endpoints, trusted-proxy browser identity, or `Authorization: Bearer hut_...` user API tokens.
- **Browser + Authentik outpost** owns human login and approval. The browser approval endpoints are trusted-proxy-authenticated; the approver identity comes only from outpost-injected headers.

Electron never supplies owner identity. It only receives a token after the browser approval endpoint binds `owner_user_id` from the trusted-proxy `Auth_Context`.

## Required path split

| Path | Caller | Auth requirement | Notes |
|---|---|---|---|
| `POST /api/v1/device/authorize` | Electron | Public, rate-limited | Creates pending grant; records display-only device fields and request IP. |
| `POST /api/v1/device/token` | Electron | Public, rate-limited | Polls with `device_code`; returns `pending`, `approved`, `denied`, `expired`, or `slow_down` with `Retry-After`. |
| `GET /api/v1/device` | Browser | Trusted proxy | Standalone typed-code approval page. |
| `POST /api/v1/device/verify` | Browser | Trusted proxy, per-IP attempt cap | Shows captured device details for `user_code`; generic invalid/expired errors. |
| `POST /api/v1/device/approve` | Browser | Trusted proxy | Binds owner from trusted proxy headers; records approver IP/UA/timestamp; approves or denies. |
| Other `/api/v1/...` | Electron after approval | `Authorization: Bearer hut_...` | Electron task 4 injects bearer from `safeStorage`; no trusted headers. |

## Supported deployment patterns

### Pattern A: two hostnames (recommended)

- `api.heimdall.example` → TLS terminator → Hub.
  - Public/bearer API hostname for Electron.
  - Must allow `POST /api/v1/device/authorize`, `POST /api/v1/device/token`, and bearer-authenticated `/api/v1/...`.
- `app.heimdall.example` → Authentik outpost → Hub.
  - Browser approval/app hostname.
  - Enforces outpost auth on `/api/v1/device`, `/api/v1/device/verify`, `/api/v1/device/approve`, and browser app routes.

Configure Hub so device authorization responses return the browser/outpost URL as the verification URI, while Electron uses the API hostname as its base URL:

```bash
ham-hub \
  --listen 127.0.0.1:8081 \
  --trusted-proxy-cidr <outpost-or-reverse-proxy-cidr> \
  --device-auth-verification-uri https://app.heimdall.example/api/v1/device
```

Configure Electron with the public API URL:

```bash
HEIMDALL_HUB_API_URL=https://api.heimdall.example npm run dev
```

`src/ui/electron/main.cts` also accepts `HEIMDALL_HUB_URL`; `HEIMDALL_HUB_API_URL` is preferred for clarity.

### Pattern B: one hostname with outpost path bypass

`heimdall.example` fronts both browser and API traffic. The outpost/reverse proxy must:

1. Bypass interactive auth for:
   - `POST /api/v1/device/authorize`
   - `POST /api/v1/device/token`
   - `/api/v1/...` requests that already carry `Authorization: Bearer hut_...`
2. Enforce trusted-proxy auth for:
   - `GET /api/v1/device`
   - `POST /api/v1/device/verify`
   - `POST /api/v1/device/approve`
   - browser app routes
3. Forward the configured trusted identity headers only from the outpost/proxy, never from clients.

## Trusted X-Forwarded-For requirement

Hub trusts `X-Forwarded-For` only when the TCP peer (`req.remote_addr`) is inside `--trusted-proxy-cidr`. In that case the first XFF hop is used as the client IP for grant display, rate limiting, and approve/deny audit. If the TCP peer is not trusted, XFF is ignored and `remote_addr` is used.

Operational checks:

```bash
# Hub should trust only the reverse proxy/outpost source network.
ham-hub --trusted-proxy-cidr 127.0.0.1/32  # local dev proxy example

# Public Electron requests must not need outpost cookies.
curl -i https://api.heimdall.example/api/v1/device/authorize \
  -H 'Content-Type: application/json' \
  --data '{"client":"heimdall-electron","device_label":"Ops laptop"}'

# Browser approval paths should reject direct/untrusted access without proxy headers.
curl -i https://api.heimdall.example/api/v1/device/verify \
  -H 'Content-Type: application/json' \
  --data '{"user_code":"ABCD-2345"}'
```

## Audit and revocation

Approve/deny decisions are recorded on the in-memory grant while the flow is live:

- `owner_user_id` from trusted-proxy auth context;
- `approver_ip` from trusted XFF resolution;
- `approver_ua` from `User-Agent`;
- `device_label`, `client`, and `decided_at`.

Approved flows also mint a normal user API token with:

- `created_from = "device_authorization"`;
- `device_label = <authorized device label>`;
- no single-active revocation and no per-user cap.

Operators can inspect durable token provenance and revoke any device token:

```bash
ham-hub tokens list --user <user_id>
ham-hub tokens revoke --token-id <utok_...>
```

## Development defaults

The Nix `.#hub` app defaults to Hub on `127.0.0.1:8081` and bundled migrations. The `.#dev-proxy` app defaults to `127.0.0.1:8080` forwarding to Hub and injecting trusted identity headers for browser/dev flows. For Electron device auth, prefer pointing Electron at the public Hub API (`HEIMDALL_HUB_API_URL=http://127.0.0.1:8081`) and keep browser verification routed through the returned `verification_uri`.

## Security invariants

The task test matrix locks in these invariants:

- client-supplied `owner_user_id` / `user` fields in approve bodies are ignored;
- XFF is honored only from trusted CIDRs;
- `user_code` verification has a per-IP brute-force cap and recovers after cooldown;
- public authorize/token endpoints are rate-limited;
- device grants are single-use and terminal;
- unknown `device_code` polls return `pending` to prevent enumeration;
- generated `device_code` and `user_code` are independent/unlinkable;
- Electron code contains no client-side trusted-header injection.
