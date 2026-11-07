DROP TRIGGER reservation_shared_admission;
DROP TRIGGER local_shared_admission;
DROP TRIGGER readiness_scope;
DROP TRIGGER runtime_immutable;
DROP TRIGGER runtime_no_delete;
ALTER TABLE executor_runtime RENAME TO executor_runtime_v7;

CREATE TABLE executor_runtime (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL CHECK(schema_version=8),
 account_id TEXT NOT NULL, executor_bridge_id TEXT NOT NULL, operator_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL CHECK(incarnation>0), clock_high_ms INTEGER NOT NULL CHECK(clock_high_ms>=0),
 recovery_state TEXT NOT NULL CHECK(recovery_state IN ('ready','reconciling','clock_uncertain')),
 policy_revision INTEGER NOT NULL DEFAULT 0 CHECK(policy_revision>=0), device_capacity INTEGER NOT NULL DEFAULT 0 CHECK(device_capacity BETWEEN 0 AND 128)
);
CREATE TRIGGER runtime_immutable BEFORE UPDATE ON executor_runtime
WHEN NEW.singleton IS NOT OLD.singleton OR NEW.account_id IS NOT OLD.account_id OR NEW.executor_bridge_id IS NOT OLD.executor_bridge_id
 OR NEW.operator_key_id IS NOT OLD.operator_key_id OR NEW.schema_version IS NOT OLD.schema_version
 OR NEW.incarnation<OLD.incarnation OR NEW.clock_high_ms<OLD.clock_high_ms OR NEW.policy_revision<OLD.policy_revision
BEGIN SELECT RAISE(ABORT,'immutable executor identity or version'); END;
CREATE TRIGGER runtime_no_delete BEFORE DELETE ON executor_runtime BEGIN SELECT RAISE(ABORT,'immutable executor identity'); END;

INSERT INTO executor_runtime SELECT singleton,8,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v7;
DROP TABLE executor_runtime_v7;


CREATE TABLE executor_local_drafts (
 draft_id TEXT PRIMARY KEY, source_digest TEXT NOT NULL UNIQUE,
 revision INTEGER NOT NULL CHECK(revision>0),
 configuration TEXT NOT NULL CHECK(json_valid(configuration)),
 material TEXT NOT NULL CHECK(json_valid(material)),
 principal_id TEXT NOT NULL DEFAULT '', key_id TEXT NOT NULL DEFAULT '',
 state TEXT NOT NULL CHECK(state IN ('pending','prepared','authorized','cancelled')),
 launch_id TEXT REFERENCES executor_local_launches(launch_id),
 CHECK((state='pending' AND principal_id='' AND key_id='' AND launch_id IS NULL)
    OR (state!='pending' AND principal_id!='' AND key_id!='')),
 CHECK((state='authorized' AND launch_id IS NOT NULL) OR state!='authorized')
);
CREATE TRIGGER local_draft_immutable BEFORE UPDATE ON executor_local_drafts
WHEN NEW.draft_id IS NOT OLD.draft_id OR NEW.source_digest IS NOT OLD.source_digest
 OR NEW.revision IS NOT OLD.revision OR NEW.configuration IS NOT OLD.configuration
 OR NEW.material IS NOT OLD.material
 OR (OLD.principal_id!='' AND (NEW.principal_id IS NOT OLD.principal_id OR NEW.key_id IS NOT OLD.key_id))
 OR (OLD.launch_id IS NOT NULL AND NEW.launch_id IS NOT OLD.launch_id)
 OR (OLD.state='cancelled' AND NEW.state!='cancelled')
 OR (OLD.state='authorized' AND NEW.state NOT IN ('authorized','cancelled'))
 OR (OLD.state='prepared' AND NEW.state='pending')
BEGIN SELECT RAISE(ABORT,'immutable local draft or invalid transition'); END;
CREATE TRIGGER local_draft_no_delete BEFORE DELETE ON executor_local_drafts BEGIN SELECT RAISE(ABORT,'retained local draft'); END;
CREATE TABLE executor_local_draft_receipts (
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 input_digest TEXT NOT NULL, draft_id TEXT NOT NULL REFERENCES executor_local_drafts(draft_id),
 result_json TEXT NOT NULL CHECK(json_valid(result_json)), PRIMARY KEY(principal_id,operation_id)
);
CREATE TRIGGER local_draft_receipt_no_update BEFORE UPDATE ON executor_local_draft_receipts BEGIN SELECT RAISE(ABORT,'immutable draft receipt'); END;
CREATE TRIGGER local_draft_receipt_no_delete BEFORE DELETE ON executor_local_draft_receipts BEGIN SELECT RAISE(ABORT,'retained draft receipt'); END;

CREATE TRIGGER readiness_scope BEFORE INSERT ON executor_readiness
WHEN NOT EXISTS(SELECT 1 FROM executor_reservations r JOIN executor_bootstraps b USING(reservation_id)
 WHERE r.reservation_id=NEW.reservation_id AND r.instance_id=NEW.instance_id AND r.launch_key=NEW.launch_key
 AND json_extract(b.document,'$.token_generation')=NEW.token_generation
 AND r.state='active' AND r.launch_state='confirmed'
 AND r.executor_incarnation=NEW.executor_incarnation AND r.observed_incarnation=NEW.executor_incarnation
 AND NEW.executor_incarnation=(SELECT incarnation FROM executor_runtime)
 AND NEW.ready_ms<r.expires_ms AND NEW.ready_ms<r.hard_ms)
BEGIN SELECT RAISE(ABORT,'readiness requires current exact child'); END;

CREATE TRIGGER reservation_shared_admission BEFORE INSERT ON executor_reservations
WHEN NEW.state!='released' AND (
 (SELECT count(*) FROM executor_live_resources)>=(SELECT device_capacity FROM executor_runtime)
 OR EXISTS(SELECT 1 FROM executor_live_resources WHERE slot_id=NEW.slot_id OR instance_id=NEW.instance_id
   OR (directory_key!='' AND directory_key=NEW.directory_key)))
BEGIN SELECT RAISE(ABORT,'shared executor resource conflict'); END;
CREATE TRIGGER local_shared_admission BEFORE INSERT ON executor_local_launches
WHEN NEW.state!='admitted' OR
 (SELECT count(*) FROM executor_live_resources)>=(SELECT device_capacity FROM executor_runtime)
 OR EXISTS(SELECT 1 FROM executor_live_resources WHERE slot_id=NEW.slot_id OR instance_id=NEW.instance_id
   OR (directory_key!='' AND directory_key=NEW.directory_key))
BEGIN SELECT RAISE(ABORT,'shared executor resource conflict'); END;
