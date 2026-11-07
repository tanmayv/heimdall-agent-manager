package main

import "core:sync"
import executor "odin_test:lib/executor_local"

Bridge_Legacy_Shell_Delivery_Kind :: enum { Input, Resize }
Bridge_Legacy_Shell_Delivery :: struct {
    kind:Bridge_Legacy_Shell_Delivery_Kind,
    target,data:string,
    rows,cols:u16,
}

// Worker-side physical boundary for terminal input and resize. A shell can
// reach arbitrary shared resources, so unknown overlap refuses every installed
// barrier. Keep the physical gate through the write: a successful queue/start
// observation cannot authorize an input after a concurrent barrier installation.
bridge_legacy_shell_delivery :: proc(input:Bridge_Legacy_Shell_Delivery,injected:^executor.Store=nil,injected_socket:string="")->(delivered,refused:bool) {
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_legacy_physical_mutex);defer sync.mutex_unlock(&bridge_legacy_physical_mutex)
    store,available:=bridge_legacy_dispatch_store_locked(injected)
    if !available do return false,true
    if store!=nil {
        sync.mutex_lock(&store.mutex)
        usable:=store.db!=nil && !store.unusable
        clear:=false
        if usable {
            rows,read:=executor.query(store.db,"SELECT 1 FROM executor_legacy_barriers LIMIT 1")
            clear=read && len(rows)==0
        }
        sync.mutex_unlock(&store.mutex)
        if !clear do return false,true
    }
    switch input.kind {
    case .Input:
        if injected_socket!="" do return bridge_pty_host_deliver_shell_input(injected_socket,input.target,input.data),false
        return bridge_pty_host_deliver_shell_input(input.target,input.data),false
    case .Resize:
        if injected_socket!="" do return bridge_pty_host_deliver_shell_resize(injected_socket,input.target,input.rows,input.cols),false
        return bridge_pty_host_deliver_shell_resize(input.target,input.rows,input.cols),false
    }
    return false,true
}

bridge_legacy_shell_input :: proc(target,data:string,injected:^executor.Store=nil,injected_socket:string="")->(delivered,refused:bool) {
    return bridge_legacy_shell_delivery({kind=.Input,target=target,data=data},injected,injected_socket)
}
