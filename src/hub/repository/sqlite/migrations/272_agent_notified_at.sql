-- When the bridge last typed the notice that points a PTY agent at its unread
-- messages ('' = never). The UI shows an unread user message as notified when
-- it was created at or before this time. Written only by a monotonic UPDATE
-- (content_note_agent_notified), never by the conversation save.
-- One atomic statement; run_migrations treats the column as completion.
ALTER TABLE chat_conversations ADD COLUMN agent_notified_at TEXT NOT NULL DEFAULT '';
