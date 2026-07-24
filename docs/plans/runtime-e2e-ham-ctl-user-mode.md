# Runtime E2E ham-ctl Hub user-mode notes

## Scope

This note records the RTE2E-6 `ham-ctl` user-mode implementation boundary for the runtime E2E slice.

## Implemented contract

- User-mode is selected with `ham-ctl hub ...` (or `--hub`) and can run config-free for smoke scripts.
- Hub URL comes from `--hub-url`, `--daemon-url`, `HAM_HUB_URL`, or `HEIMDALL_HUB_URL`.
- User API token comes from `--user-token`, `--token`, `HAM_HUB_USER_TOKEN`, or `HEIMDALL_USER_TOKEN`.
- The token is sent only as `Authorization: Bearer <token>`.
- User-mode routes target Hub `/api/v1`; no Hub bearer token is placed in query strings, request bodies, or URL paths.
- Implemented smoke-driving surfaces:
  - `hub me` and `hub health`
  - `hub agents list|create|run`
  - `hub launch`
  - `hub chats list|create|send|messages`
  - `hub task-chains list|create|show|publish|complete`
  - `hub tasks list|create|publish|status|nudge`

## RTE2E-9 preservation

This work adds an explicit Hub user-mode branch while preserving the existing daemon/current `ham-ctl` commands and legacy routes. Existing commands such as daemon `agents run`, `send`, `inbox`, `tasks`, `artifacts`, and `chat` continue to dispatch through their existing handlers unless `hub`/`--hub` mode is selected.
