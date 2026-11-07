package main

import "core:fmt"
import "core:strings"
import "core:sync"
import executor "odin_test:lib/executor_local"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

// Private native scheduler discriminator, intentionally absent from the Hub
// JSON command registry. The counter is a queue handle, never a source claim.
BRIDGE_DISPATCH_BINARY_INPUT_KIND :: "binary_pty_input"
bridge_dispatch_binary_input_counter:u64
bridge_command_binary_input_spec :: proc()->Bridge_Command_Spec {
    return {class=.Shell,priority=.Interactive,key_kind=.Shell,queued=true,timeout_ms=5000,cost_units=1}
}

bridge_command_dispatch_binary_input :: proc(conn:^ws.Connection,frame:[]byte,generation:i64)->bool {
    if len(frame)>BRIDGE_DISPATCH_COMMAND_BYTES_LIMIT do return false
    kind,_,target,_,valid:=contracts.pty_wire_decode_session_frame(frame)
    if !valid || kind!=contracts.PTY_WIRE_KIND_INPUT || target=="" do return false
    number:u64
    for {
        old:=sync.atomic_load(&bridge_dispatch_binary_input_counter)
        if old==0xffffffffffffffff do return false
        if _,changed:=sync.atomic_compare_exchange_strong(&bridge_dispatch_binary_input_counter,old,old+1);changed {
            number=old+1
            break
        }
    }
    id:=fmt.tprintf("bridge_binary_%d",number)
    key:=strings.concatenate({"shell:",target},context.temp_allocator)
    return bridge_command_dispatch_enqueue(conn,transmute(string)frame,BRIDGE_DISPATCH_BINARY_INPUT_KIND,id,
        bridge_command_binary_input_spec(),generation,native_binary=true,native_ordering_key=key)
}

// Worker-side physical boundary for binary and JSON terminal input. A shell can
// reach arbitrary shared resources, so unknown overlap refuses every installed
// barrier. Keep the physical gate through the write: a successful queue/start
// observation cannot authorize an input after a concurrent barrier installation.
bridge_legacy_shell_input :: proc(target,data:string,injected:^executor.Store=nil,injected_socket:string="")->(delivered,refused:bool) {
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
    if injected_socket!="" do return bridge_pty_host_deliver_shell_input(injected_socket,target,data),false
    return bridge_pty_host_deliver_shell_input(target,data),false
}
