-- Agent-to-agent messages are delivered to the target instance inbox, but they
-- must not drive the human-facing conversation transcript/preview.
-- Code now filters them out of /api/v1/chats/*/messages and stops updating
-- chat_conversations when sending agent_to_agent. This migration repairs
-- conversations whose last human-visible preview was overwritten by a2a traffic.
UPDATE chat_conversations
SET
  last_message_preview = COALESCE((
    SELECT m.body
    FROM chat_messages m
    WHERE m.conversation_id = chat_conversations.conversation_id
      AND m.owner_user_id = chat_conversations.owner_user_id
      AND m.direction != 'agent_to_agent'
    ORDER BY m.created_at DESC
    LIMIT 1
  ), ''),
  last_message_at = COALESCE((
    SELECT m.created_at
    FROM chat_messages m
    WHERE m.conversation_id = chat_conversations.conversation_id
      AND m.owner_user_id = chat_conversations.owner_user_id
      AND m.direction != 'agent_to_agent'
    ORDER BY m.created_at DESC
    LIMIT 1
  ), ''),
  updated_at = COALESCE((
    SELECT m.created_at
    FROM chat_messages m
    WHERE m.conversation_id = chat_conversations.conversation_id
      AND m.owner_user_id = chat_conversations.owner_user_id
      AND m.direction != 'agent_to_agent'
    ORDER BY m.created_at DESC
    LIMIT 1
  ), chat_conversations.updated_at)
WHERE EXISTS (
  SELECT 1 FROM chat_messages a
  WHERE a.conversation_id = chat_conversations.conversation_id
    AND a.owner_user_id = chat_conversations.owner_user_id
    AND a.direction = 'agent_to_agent'
)
AND NOT EXISTS (
  SELECT 1 FROM chat_messages newer_visible
  WHERE newer_visible.conversation_id = chat_conversations.conversation_id
    AND newer_visible.owner_user_id = chat_conversations.owner_user_id
    AND newer_visible.direction != 'agent_to_agent'
    AND newer_visible.created_at > (
      SELECT MAX(a2a.created_at)
      FROM chat_messages a2a
      WHERE a2a.conversation_id = chat_conversations.conversation_id
        AND a2a.owner_user_id = chat_conversations.owner_user_id
        AND a2a.direction = 'agent_to_agent'
    )
);
