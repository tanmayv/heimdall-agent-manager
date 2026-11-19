-- Subscription identity survives instance restarts. Network provisioning is
-- reconciled after commit; no JetStream operation belongs in a SQLite UoW.
CREATE TABLE event_subscriptions (
 subscription_id TEXT PRIMARY KEY CHECK(subscription_id != ''),
 owner_user_id TEXT NOT NULL CHECK(owner_user_id != ''),
 subscriber_agent_id TEXT NOT NULL CHECK(subscriber_agent_id != ''),
 chain_id TEXT NOT NULL CHECK(chain_id != ''),
 task_id TEXT,
 source TEXT NOT NULL CHECK(source IN ('role_default','explicit')),
 filter_subjects TEXT NOT NULL CHECK(json_valid(filter_subjects) AND json_type(filter_subjects) = 'array'),
 wake_policy TEXT NOT NULL,
 consumer_name TEXT NOT NULL UNIQUE CHECK(consumer_name != ''),
 created_at TEXT NOT NULL,
 CHECK(task_id IS NULL OR task_id != '')
);
CREATE UNIQUE INDEX event_subscriptions_scope
 ON event_subscriptions(owner_user_id,subscriber_agent_id,chain_id,COALESCE(task_id,''),source);
CREATE INDEX event_subscriptions_subscriber
 ON event_subscriptions(owner_user_id,subscriber_agent_id);
