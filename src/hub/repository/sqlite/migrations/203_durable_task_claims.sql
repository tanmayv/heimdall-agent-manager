BEGIN;
ALTER TABLE task_leases ADD COLUMN phase TEXT NOT NULL DEFAULT 'active' CHECK (phase IN ('active', 'waiting'));
UPDATE task_leases SET expires_at='', hard_deadline_at='';

-- Legacy submit released its worker. Capture only pre-cutover review tasks:
-- boot restores a waiting repair owner, or records why restoration is unsafe.
INSERT INTO task_events(task_id,chain_id,owner_user_id,ts_ms,actor_kind,actor_id,kind,payload_json)
SELECT t.task_id,t.chain_id,t.owner_user_id,CAST(strftime('%s','now') AS INTEGER)*1000,
 'hub','migration203','durable_claim_conversion_pending',
 json_object('holder_instance_id',COALESCE(a.holder_instance_id,''),'attempt_no',t.attempt_no)
FROM tasks t LEFT JOIN task_attempts a ON a.task_id=t.task_id AND a.attempt_no=t.attempt_no
WHERE t.state='in_review'
 AND NOT EXISTS(SELECT 1 FROM task_leases l WHERE l.task_id=t.task_id AND l.kind='work')
 AND NOT EXISTS(SELECT 1 FROM task_events e WHERE e.task_id=t.task_id AND e.kind='durable_claim_conversion_pending');
COMMIT;
