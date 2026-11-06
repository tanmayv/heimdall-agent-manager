#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

read_result :: proc(s:^Store,c:json.Object,payload:string,revision:i64) -> Result {
    method,chain,task:=field(c,"method"),field(c,"chain_id"),field(c,"task_id")
    p,_:=contracts.owner_parse(payload,contracts.owner_payload_kind(method))
    if method=="native.metadata.read" do return native_metadata_read(s,chain,p)
    if method=="fleet.policy.read" do return fleet_policy_read(s,chain,p,revision)
    if method=="native.history.read" || method=="native.history.fetch" do return native_history_read(s,c,p)
    if method=="history.read" do return event_inventory(s,chain,p)
    if method=="history.fetch" do return event_fetch(s,chain,p)
    if method=="attempt.read" {
        _,record,_,ok:=attempt_scan(s,chain,task,number(field(p,"attempt")))
        if !ok do return fail("storage_error")
        if record.attempt_no=="" do return fail("invalid_scope")
        return Result{code="ok",body=encode(record)}
    }
    if method=="context.read" do return context_history(s,chain,p)
    if method=="source.read" do return source_inventory(s,chain,field(p,"cursor"),number(field(p,"limit")))
    if method=="workflow.read" do return workflow_inventory(s,chain,field(p,"cursor"),number(field(p,"limit")),revision)
    if method=="receipt.read" {
        rows,ok:=query(s.db,"SELECT method,result_json,commit_seq,chain_id,task_id FROM command_receipts WHERE principal_id=? AND operation_id=?",field(c,"principal_id"),field(p,"operation_id"))
        if !ok do return fail("storage_error")
        if len(rows)==0 {
            retired,found:=query(s.db,"SELECT chain_id FROM operation_tombstones WHERE principal_id=? AND operation_id=?",field(c,"principal_id"),field(p,"operation_id"))
            if !found do return fail("storage_error")
            if len(retired)==1 && retired[0][0]==chain do return fail("retired")
        }
        if len(rows)!=1 || rows[0][3]!=chain do return fail("invalid_scope")
        return Result{code="ok",body=rows[0][1],seq=number(rows[0][2]),replay=true}
    }
    if method=="submission.read" {
        rows,ok:=query(s.db,"SELECT summary,head,requirements_revision,configuration_revision,author_agent_id,lease_id FROM local_submissions WHERE chain_id=? AND task_id=? AND attempt=?",chain,task,field(p,"attempt"))
        if !ok do return fail("storage_error")
        if len(rows)!=1 do return fail("invalid_scope")
        summary:=rows[0][0]
        offset:=number(field(p,"offset"))
        if offset>i64(len(summary)) || (offset<i64(len(summary)) && summary[offset]&0xc0==0x80) do return fail("malformed")
        end:=min(i64(len(summary)),offset+8192)
        for end>offset && end<i64(len(summary)) && summary[end]&0xc0==0x80 {end-=1}
        next:=""
        if end<i64(len(summary)) do next=fmt.tprintf("%d",end)
        output,output_read:=query(s.db,"SELECT output_json FROM local_workflow_outputs WHERE chain_id=? AND task_id=? AND attempt=?",chain,task,field(p,"attempt"))
        if !output_read do return fail("storage_error")
        output_json:=""
        if len(output)==1 do output_json=output[0][0]
        attempts,_,native_attempt,mapped:=attempt_scan(s,chain,task,0,rows[0][5])
        if !mapped do return fail("storage_error")
        if attempts.incomplete do native_attempt=""
        body:=encode(doc(map[string]string{"native_attempt"=native_attempt,"attempt_completeness"=("incomplete" if attempts.incomplete else "full"),"output"=output_json,"kind"="submission","chain_id"=chain,"task_id"=task,"attempt"=field(p,"attempt"),"summary"=summary[offset:end],"offset"=field(p,"offset"),"next_offset"=next,"head"=rows[0][1],"requirements_revision"=rows[0][2],"configuration_revision"=rows[0][3],"author_agent_id"=rows[0][4]}))
        if len(body)>MAX_PAGE do return fail("invalid_content")
        return Result{code="ok",body=body}
    }
    if method=="runtime.read" {
        fleet,ok:=query(s.db,"SELECT instance_id,configuration_revision,enabled FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
        if !ok do return fail("storage_error")
        leases,read:=query(s.db,"SELECT lease_id,instance_id,expires_ms,hard_ms,deadline_version FROM local_leases WHERE chain_id=? AND task_id=? AND retired_seq IS NULL",chain,task)
        if !read do return fail("storage_error")
        // Fixed-size one-task observation; capabilities/token generations are
        // deliberately excluded from the human observation response.
        configs,cok:=query(s.db,"SELECT config_json FROM lifecycle_configs WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
        req,rok:=query(s.db,"SELECT revision,brief_json FROM task_requirements WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
        states,sok:=query(s.db,"SELECT state,attempt,merge_receipt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
        submissions,aok:=query(s.db,"SELECT attempt,head,requirements_revision,summary,author_agent_id FROM local_submissions WHERE chain_id=? AND task_id=? ORDER BY attempt DESC LIMIT 1",chain,task)
        if !cok || !rok || !sok || !aok do return fail("storage_error")
        controls,controls_ok:=query(s.db,"SELECT mode,resume_state,reason,waiting_on FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
        if !controls_ok do return fail("storage_error")
        attempts,attempts_ok:=attempt_view(s,chain,task)
        if !attempts_ok do return fail("storage_error")
        _,budget,budget_ok:=budget_view(s,chain,task)
        if !budget_ok do return fail("storage_error")
        return Result{code="ok",body=encode(struct { revision:string, fleet,leases,config,requirements,state,submission,controls:[dynamic][]string, attempts:contracts.Owner_Attempt_State, budget:contracts.Owner_Budget_State, }{fmt.tprintf("%d",revision),fleet,leases,configs,req,states,submissions,controls,attempt_document(attempts),budget})}
    }
    scope:=contracts.owner_payload_digest(encode([5]string{s.account,chain,task,method,fmt.tprintf("%d",revision)}))
    cursor:=field(p,"cursor")
    offset:i64
    if cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=2 || parts[0]!=scope do return fail("stale_cursor")
        offset=number(parts[1])
        if offset<0 || offset>MAX_RECORDS || fmt.tprintf("%d",offset)!=parts[1] do return fail("malformed")
    }
    limit:=number(field(p,"limit"))
    result:=make(map[string]json.Value,context.temp_allocator)
    result["chain_id"]=json.String(chain); result["task_id"]=json.String(task); result["revision"]=json.String(fmt.tprintf("%d",revision))
    rows:[dynamic][]string
    ok:bool
    if method=="chain.read" {
        header,found:=query(s.db,"SELECT title,description FROM task_chains WHERE chain_id=?",chain)
        if !found || len(header)!=1 do return fail("invalid_scope")
        result["title"]=json.String(header[0][0]);result["description"]=json.String(header[0][1])
        projection,ready:=context_materialize(s,chain)
        if !ready do return fail("storage_error")
        result["context"]=projection
        rows,ok=query(s.db,"SELECT task_id,title,revision FROM tasks WHERE chain_id=? ORDER BY task_id LIMIT ? OFFSET ?",chain,fmt.tprintf("%d",limit+1),fmt.tprintf("%d",offset))
    } else {
        header,found:=query(s.db,"SELECT title,body FROM tasks WHERE chain_id=? AND task_id=?",chain,task)
        if !found || len(header)!=1 do return fail("invalid_scope")
        result["title"]=json.String(header[0][0]);result["body"]=json.String(header[0][1])
        rows,ok=query(s.db,"SELECT operation_id,principal_id,body,seq FROM task_comments WHERE chain_id=? AND task_id=? ORDER BY seq LIMIT ? OFFSET ?",chain,task,fmt.tprintf("%d",limit+1),fmt.tprintf("%d",offset))
    }
    if !ok do return fail("storage_error")
    items:=make([dynamic]json.Value,context.temp_allocator)
    for row,i in rows {
        if i>=int(limit) do break
        item:json.Object
        if method=="chain.read" { item=doc(map[string]string{"task_id"=row[0],"title"=row[1],"revision"=row[2]}) } else {
            item=doc(map[string]string{"operation_id"=row[0],"principal_id"=row[1],"body"=row[2],"seq"=row[3]})
        }
        append(&items,item)
        // Reserve the full candidate JSON, including array commas, keys and a
        // nonterminal cursor. A terminal cursor is shorter than this reservation.
        result["items"]=json.Array(items)
        result["next_cursor"]=json.String(fmt.tprintf("%s:%d",scope,offset+i64(len(items))))
        candidate:=encode(result)
        if candidate=="" || len(candidate)>MAX_PAGE {
            ordered_remove(&items,len(items)-1)
            break
        }
    }
    // Old draft data that violates admission limits fails explicitly instead
    // of returning an empty page with the same cursor forever.
    if len(items)==0 && len(rows)>0 do return fail("invalid_content")
    next:=""
    if len(items)<len(rows) { next=fmt.tprintf("%s:%d",scope,offset+i64(len(items))) }
    result["items"]=json.Array(items);result["next_cursor"]=json.String(next)
    encoded:=encode(result)
    if encoded=="" || len(encoded)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=encoded}
}
genesis_for :: proc(s:^Store,chain:string) -> string {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    rows,ok:=query(s.db,"SELECT genesis_json FROM chain_genesis WHERE chain_id=?",chain)
    if !ok || len(rows)!=1 do return ""
    return rows[0][0]
}
directory_pin :: proc(s:^Store) -> (i64,string) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    rows,ok:=query(s.db,"SELECT directory_version,directory_hash FROM runtime_database WHERE singleton=1")
    if !ok || len(rows)!=1 do return -1,""
    return number(rows[0][0]),rows[0][1]
}
