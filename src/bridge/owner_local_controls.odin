package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"

// The owner mutex serializes this consumer with switch/claim. The startup I/O
// lock serializes exact-child validation with local relaunch and token rotation.
// No SQLite transaction is open while talking to the PTY daemon.
bridge_owner_control_notice :: proc(s:^owner.Store,claim:owner.Intent_Claim) -> (bool,string,i64) {
    now:=time.to_unix_nanoseconds(time.now())/1000000
    expected:owner.Child
    if json.unmarshal_string(claim.fence,&expected,.JSON,context.temp_allocator)!=nil do return false,"malformed_child",now
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_local_token_mutex)
    inst,found:=bridge_runtime_instance_snapshot(expected.instance)
    matched,has_token:=false,false
    for i:=len(bridge_local_token_records)-1;i>=0;i-=1 {
        r:=bridge_local_token_records[i]
        if r.agent_instance_id!=expected.instance || r.role!=.Agent || r.invalidated_at_unix_ms!=0 do continue
        has_token=true
        epoch:=fmt.tprintf("local_%s",contracts.owner_payload_digest(inst.startup.launch_key))
        if separator:=strings.index(r.instance_token,"~");separator>=0 do epoch=r.instance_token[separator+1:]
        matched=found && inst.startup.launch_key!="" && epoch==expected.epoch && i64(r.run_count)==expected.run_count &&
          contracts.owner_payload_digest(r.token_hash)==expected.token_generation
        break
    }
    sync.mutex_unlock(&bridge_local_token_mutex)
    if has_token && (!found || inst.startup.launch_key=="") do return false,"child_unverified",now
    if has_token && !matched do return true,"obsolete_child",now
    socket:=pty_host_socket_path();defer delete(socket)
    if !matched {
        reply,ok:=bridge_pty_host_list(socket)
        if !ok do return false,"child_unavailable",now
        defer pty_host_reply_delete(reply)
        for child in reply.agents do if child.instance_id==expected.instance do return false,"child_unverified",now
        return true,"child_absent",now
    }
    pid,queried:=bridge_pty_host_startup_launch(socket,expected.instance,inst.startup.launch_key)
    if !queried do return false,"child_unavailable",now
    if pid==0 {
        if claim.kind=="stop" do bridge_owner_control_stopped(expected.instance)
        return true,"child_absent",now
    }
    active,read:=owner.query(s.db,"SELECT task_id FROM local_leases WHERE instance_id=? AND launch_epoch=? AND run_count=? AND token_generation=? AND retired_seq IS NULL",expected.instance,expected.epoch,fmt.tprintf("%d",expected.run_count),expected.token_generation)
    if !read do return false,"storage_error",now
    payload,valid:=contracts.owner_request_document(claim.payload);p,obj:=payload.(json.Object)
    if !valid || !obj do return false,"malformed_notice",now
    method,task:=contracts.owner_string(p,"method"),contracts.owner_string(p,"task_id")
    if method=="task.hold" {
        held,read:=owner.query(s.db,"SELECT 1 FROM local_controls WHERE task_id=? AND mode='held'",task)
        if !read do return false,"storage_error",now
        if len(held)==0 do return true,"obsolete_checkpoint",now
    }
    reviews,reviews_ok:=owner.query(s.db,"SELECT task_id FROM local_review_sessions WHERE json_extract(child,'$.instance')=? AND json_extract(child,'$.epoch')=? AND json_extract(child,'$.run_count')=CAST(? AS INTEGER) AND json_extract(child,'$.token_generation')=?",expected.instance,expected.epoch,fmt.tprintf("%d",expected.run_count),expected.token_generation)
    if !reviews_ok do return false,"storage_error",now
    if reason:=bridge_owner_control_notice_scope(claim.kind,method,task,active[:],reviews[:]);reason!="" do return true,reason,now
    if claim.kind=="checkpoint" {
        // Notification asks the child to inspect authoritative local state; it
        // conveys no approval, lease or capability.
        text:=fmt.tprintf("[owner-local] %s on task %s; inspect owner-local runtime.\n",contracts.owner_string(p,"method"),contracts.owner_string(p,"task_id"))
        sent:=bridge_pty_host_deliver_raw_input_string(expected.instance,text)
        return sent,"checkpoint",now
    }
    if claim.kind!="stop" do return false,"invalid_notice",now
    bridge_runtime_mark_stop_intent_io_locked(expected.instance)
    if !bridge_pty_host_close(socket,expected.instance) do return false,"stop_failed",now
    bridge_owner_control_stopped(expected.instance)
    return true,"stopped",now
}
// Caller still holds startup I/O lock; a restarted child cannot appear between
// daemon absence/close and invalidation of the exact stopped generation.
bridge_owner_control_stopped :: proc(instance:string) {
    bridge_runtime_mark_stop_intent_io_locked(instance)
    _=bridge_agent_token_invalidate_instance(instance)
    bridge_runtime_remove_launch(instance)
    bridge_runtime_set_status(instance,"stopped","idle")
}

// Hold notifications address the existing live holder. Other stale stop or
// checkpoint intents must never interrupt a child transferred to another task.
bridge_owner_control_notice_scope :: proc(kind,method,task:string,work,reviews:[][]string) -> string {
    for row in work {
        if kind!="checkpoint" || (method!="requirements.edit" && method!="task.hold") || row[0]!=task do return "child_has_new_lease"
    }
    for row in reviews {
        if kind!="checkpoint" || method!="task.hold" || row[0]!=task do return "child_has_review_session"
    }
    return ""
}
