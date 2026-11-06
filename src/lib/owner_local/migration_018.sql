-- V18: immutable source-backed native member/directory metadata.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v18 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 18 CHECK(schema_version=18),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v18 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,18,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v18 RENAME TO runtime_database;
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











CREATE TABLE native_metadata_origins (
 chain_id TEXT PRIMARY KEY REFERENCES task_chains(chain_id),
 owner_user_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(chain_id,owner_user_id)
);
CREATE TABLE native_metadata_snapshots (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN('member','directory')),
 owner_user_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 record_count INTEGER NOT NULL CHECK(record_count>=0 AND record_count<=100),
 content_digest TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,kind),
 UNIQUE(chain_id,source_revision,kind,owner_user_id),
 FOREIGN KEY(chain_id,owner_user_id) REFERENCES native_metadata_origins(chain_id,owner_user_id)
);
CREATE TABLE native_metadata_members (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'member' CHECK(kind='member'),
 agent_instance_id TEXT NOT NULL, agent_id TEXT NOT NULL, owner_user_id TEXT NOT NULL,
 role TEXT NOT NULL, created_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,agent_instance_id),
 FOREIGN KEY(chain_id,source_revision,kind,owner_user_id) REFERENCES native_metadata_snapshots(chain_id,source_revision,kind,owner_user_id)
);
CREATE TABLE native_metadata_directories (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'directory' CHECK(kind='directory'),
 directory_id TEXT NOT NULL, owner_user_id TEXT NOT NULL, path TEXT NOT NULL, bridge_id TEXT NOT NULL,
 vcs_kind TEXT NOT NULL, vcs_info_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,directory_id),
 FOREIGN KEY(chain_id,source_revision,kind,owner_user_id) REFERENCES native_metadata_snapshots(chain_id,source_revision,kind,owner_user_id)
);
CREATE TRIGGER native_metadata_origins_no_update BEFORE UPDATE ON native_metadata_origins BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER native_metadata_origins_no_delete BEFORE DELETE ON native_metadata_origins BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER native_metadata_snapshots_no_update BEFORE UPDATE ON native_metadata_snapshots BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER native_metadata_snapshots_no_delete BEFORE DELETE ON native_metadata_snapshots BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER native_metadata_members_no_update BEFORE UPDATE ON native_metadata_members BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER native_metadata_members_no_delete BEFORE DELETE ON native_metadata_members BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER native_metadata_directories_no_update BEFORE UPDATE ON native_metadata_directories BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER native_metadata_directories_no_delete BEFORE DELETE ON native_metadata_directories BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
