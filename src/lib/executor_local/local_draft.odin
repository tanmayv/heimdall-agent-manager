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

local_draft_consent :: proc(s:^Store,draft:Local_Draft)->(string,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable || draft.launch_id=="" do return "",false
    rows,read:=query(s.db,`SELECT consent FROM executor_local_launches l JOIN executor_local_drafts d ON d.launch_id=l.launch_id
      WHERE d.draft_id=? AND d.state='authorized' AND l.state IN ('admitted','dispatching','active')`,draft.id)
    if !read || len(rows)!=1 do return "",false
    return rows[0][0],true
}

// Selection is a native proposal from installed signed resources, never new
// authority. Authorization and first dispatch revalidate these exact versions.
// Empty path is allowed only when a single current mapping is unambiguous.
local_draft_selection :: proc(s:^Store,profile,path:string)->(slot,directory:string,policy:i64,mapping:Directory_Mapping,code:string) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return "","",0,{},"storage_error"
    rows,read:=query(s.db,`SELECT directory_id,directory_path,directory_key,revision FROM executor_directories d
      WHERE enabled=1 AND revision=(SELECT max(revision) FROM executor_directories WHERE directory_id=d.directory_id)
      AND (?='' OR directory_path=?) ORDER BY directory_id LIMIT 2`,path,path)
    if !read do return "","",0,{},"storage_error"
    if len(rows)!=1 do return "","",0,{},"directory_selection_required"
    r:=rows[0]
    slots,found:=query(s.db,`SELECT slot_id,(SELECT policy_revision FROM executor_runtime) FROM executor_slots
      WHERE provider_profile=? AND enabled=1 AND NOT EXISTS(SELECT 1 FROM executor_live_resources r WHERE r.slot_id=executor_slots.slot_id)
      ORDER BY slot_id LIMIT 1`,profile)
    if !found do return "","",0,{},"storage_error"
    if len(slots)!=1 do return "","",0,{},"slot_selection_required"
    return slots[0][0],r[0],number(slots[0][1]),Directory_Mapping{r[1],r[2],number(r[3])},"ok"
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

// Explicit projection: neither material, consent, launch key nor local token.
// The public configuration contains only digests of native random material.
local_draft_view :: proc(s:^Store,id:string)->Result {
    d,found:=local_draft_tx(s,id)
    if !found do return fail("draft_not_found")
    launch_state:=""
    if d.launch_id!="" {
        rows,read:=query(s.db,"SELECT state FROM executor_local_launches WHERE launch_id=?",d.launch_id)
        if !read || len(rows)!=1 do return fail("storage_error")
        launch_state=rows[0][0]
    }
    return Result{code="ok",body=encode(struct{draft_id,draft_revision,configuration,configuration_digest,state,launch_state:string}{
        d.id,fmt.tprintf("%d",d.revision),d.configuration,contracts.owner_payload_digest(d.configuration),d.state,launch_state})}
}

// Exact signed draft operations are serialized with first dispatch in the
// same Store mutex. Authorization, quota admission, cancellation and receipts
// each commit atomically. Fresh enrolled keys remain mandatory even on replay.
local_draft_command :: proc(s:^Store,raw:string,key:contracts.Owner_Verified_Key,now:i64,resources:Local_Resources={})->Result {
    context.allocator=context.temp_allocator
    started:=time.tick_now()
    o,valid:=contracts.executor_parse(raw,"local_draft")
    if !valid do return fail("malformed")
    if !scope(s,o) || !contracts.executor_verify("local_draft",o,key) do return fail("invalid_scope")
    digest,_:=contracts.executor_digest("local_draft",o)
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    d,found:=local_draft_tx(s,field(o,"draft_id"))
    if !found do return fail("draft_not_found")
    method:=field(o,"method")
    // A different enrolled principal/key cannot inspect, replay or cancel it.
    if d.principal!="" && (d.principal!=key.principal_id || d.key!=key.key_id) do return fail("draft_not_owned")
    if field(o,"draft_revision")!=fmt.tprintf("%d",d.revision) ||
       field(o,"configuration_digest")!=contracts.owner_payload_digest(d.configuration) {return fail("draft_conflict")}
    rows,read:=query(s.db,"SELECT input_digest,result_json FROM executor_local_draft_receipts WHERE principal_id=? AND operation_id=?",key.principal_id,field(o,"operation_id"))
    if !read do return fail("storage_error")
    if len(rows)>0 {
        if rows[0][0]!=digest do return fail("operation_conflict")
        return Result{code="ok",body=rows[0][1],replay=true}
    }
    if now<num(o,"issued_ms") || !request_live(o,now) do return fail("expired")
    // Cancellation and inspect are allowed during recovery; neither refunds a
    // dispatched row. Clock regression still rejects all fresh operations.
    if code:=clock(s,now,false);code!="" do return fail(code)
    quota,checked:=query(s.db,"SELECT count(*) FROM executor_local_draft_receipts")
    if !checked do return fail("storage_error")
    if number(quota[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    if d.principal=="" {
        if method!="prepare" do return fail("draft_not_owned")
        if _,written:=query(s.db,"UPDATE executor_local_drafts SET principal_id=?,key_id=?,state='prepared' WHERE draft_id=? AND state='pending'",key.principal_id,key.key_id,d.id);!written {return fail("storage_error")}
    } else if method=="authorize" {
        if d.state=="cancelled" do return fail("draft_cancelled")
        // A second authorize operation must never mint another admission.
        if d.state!="authorized" {
            if d.state!="prepared" do return fail("draft_not_prepared")
            c,configured:=contracts.executor_parse(d.configuration,"local_configuration")
            if !configured do return fail("storage_error")
            admitted:=admit_local_tx(s,raw,d.configuration,o,c,digest,now,resources,started)
            if admitted.code!="ok" do return admitted
            v,_:=contracts.owner_content_document(admitted.body);body,_:=v.(json.Object)
            if _,written:=query(s.db,"UPDATE executor_local_drafts SET state='authorized',launch_id=? WHERE draft_id=?",field(body,"launch_id"),d.id);!written {return fail("storage_error")}
        }
    } else if method=="cancel" {
        if d.launch_id!="" {
            launch,read:=query(s.db,"SELECT state FROM executor_local_launches WHERE launch_id=?",d.launch_id)
            if !read || len(launch)!=1 do return fail("storage_error")
            state:=launch[0][0]
            if state=="admitted" {
                if _,written:=query(s.db,"UPDATE executor_local_launches SET state='released' WHERE launch_id=? AND state='admitted'",d.launch_id);!written {return fail("storage_error")}
            } else if state!="released" {
                // Uncertain and live children retain their shared budget until
                // exact daemon stop/reconciliation establishes trusted absence.
                if _,written:=query(s.db,"UPDATE executor_local_launches SET state='stopping' WHERE launch_id=?",d.launch_id);!written {return fail("storage_error")}
            }
        }
        if _,written:=query(s.db,"UPDATE executor_local_drafts SET state='cancelled' WHERE draft_id=?",d.id);!written {return fail("storage_error")}
    } else if method=="prepare" && d.state!="prepared" {
        return fail("draft_not_prepared")
    }
    result:=local_draft_view(s,d.id)
    if result.code!="ok" do return result
    if _,written:=query(s.db,"INSERT INTO executor_local_draft_receipts VALUES(?,?,?,?,?)",key.principal_id,field(o,"operation_id"),digest,d.id,result.body);!written {return fail("storage_error")}
    if !commit(s) do return fail("storage_error")
    return result
}
