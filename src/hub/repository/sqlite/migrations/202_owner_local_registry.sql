-- Owner-local chains deliberately have no row in legacy task_chains/tasks.
CREATE TABLE owner_local_chains (
 chain_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, owner_bridge_id TEXT NOT NULL,
 owner_key_id TEXT NOT NULL, creator_id TEXT NOT NULL,
 genesis_digest TEXT NOT NULL, genesis_json TEXT NOT NULL
);
CREATE INDEX owner_local_chains_account ON owner_local_chains(account_id,chain_id);
CREATE TRIGGER owner_local_genesis_immutable BEFORE UPDATE ON owner_local_chains
 BEGIN SELECT RAISE(ABORT,'immutable owner-local genesis'); END;
CREATE TABLE owner_local_titles (
 chain_id TEXT NOT NULL REFERENCES owner_local_chains(chain_id), task_id TEXT NOT NULL,
 metadata_revision INTEGER NOT NULL CHECK(metadata_revision>0),
 registry_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id)
);
