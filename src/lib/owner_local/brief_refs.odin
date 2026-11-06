#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import contracts "odin_test:contracts"

// Only immutable owner-local rows participate. The Store already pins the
// account; chain membership is checked in each query, including deleted tasks.
brief_inputs_resolve :: proc(s:^Store,chain,raw:string) -> (string,string) {
    v,parsed:=contracts.owner_request_document(raw);brief,obj:=v.(json.Object)
    if !parsed || !obj do return "","invalid_content"
    inputs,present:=brief["inputs"]
    if !present do return "[]","ok"
    refs,array:=inputs.(json.Array)
    if !array || len(refs)>100 do return "","invalid_content"
    items:=make([dynamic]json.Object,context.temp_allocator)
    for value in refs {
        text,is_string:=value.(json.String)
        ref,valid:=contracts.owner_pinned_ref(string(text))
        if !is_string || !valid do return "","invalid_content"
        rows:[dynamic][]string
        ok:bool
        if ref.kind=="event" {
            rows,ok=query(s.db,"SELECT DISTINCT record_json FROM native_history_records WHERE chain_id=? AND record_kind='event' AND record_key=?",chain,ref.key)
        } else {
            rows,ok=query(s.db,"SELECT DISTINCT record_json FROM native_history_records WHERE chain_id=? AND task_id=? AND record_kind='facet' AND attempt_no=? AND facet_kind=? AND (?='' OR facet_version=?)",chain,ref.task,ref.attempt,ref.key,ref.version,ref.version)
        }
        if !ok do return "","storage_error"
        source:="native_history"
        body:=""
        if len(rows)==1 { body=rows[0][0] } else if len(rows)>1 { return "","invalid_content" } else if ref.kind=="event" {
            local,read:=query(s.db,"SELECT evidence_json FROM local_events WHERE chain_id=? AND seq=? AND completeness='full'",chain,ref.key)
            if !read do return "","storage_error"
            if len(local)!=1 do return "","invalid_scope"
            body=local[0][0];source="local_event"
        } else if ref.key=="output" && ref.version=="1" {
            local,read:=query(s.db,"SELECT output_json FROM local_workflow_outputs WHERE chain_id=? AND task_id=? AND attempt=?",chain,ref.task,ref.attempt)
            if !read do return "","storage_error"
            if len(local)!=1 do return "","invalid_scope"
            body=local[0][0];source="local_output"
        } else { return "","invalid_scope" }
        append(&items,doc(map[string]string{"ref"=string(text),"source"=source,"account_id"=s.account,"chain_id"=chain,"digest"=payload_hash(body),"body"=body}))
    }
    result:=encode(items)
    if len(result)>MAX_BODY || len(encode(result))>MAX_ENCODED_FIELD do return "","invalid_content"
    return result,"ok"
}
brief_inputs_pin :: proc(s:^Store,chain,task,revision,raw:string) -> string {
    inputs,code:=brief_inputs_resolve(s,chain,raw)
    if code!="ok" do return code
    if _,ok:=query(s.db,"INSERT INTO local_brief_inputs VALUES(?,?,?,?)",chain,task,revision,inputs);!ok do return "storage_error"
    return "ok"
}
brief_inputs_read :: proc(s:^Store,chain,task,revision,raw:string) -> (string,bool) {
    rows,ok:=query(s.db,"SELECT inputs_json FROM local_brief_inputs WHERE chain_id=? AND task_id=? AND requirements_revision=?",chain,task,revision)
    if !ok do return "",false
    if len(rows)==1 do return rows[0][0],true
    // Old requirements are unchanged evidence. Resolve only immutable refs;
    // legacy mutable inputs fail closed until explicitly edited and pinned.
    inputs,code:=brief_inputs_resolve(s,chain,raw)
    return inputs,code=="ok"
}
