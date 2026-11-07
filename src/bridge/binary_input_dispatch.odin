package main

import "core:fmt"
import "core:strings"
import "core:sync"
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
