-- EV2 (REQ-EVP-1..3): an event subscription belongs to one agent INSTANCE,
-- not to the durable agent identity that every instance of that agent shares.
--
-- subscriber_agent_id stays as an informational column (the instance's agent)
-- so a hub process still running the previous build during a rolling restart
-- keeps working against this schema; nothing keys on it any more.
BEGIN IMMEDIATE;
ALTER TABLE event_subscriptions ADD COLUMN subscriber_instance_id TEXT NOT NULL DEFAULT '';

-- Every delete releases the subscription's pending deliveries and queues its
-- JetStream consumer for deletion, whether or not foreign keys are enforced.
-- The runtime deletes queued consumers and treats "not found" as done, so the
-- queue is idempotent across restarts (REQ-EVP-2, REQ-EVP-3).
DROP TRIGGER IF EXISTS event_subscription_deleted;
CREATE TRIGGER event_subscription_deleted AFTER DELETE ON event_subscriptions
BEGIN
 DELETE FROM event_deliveries WHERE subscription_id=old.subscription_id;
 INSERT OR IGNORE INTO event_consumer_deletions VALUES(old.consumer_name);
END;

-- One-time cleanup of the identity-keyed rows (REQ-EVP-3). A bot's explicit
-- watches move to the bot's canonical instance; every other row is deleted.
-- Role defaults are derived again below, for the instances that hold the role.
--
-- created_at is also where a subscription's consumer starts reading
-- (DeliverByStartTime, eventinbox.subscription_start_ns), so a subscription
-- created here never replays the stream's 14-day retention. A moved bot watch
-- therefore gets a new consumer starting now: its old consumer (which reads
-- from the start of the stream) and its deliveries are released first.
INSERT OR IGNORE INTO event_consumer_deletions
SELECT consumer_name FROM event_subscriptions WHERE source='explicit' AND EXISTS(
 SELECT 1 FROM bots b JOIN agent_instances ai
  ON ai.agent_instance_id=b.agent_instance_id AND ai.owner_user_id=b.owner_user_id
 WHERE b.owner_user_id=event_subscriptions.owner_user_id AND b.agent_id=event_subscriptions.subscriber_agent_id
  AND b.agent_instance_id!='' AND ai.stopped_by='');
DELETE FROM event_deliveries WHERE subscription_id IN(SELECT subscription_id FROM event_subscriptions WHERE source='explicit' AND EXISTS(
 SELECT 1 FROM bots b JOIN agent_instances ai
  ON ai.agent_instance_id=b.agent_instance_id AND ai.owner_user_id=b.owner_user_id
 WHERE b.owner_user_id=event_subscriptions.owner_user_id AND b.agent_id=event_subscriptions.subscriber_agent_id
  AND b.agent_instance_id!='' AND ai.stopped_by=''));
UPDATE event_subscriptions SET consumer_name='inbox_'||lower(hex(randomblob(16))),
 created_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), subscriber_instance_id=(
 SELECT b.agent_instance_id FROM bots b
 WHERE b.owner_user_id=event_subscriptions.owner_user_id AND b.agent_id=event_subscriptions.subscriber_agent_id)
WHERE source='explicit' AND EXISTS(
 SELECT 1 FROM bots b JOIN agent_instances ai
  ON ai.agent_instance_id=b.agent_instance_id AND ai.owner_user_id=b.owner_user_id
 WHERE b.owner_user_id=event_subscriptions.owner_user_id AND b.agent_id=event_subscriptions.subscriber_agent_id
  AND b.agent_instance_id!='' AND ai.stopped_by='');
DELETE FROM event_subscriptions WHERE subscriber_instance_id='';

DROP INDEX IF EXISTS event_subscriptions_scope;
DROP INDEX IF EXISTS event_subscriptions_subscriber;
CREATE UNIQUE INDEX event_subscriptions_scope
 ON event_subscriptions(owner_user_id,subscriber_instance_id,chain_id,COALESCE(task_id,''),source);
CREATE INDEX event_subscriptions_subscriber
 ON event_subscriptions(owner_user_id,subscriber_instance_id);

DROP TRIGGER IF EXISTS event_roles_task_chain_members_insert;
DROP TRIGGER IF EXISTS event_roles_task_chain_members_update;
DROP TRIGGER IF EXISTS event_roles_task_chain_members_delete;
DROP TRIGGER IF EXISTS event_roles_task_leases_insert;
DROP TRIGGER IF EXISTS event_roles_task_leases_update;
DROP TRIGGER IF EXISTS event_roles_task_leases_delete;
DROP VIEW IF EXISTS event_role_scopes;

-- Role defaults belong to the instance that holds the role: the coordinator
-- member's instance for the chain, the work-claim holder for its task. An
-- instance the user stopped (stopped_by != '') holds no subscriptions (E3).
-- An idle-stopped or crashed instance keeps them: coordinator wake and bot
-- relaunch restart the SAME instance, which must still receive the events
-- published while it was down (and a wake-worthy event can start it).
CREATE VIEW event_role_scopes AS
SELECT DISTINCT m.owner_user_id, m.agent_instance_id AS subscriber_instance_id,
 COALESCE(NULLIF(ai.agent_id,''),NULLIF(m.agent_id,''),m.agent_instance_id) AS subscriber_agent_id,
 m.chain_id, '' AS task_id, json_array('ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.state','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.state','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.review_requested_from_user','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.blocked_on_human','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.review_verdict','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.merge_conflict','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.work_finished') AS filter_subjects
FROM task_chain_members m LEFT JOIN agent_instances ai
 ON ai.agent_instance_id=m.agent_instance_id AND ai.owner_user_id=m.owner_user_id
WHERE m.role='coordinator' AND m.agent_instance_id!='' AND COALESCE(ai.stopped_by,'')=''
UNION
SELECT l.owner_user_id, l.holder_instance_id, COALESCE(NULLIF(ai.agent_id,''),l.holder_instance_id), l.chain_id, l.task_id,
 json_array('ev.'||l.owner_user_id||'.chain.'||l.chain_id||'.task.'||l.task_id||'.requirements_changed')
FROM task_leases l LEFT JOIN agent_instances ai
 ON ai.agent_instance_id=l.holder_instance_id AND ai.owner_user_id=l.owner_user_id
WHERE l.kind='work' AND l.phase IN ('active','waiting') AND l.holder_instance_id!='' AND COALESCE(ai.stopped_by,'')='';

-- Chain-scoped resync: membership or claim changes (coordinator reassignment,
-- claim release, transfer, completion) drop the old holder's role defaults
-- and create fresh ones for the new holder in the same transaction.
CREATE TRIGGER event_roles_task_chain_members_insert AFTER INSERT ON task_chain_members
BEGIN
 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=new.owner_user_id AND event_subscriptions.chain_id=new.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_instance_id=event_subscriptions.subscriber_instance_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,task_id,source,filter_subjects,wake_policy,consumer_name,created_at,subscriber_instance_id)
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%fZ','now'),v.subscriber_instance_id
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_instance_id=v.subscriber_instance_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=new.owner_user_id AND v.chain_id=new.chain_id;
END;
CREATE TRIGGER event_roles_task_chain_members_update AFTER UPDATE ON task_chain_members
BEGIN
 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=new.owner_user_id AND event_subscriptions.chain_id=new.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_instance_id=event_subscriptions.subscriber_instance_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,task_id,source,filter_subjects,wake_policy,consumer_name,created_at,subscriber_instance_id)
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%fZ','now'),v.subscriber_instance_id
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_instance_id=v.subscriber_instance_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=new.owner_user_id AND v.chain_id=new.chain_id;
 -- A Dead instance (terminated, or failed without a typed error) that this
 -- change left without any role has been superseded: its subscriptions end.
 DELETE FROM event_subscriptions WHERE owner_user_id=old.owner_user_id
 AND subscriber_instance_id IN(SELECT ai.agent_instance_id FROM agent_instances ai
  WHERE ai.agent_instance_id=old.agent_instance_id AND ai.owner_user_id=old.owner_user_id AND (ai.runtime_status='terminated' OR (ai.runtime_status='failed' AND COALESCE(ai.last_error_json,'')='')) AND NOT (EXISTS(SELECT 1 FROM task_chain_members m WHERE m.owner_user_id=ai.owner_user_id AND m.agent_instance_id=ai.agent_instance_id AND m.role='coordinator')
  OR EXISTS(SELECT 1 FROM task_leases l WHERE l.owner_user_id=ai.owner_user_id AND l.holder_instance_id=ai.agent_instance_id AND l.kind='work' AND l.phase IN ('active','waiting'))
  OR EXISTS(SELECT 1 FROM bots b WHERE b.owner_user_id=ai.owner_user_id AND b.agent_instance_id=ai.agent_instance_id)));
END;
CREATE TRIGGER event_roles_task_chain_members_delete AFTER DELETE ON task_chain_members
BEGIN
 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=old.owner_user_id AND event_subscriptions.chain_id=old.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_instance_id=event_subscriptions.subscriber_instance_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,task_id,source,filter_subjects,wake_policy,consumer_name,created_at,subscriber_instance_id)
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%fZ','now'),v.subscriber_instance_id
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_instance_id=v.subscriber_instance_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=old.owner_user_id AND v.chain_id=old.chain_id;
 -- A Dead instance (terminated, or failed without a typed error) that this
 -- change left without any role has been superseded: its subscriptions end.
 DELETE FROM event_subscriptions WHERE owner_user_id=old.owner_user_id
 AND subscriber_instance_id IN(SELECT ai.agent_instance_id FROM agent_instances ai
  WHERE ai.agent_instance_id=old.agent_instance_id AND ai.owner_user_id=old.owner_user_id AND (ai.runtime_status='terminated' OR (ai.runtime_status='failed' AND COALESCE(ai.last_error_json,'')='')) AND NOT (EXISTS(SELECT 1 FROM task_chain_members m WHERE m.owner_user_id=ai.owner_user_id AND m.agent_instance_id=ai.agent_instance_id AND m.role='coordinator')
  OR EXISTS(SELECT 1 FROM task_leases l WHERE l.owner_user_id=ai.owner_user_id AND l.holder_instance_id=ai.agent_instance_id AND l.kind='work' AND l.phase IN ('active','waiting'))
  OR EXISTS(SELECT 1 FROM bots b WHERE b.owner_user_id=ai.owner_user_id AND b.agent_instance_id=ai.agent_instance_id)));
END;
CREATE TRIGGER event_roles_task_leases_insert AFTER INSERT ON task_leases
BEGIN
 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=new.owner_user_id AND event_subscriptions.chain_id=new.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_instance_id=event_subscriptions.subscriber_instance_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,task_id,source,filter_subjects,wake_policy,consumer_name,created_at,subscriber_instance_id)
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%fZ','now'),v.subscriber_instance_id
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_instance_id=v.subscriber_instance_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=new.owner_user_id AND v.chain_id=new.chain_id;
END;
CREATE TRIGGER event_roles_task_leases_update AFTER UPDATE ON task_leases
BEGIN
 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=new.owner_user_id AND event_subscriptions.chain_id=new.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_instance_id=event_subscriptions.subscriber_instance_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,task_id,source,filter_subjects,wake_policy,consumer_name,created_at,subscriber_instance_id)
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%fZ','now'),v.subscriber_instance_id
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_instance_id=v.subscriber_instance_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=new.owner_user_id AND v.chain_id=new.chain_id;
 -- A Dead instance (terminated, or failed without a typed error) that this
 -- change left without any role has been superseded: its subscriptions end.
 DELETE FROM event_subscriptions WHERE owner_user_id=old.owner_user_id
 AND subscriber_instance_id IN(SELECT ai.agent_instance_id FROM agent_instances ai
  WHERE ai.agent_instance_id=old.holder_instance_id AND ai.owner_user_id=old.owner_user_id AND (ai.runtime_status='terminated' OR (ai.runtime_status='failed' AND COALESCE(ai.last_error_json,'')='')) AND NOT (EXISTS(SELECT 1 FROM task_chain_members m WHERE m.owner_user_id=ai.owner_user_id AND m.agent_instance_id=ai.agent_instance_id AND m.role='coordinator')
  OR EXISTS(SELECT 1 FROM task_leases l WHERE l.owner_user_id=ai.owner_user_id AND l.holder_instance_id=ai.agent_instance_id AND l.kind='work' AND l.phase IN ('active','waiting'))
  OR EXISTS(SELECT 1 FROM bots b WHERE b.owner_user_id=ai.owner_user_id AND b.agent_instance_id=ai.agent_instance_id)));
END;
CREATE TRIGGER event_roles_task_leases_delete AFTER DELETE ON task_leases
BEGIN
 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=old.owner_user_id AND event_subscriptions.chain_id=old.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_instance_id=event_subscriptions.subscriber_instance_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,task_id,source,filter_subjects,wake_policy,consumer_name,created_at,subscriber_instance_id)
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%fZ','now'),v.subscriber_instance_id
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_instance_id=v.subscriber_instance_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=old.owner_user_id AND v.chain_id=old.chain_id;
 -- A Dead instance (terminated, or failed without a typed error) that this
 -- change left without any role has been superseded: its subscriptions end.
 DELETE FROM event_subscriptions WHERE owner_user_id=old.owner_user_id
 AND subscriber_instance_id IN(SELECT ai.agent_instance_id FROM agent_instances ai
  WHERE ai.agent_instance_id=old.holder_instance_id AND ai.owner_user_id=old.owner_user_id AND (ai.runtime_status='terminated' OR (ai.runtime_status='failed' AND COALESCE(ai.last_error_json,'')='')) AND NOT (EXISTS(SELECT 1 FROM task_chain_members m WHERE m.owner_user_id=ai.owner_user_id AND m.agent_instance_id=ai.agent_instance_id AND m.role='coordinator')
  OR EXISTS(SELECT 1 FROM task_leases l WHERE l.owner_user_id=ai.owner_user_id AND l.holder_instance_id=ai.agent_instance_id AND l.kind='work' AND l.phase IN ('active','waiting'))
  OR EXISTS(SELECT 1 FROM bots b WHERE b.owner_user_id=ai.owner_user_id AND b.agent_instance_id=ai.agent_instance_id)));
END;

-- Instance lifecycle (REQ-EVP-2, E3).
-- A user stop ends every subscription the instance owns (role defaults and
-- explicit watches), with its deliveries and consumers. A later explicit start
-- clears stopped_by; the instance then gets fresh role defaults for the roles
-- it still holds, starting at that moment (no backlog).
CREATE TRIGGER event_instance_stopped AFTER UPDATE OF stopped_by ON agent_instances
WHEN new.stopped_by!='' AND old.stopped_by=''
BEGIN
 DELETE FROM event_subscriptions
 WHERE owner_user_id=new.owner_user_id AND subscriber_instance_id=new.agent_instance_id;
END;
CREATE TRIGGER event_instance_restarted AFTER UPDATE OF stopped_by ON agent_instances
WHEN new.stopped_by='' AND old.stopped_by!=''
BEGIN
 INSERT OR IGNORE INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,task_id,source,filter_subjects,wake_policy,consumer_name,created_at,subscriber_instance_id)
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%fZ','now'),v.subscriber_instance_id
 FROM event_role_scopes v WHERE v.owner_user_id=new.owner_user_id AND v.subscriber_instance_id=new.agent_instance_id;
END;
-- A crash or termination alone ends nothing: the same instance may be
-- relaunched in place. The instance is superseded, and its subscriptions end,
-- only once it is Dead AND holds no role (no coordinator membership, no live
-- work claim, not the bot's instance). The member and claim triggers above
-- check this when a role moves away; this one when the instance dies after its
-- roles have already moved.
CREATE TRIGGER event_instance_superseded AFTER UPDATE OF runtime_status,last_error_json ON agent_instances
WHEN (new.runtime_status='terminated' OR (new.runtime_status='failed' AND COALESCE(new.last_error_json,'')='')) AND NOT (old.runtime_status='terminated' OR (old.runtime_status='failed' AND COALESCE(old.last_error_json,'')='')) AND NOT (EXISTS(SELECT 1 FROM task_chain_members m WHERE m.owner_user_id=new.owner_user_id AND m.agent_instance_id=new.agent_instance_id AND m.role='coordinator')
  OR EXISTS(SELECT 1 FROM task_leases l WHERE l.owner_user_id=new.owner_user_id AND l.holder_instance_id=new.agent_instance_id AND l.kind='work' AND l.phase IN ('active','waiting'))
  OR EXISTS(SELECT 1 FROM bots b WHERE b.owner_user_id=new.owner_user_id AND b.agent_instance_id=new.agent_instance_id))
BEGIN
 DELETE FROM event_subscriptions
 WHERE owner_user_id=new.owner_user_id AND subscriber_instance_id=new.agent_instance_id;
END;
CREATE TRIGGER event_instance_deleted AFTER DELETE ON agent_instances
BEGIN
 DELETE FROM event_subscriptions
 WHERE owner_user_id=old.owner_user_id AND subscriber_instance_id=old.agent_instance_id;
END;
-- A bot that moves to a new instance has replaced the old one: the old
-- instance's subscriptions end with it.
CREATE TRIGGER event_bot_instance_replaced AFTER UPDATE OF agent_instance_id ON bots
WHEN old.agent_instance_id!='' AND old.agent_instance_id!=new.agent_instance_id
BEGIN
 DELETE FROM event_subscriptions
 WHERE owner_user_id=old.owner_user_id AND subscriber_instance_id=old.agent_instance_id;
END;

-- Derive the role defaults for the current role holders.
INSERT OR IGNORE INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,task_id,source,filter_subjects,wake_policy,consumer_name,created_at,subscriber_instance_id)
SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%fZ','now'),v.subscriber_instance_id
FROM event_role_scopes v;
COMMIT;
