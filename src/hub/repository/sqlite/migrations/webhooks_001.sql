CREATE TABLE event_webhooks (
 webhook_id TEXT PRIMARY KEY CHECK(webhook_id != ''),
 owner_user_id TEXT NOT NULL CHECK(owner_user_id != ''),
 name TEXT NOT NULL DEFAULT '',
 token_hash TEXT NOT NULL CHECK(token_hash != ''),
 enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 last_received_at TEXT NOT NULL DEFAULT ''
);
CREATE INDEX event_webhooks_owner ON event_webhooks(owner_user_id);
