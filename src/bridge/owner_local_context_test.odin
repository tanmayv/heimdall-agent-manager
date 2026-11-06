#+feature dynamic-literals
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import owner "odin_test:lib/owner_local"

@(test)
test_owner_context_atomic_delivery_and_explicit_budget_failure :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    dir:=fmt.tprintf("%s/.cache/heimdall-tests/context-delivery-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(dir)==nil);defer _=os.remove_all(dir)
    command:=owner.doc(map[string]string{"chain_id"="chain","task_id"="task","lease_id"="exact_lease","instance_id"="exact_child"})
    brief:="{\"goal\":\"保留 exact current requirements\",\"acceptance\":[\"current criterion\"]}"
    summary:=strings.repeat("history giant line ",10000,context.temp_allocator)
    result:=owner.doc(map[string]string{"requirements_revision"="7","acknowledged"="0","brief"=brief,"chain_summary"=summary,"context_provenance"="{\"source_seq\":\"100\",\"source_digest\":\"digest\"}"})
    testing.expect(t,bridge_owner_materialize_context(dir,command,owner.encode(result)))
    path:=fmt.tprintf("%s/TASK.md",dir)
    first,read:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,read==nil && len(first)<=BRIDGE_TASK_MD_MAX_BYTES)
    testing.expect(t,strings.contains(string(first),brief) && strings.contains(string(first),"exact_lease") && strings.contains(string(first),"Acknowledged: 0"))
    testing.expect(t,!bridge_owner_materialize_context(dir,command,"{}"))
    result=owner.doc(map[string]string{"requirements_revision"="7","acknowledged"="0","brief"=strings.repeat("x",40000,context.temp_allocator),"chain_summary"="small","context_provenance"="snapshot"})
    testing.expect(t,!bridge_owner_materialize_context(dir,command,owner.encode(result)),"essential content cannot bypass actual file budget")
    after,_:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,string(after)==string(first),"failed delivery leaves the last complete file intact")
}
