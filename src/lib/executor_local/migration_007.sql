DROP TRIGGER readiness_scope;
DROP TRIGGER runtime_immutable;
DROP TRIGGER runtime_no_delete;
ALTER TABLE executor_runtime RENAME TO executor_runtime_v6;

CREATE TABLE executor_runtime (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL CHECK(schema_version=7),
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

INSERT INTO executor_runtime SELECT singleton,7,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v6;
DROP TABLE executor_runtime_v6;


-- Local device consent never fabricates an owner, chain, task or lease.
CREATE TABLE executor_local_launches (
 launch_id TEXT PRIMARY KEY, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 input_digest TEXT NOT NULL, consent TEXT NOT NULL CHECK(json_valid(consent)),
 configuration TEXT NOT NULL CHECK(json_valid(configuration)),
 slot_id TEXT NOT NULL REFERENCES executor_slots(slot_id),
 instance_id TEXT NOT NULL, directory_key TEXT NOT NULL,
 executor_incarnation INTEGER NOT NULL CHECK(executor_incarnation>0),
 launch_key TEXT NOT NULL UNIQUE, spawn_digest TEXT NOT NULL,
 admitted_ms INTEGER NOT NULL CHECK(admitted_ms>0), admitted_tick_ns INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('admitted','dispatching','active','stopping','released')),
 observed_incarnation INTEGER NOT NULL DEFAULT 0 CHECK(observed_incarnation>=0),
 UNIQUE(principal_id,operation_id)
);
CREATE TRIGGER local_launch_immutable BEFORE UPDATE ON executor_local_launches
WHEN NEW.launch_id IS NOT OLD.launch_id OR NEW.principal_id IS NOT OLD.principal_id
 OR NEW.operation_id IS NOT OLD.operation_id OR NEW.input_digest IS NOT OLD.input_digest
 OR NEW.consent IS NOT OLD.consent OR NEW.configuration IS NOT OLD.configuration
 OR NEW.slot_id IS NOT OLD.slot_id OR NEW.instance_id IS NOT OLD.instance_id
 OR NEW.directory_key IS NOT OLD.directory_key OR NEW.executor_incarnation IS NOT OLD.executor_incarnation
 OR NEW.launch_key IS NOT OLD.launch_key OR NEW.spawn_digest IS NOT OLD.spawn_digest
 OR NEW.admitted_ms IS NOT OLD.admitted_ms OR NEW.admitted_tick_ns IS NOT OLD.admitted_tick_ns
 OR NEW.observed_incarnation<OLD.observed_incarnation
 OR (OLD.state='released' AND NEW.state!='released')
 OR (OLD.state='stopping' AND NEW.state NOT IN ('stopping','released'))
 OR (OLD.state!='admitted' AND NEW.state='admitted')
 OR (OLD.state IN ('active','stopping') AND NEW.state='dispatching')
BEGIN SELECT RAISE(ABORT,'immutable local launch or invalid transition'); END;
CREATE TRIGGER local_launch_no_delete BEFORE DELETE ON executor_local_launches BEGIN SELECT RAISE(ABORT,'retained local launch'); END;
CREATE TABLE executor_local_observations (
 launch_id TEXT NOT NULL REFERENCES executor_local_launches(launch_id),
 executor_incarnation INTEGER NOT NULL CHECK(executor_incarnation>0),
 present INTEGER NOT NULL CHECK(present IN (0,1)), PRIMARY KEY(launch_id,executor_incarnation,present)
);
CREATE TRIGGER local_observation_no_update BEFORE UPDATE ON executor_local_observations BEGIN SELECT RAISE(ABORT,'immutable local observation'); END;
CREATE TRIGGER local_observation_no_delete BEFORE DELETE ON executor_local_observations BEGIN SELECT RAISE(ABORT,'retained local observation'); END;
CREATE VIEW executor_live_resources AS
 SELECT slot_id,instance_id,directory_key FROM executor_reservations WHERE state!='released'
 UNION ALL SELECT slot_id,instance_id,directory_key FROM executor_local_launches WHERE state!='released';
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

CREATE TRIGGER readiness_scope BEFORE INSERT ON executor_readiness
WHEN NOT EXISTS(SELECT 1 FROM executor_reservations r JOIN executor_bootstraps b USING(reservation_id)
 WHERE r.reservation_id=NEW.reservation_id AND r.instance_id=NEW.instance_id AND r.launch_key=NEW.launch_key
 AND json_extract(b.document,'$.token_generation')=NEW.token_generation
 AND r.state='active' AND r.launch_state='confirmed'
 AND r.executor_incarnation=NEW.executor_incarnation AND r.observed_incarnation=NEW.executor_incarnation
 AND NEW.executor_incarnation=(SELECT incarnation FROM executor_runtime)
 AND NEW.ready_ms<r.expires_ms AND NEW.ready_ms<r.hard_ms)
BEGIN SELECT RAISE(ABORT,'readiness requires current exact child'); END;
