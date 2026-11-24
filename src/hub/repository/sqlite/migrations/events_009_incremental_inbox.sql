BEGIN IMMEDIATE;
DROP VIEW event_role_scopes;
CREATE VIEW event_role_scopes AS
SELECT DISTINCT m.owner_user_id, m.agent_instance_id AS subscriber_instance_id,
 COALESCE(NULLIF(ai.agent_id,''),NULLIF(m.agent_id,''),m.agent_instance_id) AS subscriber_agent_id,
 m.chain_id, '' AS task_id, json_array('ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.state','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.state','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.review_requested_from_user','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.blocked_on_human','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.review_verdict','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.task.*.merge_conflict','ev.'||m.owner_user_id||'.chain.'||m.chain_id||'.work_finished') AS filter_subjects
FROM task_chain_members m LEFT JOIN agent_instances ai
 ON ai.agent_instance_id=m.agent_instance_id AND ai.owner_user_id=m.owner_user_id
WHERE NOT EXISTS(SELECT 1 FROM task_chains c WHERE c.chain_id=m.chain_id AND c.owner_user_id=m.owner_user_id AND c.status IN ('completed','cancelled','archived')) AND m.role='coordinator' AND m.agent_instance_id!='' AND COALESCE(ai.stopped_by,'')=''
UNION
SELECT l.owner_user_id, l.holder_instance_id, COALESCE(NULLIF(ai.agent_id,''),l.holder_instance_id), l.chain_id, l.task_id,
 json_array('ev.'||l.owner_user_id||'.chain.'||l.chain_id||'.task.'||l.task_id||'.requirements_changed')
FROM task_leases l LEFT JOIN agent_instances ai
 ON ai.agent_instance_id=l.holder_instance_id AND ai.owner_user_id=l.owner_user_id
WHERE NOT EXISTS(SELECT 1 FROM task_chains c WHERE c.chain_id=l.chain_id AND c.owner_user_id=l.owner_user_id AND c.status IN ('completed','cancelled','archived')) AND l.kind='work' AND l.phase IN ('active','waiting') AND l.holder_instance_id!='' AND COALESCE(ai.stopped_by,'')='';


-- Keep role defaults off terminal chains; archived chains also release explicit watches.
CREATE TRIGGER event_inbox_terminal_chain AFTER UPDATE OF status ON task_chains
WHEN NEW.status IN ('completed','cancelled','archived')
BEGIN
 DELETE FROM event_subscriptions WHERE owner_user_id=NEW.owner_user_id AND chain_id=NEW.chain_id
 AND (source!='explicit' OR NEW.status='archived');
END;
CREATE TRIGGER event_inbox_reopened_chain AFTER UPDATE OF status ON task_chains
WHEN NEW.status='active' AND OLD.status!='active'
BEGIN
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
-- Prevent a late watch or role-resync from recreating a retired subscription.
CREATE TRIGGER event_inbox_terminal_insert BEFORE INSERT ON event_subscriptions
WHEN EXISTS(SELECT 1 FROM task_chains c WHERE c.owner_user_id=NEW.owner_user_id AND c.chain_id=NEW.chain_id
 AND (c.status='archived' OR (NEW.source!='explicit' AND c.status IN ('completed','cancelled'))))
BEGIN SELECT RAISE(IGNORE); END;
DELETE FROM event_subscriptions WHERE EXISTS(
 SELECT 1 FROM task_chains c WHERE c.owner_user_id=event_subscriptions.owner_user_id
 AND c.chain_id=event_subscriptions.chain_id AND
 (c.status='archived' OR (event_subscriptions.source!='explicit' AND c.status IN ('completed','cancelled'))));

-- One coalesced invalidation per chain, indexed by a monotonic revision.
-- Retain deletion scopes so a disconnected runtime can evict cached rows.
CREATE TABLE event_inbox_clock(singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL);
INSERT INTO event_inbox_clock VALUES(1,0);
CREATE TABLE event_inbox_changes(owner_user_id TEXT NOT NULL,chain_id TEXT NOT NULL,revision INTEGER NOT NULL,
 PRIMARY KEY(owner_user_id,chain_id));
CREATE INDEX event_inbox_changes_revision ON event_inbox_changes(revision);
CREATE INDEX event_subscriptions_chain ON event_subscriptions(owner_user_id,chain_id);
CREATE TRIGGER event_inbox_subscription_insert AFTER INSERT ON event_subscriptions BEGIN
UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes VALUES(NEW.owner_user_id,NEW.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1))
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
END;
CREATE TRIGGER event_inbox_subscription_update AFTER UPDATE ON event_subscriptions BEGIN
UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes VALUES(OLD.owner_user_id,OLD.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1))
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes VALUES(NEW.owner_user_id,NEW.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1))
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
END;
CREATE TRIGGER event_inbox_subscription_delete AFTER DELETE ON event_subscriptions BEGIN
UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes VALUES(OLD.owner_user_id,OLD.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1))
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
END;
CREATE TRIGGER event_inbox_delivery_insert AFTER INSERT ON event_deliveries BEGIN
 UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes SELECT s.owner_user_id,s.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1)
 FROM event_subscriptions s WHERE s.subscription_id=NEW.subscription_id
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
 END;
CREATE TRIGGER event_inbox_delivery_update AFTER UPDATE ON event_deliveries BEGIN
 UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes SELECT s.owner_user_id,s.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1)
 FROM event_subscriptions s WHERE s.subscription_id=NEW.subscription_id
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
 END;
CREATE TRIGGER event_inbox_delivery_delete AFTER DELETE ON event_deliveries BEGIN
 UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes SELECT s.owner_user_id,s.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1)
 FROM event_subscriptions s WHERE s.subscription_id=OLD.subscription_id
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
 END;

CREATE TRIGGER event_inbox_target_update AFTER UPDATE OF runtime_status,activity_status,stopped_by,bridge_id ON agent_instances
WHEN OLD.runtime_status!=NEW.runtime_status OR OLD.activity_status!=NEW.activity_status OR OLD.stopped_by!=NEW.stopped_by OR OLD.bridge_id!=NEW.bridge_id
BEGIN
 UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes SELECT DISTINCT s.owner_user_id,s.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1)
 FROM event_subscriptions s WHERE s.owner_user_id=NEW.owner_user_id AND s.subscriber_instance_id=NEW.agent_instance_id
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
END;
CREATE TRIGGER event_inbox_bot_insert AFTER INSERT ON bots BEGIN
UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes SELECT DISTINCT s.owner_user_id,s.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1)
 FROM event_subscriptions s WHERE s.owner_user_id=NEW.owner_user_id AND s.subscriber_instance_id=NEW.agent_instance_id
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
END;
CREATE TRIGGER event_inbox_bot_update AFTER UPDATE ON bots BEGIN
UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes SELECT DISTINCT s.owner_user_id,s.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1)
 FROM event_subscriptions s WHERE s.owner_user_id=OLD.owner_user_id AND s.subscriber_instance_id=OLD.agent_instance_id
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes SELECT DISTINCT s.owner_user_id,s.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1)
 FROM event_subscriptions s WHERE s.owner_user_id=NEW.owner_user_id AND s.subscriber_instance_id=NEW.agent_instance_id
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
END;
CREATE TRIGGER event_inbox_bot_delete AFTER DELETE ON bots BEGIN
UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes SELECT DISTINCT s.owner_user_id,s.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1)
 FROM event_subscriptions s WHERE s.owner_user_id=OLD.owner_user_id AND s.subscriber_instance_id=OLD.agent_instance_id
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
END;
CREATE TRIGGER event_inbox_target_insert AFTER INSERT ON agent_instances BEGIN
 UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes SELECT DISTINCT s.owner_user_id,s.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1)
 FROM event_subscriptions s WHERE s.owner_user_id=NEW.owner_user_id AND s.subscriber_instance_id=NEW.agent_instance_id
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
END;
CREATE TRIGGER event_inbox_target_delete AFTER DELETE ON agent_instances BEGIN
 UPDATE event_inbox_clock SET revision=revision+1 WHERE singleton=1;
 INSERT INTO event_inbox_changes SELECT DISTINCT s.owner_user_id,s.chain_id,(SELECT revision FROM event_inbox_clock WHERE singleton=1)
 FROM event_subscriptions s WHERE s.owner_user_id=OLD.owner_user_id AND s.subscriber_instance_id=OLD.agent_instance_id
 ON CONFLICT(owner_user_id,chain_id) DO UPDATE SET revision=excluded.revision;
END;
COMMIT;
