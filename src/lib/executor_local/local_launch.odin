#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"

// Trusted output of canonical directory and catalog/profile resolution, plus
// the full physical Spawn digest. Never decode this struct from a request.
Local_Resources :: struct {configuration_digest,spawn_digest,directory_path:string,resolved:bool}
Local_Launch :: struct {id,instance,launch_key,configuration,spawn_digest,state:string,incarnation:i64}

local_result :: proc(s:^Store,id:string)->Result {
    rows,ok:=query(s.db,"SELECT launch_id,instance_id,launch_key,state FROM executor_local_launches WHERE launch_id=?",id)
    if !ok || len(rows)!=1 do return fail("storage_error")
    return Result{code="ok",body=encode(struct{launch_id,instance_id,launch_key,state:string}{rows[0][0],rows[0][1],rows[0][2],rows[0][3]})}
}

// Consent grants one exact local identity, never a task grant. Historical
// replay returns the retained result but cannot reacquire physical permission.
admit_local :: proc(s:^Store,raw,configuration:string,key:contracts.Owner_Verified_Key,now:i64,resources:Local_Resources)->Result {
    context.allocator=context.temp_allocator
    started:=time.tick_now()
    o,valid:=contracts.executor_parse(raw,"local_launch")
    c,configured:=contracts.executor_parse(configuration,"local_configuration")
    if !valid || !configured do return fail("malformed")
    if !scope(s,o) || !scope(s,c) || !contracts.executor_verify("local_launch",o,key) do return fail("invalid_scope")
    digest,_:=contracts.executor_digest("local_launch",o)
    if contracts.owner_payload_digest(configuration)!=field(o,"configuration_digest") do return fail("digest_mismatch")
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    result:=admit_local_tx(s,raw,configuration,o,c,digest,now,resources,started)
    if result.code=="ok" && !result.replay && !commit(s) do return fail("storage_error")
    return result
}

// Caller authenticates the command and holds the mutex and SQL transaction.
// Shared by standalone consent and exact draft authorization, so the draft,
// admission, and operation receipt commit or roll back together.
admit_local_tx :: proc(s:^Store,raw,configuration:string,o,c:json.Object,digest:string,now:i64,resources:Local_Resources,started:time.Tick)->Result {
    config_digest:=contracts.owner_payload_digest(configuration)
    rows,read:=query(s.db,"SELECT launch_id,input_digest FROM executor_local_launches WHERE principal_id=? AND operation_id=?",field(o,"principal_id"),field(o,"operation_id"))
    if !read do return fail("storage_error")
    if len(rows)>0 {
        if rows[0][1]!=digest do return fail("operation_conflict")
        result:=local_result(s,rows[0][0]);result.replay=true
        return result
    }
    if now<num(o,"issued_ms") || !request_live(o,now) do return fail("expired")
    if code:=clock(s,now);code!="" do return fail(code)
    if num(c,"executor_incarnation")!=s.incarnation do return fail("stale_incarnation")
    if !resources.resolved || resources.configuration_digest!=config_digest || resources.spawn_digest!=field(c,"spawn_digest") || resources.directory_path=="" do return fail("invalid_resources")
    mapping,mapped:=query(s.db,"SELECT directory_path,directory_key,revision,enabled FROM executor_directories WHERE directory_id=? ORDER BY revision DESC LIMIT 1",field(c,"directory_id"))
    if !mapped do return fail("storage_error")
    if len(mapping)!=1 || mapping[0][3]!="1" || mapping[0][0]!=resources.directory_path || mapping[0][1]!=field(c,"directory_key") || mapping[0][2]!=field(c,"directory_revision") do return fail("invalid_resources")
    quota,q_ok:=query(s.db,"SELECT count(*) FROM executor_local_launches")
    if !q_ok do return fail("storage_error")
    if number(quota[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    policy,policy_ok:=query(s.db,"SELECT policy_revision,device_capacity,(SELECT count(*) FROM executor_live_resources) FROM executor_runtime WHERE singleton=1")
    if !policy_ok || len(policy)!=1 do return fail("storage_error")
    if policy[0][0]!=field(c,"policy_revision") do return fail("stale_policy")
    if number(policy[0][2])>=number(policy[0][1]) do return fail("capacity_exhausted")
    slots,slots_ok:=query(s.db,"SELECT 1 FROM executor_slots WHERE slot_id=? AND provider_profile=? AND enabled=1",field(c,"slot_id"),field(c,"provider_profile"))
    if !slots_ok do return fail("storage_error")
    if len(slots)!=1 do return fail("invalid_slot")
    conflicts,checked:=query(s.db,"SELECT 1 FROM executor_live_resources WHERE slot_id=? OR instance_id=? OR directory_key=?",field(c,"slot_id"),field(c,"instance_id"),field(c,"directory_key"))
    if !checked do return fail("storage_error")
    if len(conflicts)>0 do return fail("resource_conflict")
    id:=contracts.owner_payload_digest(encode([4]string{"local-launch",s.executor,field(o,"principal_id"),field(o,"operation_id")}))
    launch_key:=contracts.owner_payload_digest(encode([3]string{"local-launch-key",id,digest}))
    _,written:=query(s.db,`INSERT INTO executor_local_launches VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,'admitted',0)`,
        id,field(o,"principal_id"),field(o,"operation_id"),digest,raw,configuration,field(c,"slot_id"),field(c,"instance_id"),field(c,"directory_key"),field(c,"executor_incarnation"),launch_key,field(c,"spawn_digest"),fmt.tprintf("%d",now),fmt.tprintf("%d",started._nsec))
    if !written do return fail("storage_error")
    result:=local_result(s,id)
    if result.code!="ok" do return fail("storage_error")
    return result
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
local_begin_dispatch :: proc(s:^Store,launch:Local_Launch,key:contracts.Owner_Verified_Key,now:i64,resources:Local_Resources)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if launch.incarnation!=s.incarnation || !begin(s) do return false
    defer rollback(s)
    if code:=clock(s,now);code!="" do return false
    rows,ok:=query(s.db,"SELECT consent,configuration,admitted_ms,admitted_tick_ns FROM executor_local_launches WHERE launch_id=? AND instance_id=? AND launch_key=? AND spawn_digest=? AND state='admitted' AND executor_incarnation=?",launch.id,launch.instance,launch.launch_key,launch.spawn_digest,fmt.tprintf("%d",s.incarnation))
    if !ok || len(rows)!=1 || rows[0][1]!=launch.configuration do return false
    o,kind,valid:=local_consent(rows[0][0])
    c,configured:=contracts.executor_parse(rows[0][1],"local_configuration")
    if !valid || !configured || !contracts.executor_verify(kind,o,key) || !local_time_live(o,now,number(rows[0][2]),number(rows[0][3])) || !resources.resolved || resources.configuration_digest!=contracts.owner_payload_digest(rows[0][1]) || resources.spawn_digest!=launch.spawn_digest do return false
    current,read:=query(s.db,`SELECT 1 FROM executor_runtime WHERE policy_revision=? AND
      EXISTS(SELECT 1 FROM executor_slots WHERE slot_id=? AND provider_profile=? AND enabled=1) AND
      EXISTS(SELECT 1 FROM executor_directories WHERE directory_id=? AND revision=? AND enabled=1 AND directory_key=? AND directory_path=?
       AND revision=(SELECT max(revision) FROM executor_directories WHERE directory_id=?))`,
      field(c,"policy_revision"),field(c,"slot_id"),field(c,"provider_profile"),field(c,"directory_id"),field(c,"directory_revision"),field(c,"directory_key"),resources.directory_path,field(c,"directory_id"))
    if !read || len(current)!=1 do return false
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

// A slow durable commit must not carry first physical I/O past consent expiry.
// This check cannot restore a consumed dispatch or authorize another Spawn.
local_dispatch_current :: proc(s:^Store,launch:Local_Launch,key:contracts.Owner_Verified_Key,now:i64)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable || launch.incarnation!=s.incarnation do return false
    rows,ok:=query(s.db,`SELECT consent,admitted_ms,admitted_tick_ns FROM executor_local_launches WHERE launch_id=? AND instance_id=? AND launch_key=? AND configuration=?
      AND executor_incarnation=? AND state='dispatching' AND (SELECT recovery_state FROM executor_runtime)='ready'
      AND (SELECT clock_high_ms FROM executor_runtime)<=CAST(? AS INTEGER)`,launch.id,launch.instance,launch.launch_key,launch.configuration,fmt.tprintf("%d",s.incarnation),fmt.tprintf("%d",now))
    if !ok || len(rows)!=1 do return false
    o,kind,valid:=local_consent(rows[0][0])
    return valid && contracts.executor_verify(kind,o,key) && local_time_live(o,now,number(rows[0][1]),number(rows[0][2]))
}

// The saved monotonic admission time belongs only to this runtime incarnation.
// Reopening the ledger fences all old admissions before interpreting its tick.
local_time_live :: proc(o:json.Object,now,admitted_ms,admitted_tick_ns:i64)->bool {
    elapsed:=time.tick_since(time.Tick{admitted_tick_ns})
    remaining:=num(o,"request_expires_ms")-admitted_ms
    return now>=admitted_ms && now>=num(o,"issued_ms") && request_live(o,now) &&
        remaining>0 && remaining<=contracts.EXECUTOR_TRANSPORT_TTL_MS &&
        elapsed>=0 && elapsed<time.Duration(remaining)*time.Millisecond
}


// A draft authorize command is itself exact device consent. Other draft
// methods can never be interpreted as permission for physical dispatch.
local_consent :: proc(raw:string)->(json.Object,string,bool) {
    if o,valid:=contracts.executor_parse(raw,"local_launch");valid do return o,"local_launch",true
    o,valid:=contracts.executor_parse(raw,"local_draft")
    return o,"local_draft",valid && field(o,"method")=="authorize"
}
