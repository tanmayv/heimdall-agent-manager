-- V30 (R3): one-shot import of a frozen legacy Hub chain. The import is one
-- transaction; the chain stays quarantined (no admission, no mutation) until
-- the Hub has committed its cutover and the owner records activation.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v30 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 30 CHECK(schema_version=30),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v30 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,30,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v30 RENAME TO runtime_database;
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
-- migrate() adds chain_genesis.import_manifest_hash before this script.
CREATE TABLE IF NOT EXISTS migration_imports (
 migration_id TEXT NOT NULL, manifest_digest TEXT NOT NULL CHECK(length(manifest_digest)=64),
 chain_id TEXT NOT NULL UNIQUE REFERENCES task_chains(chain_id),
 selection_digest TEXT NOT NULL CHECK(length(selection_digest)=64),
 principal_id TEXT NOT NULL, key_id TEXT NOT NULL,
 import_seq INTEGER NOT NULL CHECK(import_seq>0),
 manifest_json TEXT NOT NULL, receipt_json TEXT NOT NULL, summary_json TEXT NOT NULL,
 activated_seq INTEGER CHECK(activated_seq IS NULL OR activated_seq>import_seq),
 PRIMARY KEY(migration_id,manifest_digest), UNIQUE(migration_id)
);
CREATE TRIGGER IF NOT EXISTS migration_import_identity BEFORE UPDATE ON migration_imports
WHEN NEW.migration_id IS NOT OLD.migration_id OR NEW.manifest_digest IS NOT OLD.manifest_digest
 OR NEW.chain_id IS NOT OLD.chain_id OR NEW.selection_digest IS NOT OLD.selection_digest
 OR NEW.principal_id IS NOT OLD.principal_id OR NEW.key_id IS NOT OLD.key_id
 OR NEW.import_seq IS NOT OLD.import_seq OR NEW.manifest_json IS NOT OLD.manifest_json
 OR NEW.receipt_json IS NOT OLD.receipt_json OR NEW.summary_json IS NOT OLD.summary_json
 OR OLD.activated_seq IS NOT NULL OR NEW.activated_seq IS NULL
BEGIN SELECT RAISE(ABORT,'immutable migration import'); END;
CREATE TRIGGER IF NOT EXISTS migration_import_no_delete BEFORE DELETE ON migration_imports
BEGIN SELECT RAISE(ABORT,'retained migration import'); END;
-- Verbatim, hash-verified export documents: the lossless archival copy.
CREATE TABLE IF NOT EXISTS migration_import_documents (
 migration_id TEXT NOT NULL REFERENCES migration_imports(migration_id),
 doc_index INTEGER NOT NULL CHECK(doc_index>=0), kind TEXT NOT NULL,
 row_count INTEGER NOT NULL CHECK(row_count>0), sha256 TEXT NOT NULL CHECK(length(sha256)=64),
 body TEXT NOT NULL,
 PRIMARY KEY(migration_id,doc_index)
);
CREATE TRIGGER IF NOT EXISTS migration_import_document_no_update BEFORE UPDATE ON migration_import_documents
BEGIN SELECT RAISE(ABORT,'immutable migration document'); END;
CREATE TRIGGER IF NOT EXISTS migration_import_document_no_delete BEFORE DELETE ON migration_import_documents
BEGIN SELECT RAISE(ABORT,'immutable migration document'); END;
