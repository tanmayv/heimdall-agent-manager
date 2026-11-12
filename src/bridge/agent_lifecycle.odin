package main

import "base:runtime"
import "core:strings"
import "core:sync"
import jsonx "../lib/jsonx"

// Ownership stops are persisted and retried with one command id. A failure is
// an observation to reevaluate, while a successful receipt remains idempotent.
bridge_failed_fenced_stop_retry :: proc(command_type, command_json, result_json: string) -> bool {
    if command_type != "stop_agent" || jsonx.extract_int(command_json, "expected_run_count", -1) < 0 do return false
    return jsonx.extract_string(result_json, "status", "", false, context.temp_allocator) == "failed"
}

// Launch, wake and stop may enter through different dispatcher keys or local
// recovery hooks. Serialize their process/token/status changes per instance.
// The registry mutex is never held while waiting for an instance or doing I/O.
Bridge_Agent_Lifecycle :: struct {
    mutex: sync.Mutex,
    users: int,
    instance_id: string,
}
bridge_agent_lifecycle_mutex: sync.Mutex
bridge_agent_lifecycles: map[string]^Bridge_Agent_Lifecycle

bridge_agent_lifecycle_enter :: proc(instance_id:string)->^Bridge_Agent_Lifecycle {
    sync.mutex_lock(&bridge_agent_lifecycle_mutex)
    if bridge_agent_lifecycles==nil do bridge_agent_lifecycles=make(map[string]^Bridge_Agent_Lifecycle,runtime.heap_allocator())
    entry,exists:=bridge_agent_lifecycles[instance_id]
    if !exists {
        entry=new(Bridge_Agent_Lifecycle,runtime.heap_allocator())
        entry.instance_id=strings.clone(instance_id,runtime.heap_allocator())
        bridge_agent_lifecycles[entry.instance_id]=entry
    }
    entry.users+=1
    sync.mutex_unlock(&bridge_agent_lifecycle_mutex)
    sync.mutex_lock(&entry.mutex)
    return entry
}

bridge_agent_lifecycle_leave :: proc(entry:^Bridge_Agent_Lifecycle) {
    sync.mutex_unlock(&entry.mutex)
    sync.mutex_lock(&bridge_agent_lifecycle_mutex)
    defer sync.mutex_unlock(&bridge_agent_lifecycle_mutex)
    entry.users-=1
    if entry.users==0 {
        delete_key(&bridge_agent_lifecycles,entry.instance_id)
        delete(entry.instance_id,runtime.heap_allocator())
        free(entry,runtime.heap_allocator())
    }
}

// The generation comparison and every destructive stop side effect share the
// same critical section as launch, including failure-status restoration.
bridge_runtime_stop_generation :: proc(instance_id:string,force:bool,expected_run_count:int,stop:=bridge_runtime_stop_agent_unlocked, absent:=bridge_runtime_process_absent)->(ok:bool,restored:string,stale:bool) {
    lifecycle:=bridge_agent_lifecycle_enter(instance_id)
    defer bridge_agent_lifecycle_leave(lifecycle)
    if expected_run_count>=0 && bridge_agent_instance_run_count(instance_id)!=expected_run_count {
        // A newer token alone says nothing about the old child. A successful
        // daemon enumeration can prove there is no process to stop, without
        // touching the newer generation's credentials or projected status.
        if absent(instance_id) do return true,"",false
        return false,"",true
    }
    ok,restored=bridge_runtime_stop_or_restore_unlocked(instance_id,force,stop)
    return ok,restored,false
}

bridge_runtime_process_absent :: proc(instance_id: string) -> bool {
    socket, daemon_ok := bridge_pty_host_ensure_daemon()
    if !daemon_ok do return false
    reply, listed := bridge_pty_host_list(socket)
    if !listed do return false
    defer pty_host_reply_delete(reply)
    for agent in reply.agents do if agent.instance_id == instance_id do return false
    return true
}
