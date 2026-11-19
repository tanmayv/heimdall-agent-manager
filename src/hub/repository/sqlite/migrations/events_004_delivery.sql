-- Durable delivery metadata never retains a C message. Ack replies and topic
-- generations remain available across requests and hub restarts.
CREATE TABLE event_deliveries (
 subscription_id TEXT NOT NULL REFERENCES event_subscriptions(subscription_id) ON DELETE CASCADE,
 event_id TEXT NOT NULL,
 ack_reply TEXT NOT NULL,
 topic_key TEXT NOT NULL DEFAULT '',
 topic_generation INTEGER NOT NULL DEFAULT 0,
 stream_sequence INTEGER NOT NULL,
 acknowledged INTEGER NOT NULL DEFAULT 0,
 resolved_sent INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(subscription_id,event_id)
);
CREATE TABLE event_consumer_deletions (
 consumer_name TEXT PRIMARY KEY
);
CREATE TRIGGER event_subscription_deleted AFTER DELETE ON event_subscriptions
BEGIN
 INSERT OR IGNORE INTO event_consumer_deletions VALUES(old.consumer_name);
END;

-- The canonical membership and live claims drive role defaults in the same
-- transaction. Waiting is retained ownership; only ending the claim removes
-- the subscription. Explicit watches are independent.
CREATE VIEW event_role_scopes AS
SELECT DISTINCT m.owner_user_id, COALESCE(NULLIF(m.agent_id,''),ai.agent_id) AS subscriber_agent_id,
 m.chain_id, '' AS task_id, json_array('ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.state','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.state','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.review_requested_from_user','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.blocked_on_human','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.review_verdict','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.merge_conflict','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.work_finished') AS filter_subjects
FROM task_chain_members m LEFT JOIN agent_instances ai
 ON ai.agent_instance_id=m.agent_instance_id AND ai.owner_user_id=m.owner_user_id
WHERE m.role='coordinator' AND COALESCE(NULLIF(m.agent_id,''),ai.agent_id,'')!=''
UNION
SELECT l.owner_user_id, ai.agent_id, l.chain_id, l.task_id,
 json_array('ev.'||l.owner_user_id||'.chain.'||l.chain_id||'.task.'||l.task_id||'.requirements_changed')
FROM task_leases l JOIN agent_instances ai
 ON ai.agent_instance_id=l.holder_instance_id AND ai.owner_user_id=l.owner_user_id
WHERE l.kind='work' AND l.phase IN ('active','waiting') AND ai.agent_id!='';
CREATE TRIGGER event_roles_task_chain_members_insert AFTER INSERT ON task_chain_members
BEGIN

 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=new.owner_user_id AND event_subscriptions.chain_id=new.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_agent_id=event_subscriptions.subscriber_agent_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%SZ','now')
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_agent_id=v.subscriber_agent_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=new.owner_user_id AND v.chain_id=new.chain_id;
END;
CREATE TRIGGER event_roles_task_chain_members_update AFTER UPDATE ON task_chain_members
BEGIN

 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=new.owner_user_id AND event_subscriptions.chain_id=new.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_agent_id=event_subscriptions.subscriber_agent_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%SZ','now')
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_agent_id=v.subscriber_agent_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=new.owner_user_id AND v.chain_id=new.chain_id;
END;
CREATE TRIGGER event_roles_task_chain_members_delete AFTER DELETE ON task_chain_members
BEGIN

 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=old.owner_user_id AND event_subscriptions.chain_id=old.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_agent_id=event_subscriptions.subscriber_agent_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%SZ','now')
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_agent_id=v.subscriber_agent_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=old.owner_user_id AND v.chain_id=old.chain_id;
END;
CREATE TRIGGER event_roles_task_leases_insert AFTER INSERT ON task_leases
BEGIN

 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=new.owner_user_id AND event_subscriptions.chain_id=new.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_agent_id=event_subscriptions.subscriber_agent_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%SZ','now')
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_agent_id=v.subscriber_agent_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=new.owner_user_id AND v.chain_id=new.chain_id;
END;
CREATE TRIGGER event_roles_task_leases_update AFTER UPDATE ON task_leases
BEGIN

 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=new.owner_user_id AND event_subscriptions.chain_id=new.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_agent_id=event_subscriptions.subscriber_agent_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%SZ','now')
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_agent_id=v.subscriber_agent_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=new.owner_user_id AND v.chain_id=new.chain_id;
END;
CREATE TRIGGER event_roles_task_leases_delete AFTER DELETE ON task_leases
BEGIN

 DELETE FROM event_subscriptions WHERE event_subscriptions.source='role_default' AND event_subscriptions.owner_user_id=old.owner_user_id AND event_subscriptions.chain_id=old.chain_id
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=event_subscriptions.owner_user_id AND v.subscriber_agent_id=event_subscriptions.subscriber_agent_id
  AND v.chain_id=event_subscriptions.chain_id AND v.task_id=COALESCE(event_subscriptions.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%SZ','now')
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_agent_id=v.subscriber_agent_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND v.owner_user_id=old.owner_user_id AND v.chain_id=old.chain_id;
END;

 DELETE FROM event_subscriptions AS s WHERE s.source='role_default' AND 1=1
 AND NOT EXISTS(SELECT 1 FROM event_role_scopes v WHERE
  v.owner_user_id=s.owner_user_id AND v.subscriber_agent_id=s.subscriber_agent_id
  AND v.chain_id=s.chain_id AND v.task_id=COALESCE(s.task_id,''));
 INSERT OR IGNORE INTO event_subscriptions
 SELECT 'sub_'||lower(hex(randomblob(16))),v.owner_user_id,v.subscriber_agent_id,
 v.chain_id,NULLIF(v.task_id,''),'role_default',v.filter_subjects,'catalog',
 'inbox_'||lower(hex(randomblob(16))),strftime('%Y-%m-%dT%H:%M:%SZ','now')
 FROM event_role_scopes v WHERE NOT EXISTS(
 SELECT 1 FROM event_subscriptions existing WHERE existing.source='role_default'
 AND existing.owner_user_id=v.owner_user_id AND existing.subscriber_agent_id=v.subscriber_agent_id
 AND existing.chain_id=v.chain_id AND COALESCE(existing.task_id,'')=v.task_id
) AND 1=1;
