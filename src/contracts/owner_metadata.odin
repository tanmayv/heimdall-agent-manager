package contracts

import "core:encoding/json"

// Native source shapes: domain.Task_Chain_Member / Task_Chain_Directory.
// Original ownership is provenance, never an account/child capability.
Owner_Native_Member :: struct {
    chain_id: string,
    agent_instance_id: string,
    agent_id: string,
    owner_user_id: string,
    role: string,
    created_at: string,
}
Owner_Native_Directory :: struct {
    directory_id: string,
    chain_id: string,
    owner_user_id: string,
    path: string,
    bridge_id: string,
    vcs_kind: string,
    vcs_info_json: string,
    created_at: string,
    updated_at: string,
}
Owner_Metadata_Import :: struct {
    chain_id: string,
    owner_user_id: string,
    source_revision: string,
    kind: string,
    records: []json.Object,
}

// Strict schema checks preserve native strings, including Unicode paths and
// original timestamp spellings. Nested VCS JSON is validated but never rewritten.
owner_metadata_record_valid :: proc(row: json.Object, kind: string) -> bool {
    if len(owner_metadata_fact_fields(kind))>0 do return owner_metadata_fact_valid(row,kind)
    fields: []string
    switch kind {
    case "member": fields=[]string{"chain_id","agent_instance_id","agent_id","owner_user_id","role","created_at"}
    case "directory": fields=[]string{"directory_id","chain_id","owner_user_id","path","bridge_id","vcs_kind","vcs_info_json","created_at","updated_at"}
    case: return false
    }
    if len(row)!=len(fields) do return false
    for name in fields {
        text,str:=row[name].(json.String)
        if !str || len(text)>4096 do return false
    }
    if !owner_field_valid(owner_string(row,"chain_id"),"id") || !owner_field_valid(owner_string(row,"owner_user_id"),"id") do return false
    if len(owner_string(row,"created_at"))>128 do return false
    if kind=="member" {
        instance,agent:=owner_string(row,"agent_instance_id"),owner_string(row,"agent_id")
        return owner_field_valid(instance,"optional") && owner_field_valid(agent,"optional") &&
            owner_field_valid(owner_string(row,"role"),"id")
    }
    if !owner_field_valid(owner_string(row,"directory_id"),"id") || !owner_field_valid(owner_string(row,"bridge_id"),"optional") ||
        len(owner_string(row,"path"))==0 || len(owner_string(row,"updated_at"))>128 { return false }
    // Native directories may have no VCS detection yet; retain the exact empty
    // value as well as arbitrary object fields reported by the owning bridge.
    vcs:=owner_string(row,"vcs_info_json")
    if vcs!="" {
        value,ok:=owner_content_document(vcs)
        if _,obj:=value.(json.Object); !ok || !obj do return false
    }
    return len(owner_string(row,"vcs_kind"))<=128
}
owner_metadata_import_parse :: proc(raw:string) -> (Owner_Metadata_Import,bool) {
    if len(raw)>49152 do return {},false
    value,ok:=owner_content_document(raw)
    row,obj:=value.(json.Object)
    if !ok || !obj || len(row)!=5 do return {},false
    for name in ([4]string{"chain_id","owner_user_id","source_revision","kind"}) {
        if _,str:=row[name].(json.String); !str do return {},false
    }
    result:=Owner_Metadata_Import{
        chain_id=owner_string(row,"chain_id"),owner_user_id=owner_string(row,"owner_user_id"),
        source_revision=owner_string(row,"source_revision"),kind=owner_string(row,"kind"),
    }
    if !owner_field_valid(result.chain_id,"id") || !owner_field_valid(result.owner_user_id,"id") ||
        !owner_field_valid(result.source_revision,"id") || !owner_field_valid(result.kind,"metadata_kind") { return {},false }
    items,array:=row["records"].(json.Array)
    if !array || len(items)>100 do return {},false
    records:=make([dynamic]json.Object,context.temp_allocator)
    seen:=make(map[string]bool,context.temp_allocator)
    for item in items {
        record,valid:=item.(json.Object)
        if !valid || !owner_metadata_record_valid(record,result.kind) ||
            owner_string(record,"chain_id")!=result.chain_id || owner_string(record,"owner_user_id")!=result.owner_user_id { return {},false }
        // Native key: (chain_id, agent_instance_id), including an empty
        // historical instance value; durable agent IDs do not replace it.
        key:=owner_string(record,"directory_id")
        if result.kind=="member" do key=owner_string(record,"agent_instance_id")
        if name:=owner_metadata_fact_key(result.kind); name!="" do key=owner_string(record,name)
        if key in seen do return {},false
        seen[key]=true
        append(&records,record)
    }
    result.records=records[:]
    return result,true
}
