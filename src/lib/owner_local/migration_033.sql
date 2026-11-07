-- V33 (R4b search review): an archived workflow stage task (V31
-- migration_archived_tasks) is indexed only as its 'archived_task' document,
-- never as a live 'task' document, including after later edits of the row.
-- NOTE for merge: numbered after V32 on bridge-owned/subagents; renumber if
-- another branch (R4a) adds an owner_local migration first.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v33 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 33 CHECK(schema_version=33),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v33 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,33,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v33 RENAME TO runtime_database;
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
DROP TRIGGER IF EXISTS search_tasks_insert;
DROP TRIGGER IF EXISTS search_tasks_update;
CREATE TRIGGER search_tasks_insert AFTER INSERT ON tasks
WHEN NOT EXISTS(SELECT 1 FROM migration_archived_tasks a WHERE a.chain_id=new.chain_id AND a.task_id=new.task_id)
BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'task',new.task_id,new.revision,new.title,new.body) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER search_tasks_update AFTER UPDATE ON tasks
WHEN NOT EXISTS(SELECT 1 FROM migration_archived_tasks a WHERE a.chain_id=new.chain_id AND a.task_id=new.task_id)
BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'task',new.task_id,new.revision,new.title,new.body) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
DELETE FROM search_docs WHERE kind='task' AND EXISTS(SELECT 1 FROM migration_archived_tasks a WHERE a.chain_id=search_docs.chain_id AND a.task_id=search_docs.task_id);
