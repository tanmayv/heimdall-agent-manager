CREATE INDEX IF NOT EXISTS action_instances_owner_agent_bridge ON agent_instances(owner_user_id, agent_id, bridge_id, created_at DESC, agent_instance_id DESC) WHERE kind = 'agent';
CREATE INDEX IF NOT EXISTS action_conversations_owner_instance ON chat_conversations(owner_user_id, agent_instance_id, created_at DESC, conversation_id DESC);
