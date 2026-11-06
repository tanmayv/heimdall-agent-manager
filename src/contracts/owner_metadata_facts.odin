package contracts

import "core:encoding/json"

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
owner_metadata_fact_fields :: proc(kind:string) -> []Owner_Field {
    switch kind {
    case "chain": return owner_native_chain_fields[:]
    case "task": return owner_native_task_fields[:]
    case "comment": return owner_native_comment_fields[:]
    case "summary": return owner_native_summary_fields[:]
    }
    return nil
}
owner_metadata_fact_key :: proc(kind:string) -> string {
    switch kind {
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
        if !ok || len(v)>4096 do return false
        text:=string(v)
        switch f.kind {
        case "id","optional": if !owner_field_valid(text,f.kind) do return false
        case "timestamp": if len(text)>128 do return false
        case "object","object_optional":
            if text=="" && f.kind=="object_optional" do continue
            value,valid:=owner_content_document(text)
            if _,obj:=value.(json.Object); !valid || !obj do return false
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
