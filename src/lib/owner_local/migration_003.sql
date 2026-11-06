-- V2 constrained runtime_database.schema_version to exactly 2. Rebuild it
-- transactionally, preserving identity, clocks and pins, before adding leases.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v3 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 3 CHECK(schema_version=3),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v3 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,3,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v3 RENAME TO runtime_database;
CREATE TRIGGER runtime_identity_immutable BEFORE UPDATE ON runtime_database
WHEN NEW.account_id IS NOT OLD.account_id OR NEW.owner_bridge_id IS NOT OLD.owner_bridge_id
 OR NEW.owner_key_id IS NOT OLD.owner_key_id OR NEW.database_id IS NOT OLD.database_id
 OR NEW.singleton IS NOT OLD.singleton
BEGIN SELECT RAISE(ABORT,'immutable runtime identity'); END;
CREATE TRIGGER runtime_identity_no_delete BEFORE DELETE ON runtime_database
BEGIN SELECT RAISE(ABORT,'immutable runtime identity'); END;
CREATE TRIGGER runtime_monotonic BEFORE UPDATE ON runtime_database
WHEN NEW.incarnation<OLD.incarnation OR NEW.commit_seq<OLD.commit_seq
 OR NEW.clock_high_ms<OLD.clock_high_ms OR NEW.clock_generation<OLD.clock_generation
 OR NEW.directory_version<OLD.directory_version
 OR (NEW.directory_version=OLD.directory_version AND NEW.directory_hash IS NOT OLD.directory_hash)
BEGIN SELECT RAISE(ABORT,'runtime versions cannot regress'); END;
CREATE TRIGGER runtime_counter_types BEFORE UPDATE ON runtime_database
WHEN typeof(NEW.incarnation)!='integer' OR NEW.incarnation<0
 OR typeof(NEW.commit_seq)!='integer' OR NEW.commit_seq<0
 OR typeof(NEW.clock_high_ms)!='integer' OR NEW.clock_high_ms<0
 OR typeof(NEW.clock_generation)!='integer' OR NEW.clock_generation<1
 OR typeof(NEW.directory_version)!='integer' OR NEW.directory_version<0
BEGIN SELECT RAISE(ABORT,'invalid runtime counter'); END;
CREATE TRIGGER intent_transition BEFORE UPDATE ON runtime_intents
WHEN typeof(NEW.attempts)!='integer' OR NEW.attempts<OLD.attempts
 OR typeof(NEW.claim_incarnation)!='integer' OR NEW.claim_incarnation<0
 OR typeof(NEW.next_retry_ms)!='integer' OR NEW.next_retry_ms<OLD.next_retry_ms
 OR (NEW.state='claimed' AND (OLD.state!='pending' OR NEW.attempts!=OLD.attempts+1
   OR NEW.claim_incarnation!=(SELECT incarnation FROM runtime_database WHERE singleton=1)))
 OR (NEW.state!='claimed' AND NEW.attempts!=OLD.attempts)
 OR (NEW.state='settled' AND NEW.published!=1) OR (NEW.state!='settled' AND NEW.published!=0)
 OR (OLD.state='pending' AND NEW.state='settled')
BEGIN SELECT RAISE(ABORT,'invalid intent transition'); END;

CREATE TABLE local_fleet (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, instance_id TEXT NOT NULL,
 configuration_revision INTEGER NOT NULL CHECK(configuration_revision>0),
 enabled INTEGER NOT NULL CHECK(enabled IN(0,1)),
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, configuration_command TEXT NOT NULL, configuration_payload TEXT NOT NULL,
 launch_epoch TEXT NOT NULL, run_count INTEGER NOT NULL CHECK(run_count>0), token_generation TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE local_leases (
 lease_id TEXT PRIMARY KEY, chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 instance_id TEXT NOT NULL, launch_epoch TEXT NOT NULL, run_count INTEGER NOT NULL CHECK(run_count>0),
 token_generation TEXT NOT NULL, configuration_revision INTEGER NOT NULL CHECK(configuration_revision>0),
 requirements_revision INTEGER NOT NULL CHECK(requirements_revision>0),
 expires_ms INTEGER NOT NULL, hard_ms INTEGER NOT NULL CHECK(expires_ms<=hard_ms),
 deadline_version INTEGER NOT NULL CHECK(deadline_version>0),
 capability_json TEXT NOT NULL, retired_seq INTEGER,
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE UNIQUE INDEX local_lease_holder ON local_leases(instance_id) WHERE retired_seq IS NULL;
CREATE UNIQUE INDEX local_lease_task ON local_leases(task_id) WHERE retired_seq IS NULL;
CREATE TABLE lease_receipt_pins (
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, lease_id TEXT NOT NULL REFERENCES local_leases(lease_id),
 PRIMARY KEY(principal_id,operation_id,lease_id),
 FOREIGN KEY(principal_id,operation_id) REFERENCES command_receipts(principal_id,operation_id)
);

CREATE INDEX local_lease_expiry ON local_leases(expires_ms) WHERE retired_seq IS NULL;
CREATE TRIGGER local_fleet_revision BEFORE UPDATE ON local_fleet
WHEN NEW.chain_id IS NOT OLD.chain_id OR NEW.task_id IS NOT OLD.task_id
 OR NEW.configuration_revision<=OLD.configuration_revision
BEGIN SELECT RAISE(ABORT,'fleet revision'); END;
CREATE TRIGGER local_lease_identity BEFORE UPDATE ON local_leases
WHEN NEW.lease_id IS NOT OLD.lease_id OR NEW.chain_id IS NOT OLD.chain_id OR NEW.task_id IS NOT OLD.task_id
 OR NEW.instance_id IS NOT OLD.instance_id OR NEW.launch_epoch IS NOT OLD.launch_epoch
 OR NEW.run_count IS NOT OLD.run_count OR NEW.token_generation IS NOT OLD.token_generation
 OR NEW.configuration_revision IS NOT OLD.configuration_revision OR NEW.requirements_revision IS NOT OLD.requirements_revision
 OR NEW.hard_ms IS NOT OLD.hard_ms OR OLD.retired_seq IS NOT NULL
 OR NEW.expires_ms<OLD.expires_ms
 OR (NEW.capability_json IS NOT OLD.capability_json AND NEW.deadline_version!=OLD.deadline_version+1)
 OR (NEW.retired_seq IS NOT NULL AND (NEW.capability_json IS NOT OLD.capability_json OR NEW.deadline_version!=OLD.deadline_version))
BEGIN SELECT RAISE(ABORT,'immutable lease fence'); END;
