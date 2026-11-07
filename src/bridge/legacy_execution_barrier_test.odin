package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import executor "odin_test:lib/executor_local"

bridge_legacy_test_store :: proc(t:^testing.T)->(^executor.Store,string) {
    path:=fmt.tprintf("%s/.cache/heimdall-tests/legacy-physical-%d.sqlite",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    s:=new(executor.Store,context.temp_allocator)
    if !testing.expect(t,executor.open(s,path,"account","executor","operator")) do testing.fail_now(t,"legacy physical journal")
    return s,path
}
bridge_legacy_test_close :: proc(s:^executor.Store,path:string) {
    executor.close(s)
    for ext in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,ext))
}
