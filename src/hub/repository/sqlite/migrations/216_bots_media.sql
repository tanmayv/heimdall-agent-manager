-- 212_bots_media.sql: media attachments for bots (experiment "bots").
-- Rebuilds channel_push_events to accept media events, carrying every row and seq
-- unchanged, and adds channel_attachments. No column stores media bytes.
BEGIN IMMEDIATE;

CREATE TABLE channel_push_events_next (
  seq                  INTEGER PRIMARY KEY AUTOINCREMENT,
  provider             TEXT NOT NULL CHECK (provider IN ('whatsapp')),
  event_key            TEXT NOT NULL UNIQUE,
  kind                 TEXT NOT NULL CHECK (kind IN ('text','start','disconnect','unsupported','delivery_failed','media')),
  external_chat_id     TEXT NOT NULL,
  external_user_id     TEXT NOT NULL DEFAULT '',
  external_message_id  TEXT NOT NULL DEFAULT '',
  sender_display       TEXT NOT NULL DEFAULT '',
  body                 TEXT NOT NULL DEFAULT '',        -- plaintext until processed, then ''
  provider_code        INTEGER NOT NULL DEFAULT 0,
  provider_time        TEXT NOT NULL DEFAULT '',
  received_at          TEXT NOT NULL,
  processed_at         TEXT NOT NULL DEFAULT '',
  media_kind           TEXT NOT NULL DEFAULT '' CHECK (media_kind IN ('','image','document','voice','audio')),
  media_ref            TEXT NOT NULL DEFAULT '',        -- provider file reference until processed, then ''
  media_name           TEXT NOT NULL DEFAULT '',        -- until processed, then ''
  media_mime           TEXT NOT NULL DEFAULT '',
  media_size           INTEGER NOT NULL DEFAULT 0       -- provider-declared bytes; 0 = unknown
);
INSERT INTO channel_push_events_next
  (seq, provider, event_key, kind, external_chat_id, external_user_id, external_message_id, sender_display, body, provider_code, provider_time, received_at, processed_at)
  SELECT seq, provider, event_key, kind, external_chat_id, external_user_id, external_message_id, sender_display, body, provider_code, provider_time, received_at, processed_at
  FROM channel_push_events;
DROP TABLE channel_push_events;
ALTER TABLE channel_push_events_next RENAME TO channel_push_events;
CREATE INDEX channel_push_events_pending
  ON channel_push_events(provider, seq) WHERE processed_at = '';

CREATE TABLE channel_attachments (
  attachment_id   TEXT PRIMARY KEY,                     -- "cha_..."
  message_id      TEXT NOT NULL UNIQUE,                 -- channel_messages.message_id; one attachment per message
  binding_id      TEXT NOT NULL,
  owner_user_id   TEXT NOT NULL,
  bot_id          TEXT NOT NULL,
  direction       TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  kind            TEXT NOT NULL CHECK (kind IN ('image','document','voice','audio')),
  file_ref        TEXT NOT NULL DEFAULT '',             -- inbound: Telegram file_id or WhatsApp media id; outbound: ''
  name            TEXT NOT NULL DEFAULT '',
  mime            TEXT NOT NULL DEFAULT '',             -- base MIME type (D8)
  size_bytes      INTEGER NOT NULL DEFAULT 0,           -- inbound: provider-declared, 0 = unknown; outbound: exact
  artifact_id     TEXT NOT NULL DEFAULT '',
  state           TEXT NOT NULL CHECK (state IN ('pending','stored','too_large','unavailable','native','link')),
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);
CREATE INDEX channel_attachments_bot
  ON channel_attachments(bot_id, state);

COMMIT;
