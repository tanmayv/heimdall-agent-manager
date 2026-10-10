CREATE TABLE IF NOT EXISTS user_conversation_launch_preferences (
  owner_user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
  payload_json TEXT NOT NULL DEFAULT '{}',
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Persist the identities of existing seeded favorites so rename does not unpin.
INSERT INTO user_conversation_launch_preferences (owner_user_id, payload_json)
SELECT owner_user_id, json_object('pinned_agent_ids',json_group_array(agent_id),
  'favorite_agent_ids',json_group_array(agent_id))
FROM agents WHERE slug IN ('coordinator','worker') GROUP BY owner_user_id
ON CONFLICT(owner_user_id) DO NOTHING;
