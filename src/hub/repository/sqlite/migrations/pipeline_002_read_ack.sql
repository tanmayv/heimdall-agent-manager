-- Allow delivered (awaiting read) without changing retry/open indexes.
CREATE TABLE pipeline_deliveries_read_ack (
  delivery_id TEXT PRIMARY KEY CHECK(delivery_id != ''),
  owner_user_id TEXT NOT NULL CHECK(owner_user_id != ''),
  kind TEXT NOT NULL CHECK(kind IN ('prompt','notice','bot','lease')),
  bridge_id TEXT NOT NULL CHECK(bridge_id != ''),
  agent_instance_id TEXT NOT NULL CHECK(agent_instance_id != ''),
  ref TEXT NOT NULL,                       -- run:<run_id> | sub:<agent_instance_id> | bot:<attempt_id> | lease:<lease_id>
  message_id TEXT NOT NULL DEFAULT '',     -- the chat message of a prompt or notice
  state TEXT NOT NULL CHECK(state IN ('routed','forwarded','delivered','done','failed','replaced')),
  outcome TEXT NOT NULL DEFAULT '',        -- state done: started | notified | accepted
  reason TEXT NOT NULL DEFAULT '',         -- state failed: 6.11.9
  round INTEGER NOT NULL DEFAULT 0,        -- placement round, 0..2 (6.11.7)
  excluded_bridges TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(excluded_bridges)),
  attempt INTEGER NOT NULL DEFAULT 0,      -- num_delivered of the newest forward
  ack_reply TEXT NOT NULL DEFAULT '',      -- JetStream reply subject of the newest forward
  stream_sequence INTEGER NOT NULL DEFAULT 0,
  retry_at TEXT NOT NULL DEFAULT '',       -- set by a retry answer: when JetStream redelivers; '' while a frame is in flight
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  forwarded_at TEXT NOT NULL DEFAULT '',   -- first forward
  updated_at TEXT NOT NULL
);
INSERT INTO pipeline_deliveries_read_ack SELECT * FROM pipeline_deliveries;
DROP TABLE pipeline_deliveries;
ALTER TABLE pipeline_deliveries_read_ack RENAME TO pipeline_deliveries;
CREATE INDEX pipeline_deliveries_open ON pipeline_deliveries(bridge_id,created_at,delivery_id) WHERE state IN ('routed','forwarded');
CREATE INDEX pipeline_deliveries_ref  ON pipeline_deliveries(ref);
CREATE INDEX pipeline_deliveries_expiry ON pipeline_deliveries(expires_at) WHERE state IN ('routed','forwarded');       -- S2: expired (6.16)
CREATE INDEX pipeline_deliveries_closed ON pipeline_deliveries(updated_at) WHERE state IN ('done','failed','replaced'); -- S2: prune (6.11.10)
CREATE TRIGGER pipeline_deliveries_owner_immutable BEFORE UPDATE OF owner_user_id ON pipeline_deliveries
  BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE INDEX pipeline_deliveries_message_read ON pipeline_deliveries(message_id) WHERE kind='prompt' AND state='delivered';
-- Preserve the bot idle-stop lookup when this rebuild follows actions_004.
CREATE INDEX IF NOT EXISTS pipeline_deliveries_instance_prompt_pending ON pipeline_deliveries(agent_instance_id) WHERE kind = 'prompt' AND state IN ('routed','forwarded','delivered');
