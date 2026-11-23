-- ACP user-input delivery evidence and conversation-level Send now batches.
-- Bridge reports are monotonic per row (report_seq) and fenced by launch_epoch.
CREATE TABLE IF NOT EXISTS acp_input_deliveries (
  message_id TEXT PRIMARY KEY REFERENCES chat_messages(message_id) ON DELETE CASCADE,
  owner_user_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  agent_instance_id TEXT NOT NULL,
  launch_epoch TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL CHECK (state IN ('sent','queued','dispatching','delivered','discarded')),
  hold_reason TEXT NOT NULL DEFAULT '' CHECK (hold_reason IN ('','turn_active','dispatch_pending')),
  mode TEXT NOT NULL DEFAULT '' CHECK (mode IN ('','prompt','steer','read')),
  turn_id TEXT NOT NULL DEFAULT '',
  batch_id TEXT NOT NULL DEFAULT '',
  error TEXT NOT NULL DEFAULT '',
  report_seq INTEGER NOT NULL DEFAULT 0 CHECK (report_seq >= 0),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  delivered_at TEXT NOT NULL DEFAULT '',
  agent_read_at TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS acp_input_deliveries_conversation ON acp_input_deliveries(conversation_id, state, created_at);
CREATE INDEX IF NOT EXISTS acp_input_deliveries_instance ON acp_input_deliveries(agent_instance_id, state);

CREATE TABLE IF NOT EXISTS acp_send_now_batches (
  batch_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  agent_instance_id TEXT NOT NULL,
  launch_epoch TEXT NOT NULL,
  request_id TEXT NOT NULL,
  attempt INTEGER NOT NULL DEFAULT 1 CHECK (attempt >= 1),
  state TEXT NOT NULL CHECK (state IN ('pending','sent','dispatching','delivered','empty','failed')),
  error TEXT NOT NULL DEFAULT '',
  member_ids_json TEXT NOT NULL DEFAULT '[]',
  excluded_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (conversation_id, request_id)
);
CREATE INDEX IF NOT EXISTS acp_send_now_batches_conversation ON acp_send_now_batches(conversation_id, created_at);

CREATE TABLE IF NOT EXISTS acp_input_runtime (
  agent_instance_id TEXT PRIMARY KEY,
  launch_epoch TEXT NOT NULL,
  steering_supported INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
