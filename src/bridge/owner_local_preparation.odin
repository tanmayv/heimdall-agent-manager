package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import channel "odin_test:lib/executor_channel"
import vault "odin_test:lib/vault"

bridge_owner_prepare_worker:Owner_Executor_Worker
bridge_owner_prepare_chain,bridge_owner_prepare_task:string

// Called by the single executor worker. The owner mutex covers local decisions
// only; the retained opaque response survives transient database failures.
bridge_owner_preparation_once :: proc(s:^owner.Store) {
    public:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
    own:=contracts.Owner_Verified_Key{s.account,s.owner,s.owner_key,public,"bridge",true,false}
    sync.mutex_lock(&bridge_owner_mutex)
    // C1: read the clock under the owner mutex, never before it.
    now:=time.to_unix_nanoseconds(time.now())/1000000
    // Rotate a bounded scan, so inadmissible early assignments cannot starve
    // later chains. Exact initiation remains idempotent in the owner journal.
    busy,busy_ok:=owner.query(s.db,"SELECT 1 FROM owner_execution_journal WHERE state='preparing' AND prepare_until_ms>CAST(? AS INTEGER) LIMIT 1",fmt.tprintf("%d",now))
    candidates,read:=owner.query(s.db,`SELECT f.chain_id,f.task_id FROM local_fleet f
      JOIN local_assignment_history h ON h.chain_id=f.chain_id AND h.task_id=f.task_id AND h.revision=f.configuration_revision
      WHERE f.enabled=1 AND json_extract(h.command_json,'$.method')='fleet.reserve'
      AND (f.chain_id>? OR (f.chain_id=? AND f.task_id>?)) ORDER BY f.chain_id,f.task_id LIMIT 20`,
      bridge_owner_prepare_chain,bridge_owner_prepare_chain,bridge_owner_prepare_task)
    if read && busy_ok && len(busy)==0 {
        if len(candidates)==0 {
            delete(bridge_owner_prepare_chain,runtime.default_allocator());delete(bridge_owner_prepare_task,runtime.default_allocator())
            bridge_owner_prepare_chain="";bridge_owner_prepare_task=""
        }
        for row in candidates {
            result:=owner.execution_prepare_assignment(s,row[0],row[1],own,now,{nil,bridge_owner_sign})
            bridge_owner_prepare_log(row[0],row[1],result.code)
            delete(bridge_owner_prepare_chain,runtime.default_allocator());delete(bridge_owner_prepare_task,runtime.default_allocator())
            bridge_owner_prepare_chain=strings.clone(row[0],runtime.default_allocator());bridge_owner_prepare_task=strings.clone(row[1],runtime.default_allocator())
            if result.code=="ok" && !result.replay do break
        }
    }
    sync.mutex_unlock(&bridge_owner_mutex)
    _=bridge_owner_preparation_batch(&bridge_owner_prepare_worker,s,&bridge_owner_mutex,now,own,nil,
        bridge_owner_preparation_snapshot,bridge_owner_executor_exchange,bridge_owner_preparation_accept)
}

Owner_Preparation_Snapshot :: #type proc(rawptr,^owner.Store,i64)->(owner.Intent_Claim,string,bool)

// Injected callbacks exercise the same unlocked I/O and retained-response path.
bridge_owner_preparation_batch :: proc(w:^Owner_Executor_Worker,s:^owner.Store,mutex:^sync.Mutex,now:i64,
    own:contracts.Owner_Verified_Key,ctx:rawptr,snapshot:Owner_Preparation_Snapshot,
    exchange:Owner_Executor_Exchange,accept:Owner_Executor_Accept,
    current:proc(^owner.Store,string,i64)->bool=owner.execution_preparation_current)->bool {
    if !sync.mutex_try_lock(&w.mutex) do return false
    defer sync.mutex_unlock(&w.mutex)
    sync.mutex_lock(mutex)
    now:=owner.effective_now(s,now) // C1: read before the lock; monotonic clamp
    if !w.pending {
        c,pin,ok:=snapshot(ctx,s,now)
        if !ok {sync.mutex_unlock(mutex);return false}
        if c.id=="" {sync.mutex_unlock(mutex);return true}
        bridge_owner_executor_keep(w,c,pin)
    }
    prepared,parsed:=contracts.executor_parse(w.claim.fence,"prepare")
    if parsed && (contracts.executor_number(prepared,"prepare_until_ms")<=now ||
        contracts.executor_number(prepared,"owner_incarnation")!=s.incarnation) {
        bridge_owner_executor_clear(w);sync.mutex_unlock(mutex);return true
    }
    if !current(s,w.claim.id,now) {
        // A failed admission read is indistinguishable from cancellation here.
        // Retain the outcome, send nothing, and retry local observation only.
        sync.mutex_unlock(mutex);return false
    }
    sync.mutex_unlock(mutex)
    if !w.received {
        response,completed:=exchange(ctx,w.claim,w.snapshot)
        if len(response)>3*1024*1024 || completed<0 || completed>0x7fffffffffffffff-60000 {response="";completed=now}
        // Runtime allocator, not request temp storage.
        w.response=strings.clone(response,runtime.default_allocator())
        w.completed=completed;w.received=true
    }
    sync.mutex_lock(mutex);defer sync.mutex_unlock(mutex)
    if !current(s,w.claim.id,max(now,w.completed)) do return false
    ready,success,code:=accept(ctx,s,w.claim,w.snapshot,w.response,max(now,w.completed))
    if !ready do return false
    if !success do bridge_owner_preparation_log_refusal(w.claim,code)
    bridge_owner_executor_clear(w)
    return true
}

// A refused remote prepare/query used to be silent: the reservation expired
// and was retried with no trace (Mundus .13). Log each distinct refusal once
// per reservation so the next retry's identical outcome does not flood.
bridge_owner_preparation_last_refusal:string
bridge_owner_preparation_log_refusal :: proc(c:owner.Intent_Claim,code:string) {
    key:=fmt.tprintf("%s|%s|%s",c.id,c.kind,code)
    if key==bridge_owner_preparation_last_refusal do return
    delete(bridge_owner_preparation_last_refusal,runtime.default_allocator())
    bridge_owner_preparation_last_refusal=strings.clone(key,runtime.default_allocator())
    fmt.eprintfln("bridge owner remote %s refused by Bridge %s: %s (chain %s, reservation %s)",c.kind,c.destination,code,c.chain,c.id)
}

bridge_owner_preparation_snapshot :: proc(_:rawptr,s:^owner.Store,now:i64)->(owner.Intent_Claim,string,bool) {
    entries,ok:=owner.execution_preparations(s)
    if !ok do return {},"",false
    for entry in entries {
        if !owner.execution_preparation_current(s,entry.reservation,now) do continue
        p,valid:=contracts.executor_parse(entry.prepare,"prepare")
        if !valid do return {},"",false
        rows,read:=owner.query(s.db,"SELECT query_json FROM owner_execution_queries WHERE reservation_id=?",entry.reservation)
        if !read do return {},"",false
        c:=owner.Intent_Claim{id=entry.reservation,chain=contracts.owner_string(p,"chain_id"),
            kind="executor.prepare",destination=contracts.owner_string(p,"executor_bridge_id"),fence=entry.prepare,payload=entry.prepare}
        if len(rows)==1 {c.kind="executor.query";c.payload=rows[0][0]}
        c.digest=contracts.owner_payload_digest(c.payload)
        assignment,a_ok:=owner.query(s.db,"SELECT payload_json FROM local_assignment_history WHERE chain_id=? AND task_id=? AND revision=?",
            c.chain,contracts.owner_string(p,"task_id"),contracts.owner_string(p,"configuration_revision"))
        if !a_ok || len(assignment)!=1 do return {},"",false
        config,parsed:=owner.remote_assignment_configuration(assignment[0][0])
        if !parsed do return {},"",false
        return c,bridge_owner_json(Owner_Executor_Pin{key_id=contracts.owner_string(config,"executor_key_id"),generation=bridge_task_chain_search_generation()}),true
    }
    return {},"",true
}

bridge_owner_preparation_accept :: proc(_:rawptr,s:^owner.Store,c:owner.Intent_Claim,snapshot,response:string,now:i64)->(bool,bool,string) {
    pin:Owner_Executor_Pin;outcome:Owner_Executor_Outcome
    if json.unmarshal_string(snapshot,&pin,.JSON,context.temp_allocator)!=nil ||
       json.unmarshal_string(response,&outcome,.JSON,context.temp_allocator)!=nil {return true,false,"malformed_executor_response"}
    if pin.generation!=bridge_task_chain_search_generation() || sync.atomic_load(&bridge_hub_traffic_stopped) do return true,false,"vault_locked"
    if outcome.code!="response" do return true,false,outcome.code
    envelope:Owner_Executor_HTTP_Reply
    if json.unmarshal_string(outcome.body,&envelope,.JSON,context.temp_allocator)!=nil do return true,false,"malformed_executor_response"
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return true,false,"vault_locked"
    key,trusted,read:=bridge_owner_executor_directory(s,envelope.data.directory,pin,c,&kr)
    if !read do return false,false,"storage_error"
    if !trusted do return true,false,"invalid_executor_directory"
    scope,scoped:=contracts.executor_parse(outcome.scope,"transport_scope")
    reply:Owner_Executor_Command_Reply
    if !scoped || json.unmarshal_string(envelope.data.reply,&reply,.JSON,context.temp_allocator)!=nil ||
       reply.request_id!=contracts.owner_string(scope,"request_id") || reply.type!="command_result" {return true,false,"invalid_executor_reply"}
    // Keep the executor's own refusal code (e.g. invalid_scope, stale_incarnation) for the log.
    if reply.code!="ok" do return true,false,fmt.tprintf("executor_refused:%s",reply.code)
    raw,authenticated:=channel.open_signed(reply.envelope,&kr,scope,key,now,context.temp_allocator)
    if !authenticated do return true,false,"invalid_executor_receipt"
    public:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
    own:=contracts.Owner_Verified_Key{s.account,s.owner,s.owner_key,public,"bridge",true,false}
    result:owner.Result
    if c.kind=="executor.prepare" {
        // Even a fresh prepare reply is followed by the durable exact query.
        result=owner.execution_query_start(s,c.id,raw,own,key,now,{nil,bridge_owner_sign})
    } else {
        rows,ok:=owner.query(s.db,"SELECT prepare_receipt,query_json FROM owner_execution_queries WHERE reservation_id=?",c.id)
        if !ok do return false,false,"storage_error"
        if len(rows)!=1 || rows[0][1]!=c.payload do return true,false,"query_changed"
        result=owner.execution_prepare_commit(s,c.id,rows[0][0],own,key,now,{nil,bridge_owner_sign},rows[0][1],raw)
    }
    return result.code!="storage_error" && result.code!="invalid_scope",result.code=="ok",result.code
}

// G3: a refused preparation is never silent. Each task's refusal code is
// logged once when it first appears or changes (the loop runs every second).
bridge_owner_prepare_seen:map[string]string
bridge_owner_prepare_log :: proc(chain,task,code:string) {
    key:=fmt.tprintf("%s|%s",chain,task)
    if bridge_owner_prepare_seen==nil do bridge_owner_prepare_seen=make(map[string]string,runtime.default_allocator())
    last,seen:=bridge_owner_prepare_seen[key]
    if code=="ok" {
        if seen {
            stored_key,stored_value:=delete_key(&bridge_owner_prepare_seen,key)
            delete(stored_key,runtime.default_allocator());delete(stored_value,runtime.default_allocator())
        }
        return
    }
    if seen && last==code do return
    fmt.eprintfln("bridge owner preparation: %s %s refused: %s",chain,task,code)
    if seen {
        delete(bridge_owner_prepare_seen[key],runtime.default_allocator())
        bridge_owner_prepare_seen[key]=strings.clone(code,runtime.default_allocator())
        return
    }
    if len(bridge_owner_prepare_seen)>=1024 {
        for k,v in bridge_owner_prepare_seen {delete(k,runtime.default_allocator());delete(v,runtime.default_allocator())}
        clear(&bridge_owner_prepare_seen)
    }
    bridge_owner_prepare_seen[strings.clone(key,runtime.default_allocator())]=strings.clone(code,runtime.default_allocator())
}
