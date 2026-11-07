package domain

// Minimal source fencing metadata. Original signed documents and aggregate
// bodies are not cached here. Callers verify current directory consent before
// using these repository inputs; hashes alone confer no migration authority.
Legacy_Migration_Selection :: struct {
    account_id,chain_id,migration_id,owner_bridge_id,owner_key_id,selection_digest:string,
    expected_work_revision:i64,
}
Legacy_Source_Effect :: struct {
    account_id,chain_id,effect_id,bridge_id,kind,input_digest,command_id:string,
}
Legacy_Source_Fence :: struct {
    selection:Legacy_Migration_Selection,
    state,quiescence_digest:string,
    revision,generation:i64,
    manifest_digest,receipt_digest:string,
}

// R3 one-shot import. A blocker refuses selection before any write; codes are
// stable for the UI and ham-ctl.
Legacy_Migration_Blocker :: struct { code:string, count:i64 }
// Verbatim export of one frozen chain. manifest_digest is the import identity.
Legacy_Migration_Export :: struct {
    manifest,manifest_digest:string,
    documents:[]string,
}
