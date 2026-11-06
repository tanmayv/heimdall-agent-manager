-- V20: operational task priority with immutable history.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v20 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 20 CHECK(schema_version=20),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v20 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,20,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v20 RENAME TO runtime_database;
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












CREATE TABLE local_task_priority_versions (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), task_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 priority TEXT NOT NULL CHECK(priority IN ('p0','p1','p2')),
 PRIMARY KEY(chain_id,task_id,accepted_seq)
);
CREATE TRIGGER local_task_priority_scope BEFORE INSERT ON local_task_priority_versions
WHEN NOT EXISTS(SELECT 1 FROM tasks WHERE chain_id=NEW.chain_id AND task_id=NEW.task_id)
BEGIN SELECT RAISE(ABORT,'priority task scope'); END;
CREATE TRIGGER local_task_priority_no_update BEFORE UPDATE ON local_task_priority_versions
BEGIN SELECT RAISE(ABORT,'immutable priority history'); END;
CREATE TRIGGER local_task_priority_no_delete BEFORE DELETE ON local_task_priority_versions
BEGIN SELECT RAISE(ABORT,'immutable priority history'); END;

-- Reconcile pre-V18 history against a single immutable chain origin. A native
-- history owner conflicting with an existing origin (or another historical
-- owner) collides on the chain primary key and rolls the entire migration back.
INSERT INTO native_metadata_origins(chain_id,owner_user_id,accepted_seq)
SELECT h.chain_id,h.owner_user_id,min(h.accepted_seq)
FROM native_history_records h
WHERE NOT EXISTS(SELECT 1 FROM native_metadata_origins o WHERE o.chain_id=h.chain_id AND o.owner_user_id=h.owner_user_id)
GROUP BY h.chain_id,h.owner_user_id;
CREATE TRIGGER native_history_origin BEFORE INSERT ON native_history_records
WHEN NOT EXISTS(SELECT 1 FROM native_metadata_origins o WHERE o.chain_id=NEW.chain_id AND o.owner_user_id=NEW.owner_user_id)
BEGIN SELECT RAISE(ABORT,'native history owner conflict'); END;

CREATE TABLE native_fleet_snapshots (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind='fleet'),
 owner_user_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 record_count INTEGER NOT NULL CHECK(record_count>=0 AND record_count<=100), content_digest TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,kind), UNIQUE(chain_id,source_revision),
 FOREIGN KEY(chain_id,owner_user_id) REFERENCES native_metadata_origins(chain_id,owner_user_id)
);
CREATE TABLE native_fleet_policies (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, agent_id TEXT NOT NULL,
 provider_profile TEXT NOT NULL, capacity INTEGER NOT NULL CHECK(capacity>0),
 min_warm INTEGER NOT NULL CHECK(min_warm>=0), idle_ttl_seconds INTEGER NOT NULL CHECK(idle_ttl_seconds>=0),
 bridge_models_json TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, roles_json TEXT NOT NULL,
 bridge_id TEXT NOT NULL, paused_roles_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,agent_id),
 FOREIGN KEY(chain_id,source_revision) REFERENCES native_fleet_snapshots(chain_id,source_revision)
);
CREATE TABLE local_fleet_policy_sources (
 chain_id TEXT NOT NULL, agent_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL, source_revision TEXT NOT NULL,
 PRIMARY KEY(chain_id,agent_id,accepted_seq),
 FOREIGN KEY(chain_id,agent_id,accepted_seq) REFERENCES local_fleet_policy_versions(chain_id,agent_id,seq),
 FOREIGN KEY(chain_id,source_revision,agent_id) REFERENCES native_fleet_policies(chain_id,source_revision,agent_id)
);
CREATE TRIGGER native_fleet_snapshots_no_update BEFORE UPDATE ON native_fleet_snapshots BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
CREATE TRIGGER native_fleet_snapshots_no_delete BEFORE DELETE ON native_fleet_snapshots BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
CREATE TRIGGER native_fleet_policies_no_update BEFORE UPDATE ON native_fleet_policies BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
CREATE TRIGGER native_fleet_policies_no_delete BEFORE DELETE ON native_fleet_policies BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
CREATE TRIGGER local_fleet_policy_sources_no_update BEFORE UPDATE ON local_fleet_policy_sources BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
CREATE TRIGGER local_fleet_policy_sources_no_delete BEFORE DELETE ON local_fleet_policy_sources BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
