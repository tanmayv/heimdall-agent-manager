# ham-hub-proxy

A dumb, single-purpose **TLS re-origination proxy**. It lets a `ham-bridge` that can
only reach a **local plaintext port** talk to a **remote HTTPS hub** (e.g.
`hub.mundus.in`) that is only reachable while an SSH tunnel is up.

## Why it exists

The bridge derives everything from one base URL (`--hub`):
- `http://…` → plaintext TCP + `ws://`
- `https://…` → TLS (SNI) + `wss://`

If a VM cannot reach the hub directly (no direct egress; only an SSH tunnel back to
your machine), point the bridge at a **local `http://`** URL and let this proxy add
TLS and forward to the real hub — on a machine that *can* reach it.

A pure TCP byte-pipe does **not** work, because the hub's edge vhost-matches on the
`Host` header (a wrong hostname → HTTP 403; the port is ignored). So the proxy
rewrites the first request head's `Host` to the upstream hostname, then becomes a
transparent bidirectional pipe (which carries the WebSocket upgrade + frames
unchanged, since the bridge uses `Connection: close` for HTTP and a single
long-lived stream for `/api/v1/bridge-ws`).

TLS is delegated to `openssl s_client` (the same mechanism the bridge itself uses) —
no in-process TLS stack.

## Topology

```
[VM]  ham-bridge --hub http://127.0.0.1:8090        (plaintext, no TLS on the VM)
        │
        │  reverse tunnel, opened FROM your machine:
        │  ssh -R 8090:127.0.0.1:8090 <vm>
        ▼
[your machine]  ham-hub-proxy --listen 127.0.0.1:8090 --upstream https://hub.mundus.in
        │  TLS + SNI=hub.mundus.in, Host: rewritten to hub.mundus.in
        ▼
      hub.mundus.in:443
```

When the SSH tunnel drops, the VM's bridge just gets connection-refused on
`127.0.0.1:8090` and retries with its normal backoff — no special handling needed.

## Build

```sh
nix build .#ham-hub-proxy
# -> ./result/bin/ham-hub-proxy  (openssl bundled on PATH)
```

## Run

On the machine that can reach the hub:

```sh
ham-hub-proxy --listen 127.0.0.1:8090 --upstream https://hub.mundus.in
# add --verbose to log each forwarded request line
```

Then, from that same machine, open the reverse tunnel to the VM:

```sh
ssh -R 8090:127.0.0.1:8090 <vm>
```

On the VM, run the bridge against the local plaintext port:

```sh
ham-bridge --hub http://127.0.0.1:8090 --bridge-token-file <path> ...
```

### Flags

- `--upstream https://<host>[:port]` (required) — the real hub. `http://` is rejected
  (this proxy exists to *add* TLS). Port defaults to 443.
- `--listen <host:port>` — where to accept the bridge's plaintext connection
  (default `127.0.0.1:8090`).
- `--verbose` — log each request's first line.
- `HAM_TLS_CA_FILE=<path>` (env) — passed to `openssl -CAfile` for a custom CA.

## Notes / limits

- It rewrites **only** the `Host` header hostname; everything else (path, method,
  `Authorization: Bearer`, WebSocket headers, body) passes through untouched.
- It assumes one logical request per TCP connection (true for the bridge:
  `Connection: close` for HTTP, one long-lived stream for the WS). It is not a
  general-purpose HTTP/1.1 keep-alive proxy.
- Verified end-to-end against `hub.mundus.in`: plaintext `GET /api/v1/health` →
  `200`, and a `GET /api/v1/bridge-ws` upgrade → `101 Switching Protocols`.
