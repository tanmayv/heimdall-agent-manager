#+build !windows
#+feature dynamic-literals
package main
import "core:fmt"
import "core:encoding/json"
import "core:os"
import "core:testing"
import "core:time"
import "core:strings"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import executor "odin_test:lib/executor_local"

 // Real signed owner cancellation -> durable query/ordinary stop -> actual
 // executor daemon -> correlated signed absence. No provider support claim.
native_owner_remote_stop :: proc(t:^testing.T,p:^Native_Owner_Proof,wire:Executor_Exchange_Wire,
    activation:owner.Intent_Claim,content:json.Object,owner_path:string) {
    binary:=bridge_env_get("HEIMDALL_EXECUTOR_TEST_PTY",context.temp_allocator)
    if binary=="" {
        when #config(EXECUTOR_TEST_REQUIRED,false) {testing.fail_now(t,"actual stop proof requires daemon")}
        else {fmt.eprintln("[skip] actual stop proof requires daemon")}
        return
    }
    suffix:=fmt.tprintf("%d",time.to_unix_nanoseconds(time.now()))
    socket:=fmt.tprintf("/tmp/ham-remote-stop-%s.sock",suffix)
    daemon,err:=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",socket,"daemon"}})
    if !testing.expect(t,err==nil) do return
    defer {_=os.process_kill(daemon);_,_=os.process_wait(daemon);_=os.remove(socket);_=os.remove(fmt.tprintf("%s.lock",socket))}
    ready:=false
    for _ in 0..<100 {if bridge_pty_host_ping(socket) {ready=true;break};time.sleep(10*time.Millisecond)}
    if !testing.expect(t,ready) do return
    swap:=pty_host_test_install_socket(socket);defer pty_host_test_restore_socket(swap)
    old_ctl,had_ctl:=bridge_env_lookup("HEIMDALL_HAM_CTL_BIN",context.temp_allocator)
    bridge_test_env_set("HEIMDALL_HAM_CTL_BIN","/bin/sh")
    defer {if had_ctl {bridge_test_env_set("HEIMDALL_HAM_CTL_BIN",old_ctl)} else {bridge_test_env_unset("HEIMDALL_HAM_CTL_BIN")}}
    probe:=Executor_Test_Prepare{fmt.tprintf("%s/remote-stop-child",p.work),0}
    io:=Executor_Launch_IO{&probe,bridge_executor_test_physical_prepare,socket}
    physical:=Native_Owner_Physical{owner=p,socket=socket}
    a,_:=contracts.executor_parse(activation.payload,"action")
    _,code:=bridge_executor_test_exchange(t,wire,a,"action",p.owner_private,p.kr,p.host,"remote_stop_activate",
        bootstrap=contracts.owner_string(content,"bootstrap"),body=contracts.owner_string(content,"body"),launch_io=io,
        exchange_ctx=&physical,exchange_fn=native_owner_fence_exchange,owner_intent=activation.id)
    if !testing.expect_value(t,code,"ok") do return
    b,_:=contracts.executor_parse(contracts.owner_string(content,"bootstrap"),"bootstrap")
    instance,key:=contracts.owner_string(b,"instance_id"),contracts.owner_string(b,"launch_key")
    pid,known:=bridge_pty_host_executor_query(socket,instance,key)
    if !testing.expect(t,known && pid>0) do return
    defer {_=bridge_pty_host_executor_close(socket,instance,key);bridge_shell_test_kill_pid(int(pid))}
    rows,_:=owner.query(p.store.db,"SELECT revision FROM tasks WHERE task_id=?",p.task)
    payload:=executor.encode(native_owner_document([][2]string{{"body_cipher",native_owner_cipher(p,"Cancel exact remote shell")}}))
    if !testing.expect_value(t,native_owner_call(p,"task.cancel","remote_stop_cancel",p.task,payload,rows[0][0]).code,"ok") do return
    now:=bridge_executor_physical_clock(nil)
    claims,claimed:=owner.intent_claim_due(&p.store,now,20,.Executor)
    if !testing.expect(t,claimed && len(claims)==1 && owner.execution_stop_kind(claims[0].kind)) do return
    c:=claims[0]
    // A generic owner consumer must reject this remote child before consulting
    // even a live, empty owner daemon. No wrong-device absence can settle it.
    original,parsed:=contracts.owner_content_document(c.payload);original_object,_:=original.(json.Object)
    if !testing.expect(t,parsed) do return
    local_socket_path:=fmt.tprintf("/tmp/ham-owner-empty-%s.sock",suffix)
    empty,empty_error:=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",local_socket_path,"daemon"}})
    if !testing.expect(t,empty_error==nil) do return
    defer {_=os.process_kill(empty);_,_=os.process_wait(empty);_=os.remove(local_socket_path);_=os.remove(fmt.tprintf("%s.lock",local_socket_path))}
    empty_ready:=false
    for _ in 0..<100 {if bridge_pty_host_ping(local_socket_path) {empty_ready=true;break};time.sleep(10*time.Millisecond)}
    testing.expect(t,empty_ready)
    absent,absence_code,_:=bridge_owner_control_notice(&p.store,owner.Intent_Claim{kind="stop",fence=contracts.owner_string(original_object,"child")})
    testing.expect(t,!absent && absence_code=="remote_child_requires_executor","owner-local absence cannot settle a remote stop")
    sign:=owner.Signer{p.owner_private,native_owner_sign}
    first:=owner.execution_stop_request(&p.store,c,p.key,now,sign)
    if !testing.expect_value(t,first.code,"ok") do return
    q,_:=contracts.executor_parse(first.body,"action")
    // Restart the serving executor while retaining the actual daemon/child.
    executor.close(&bridge_executor_store)
    testing.expect(t,bridge_executor_open(p.host.account_id,p.host.key_id))
    query_receipt,query_code:=bridge_executor_test_exchange(t,wire,q,"action",p.owner_private,p.kr,p.host,"remote_stop_query_after_restart")
    if !testing.expect_value(t,query_code,"ok") do return
    repeated:=owner.execution_stop_request(&p.store,c,p.key,bridge_executor_physical_clock(nil),sign)
    testing.expect(t,repeated.body==first.body,"lost query reply retries exact immutable operation")
    if !testing.expect_value(t,owner.execution_stop_accept(&p.store,c,first.body,executor.encode(query_receipt),p.host,bridge_executor_physical_clock(nil)).code,"accepted") do return
    stop:=owner.execution_stop_request(&p.store,c,p.key,bridge_executor_physical_clock(nil),sign)
    if !testing.expect_value(t,stop.code,"ok") do return
    request,_:=contracts.executor_parse(stop.body,"action")
    testing.expect(t,contracts.executor_number(request,"executor_incarnation")==bridge_executor_store.incarnation)
    // Unreachable physical endpoint: signed stopping is acceptance, not absence.
    disconnected:=Executor_Launch_IO{socket=fmt.tprintf("%s.disconnected",socket)}
    accepted,stop_code:=bridge_executor_test_exchange(t,wire,request,"action",p.owner_private,p.kr,p.host,"remote_stop_disconnected",launch_io=disconnected)
    if !testing.expect_value(t,stop_code,"ok") do return
    testing.expect_value(t,contracts.owner_string(accepted,"state"),"stopping")
    if !testing.expect_value(t,owner.execution_stop_accept(&p.store,c,stop.body,executor.encode(accepted),p.host,bridge_executor_physical_clock(nil)).code,"accepted") do return
    charge,_:=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources")
    testing.expect_value(t,charge[0][0],"1")
    still,live:=bridge_pty_host_executor_query(socket,instance,key)
    testing.expect(t,live && still==pid)
    // Owner restart preserves immutable steps and terminal retirement; it must
    // re-query current serving metadata rather than revive the retired lease.
    owner.close(&p.store)
    if !testing.expect(t,owner.open(&p.store,owner_path,p.key.account_id,p.key.principal_id,p.key.key_id)) do return
    claims,claimed=owner.intent_claim_due(&p.store,bridge_executor_physical_clock(nil),20,.Executor)
    stop_found:=false
    for claim in claims do if owner.execution_stop_kind(claim.kind) {c=claim;stop_found=true}
    if !testing.expect(t,claimed && stop_found) do return
    next:=owner.execution_stop_request(&p.store,c,p.key,bridge_executor_physical_clock(nil),sign)
    q,_=contracts.executor_parse(next.body,"action")
    testing.expect_value(t,contracts.owner_string(q,"method"),"query")
    receipt,read_code:=bridge_executor_test_exchange(t,wire,q,"action",p.owner_private,p.kr,p.host,"remote_stop_requery")
    if !testing.expect_value(t,read_code,"ok") do return
    if !testing.expect_value(t,owner.execution_stop_accept(&p.store,c,next.body,executor.encode(receipt),p.host,bridge_executor_physical_clock(nil)).code,"accepted") do return
    next=owner.execution_stop_request(&p.store,c,p.key,bridge_executor_physical_clock(nil),sign)
    request,_=contracts.executor_parse(next.body,"action")
    receipt,read_code=bridge_executor_test_exchange(t,wire,request,"action",p.owner_private,p.kr,p.host,"remote_stop_reconnect",launch_io=io)
    if !testing.expect_value(t,read_code,"ok") do return
    testing.expect_value(t,contracts.owner_string(receipt,"state"),"released")
    duplicate:=owner.execution_stop_request(&p.store,c,p.key,bridge_executor_physical_clock(nil),sign)
    testing.expect(t,duplicate.body==next.body,"lost stop reply keeps exact request bytes")
    receipt,read_code=bridge_executor_test_exchange(t,wire,request,"action",p.owner_private,p.kr,p.host,"remote_stop_duplicate",launch_io=io)
    testing.expect_value(t,read_code,"ok")
    if !testing.expect_value(t,owner.execution_stop_accept(&p.store,c,next.body,executor.encode(receipt),p.host,bridge_executor_physical_clock(nil)).code,"released") do return
    testing.expect(t,owner.intent_result(&p.store,c,true,executor.encode(receipt),bridge_executor_physical_clock(nil)))
    charge,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources")
    testing.expect_value(t,charge[0][0],"0")
    stopped,observed:=bridge_pty_host_executor_query(socket,instance,key)
    testing.expect(t,observed && stopped==0)
    // A distinct test-only physical generation reuses the instance. Replay of
    // the old signed reservation stop must never close that replacement key.
    replacement_key:=strings.repeat("c",64,context.temp_allocator)
    replacement:=Pty_Host_Spawn_Request{instance=instance,argv=[]string{"sh"},rows=24,cols=80,
        env=[][2]string{{"HEIMDALL_EXECUTOR_LAUNCH_KEY",replacement_key},{"HEIMDALL_EXECUTOR_LOCAL_LAUNCH","1"}}}
    _,_=bridge_pty_host_spawn(socket,replacement)
    replacement_pid,replacement_known:=bridge_pty_host_executor_query(socket,instance,replacement_key)
    if !testing.expect(t,replacement_known && replacement_pid>0) do return
    defer {_=bridge_pty_host_executor_close(socket,instance,replacement_key);bridge_shell_test_kill_pid(int(replacement_pid))}
    _,read_code=bridge_executor_test_exchange(t,wire,request,"action",p.owner_private,p.kr,p.host,"remote_stop_stale_replacement",launch_io=io)
    testing.expect_value(t,read_code,"ok")
    same_pid,same_known:=bridge_pty_host_executor_query(socket,instance,replacement_key)
    testing.expect(t,same_known && same_pid==replacement_pid,"old remote stop never retargets a replacement")
    fmt.println("[remote-stop] signed original owner cancel -> durable query/stop -> executor/owner restart -> disconnected stopping retains charge -> exact released receipt PASS")
}
