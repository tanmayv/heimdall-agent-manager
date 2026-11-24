# Webhook ingress

Owner APIs require session/user authentication and the `actions` experiment:

| Method | Path | Result inside the standard API `data` envelope |
| --- | --- | --- |
| GET | `/api/v1/webhooks` | Array of webhook records |
| POST | `/api/v1/webhooks` | `201 {webhook, token}`; token shown once |
| GET | `/api/v1/webhooks/<id>` | Webhook record |
| PATCH | `/api/v1/webhooks/<id>` | Webhook record; optional `name` and `enabled` |
| DELETE | `/api/v1/webhooks/<id>` | `{deleted: true}` |
| POST | `/api/v1/webhooks/<id>/rotate` | `{webhook, token}`; token shown once |

A record has `webhook_id`, `owner_user_id`, `name`, `enabled`, `created_at`,
`updated_at`, and `last_received_at`. No read API serializes `token_hash`.
Create accepts optional `name` and `enabled`. Tokens contain 32 CSPRNG bytes encoded
as URL-safe hex after `whsec_`; SQLite stores only their SHA-256 digest. Rotation
replaces that digest, invalidating both URL forms immediately.

Both public POST routes call the same ingress handler:

* Preferred: `/api/v1/hooks/<id>` with `Authorization: Bearer <token>`.
* URL-only senders: `/api/v1/hooks/<id>/<token>`. **Anyone with this URL can post events.**

Supplying both credentials is rejected. Query-string credentials are never used.
The owner always comes from the persisted webhook row. Unknown, disabled,
missing/wrong-token and experiment-disabled calls share `401 {"error":"unauthorized"}`.
Pre-auth throttling may instead return an ID-independent `429`.

Ingress redacts, applies hub/IP pre-auth limits and the byte cap, authenticates,
charges the webhook budget, validates JSON media type and an object of depth at most
16, then commits an outbox event. It queries no trigger, run, target or delivery
repository. `202` returns `data.event_id` and `data.duplicate`. A retry with the
same nonempty `Idempotency-Key` (at most 128 bytes) uses `evt_wh_` plus the first
32 hex characters of SHA-256 of `<webhook_id>|<key>`. The duplicate check,
version increment, append-if-absent and receipt timestamp share one unit of work.
Duplicates do not increment the entity version. A conflicting append rolls back.

`HEIMDALL_WEBHOOK_LIMITS_JSON` overrides any of these hub-wide defaults; unknown,
noninteger or out-of-range values fail startup. The effective values are advertised
at `GET /api/v1/actions/trigger-types` under `data.limits.webhook`.

| Key | Default | Accepted range |
| --- | ---: | ---: |
| `body_bytes` | 65536 | 1–1048576 |
| `pre_auth_per_minute` | 1200 | 1–1000000 |
| `per_webhook_per_minute` | 60 | 1–1000000 |
| `failed_auth_per_ip` | 20 | 1–1000000 |
| `per_owner` | 50 | 1–10000 |

Counters use fixed one-minute windows and reset on restart. Failed-auth IP limits
apply to that client's following requests, including valid ones; they cannot
consume another IP's per-webhook authenticated budget. Client IP resolution uses
the existing trusted forwarded-for CIDRs. `429` carries `Retry-After: 60`.

## Request-path recording audit

The audit searched production `src/hub` references to `req.path`, `request.path`,
`raw_target`, logging/trace/span calls and request/route labels. The relevant sites
are listed below; routing and entity-id extraction alone do not persist a path.

| Site | What it records or passes onward | Secret-URL treatment |
| --- | --- | --- |
| `transport/http/server.odin`: `handle_client` | Parses target into `Request.path`, `query`, `raw_target` | Calls `event_webhook_redact` immediately after constructing the wrapper, before preview, CSRF, upgrade and normal dispatch. Path and raw target become `/api/v1/hooks/<id>/[redacted]`; query is cleared. |
| `transport/http/router.odin`: all three dispatch entry points | Matched path and route pattern | Apply the same idempotent wrapper for in-process callers too. Only the private `hook_token` field reaches ingress; requests must never be serialized/logged wholesale. |
| `transport/http/metrics_http.odin`: `http_metrics_observe` | Request count/duration route labels | Receives registered `/api/v1/hooks/*` or `/api/v1/hooks/*/*`, never raw path. |
| `transport/http/metrics_http.odin`: `http_request_db_observe`, `format_db_slow_request` | DB metric labels and sampled/slow stderr record | Receives the same route pattern; includes no request body, query, header or path parameter. |
| `transport/http/middleware.odin`: `require_auth_any` and `service/auth/auth_service.odin`: `log_bridge_auth_denied` | Bridge auth denial path | Any router-supplied request is already redacted; public hook handler does not invoke session/bridge middleware. |
| `transport/http/agent_handlers.odin`: `list_agent_instances_handler`, `create_agent_instance_handler` | Cross-bridge auth denial path via the same audit logger | Already-redacted wrapper; these routes cannot match hook URLs. |
| `transport/http/vault_directory_handlers.odin`: `signed_request`; `oidc_device_gate.odin`: `request_signature_target` | Path/raw target in temporary signature canonical input | Already-redacted wrapper; public hook ingress bypasses device proof handling. No path is persisted by this code. |
| `transport/http/shell_session_handlers.odin`: preview path forwarding helpers | Path/query in the bridge's HTTP relay | Already-redacted wrapper; hook routes do not match preview route prefixes. |

There is no general inbound access logger or request-path span exporter in the
current hub. The ingress handler and service emit no request logs, and all their
error bodies are fixed strings that do not include paths or tokens. Panic sites
on this path do not format a `Request` or target. Rate keys contain only resolved
client IP or webhook ID. Proxy and sender logs are outside this boundary; see
the logging guidance in `SELF_HOSTING.md`.

The focused tests exercise the real TCP request wrapper for accepted, rejected,
oversized, rate-limited and forced storage-error secret URLs. They capture the
post-wrapper path/raw target, exported metrics, slow-log formatter output and
response bodies, and assert no presented URL token occurs. SQLite statement tracing
asserts a nonzero ingress query count with zero action/delivery-table queries.
