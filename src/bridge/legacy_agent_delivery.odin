package main

import "core:sync"
import executor "odin_test:lib/executor_local"

Bridge_Legacy_Agent_Delivery_Kind :: enum { Message, Task_Nudge, Notice, Resize }
Bridge_Legacy_Agent_Delivery :: struct {
    kind:Bridge_Legacy_Agent_Delivery_Kind,
    instance,sender,task,role,text,title:string,
    interrupt:bool,
    rows,cols:u16,
}

// Higher-level queued/rollover producer only. The low-level PTY transport stays
// unchanged for callers already holding these gates. refused forbids replacing
// an uncertain child via a wake/restart fallback. Reader binary input is not
// covered here and remains an explicit migration completeness gap.
bridge_legacy_agent_delivery :: proc(input:Bridge_Legacy_Agent_Delivery,injected:^executor.Store=nil,injected_socket:string="")->(delivered,refused:bool) {
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_legacy_physical_mutex);defer sync.mutex_unlock(&bridge_legacy_physical_mutex)
    store,available:=bridge_legacy_dispatch_store_locked(injected)
    if !available do return false,true
    socket:=injected_socket
    owned_socket:=""
    if socket=="" {owned_socket=pty_host_socket_path();socket=owned_socket}
    defer delete(owned_socket)
    if store!=nil {
        inst,exists:=bridge_runtime_instance_snapshot(input.instance)
        if !exists || !bridge_legacy_startup_input_allowed_locked(store,inst,socket) do return false,true
    } else if injected_socket=="" {
        ok:bool
        socket,ok=bridge_pty_host_ensure_daemon()
        if !ok do return false,false
    }
    switch input.kind {
    case .Message:
        return bridge_pty_host_deliver_message(socket,input.instance,input.sender),false
    case .Task_Nudge:
        return bridge_pty_host_deliver_task_nudge(socket,input.instance,input.task,input.role,input.text,input.title,input.interrupt),false
    case .Notice:
        return bridge_pty_host_deliver_notice(socket,input.instance,input.text),false
    case .Resize:
        return bridge_pty_host_deliver_resize_socket(socket,input.instance,input.rows,input.cols),false
    }
    return false,true
}
