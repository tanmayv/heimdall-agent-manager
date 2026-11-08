-- V35 (R2-1/R3-1 gate integrity): a review row records the principal kind that
-- signed it. Only a device-signed review ('device') can satisfy a user-approval
-- gate; an agent row, including a coordinator's review post --on-behalf-of
-- user (review.human), is 'agent' and never counts as the user.
-- The principal_kind column itself is added by migrate() (re-runnable after a
-- test downgrade of the version). Backfill: an existing row is 'agent' unless
-- its principal is a device key of the chain (the chain creator or a grantee)
-- and no agent-attributed event recorded that exact review operation.
-- Attempts already past the gate are not re-gated (state is not touched);
-- attempts still in_review keep waiting for a device-signed review.
-- runtime_database.schema_version is pinned per version: rebuild it as V33 did.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v35 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 35 CHECK(schema_version=35),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v35 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,35,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v35 RENAME TO runtime_database;
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
DROP TRIGGER IF EXISTS local_reviews_immutable;
UPDATE local_reviews SET principal_kind='device' WHERE principal_kind!='device'
 AND (EXISTS(SELECT 1 FROM task_chains c WHERE c.chain_id=local_reviews.chain_id AND c.creator=local_reviews.principal_id)
  OR EXISTS(SELECT 1 FROM local_grants g WHERE g.chain_id=local_reviews.chain_id AND g.principal_id=local_reviews.principal_id))
 AND NOT EXISTS(SELECT 1 FROM local_events e WHERE e.chain_id=local_reviews.chain_id AND e.actor_kind='agent'
  AND e.actor_id=local_reviews.principal_id AND e.operation_id=local_reviews.operation_id);
CREATE TRIGGER local_reviews_immutable BEFORE UPDATE ON local_reviews BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
