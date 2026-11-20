-- Local web channel; pairings remain external-only.
BEGIN IMMEDIATE;
CREATE TABLE channel_bindings_next (
  binding_id         TEXT PRIMARY KEY,                  -- "chb_..."
  owner_user_id      TEXT NOT NULL,
  bot_id             TEXT NOT NULL,
  provider           TEXT NOT NULL CHECK (provider IN ('telegram','whatsapp','web')),
  external_chat_id   TEXT NOT NULL,                     -- Telegram chat.id; WhatsApp phone digits or BSUID (D2)
  external_user_id   TEXT NOT NULL,                     -- Telegram from.id; WhatsApp BSUID or phone digits (D2)
  external_display   TEXT NOT NULL DEFAULT '',
  state              TEXT NOT NULL CHECK (state IN ('active','revoked')),
  created_at         TEXT NOT NULL,
  revoked_at         TEXT NOT NULL DEFAULT '',
  last_inbound_at    TEXT NOT NULL DEFAULT '',          -- RFC 3339 UTC of the user's latest message
  reengage_sent_at   TEXT NOT NULL DEFAULT '',          -- template sent for the current closed window
  reengage_error     TEXT NOT NULL DEFAULT '' CHECK (reengage_error IN ('','template_unavailable','send_failed'))
);
INSERT INTO channel_bindings_next
  (binding_id, owner_user_id, bot_id, provider, external_chat_id, external_user_id, external_display, state, created_at, revoked_at, last_inbound_at, reengage_sent_at, reengage_error)
  SELECT binding_id, owner_user_id, bot_id, provider, external_chat_id, external_user_id, external_display, state, created_at, revoked_at, last_inbound_at, reengage_sent_at, reengage_error
  FROM channel_bindings;
DROP TABLE channel_bindings;
ALTER TABLE channel_bindings_next RENAME TO channel_bindings;
CREATE UNIQUE INDEX channel_bindings_active_chat
  ON channel_bindings(provider, external_chat_id) WHERE state = 'active';
CREATE UNIQUE INDEX channel_bindings_active_owner
  ON channel_bindings(owner_user_id, provider) WHERE state = 'active';
CREATE INDEX channel_bindings_active_user
  ON channel_bindings(provider, external_user_id) WHERE state = 'active';

CREATE INDEX channel_messages_history_page ON channel_messages(bot_id, owner_user_id, created_at DESC, message_id DESC);
COMMIT;
