-- V22: operational members/directories and path/authority revocation.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v22 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 22 CHECK(schema_version=22),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v22 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,22,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v22 RENAME TO runtime_database;
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

CREATE TABLE local_chain_member_versions (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 instance_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 agent_id TEXT NOT NULL, role TEXT NOT NULL CHECK(length(role)>0 AND length(role)<=160),
 enabled INTEGER NOT NULL CHECK(enabled IN (0,1)), child_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,instance_id,accepted_seq)
);
-- Lifetime single-chain binding survives removal and process restart.
CREATE TABLE local_member_chains (
 instance_id TEXT PRIMARY KEY, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id)
);
CREATE TABLE local_chain_directory_versions (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 directory_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 enabled INTEGER NOT NULL CHECK(enabled IN (0,1)), body TEXT NOT NULL,
 PRIMARY KEY(chain_id,directory_id,accepted_seq)
);
CREATE TABLE local_config_revocations (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,task_id,revision),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE local_coordinator_revocations (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), revision INTEGER NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,revision)
);
CREATE TRIGGER local_chain_member_versions_no_update BEFORE UPDATE ON local_chain_member_versions
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER local_chain_member_versions_no_delete BEFORE DELETE ON local_chain_member_versions
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER local_member_chains_no_update BEFORE UPDATE ON local_member_chains
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER local_member_chains_no_delete BEFORE DELETE ON local_member_chains
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER local_chain_directory_versions_no_update BEFORE UPDATE ON local_chain_directory_versions
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER local_chain_directory_versions_no_delete BEFORE DELETE ON local_chain_directory_versions
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER local_config_revocations_no_update BEFORE UPDATE ON local_config_revocations
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER local_config_revocations_no_delete BEFORE DELETE ON local_config_revocations
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER local_coordinator_revocations_no_update BEFORE UPDATE ON local_coordinator_revocations
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER local_coordinator_revocations_no_delete BEFORE DELETE ON local_coordinator_revocations
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;

CREATE TABLE local_brief_inputs (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, requirements_revision INTEGER NOT NULL,
 inputs_json TEXT NOT NULL CHECK(json_valid(inputs_json) AND json_type(inputs_json)='array'),
 PRIMARY KEY(chain_id,task_id,requirements_revision),
 FOREIGN KEY(chain_id,task_id,requirements_revision) REFERENCES task_requirements(chain_id,task_id,revision)
);
CREATE TRIGGER local_brief_inputs_no_update BEFORE UPDATE ON local_brief_inputs
BEGIN SELECT RAISE(ABORT,'immutable brief inputs'); END;
CREATE TRIGGER local_brief_inputs_no_delete BEFORE DELETE ON local_brief_inputs
BEGIN SELECT RAISE(ABORT,'immutable brief inputs'); END;

CREATE TABLE local_metadata_retirements (
 seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, lease_id TEXT NOT NULL,
 cause TEXT NOT NULL CHECK(cause IN ('chain.member.set','chain.directory.set')),
 PRIMARY KEY(seq,chain_id,task_id),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TRIGGER local_metadata_retirements_no_update BEFORE UPDATE ON local_metadata_retirements
BEGIN SELECT RAISE(ABORT,'immutable metadata retirement'); END;
CREATE TRIGGER local_metadata_retirements_no_delete BEFORE DELETE ON local_metadata_retirements
BEGIN SELECT RAISE(ABORT,'immutable metadata retirement'); END;
