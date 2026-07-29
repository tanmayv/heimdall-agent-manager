# Agent Pane Capture Request Plan

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
  "error_code": "wrapper_unavailable"
}
```

All existing readers should normalize missing `message_type` to `text` and
missing `message_status` to `complete`.

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

Server behavior:

1. Validate the conversation belongs to the user.
2. Resolve its `agent_instance_id` and owning `bridge_id`.
3. Create a durable placeholder chat message:
   - `direction = "agent_to_user"` (or a new explicit `system_to_user` if the UI
     already supports it by implementation time)
   - `message_type = "pane_capture"`
   - `message_status = "pending"`
   - empty or short body such as `"Requesting pane capture..."`
4. Send a Bridge runtime command.
5. Return `202` with the placeholder message and request id.

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

### Hub → Bridge runtime command

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

### Bridge → Wrapper push

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

If no wrapper subscription exists, Bridge returns a failed result with
`error_code = "wrapper_unavailable"`.

### Wrapper → Bridge local endpoint

Allow wrapper token method `wrapper.pane_capture.result`:

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

Then publish the normal chat/sidebar invalidation event so the conversation view
refetches.

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
- new migration `017_chat_message_types.sql`

Work:

- Add columns `message_type`, `message_status`, `metadata_json` with defaults.
- Add repository method to update a message body/status/metadata by owner and id.
- Ensure list/fetch JSON includes the new fields.

### 2. Hub service + HTTP route

Files likely touched:

- `src/hub/service/content/content_service.odin`
- `src/hub/transport/http/content_handlers.odin`
- `src/hub/app/wiring.odin`
- `src/hub/transport/http/bridge_handlers.odin`

Work:

- Add `request_pane_capture(auth, conversation_id, input)`.
- Create placeholder and send `capture_agent_pane` runtime command.
- Handle `pane_capture_result` from bridge WS and update placeholder.
- Publish chat changed event and invalidate sidebar/conversation data.

### 3. Bridge runtime command forwarding

Files likely touched:

- `src/bridge/hub_runtime_client.odin`
- `src/bridge/wrapper_endpoint.odin`

Work:

- Handle `capture_agent_pane` command.
- Forward `pane_capture_request` push to wrapper.
- Track pending capture command ids.
- Accept `wrapper.pane_capture.result` from wrapper local endpoint.
- Send `pane_capture_result` to Hub.

### 4. Wrapper pane capture

Files likely touched:

- `src/wrapper/bridge_runtime.odin`
- `src/lib/tmux/tmux.odin`

Work:

- Add push handler for `pane_capture_request`.
- Add tmux width resize helper.
- Capture after settle delay.
- Return success/error result through local endpoint.

### 5. UI endpoint + rendering

Files likely touched:

- `src/ui/api/endpoints/chats.ts`
- `src/ui/components/chat/ConversationThreadPage.tsx`
- `src/ui/components/chat/ChatMessageList.tsx`
- `src/ui/components/MessageBubble.tsx` or current message body renderer
- debug registry in `AGENTS.md`

Work:

- Add `requestPaneCapture` RTK mutation.
- Add button beside Send.
- Add optimistic loading message.
- Render typed pane capture cards.
- Invalidate `Chat`, `ConversationSummaries`, and `SidebarConversations`.

## Tests

Minimum regression tests:

- Hub migration/static test: chat messages expose `message_type`,
  `message_status`, and `metadata_json`.
- Hub API test: `POST /chats/{id}/pane-capture` creates a pending typed message
  and sends a Bridge command.
- Bridge static/unit test: `capture_agent_pane` forwards only to wrapper; missing
  wrapper returns `wrapper_unavailable`.
- Wrapper static/unit test: request handler resizes to width 80 before capture and
  reports `pane_not_running` when pane is gone.
- UI static test: `conversation-request-pane-btn` exists beside send and typed
  `pane_capture` messages render with loading/success/error states.
- End-to-end/manual: start a live agent, click Request pane, observe pending
  message become a monospace capture; stop wrapper and verify failure message.

## Rollout notes

- Existing chat rows remain valid through defaults.
- Older Bridges/Wrappers that do not understand `capture_agent_pane` should yield
  a timeout/failure message, not leave pending rows forever.
- A cleanup job or read-time fallback should mark stale pending pane captures as
  failed after a timeout.
