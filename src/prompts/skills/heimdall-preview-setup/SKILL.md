---
name: heimdall-preview-setup
description: How to share a web app or API you are running on localhost (dev server, prod build, backend) with the user through Heimdall, so they can open it in the Heimdall preview sidebar or on their phone: `ham-ctl shell serve --port`, presenting the hub-returned `preview_url` verbatim, making apps work under the preview path prefix, frontend and backend on different machines, and troubleshooting blank or stopped previews. Load whenever you want the user to see, click through or test something you started locally. Never send a localhost URL.
---

# Share a local web app through Heimdall

The user, often on a phone or another machine, cannot open `http://localhost:<port>` on your machine. Start a port-declared server session (session kinds, `--cwd`, ports: `shell-sessions`) and give them the `preview_url` the Hub returns.

## Start and share
1. Build the frontend for production and serve that with its preview/static server. A dev server's many module requests and dev-only WebSocket assumptions are fragile through the tunnel.
2. Bind to `127.0.0.1` (Heimdall also falls back to `::1`, but IPv4 loopback is predictable).
3. Start it as a managed session, declaring the same port:
   ```bash
   ham-ctl shell serve --cmd 'npm run preview -- --host 127.0.0.1 --port 4173' \
     --port 4173 --cwd /absolute/path/to/app
   ```
   `--port` is optional for a server session but required to make it previewable. The Hub exposes the session to its owner without opening an inbound port on the machine, and it works with the Hub on a different host.
4. Send the user the link the Hub gives you, **verbatim**. `shell serve` (and `ham-ctl shell show <sid>`, any time later) prints `Preview: https://heimdall-preview.example.com/p/sh_18dd.../`; it is also the `preview_url` field of the session JSON. The Hub builds it from its own `--preview-origin` configuration, so never build a URL from `server_port` or the session id, and never send a localhost URL. No `Preview:` line means the session has no declared port: start it with `--port` (or `shell set-port`). The user also sees the session's captured **Stdout** in the session pane.

The URL has one of two forms; both keep a session path prefix, so every rule below applies to both:
- **Preview origin configured:** `<preview_origin>/p/<sid>/`. Isolated from the Hub origin and protected by its own sign-in: the Hub mints a host-only `__Host-heimdall_preview` cookie for the user's Hub session (an unauthenticated navigation bounces through the Hub and back). If the iframe asks for authentication, tell the user to click **Sign in / open in new tab** once.
- **Legacy mode:** `<ui_origin>/api/v1/preview/<sid>/`. Shares the Hub origin, so JavaScript runs with the user's Hub-origin privileges: preview only trusted code.

## Frontend checklist
- Emit document-relative assets: Vite `base: './'`, Create React App `"homepage": "."`, Angular `<base href="./">`. Next.js `basePath` is build-time and holds the session-specific prefix, so prefer a proxy/BFF or a setup that accepts the runtime prefix.
- Call same-app endpoints with document-relative URLs (`fetch('api/items')`, `fetch('./api/items')`), not root-relative `/api/items`. Never call `http://localhost:<port>` from browser JavaScript: on a phone, `localhost` is the phone.
- Serve the production build (`vite build && vite preview --host 127.0.0.1`, or `npx serve -s dist -l 4173`).
- Use hash routing, or make the upstream SPA fallback return the app shell for a refresh below the prefix. A path-routed app reads `location.pathname` and sees the prefix; the preview URL has no hash, so an app that falls back to the real pathname when the hash is empty (Heimdall's own UI, `src/ui/utils/appLocation.ts`) must seed it first (`location.replace(location.pathname + '#/')`) before app code runs.
- Do not emit `X-Frame-Options: DENY` or CSP `frame-ancestors 'none'` if the app must render in the sidebar.

## Backend behavior through the tunnel
The Hub strips the session prefix and does **not** rewrite HTML, so the process sees ordinary root-relative paths while the browser sees the prefix; that asymmetry causes every prefix problem. The upstream receives its original method, path below the prefix, query and body, with `Host: 127.0.0.1:<declared-port>` plus `X-Forwarded-Host`, `X-Forwarded-Proto: https`, `X-Forwarded-Prefix` and `X-Forwarded-For`, and, where applicable, browser `Origin`, `Authorization`, common CSRF headers, conditional/content headers and WebSocket negotiation headers.

- **Legacy mode:** `Origin` is the Hub origin, `Cookie` is never forwarded, and `Authorization: Bearer ...` is consumed by the Hub's own authentication (an unknown Bearer token is rejected with `401`), so only non-Bearer schemes such as Basic reach the app. A previewed page is same-origin with the Hub: its own absolute `/api/v1/...` requests go to the **Hub**, authenticated as the viewing user, and never reach your dev server or its proxy.
- **Preview origin:** `Origin` is the preview origin, `Authorization` is left for the app, `OPTIONS` reaches the app, and application cookies are forwarded after all Hub cookies (`__Host-heimdall_*`, legacy `authentik_*`) are removed.
- Hub credentials never reach the app in either mode.
- Use `X-Forwarded-Prefix` when generating absolute URLs, but prefer relative ones. The Hub rewrites root/local `Location` responses under the session prefix, forces each `Set-Cookie` `Path` to it, drops `Domain`, and strips `Service-Worker-Allowed`.
- Telling a dev server that its public base is the prefix fixes the HTML but then 404s the stripped paths the Hub forwards; satisfying both needs a small reverse proxy on the declared port that re-adds the prefix (and relays `Upgrade`, or HMR dies). Prefer a production build.
- For SSE or long polling, emit a heartbeat more often than every 120 seconds (the non-WebSocket relay has a 120-second idle timeout).

## Connect a frontend to a backend
For a backend in the same app/session, use document-relative URLs, ideally with the API behind the frontend server (dev-server proxy, framework rewrite, BFF or SSR handler) so the browser still calls a relative path. For a real remote API called directly by the browser, configure CORS for the actual public origin (`https://<preview-host>` in preview-origin mode, `https://<hub-host>` in legacy mode), with credential settings only if the API needs them.

### Backend on machine A, frontend on machine B, viewed on a phone
Start two port-declared sessions owned by the same Heimdall user: `sidA` (backend, bridge A) and `sidB` (frontend, bridge B). Give the user `sidB`'s `preview_url` verbatim. A session id does not exist until `shell start` returns, and it is not service-discovered or added to the process environment: start the callee first and inject `sidA` into the frontend at runtime (env var, config file, generated markup), or start the caller and bind its port later with `shell set-port`. Choose one pattern:

1. **Browser to backend:** call `/p/<sidA>/api/...` (legacy: `/api/v1/preview/<sidA>/api/...`). Same-origin, so no CORS headers and no preflight is triggered; carries the preview-origin cookie where applicable, owner-checked by the Hub. A relative form also works because every preview has the shape `<prefix>/<sid>/`, with no host, port or Hub name in the page:
   ```js
   // page served at <hub>/api/v1/preview/<FE_SESSION>/
   const api = (p) => new URL(`../${BACKEND_SESSION}/${p}`, location.href).toString();
   ```
2. **Frontend server/BFF/SSR to backend:** on machine B call `http://127.0.0.1:<bridge-B-local_endpoint_port>/proxy/<sidA>/api/...` (find the port with `ham-ctl bridge list --scope configured`); browser code calls a document-relative path such as `api/...`. The same relative form resolves under `/proxy/<session_id>/`, so you can verify a browser flow server-side with `curl` before anyone opens it.

Both sessions must have the same owner. `POST` crosses the tunnel with method and body intact and non-2xx statuses propagate unchanged. Cookies from either app are path-scoped to its own session prefix. Keep the relative-base, production-build and SSE-heartbeat rules above. On the first phone visit the user may need **Sign in / open in new tab** once.

## Diagnose blank or stopped previews
A stopped session stays open and shows status and exit code; **Preview · Stdout** shows its captured output. Check session status and **Stdout** first.

| Symptom | Check and fix |
|---|---|
| Blank page | Open **Stdout**, confirm the session is running, then inspect browser errors. Verify the production server bound the declared port and assets use a relative base. Root-absolute URLs (`/assets/app.js`) resolve against the Hub root, not your session. |
| `404` for `/assets/...` | The build emitted root-absolute paths. Configure `base: './'`, `homepage: "."` or `<base href="./">`, rebuild, restart. |
| `port_closed` | The declared port does not match the listener, or nothing is listening. Bind the exact port to `127.0.0.1`; `::1` is only a fallback. |
| WebSocket `403` | The dev server rejects the public Origin or forwarded Host. Prefer a production build; otherwise allow the public preview/Hub origin and trust the forwarded headers in preview mode. |
| API `401` | Check which mode is active. Legacy strips cookies and cannot carry `Authorization: Bearer` (the Hub consumes or rejects it): use the preview origin, or a frontend proxy/BFF that adds the token server-side. Preview-origin strips only the Hub's own cookies and forwards `Authorization`. Confirm both sessions share an owner. |
| Redirect loop | Trust `X-Forwarded-Proto`, `X-Forwarded-Host` and `X-Forwarded-Prefix`; emit relative redirects when possible. |
| Refused to frame / X-Frame-Options | Remove `X-Frame-Options: DENY` and restrictive `frame-ancestors` for this preview build. |

Never work around an owner check, publish a bridge port, or paste local credentials into frontend code. If the preview contains untrusted dependencies or content, do not open it in legacy mode.
