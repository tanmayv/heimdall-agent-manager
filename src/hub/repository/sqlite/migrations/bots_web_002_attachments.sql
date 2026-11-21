BEGIN IMMEDIATE;
CREATE TABLE channel_attachments_next (
  attachment_id   TEXT PRIMARY KEY,                     -- "cha_..."
  message_id      TEXT NOT NULL,                 -- channel_messages.message_id; multiple uploads per web message
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
INSERT INTO channel_attachments_next SELECT * FROM channel_attachments;
DROP TABLE channel_attachments;
ALTER TABLE channel_attachments_next RENAME TO channel_attachments;
CREATE INDEX channel_attachments_bot ON channel_attachments(bot_id, state);
CREATE INDEX channel_attachments_message ON channel_attachments(message_id);
COMMIT;
