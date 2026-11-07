DROP TRIGGER runtime_immutable;
DROP TRIGGER runtime_no_delete;
ALTER TABLE executor_runtime RENAME TO executor_runtime_v1;

CREATE TABLE executor_runtime (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL CHECK(schema_version=2),
 account_id TEXT NOT NULL, executor_bridge_id TEXT NOT NULL, operator_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL CHECK(incarnation>0), clock_high_ms INTEGER NOT NULL CHECK(clock_high_ms>=0),
 recovery_state TEXT NOT NULL CHECK(recovery_state IN ('ready','reconciling','clock_uncertain')),
 policy_revision INTEGER NOT NULL DEFAULT 0 CHECK(policy_revision>=0), device_capacity INTEGER NOT NULL DEFAULT 0 CHECK(device_capacity BETWEEN 0 AND 128)
);

INSERT INTO executor_runtime SELECT singleton,2,account_id,executor_bridge_id,operator_key_id,incarnation,clock_high_ms,recovery_state,policy_revision,device_capacity FROM executor_runtime_v1;
DROP TABLE executor_runtime_v1;
CREATE TRIGGER runtime_immutable BEFORE UPDATE ON executor_runtime
WHEN NEW.singleton IS NOT OLD.singleton OR NEW.account_id IS NOT OLD.account_id OR NEW.executor_bridge_id IS NOT OLD.executor_bridge_id
 OR NEW.operator_key_id IS NOT OLD.operator_key_id OR NEW.schema_version IS NOT OLD.schema_version
 OR NEW.incarnation<OLD.incarnation OR NEW.clock_high_ms<OLD.clock_high_ms OR NEW.policy_revision<OLD.policy_revision
BEGIN SELECT RAISE(ABORT,'immutable executor identity or version'); END;
CREATE TRIGGER runtime_no_delete BEFORE DELETE ON executor_runtime BEGIN SELECT RAISE(ABORT,'immutable executor identity'); END;
CREATE TABLE executor_issuances (
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, owner_bridge_id TEXT NOT NULL,
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, input_digest TEXT NOT NULL,
 consent TEXT NOT NULL CHECK(json_valid(consent)), selection TEXT NOT NULL CHECK(json_valid(selection)),
 instance_id TEXT NOT NULL UNIQUE, token_secret TEXT NOT NULL UNIQUE,
 configuration TEXT NOT NULL CHECK(json_valid(configuration)), result_json TEXT NOT NULL CHECK(json_valid(result_json)),
 PRIMARY KEY(principal_id,operation_id)
);
CREATE TRIGGER issuance_no_update BEFORE UPDATE ON executor_issuances BEGIN SELECT RAISE(ABORT,'immutable issuance'); END;
CREATE TRIGGER issuance_no_delete BEFORE DELETE ON executor_issuances BEGIN SELECT RAISE(ABORT,'retained issuance'); END;
CREATE TABLE executor_directories (
 directory_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 directory_path TEXT NOT NULL, directory_key TEXT NOT NULL, enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
 input_digest TEXT NOT NULL, document TEXT NOT NULL CHECK(json_valid(document)),
 PRIMARY KEY(directory_id,revision)
);
CREATE TRIGGER directory_no_update BEFORE UPDATE ON executor_directories BEGIN SELECT RAISE(ABORT,'immutable directory mapping'); END;
CREATE TRIGGER directory_no_delete BEFORE DELETE ON executor_directories BEGIN SELECT RAISE(ABORT,'retained directory mapping'); END;
CREATE TABLE executor_enrollment_pin (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), version INTEGER NOT NULL CHECK(version>=0), head_hash TEXT NOT NULL
);
INSERT INTO executor_enrollment_pin VALUES(1,0,'');
CREATE TRIGGER enrollment_pin_monotonic BEFORE UPDATE ON executor_enrollment_pin
WHEN NEW.singleton IS NOT OLD.singleton OR NEW.version<OLD.version OR (NEW.version=OLD.version AND NEW.head_hash IS NOT OLD.head_hash)
BEGIN SELECT RAISE(ABORT,'enrollment pin cannot regress'); END;
CREATE TRIGGER enrollment_pin_no_delete BEFORE DELETE ON executor_enrollment_pin BEGIN SELECT RAISE(ABORT,'retained enrollment pin'); END;
