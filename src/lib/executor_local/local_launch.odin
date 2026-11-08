#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"

// Trusted output of canonical project directory and catalog/profile
// resolution, plus the full physical Spawn digest. Never decode this struct
// from a request. directory_path is empty for a launch without a project.
Local_Resources :: struct {configuration_digest,spawn_digest,directory_path:string,resolved:bool}
Local_Launch :: struct {id,instance,launch_key,configuration,spawn_digest,state:string,incarnation:i64}

local_result :: proc(s:^Store,id:string)->Result {
    rows,ok:=query(s.db,"SELECT launch_id,instance_id,launch_key,state FROM executor_local_launches WHERE launch_id=?",id)
    if !ok || len(rows)!=1 do return fail("storage_error")
    return Result{code="ok",body=encode(struct{launch_id,instance_id,launch_key,state:string}{rows[0][0],rows[0][1],rows[0][2],rows[0][3]})}
}

local_launch :: proc(s:^Store,id:string)->(Local_Launch,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return {},false
    rows,ok:=query(s.db,"SELECT launch_id,instance_id,launch_key,configuration,spawn_digest,state FROM executor_local_launches WHERE launch_id=?",id)
    if !ok || len(rows)!=1 do return {},false
    return Local_Launch{rows[0][0],rows[0][1],rows[0][2],rows[0][3],rows[0][4],rows[0][5],s.incarnation},true
}

// Atomic first-I/O consumption. Lost replies and Bridge restarts remain
// query-only; the same operation never launches again, including after exit.
// Only a native admission (the Bridge's own trusted launch command) can be
// dispatched. A pre-upgrade device-consent admission is never dispatched.
local_begin_dispatch :: proc(s:^Store,launch:Local_Launch,now:i64,resources:Local_Resources)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if launch.incarnation!=s.incarnation || !begin(s) do return false
    defer rollback(s)
    if code:=clock(s,now);code!="" do return false
    rows,ok:=query(s.db,"SELECT consent,configuration FROM executor_local_launches WHERE launch_id=? AND instance_id=? AND launch_key=? AND spawn_digest=? AND state='admitted' AND executor_incarnation=?",launch.id,launch.instance,launch.launch_key,launch.spawn_digest,fmt.tprintf("%d",s.incarnation))
    if !ok || len(rows)!=1 || rows[0][1]!=launch.configuration do return false
    if !local_native_consent(rows[0][0]) || !resources.resolved || resources.configuration_digest!=contracts.owner_payload_digest(rows[0][1]) || resources.spawn_digest!=launch.spawn_digest do return false
    changed,written:=query(s.db,"UPDATE executor_local_launches SET state='dispatching' WHERE launch_id=? AND state='admitted' RETURNING launch_id",launch.id)
    return written && len(changed)==1 && commit(s)
}

// Only an exact trusted daemon observation can refund a dispatched launch.
// No wall-clock expiry or generic instance listing establishes absence.
observe_local_child :: proc(s:^Store,launch:Local_Launch,observation:Child_Observation)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if launch.incarnation!=s.incarnation || observation.executor_incarnation!=s.incarnation || observation.instance!=launch.instance || observation.launch_key!=launch.launch_key || !begin(s) do return false
    defer rollback(s)
    rows,ok:=query(s.db,"SELECT state FROM executor_local_launches WHERE launch_id=? AND instance_id=? AND launch_key=? AND state IN ('dispatching','active','stopping')",launch.id,launch.instance,launch.launch_key)
    if !ok || len(rows)!=1 do return false
    state:="released"
    if observation.present {state="stopping" if rows[0][0]=="stopping" else "active"}
    if _,written:=query(s.db,"INSERT OR IGNORE INTO executor_local_observations VALUES(?,?,?)",launch.id,fmt.tprintf("%d",s.incarnation),"1" if observation.present else "0");!written do return false
    if _,written:=query(s.db,"UPDATE executor_local_launches SET state=?,observed_incarnation=? WHERE launch_id=?",state,fmt.tprintf("%d",s.incarnation),launch.id);!written do return false
    return commit(s)
}

// An undispatched admission has no child and can be explicitly cancelled.
// Once first I/O is consumed the charge survives until trusted exact absence.
cancel_local_admission :: proc(s:^Store,id:string)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return false
    defer rollback(s)
    rows,ok:=query(s.db,"UPDATE executor_local_launches SET state='released' WHERE launch_id=? AND state='admitted' RETURNING launch_id",id)
    return ok && len(rows)==1 && commit(s)
}

stop_local_launch :: proc(s:^Store,launch:Local_Launch)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if launch.incarnation!=s.incarnation || !begin(s) do return false
    defer rollback(s)
    rows,ok:=query(s.db,"UPDATE executor_local_launches SET state='stopping' WHERE launch_id=? AND instance_id=? AND launch_key=? AND state IN ('dispatching','active','stopping') RETURNING launch_id",launch.id,launch.instance,launch.launch_key)
    return ok && len(rows)==1 && commit(s)
}

local_reconcile_candidates :: proc(s:^Store,after:string,limit:int)->([]Local_Launch,bool) {
    context.allocator=context.temp_allocator
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable || limit<=0 || limit>RECONCILE_BATCH_MAX do return nil,false
    rows,ok:=query(s.db,"SELECT launch_id,instance_id,launch_key,configuration,spawn_digest,state FROM executor_local_launches WHERE launch_id>? AND state IN ('dispatching','active','stopping') ORDER BY launch_id LIMIT CAST(? AS INTEGER)",after,fmt.tprintf("%d",limit))
    if !ok do return nil,false
    out:=make([]Local_Launch,len(rows),context.temp_allocator)
    for row,i in rows do out[i]=Local_Launch{row[0],row[1],row[2],row[3],row[4],row[5],s.incarnation}
    return out,true
}

local_observation_current :: proc(s:^Store,launch:Local_Launch)->(stop,current:bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable || launch.incarnation!=s.incarnation do return false,false
    rows,ok:=query(s.db,"SELECT state FROM executor_local_launches WHERE launch_id=? AND instance_id=? AND launch_key=? AND configuration=? AND spawn_digest=? AND state IN ('dispatching','active','stopping')",launch.id,launch.instance,launch.launch_key,launch.configuration,launch.spawn_digest)
    if !ok || len(rows)!=1 do return false,false
    return rows[0][0]=="stopping",true
}

// A slow durable commit must not carry first physical I/O past a recovery
// fence or clock regression. This cannot restore a consumed dispatch.
local_dispatch_current :: proc(s:^Store,launch:Local_Launch,now:i64)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable || launch.incarnation!=s.incarnation do return false
    rows,ok:=query(s.db,`SELECT consent FROM executor_local_launches WHERE launch_id=? AND instance_id=? AND launch_key=? AND configuration=?
      AND executor_incarnation=? AND state='dispatching' AND (SELECT recovery_state FROM executor_runtime)='ready'
      AND (SELECT clock_high_ms FROM executor_runtime)<=CAST(? AS INTEGER)`,launch.id,launch.instance,launch.launch_key,launch.configuration,fmt.tprintf("%d",s.incarnation),fmt.tprintf("%d",now))
    return ok && len(rows)==1 && local_native_consent(rows[0][0])
}

// The Bridge's own admission record. It carries no device signature: the
// launch command already arrived over the trusted Hub path (vault-encrypted
// payload from the user's device, or the owner Bridge's signed dispatch).
LOCAL_NATIVE_PRINCIPAL :: "native"
LOCAL_NATIVE_SLOT :: "native_local"
local_native_consent :: proc(raw:string)->bool {
    v,ok:=contracts.owner_content_document(raw);o,object:=v.(json.Object)
    return ok && object && len(o)==2 && field(o,"kind")=="native_local" && contracts.owner_field_valid(field(o,"draft_id"),"hash")
}
