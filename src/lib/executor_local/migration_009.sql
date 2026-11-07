DROP TRIGGER reservation_shared_admission;
DROP TRIGGER local_shared_admission;
DROP TRIGGER readiness_scope;
DROP TRIGGER runtime_immutable;
DROP TRIGGER runtime_no_delete;
ALTER TABLE executor_runtime RENAME TO executor_runtime_v8;

CREATE TABLE executor_runtime (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL CHECK(schema_version=9),
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

INSERT INTO executor_runtime SELECT singleton,9,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v8;
DROP TABLE executor_runtime_v8;



-- Migration fences are execution metadata, never imported task authority.
-- A barrier is permanent until a separately verified source resume protocol
-- exists. Completion of a command handler is not proof of child absence.
CREATE TABLE executor_legacy_barriers (
 chain_id TEXT PRIMARY KEY CHECK(length(chain_id)>0),
 migration_id TEXT NOT NULL CHECK(length(migration_id)>0),
 selection_digest TEXT NOT NULL CHECK(length(selection_digest)=64 AND selection_digest NOT GLOB '*[^0-9a-f]*'),
 source_generation INTEGER NOT NULL CHECK(source_generation>0),
 installed_incarnation INTEGER NOT NULL CHECK(installed_incarnation>0)
);
CREATE TRIGGER legacy_barrier_admission BEFORE INSERT ON executor_legacy_barriers
WHEN NEW.installed_incarnation!=(SELECT incarnation FROM executor_runtime)
BEGIN SELECT RAISE(ABORT,'legacy barrier requires current executor'); END;
CREATE TRIGGER legacy_barrier_no_update BEFORE UPDATE ON executor_legacy_barriers BEGIN SELECT RAISE(ABORT,'retained legacy barrier'); END;
CREATE TRIGGER legacy_barrier_no_delete BEFORE DELETE ON executor_legacy_barriers BEGIN SELECT RAISE(ABORT,'retained legacy barrier'); END;

-- Targets remain fenced even if a late command claims a different chain.
-- Workdir identity is a digest of the verified canonical path, not prose/path.
CREATE TABLE executor_legacy_resources (
 kind TEXT NOT NULL CHECK(kind IN ('instance','task','workdir_hash')),
 resource_id TEXT NOT NULL CHECK(length(resource_id)>0),
 chain_id TEXT NOT NULL REFERENCES executor_legacy_barriers(chain_id),
 PRIMARY KEY(kind,resource_id,chain_id)
);
CREATE TRIGGER legacy_resource_no_update BEFORE UPDATE ON executor_legacy_resources BEGIN SELECT RAISE(ABORT,'retained legacy resource fence'); END;
CREATE TRIGGER legacy_resource_no_delete BEFORE DELETE ON executor_legacy_resources BEGIN SELECT RAISE(ABORT,'retained legacy resource fence'); END;

CREATE TABLE executor_legacy_commands (
 command_id TEXT PRIMARY KEY CHECK(length(command_id)>0),
 chain_id TEXT NOT NULL CHECK(length(chain_id)>0),
 input_digest TEXT NOT NULL CHECK(length(input_digest)=64 AND input_digest NOT GLOB '*[^0-9a-f]*'),
 admitted_incarnation INTEGER NOT NULL CHECK(admitted_incarnation>0),
 state TEXT NOT NULL CHECK(state IN ('running','returned'))
);
CREATE INDEX legacy_command_chain_state ON executor_legacy_commands(chain_id,state);
CREATE TRIGGER legacy_command_admission BEFORE INSERT ON executor_legacy_commands
WHEN NEW.state!='running' OR NEW.admitted_incarnation!=(SELECT incarnation FROM executor_runtime)
 OR EXISTS(SELECT 1 FROM executor_legacy_barriers WHERE chain_id=NEW.chain_id)
BEGIN SELECT RAISE(ABORT,'legacy dispatch fenced'); END;
CREATE TRIGGER legacy_command_transition BEFORE UPDATE ON executor_legacy_commands
WHEN NEW.command_id IS NOT OLD.command_id OR NEW.chain_id IS NOT OLD.chain_id
 OR NEW.input_digest IS NOT OLD.input_digest OR NEW.admitted_incarnation IS NOT OLD.admitted_incarnation
 OR OLD.state!='running' OR NEW.state!='returned'
 OR NEW.admitted_incarnation!=(SELECT incarnation FROM executor_runtime)
BEGIN SELECT RAISE(ABORT,'immutable legacy command or stale completion'); END;
CREATE TRIGGER legacy_command_no_delete BEFORE DELETE ON executor_legacy_commands BEGIN SELECT RAISE(ABORT,'retained legacy dispatch'); END;

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
