-- Lookup indexes for the hot list paths.
--
-- chat_messages had only its primary key, so the eight correlated subqueries
-- content_list_conversations runs per conversation (last message id/direction/
-- sender/type/status/created_at, plus a COUNT) each scanned the whole table.
-- Measured on a production database (165 conversations, 3491 messages) one
-- listing took 1392 ms; with this index it takes 4 ms. Column order matches the
-- subqueries' filter (conversation_id, owner_user_id) then their ORDER BY
-- (created_at DESC, message_id DESC), so each becomes a single seek.
CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation_recent
  ON chat_messages(conversation_id, owner_user_id, created_at DESC, message_id DESC);

-- tasks is filtered by chain within an owner on every chain read, and the
-- task-chains list now rolls up a per-chain COUNT in one grouped pass.
CREATE INDEX IF NOT EXISTS idx_tasks_chain_owner ON tasks(chain_id, owner_user_id);

-- task_comments carries the same shape for its per-task rollup.
CREATE INDEX IF NOT EXISTS idx_task_comments_task_owner
  ON task_comments(task_id, owner_user_id, created_at DESC, comment_id DESC);
