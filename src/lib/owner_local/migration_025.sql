-- V25: canonical linked content, envelopes, references and tombstones.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v25 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 25 CHECK(schema_version=25),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v25 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,25,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v25 RENAME TO runtime_database;
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


-- Identities survive body GC. A tombstone is permanent and dominates restore.
CREATE TABLE linked_identities (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), kind TEXT NOT NULL CHECK(kind IN ('message','artifact','blob')),
 object_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 task_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,kind,object_id,revision)
);
CREATE TABLE linked_bodies (
 chain_id TEXT NOT NULL, kind TEXT NOT NULL, object_id TEXT NOT NULL, revision INTEGER NOT NULL,
 record_json TEXT NOT NULL CHECK(json_valid(record_json)), vault_id TEXT NOT NULL, key_epoch INTEGER NOT NULL CHECK(key_epoch>0),
 prose TEXT NOT NULL,
 PRIMARY KEY(chain_id,kind,object_id,revision),
 FOREIGN KEY(chain_id,kind,object_id,revision) REFERENCES linked_identities(chain_id,kind,object_id,revision)
);
CREATE TABLE linked_tombstones (
 chain_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('message','artifact','blob')), object_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 deleted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,kind,object_id,revision),
 FOREIGN KEY(chain_id) REFERENCES task_chains(chain_id),
 FOREIGN KEY(chain_id,kind,object_id,revision) REFERENCES linked_identities(chain_id,kind,object_id,revision)
);
CREATE TABLE linked_references (
 chain_id TEXT NOT NULL, source_kind TEXT NOT NULL, source_id TEXT NOT NULL, source_revision INTEGER NOT NULL,
 target_kind TEXT NOT NULL, target_id TEXT NOT NULL, target_revision INTEGER NOT NULL,
 PRIMARY KEY(chain_id,source_kind,source_id,source_revision,target_kind,target_id,target_revision),
 FOREIGN KEY(chain_id,source_kind,source_id,source_revision) REFERENCES linked_bodies(chain_id,kind,object_id,revision),
 FOREIGN KEY(chain_id,target_kind,target_id,target_revision) REFERENCES linked_identities(chain_id,kind,object_id,revision)
);
CREATE INDEX linked_target ON linked_references(chain_id,target_kind,target_id,target_revision);
CREATE TRIGGER linked_identity_no_update BEFORE UPDATE ON linked_identities BEGIN SELECT RAISE(ABORT,'immutable linked identity'); END;
CREATE TRIGGER linked_identity_no_delete BEFORE DELETE ON linked_identities BEGIN SELECT RAISE(ABORT,'retain linked identity'); END;
CREATE TRIGGER linked_body_no_update BEFORE UPDATE ON linked_bodies BEGIN SELECT RAISE(ABORT,'immutable linked body'); END;
CREATE TRIGGER linked_tombstone_no_update BEFORE UPDATE ON linked_tombstones BEGIN SELECT RAISE(ABORT,'immutable linked tombstone'); END;
CREATE TRIGGER linked_tombstone_no_delete BEFORE DELETE ON linked_tombstones BEGIN SELECT RAISE(ABORT,'retain linked tombstone'); END;
CREATE TRIGGER linked_body_no_resurrection BEFORE INSERT ON linked_bodies
 WHEN EXISTS(SELECT 1 FROM linked_tombstones WHERE chain_id=NEW.chain_id AND kind=NEW.kind AND object_id=NEW.object_id AND revision=NEW.revision)
 BEGIN SELECT RAISE(ABORT,'retired linked body'); END;
CREATE TRIGGER linked_body_delete_guard BEFORE DELETE ON linked_bodies
 WHEN NOT EXISTS(SELECT 1 FROM linked_tombstones WHERE chain_id=OLD.chain_id AND kind=OLD.kind AND object_id=OLD.object_id AND revision=OLD.revision)
 BEGIN SELECT RAISE(ABORT,'tombstone before body GC'); END;
CREATE TRIGGER linked_search_insert AFTER INSERT ON linked_bodies WHEN NEW.kind='message' BEGIN
 INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
 SELECT NEW.chain_id,i.task_id,'message',json_array(NEW.object_id,NEW.revision),NEW.revision,'',NEW.prose
 FROM linked_identities i WHERE i.chain_id=NEW.chain_id AND i.kind=NEW.kind AND i.object_id=NEW.object_id AND i.revision=NEW.revision;
END;
CREATE TRIGGER linked_search_delete AFTER DELETE ON linked_bodies WHEN OLD.kind='message' BEGIN
 DELETE FROM search_docs WHERE chain_id=OLD.chain_id AND kind='message' AND object_id=json_array(OLD.object_id,OLD.revision);
END;

CREATE TRIGGER linked_reference_no_update BEFORE UPDATE ON linked_references BEGIN SELECT RAISE(ABORT,'immutable linked reference'); END;
CREATE TRIGGER linked_reference_delete_guard BEFORE DELETE ON linked_references
 WHEN NOT EXISTS(SELECT 1 FROM linked_tombstones WHERE chain_id=OLD.chain_id AND kind=OLD.source_kind AND object_id=OLD.source_id AND revision=OLD.source_revision)
 BEGIN SELECT RAISE(ABORT,'tombstone before reference GC'); END;
