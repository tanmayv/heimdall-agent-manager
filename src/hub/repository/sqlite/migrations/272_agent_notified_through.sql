-- The PTY unread tray's message high-water mark: the newest user->agent
-- message a typed unread-messages notice covered ('' = never), with that
-- message's created_at so transcript order (created_at, message_id) compares
-- without a join. Written only by a monotonic UPDATE
-- (content_note_agent_notified), never by the conversation save.
-- The second column is added last: run_migrations treats it as completion.
BEGIN IMMEDIATE;
ALTER TABLE chat_conversations ADD COLUMN agent_notified_message_id TEXT NOT NULL DEFAULT '';
ALTER TABLE chat_conversations ADD COLUMN agent_notified_message_at TEXT NOT NULL DEFAULT '';
COMMIT;
