# Agent Pane Capture Request Plan

Status: Draft implementation plan (contracts-first; no code changes in this document).

## Hard invariants

- Pane capture is an explicit user action only. There is no continuous terminal
  streaming and no automatic capture on normal chat/message delivery.
- Hub and Bridge heartbeats stay minimal. They must not carry pane text,
  capture parameters, chat messages, comments, tasks, policy, or typed-message
  payloads.
- The only raw pane text transport is the on-demand command/result path:
  Hub → Bridge runtime WS command → Wrapper local push/result → Bridge runtime
  WS result → durable Hub chat message. User WS events remain body-free
  invalidations.
- Hub remains the durable source of truth for the chat placeholder/result state;
  Bridge and Wrapper keep only in-flight request state.
- Unknown protocol versions, unknown capture fields, or unsupported Bridge/Wrapper
  capabilities fail closed and update the placeholder to `failed` rather than
  leaving a pending row indefinitely.

## Goal

Add a user-facing **Request pane** action in chat that asks the running wrapper to
resize its tmux pane to 80 columns, wait briefly for the TUI to reflow, capture
the visible/near-visible pane text, and return that capture as a typed chat
message. The UI should show a temporary loading message while the request is in
flight, then replace it with the capture or a clear failure message.

## Non-goals

- Do not stream raw terminal output continuously.
- Do not expose arbitrary tmux targets or paths to the UI.
- Do not let the Hub capture panes directly when a wrapper is missing; the
  user-requested path is Hub → Bridge → Wrapper so wrapper liveness/token checks
  remain authoritative.
- Do not send pane captures through normal agent prompt delivery.

## Contract additions

All new records and wire messages use `protocol_version: 1` where they cross a
Hub↔Bridge or Bridge↔Wrapper boundary. Request fields are allowlisted and
clamped at every boundary so a stale UI or downgraded Bridge cannot smuggle
arbitrary tmux targets, paths, large captures, or user/owner identifiers.

### Chat message record

Extend `Chat_Message` / `chat_messages` with typed message metadata:

- `message_type: string`
  - default: `"text"`
  - new value: `"pane_capture"`
- `message_status: string`
  - default: `"complete"`
  - values for pane capture: `"pending" | "complete" | "failed"`
- `metadata_json: string`
  - for pane captures:

```json
{
  "pane_capture_request_id": "cap_...",
  "agent_instance_id": "inst_...",
  "bridge_id": "brg_...",
  "width": 80,
  "settle_ms": 3000,
  "line_limit": 120,
  "line_count": 72,
  "truncated": false,
  "error_code": "wrapper_unavailable",
  "pending_timeout_at": "2026-07-29T12:00:30Z"
}
```

All existing readers should normalize missing `message_type` to `text` and
missing `message_status` to `complete`. New writers should always populate all
three fields. `metadata_json` must be valid JSON (use `{}` for text messages),
and list/fetch responses should include both the raw snake_case fields and any
UI-normalized aliases already used by the chat endpoint conventions.

The durable message fetch response may include pane output in `body` after
completion. User WS/resource-change summaries must not include the captured
pane body; they only notify the UI that the conversation changed and must be
refetched.

### User REST endpoint

Add a cookie-auth endpoint:

```http
POST /api/v1/chats/{conversation_id}/pane-capture
Content-Type: application/json

{
  "width": 80,
  "settle_ms": 3000,
  "line_limit": 120
}
```

All fields are optional. Defaults/clamps:

- `width`: default `80`, clamp `40..200`
- `settle_ms`: default `3000`, clamp `500..10000`
- `line_limit`: default `120`, clamp `20..300`

Server behavior:

1. Validate the conversation belongs to the user.
2. Resolve its `agent_instance_id` and owning `bridge_id`.
3. Create a durable placeholder chat message:
   - `direction = "agent_to_user"` (or a new explicit `system_to_user` if the UI
     already supports it by implementation time)
   - `message_type = "pane_capture"`
   - `message_status = "pending"`
   - empty or short body such as `"Requesting pane capture..."`
4. Send a Bridge runtime command over the existing Bridge runtime command sink
   (not heartbeat). If the Bridge is already offline/unreachable, either return
   a validation error before creating the placeholder or create-and-immediately
   mark the placeholder `failed`; do not leave an orphan pending message.
5. Return `202` with the placeholder message and request id once the request is
   accepted for asynchronous completion.

Response:

```json
{
  "message": {
    "message_id": "msg_...",
    "message_type": "pane_capture",
    "message_status": "pending",
    "body": "Requesting pane capture..."
  },
  "pane_capture_request_id": "cap_..."
}
```

The request id is stable for dedupe/retry. A duplicate user click while a
matching pending capture exists for the same conversation should return the
existing pending placeholder rather than enqueueing another command.

### Hub → Bridge runtime command

This is sent as a normal runtime WS command through the Hub's Bridge command
registry/sink. It is never piggybacked on `bridge_heartbeat`, heartbeat acks, or
agent status reports.

```json
{
  "type": "capture_agent_pane",
  "protocol_version": 1,
  "command_id": "cmd_...",
  "pane_capture_request_id": "cap_...",
  "conversation_id": "chat_...",
  "message_id": "msg_...",
  "agent_instance_id": "inst_...",
  "width": 80,
  "settle_ms": 3000,
  "line_limit": 120
}
```

Bridge should treat `command_id` as idempotent. A repeated command with the same
id returns the cached accepted/final result. If the Bridge does not support this
command type/protocol version, it returns a failed `command_result` with a stable
error code such as `unsupported_capture_agent_pane`.

### Bridge → Wrapper push

Bridge tracks a pending in-memory record keyed by `pane_capture_request_id` /
`command_id` containing `conversation_id`, `message_id`, and `agent_instance_id`.
The wrapper push only carries the fields the wrapper needs to perform the
capture; it does not include conversation ownership, Hub tokens, Bridge tokens,
or any arbitrary tmux target.

Forward the command only to the subscribed wrapper for that instance:

```json
{
  "push": "pane_capture_request",
  "payload": {
    "command_id": "cmd_...",
    "pane_capture_request_id": "cap_...",
    "message_id": "msg_...",
    "width": 80,
    "settle_ms": 3000,
    "line_limit": 120
  }
}
```

If no wrapper subscription exists, Bridge immediately sends a
`pane_capture_result` failure to Hub with `error_code = "wrapper_unavailable"`
and may also cache a failed `command_result` for command idempotency.

### Wrapper → Bridge local endpoint

Allow wrapper-token-only method `wrapper.pane_capture.result` in the local JSONL
endpoint method allowlist. It must be rejected for agent tokens. The local
endpoint's existing spoofed-param guard must continue to reject owner/user,
Hub/Bridge token, and instance override fields.

```json
{
  "v": 1,
  "id": "cap_...",
  "token": "<wrapper-token>",
  "method": "wrapper.pane_capture.result",
  "params": {
    "command_id": "cmd_...",
    "pane_capture_request_id": "cap_...",
    "message_id": "msg_...",
    "ok": true,
    "output": "... captured pane text ...",
    "width": 80,
    "line_count": 72,
    "truncated": false
  }
}
```

Failure example:

```json
{
  "ok": false,
  "error_code": "pane_not_running",
  "message": "The agent tmux pane is no longer running."
}
```

### Bridge → Hub runtime result

Bridge sends this as its own runtime WS frame, not as heartbeat content. The
frame may include the captured output because it is the explicit request result;
all other Bridge/user events should carry only metadata/invalidation.

Hub must handle a new runtime WS frame:

```json
{
  "type": "pane_capture_result",
  "command_id": "cmd_...",
  "pane_capture_request_id": "cap_...",
  "conversation_id": "chat_...",
  "message_id": "msg_...",
  "agent_instance_id": "inst_...",
  "ok": true,
  "output": "...",
  "width": 80,
  "line_count": 72,
  "truncated": false
}
```

Hub updates the existing placeholder message in place:

- success: `message_status = "complete"`, `body = output`
- failure: `message_status = "failed"`, `body = user-facing failure message`,
  metadata includes `error_code`

Before updating, Hub verifies that the placeholder exists, belongs to the same
conversation/agent instance/Bridge, and is still `message_type = "pane_capture"`.
Duplicate results are idempotent: if the placeholder is already terminal
(`complete` or `failed`), ignore the body update and only return/log success.

Then publish the normal chat/sidebar invalidation event so the conversation view
refetches. The event summary should include only ids/status metadata, never the
captured pane body.

## Lifecycle, restart, and timeout semantics

- Hub persists the pending placeholder before sending the command and records a
  `pending_timeout_at` in metadata. A periodic cleanup or read-time repair marks
  stale pending pane captures as `failed` with `error_code = "capture_timeout"`.
- Bridge pending capture maps are in-memory only. A Bridge process restart loses
  in-flight capture state, reconnects with a fresh runtime WS session, and does
  not replay old capture commands from heartbeat/sync. Hub timeout handling is
  responsible for clearing any placeholder that was pending during the restart.
- Wrapper notification subscriptions are in-memory. After Bridge restart,
  wrappers reconnect/resubscribe through `wrapper.notifications.subscribe`; new
  pane capture requests work once the subscription is restored.
- If the wrapper exits or its pane disappears while a capture is pending, Bridge
  or Wrapper sends a failed result with `pane_not_running` / `wrapper_unavailable`
  if it can observe the failure; otherwise Hub timeout resolves it.
- Hub restart recovery should scan durable pending `pane_capture` messages at
  startup or first read and mark entries whose timeout has passed as failed. Do
  not depend on Bridge replay to fix pending rows after Hub restart.

## Wrapper/tmux behavior

Implement in `ham-wrapper bridge-runtime` because it owns the live pane id and
wrapper token.

1. On `pane_capture_request`, resolve `cfg.pane_id` and verify `tmux.pane_exists`.
2. Resize width only:
   - add `tmux.resize_pane_width(pane_id, width)` using `tmux resize-pane -t
     <pane> -x 80`.
   - clamp width to a safe range, e.g. `40..200`; default to 80.
3. Wait `settle_ms` (default 3000, clamp e.g. `500..10000`) so TUIs can reflow.
4. Capture using `tmux.capture_pane_text(pane_id, line_limit)` or an enhanced
   helper with `capture-pane -p -J` if joined wrapped lines are desired.
5. Sanitize before sending:
   - strip or escape terminal control sequences as needed for display;
   - cap output bytes, e.g. 64 KiB;
   - report `truncated: true` when capped.
6. Send result through `wrapper.pane_capture.result`.

Error cases:

- missing wrapper subscription → `wrapper_unavailable`
- pane missing/exited → `pane_not_running`
- resize failed → `resize_failed`
- capture failed → `capture_failed`
- bridge command timed out → `capture_timeout`

## Privacy and safety notes

- Pane capture is sensitive terminal content. Store it only because the user
  explicitly requested it, cap it before Hub storage, and avoid echoing it into
  agent prompts, bridge heartbeats, status reports, analytics, or logs.
- Redact known bearer token prefixes (`hbr_`, `hbe_`, instance/wrapper tokens) in
  Bridge/Wrapper logs and test failures. Sanitization should strip ANSI/control
  sequences before persistence and display.
- The UI must make the action visually distinct from sending a chat message so
  users understand it captures terminal state rather than contacting the agent.

## UI behavior

### Button placement

Add a button beside the chat send button in `ConversationThreadPage` / shared
`ChatComposer` wiring.

Suggested debug IDs:

- `conversation-request-pane-btn`
- `conversation-pane-capture-loading-${messageId}`
- `conversation-pane-capture-output-${messageId}`
- `conversation-pane-capture-error-${messageId}`

The button label/icon can be a debug-style terminal icon such as `▣`, `⌗`, or
`🐞`; it must include an accessible label: `Request terminal pane capture`.

Disable when:

- conversation has no `agent_instance_id`
- runtime status is stopped/failed/unreachable
- a pane capture request is already pending for this conversation

### Optimistic/loading message

On click:

1. Create a local optimistic chat message keyed by `pane_capture_request_id` (or
   use the server-returned placeholder if the endpoint responds quickly).
2. Render it as a distinct pane-capture card with a spinner/loading icon and text
   like `Requesting terminal pane...`.
3. When fetch/refetch returns the durable message with matching
   `message_id`/`pane_capture_request_id`, replace the optimistic item.
4. Render `message_type = "pane_capture"` differently from normal chat:
   - monospace/preformatted body;
   - small metadata strip (`80 cols`, timestamp, line count);
   - failed state with warning styling and retry button.

## Implementation tasks

### 1. Backend schema + repository

Files likely touched:

- `src/hub/domain/content.odin`
- `src/hub/repository/iface/content_repo.odin`
- `src/hub/repository/sqlite/content_repo_sqlite.odin`
- `src/hub/repository/sqlite/migrations.odin`
- new migration `017_chat_message_types.sql` (or the next available migration
  number if this plan is implemented after another migration lands)

Work:

- Add columns `message_type`, `message_status`, `metadata_json` with defaults in
  both schema bootstrap and incremental migration SQL.
- Update `Chat_Message`, `bind_message`, `message_from_stmt`, list/select
  projections, and `write_message_json` so old rows normalize to
  `text`/`complete`/`{}`.
- Add repository method to update a message body/status/metadata by
  `owner_user_id`, `conversation_id`, and `message_id`.
- Ensure list/fetch JSON includes the new fields and never double-escapes
  `metadata_json` if it is emitted as an object.

### 2. Hub service + HTTP route

Files likely touched:

- `src/hub/service/content/content_service.odin`
- `src/hub/service/events/event_bus.odin` (only if a helper is needed; existing
  `publish_resource_changed` may be enough)
- `src/hub/transport/http/content_handlers.odin`
- `src/hub/app/wiring.odin`
- `src/hub/transport/http/bridge_handlers.odin`

Work:

- Add `request_pane_capture(auth, conversation_id, input)` with ownership,
  bridge/instance resolution, pending dedupe, clamp/default validation, and
  placeholder creation.
- Create placeholder and send `capture_agent_pane` runtime command through
  `project_service.bridge_command_send_runtime`; do not send it via heartbeat or
  status-report paths.
- Handle `pane_capture_result` from bridge WS and update placeholder in place.
- Implement timeout/read-repair for stale pending captures.
- Publish chat changed/sidebar invalidation events with body-free summaries.

### 3. Bridge runtime command forwarding

Files likely touched:

- `src/bridge/hub_runtime_client.odin`
- `src/bridge/wrapper_endpoint.odin`

Work:

- Handle `capture_agent_pane` command with protocol/version checks and cached
  command-id results.
- Forward `pane_capture_request` push only to the subscribed wrapper for
  `agent_instance_id`.
- Track pending capture command ids in memory with a deadline; on timeout send a
  failed `pane_capture_result` if the Hub connection is still live.
- Accept `wrapper.pane_capture.result` from the wrapper-token path in the local
  endpoint and reject it for agent tokens.
- Send `pane_capture_result` to Hub as a runtime WS frame; never include capture
  output in `bridge_heartbeat` or `agent_instance_status`.

### 4. Wrapper pane capture

Files likely touched:

- `src/wrapper/bridge_runtime.odin`
- `src/lib/tmux/tmux.odin`

Work:

- Add push handler for `pane_capture_request` in the notification subscription
  loop; keep existing `agent_message` pushes body-free.
- Add tmux width resize helper and use the current wrapper-owned `pane_id` only.
- Capture after settle delay, sanitize/control-strip, byte-cap, line-cap, and set
  `truncated`/`line_count` accurately.
- Return success/error result through local endpoint with `wrapper.pane_capture.result`.

### 5. UI endpoint + rendering

Files likely touched:

- `src/ui/api/endpoints/chats.ts`
- `src/ui/components/chat/types.ts`
- `src/ui/components/chat/ConversationThreadPage.tsx`
- `src/ui/components/chat/ChatMessageList.tsx`
- `src/ui/components/MessageBubble.tsx` or current message body renderer
- debug registry in `AGENTS.md`

Work:

- Add `requestPaneCapture` RTK mutation and normalize `message_type`,
  `message_status`, and parsed metadata onto `ChatMessage`.
- Add button beside Send with `data-debug-id="conversation-request-pane-btn"`
  and an accessible label.
- Add optimistic loading message keyed by `pane_capture_request_id` and reconcile
  it with the server placeholder/result.
- Render typed pane capture cards with loading/success/error states and stable
  debug IDs.
- Disable duplicate requests while one pending capture exists in the conversation.
- Invalidate `Chat`, `ConversationSummaries`, and `SidebarConversations` on
  request, result WS invalidation, and retry.

## Tests

Minimum regression tests:

- Hub migration/static test: chat messages expose `message_type`,
  `message_status`, and `metadata_json`, and old rows normalize to
  `text`/`complete`/`{}`.
- Hub API test: `POST /chats/{id}/pane-capture` creates a pending typed message,
  sends a Bridge command, dedupes while pending, and refuses cross-owner
  conversations.
- Hub runtime result test: `pane_capture_result` updates only the matching
  pending placeholder, ignores duplicate terminal results, and publishes a
  body-free resource invalidation.
- Bridge static/unit test: `capture_agent_pane` forwards only to wrapper; missing
  wrapper returns `wrapper_unavailable`; heartbeat/status JSON does not include
  capture payloads or output.
- Bridge restart/manual test: pending capture during Bridge restart eventually
  becomes `capture_timeout` rather than staying pending forever.
- Wrapper static/unit test: request handler resizes to width 80 before capture,
  strips ANSI/control sequences, caps bytes/lines, and reports
  `pane_not_running` when pane is gone.
- UI static test: `conversation-request-pane-btn` exists beside send and typed
  `pane_capture` messages render with loading/success/error states.
- End-to-end/manual: start a live agent, click Request pane, observe pending
  message become a monospace capture; stop wrapper and verify failure message.

## Rollout notes

- Existing chat rows remain valid through defaults.
- Prefer explicit Bridge capability advertisement for `capture_agent_pane` once
  provider/runtime capabilities are refreshed; until then, unsupported Bridges
  must fail closed or time out safely.
- Older Bridges/Wrappers that do not understand `capture_agent_pane` should yield
  a timeout/failure message, not leave pending rows forever.
- A cleanup job or read-time fallback should mark stale pending pane captures as
  failed after a timeout.
- No migration or rollout step should add capture/chat/comment/task payloads to
  Bridge heartbeats.
