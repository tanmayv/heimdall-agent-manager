-- V2 constrained runtime_database.schema_version to exactly 2. Rebuild it
-- transactionally, preserving identity, clocks and pins, before adding leases.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v5 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 5 CHECK(schema_version=5),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v5 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,5,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v5 RENAME TO runtime_database;
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



CREATE TABLE task_deletions(chain_id TEXT NOT NULL, task_id TEXT PRIMARY KEY, seq INTEGER NOT NULL);
CREATE TABLE search_docs(
 rowid INTEGER PRIMARY KEY, chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 kind TEXT NOT NULL, object_id TEXT NOT NULL, revision INTEGER NOT NULL,
 title TEXT NOT NULL, body TEXT NOT NULL, UNIQUE(chain_id,kind,object_id)
);
CREATE INDEX search_scope ON search_docs(chain_id,task_id);
CREATE VIRTUAL TABLE search_fts USING fts5(title,body,content='search_docs',content_rowid='rowid',tokenize='unicode61');
CREATE TRIGGER search_insert AFTER INSERT ON search_docs BEGIN
 INSERT INTO search_fts(rowid,title,body) VALUES(new.rowid,new.title,new.body);
END;
CREATE TRIGGER search_delete AFTER DELETE ON search_docs BEGIN
 INSERT INTO search_fts(search_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body);
END;
CREATE TRIGGER search_update AFTER UPDATE ON search_docs BEGIN
 INSERT INTO search_fts(search_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body);
 INSERT INTO search_fts(rowid,title,body) VALUES(new.rowid,new.title,new.body);
END;
CREATE TRIGGER search_task_chains_insert AFTER INSERT ON task_chains BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,'','chain',new.chain_id,new.revision,new.title,new.description) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER search_task_chains_update AFTER UPDATE ON task_chains BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,'','chain',new.chain_id,new.revision,new.title,new.description) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER search_task_chains_delete AFTER DELETE ON task_chains BEGIN DELETE FROM search_docs WHERE chain_id=old.chain_id AND kind='chain' AND object_id=old.chain_id; END;
INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) SELECT chain_id,'','chain',chain_id,revision,title,description FROM task_chains;
CREATE TRIGGER search_tasks_insert AFTER INSERT ON tasks BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'task',new.task_id,new.revision,new.title,new.body) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER search_tasks_update AFTER UPDATE ON tasks BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'task',new.task_id,new.revision,new.title,new.body) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER search_tasks_delete AFTER DELETE ON tasks BEGIN DELETE FROM search_docs WHERE chain_id=old.chain_id AND kind='task' AND object_id=old.task_id; END;
INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) SELECT chain_id,task_id,'task',task_id,revision,title,body FROM tasks;
CREATE TRIGGER search_task_comments_insert AFTER INSERT ON task_comments BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'comment',new.principal_id||':'||new.operation_id,new.seq,'',new.body) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER search_task_comments_update AFTER UPDATE ON task_comments BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'comment',new.principal_id||':'||new.operation_id,new.seq,'',new.body) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER search_task_comments_delete AFTER DELETE ON task_comments BEGIN DELETE FROM search_docs WHERE chain_id=old.chain_id AND kind='comment' AND object_id=old.principal_id||':'||old.operation_id; END;
INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) SELECT chain_id,task_id,'comment',principal_id||':'||operation_id,seq,'',body FROM task_comments;
CREATE TRIGGER search_task_requirements_insert AFTER INSERT ON task_requirements BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'requirements',new.task_id,new.revision,'',new.brief_json) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER search_task_requirements_update AFTER UPDATE ON task_requirements BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'requirements',new.task_id,new.revision,'',new.brief_json) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER search_task_requirements_delete AFTER DELETE ON task_requirements BEGIN DELETE FROM search_docs WHERE chain_id=old.chain_id AND kind='requirements' AND object_id=old.task_id; END;
INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) SELECT chain_id,task_id,'requirements',task_id,revision,'',brief_json FROM task_requirements WHERE revision=(SELECT MAX(b.revision) FROM task_requirements b WHERE b.chain_id=task_requirements.chain_id AND b.task_id=task_requirements.task_id);
CREATE TRIGGER search_local_submissions_insert AFTER INSERT ON local_submissions BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'output',new.task_id,new.attempt,'',new.summary) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER search_local_submissions_update AFTER UPDATE ON local_submissions BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'output',new.task_id,new.attempt,'',new.summary) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER search_local_submissions_delete AFTER DELETE ON local_submissions BEGIN DELETE FROM search_docs WHERE chain_id=old.chain_id AND kind='output' AND object_id=old.task_id; END;
INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) SELECT chain_id,task_id,'output',task_id,attempt,'',summary FROM local_submissions WHERE attempt=(SELECT MAX(b.attempt) FROM local_submissions b WHERE b.chain_id=local_submissions.chain_id AND b.task_id=local_submissions.task_id);

DROP TRIGGER receipt_scope;
CREATE TRIGGER receipt_scope BEFORE INSERT ON command_receipts
WHEN NOT EXISTS(SELECT 1 FROM task_chains WHERE chain_id=NEW.chain_id)
 OR (NEW.task_id!='' AND NOT EXISTS(SELECT 1 FROM tasks WHERE chain_id=NEW.chain_id AND task_id=NEW.task_id)
     AND NOT (NEW.method='task.delete' AND EXISTS(SELECT 1 FROM task_deletions d WHERE d.chain_id=NEW.chain_id AND d.task_id=NEW.task_id AND d.seq=NEW.commit_seq)))
 OR EXISTS(SELECT 1 FROM operation_tombstones WHERE principal_id=NEW.principal_id AND operation_id=NEW.operation_id)
BEGIN SELECT RAISE(ABORT,'receipt scope or retired operation'); END;
CREATE TRIGGER task_deletion_no_update BEFORE UPDATE ON task_deletions BEGIN SELECT RAISE(ABORT,'immutable deletion'); END;
CREATE TRIGGER task_deletion_no_delete BEFORE DELETE ON task_deletions BEGIN SELECT RAISE(ABORT,'retain deletion'); END;
CREATE TRIGGER task_no_resurrection BEFORE INSERT ON tasks WHEN EXISTS(SELECT 1 FROM task_deletions WHERE task_id=NEW.task_id) BEGIN SELECT RAISE(ABORT,'retired task'); END;
