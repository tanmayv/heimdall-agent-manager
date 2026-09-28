CREATE TABLE IF NOT EXISTS task_subscriptions (
    subscription_id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    subscriber_agent_instance_id TEXT NOT NULL,
    chain_id TEXT NOT NULL,
    task_id TEXT NOT NULL DEFAULT '',
    event_type TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(subscriber_agent_instance_id, chain_id, task_id, event_type)
);
CREATE INDEX IF NOT EXISTS idx_task_sub_chain ON task_subscriptions(chain_id, event_type);
CREATE INDEX IF NOT EXISTS idx_task_sub_task ON task_subscriptions(task_id, event_type);
