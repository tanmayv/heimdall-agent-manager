# Message Bus / Event Pipeline Implementation Plan

## Motivation

The current daemon flow is too direct:

```text
/agent-rpc send_message -> MessageProvider -> manually send WS notification
/agent-rpc fetch_messages -> MessageProvider -> manually send read receipt WS notification
```

This works for the POC, but it makes future plugin behavior hard to add.

We want a daemon architecture where future plugins can observe and eventually modify behavior around message lifecycle events, such as:

- `new_message`
- `message_stored`
- `messages_available`
- `message_read`
- `message_delivered`
- message metrics/logging
- message mirroring to another backend
- moderation/filtering
- message transformation
- Discord/file/other backend adapters

The key design goal is:

```text
RPC should not directly orchestrate every provider + WS side effect.
RPC should call a message service, and message lifecycle events should flow through a daemon-side bus.
```

This lets us keep providers simple, keep `agent_rpc.odin` lean, and create a clean place for future plugin/event handlers.

## Important Distinction

### Actual messages

Actual message bodies are stored/fetched through `MessageProvider` and RPC:

```text
agent -> /agent-rpc fetch_messages -> daemon -> provider -> actual message bodies
```

### Message events

WebSocket is metadata-only:

```text
daemon -> WS -> wrapper: message_event
```

WS events must not include actual message bodies.

Examples:

```json
{
  "type": "message_event",
  "event": "messages_available",
  "conversation_id": "conv_coder-agent_project-2",
  "pending_count": 1
}
```

```json
{
  "type": "message_event",
  "event": "messages_read",
  "conversation_id": "conv_coder-agent_project-2",
  "message_id": "msg_1",
  "read_by_agent_instance_id": "coder-agent@project-2",
  "read_unix_ms": 123456789
}
```

## Recommended Architecture

```text
agent RPC
  -> agent_rpc.odin
  -> message_service.odin
  -> MessageProvider
  -> message_bus.odin
  -> built-in handlers / future plugins
  -> WS event notifications
```

## Commands vs Events

### Commands

Commands are requests to do something:

- `Send_Message_Command`
- `Fetch_Messages_Command`
- `Mark_Read_Command`

### Events

Events are facts that something happened:

- `New_Message_Requested`
- `Message_Stored`
- `Messages_Available`
- `Message_Read`
- `Message_Delivered`
- `Message_Send_Failed`

Plugins should primarily listen to events. Later, plugins can also hook commands before they execute.

## New Files

Add:

```text
src/daemon/message_bus.odin
src/daemon/message_service.odin
src/daemon/message_hooks.odin
src/daemon/ws_events.odin
```

### `src/daemon/message_bus.odin`

Owns internal daemon message events and synchronous dispatch.

For the POC, keep it synchronous. Do not build a complex async queue yet.

Suggested types:

```odin
Message_Event_Kind :: enum {
  New_Message_Requested,
  Message_Stored,
  Messages_Available,
  Message_Read,
  Message_Delivered,
  Message_Send_Failed,
}

Message_Event :: struct {
  kind: Message_Event_Kind,
  message_id: contracts.Message_ID,
  conversation_id: contracts.Conversation_ID,
  from_agent_instance_id: contracts.Agent_Instance_ID,
  target_agent_instance_id: contracts.Agent_Instance_ID,
  read_by_agent_instance_id: contracts.Agent_Instance_ID,
  pending_count: int,
  created_unix_ms: i64,
  read_unix_ms: i64,

  // Internal only. Never serialize this onto WS.
  body: string,
}
```

Initial API:

```odin
message_bus_emit :: proc(event: Message_Event)
```

For now, `message_bus_emit` can directly call built-in handlers such as WS notification handling.

Later, this can become:

```odin
register_message_event_handler(handler)
```

### `src/daemon/message_service.odin`

Owns message lifecycle orchestration.

Move provider orchestration from `agent_rpc.odin` into here.

Suggested APIs:

```odin
message_service_send_message :: proc(
  from_agent_instance_id: string,
  target_agent_instance_id: string,
  payload: string,
) -> contracts.Send_Message_Response
```

```odin
message_service_fetch_messages :: proc(
  agent_instance_id: string,
  conversation_id: string,
  limit: int,
  include_read: bool,
) -> contracts.Fetch_Messages_Response
```

Responsibilities:

- validate/resolve conversation IDs where appropriate
- call provider facade functions:
  - `mp.send_message`
  - `mp.fetch_messages`
  - `mp.unread_count`
  - `mp.mark_read`
- emit message bus events:
  - `New_Message_Requested`
  - `Message_Stored`
  - `Messages_Available`
  - `Message_Read`

### `src/daemon/message_hooks.odin`

Define future plugin hooks.

Initial implementation can be no-op.

Suggested pre-send context:

```odin
Send_Message_Context :: struct {
  from_agent_instance_id: contracts.Agent_Instance_ID,
  target_agent_instance_id: contracts.Agent_Instance_ID,
  conversation_id: contracts.Conversation_ID,
  body: string,
  rejected: bool,
  rejection_reason: string,
}
```

Future hook shape:

```odin
Message_Pre_Send_Hook :: proc(ctx: ^Send_Message_Context)
```

For now:

```odin
run_pre_send_hooks :: proc(ctx: ^Send_Message_Context) {
  // no-op for POC
}
```

This is where future plugins can:

- rewrite message body
- reject messages
- add metadata
- mirror messages
- route to external backends

### `src/daemon/ws_events.odin`

Converts daemon message events into metadata-only WS notifications.

Responsibilities:

- handle `Messages_Available`
- handle `Message_Read`
- call registry/WS send helpers
- ensure no actual message body is included in WS payload

Example:

```text
Message_Event{kind=Messages_Available}
  -> {"type":"message_event","event":"messages_available",...}
```

```text
Message_Event{kind=Message_Read}
  -> {"type":"message_event","event":"messages_read",...}
```

## Changes to Existing Files

### `src/daemon/agent_rpc.odin`

Should become thin.

Current logic directly calls provider and WS notification. Move that into `message_service.odin`.

Desired shape:

```odin
if action == "send_message" {
  response := message_service_send_message(from_agent_instance_id, target_agent_instance_id, payload)
  write_response(...)
} else if action == "fetch_messages" {
  response := message_service_fetch_messages(from_agent_instance_id, conversation_id, limit, include_read)
  write_response(...)
}
```

Keep canonical action names only:

```text
send_message
fetch_messages
```

Do not accept variants like:

```text
Send_Message
SendMessage
Fetch_Messages
FetchMessages
```

### `src/daemon/ws.odin`

Keep low-level WS mechanics here:

- handshake
- accept key
- read loop
- text frame sending

Message-event-specific JSON can move to `ws_events.odin`.

### `src/daemon/registry.odin`

Registry should track agent instance metadata and WS socket state.

It should not own message lifecycle logic.

Long term, registry should ideally not know WS frame details. It can either:

- expose socket lookup and let `ws_events.odin` send, or
- keep a small `registry_send_ws_text` wrapper that delegates to `ws_send_text`

For the POC, either is acceptable, but keep message event formatting out of registry.

### `src/lib/message_provider/*`

Provider should stay focused on storage/fetch state.

Provider should not send WS events directly.

Provider should not know daemon routing/plugin details.

## Read Receipt Rule

Current desired behavior:

```text
fetch_messages by target agent == message read
```

The wrapper receiving a WS notification is **not** a read.

Read happens only when the agent fetches actual messages via RPC.

When fetch marks messages read, `message_service_fetch_messages` should emit `Message_Read` events for newly read messages.

Important: avoid duplicate read receipts.

Current mitigation:

```text
fetch_messages default include_read=false
```

Better long-term provider result:

```odin
newly_read_message_ids: []Message_ID
```

or:

```odin
read_receipts: []Delivery_Receipt
```

For now, service can infer newly read messages by fetching unread messages only.

## Implementation Steps

1. Add `message_bus.odin` with event type and synchronous `message_bus_emit`.
2. Add `ws_events.odin` and route `Messages_Available` / `Message_Read` events to WS notifications.
3. Add `message_hooks.odin` with no-op pre-send hook support.
4. Add `message_service.odin` and move send/fetch orchestration out of `agent_rpc.odin`.
5. Update `agent_rpc.odin` to call message service only.
6. Ensure WS payloads remain metadata-only.
7. Build:

```bash
nix build .#bc-odin-daemon .#bc-agent-wrapper .#bc-odinctl
```

8. Smoke test:

```text
A send_message to B
B receives messages_available WS event
B fetch_messages
A receives messages_read WS event
```

## Non-Goals For This Step

- Do not implement async queue persistence yet.
- Do not implement external provider backend yet.
- Do not implement dynamic plugin loading yet.
- Do not send actual message body over WS.

## Success Criteria

- `server.odin` remains lean.
- `agent_rpc.odin` is mostly request parsing/auth + service calls.
- Message lifecycle side effects happen through the bus/service.
- Message provider remains a backend abstraction.
- WS events are clearly separated from actual messages.
- Existing smoke tests still pass.
