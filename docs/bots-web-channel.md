# Built-in bot web channel

The web channel uses the owner's existing bot and agent. It requires authentication
and the `bots` experiment. It does not need Telegram or WhatsApp configuration,
pairing, a WhatsApp entitlement, templates, or a reply window.

## Send a message

`POST /api/v1/bots/me/channels/web/messages`

```json
{"text":"Hello","idempotency_key":"a-client-generated-request-id"}
```

The optional `artifact_ids` array accepts up to 20 distinct IDs of existing,
nondeleted artifacts belonging to the authenticated owner. Invalid arrays return
400; missing, deleted or foreign artifacts return 404. Text may be empty or blank
when attachments are present; otherwise it must be nonblank. Text is valid UTF-8,
up to 16384 bytes. The key must be nonblank
valid UTF-8, up to 200 bytes. Keep the same key, text and ordered artifact IDs when retrying a request.
The server creates an active web binding on demand and atomically stores the
inbound message and its attachment references in one transaction. Keys are scoped to the bot; the same key/text returns the same
message even after body retention. Reusing a key with different text or attachments returns 409.
The durable payload hash is kept in the local message's external_message_id;
no external service receives it.

Success uses the normal response envelope with
`data: {message_id, created}`: 201 on first intake, 200 on replay. Delivery uses
the normal pending-delivery supervisor, so the agent wakes when an eligible
machine is available. A retry also retries delivery scheduling after a previous
post-intake failure. Experiment off returns 403; no bot returns 404.

Replies use the existing channel routing: an eligible read pending message takes
precedence, otherwise the newest inbound message chooses the active binding.
A reply to web is stored and marked sent locally. Subsequent Telegram or WhatsApp
input continues to use the existing routing rules.

## Unified history

`GET /api/v1/bots/me/messages?limit=50&cursor=<next_cursor>`

Returns `data: {messages, next_cursor}`. Each message has `message_id`,
`binding_id`, `provider` (`telegram`, `whatsapp`, or `web`), `direction`,
`body`, `body_purged`, `send_state`, `created_at`, `read_at`, and `replied_at`, plus `attachments` with the same metadata as agent channel read/history.
Web uploads are immediately `stored` and expose `artifact_id` for normal artifact fetch.
Purged messages expose no attachments.
It includes both directions and revoked bindings belonging to this bot and owner.
Existing retention and purge behavior applies.

Ordering is descending `(created_at, message_id)`. Limit is 1..200; default 50.
Pass the returned cursor unchanged for the next page; an empty cursor marks the
end. The cursor is the last returned message ID, validated against this owner
and bot. An unknown or other owner's cursor returns 400. New messages do not
shift older pages. The existing Telegram history endpoint stays compatible.

## Live updates

New stored inbound messages and recorded outbound sends publish the existing
owner-scoped `bot_changed` event on the user event stream. The UI's existing
`Bot` cache invalidation refreshes unified history. The bot API exports
`useGetUnifiedBotMessagesQuery` and `useSendBotWebMessageMutation`.
A replay does not emit another intake event.

The namespaced migration `bots_web_001_channel.sql` widens only the binding
provider constraint, preserves external channel state, and adds a paging index.
Web bindings are revoked and purged with normal bot deletion. Disabling the
experiment refuses web intake and stops delivery through the existing lifecycle.
