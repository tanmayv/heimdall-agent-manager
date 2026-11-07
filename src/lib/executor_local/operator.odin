package executor_local

import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"

// A transport credential is insufficient. Readback requires an exact signed
// record from this journal's pinned host operator, just like installation.
operator_read :: proc(s:^Store,kind,raw:string,key:contracts.Owner_Verified_Key)->Result {
    if kind!="policy" && kind!="directory" do return fail("malformed")
    o,valid:=contracts.executor_parse(raw,kind)
    if !valid || !scope(s,o) || key.key_id!=s.operator_key || !contracts.executor_verify(kind,o,key) do return fail("invalid_scope")
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return fail("storage_error")
    rows:[dynamic][]string
    read:bool
    if kind=="policy" {
        rows,read=query(s.db,"SELECT revision,document FROM executor_policies ORDER BY revision DESC LIMIT 1")
    } else {
        rows,read=query(s.db,"SELECT revision,document FROM executor_directories WHERE directory_id=? ORDER BY revision DESC LIMIT 1",field(o,"directory_id"))
    }
    if !read do return fail("storage_error")
    if len(rows)!=1 do return fail("configuration_not_found")
    budget,checked:=query(s.db,"SELECT device_capacity,(SELECT count(*) FROM executor_live_resources) FROM executor_runtime")
    if !checked || len(budget)!=1 do return fail("storage_error")
    return Result{code="ok",body=encode(struct{kind,revision,document,device_capacity,live_resources,executor_incarnation:string}{
        kind,rows[0][0],rows[0][1],budget[0][0],budget[0][1],fmt.tprintf("%d",s.incarnation)})}
}
