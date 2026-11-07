#+build !windows
#+feature dynamic-literals
package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import vault "odin_test:lib/vault"

bridge_executor_test_doc :: proc(kind:string)->json.Object {
    if kind=="bootstrap" || kind=="child_request" || kind=="child_result" {
        v,_:=contracts.owner_content_document(#load("../contracts/fixtures/executor-child-v1.json",string))
        root,_:=v.(json.Object)
        field:="child" if kind=="child_request" else "bootstrap"
        if kind=="child_result" do field="child_result"
        o,_:=contracts.executor_parse(contracts.owner_string(root,field),kind)
        return o
    }
    v,_:=contracts.owner_content_document(#load("../contracts/fixtures/executor-v1.json",string));root,_:=v.(json.Object);items,_:=root["valid"].(json.Array)
    for item in items {row,_:=item.(json.Object);if contracts.owner_string(row,"kind")==kind {o,_:=contracts.executor_parse(contracts.owner_string(row,"raw"),kind);return o}}
    return nil
}
bridge_executor_test_set :: proc(o:json.Object,name,value:string) {m:=o;m[name]=json.String(value)}
bridge_executor_test_key :: proc(id,key_id:string,scalar:u8)->(ecdsa.Private_Key,contracts.Owner_Verified_Key) {
    private:ecdsa.Private_Key;bytes:[32]byte;bytes[31]=scalar
    _=ecdsa.private_key_set_bytes(&private,.SECP256R1,bytes[:]);pub:[65]byte;ecdsa.private_key_public_bytes(&private,pub[:])
    return private,contracts.Owner_Verified_Key{"account",id,key_id,vault.hex_encode_lower(pub[:],context.temp_allocator),"bridge",true,false}
}
bridge_executor_test_sign :: proc(o:json.Object,kind:string,private:^ecdsa.Private_Key)->string {
    canonical,_:=contracts.executor_canonical(kind,o);sig,_:=vault.sign_p256(private,transmute([]byte)canonical)
    m:=o;m["signature"]=json.String(vault.hex_encode_lower(sig.sig[:],context.temp_allocator))
    return executor.encode(m)
}
bridge_executor_test_clock :: proc(ctx:rawptr)->i64 {return ((^i64)(ctx))^}
bridge_executor_test_owner :: proc(ctx:rawptr,_:executor.Intent)->executor.Current_Owner_Fence {return ((^executor.Current_Owner_Fence)(ctx))^}

@(test)
bridge_executor_real_daemon_ledger_dispatch_and_stale_stop :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    binary:=os.get_env("HEIMDALL_EXECUTOR_TEST_PTY",context.temp_allocator)
    if binary=="" {
        when #config(EXECUTOR_TEST_REQUIRED,false) {
            testing.fail_now(t,"HEIMDALL_EXECUTOR_TEST_PTY must name the built real daemon")
        } else {
            fmt.eprintln("[skip] real executor test requires HEIMDALL_EXECUTOR_TEST_PTY; select with -define:EXECUTOR_TEST_REQUIRED=true")
            return
        }
    }
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    suffix:=fmt.tprintf("%d",time.to_unix_nanoseconds(time.now()))
    socket:=fmt.tprintf("/tmp/ham-executor-%s.sock",suffix)
    swap:=pty_host_test_install_socket(socket);defer pty_host_test_restore_socket(swap)
    process,err:=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",socket,"daemon"}})
    if !testing.expect(t,err==nil) do return
    process_live:=true
    defer {
        frame:=pty_host_frame([]byte{0x37});reply,ok:=pty_host_request(socket,frame);delete(frame)
        if ok do pty_host_reply_delete(reply)
        if process_live {_=os.process_kill(process);_,_=os.process_wait(process)};_=os.remove(socket)
    }
    ready:=false
    for _ in 0..<100 {if bridge_pty_host_ping(socket) {ready=true;break};time.sleep(10*time.Millisecond)}
    if !testing.expect(t,ready,"real daemon must be available") do return
    path:=fmt.tprintf("%s/.cache/heimdall-tests/executor-live-%s.sqlite",os.get_env("HOME",context.temp_allocator),suffix)
    s:executor.Store
    if !testing.expect(t,executor.open(&s,path,"account","executor","operator")) do return
    defer {
        executor.close(&s)
        for ext in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,ext))
    }
    host_private,host:=bridge_executor_test_key("executor","operator",1);defer ecdsa.private_key_clear(&host_private)
    owner_private,owner:=bridge_executor_test_key("owner1","owner1",2);defer ecdsa.private_key_clear(&owner_private)
    base:=bridge_runtime_now_ms()-1000
    policy:=bridge_executor_test_doc("policy")
    testing.expect_value(t,executor.install_policy(&s,bridge_executor_test_sign(policy,"policy",&host_private),host,1000).code,"ok")
    p:=bridge_executor_test_doc("prepare")
    bridge_executor_test_set(p,"prepare_until_ms",fmt.tprintf("%d",base+3000))
    bridge_executor_test_set(p,"request_expires_ms",fmt.tprintf("%d",base+2000))
    bridge_executor_test_set(p,"hard_ms",fmt.tprintf("%d",base+10000))
    resources:=executor.Resolved_Resources{contracts.owner_string(p,"directory_key"),"default","instance","1"}
    testing.expect_value(t,executor.prepare(&s,bridge_executor_test_sign(p,"prepare",&owner_private),owner,base+1000,resources).code,"ok")
    digest,_:=contracts.executor_digest("prepare",p)
    a:=bridge_executor_test_doc("action");bridge_executor_test_set(a,"prepare_digest",digest)
    for pair in ([3][2]string{{"expires_ms",fmt.tprintf("%d",base+5000)},{"request_expires_ms",fmt.tprintf("%d",base+2000)},{"hard_ms",fmt.tprintf("%d",base+10000)}}) do bridge_executor_test_set(a,pair[0],pair[1])
    proof:=executor.Current_Owner_Fence{true,digest,1,1}
    testing.expect_value(t,executor.action(&s,bridge_executor_test_sign(a,"action",&owner_private),owner,base+1100,proof).code,"ok")
    intent,claimed:=executor.take_intent(&s,base+1200)
    if !testing.expect(t,claimed) do return
    req:=Pty_Host_Spawn_Request{instance="instance",argv=[]string{"sh"},rows=24,cols=80,has_timeout_seconds=true,timeout_seconds=3}
    io_now:=base+1200
    denied:=proof;denied.current=false
    delivered,reason:=bridge_executor_dispatch(&s,intent,base+1200,socket,req,&denied,bridge_executor_test_owner,&io_now,bridge_executor_test_clock)
    testing.expect(t,!delivered && reason=="owner_fence_not_current")
    old_binary:=os.get_env("HEIMDALL_EXECUTOR_OLD_PTY",context.temp_allocator)
    if old_binary!="" {
        old_socket:=fmt.tprintf("/tmp/ham-executor-old-%s.sock",suffix)
        old_swap:=pty_host_test_install_socket(old_socket);defer pty_host_test_restore_socket(old_swap)
        old_process,old_error:=os.process_start(os.Process_Desc{command=[]string{old_binary,"--socket",old_socket,"daemon"}})
        if !testing.expect(t,old_error==nil) do return
        defer {_=os.process_kill(old_process);_,_=os.process_wait(old_process);_=os.remove(old_socket)}
        old_ready:=false
        for _ in 0..<100 {if bridge_pty_host_ping(old_socket) {old_ready=true;break};time.sleep(10*time.Millisecond)}
        if !testing.expect(t,old_ready) do return
        refused,old_reason:=bridge_executor_dispatch(&s,intent,base+1200,old_socket,req,&proof,bridge_executor_test_owner,&io_now,bridge_executor_test_clock)
        testing.expect(t,!refused && old_reason=="executor_unsupported","an old daemon must be refused before Spawn")
        roster,listed:=bridge_pty_host_list(old_socket)
        testing.expect(t,listed && len(roster.agents)==0,"unsupported daemon did not receive a fallback launch")
        pty_host_reply_delete(roster)
    } else {fmt.eprintln("[skip] old-daemon compatibility phase requires HEIMDALL_EXECUTOR_OLD_PTY")}
    // Commit first dispatch and create the real child, but lose its reply
    // before the local observation commits. Recovery has no Spawn or nonce.
    testing.expect(t,executor.begin_dispatch(&s,intent,base+1200))
    lost_req:=req
    lost_req.env=[][2]string{{"HEIMDALL_EXECUTOR_LAUNCH_KEY",intent.launch_key},{"HEIMDALL_EXECUTOR_DEADLINE_MS",fmt.tprintf("%d",base+5000)}}
    _,_=bridge_pty_host_spawn(socket,lost_req)
    original_pid,original_known:=bridge_pty_host_executor_query(socket,intent.instance,intent.launch_key)
    if !testing.expect(t,original_known && original_pid>0) do return
    delivered,reason=bridge_executor_dispatch(&s,intent,base+1200,socket,{},nil,nil,&io_now,bridge_executor_test_clock)
    if !testing.expect(t,delivered && reason=="child_present") do return
    pid,known:=bridge_pty_host_executor_query(socket,"instance",intent.launch_key)
    testing.expect(t,known && pid>0)
    testing.expect(t,pid==original_pid,"query-only recovery preserves the original physical child")
    testing.expect(t,!bridge_pty_host_close(socket,"instance"),"unfenced stop cannot close resource-fenced child")
    testing.expect(t,executor.expire(&s,base+6000))
    stop,stopping:=executor.take_intent(&s,base+6000);testing.expect(t,stopping && stop.kind=="stop")
    // Simulate executor runtime death with a committed uncertain safety stop
    // while the real daemon retains its exact child. No launch is reissued.
    executor.close(&s)
    if !testing.expect(t,executor.open(&s,path,"account","executor","operator")) do return
    adopted:executor.Intent;adopted,stopping=executor.take_intent(&s,base+6000)
    testing.expect(t,stopping && adopted.kind=="stop" && adopted.incarnation==2 && adopted.launch_key==stop.launch_key)
    io_now=base+6000
    delivered,reason=bridge_executor_dispatch(&s,stop,base+6000,socket,{},nil,nil,&io_now,bridge_executor_test_clock)
    testing.expect(t,!delivered && reason=="stale_intent")
    delivered,reason=bridge_executor_dispatch(&s,adopted,base+6000,socket,{},nil,nil,&io_now,bridge_executor_test_clock)
    testing.expect(t,delivered && reason=="child_absent")
    testing.expect(t,executor.complete_recovery(&s,base+6000))
    p2:=bridge_executor_test_doc("prepare");bridge_executor_test_set(p2,"executor_incarnation","2")
    for pair in ([6][2]string{{"operation_id","warm_prepare"},{"reservation_id","warm"},{"purpose","warm"},{"prepare_until_ms","8000"},{"request_expires_ms","7000"},{"grant_generation","2"}}) do bridge_executor_test_set(p2,pair[0],pair[1])
    bridge_executor_test_set(p2,"prepare_until_ms",fmt.tprintf("%d",base+8000))
    bridge_executor_test_set(p2,"request_expires_ms",fmt.tprintf("%d",base+7000))
    bridge_executor_test_set(p2,"hard_ms",fmt.tprintf("%d",base+10000))
    testing.expect_value(t,executor.prepare(&s,bridge_executor_test_sign(p2,"prepare",&owner_private),owner,base+6000,resources).code,"ok")
    digest2,_:=contracts.executor_digest("prepare",p2)
    a2:=bridge_executor_test_doc("action");bridge_executor_test_set(a2,"executor_incarnation","2")
    for pair in ([6][2]string{{"operation_id","warm_activate"},{"reservation_id","warm"},{"prepare_digest",digest2},{"expires_ms","9000"},{"request_expires_ms","7000"},{"grant_generation","2"}}) do bridge_executor_test_set(a2,pair[0],pair[1])
    for pair in ([4][2]string{{"owner_commit_seq","2"},{"expires_ms",fmt.tprintf("%d",base+9000)},{"request_expires_ms",fmt.tprintf("%d",base+7000)},{"hard_ms",fmt.tprintf("%d",base+10000)}}) do bridge_executor_test_set(a2,pair[0],pair[1])
    proof2:=executor.Current_Owner_Fence{true,digest2,1,2}
    testing.expect_value(t,executor.action(&s,bridge_executor_test_sign(a2,"action",&owner_private),owner,base+6100,proof2).code,"ok")
    warm,warmed:=executor.take_intent(&s,base+6200);testing.expect(t,warmed)
    io_now=base+6200
    req.timeout_seconds=2
    delivered,reason=bridge_executor_dispatch(&s,warm,base+6200,socket,req,&proof2,bridge_executor_test_owner,&io_now,bridge_executor_test_clock)
    testing.expect(t,delivered && reason=="child_present")
    testing.expect(t,!bridge_pty_host_executor_close(socket,"instance",intent.launch_key),"old exact stop cannot kill replacement")
    new_pid,alive:=bridge_pty_host_executor_query(socket,"instance",warm.launch_key)
    testing.expect(t,alive && new_pid>0 && new_pid!=pid)
    testing.expect(t,!executor.observe_child(&s,"warm",executor.Child_Observation{"instance",intent.launch_key,s.incarnation,false}))
    testing.expect(t,executor.expire(&s,base+9000))
    stop2,_:=executor.take_intent(&s,base+9000)
    io_now=base+9000
    delivered,reason=bridge_executor_dispatch(&s,stop2,base+9000,socket,{},nil,nil,&io_now,bridge_executor_test_clock)
    testing.expect(t,delivered && reason=="child_absent")
    rows,ok:=executor.query(s.db,"SELECT count(*) FROM executor_reservations WHERE state!='released'")
    testing.expect(t,ok && rows[0][0]=="0")
    // Real daemon loss must not turn an unknown child into free capacity.
    p3:=bridge_executor_test_doc("prepare");bridge_executor_test_set(p3,"executor_incarnation","2")
    for pair in ([6][2]string{{"operation_id","crash_prepare"},{"reservation_id","crash"},{"purpose","manual"},{"prepare_until_ms",fmt.tprintf("%d",base+11000)},{"request_expires_ms",fmt.tprintf("%d",base+10000)},{"hard_ms",fmt.tprintf("%d",base+20000)}}) do bridge_executor_test_set(p3,pair[0],pair[1])
    testing.expect_value(t,executor.prepare(&s,bridge_executor_test_sign(p3,"prepare",&owner_private),owner,base+9000,resources).code,"ok")
    digest3,_:=contracts.executor_digest("prepare",p3)
    a3:=bridge_executor_test_doc("action");bridge_executor_test_set(a3,"executor_incarnation","2")
    for pair in ([7][2]string{{"operation_id","crash_activate"},{"reservation_id","crash"},{"prepare_digest",digest3},{"expires_ms",fmt.tprintf("%d",base+12000)},{"request_expires_ms",fmt.tprintf("%d",base+10000)},{"hard_ms",fmt.tprintf("%d",base+20000)},{"owner_commit_seq","3"}}) do bridge_executor_test_set(a3,pair[0],pair[1])
    proof3:=executor.Current_Owner_Fence{true,digest3,1,3}
    testing.expect_value(t,executor.action(&s,bridge_executor_test_sign(a3,"action",&owner_private),owner,base+9100,proof3).code,"ok")
    crash,_:=executor.take_intent(&s,base+9200);io_now=base+9200
    delivered,reason=bridge_executor_dispatch(&s,crash,base+9200,socket,req,&proof3,bridge_executor_test_owner,&io_now,bridge_executor_test_clock)
    if !testing.expect(t,delivered && reason=="child_present") do return
    crash_pid,present:=bridge_pty_host_executor_query(socket,"instance",crash.launch_key)
    if !testing.expect(t,present && crash_pid>0) do return
    process_live=false
    _=os.process_kill(process);_,_=os.process_wait(process)
    // This helper only kills a verified own session leader/group; the child
    // also has the enforced two-second physical deadline.
    bridge_shell_test_kill_pid(int(crash_pid))
    _=os.remove(socket)
    process,err=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",socket,"daemon"}})
    process_live=err==nil
    if !testing.expect(t,process_live) do return
    ready=false
    for _ in 0..<100 {if bridge_pty_host_ping(socket) {ready=true;break};time.sleep(10*time.Millisecond)}
    if !testing.expect(t,ready) do return
    _,known_after_loss:=bridge_pty_host_executor_query(socket,"instance",crash.launch_key)
    testing.expect(t,!known_after_loss,"new daemon cannot attest old key absence")
    testing.expect(t,executor.expire(&s,base+12000))
    crash_stop,_:=executor.take_intent(&s,base+12000);io_now=base+12000
    delivered,reason=bridge_executor_dispatch(&s,crash_stop,base+12000,socket,{},nil,nil,&io_now,bridge_executor_test_clock)
    testing.expect(t,!delivered && reason=="executor_uncertain")
    rows,ok=executor.query(s.db,"SELECT count(*) FROM executor_reservations WHERE state!='released'")
    testing.expect(t,ok && rows[0][0]=="1","daemon loss never silently frees unknown resources")
}

Bridge_Executor_Late_Proof :: struct {proof:executor.Current_Owner_Fence,clock:^i64,later:i64}
bridge_executor_test_late_owner :: proc(ctx:rawptr,_:executor.Intent)->executor.Current_Owner_Fence {
    value:=(^Bridge_Executor_Late_Proof)(ctx)
    value.clock^=value.later
    return value.proof
}
@(test)
bridge_executor_expiry_during_owner_check_and_clock_regression_fail_before_io :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    path:=fmt.tprintf("%s/.cache/heimdall-tests/executor-late-%d.sqlite",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    s:executor.Store
    if !testing.expect(t,executor.open(&s,path,"account","executor","operator")) do return
    defer {
        executor.close(&s)
        for ext in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,ext))
    }
    host_private,host:=bridge_executor_test_key("executor","operator",1);defer ecdsa.private_key_clear(&host_private)
    owner_private,owner:=bridge_executor_test_key("owner1","owner1",2);defer ecdsa.private_key_clear(&owner_private)
    testing.expect_value(t,executor.install_policy(&s,bridge_executor_test_sign(bridge_executor_test_doc("policy"),"policy",&host_private),host,1000).code,"ok")
    p:=bridge_executor_test_doc("prepare");digest,_:=contracts.executor_digest("prepare",p)
    resources:=executor.Resolved_Resources{contracts.owner_string(p,"directory_key"),"default","instance","1"}
    testing.expect_value(t,executor.prepare(&s,bridge_executor_test_sign(p,"prepare",&owner_private),owner,1000,resources).code,"ok")
    a:=bridge_executor_test_doc("action");bridge_executor_test_set(a,"prepare_digest",digest)
    proof:=executor.Current_Owner_Fence{true,digest,1,1}
    testing.expect_value(t,executor.action(&s,bridge_executor_test_sign(a,"action",&owner_private),owner,1100,proof).code,"ok")
    intent,ok:=executor.take_intent(&s,1200);testing.expect(t,ok)
    now:i64=1200;late:=Bridge_Executor_Late_Proof{proof,&now,5000}
    req:=Pty_Host_Spawn_Request{instance="instance",argv=[]string{"sh"},has_timeout_seconds=true,timeout_seconds=3}
    sent,reason:=bridge_executor_dispatch(&s,intent,1200,"/not/contacted",req,&late,bridge_executor_test_late_owner,&now,bridge_executor_test_clock)
    testing.expect(t,!sent && reason=="stale_intent","owner check cannot preserve an already elapsed admission window")
    rows,read:=executor.query(s.db,"SELECT state,(SELECT clock_high_ms FROM executor_runtime) FROM executor_reservations")
    testing.expect(t,read && rows[0][0]=="stopping" && rows[0][1]=="5000")
    now=1200
    sent,reason=bridge_executor_dispatch(&s,intent,1200,"/not/contacted",req,&proof,bridge_executor_test_owner,&now,bridge_executor_test_clock)
    testing.expect(t,!sent && reason=="clock_or_storage_error")
    rows,read=executor.query(s.db,"SELECT recovery_state FROM executor_runtime")
    testing.expect(t,read && rows[0][0]=="clock_uncertain")
}

@(test)
bridge_executor_physical_fence_rechecks_wall_and_monotonic_expiry :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    now:=bridge_executor_physical_clock(nil)
    q:=bridge_executor_test_doc("fence_request")
    bridge_executor_test_set(q,"issued_ms",fmt.tprintf("%d",now))
    bridge_executor_test_set(q,"request_expires_ms",fmt.tprintf("%d",now+1000))
    pending:=executor.Fence_Challenge{request=executor.encode(q),consumed=true,started=time.tick_now()}
    physical:=Executor_Physical_Fence{executor.Current_Owner_Fence{true,"digest",1,1},&pending}
    testing.expect(t,bridge_executor_physical_fence(&physical,{}).current)
    pending.consumed=false
    testing.expect(t,!bridge_executor_physical_fence(&physical,{}).current,"unverified pending exchange is not a proof")
    pending.consumed=true;pending.started=time.tick_add(time.tick_now(),-2*time.Second)
    testing.expect(t,!bridge_executor_physical_fence(&physical,{}).current,"elapsed monotonic nonce lifetime fails closed")
    pending.started=time.tick_now()
    bridge_executor_test_set(q,"request_expires_ms",fmt.tprintf("%d",now))
    pending.request=executor.encode(q)
    testing.expect(t,!bridge_executor_physical_fence(&physical,{}).current,"wall expiry fails closed")
    bridge_executor_test_set(q,"issued_ms",fmt.tprintf("%d",now+1000))
    bridge_executor_test_set(q,"request_expires_ms",fmt.tprintf("%d",now+2000))
    pending.request=executor.encode(q)
    testing.expect(t,!bridge_executor_physical_fence(&physical,{}).current,"wall clock before challenge issue fails closed")
}
