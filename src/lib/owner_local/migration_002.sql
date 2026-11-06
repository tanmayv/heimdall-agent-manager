-- Applied under BEGIN IMMEDIATE, together with schema_migrations.version.
ALTER TABLE runtime_database ADD COLUMN database_id TEXT NOT NULL DEFAULT '';
ALTER TABLE runtime_database ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 2 CHECK(schema_version=2);
ALTER TABLE runtime_database ADD COLUMN clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0);
ALTER TABLE runtime_database ADD COLUMN recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'));
UPDATE runtime_database SET database_id=lower(hex(randomblob(16)));
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
CREATE TRIGGER chain_identity_immutable BEFORE UPDATE ON task_chains
WHEN NEW.chain_id IS NOT OLD.chain_id OR NEW.creator IS NOT OLD.creator OR NEW.creator_key IS NOT OLD.creator_key
BEGIN SELECT RAISE(ABORT,'immutable chain identity'); END;
CREATE TRIGGER task_identity_immutable BEFORE UPDATE ON tasks
WHEN NEW.chain_id IS NOT OLD.chain_id OR NEW.task_id IS NOT OLD.task_id
BEGIN SELECT RAISE(ABORT,'immutable task identity'); END;
CREATE TRIGGER chain_revision BEFORE UPDATE ON task_chains WHEN typeof(NEW.revision)!='integer' OR NEW.revision!=OLD.revision+1
BEGIN SELECT RAISE(ABORT,'chain update requires next revision'); END;
CREATE TRIGGER task_revision BEFORE UPDATE ON tasks WHEN typeof(NEW.revision)!='integer' OR NEW.revision!=OLD.revision+1
BEGIN SELECT RAISE(ABORT,'task update requires next revision'); END;
CREATE TRIGGER grant_identity_immutable BEFORE UPDATE ON local_grants
WHEN NEW.chain_id IS NOT OLD.chain_id OR NEW.principal_id IS NOT OLD.principal_id OR NEW.key_id IS NOT OLD.key_id
BEGIN SELECT RAISE(ABORT,'immutable grant identity'); END;
CREATE TRIGGER grant_revision BEFORE UPDATE ON local_grants WHEN typeof(NEW.revision)!='integer' OR NEW.revision!=OLD.revision+1
BEGIN SELECT RAISE(ABORT,'grant update requires next revision'); END;
CREATE TRIGGER grant_valid_insert BEFORE INSERT ON local_grants
WHEN NEW.revision<1 OR NEW.expires_ms<0 OR NEW.can_read NOT IN(0,1) OR NEW.can_mutate NOT IN(0,1) OR NEW.revoked NOT IN(0,1)
BEGIN SELECT RAISE(ABORT,'invalid grant'); END;
CREATE TRIGGER grant_valid_update BEFORE UPDATE ON local_grants
WHEN NEW.expires_ms<0 OR NEW.can_read NOT IN(0,1) OR NEW.can_mutate NOT IN(0,1) OR NEW.revoked NOT IN(0,1)
BEGIN SELECT RAISE(ABORT,'invalid grant'); END;

ALTER TABLE command_receipts ADD COLUMN created_ms INTEGER NOT NULL DEFAULT 0 CHECK(created_ms>=0);
-- V1 had no creation timestamp. Expiry is later than successful admission, so
-- retaining for 30 days after it is a conservative lower bound, unlike epoch 0.
UPDATE command_receipts SET created_ms=request_expires_ms;
CREATE TABLE operation_tombstones (
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 task_id TEXT NOT NULL, method TEXT NOT NULL, input_digest TEXT NOT NULL, digest_key_id TEXT NOT NULL,
 request_expires_ms INTEGER NOT NULL, commit_seq INTEGER NOT NULL CHECK(commit_seq>0),
 PRIMARY KEY(principal_id,operation_id)
);
CREATE TRIGGER receipt_no_update BEFORE UPDATE ON command_receipts
BEGIN SELECT RAISE(ABORT,'immutable receipt'); END;
CREATE TRIGGER tombstone_no_update BEFORE UPDATE ON operation_tombstones
BEGIN SELECT RAISE(ABORT,'immutable operation tombstone'); END;
CREATE TRIGGER tombstone_no_delete BEFORE DELETE ON operation_tombstones
BEGIN SELECT RAISE(ABORT,'retain operation tombstone'); END;
CREATE TRIGGER receipt_scope BEFORE INSERT ON command_receipts
WHEN NOT EXISTS(SELECT 1 FROM task_chains WHERE chain_id=NEW.chain_id)
 OR (NEW.task_id!='' AND NOT EXISTS(SELECT 1 FROM tasks WHERE chain_id=NEW.chain_id AND task_id=NEW.task_id))
 OR EXISTS(SELECT 1 FROM operation_tombstones WHERE principal_id=NEW.principal_id AND operation_id=NEW.operation_id)
BEGIN SELECT RAISE(ABORT,'receipt scope or retired operation'); END;
CREATE TRIGGER receipt_no_forget BEFORE DELETE ON command_receipts
WHEN NOT EXISTS(SELECT 1 FROM operation_tombstones t WHERE t.principal_id=OLD.principal_id
 AND t.operation_id=OLD.operation_id AND t.input_digest=OLD.input_digest AND t.method=OLD.method
 AND t.chain_id=OLD.chain_id AND t.task_id=OLD.task_id AND t.commit_seq=OLD.commit_seq)
BEGIN SELECT RAISE(ABORT,'receipt requires retained tombstone'); END;
CREATE TRIGGER changes_no_update BEFORE UPDATE ON local_changes
BEGIN SELECT RAISE(ABORT,'immutable local change'); END;

ALTER TABLE runtime_intents ADD COLUMN principal_id TEXT NOT NULL DEFAULT '';
ALTER TABLE runtime_intents ADD COLUMN operation_id TEXT NOT NULL DEFAULT '';
ALTER TABLE runtime_intents ADD COLUMN kind TEXT NOT NULL DEFAULT 'registry';
ALTER TABLE runtime_intents ADD COLUMN destination_bridge TEXT NOT NULL DEFAULT '';
ALTER TABLE runtime_intents ADD COLUMN exact_fence_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE runtime_intents ADD COLUMN payload_digest TEXT NOT NULL DEFAULT '';
ALTER TABLE runtime_intents ADD COLUMN state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN('pending','claimed','settled'));
ALTER TABLE runtime_intents ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0);
ALTER TABLE runtime_intents ADD COLUMN next_retry_ms INTEGER NOT NULL DEFAULT 0 CHECK(next_retry_ms>=0);
ALTER TABLE runtime_intents ADD COLUMN claim_incarnation INTEGER NOT NULL DEFAULT 0 CHECK(claim_incarnation>=0);
ALTER TABLE runtime_intents ADD COLUMN result_json TEXT NOT NULL DEFAULT '';
UPDATE runtime_intents SET operation_id=intent_id,principal_id=COALESCE((SELECT principal_id FROM command_receipts r
 WHERE r.operation_id=runtime_intents.intent_id AND r.chain_id=runtime_intents.chain_id),'');
UPDATE runtime_intents SET state='settled' WHERE published=1;
CREATE INDEX runtime_intents_due ON runtime_intents(state,next_retry_ms,commit_seq);
CREATE INDEX runtime_intents_receipt ON runtime_intents(principal_id,operation_id,state);
CREATE UNIQUE INDEX runtime_intents_target ON runtime_intents(principal_id,operation_id,kind,destination_bridge);
CREATE TRIGGER intent_source BEFORE INSERT ON runtime_intents
WHEN NOT EXISTS(SELECT 1 FROM command_receipts r WHERE r.principal_id=NEW.principal_id
 AND r.operation_id=NEW.operation_id AND r.chain_id=NEW.chain_id AND r.commit_seq=NEW.commit_seq)
BEGIN SELECT RAISE(ABORT,'intent requires source receipt'); END;
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
CREATE TRIGGER intent_no_delete BEFORE DELETE ON runtime_intents
BEGIN SELECT RAISE(ABORT,'retain intent outcome'); END;
