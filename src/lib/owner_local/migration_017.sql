-- V17: typed durable fleet policy and exact accepted version history.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v17 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 17 CHECK(schema_version=17),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v17 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,17,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v17 RENAME TO runtime_database;
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










CREATE TABLE local_fleet_policy_versions (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 agent_id TEXT NOT NULL, seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 provider_profile TEXT NOT NULL, capacity INTEGER NOT NULL CHECK(typeof(capacity)='integer' AND capacity>=1),
 min_warm INTEGER NOT NULL CHECK(typeof(min_warm)='integer' AND min_warm>=0),
 idle_ttl_seconds INTEGER NOT NULL CHECK(typeof(idle_ttl_seconds)='integer' AND idle_ttl_seconds>=0),
 bridge_models_json TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
 roles_json TEXT NOT NULL, bridge_id TEXT NOT NULL, paused_roles_json TEXT NOT NULL,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,agent_id,seq)
);
CREATE TABLE local_fleet_policy_roles (
 chain_id TEXT NOT NULL, agent_id TEXT NOT NULL, seq INTEGER NOT NULL,
 role TEXT NOT NULL, paused INTEGER NOT NULL CHECK(paused IN(0,1)),
 PRIMARY KEY(chain_id,agent_id,seq,role,paused),
 FOREIGN KEY(chain_id,agent_id,seq) REFERENCES local_fleet_policy_versions(chain_id,agent_id,seq)
);
CREATE TABLE local_fleet_policy_models (
 chain_id TEXT NOT NULL, agent_id TEXT NOT NULL, seq INTEGER NOT NULL,
 bridge_id TEXT NOT NULL, provider_profile TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
 PRIMARY KEY(chain_id,agent_id,seq,bridge_id),
 FOREIGN KEY(chain_id,agent_id,seq) REFERENCES local_fleet_policy_versions(chain_id,agent_id,seq)
);
CREATE VIEW local_fleet_policy_current AS
 SELECT v.* FROM local_fleet_policy_versions v WHERE v.seq=(
 SELECT max(h.seq) FROM local_fleet_policy_versions h WHERE h.chain_id=v.chain_id AND h.agent_id=v.agent_id);
CREATE TRIGGER local_fleet_policy_versions_no_update BEFORE UPDATE ON local_fleet_policy_versions BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
CREATE TRIGGER local_fleet_policy_versions_no_delete BEFORE DELETE ON local_fleet_policy_versions BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
CREATE TRIGGER local_fleet_policy_roles_no_update BEFORE UPDATE ON local_fleet_policy_roles BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
CREATE TRIGGER local_fleet_policy_roles_no_delete BEFORE DELETE ON local_fleet_policy_roles BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
CREATE TRIGGER local_fleet_policy_models_no_update BEFORE UPDATE ON local_fleet_policy_models BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
CREATE TRIGGER local_fleet_policy_models_no_delete BEFORE DELETE ON local_fleet_policy_models BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
