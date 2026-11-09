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
    // What the import neutralized before the freeze (JSON array of
    // Legacy_Migration_Blocker) and the task ids it force-held (JSON array).
    neutralized_json,forced_held_json:string,
}

// R3 one-shot import. The Hub engine is removed, so busy work no longer refuses
// selection: the import neutralizes it in the freeze transaction and records
// what it did with the same {code,count,items} shape. Codes are stable for the
// UI and ham-ctl.
Legacy_Migration_Blocker :: struct { code:string, count:i64, items:[]string }
// Verbatim export of one frozen chain. manifest_digest is the import identity.
Legacy_Migration_Export :: struct {
    manifest,manifest_digest:string,
    documents:[]string,
}
// One legacy Hub chain as Import all lists it. state: none|draining|frozen|imported.
Legacy_Chain_Row :: struct {
    chain_id,title,status:string,
    work_revision,task_count:i64,
    state,migration_id,owner_bridge_id:string,
}
