package domain

// This is the entire durable owner-local listing projection. No task detail,
// state, comment, lease, brief or result may be added to it.
Owner_Registry_Record :: struct {
    account_id, chain_id, owner_bridge_id, owner_key_id, creator_id: string,
    genesis_digest, genesis_json: string,
    task_id, registry_json: string,
    metadata_revision: i64,
}
