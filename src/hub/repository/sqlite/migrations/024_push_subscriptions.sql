CREATE TABLE IF NOT EXISTS push_subscriptions (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_push_subscriptions_endpoint ON push_subscriptions(endpoint);
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_owner ON push_subscriptions(owner_user_id);
CREATE TRIGGER IF NOT EXISTS push_subscriptions_owner_immutable BEFORE UPDATE OF owner_user_id ON push_subscriptions BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
