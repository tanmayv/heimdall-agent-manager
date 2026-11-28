-- Reply origin (R7): which user->agent inputs an agent reply answers.
--
-- chat_messages.origin: the channel a user message arrived from. NULL means
-- local (web UI / ctl). Nothing writes it yet; the bot channel work fills it.
--
-- chat_input_consumptions: the first time the agent consumed a user input
-- (ACP inline delivery, or the agent's own marking `chat read`). seq orders
-- consumption across restarts; one row per message (first consumption wins).
--
-- chat_reply_watermarks: per conversation, the consumption point of the last
-- reply (through_seq) and that reply's id. A reply answers the inputs
-- consumed after through_seq; the watermark advances in the reply's unit of
-- work. The reply's answered ids and route status live only in its
-- metadata_json ("reply_origin"); the watermark points at that reply.
-- The watermark table is created last: run_migrations treats it as completion.
BEGIN IMMEDIATE;
ALTER TABLE chat_messages ADD COLUMN origin TEXT;
CREATE TABLE chat_input_consumptions (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id TEXT NOT NULL UNIQUE,
  owner_user_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('delivered', 'read')),
  consumed_at TEXT NOT NULL
);
CREATE INDEX idx_chat_input_consumptions_conversation ON chat_input_consumptions(conversation_id, seq);
CREATE TABLE chat_reply_watermarks (
  conversation_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  through_seq INTEGER NOT NULL DEFAULT 0,
  reply_message_id TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
COMMIT;
