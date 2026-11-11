package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import owner "odin_test:lib/owner_local"

// T1 review: the `caller` block of the owner agent.task_chain.show reply and
// the reopen refusal text ham-ctl parses.
@(test)
test_owner_caller_view_and_reopen_refusal_message :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    path:=fmt.tprintf("%s/.cache/heimdall-tests/owner-t1-view-%d.sqlite",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    store:owner.Store
    if !testing.expect(t,owner.open(&store,path,"account","bridge","bridge_key")) do return
    defer {
        owner.close(&store)
        for suffix in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,suffix))
    }
    child:=owner.Child{"inst_c","epoch",strings.repeat("c",64),1,"agt_coord"}
    view:=bridge_owner_caller_view(&store,"chain",child)
    testing.expect_value(t,view["agent_id"].(json.String),"agt_coord")
    testing.expect_value(t,view["instance_id"].(json.String),"inst_c")
    testing.expect_value(t,bool(view["coordinator"].(json.Boolean)),false)
    testing.expect_value(t,bool(view["worker_fleet_row"].(json.Boolean)),false)
    msg:=bridge_owner_reopen_refusal_message("consumed by a started dependent (task second); create replacement work instead")
    testing.expect_value(t,msg,"task cannot be reopened: consumed by a started dependent (task second); create replacement work instead")
}
