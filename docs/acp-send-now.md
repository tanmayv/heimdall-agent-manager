# ACP input delivery and batch Send now

The delivery evidence applies only to user messages sent to an ACP agent
(`agent_instances.runtime_transport = 'acp'`). PTY and other non-ACP rows have no
delivery record and keep today's `read_at` behaviour. Send now itself is available to
every runtime that declares it; a PTY agent's Send now has no members (see
[Send now without members (PTY)](#send-now-without-members-pty)).

## Evidence model

Each ACP user message has one row in `acp_input_deliveries` (migration
`acp_delivery_001_input_deliveries.sql`). It keeps two separate kinds of evidence:

| Evidence | Written by | Meaning |
| --- | --- | --- |
| `state` | Bridge reports (monotonic `report_seq`, fenced by `launch_epoch`) | `sent` (persisted by the Hub, not yet admitted by the bridge), `queued`, `dispatching` (a steer is in flight), `delivered` (the prompt was dispatched or the steer accepted), `discarded` (an ambiguous in-flight steer when the runtime ended) |
| `agent_read_at` | The Hub, on the agent's own `chat read` (never on the bridge input drain) | Actual read. It implies `delivered` (with `mode=read` if no earlier delivery). |

The bridge's inbox admission sets the legacy `chat_messages.read_at`, so for ACP rows
that field means **admission, not read**. `chat_messages.delivered_at` is now written
once a row is delivered.

The ACP agent's own default `chat read` (`unread_only=true`) therefore treats a row as
unread when its legacy `read_at` is empty **or** its delivery row has no `agent_read_at`
and is not yet `delivered`/`discarded`. That read records `agent_read_at`, sends
`acp_inputs_read` to the bridge, and removes the row from the tray and Send now. The
bridge input drain (`input_source=bridge_acp`) keeps the legacy `read_at` filter, so
admission never loops. Cross-agent reads (`target_instance_id`) are unchanged.

`hold_reason` is reported by the bridge:

- `turn_active`: the input is held because a turn is running. This is the only reason
  that makes a row tray and Send now eligible. Once set, it stays until the row is
  delivered.
- `dispatch_pending`: the agent is idle, and the input goes out on the next drain.

Rows that are idle sends, transport offline (`sent`), vault or publication blocked, or
failed messages are never turn-held.

Status path for the UI: `sent → (queued) → delivered → read`, which `acp_delivery.status`
exposes. A read can skip any intermediate status.

## API

Message JSON (`GET /chats/{cid}/messages`, the message detail, and agent reads) adds,
for ACP user rows only:

```json
"acp_delivery": {"status":"sent|queued|delivered|read|not_delivered","state":"...","hold_reason":"turn_active|dispatch_pending|",
  "tray_eligible":true,"mode":"prompt|steer|read|","launch_epoch":"...","turn_id":"...","batch_id":"...",
  "error":"","delivered_at":"","agent_read_at":"","updated_at":""}
```

Assistant rows add `metadata.acp.input_ids`: every user input the segment answers. A
batch lists all of its members.

`POST /api/v1/chats/{cid}/send-now`, owner session:

```json
{"request_id":"<stable per click intent>","launch_epoch":"<instance epoch>","message_ids":["<tray snapshot, optional cutoff>"]}
```

The response is `{"outcome":..., "batch":{batch_id,request_id,launch_epoch,attempt,state,error,message_ids,excluded:[{message_id,reason}],created_at,updated_at}}`.

| HTTP | outcome | Meaning |
| --- | --- | --- |
| 202 | `accepted` | A new batch, or a retry of a failed one, was sent to the bridge |
| 202 | `duplicate` | This request, or another batch for the conversation, is still in flight. No command is sent. |
| 200 | `empty` | Nothing is eligible. Nothing is sent and nothing is cancelled. |
| 200 | `delivered` | The request was already completed |
| 503 | `failed` | The bridge is offline. Retry with the same `request_id`. |
| 409 | error | Stale `launch_epoch`, or the agent's runtime has no Send now |

- **Snapshot:** queued, turn-held, current-epoch, unread rows in FIFO order, limited to
  `message_ids` when that list is given. Rows that arrive later are not included and
  wait for the next batch.
- **Retry:** the same `request_id` after `failed`. The attempt goes up by one, the
  frozen members are checked again (rows that were delivered, read or are stale drop
  out), and the batch is never re-snapshotted. The bridge command id is
  `cmd_sn_<batch>_a<attempt>`. If the bridge receives a retry while the batch is
  already in flight (a steer pending, a cancel before its prompt, or delivered), it
  keeps the frozen membership and only re-reports the current batch state
  (`dispatching` or `delivered`) for the new attempt. Nothing is re-selected,
  re-steered or cancelled again.
- A `pending` or `sent` batch with no bridge progress for 30 s becomes `failed`
  (`bridge_no_response`) and can be retried.

`GET /api/v1/chats/{cid}/send-now` returns `{runtime_transport, send_now, launch_epoch,
steering_supported (null until reported), batch}`, for reloads and for the tooltip choice.
`send_now` is the runtime's declared capability
(`contracts.runtime_transport_capabilities`): `members` (ACP), `notice` (PTY) or `""`
(no Send now). The UI decides from it, never from the transport name.

WebSocket: `chat_event` with `event:"messages_delivery"`, `message_ids`, `batch_id` and
`fetch_required:true`.

Batch states: `pending → sent → dispatching → delivered | empty | failed`. Possible
errors: `bridge_offline`, `bridge_no_response`, `cancel_timeout`, `runtime_failed`,
`agent_restarted`, `agent_stopped`, `batch_in_progress`.

## Bridge behaviour

- **Reports** travel in the same FIFO chat outbox as assistant revisions
  (`kind:"input_state"`). A delivery is therefore stored before any assistant text it
  caused, and it survives restarts through the journal and the recovery scanner.
  Consecutive reports coalesce. A rejected report is dropped and never fails the agent.
- **`send_now_batch`** runs on the runtime dispatcher, so it is serialized with drain,
  steering results and turn completion. It first checks each member against the
  bridge's own state: members that are already dispatched, in the current turn,
  in a steer in flight, or read are left out, and an empty batch sends nothing. The
  remaining members move to the queue front and are sent as **one** input that keeps
  each message's own context block, in FIFO order:
  - If the agent is idle, it goes as one prompt.
  - If the agent can be steered, it goes as one steer. When another steer is already in
    flight, the batch waits for it.
  - On Codex, before the turn id is known, the batch waits for the turn id and then
    steers.
  - Otherwise the bridge sends one cancel, and the batch becomes the next prompt.
- **Rejected steers** go back to the queue front and are never steered again. A
  rejected batch falls back to a single cancel.
- **Cancel timeout:** the runtime fails (existing behaviour) and the batch reports
  `failed:cancel_timeout`. Its inputs stay queued and were never dispatched. The first
  report of the next launch epoch makes the Hub reopen them: they return to `sent`
  with `read_at` cleared, and the bridge gets a fetch edge, so they are admitted again
  without replaying anything that ran. In-flight steers from the old epoch become
  `discarded`.
- **Agent read:** the Hub sends `acp_inputs_read`, and the bridge drops those inputs
  from its queue and from an unmerged batch. An input already merged into the combined
  batch input is still sent once inside that batch.

## Send now without members (PTY)

A PTY agent is never typed message bodies. Each user message only gives the agent a
notice that points at `ham-ctl chat read`, and the agent's own `chat read` returns every
unread message (that read is the read evidence, as `read_at` was before). So a PTY Send
now needs no batch members:

- **Hub:** `POST /chats/{cid}/send-now` records the request as a batch row without
  members (`message_ids` in the request is ignored) and sends the bridge the same
  `acp_send_now_batch` command with a `batch_id`, the attempt and no `message_ids`. The
  outcome is the bridge's command result: `delivered` (HTTP 200) once the notice was
  typed, or `failed` (HTTP 503: `bridge_offline`, `bridge_no_response`, `send_failed`).
  A repeat of the same `request_id` is a no-op; a retry after `failed` bumps the attempt.
- **Bridge:** queued user messages coalesce into ONE pending unread notice per agent in
  the shared inbox, typed only at a trusted idle and never with an interrupt key. Send
  now presses the profile's interrupt keys (Esc by default), types the notice and
  submits, then consumes the pending notice so nothing is typed twice. The inbox
  remembers the last applied request id (`send_now_applied`), so a repeat is a no-op
  also after a bridge restart.
- **Steer** (when the profile's `pty_delivery.can_steer` is on, the default) stops a
  running turn with the interrupt keys, or types without them at a trusted idle, then
  types the notice and submits. With `can_steer` off, steer becomes send now.
- **UI:** unread PTY rows stay in the transcript; one "Send now" action above the
  composer (`conversation-unread`, `conversation-queued-send-now`) asks the agent to read
  them now.
