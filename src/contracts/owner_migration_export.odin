package contracts

import "core:encoding/json"

// R3 one-shot legacy import. The Hub serializes one consistent read of a frozen
// legacy chain as verbatim table rows (every column, original IDs, authors and
// timestamps) and a manifest of per-kind row counts and per-document SHA-256
// hashes. The manifest digest is the import identity: the owner Bridge refetches
// and rehashes every document before its single import transaction, and its
// signed migration_import_receipt binds that digest. Transport is chunked by
// document, never by the 64 KiB owner command body cap.
OWNER_MIGRATION_EXPORT_FORMAT :: "heimdall.legacy-aggregate.v1"
// Rows are packed into documents of about this size. A larger single row gets
// a document of its own, bounded by OWNER_MIGRATION_ROW_MAX.
OWNER_MIGRATION_PART_TARGET :: 256 * 1024
OWNER_MIGRATION_ROW_MAX :: 4 * 1024 * 1024
OWNER_MIGRATION_DOCUMENT_MAX :: OWNER_MIGRATION_ROW_MAX + 4096
OWNER_MIGRATION_MAX_DOCUMENTS :: 4096
OWNER_MIGRATION_MANIFEST_MAX :: 1024 * 1024

// scope is a WHERE clause whose ?1 is the chain id; order makes reads stable.
Owner_Export_Kind :: struct { kind, table, scope, order: string }
OWNER_MIGRATION_EXPORT_KINDS := [?]Owner_Export_Kind{
    {"chain", "task_chains", "chain_id=?1", "chain_id"},
    {"task", "tasks", "chain_id=?1", "task_id"},
    {"dependency", "task_dependencies", "chain_id=?1", "task_id,depends_on_task_id"},
    {"comment", "task_comments", "chain_id=?1", "created_at,comment_id"},
    {"summary", "chain_summaries", "chain_id=?1", "chain_id"},
    {"member", "task_chain_members", "chain_id=?1", "agent_instance_id"},
    {"directory", "task_chain_directories", "chain_id=?1", "directory_id"},
    {"fleet", "task_chain_fleets", "task_chain_id=?1", "agent_id"},
    {"lease", "task_leases", "chain_id=?1", "lease_id"},
    {"event", "task_events", "chain_id=?1", "event_id"},
    {"attempt", "task_attempts", "chain_id=?1", "task_id,attempt_no"},
    {"facet", "task_attempt_facets", "chain_id=?1", "task_id,attempt_no,kind"},
    {"review", "task_reviews", "chain_id=?1", "task_id,attempt_no,role,reviewer_agent_id"},
    {"workflow_run", "workflow_runs", "chain_id=?1", "run_id"},
    {"workflow_execution", "workflow_run_executions", "chain_id=?1", "run_id,execution_no"},
    {"workflow_stage", "workflow_stage_executions", "chain_id=?1", "run_id,execution_no,stage_key"},
    {"workflow_event", "workflow_run_events", "chain_id=?1", "event_id"},
    {"work_dependency", "work_dependencies", "chain_id=?1", "dependency_id"},
    {"work_receipt", "work_input_receipts", "chain_id=?1", "receipt_id"},
    {"work_scope", "work_scope_decisions", "chain_id=?1", "decision_id"},
    {"work_completion", "work_chain_completions", "chain_id=?1", "completion_id"},
    {"artifact", "artifacts", "chain_id=?1", "artifact_id"},
    {"conversation", "chat_conversations", "chain_id=?1", "conversation_id"},
    {"message", "chat_messages", "conversation_id IN (SELECT conversation_id FROM chat_conversations WHERE chain_id=?1)", "created_at,message_id"},
}

// Rows of these kinds are preserved verbatim in the owner's import archive but
// are not turned into live owner-local authority. Stated in every manifest so
// nothing is dropped silently.
OWNER_MIGRATION_ARCHIVAL_ONLY := [?]Owner_Migration_Note{
    {"member", "owner-local members bind an exact launched child (launch epoch, run count, token generation) that legacy rows never recorded; re-add members after cutover"},
    {"fleet", "owner-local fleet assignment needs a signed per-task configuration bound to a live child; reconfigure the fleet after cutover"},
    {"directory", "owner-local directories are signed device configuration; re-attach directories after cutover"},
    {"lease", "a frozen chain has no live lease; any row is archival"},
    {"event", "imported as native history (native.history.read); legacy events never replay into local lifecycle"},
    {"attempt", "imported as native history; no local lease or submission is fabricated"},
    {"facet", "imported as native history with empty references; no local submission is fabricated"},
    {"review", "verdicts on finished attempts are archival; tasks awaiting review are refused before freeze"},
    {"workflow_run", "terminal workflow runs are archival; their generated tasks import as ordinary tasks"},
    {"workflow_execution", "archival"},
    {"workflow_stage", "archival"},
    {"workflow_event", "archival"},
    {"work_dependency", "only task-to-task edges that are not removed become live dependencies; edges naming workflow runs are archival"},
    {"work_receipt", "archival"},
    {"work_scope", "archival"},
    {"artifact", "metadata and inline content archived; bytes behind blob_ref stay in Hub artifact storage"},
    {"conversation", "archival"},
    {"message", "archival"},
}

Owner_Migration_Note :: struct { kind, reason: string }
Owner_Migration_Kind_Count :: struct { kind, table: string, rows: i64 }
Owner_Migration_Document_Ref :: struct { index: i64, kind: string, rows, bytes: i64, sha256: string }
// Field order is the serialized order; the Hub marshals this struct exactly once
// and both sides hash those bytes, never a re-serialization.
Owner_Migration_Manifest :: struct {
    format, account_id, chain_id, migration_id, selection_digest: string,
    source_generation, work_revision: i64,
    kinds: []Owner_Migration_Kind_Count,
    documents: []Owner_Migration_Document_Ref,
    archival_only: []Owner_Migration_Note,
    // Tasks the Hub's one-shot import force-held (in progress, or released from
    // a never-succeeded workflow gate): the owner imports them held.
    forced_held: []string,
}

owner_migration_export_kind :: proc(kind: string) -> (Owner_Export_Kind, bool) {
    for k in OWNER_MIGRATION_EXPORT_KINDS do if k.kind == kind do return k, true
    return {}, false
}

// Strict structural check of a manifest that the caller has already hashed.
// Allocations use context.temp_allocator.
owner_migration_manifest_parse :: proc(raw: string) -> (Owner_Migration_Manifest, bool) {
    m: Owner_Migration_Manifest
    if len(raw) == 0 || len(raw) > OWNER_MIGRATION_MANIFEST_MAX do return {}, false
    if json.unmarshal_string(raw, &m, .JSON, context.temp_allocator) != nil do return {}, false
    if m.format != OWNER_MIGRATION_EXPORT_FORMAT || !owner_field_valid(m.account_id, "id") || !owner_field_valid(m.chain_id, "id") ||
       !owner_field_valid(m.migration_id, "id") || !owner_hex(m.selection_digest, 64) || m.source_generation < 0 || m.work_revision < 0 {
        return {}, false
    }
    if len(m.kinds) != len(OWNER_MIGRATION_EXPORT_KINDS) || len(m.documents) > OWNER_MIGRATION_MAX_DOCUMENTS do return {}, false
    per_kind := make(map[string]i64, context.temp_allocator)
    for k, i in m.kinds {
        expected := OWNER_MIGRATION_EXPORT_KINDS[i]
        if k.kind != expected.kind || k.table != expected.table || k.rows < 0 do return {}, false
    }
    for d, i in m.documents {
        if d.index != i64(i) || !owner_hex(d.sha256, 64) || d.rows < 1 || d.bytes < 1 || d.bytes > OWNER_MIGRATION_DOCUMENT_MAX do return {}, false
        if _, known := owner_migration_export_kind(d.kind); !known do return {}, false
        per_kind[d.kind] += d.rows
    }
    for k in m.kinds do if per_kind[k.kind] != k.rows do return {}, false
    if i64(len(m.forced_held)) > per_kind["task"] do return {}, false
    for id in m.forced_held do if !owner_field_valid(id, "id") do return {}, false
    // A chain always exports itself exactly once.
    return m, len(m.kinds) > 0 && m.kinds[0].rows == 1
}

// A document is {"format","kind","index","rows":[{column:value,...}]}; values are
// JSON strings, integers or null exactly as stored by the Hub.
owner_migration_document_parse :: proc(raw: string, ref: Owner_Migration_Document_Ref) -> (json.Array, bool) {
    if i64(len(raw)) != ref.bytes || owner_payload_digest(raw) != ref.sha256 do return nil, false
    v, err := json.parse_string(raw, .JSON, true, context.temp_allocator)
    o, obj := v.(json.Object)
    if err != nil || !obj || len(o) != 4 do return nil, false
    index, integer := o["index"].(json.Integer)
    rows, array := o["rows"].(json.Array)
    if owner_string(o, "format") != OWNER_MIGRATION_EXPORT_FORMAT || owner_string(o, "kind") != ref.kind || !integer || i64(index) != ref.index || !array || i64(len(rows)) != ref.rows do return nil, false
    for row in rows {
        r, is_row := row.(json.Object)
        if !is_row || len(r) == 0 do return nil, false
        for _, value in r {
            #partial switch _ in value {
            case json.String, json.Integer, json.Null:
            case: return nil, false
            }
        }
    }
    return rows, true
}
