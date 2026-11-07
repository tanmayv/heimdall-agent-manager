#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// Event evidence is independent of receipt retention. A successful replay never
// appends; rejected commands and failed transactions leave no history behind.
// Exact signed bytes remain verbatim strings inside this owner-only document.
event_record :: proc(tx:^Transaction,seq,now:i64,chain,task,actor_kind,actor_id,kind,op,raw,payload,content,result:string) -> bool {
    if !transaction_current(tx) || seq<1 || now<0 do return false
    retirements,read:=workflow_retirement_evidence(tx.store,seq)
    if !read do return false
    deferred,deferred_ok:=workflow_deferred_evidence(tx.store,seq)
    if !deferred_ok do return false
    evidence_doc:=doc(map[string]string{"command"=raw,"payload"=payload,"content"=content,"result"=result})
    dependencies,dep_ok:=query(tx.store.db,"SELECT lease_id FROM local_dependency_retirements WHERE seq=? ORDER BY lease_id",fmt.tprintf("%d",seq))
    if !dep_ok do return false
    metadata,metadata_ok:=query(tx.store.db,"SELECT chain_id,task_id,lease_id,cause FROM local_metadata_retirements WHERE seq=? ORDER BY chain_id,task_id",fmt.tprintf("%d",seq))
    if !metadata_ok do return false
    if len(metadata)>0 do evidence_doc["metadata_retirements"]=json.String(encode(metadata))
    if len(dependencies)>0 do evidence_doc["dependency_retirements"]=json.String(encode(dependencies))
    if retirements!="[]" do evidence_doc["task_retirements"]=json.String(retirements)
    if deferred!="[]" do evidence_doc["deferred_retirements"]=json.String(deferred)
    evidence:=encode(evidence_doc)
    _,ok:=query(tx.store.db,"INSERT INTO local_events VALUES(?,?,?,?,?,?,?,?,?,'full')",
        fmt.tprintf("%d",seq),chain,task,fmt.tprintf("%d",now),actor_kind,actor_id,kind,op,evidence)
    if !ok do return false
    return work_after_event(tx,chain,task,kind,actor_id,op,payload,seq,now)
}

// Keyset inventory is stable across appends. The scope binds the authorized
// account/chain; the cursor never authorizes access to any event.
event_inventory :: proc(s:^Store,chain:string,p:json.Object) -> Result {
    scope:=contracts.owner_payload_digest(encode([3]string{s.account,chain,"history.v1"}))
    after:="0"
    cursor:=field(p,"cursor")
    if cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=2 || parts[0]!=scope do return fail("stale_cursor")
        if !contracts.owner_field_valid(parts[1],"counter") do return fail("malformed")
        after=parts[1]
    }
    limit:=number(field(p,"limit"))
    rows,ok:=query(s.db,"SELECT seq,task_id,COALESCE(ts_ms,''),actor_kind,actor_id,kind,operation_id,completeness,length(CAST(evidence_json AS BLOB)) FROM local_events WHERE chain_id=? AND seq>? ORDER BY seq LIMIT ?",chain,after,fmt.tprintf("%d",limit+1))
    if !ok do return fail("storage_error")
    result:=doc(map[string]string{"chain_id"=chain,"next_cursor"=""})
    items:=make([dynamic]json.Value,context.temp_allocator)
    last:=after
    for row,i in rows {
        if i>=int(limit) do break
        item:=doc(map[string]string{"seq"=row[0],"task_id"=row[1],"ts_ms"=row[2],"actor_kind"=row[3],"actor_id"=row[4],"kind"=row[5],"operation_id"=row[6],"completeness"=row[7],"evidence_bytes"=row[8]})
        append(&items,item)
        result["items"]=json.Array(items)
        result["next_cursor"]=json.String(fmt.tprintf("%s:%s",scope,row[0]))
        if len(encode(result))>MAX_PAGE {
            ordered_remove(&items,len(items)-1)
            break
        }
        last=row[0]
    }
    if len(items)==0 && len(rows)>0 do return fail("invalid_content")
    next:=""
    if len(items)<len(rows) do next=fmt.tprintf("%s:%s",scope,last)
    result["items"]=json.Array(items);result["next_cursor"]=json.String(next)
    return Result{code="ok",body=encode(result)}
}

// Chunk evidence separately so a rich command/result never makes the event
// inventory unpageable. Offsets are bytes and cannot split a UTF-8 code point.
event_fetch :: proc(s:^Store,chain:string,p:json.Object) -> Result {
    rows,ok:=query(s.db,"SELECT evidence_json,completeness FROM local_events WHERE chain_id=? AND seq=?",chain,field(p,"seq"))
    if !ok do return fail("storage_error")
    if len(rows)!=1 do return fail("invalid_scope")
    raw:=rows[0][0];offset:=number(field(p,"offset"))
    if offset>i64(len(raw)) || (offset<i64(len(raw)) && raw[offset]&0xc0==0x80) do return fail("malformed")
    end:=min(i64(len(raw)),offset+8192)
    for end>offset && end<i64(len(raw)) && raw[end]&0xc0==0x80 { end-=1 }
    next:=""
    if end<i64(len(raw)) do next=fmt.tprintf("%d",end)
    body:=encode(doc(map[string]string{"seq"=field(p,"seq"),"offset"=field(p,"offset"),"next_offset"=next,"evidence"=raw[offset:end],"completeness"=rows[0][1]}))
    if len(body)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=body}
}
