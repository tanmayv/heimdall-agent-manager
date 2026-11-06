PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
PRAGMA foreign_keys=ON;
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS runtime_database (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS task_chains (
 chain_id TEXT PRIMARY KEY, creator TEXT NOT NULL, creator_key TEXT NOT NULL,
 title TEXT NOT NULL, description TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0)
);
CREATE TABLE IF NOT EXISTS chain_genesis (
 chain_id TEXT PRIMARY KEY REFERENCES task_chains(chain_id),
 creation_op TEXT NOT NULL UNIQUE, genesis_digest TEXT NOT NULL, genesis_json TEXT NOT NULL
);
CREATE TRIGGER IF NOT EXISTS genesis_immutable_update BEFORE UPDATE ON chain_genesis BEGIN SELECT RAISE(ABORT,'immutable genesis'); END;
CREATE TRIGGER IF NOT EXISTS genesis_immutable_delete BEFORE DELETE ON chain_genesis BEGIN SELECT RAISE(ABORT,'immutable genesis'); END;
CREATE TABLE IF NOT EXISTS local_grants (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), principal_id TEXT NOT NULL,
 key_id TEXT NOT NULL, revision INTEGER NOT NULL, expires_ms INTEGER NOT NULL,
 can_read INTEGER NOT NULL, can_mutate INTEGER NOT NULL, revoked INTEGER NOT NULL,
 PRIMARY KEY(chain_id,principal_id,key_id)
);
CREATE TABLE IF NOT EXISTS tasks (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), task_id TEXT NOT NULL,
 title TEXT NOT NULL, body TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 PRIMARY KEY(chain_id,task_id), UNIQUE(task_id)
);
CREATE TABLE IF NOT EXISTS task_comments (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 principal_id TEXT NOT NULL, body TEXT NOT NULL, seq INTEGER NOT NULL,
 PRIMARY KEY(principal_id,operation_id),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS command_receipts (
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, chain_id TEXT NOT NULL,
 task_id TEXT NOT NULL, method TEXT NOT NULL, input_digest TEXT NOT NULL,
 digest_key_id TEXT NOT NULL, request_expires_ms INTEGER NOT NULL,
 result_json TEXT NOT NULL, commit_seq INTEGER NOT NULL,
 PRIMARY KEY(principal_id,operation_id)
);
CREATE TABLE IF NOT EXISTS runtime_intents (
 intent_id TEXT PRIMARY KEY, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 commit_seq INTEGER NOT NULL, payload_json TEXT NOT NULL, published INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS local_changes (
 seq INTEGER PRIMARY KEY, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 kind TEXT NOT NULL, object_id TEXT NOT NULL, object_revision INTEGER NOT NULL, operation TEXT NOT NULL
);
