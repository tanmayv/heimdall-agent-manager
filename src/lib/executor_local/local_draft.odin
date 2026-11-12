#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"

// Native-only snapshot. material contains startup credentials and is never
// included in a device inspect result or accepted from encrypted relay input.
Local_Draft :: struct {id,configuration,material,principal,key,state,launch_id:string,revision:i64}

local_draft_source :: proc(s:^Store,source:string)->(Local_Draft,bool) {
    id:=contracts.owner_payload_digest(encode([3]string{"local-draft",s.executor,source}))
    return local_draft_native(s,id)
}

// The native source digest identifies one exact ordinary launch generation.
// Retrying it returns the original random material, including after restart.
// Staging is inert: no token activation, bootstrap write, resource charge or I/O.
stage_local_draft :: proc(s:^Store,source,configuration,material:string)->(Local_Draft,string) {
    c,valid:=contracts.executor_parse(configuration,"local_configuration")
    v,decoded:=contracts.owner_content_document(material);_,object:=v.(json.Object)
    if !valid || !scope(s,c) || !contracts.owner_field_valid(source,"hash") ||
       len(material)>contracts.EXECUTOR_DOCUMENT_MAX || !decoded || !object {return {},"malformed"}
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return {},"storage_error"
    defer rollback(s)
    id:=contracts.owner_payload_digest(encode([3]string{"local-draft",s.executor,source}))
    prior,found:=local_draft_tx(s,id)
    if found do return prior,"ok"
    if num(c,"executor_incarnation")!=s.incarnation do return {},"stale_incarnation"
    rows,read:=query(s.db,"SELECT count(*) FROM executor_local_drafts")
    if !read do return {},"storage_error"
    if number(rows[0][0])>=MAX_RECORDS do return {},"retention_capacity"
    if _,written:=query(s.db,"INSERT INTO executor_local_drafts(draft_id,source_digest,revision,configuration,material,state) VALUES(?,?,1,?,?,'pending')",id,source,configuration,material);!written {return {},"storage_error"}
    result,ready:=local_draft_tx(s,id)
    if !ready || !commit(s) do return {},"storage_error"
    return result,"ok"
}

local_draft_tx :: proc(s:^Store,id:string)->(Local_Draft,bool) {
    rows,read:=query(s.db,"SELECT draft_id,configuration,material,principal_id,key_id,state,coalesce(launch_id,''),revision FROM executor_local_drafts WHERE draft_id=?",id)
    if !read || len(rows)!=1 do return {},false
    r:=rows[0]
    return Local_Draft{r[0],r[1],r[2],r[3],r[4],r[5],r[6],number(r[7])},true
}
local_draft_native :: proc(s:^Store,id:string)->(Local_Draft,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return {},false
    return local_draft_tx(s,id)
}

// Native authorization: the Bridge admits its own exact staged draft. The
// launch command reached this Bridge over the trusted Hub path, so no device
// approval, slot policy or signed directory mapping is consulted. The only
// shared constraint is one live exact child per instance (schema trigger).
// Retrying returns the retained admission; it never mints a second one.
authorize_native_local :: proc(s:^Store,draft_id:string,now:i64,resources:Local_Resources)->Result {
    context.allocator=context.temp_allocator
    started:=time.tick_now()
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    now:=effective_now(s,now) // C1: decide with max(caller clock, store clock), under the store mutex
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    d,found:=local_draft_tx(s,draft_id)
    if !found do return fail("draft_not_found")
    if d.state=="cancelled" do return fail("draft_cancelled")
    if d.launch_id!="" do return local_result(s,d.launch_id)
    c,configured:=contracts.executor_parse(d.configuration,"local_configuration")
    if !configured || !scope(s,c) do return fail("malformed")
    config_digest:=contracts.owner_payload_digest(d.configuration)
    if !resources.resolved || resources.configuration_digest!=config_digest || resources.spawn_digest!=field(c,"spawn_digest") do return fail("invalid_resources")
    if num(c,"executor_incarnation")!=s.incarnation do return fail("stale_incarnation")
    if code:=clock(s,now);code!="" do return fail(code)
    quota,q_ok:=query(s.db,"SELECT count(*) FROM executor_local_launches")
    if !q_ok do return fail("storage_error")
    if number(quota[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    live,checked:=query(s.db,`SELECT 1 FROM executor_local_launches WHERE instance_id=? AND state!='released'
      UNION ALL SELECT 1 FROM executor_reservations WHERE instance_id=? AND state!='released'`,field(c,"instance_id"),field(c,"instance_id"))
    if !checked do return fail("storage_error")
    if len(live)>0 do return fail("instance_not_drained")
    id:=contracts.owner_payload_digest(encode([4]string{"local-launch",s.executor,LOCAL_NATIVE_PRINCIPAL,d.id}))
    launch_key:=contracts.owner_payload_digest(encode([3]string{"local-launch-key",id,config_digest}))
    consent:=encode(struct{kind,draft_id:string}{"native_local",d.id})
    _,written:=query(s.db,`INSERT INTO executor_local_launches VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,'admitted',0)`,
        id,LOCAL_NATIVE_PRINCIPAL,d.id,config_digest,consent,d.configuration,LOCAL_NATIVE_SLOT,field(c,"instance_id"),"",field(c,"executor_incarnation"),launch_key,field(c,"spawn_digest"),fmt.tprintf("%d",now),fmt.tprintf("%d",started._nsec))
    if !written do return fail("storage_error")
    if d.principal=="" {
        if _,ok:=query(s.db,"UPDATE executor_local_drafts SET principal_id=?,key_id=?,state='authorized',launch_id=? WHERE draft_id=?",LOCAL_NATIVE_PRINCIPAL,LOCAL_NATIVE_PRINCIPAL,id,d.id);!ok do return fail("storage_error")
    } else if _,ok:=query(s.db,"UPDATE executor_local_drafts SET state='authorized',launch_id=? WHERE draft_id=?",id,d.id);!ok {return fail("storage_error")}
    result:=local_result(s,id)
    if result.code!="ok" || !commit(s) do return fail("storage_error")
    return result
}

// Undispatched admissions for an instance have no child and are released
// before a newer generation is admitted. Dispatched rows are never refunded
// here; only an exact daemon observation establishes their absence.
local_instance_launches :: proc(s:^Store,instance:string)->([]Local_Launch,bool) {
    context.allocator=context.temp_allocator
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return nil,false
    rows,ok:=query(s.db,"SELECT launch_id,instance_id,launch_key,configuration,spawn_digest,state FROM executor_local_launches WHERE instance_id=? AND state!='released' ORDER BY launch_id",instance)
    if !ok do return nil,false
    out:=make([]Local_Launch,len(rows),context.temp_allocator)
    for row,i in rows do out[i]=Local_Launch{row[0],row[1],row[2],row[3],row[4],row[5],s.incarnation}
    return out,true
}
