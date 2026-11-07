-- V26: durable owner execution preparation and activation journal.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v26 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 26 CHECK(schema_version=26),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v26 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,26,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v26 RENAME TO runtime_database;
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

CREATE TABLE owner_execution_journal (
 reservation_id TEXT PRIMARY KEY,
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 instance_id TEXT NOT NULL, lease_id TEXT NOT NULL UNIQUE,
 operation_id TEXT NOT NULL,
 prepare_digest TEXT NOT NULL, lease_digest TEXT NOT NULL,
 prepare_json TEXT NOT NULL CHECK(json_valid(prepare_json)), lease_command TEXT NOT NULL CHECK(json_valid(lease_command)), child_json TEXT NOT NULL CHECK(json_valid(child_json)),
 prepare_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 prepare_until_ms INTEGER NOT NULL CHECK(prepare_until_ms>0), owner_incarnation INTEGER NOT NULL CHECK(owner_incarnation>0),
 state TEXT NOT NULL CHECK(state IN ('preparing','committed','retired')),
 receipt_json TEXT NOT NULL DEFAULT '', activation_json TEXT NOT NULL DEFAULT '',
 grant_seq INTEGER REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 retired_seq INTEGER REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id),
 UNIQUE(instance_id,operation_id),
 CHECK((state='preparing' AND grant_seq IS NULL AND retired_seq IS NULL) OR
       (state='committed' AND grant_seq IS NOT NULL AND grant_seq>prepare_seq AND retired_seq IS NULL AND json_valid(receipt_json) AND json_valid(activation_json)) OR
       (state='retired' AND retired_seq IS NOT NULL))
);
CREATE UNIQUE INDEX owner_execution_task ON owner_execution_journal(task_id) WHERE state!='retired';
CREATE UNIQUE INDEX owner_execution_instance ON owner_execution_journal(instance_id) WHERE state!='retired';
CREATE TRIGGER owner_execution_identity BEFORE UPDATE ON owner_execution_journal
WHEN NEW.reservation_id IS NOT OLD.reservation_id OR NEW.chain_id IS NOT OLD.chain_id
 OR NEW.task_id IS NOT OLD.task_id OR NEW.instance_id IS NOT OLD.instance_id
 OR NEW.lease_id IS NOT OLD.lease_id OR NEW.operation_id IS NOT OLD.operation_id
 OR NEW.prepare_digest IS NOT OLD.prepare_digest OR NEW.lease_digest IS NOT OLD.lease_digest
 OR NEW.prepare_json IS NOT OLD.prepare_json OR NEW.lease_command IS NOT OLD.lease_command
 OR NEW.child_json IS NOT OLD.child_json OR NEW.prepare_seq IS NOT OLD.prepare_seq
 OR NEW.prepare_until_ms IS NOT OLD.prepare_until_ms OR NEW.owner_incarnation IS NOT OLD.owner_incarnation
 OR OLD.state='retired' OR (OLD.state='committed' AND NEW.state NOT IN('committed','retired'))
 OR (OLD.state='committed' AND (NEW.receipt_json IS NOT OLD.receipt_json
   OR NEW.activation_json IS NOT OLD.activation_json OR NEW.grant_seq IS NOT OLD.grant_seq))
BEGIN SELECT RAISE(ABORT,'immutable owner execution'); END;
CREATE TRIGGER owner_execution_no_delete BEFORE DELETE ON owner_execution_journal
BEGIN SELECT RAISE(ABORT,'retain execution identity'); END;

CREATE TABLE owner_execution_queries (
 reservation_id TEXT PRIMARY KEY REFERENCES owner_execution_journal(reservation_id),
 prepare_receipt TEXT NOT NULL CHECK(json_valid(prepare_receipt)),
 query_json TEXT NOT NULL CHECK(json_valid(query_json))
);
CREATE TRIGGER owner_execution_query_no_update BEFORE UPDATE ON owner_execution_queries
 BEGIN SELECT RAISE(ABORT,'immutable execution query'); END;
CREATE TRIGGER owner_execution_query_no_delete BEFORE DELETE ON owner_execution_queries
 BEGIN SELECT RAISE(ABORT,'retain execution query'); END;
