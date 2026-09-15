# Bridge-token authorization mode (`--bridge-auth-mode`)

The hub gates a handful of **bridge-token** authorization decisions. This flag
controls whether those decisions **block** or run in **audit-only** mode.

- `--bridge-auth-mode=monitor` (**default**) — ALLOW the operation, but emit a
  `bridge_auth_monitor` audit line wherever `enforce` would deny. Use this to
  enumerate real impact before turning enforcement on.
- `--bridge-auth-mode=enforce` — block (the strict behavior).
- Env: `HEIMDALL_BRIDGE_AUTH_MODE=monitor|enforce`. Precedence: default → env → flag.

Decision points made mode-aware (all involve a **bridge** token; normal agents
relay with an *instance* token and resolve as `Instance_Token`, so they are
unaffected in either mode):

| point (log tag)             | enforce behavior                              |
|-----------------------------|-----------------------------------------------|
| `bare_token_shared_endpoint`| bare bridge token rejected on shared endpoints|
| `cross_bridge_list`         | 403 listing another bridge's instances        |
| `cross_bridge_create`       | 403 creating an instance on another bridge     |
| `cross_owner_execute`       | 403 executing an action owned by another user  |

## Reading the audit log

```
journalctl -u heimdall-hub-qa | grep bridge_auth_monitor
```

Each line: `ham-hub bridge_auth_monitor point=<tag> method=<m> path=<p> bridge_id=<b> user_id=<u> target=<t> request_id=<r>`.
Once the logs are clean (or you accept the listed operations), flip the service
to `--bridge-auth-mode=enforce` and redeploy.
