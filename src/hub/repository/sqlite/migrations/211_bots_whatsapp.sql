-- 211_bots_whatsapp.sql: WhatsApp channel for bots (experiment "bots").
-- Rebuilds channel_bindings, channel_pairings and channel_messages to widen their
-- CHECK constraints, carrying every existing row unchanged, and adds the push queue.
BEGIN IMMEDIATE;

CREATE TABLE channel_bindings_next (
  binding_id         TEXT PRIMARY KEY,                  -- "chb_..."
  owner_user_id      TEXT NOT NULL,
  bot_id             TEXT NOT NULL,
  provider           TEXT NOT NULL CHECK (provider IN ('telegram','whatsapp')),
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
  (binding_id, owner_user_id, bot_id, provider, external_chat_id, external_user_id, external_display, state, created_at, revoked_at)
  SELECT binding_id, owner_user_id, bot_id, provider, external_chat_id, external_user_id, external_display, state, created_at, revoked_at
  FROM channel_bindings;
DROP TABLE channel_bindings;
ALTER TABLE channel_bindings_next RENAME TO channel_bindings;
CREATE UNIQUE INDEX channel_bindings_active_chat
  ON channel_bindings(provider, external_chat_id) WHERE state = 'active';
CREATE UNIQUE INDEX channel_bindings_active_owner
  ON channel_bindings(owner_user_id, provider) WHERE state = 'active';
CREATE INDEX channel_bindings_active_user
  ON channel_bindings(provider, external_user_id) WHERE state = 'active';

CREATE TABLE channel_pairings_next (
  code_hash      TEXT PRIMARY KEY,
  owner_user_id  TEXT NOT NULL,
  bot_id         TEXT NOT NULL,
  provider       TEXT NOT NULL CHECK (provider IN ('telegram','whatsapp')),
  created_at     TEXT NOT NULL,
  expires_at     TEXT NOT NULL,
  consumed_at    TEXT NOT NULL DEFAULT ''
);
INSERT INTO channel_pairings_next (code_hash, owner_user_id, bot_id, provider, created_at, expires_at, consumed_at)
  SELECT code_hash, owner_user_id, bot_id, provider, created_at, expires_at, consumed_at FROM channel_pairings;
DROP TABLE channel_pairings;
ALTER TABLE channel_pairings_next RENAME TO channel_pairings;
CREATE INDEX channel_pairings_owner ON channel_pairings(owner_user_id, provider);

CREATE TABLE channel_messages_next (
  message_id           TEXT PRIMARY KEY,
  binding_id           TEXT NOT NULL,
  owner_user_id        TEXT NOT NULL,
  bot_id               TEXT NOT NULL,
  direction            TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  provider_update_key  TEXT NOT NULL DEFAULT '',
  external_message_id  TEXT NOT NULL DEFAULT '',
  body                 TEXT NOT NULL,
  body_purged          INTEGER NOT NULL DEFAULT 0 CHECK (body_purged IN (0,1)),
  send_state           TEXT NOT NULL DEFAULT '' CHECK (send_state IN ('','pending','sent','failed','held')),
  send_error           TEXT NOT NULL DEFAULT '',
  created_at           TEXT NOT NULL,
  read_at              TEXT NOT NULL DEFAULT '',
  replied_at           TEXT NOT NULL DEFAULT ''
);
INSERT INTO channel_messages_next
  (message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at)
  SELECT message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at
  FROM channel_messages;
DROP TABLE channel_messages;
ALTER TABLE channel_messages_next RENAME TO channel_messages;
CREATE UNIQUE INDEX channel_messages_update_key
  ON channel_messages(provider_update_key) WHERE provider_update_key <> '';
CREATE INDEX channel_messages_bot_pending
  ON channel_messages(bot_id, direction, replied_at, created_at);
CREATE INDEX channel_messages_binding_held
  ON channel_messages(binding_id, created_at) WHERE send_state = 'held';
CREATE INDEX channel_messages_outbound_external
  ON channel_messages(binding_id, external_message_id) WHERE direction = 'outbound' AND external_message_id <> '';

CREATE TABLE channel_push_events (
  seq                  INTEGER PRIMARY KEY AUTOINCREMENT,
  provider             TEXT NOT NULL CHECK (provider IN ('whatsapp')),
  event_key            TEXT NOT NULL UNIQUE,            -- section 8.4
  kind                 TEXT NOT NULL CHECK (kind IN ('text','start','disconnect','unsupported','delivery_failed')),
  external_chat_id     TEXT NOT NULL,
  external_user_id     TEXT NOT NULL DEFAULT '',
  external_message_id  TEXT NOT NULL DEFAULT '',
  sender_display       TEXT NOT NULL DEFAULT '',
  body                 TEXT NOT NULL DEFAULT '',        -- plaintext until processed, then ''
  provider_code        INTEGER NOT NULL DEFAULT 0,      -- delivery_failed: Graph error code
  provider_time        TEXT NOT NULL DEFAULT '',        -- RFC 3339 UTC of the provider timestamp
  received_at          TEXT NOT NULL,
  processed_at         TEXT NOT NULL DEFAULT ''
);
CREATE INDEX channel_push_events_pending
  ON channel_push_events(provider, seq) WHERE processed_at = '';

COMMIT;
