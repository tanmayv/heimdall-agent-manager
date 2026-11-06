package contracts

import "core:encoding/json"
import "core:fmt"

// Native source facts; never live projections or C3 local_objects.
@(private)
owner_native_chain_fields := [?]Owner_Field{
    {"chain_id", "id"},
    {"owner_user_id", "id"},
    {"title", "text"},
    {"description", "text"},
    {"publish_state", "publish"},
    {"status", "chain_status"},
    {"kind", "chain_kind"},
    {"coordinator_agent_instance_id", "optional"},
    {"defaults_json", "object"},
    {"work_revision", "integer"},
    {"completion_summary", "text"},
    {"last_activity_at", "timestamp"},
    {"last_title_nudge_at", "timestamp"},
    {"title_source", "text"},
    {"created_at", "timestamp"},
    {"updated_at", "timestamp"},
    {"published_at", "timestamp"},
    {"completed_at", "timestamp"},
    {"is_pinned", "boolean"},
    {"pinned_at", "timestamp"},
}
@(private)
owner_native_task_fields := [?]Owner_Field{
    {"task_id", "id"},
    {"chain_id", "id"},
    {"owner_user_id", "id"},
    {"title", "text"},
    {"description", "text"},
    {"publish_state", "publish"},
    {"state", "task_state"},
    {"kind", "task_kind"},
    {"priority", "priority"},
    {"attempt_no", "integer"},
    {"brief_json", "object"},
    {"blocked_on_json", "object_optional"},
    {"requires_user_approval", "boolean"},
    {"ready_since", "text"},
    {"bridge_id", "optional"},
    {"workflow_run_id", "optional"},
    {"workflow_execution_no", "integer"},
    {"stage_key", "optional"},
    {"stage_index", "integer"},
    {"generated_by_json", "object_optional"},
    {"created_at", "timestamp"},
    {"updated_at", "timestamp"},
    {"published_at", "timestamp"},
    {"started_at", "timestamp"},
    {"completed_at", "timestamp"},
}
@(private)
owner_native_comment_fields := [?]Owner_Field{
    {"delegated_client_id", "optional"},
    {"delegated_grant_id", "optional"},
    {"comment_id", "id"},
    {"task_id", "id"},
    {"chain_id", "id"},
    {"owner_user_id", "id"},
    {"author_agent_instance_id", "optional"},
    {"body", "text"},
    {"created_at", "timestamp"},
    {"updated_at", "timestamp"},
}
@(private)
owner_native_summary_fields := [?]Owner_Field{
    {"curated_body", "text"},
    {"curated_initialized", "boolean"},
    {"failure_fingerprint", "text"},
    {"chain_id", "id"},
    {"owner_user_id", "id"},
    {"body", "text"},
    {"line_count", "integer"},
    {"version", "integer"},
    {"updated_at", "timestamp"},
}
@(private)
owner_native_work_dependency_fields := [?]Owner_Field{
    {"dependency_id", "id"},
    {"chain_id", "id"},
    {"owner_user_id", "id"},
    {"dependent", "work_ref"},
    {"prerequisite", "work_ref"},
    {"created_by_kind", "id"},
    {"created_by_id", "id"},
    {"created_at", "timestamp"},
    {"removed_at", "timestamp"},
    {"removed_by_kind", "optional"},
    {"removed_by_id", "optional"},
    {"removal_reason", "text"},
}
@(private)
owner_native_work_receipt_fields := [?]Owner_Field{
    {"receipt_id", "id"},
    {"chain_id", "id"},
    {"owner_user_id", "id"},
    {"dependent", "work_ref"},
    {"dependent_generation", "integer"},
    {"prerequisite", "work_ref"},
    {"prerequisite_generation", "integer"},
    {"output_manifest_json", "document"},
    {"created_at", "timestamp"},
}
@(private)
owner_native_work_scope_fields := [?]Owner_Field{
    {"decision_id", "integer"},
    {"chain_id", "id"},
    {"owner_user_id", "id"},
    {"item", "work_ref"},
    {"action", "scope_action"},
    {"reason", "text"},
    {"actor_kind", "id"},
    {"actor_id", "id"},
    {"created_at", "timestamp"},
}
@(private)
owner_native_work_run_fields := [?]Owner_Field{
    {"run_id", "id"},
    {"chain_id", "id"},
    {"owner_user_id", "id"},
    {"title", "text"},
    {"definition_ref", "text"},
    {"spec_json", "object"},
    {"inputs_json", "object"},
    {"current_execution_no", "integer"},
    {"request_id", "text"},
    {"request_hash", "text"},
    {"created_by_kind", "id"},
    {"created_by_id", "id"},
    {"created_at", "timestamp"},
    {"updated_at", "timestamp"},
    {"revision", "integer"},
}
@(private)
owner_native_work_execution_fields := [?]Owner_Field{
    {"run_id", "id"},
    {"execution_no", "integer"},
    {"chain_id", "id"},
    {"owner_user_id", "id"},
    {"state", "execution_state"},
    {"resolved_inputs_json", "document"},
    {"started_at", "timestamp"},
    {"ended_at", "timestamp"},
    {"failure_code", "text"},
    {"failure_detail", "text"},
    {"output_manifest_json", "document"},
    {"revision", "integer"},
}
@(private)
owner_native_work_stage_fields := [?]Owner_Field{
    {"run_id", "id"},
    {"execution_no", "integer"},
    {"stage_key", "id"},
    {"chain_id", "id"},
    {"owner_user_id", "id"},
    {"item_count", "integer"},
    {"expanded_at", "timestamp"},
}
@(private)
owner_native_work_event_fields := [?]Owner_Field{
    {"event_id", "integer"},
    {"run_id", "id"},
    {"execution_no", "integer"},
    {"chain_id", "id"},
    {"owner_user_id", "id"},
    {"ts_ms", "integer"},
    {"actor_kind", "id"},
    {"actor_id", "id"},
    {"kind", "id"},
    {"payload_json", "object"},
}
owner_metadata_fact_fields :: proc(kind:string) -> []Owner_Field {
    switch kind {
    case "work_dependency": return owner_native_work_dependency_fields[:]
    case "work_receipt": return owner_native_work_receipt_fields[:]
    case "work_scope": return owner_native_work_scope_fields[:]
    case "work_run": return owner_native_work_run_fields[:]
    case "work_execution": return owner_native_work_execution_fields[:]
    case "work_stage": return owner_native_work_stage_fields[:]
    case "work_event": return owner_native_work_event_fields[:]
    case "chain": return owner_native_chain_fields[:]
    case "task": return owner_native_task_fields[:]
    case "comment": return owner_native_comment_fields[:]
    case "summary": return owner_native_summary_fields[:]
    }
    return nil
}
owner_metadata_fact_key :: proc(kind:string) -> string {
    switch kind {
    case "work_dependency": return "dependency_id"
    case "work_receipt": return "receipt_id"
    case "work_scope": return "decision_id"
    case "work_run": return "run_id"
    case "work_execution": return "run_id"
    case "work_stage": return "run_id"
    case "work_event": return "event_id"
    case "chain": return "chain_id"
    case "task": return "task_id"
    case "comment": return "comment_id"
    case "summary": return "chain_id"
    }
    return ""
}

owner_metadata_fact_valid :: proc(row:json.Object,kind:string) -> bool {
    fields:=owner_metadata_fact_fields(kind)
    if len(fields)==0 || len(row)!=len(fields) do return false
    for f in fields {
        if f.kind=="work_ref" {
            if !owner_work_item(row[f.name]) do return false
            continue
        }
        if f.kind=="integer" {
            n,ok:=row[f.name].(json.Integer)
            if !ok || n<0 do return false
            continue
        }
        if f.kind=="boolean" {
            if _,ok:=row[f.name].(json.Boolean); !ok do return false
            continue
        }
        v,ok:=row[f.name].(json.String)
        long_document:=f.kind=="document" || (owner_work_source_kind(kind) && (f.kind=="object" || f.kind=="object_optional"))
        if !ok || (!long_document && len(v)>4096) || len(v)>65536 do return false
        text:=string(v)
        switch f.kind {
        case "id","optional": if !owner_field_valid(text,f.kind) do return false
        case "timestamp": if len(text)>128 do return false
        case "object","object_optional":
            if text=="" && f.kind=="object_optional" do continue
            value,valid:=owner_content_document(text)
            if _,obj:=value.(json.Object); !valid || !obj do return false
        case "scope_action": if text!="include" && text!="exclude" do return false
        case "execution_state": if text!="draft" && text!="pending" && text!="running" && text!="succeeded" && text!="failed" && text!="cancelled" do return false
        case "document":
            if text!="" {if _,valid:=owner_content_document(text);!valid do return false}
        case "publish": if text!="draft" && text!="published" do return false
        case "chain_status": if text!="active" && text!="completed" && text!="cancelled" && text!="archived" do return false
        case "chain_kind": if text!="mixed_work" && text!="ticket" && text!="workflow" do return false
        case "task_state": if text!="backlog" && text!="ready" && text!="in_progress" && text!="in_review" && text!="done" && text!="cancelled" do return false
        case "task_kind": if text!="task" && text!="gate" do return false
        case "priority": if text!="p0" && text!="p1" && text!="p2" do return false
        }
    }
    return true
}

owner_work_source_kind :: proc(kind:string)->bool {
    return kind=="work_dependency" || kind=="work_receipt" || kind=="work_scope" || kind=="work_run" || kind=="work_execution" || kind=="work_stage" || kind=="work_event"
}
owner_metadata_record_key :: proc(row:json.Object,kind:string)->string {
    key:=owner_string(row,owner_metadata_fact_key(kind))
    if n,integer:=row[owner_metadata_fact_key(kind)].(json.Integer);integer {
        raw,_:=json.marshal(n,allocator=context.temp_allocator);key=string(raw)
    }
    if kind=="work_execution" || kind=="work_stage" {
        raw,_:=json.marshal(row["execution_no"],allocator=context.temp_allocator)
        key=fmt.tprintf("%s:%s",key,string(raw))
        if kind=="work_stage" {key=fmt.tprintf("%s:%s",key,owner_string(row,"stage_key"))}
    }
    return key
}
