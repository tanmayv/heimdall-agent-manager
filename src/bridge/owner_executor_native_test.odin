#+build !windows
#+feature dynamic-literals
package main

import "base:runtime"
import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core:sync"
import "core:thread"
import local_socket "odin_test:lib/local_socket"
import channel "odin_test:lib/executor_channel"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

Native_Owner_Proof :: struct {
    store:owner.Store,
    device,key,host:contracts.Owner_Verified_Key,
    device_private,owner_private:^ecdsa.Private_Key,
    kr:^vault.Vault_Keyring,
    directory:vault.Directory_Verification_Input,
    genesis,chain,task,work:string,
}
native_owner_sign :: proc(ctx:rawptr,kind:string,o:json.Object)->(string,bool) {
    canonical,ok:=contracts.executor_canonical(strings.trim_prefix(kind,"executor."),o)
    if !ok {canonical,ok=contracts.owner_canonical(kind,o)}
    if !ok do return "",false
    signature,signed:=vault.sign_p256((^ecdsa.Private_Key)(ctx),transmute([]byte)canonical)
    return vault.hex_encode_lower(signature.sig[:],context.temp_allocator),signed
}
native_owner_document :: proc(pairs:[][2]string)->json.Object {
    o:=make(json.Object,context.temp_allocator)
    for pair in pairs do o[pair[0]]=json.String(pair[1])
    return o
}
native_owner_cipher :: proc(p:^Native_Owner_Proof,text:string)->string {
    out,_:=vault.seal_string(text,p.kr,context.temp_allocator);return out
}
native_owner_call :: proc(p:^Native_Owner_Proof,method,operation,task,payload,revision:string)->owner.Result {
    now:=bridge_executor_physical_clock(nil)
    c:=native_owner_document([][2]string{
        {"protocol_version","1"},{"account_id",p.key.account_id},{"chain_id",p.chain},
        {"immutable_owner_bridge",p.key.principal_id},{"principal_id",p.device.principal_id},
        {"operation_id",operation},{"method",method},{"task_id",task},{"expected_revision",revision},
        {"request_expires_ms",fmt.tprintf("%d",now+300000)},{"payload_digest",contracts.owner_payload_digest(payload)},
        {"key_id",p.device.key_id},{"signature",strings.repeat("0",128,context.temp_allocator)}})
    signature,_:=native_owner_sign(p.device_private,"command",c);c["signature"]=json.String(signature)
    return owner.execute(&p.store,executor.encode(c),payload,p.genesis,p.device,p.key,p.directory.version,p.directory.head_hash,
        now,p.kr,{p.owner_private,native_owner_sign},remote_key=p.host)
}

// Every owner authority row in this proof is created by the real signed command,
// assignment/preparation/commit/bootstrap APIs. SQL is used only to inspect state.
bridge_executor_original_owner_native :: proc(t:^testing.T,directory:vault.Directory_Verification_Input,genesis:string,
    config,bundle:json.Object,device,key,host:contracts.Owner_Verified_Key,device_private,owner_private:^ecdsa.Private_Key,
    kr:^vault.Vault_Keyring,work:string,stop_only:=false) {
    p:=Native_Owner_Proof{device=device,key=key,host=host,device_private=device_private,owner_private=owner_private,
        kr=kr,directory=directory,genesis=genesis,work=work,chain=contracts.owner_string(config,"chain_id"),task=contracts.owner_string(config,"task_id")}
    path:=fmt.tprintf("%s/owner-native.sqlite",work)
    if !testing.expect(t,owner.open(&p.store,path,key.account_id,key.principal_id,key.key_id)) {return}
    defer owner.close(&p.store)
    if !testing.expect(t,owner.observe_directory(&p.store,directory.version,directory.head_hash)) {return}
    g,_:=contracts.owner_parse(genesis,"genesis");digest,_:=contracts.owner_digest("genesis",g)
    payload:=executor.encode(native_owner_document([][2]string{{"genesis_digest",digest},
        {"title_cipher",native_owner_cipher(&p,"Native owner proof")},{"description_cipher",native_owner_cipher(&p,"Private isolated proof")}}))
    if !testing.expect_value(t,native_owner_call(&p,"chain.create","owner_genesis","",payload,"0").code,"ok") {return}
    payload=executor.encode(native_owner_document([][2]string{{"title_cipher",native_owner_cipher(&p,"Native notification")},
        {"body_cipher",native_owner_cipher(&p,"One exact owner-held child")}}))
    if !testing.expect_value(t,native_owner_call(&p,"task.create","native_task",p.task,payload,"1").code,"ok") {return}
    policy:=contracts.Owner_Fleet_Policy{task_chain_id=p.chain,agent_id=contracts.owner_string(config,"agent_id"),capacity=1,
        provider_profile=contracts.owner_string(config,"provider_profile"),provider=contracts.owner_string(config,"provider"),
        model=contracts.owner_string(config,"model"),bridge_id=host.principal_id,roles_json=`["worker"]`}
    payload=executor.encode(native_owner_document([][2]string{{"body_cipher",native_owner_cipher(&p,executor.encode(policy))}}))
    if !testing.expect_value(t,native_owner_call(&p,"fleet.policy.set","native_policy","",payload,"2").code,"ok") {return}
    reservation:=executor.encode(native_owner_document([][2]string{{"configuration",contracts.owner_string(bundle,"configuration")},
        {"attestation",contracts.owner_string(bundle,"attestation")}}))
    payload=executor.encode(native_owner_document([][2]string{{"instance_id",contracts.owner_string(config,"instance_id")},
        {"configuration_revision",contracts.owner_string(config,"configuration_revision")},{"enabled","1"},{"body_cipher",native_owner_cipher(&p,reservation)}}))
    if !testing.expect_value(t,native_owner_call(&p,"fleet.reserve","native_reserve",p.task,payload,"1").code,"ok") {return}
    payload=executor.encode(native_owner_document([][2]string{{"requirements_revision","1"},
        {"body_cipher",native_owner_cipher(&p,`{"goal":"Exercise exact native owner delivery","acceptance":["No duplicate authority or submissions"]}`)}}))
    if !testing.expect_value(t,native_owner_call(&p,"requirements.edit","native_requirements",p.task,payload,"2").code,"ok") {return}
    now:=bridge_executor_physical_clock(nil)
    if !testing.expect_value(t,owner.execution_prepare_assignment(&p.store,p.chain,p.task,p.key,now,{p.owner_private,native_owner_sign}).code,"ok") {return}
    rows,read:=owner.query(p.store.db,"SELECT prepare_json FROM owner_execution_journal")
    if !testing.expect(t,read && len(rows)==1) {return}
    prepare,parsed:=contracts.executor_parse(rows[0][0],"prepare")
    if !testing.expect(t,parsed) {return}
    wire:=Executor_Exchange_Wire{"executor_exchange","",key.account_id,"",genesis,directory}
    receipt,code:=bridge_executor_test_exchange(t,wire,prepare,"prepare",owner_private,kr,host,"native_owner_prepare")
    if !testing.expect_value(t,code,"ok") {return}
    now=bridge_executor_physical_clock(nil)
    committed:=owner.execution_prepare_commit(&p.store,contracts.owner_string(prepare,"reservation_id"),executor.encode(receipt),key,host,now,{owner_private,native_owner_sign})
    if !testing.expect_value(t,committed.code,"ok") {return}
    claims,claimed:=owner.intent_claim_due(&p.store,now,20,.Executor)
    if !testing.expect(t,claimed && len(claims)==1 && claims[0].kind=="executor.activate") {return}
    activation:=claims[0]
    boot:=owner.execution_bootstrap(&p.store,activation,"Read TASK.md and act only on its original owner lease.","","[]",key,now,{owner_private,native_owner_sign})
    if !testing.expect_value(t,boot.code,"ok") {return}
    value,_:=contracts.owner_content_document(boot.body);content,_:=value.(json.Object)
    b,valid:=contracts.executor_parse(contracts.owner_string(content,"bootstrap"),"bootstrap")
    testing.expect(t,valid && contracts.executor_verify("bootstrap",b,key))
    fmt.println("[native-owner] original signed chain/reserve/requirements/preparation/commit/bootstrap PASS")
    if stop_only {native_owner_remote_stop(t,&p,wire,activation,content,path);return}
    native_owner_physical(t,&p,wire,activation,content)
}

Native_Owner_Physical :: struct {
    owner:^Native_Owner_Proof,
    socket,endpoint,run_dir,args_file,native_path,native_session:string,
    listener:local_socket.Socket,
    stop:bool,
    accepted,callbacks:i64,
    unlocked,startup_unlocked:bool,
}
native_owner_directory :: proc(ctx:rawptr,_:i64)->(vault.Directory_Verification_Input,bool) {
    return (^Native_Owner_Physical)(ctx).owner.directory,true
}
native_owner_hook_server :: proc(ctx:rawptr) {
    context.allocator=context.temp_allocator
    p:=(^Native_Owner_Physical)(ctx)
    for !sync.atomic_load(&p.stop) {
        client,connected:=local_socket.accept(p.listener)
        if !connected {return}
        if sync.atomic_load(&p.stop) {local_socket.close(client);return}
        _=local_socket.set_recv_timeout(client,3*time.Second)
        data:=make([dynamic]byte,context.temp_allocator);buffer:[4096]byte
        for len(data)<2*contracts.EXECUTOR_DOCUMENT_MAX {
            n:=local_socket.recv(client,buffer[:]);if n<=0 do break
            append(&data,..buffer[:n])
            if strings.index_byte(string(data[:]),'\n')<0 do continue
            transport:=Executor_Child_Transport{p,native_owner_directory,nil}
            reply:=bridge_local_endpoint_handle_jsonl_line(strings.trim_space(string(data[:])),transport,p.socket)
            if strings.contains(reply,`"accepted":1`) {
                value,_:=contracts.owner_content_document(strings.trim_space(string(data[:])))
                request,_:=value.(json.Object)
                events,_:=contracts.ext_split_events(executor.encode(request["params"]))
                for raw in events {
                    ev,err:=contracts.ext_parse_event(raw)
                    if err==.None && ev.kind==.Session && ev.session_phase=="start" {
                        p.native_path=strings.clone(ev.transcript_path,runtime.default_allocator())
                        p.native_session=strings.clone(ev.session_id,runtime.default_allocator())
                    }
                    contracts.ext_event_destroy(&ev)
                }
                contracts.ext_split_events_destroy(events)
                sync.atomic_add(&p.accepted,1)
            }
            fmt.println("[native-owner] authenticated hook observer:",reply)
            line:=strings.concatenate({reply,"\n"},context.temp_allocator)
            _=local_socket.send(client,transmute([]byte)line)
            break
        }
        local_socket.close(client)
    }
}
native_owner_fence_exchange :: proc(ctx:rawptr,raw:string,generation:i64)->Executor_Fence_Outcome {
    p:=(^Native_Owner_Physical)(ctx);o:=p.owner
    p.callbacks+=1
    p.unlocked=sync.mutex_try_lock(&bridge_executor_mutex)
    if p.unlocked do sync.mutex_unlock(&bridge_executor_mutex)
    p.startup_unlocked=sync.mutex_try_lock(&bridge_startup_io_mutex)
    if p.startup_unlocked do sync.mutex_unlock(&bridge_startup_io_mutex)
    kind:="fence_request"
    q,valid:=contracts.executor_parse(raw,kind)
    if !valid {kind="notification_fence_request";q,valid=contracts.executor_parse(raw,kind)}
    if !valid do return {}
    now:=bridge_executor_physical_clock(nil)
    digest,_:=contracts.executor_digest(kind,q)
    scope:=bridge_executor_test_doc("transport_scope")
    for name in ([7]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation","executor_incarnation"}) do scope[name]=q[name]
    for pair in ([][2]string{{"request_id",fmt.tprintf("native_nonce_%d",p.callbacks)},{"method",kind},{"direction","request"},
        {"input_digest",digest},{"fence_digest",contracts.owner_string(q,"action_digest")},
        {"issued_ms",contracts.owner_string(q,"issued_ms")},{"request_expires_ms",contracts.owner_string(q,"request_expires_ms")}}) {scope[pair[0]]=json.String(pair[1])}
    // Preserve the signed encrypted reverse channel even with hermetic transport.
    token,sealed:=channel.seal(raw,o.kr,scope,now)
    if !sealed do return {}
    plain,authenticated:=channel.open_signed(token,o.kr,scope,o.host,now,context.temp_allocator)
    if !authenticated do return {}
    result:owner.Result
    if kind=="notification_fence_request" {
        result=owner.execution_notification_fence_reply(&o.store,plain,o.host,o.key,o.directory.version,o.directory.head_hash,now,{o.owner_private,native_owner_sign})
    } else {
        result=owner.execution_fence_reply(&o.store,plain,o.host,o.key,o.directory.version,o.directory.head_hash,now,{o.owner_private,native_owner_sign})
    }
    if result.code!="ok" {fmt.println("[native-owner] nonce refusal:",result.code);return {}}
    scope["direction"]=json.String("response")
    response,ok:=channel.seal(result.body,o.kr,scope,now)
    if !ok do return {}
    return {executor.encode(scope),response,o.directory}
}
native_owner_prepare_spawn :: proc(ctx:rawptr,s:^executor.Store,intent:executor.Intent,now:i64)->(Pty_Host_Spawn_Request,string,bool) {
    p:=(^Native_Owner_Physical)(ctx)
    pin:string
    request,built:=bridge_executor_prepare_spawn(s,intent,now,p.endpoint,&pin)
    if !built {
        m,available:=executor.launch_material(s,intent,now)
        c,_:=contracts.owner_parse(m.configuration,"remote_configuration")
        profile,profile_error:=profile_lookup(contracts.owner_string(c,"provider"),contracts.owner_string(c,"provider_profile"))
        dir,within:=bridge_fs_run_dir_root(intent.instance)
        fmt.println("[native-owner] prepare diagnostic material/profile/path:",available,profile_error,profile.enabled,within,dir)
        return {},"",false
    }
    // Only additional invocation flags from the separately vetted fixture.
    bytes,read_error:=os.read_entire_file(p.args_file,context.temp_allocator)
    extra:[]string
    if read_error!=nil || json.unmarshal(bytes,&extra,.JSON,context.temp_allocator)!=nil {
        bridge_pty_host_spawn_request_delete(request);return {},"",false
    }
    script:=fmt.tprintf("%s/native-hook.sh",p.owner.work)
    status:=fmt.tprintf("%s/native-hook-status",p.owner.work)
    event:=fmt.tprintf("%s/native-hook-event.json",p.owner.work)
    source:=fmt.tprintf("#!/bin/sh\necho invoked > '%s'\ncat > '%s'\nif [ -n \"$HEIMDALL_CTL_BIN\" ]; then echo ctl_present >> '%s'; \"$HEIMDALL_CTL_BIN\" extension hook codex < '%s'; else echo ctl_absent >> '%s'; fi\n",status,event,status,event,status)
    if os.write_entire_file(script,transmute([]byte)source)!=nil {bridge_pty_host_spawn_request_delete(request);return {},"",false}
    hook_config:=strings.concatenate({"hooks.SessionStart=[{hooks=[{type=\"command\",command=",executor.encode(fmt.tprintf("sh '%s'",script)),",timeout=5}]}]"},context.temp_allocator)
    filtered:=make([dynamic]string,context.temp_allocator)
    index:=0
    for index<len(extra) {
        if extra[index]=="-c" && index+1<len(extra) && strings.has_prefix(extra[index+1],"hooks.SessionStart=") {index+=2;continue}
        append(&filtered,extra[index]);index+=1
    }
    argv:=make([]string,len(request.argv)+len(filtered)+2)
    copy(argv,request.argv)
    for value,i in filtered do argv[len(request.argv)+i]=strings.clone(value)
    argv[len(argv)-2]=strings.clone("-c");argv[len(argv)-1]=strings.clone(hook_config)
    delete(request.argv);request.argv=argv
    material,_:=executor.launch_material(s,intent,now)
    for arg in request.argv {
        safe,_:=strings.replace_all(arg,material.token_secret,"<private-test-token>",context.temp_allocator)
        fmt.println("[native-owner] argv:",safe)
    }
    fmt.println("[native-owner] hook_script_sha256",contracts.owner_payload_digest(source),"vetted_args_sha256",contracts.owner_payload_digest(string(bytes)))
    p.run_dir=request.cwd
    return request,pin,true
}
native_owner_physical :: proc(t:^testing.T,p:^Native_Owner_Proof,wire:Executor_Exchange_Wire,
    activation:owner.Intent_Claim,content:json.Object) {
    binary:=bridge_env_get("HEIMDALL_EXECUTOR_TEST_PTY",context.temp_allocator)
    args_file:=bridge_env_get("HEIMDALL_NATIVE_ARGS",context.temp_allocator)
    ctl:=bridge_env_get("HEIMDALL_NATIVE_CTL",context.temp_allocator)
    if !testing.expect(t,binary!="" && ctl!="" && args_file!="","explicit private native proof binaries/args required") {return}
    suffix:=fmt.tprintf("%d",time.to_unix_nanoseconds(time.now()))
    socket:=fmt.tprintf("/tmp/ham-native-owner-%s.sock",suffix)
    endpoint_path:=fmt.tprintf("/tmp/ham-native-hook-%s.sock",suffix)
    swap:=pty_host_test_install_socket(socket);defer pty_host_test_restore_socket(swap)
    // The fixture runs inside a worker: do not inherit its production credentials
    // or endpoint into the disposable daemon/native child.
    inherited:=os.environ(context.temp_allocator) or_else nil
    daemon_env:=make([dynamic]string,context.temp_allocator)
    for entry in inherited do if !strings.has_prefix(entry,"HEIMDALL_") {append(&daemon_env,entry)}
    daemon,err:=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",socket,"daemon"},env=daemon_env[:]})
    if !testing.expect(t,err==nil) {return}
    defer {_=os.process_kill(daemon);_,_=os.process_wait(daemon);_=os.remove(socket);_=os.remove(fmt.tprintf("%s.lock",socket))}
    ready:=false
    for _ in 0..<100 {if bridge_pty_host_ping(socket) {ready=true;break};time.sleep(10*time.Millisecond)}
    if !testing.expect(t,ready) {return}
    prior_run:=bridge_cfg().local_endpoint_run_dir
    bridge_cfg().local_endpoint_run_dir=fmt.tprintf("%s/native-runtime",p.work)
    defer bridge_cfg().local_endpoint_run_dir=prior_run
    if !testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/instances",bridge_cfg().local_endpoint_run_dir))==nil) {return}
    physical:=Native_Owner_Physical{owner=p,socket=socket,endpoint=fmt.tprintf("unix:%s",endpoint_path),args_file=args_file}
    listener,listening:=local_socket.listen(endpoint_path,8)
    if !testing.expect(t,listening) {return}
    physical.listener=listener
    server:=bridge_thread_start_with_data(&physical,native_owner_hook_server)
    defer {
        sync.atomic_store(&physical.stop,true)
        wake,connected:=local_socket.dial(endpoint_path);if connected do local_socket.close(wake)
        thread.join(server);thread.destroy(server);local_socket.close(listener);_=os.remove(endpoint_path)
        delete(physical.native_path,runtime.default_allocator());delete(physical.native_session,runtime.default_allocator())
    }
    old_ctl,had_ctl:=bridge_env_lookup("HEIMDALL_HAM_CTL_BIN",context.temp_allocator)
    bridge_test_env_set("HEIMDALL_HAM_CTL_BIN",ctl)
    defer {if had_ctl {bridge_test_env_set("HEIMDALL_HAM_CTL_BIN",old_ctl)} else {bridge_test_env_unset("HEIMDALL_HAM_CTL_BIN")}}
    io:=Executor_Launch_IO{&physical,native_owner_prepare_spawn,socket}
    action,_:=contracts.executor_parse(activation.payload,"action")
    receipt,code:=bridge_executor_test_exchange(t,wire,action,"action",p.owner_private,p.kr,p.host,"native_owner_activate",
        bootstrap=contracts.owner_string(content,"bootstrap"),body=contracts.owner_string(content,"body"),launch_io=io,physical=true,
        exchange_ctx=&physical,exchange_fn=native_owner_fence_exchange,owner_intent=activation.id)
    if !testing.expect_value(t,code,"ok") {return}
    b,_:=contracts.executor_parse(contracts.owner_string(content,"bootstrap"),"bootstrap")
    instance,key:=contracts.owner_string(b,"instance_id"),contracts.owner_string(b,"launch_key")
    defer _=bridge_pty_host_executor_close(socket,instance,key)
    pid,known:=bridge_pty_host_executor_query(socket,instance,key)
    if !testing.expect(t,known && pid>0) {return}
    // A crashed daemon can leave its private native child outside the new
    // daemon's roster. Cleanup is test-only, never an absence observation.
    defer bridge_shell_test_kill_pid(int(pid))
    if !testing.expect(t,physical.unlocked && physical.startup_unlocked,"real owner nonce callback releases executor/startup mutexes") {return}
    initial:=contracts.PTY_Notification_Delivery{protocol_version=1,
        source={instance,contracts.owner_string(b,"launch_epoch"),contracts.owner_string(b,"run_count")},
        pid=fmt.tprintf("%d",pid),launch_key=contracts.owner_string(b,"token_generation"),
        operation_id="native_owner_initial",delivery_id="native_owner_initial",interrupt=false,
        message="Do not use tools. Count from 1 to 100000, one integer per line.\nLiteral\t€ 日本語 😀 native owner proof."}
    when #config(EXECUTOR_NATIVE_IDLE_REFUSAL,false) {
        initial.message="Do not use tools. Reply OK only.\nLiteral\t€ 日本語 😀 native idle proof."
    }
    prepared:Bridge_PTY_Notification_Result
    for _ in 0..<100 {
        prepared=bridge_pty_notification_request(socket,initial,PTY_NOTIFICATION_PREPARE,"")
        if prepared.error==.None && prepared.ticket!="" do break
        delete(prepared.ticket);delete(prepared.input_profile);time.sleep(50*time.Millisecond)
    }
    defer delete(prepared.ticket);defer delete(prepared.input_profile)
    if !testing.expect(t,prepared.error==.None && prepared.ticket!="","initial native literal paste must be admitted without interrupt") {return}
    initial_result:Bridge_PTY_Notification_Result
    for _ in 0..<100 {
        initial_result=bridge_pty_notification_request(socket,initial,PTY_NOTIFICATION_DISPATCH,prepared.ticket,prepared.input_profile)
        if initial_result.error==.None && initial_result.receipt.status=="delivered" do break
        fmt.println("[native-owner] initial paste gate:",initial_result.error,initial_result.receipt.status)
        delete(initial_result.ticket);delete(initial_result.input_profile);time.sleep(50*time.Millisecond)
    }
    defer delete(initial_result.ticket);defer delete(initial_result.input_profile)
    if !testing.expect_value(t,initial_result.receipt.status,"delivered") {return}
    // Codex creates/starts a native session lazily on its first actual turn.
    for _ in 0..<100 {
        if sync.atomic_load(&physical.accepted)>0 do break
        time.sleep(100*time.Millisecond)
    }
    if !testing.expect(t,sync.atomic_load(&physical.accepted)==1,"actual ham-ctl native SessionStart must reach authenticated current-child observer") {
        _=bridge_pty_host_deliver_raw_input_socket_string(socket,instance,"\x1bOQ")
        time.sleep(300*time.Millisecond)
        for index in 0..<4 {
            capture,captured:=bridge_pty_host_capture_text(socket,instance)
            if captured {fmt.println("[native-owner] warning screen",index,":",capture);delete(capture)}
            _=bridge_pty_host_deliver_raw_input_socket_string(socket,instance,"\x1b[C")
            time.sleep(100*time.Millisecond)
        }
        status,status_error:=os.read_entire_file(fmt.tprintf("%s/native-hook-status",p.work),context.temp_allocator)
        fmt.println("[native-owner] hook invocation status:",status_error,string(status))
        return
    }
    fmt.println("[native-owner] actual extension -> current bootstrap observer -> native daemon binding PASS",pid)

    users,started,aborted:=0,0,0
    for _ in 0..<100 {
        users,started,aborted=native_owner_transcript(physical.native_path,initial.message)
        if users==1 && started>0 do break
        time.sleep(50*time.Millisecond)
    }
    if !testing.expect(t,users==1 && started>0,"native transcript must contain the exact LF/TAB/Unicode initial message once in a real turn") {return}
    when #config(EXECUTOR_NATIVE_IDLE_REFUSAL,false) {
        idle:=false
        for _ in 0..<150 {
            if native_owner_idle(physical.native_path) {idle=true;break}
            time.sleep(100*time.Millisecond)
        }
        if !testing.expect(t,idle,"bounded native idle proof requires an actual completed turn") {return}
    }
    initial_replay:=bridge_pty_notification_request(socket,initial,PTY_NOTIFICATION_DISPATCH,prepared.ticket,prepared.input_profile)
    defer delete(initial_replay.ticket);defer delete(initial_replay.input_profile)
    if !testing.expect_value(t,initial_replay.receipt.status,"delivered") {return}
    if !testing.expect(t,owner.intent_result(&p.store,activation,true,executor.encode(receipt),bridge_executor_physical_clock(nil))) {return}
    before,_:=owner.query(p.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts),(SELECT count(*) FROM command_receipts),(SELECT count(*) FROM owner_execution_bootstraps)")
    revisions,_:=owner.query(p.store.db,"SELECT revision FROM tasks WHERE task_id=?",p.task)
    hold_payload:=executor.encode(native_owner_document([][2]string{{"body_cipher",native_owner_cipher(p,"Pause at the original checkpoint € 日本語 😀")}}))
    if !testing.expect_value(t,native_owner_call(p,"task.hold","native_real_hold",p.task,hold_payload,revisions[0][0]).code,"ok") {return}
    now:=bridge_executor_physical_clock(nil)
    claims,claimed:=owner.intent_claim_due(&p.store,now,20,.Executor)
    if !testing.expect(t,claimed && len(claims)==1 && claims[0].kind=="executor.notification") {return}
    claim:=claims[0]
    produced:=owner.execution_notification(&p.store,claim,p.key,now,{p.owner_private,native_owner_sign})
    if !testing.expect_value(t,produced.code,"ok") {return}
    value,_:=contracts.owner_content_document(produced.body);notice,_:=value.(json.Object)
    notification,_:=contracts.executor_parse(contracts.owner_string(notice,"notification"),"notification")
    message:=contracts.owner_string(notice,"message")
    when #config(EXECUTOR_NATIVE_IDLE_REFUSAL,false) {
        native_owner_idle_refusal(t,p,wire,notification,message,claim,&physical,io,before[:])
        return
    }
    // Fail only result persistence after the physical write, then recover from
    // the retained exact ticket/daemon receipt. This inserts no authority row.
    if !testing.expect(t,executor.exec(bridge_executor_store.db,"CREATE TRIGGER native_result_fault BEFORE INSERT ON executor_receipts WHEN NEW.kind='notification.result' BEGIN SELECT RAISE(ABORT,'lost native result persistence'); END")) {return}
    defer _=executor.exec(bridge_executor_store.db,"DROP TRIGGER IF EXISTS native_result_fault")
    lost:=false
    final:json.Object
    partial:=false
    for index in 0..<50 {
        result,result_code:=bridge_executor_test_exchange(t,wire,notification,"notification",p.owner_private,p.kr,p.host,
            fmt.tprintf("native_owner_notification_%d",index),launch_io=io,physical=true,notification_message=message,
            exchange_ctx=&physical,exchange_fn=native_owner_fence_exchange)
        if result_code=="storage_error" {
            lost=true
            if !testing.expect(t,executor.exec(bridge_executor_store.db,"DROP TRIGGER native_result_fault")) {return}
        } else if result_code=="ok" {
            status:=contracts.owner_string(result,"status")
            if status=="partial" {
                partial=true
                when #config(EXECUTOR_NATIVE_PENDING_LOSS,false) {
                    if !testing.expect(t,contracts.owner_string(result,"esc_written")=="1" &&
                        contracts.owner_string(result,"message_bytes_written")=="0" &&
                        contracts.owner_string(result,"enter_written")=="0") {return}
                    saved:=executor.notification_stage(&bridge_executor_store,notification,message,p.key,"ticket",bridge_executor_physical_clock(nil))
                    ticket:executor.Notification_Ticket
                    if !testing.expect(t,saved.code=="ok" && json.unmarshal_string(saved.body,&ticket,.JSON,context.temp_allocator)==nil &&
                        ticket.ticket==contracts.owner_string(result,"ticket")) {return}
                    charged,read_charge:=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources")
                    if !testing.expect(t,read_charge && len(charged)==1 && charged[0][0]=="1") {return}
                    callback_count:=physical.callbacks
                    _=os.process_kill(daemon);_,_=os.process_wait(daemon)
                    daemon,err=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",socket,"daemon"},env=daemon_env[:]})
                    if !testing.expect(t,err==nil) {return}
                    ready=false
                    for _ in 0..<100 {if bridge_pty_host_ping(socket) {ready=true;break};time.sleep(10*time.Millisecond)}
                    if !testing.expect(t,ready) {return}
                    unknown,known_now:=bridge_pty_host_executor_query(socket,instance,key)
                    if !testing.expect(t,!known_now && unknown==0,"pending host journal loss is unknown, not absence") {return}
                    exact:=contracts.PTY_Notification_Delivery{protocol_version=1,
                        source={instance,contracts.owner_string(notification,"launch_epoch"),contracts.owner_string(notification,"run_count")},
                        pid=ticket.pid,launch_key=contracts.owner_string(notification,"token_generation"),
                        operation_id=claim.id,delivery_id=claim.id,message=message,interrupt=true}
                    unknown_ticket:=bridge_pty_notification_request(socket,exact,PTY_NOTIFICATION_QUERY,ticket.ticket,ticket.input_profile)
                    defer delete(unknown_ticket.ticket);defer delete(unknown_ticket.input_profile)
                    if !testing.expect(t,unknown_ticket.error==.None && unknown_ticket.receipt.status=="recovery_required",
                        "lost journal reports recovery required, never a reconstructed partial or delivered receipt") {return}
                    _,reconciled:=bridge_executor_reconcile_batch(&bridge_executor_store,bridge_executor_physical_clock(nil),socket,"")
                    if !testing.expect(t,reconciled,"production sweep tolerates an unknown exact child") {return}
                    for retry in 0..<3 {
                        _,retry_code:=bridge_executor_test_exchange(t,wire,notification,"notification",p.owner_private,p.kr,p.host,
                            fmt.tprintf("native_owner_pending_loss_%d",retry),launch_io=io,physical=true,notification_message=message,
                            exchange_ctx=&physical,exchange_fn=native_owner_fence_exchange)
                        if !testing.expect_value(t,retry_code,"child_unavailable") {return}
                    }
                    retained:=executor.notification_stage(&bridge_executor_store,notification,message,p.key,"ticket",bridge_executor_physical_clock(nil))
                    no_result:=executor.notification_stage(&bridge_executor_store,notification,message,p.key,"result",bridge_executor_physical_clock(nil))
                    still_charged,_:=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources")
                    if !testing.expect(t,retained.code=="ok" && retained.body==saved.body && no_result.code=="not_found" &&
                        still_charged[0][0]==charged[0][0] && physical.callbacks==callback_count,
                        "uncertainty retains the original ticket and capacity without replacement preparation or nonce/write") {return}
                    revoked:=p.key;revoked.revoked=true
                    if !testing.expect(t,!executor.notification_current(&bridge_executor_store,notification,message,revoked,bridge_executor_physical_clock(nil)) &&
                        !executor.notification_current(&bridge_executor_store,notification,message,p.key,contracts.executor_number(notification,"request_expires_ms")),
                        "retained receipt never overrides key revocation or expiry") {return}
                    pending,fenced:=executor.notification_challenge(&bridge_executor_store,executor.encode(notification),message,1,p.key,p.host,
                        bridge_executor_physical_clock(nil),{nil,bridge_executor_sign})
                    defer executor.fence_challenge_destroy(&pending)
                    if !testing.expect(t,fenced) {return}
                    revs,_:=owner.query(p.store.db,"SELECT revision FROM tasks WHERE task_id=?",p.task)
                    cancel_payload:=executor.encode(native_owner_document([][2]string{{"body_cipher",native_owner_cipher(p,"Cancel ambiguous pending delivery")}}))
                    if !testing.expect_value(t,native_owner_call(p,"task.cancel","native_pending_cancel",p.task,cancel_payload,revs[0][0]).code,"ok") {return}
                    refused:=owner.execution_notification_fence_reply(&p.store,pending.request,p.host,p.key,p.directory.version,p.directory.head_hash,
                        bridge_executor_physical_clock(nil),{p.owner_private,native_owner_sign})
                    if !testing.expect(t,refused.code!="ok" && owner.execution_notification_current(&p.store,claim,bridge_executor_physical_clock(nil))!="ok",
                        "signed owner cancellation denies a pending delivery nonce") {return}
                    users,_,aborted=native_owner_transcript(physical.native_path,message)
                    authority,_:=owner.query(p.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts),(SELECT count(*) FROM owner_execution_bootstraps)")
                    if !testing.expect(t,users==0 && aborted<=1 && authority[0][0]==before[0][0] && authority[0][1]==before[0][1] && authority[0][2]==before[0][3],
                        "pending host loss produces no notice submission or new task authority") {return}
                    // Expiry permits cleanup attempts, never a capacity refund
                    // when the restarted daemon has no exact launch journal.
                    expiry:=contracts.executor_number(notification,"expires_ms")+1
                    _,expired_sweep:=bridge_executor_reconcile_batch(&bridge_executor_store,expiry,socket,"",&expiry,bridge_executor_test_clock)
                    expired_charge,_:=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources")
                    evidence,_:=executor.query(bridge_executor_store.db,"SELECT kind,result_json FROM executor_receipts WHERE kind LIKE 'notification.%' ORDER BY kind")
                    if !testing.expect(t,expired_sweep && expired_charge[0][0]==charged[0][0] && len(evidence)==2 &&
                        evidence[0][0]=="notification.dispatch" && evidence[1][0]=="notification.ticket" && evidence[1][1]==saved.body,
                        "expiry and failed exact close preserve the pending ticket/dispatch evidence and charged capacity") {return}
                    fmt.println("[native-owner] pending partial host-loss safe refusal PASS", "ticket",ticket.ticket,"submissions",users,"typed_aborts",aborted,"charge",still_charged[0][0],"nonce_refusal",refused.code)
                    return
                }
            }
            else if status=="delivered" {final=result;break}
            else {testing.fail_now(t,fmt.tprintf("native owner notification did not deliver: %s",status))}
        } else {testing.fail_now(t,fmt.tprintf("native owner notification failed: %s",result_code))}
        time.sleep(50*time.Millisecond)
    }
    if !testing.expect(t,final!=nil && lost && partial,"real partial interrupt and lost result persistence must reconcile to one delivery") {return}
    if !testing.expect(t,contracts.executor_notification_result_matches(final,notification,message,p.host,bridge_executor_physical_clock(nil)) &&
        contracts.owner_string(final,"esc_written")=="1" && contracts.owner_string(final,"enter_written")=="1" &&
        contracts.owner_string(final,"message_bytes_written")==fmt.tprintf("%d",len(message))) {return}
    accepted_scope:string
    repeated,repeat_code:=bridge_executor_test_exchange(t,wire,notification,"notification",p.owner_private,p.kr,p.host,"native_owner_notification_replay",
        launch_io=io,physical=true,notification_message=message,exchange_ctx=&physical,exchange_fn=native_owner_fence_exchange,scope_out=&accepted_scope)
    if !testing.expect(t,repeat_code=="ok" && contracts.owner_string(repeated,"ticket")==contracts.owner_string(final,"ticket") &&
        contracts.owner_string(repeated,"status")=="delivered") {return}
    for _ in 0..<100 {
        users,_,aborted=native_owner_transcript(physical.native_path,message)
        if users==1 && aborted==1 do break
        time.sleep(50*time.Millisecond)
    }
    if !testing.expect(t,users==1 && aborted==1,"real owner notice is submitted once after one native typed abort") {return}
    after,_:=owner.query(p.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts),(SELECT count(*) FROM command_receipts),(SELECT count(*) FROM owner_execution_bootstraps)")
    if !testing.expect(t,before[0][0]==after[0][0] && before[0][1]==after[0][1] && before[0][3]==after[0][3] &&
        contracts.executor_number(notification,"owner_commit_seq")>0 && physical.unlocked && physical.startup_unlocked) {return}
    if !testing.expect_value(t,owner.execution_notification_current(&p.store,claim,bridge_executor_physical_clock(nil)),"ok") {return}
    stale:=make(json.Object,context.temp_allocator)
    for name,value in notification do stale[name]=value
    stale["launch_epoch"]=json.String("stale_native_epoch")
    _,stale_code:=bridge_executor_test_exchange(t,wire,stale,"notification",p.owner_private,p.kr,p.host,"native_owner_stale",
        launch_io=io,physical=true,notification_message=message,exchange_ctx=&physical,exchange_fn=native_owner_fence_exchange)
    if !testing.expect_value(t,stale_code,"no_current_target") {return}
    // Completed exact receipt replay remains read-only after daemon journal
    // loss and absence of the original child. It cannot prepare a new ticket.
    if !testing.expect(t,bridge_pty_host_executor_close(socket,instance,key)) {return}
    _=os.process_kill(daemon);_,_=os.process_wait(daemon)
    daemon,err=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",socket,"daemon"},env=daemon_env[:]})
    if !testing.expect(t,err==nil) {return}
    ready=false
    for _ in 0..<100 {if bridge_pty_host_ping(socket) {ready=true;break};time.sleep(10*time.Millisecond)}
    if !testing.expect(t,ready) {return}
    absent,queried:=bridge_pty_host_executor_query(socket,instance,key)
    if !testing.expect(t,!queried && absent==0,"daemon journal loss has unknown exact-launch outcome, never authoritative absence") {return}
    list_frame:=pty_host_encode_list();defer delete(list_frame)
    listed,list_ok:=pty_host_request(socket,list_frame)
    defer pty_host_reply_delete(listed)
    if !testing.expect(t,list_ok && listed.kind==.Agent_List && len(listed.agents)==0) {return}
    recovered,recovered_code:=bridge_executor_test_exchange(t,wire,notification,"notification",p.owner_private,p.kr,p.host,"native_owner_notification_after_host_loss",
        launch_io=io,physical=true,notification_message=message,exchange_ctx=&physical,exchange_fn=native_owner_fence_exchange,scope_out=&accepted_scope)
    if !testing.expect(t,recovered_code=="ok" && contracts.owner_string(recovered,"status")=="delivered" &&
        contracts.owner_string(recovered,"ticket")==contracts.owner_string(final,"ticket")) {return}
    accepted_receipt,accepted:=native_owner_accept_result(t,p,claim,notification,message,accepted_scope)
    if !testing.expect(t,accepted,"production owner accepts the original encrypted signed exact result") {return}
    if !testing.expect(t,owner.intent_result(&p.store,claim,true,accepted_receipt,bridge_executor_physical_clock(nil))) {return}
    authority,_:=owner.query(p.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts),(SELECT count(*) FROM owner_execution_bootstraps)")
    if !testing.expect(t,authority[0][0]==before[0][0] && authority[0][1]==before[0][1] && authority[0][2]==before[0][3]) {return}
    settled,_:=owner.query(p.store.db,"SELECT state,result_json FROM runtime_intents WHERE intent_id=?",claim.id)
    if !testing.expect(t,len(settled)==1 && settled[0][0]=="settled") {return}
    fmt.println("[native-owner] actual signed owner hold -> encrypted executor/nonce -> partial interrupt/paste -> lost-result recovery -> signed receipt/replay PASS",
        "bytes",len(message),"submissions",users,"typed_aborts",aborted,"callbacks",physical.callbacks)

}

native_owner_idle :: proc(path:string)->bool {
    bytes,err:=os.read_entire_file(path,context.temp_allocator)
    if err!=nil || len(bytes)>8*1024*1024 do return false
    active,completed:=false,false
    for line in strings.split(string(bytes),"\n",context.temp_allocator) {
        value,valid:=contracts.owner_content_document(line);row,object:=value.(json.Object)
        if !valid || !object || contracts.owner_string(row,"type")!="event_msg" do continue
        payload,_:=row["payload"].(json.Object)
        switch contracts.owner_string(payload,"type") {
        case "task_started": active=true
        case "task_complete": active=false;completed=true
        case "turn_aborted": active=false
        }
    }
    return completed && !active
}

// Real idle input is refused even with a bound, approved busy-turn profile.
// Cancellation and a newer signed directory cannot turn that ticket into input.
native_owner_idle_refusal :: proc(t:^testing.T,p:^Native_Owner_Proof,wire:Executor_Exchange_Wire,
    notification:json.Object,message:string,claim:owner.Intent_Claim,physical:^Native_Owner_Physical,
    io:Executor_Launch_IO,before:[][]string) {
    for retry in 0..<2 {
        result,code:=bridge_executor_test_exchange(t,wire,notification,"notification",p.owner_private,p.kr,p.host,
            fmt.tprintf("native_owner_idle_%d",retry),launch_io=io,physical=true,notification_message=message,
            exchange_ctx=physical,exchange_fn=native_owner_fence_exchange)
        if !testing.expect(t,code=="ok" && contracts.owner_string(result,"status")=="unsupported_not_delivered" &&
            contracts.owner_string(result,"esc_written")=="0" && contracts.owner_string(result,"message_bytes_written")=="0" &&
            contracts.owner_string(result,"enter_written")=="0","real idle state refuses ESC/paste/Enter") {return}
    }
    now:=bridge_executor_physical_clock(nil)
    saved:=executor.notification_stage(&bridge_executor_store,notification,message,p.key,"ticket",now)
    if !testing.expect_value(t,saved.code,"ok") {return}
    revs,_:=owner.query(p.store.db,"SELECT revision FROM tasks WHERE task_id=?",p.task)
    payload:=executor.encode(native_owner_document([][2]string{{"body_cipher",native_owner_cipher(p,"Cancel refused idle delivery")}}))
    if !testing.expect_value(t,native_owner_call(p,"task.cancel","native_idle_cancel",p.task,payload,revs[0][0]).code,"ok") {return}
    _,cancel_code:=bridge_executor_test_exchange(t,wire,notification,"notification",p.owner_private,p.kr,p.host,"native_idle_cancelled",
        launch_io=io,physical=true,notification_message=message,exchange_ctx=physical,exchange_fn=native_owner_fence_exchange)
    if !testing.expect(t,cancel_code!="ok" && owner.execution_notification_current(&p.store,claim,bridge_executor_physical_clock(nil))!="ok",
        "signed owner cancellation refuses a formerly prepared idle ticket") {return}
    // Append a genuine device-signed owner revocation to the paired log. The
    // missing next epoch key deliberately denies opening, but advances the pin.
    approval,parsed:=vault.statement_parse(p.directory.log[len(p.directory.log)-1].statement)
    if !testing.expect(t,parsed && approval.type=="approve" && approval.subject_device_id==p.key.key_id) {return}
    revoke:=approval
    revoke.type="revoke";revoke.seq=fmt.tprintf("%d",p.directory.version+1);revoke.prev_hash=p.directory.head_hash
    revoke.issued_at_ms="6";revoke.epoch=fmt.tprintf("%d",p.directory.current_epoch+1)
    revoke.epoch_commit=strings.repeat("c",64,context.temp_allocator)
    revoke_text,_:=vault.statement_canonical(&revoke,context.temp_allocator)
    sig,signed:=vault.sign_p256(p.device_private,transmute([]byte)revoke_text)
    signature,_:=vault.signature_object(&sig,context.temp_allocator)
    if !testing.expect(t,signed) {return}
    revoked:=p.directory;revoked.version+=1;revoked.current_epoch+=1
    revoked.head_hash=vault.log_entry_hash(revoke_text,context.temp_allocator)
    revoked.log=make([]vault.Directory_Log_Item,len(p.directory.log)+1,context.temp_allocator)
    copy(revoked.log,p.directory.log);revoked.log[len(revoked.log)-1]={revoked.version,revoke_text,signature}
    revoked.devices=make([]vault.Directory_Device_Item,len(p.directory.devices),context.temp_allocator)
    copy(revoked.devices,p.directory.devices)
    for &device in revoked.devices do if device.id==p.key.key_id {device.approved=false}
    _,valid:=vault.directory_verify(revoked)
    if !testing.expect(t,valid,"revocation must be a real verified directory observation") {return}
    _,opened:=bridge_executor_directory(&bridge_executor_store,revoked,p.kr)
    pin,_,pinned:=executor.enrollment_pin(&bridge_executor_store)
    if !testing.expect(t,!opened && pinned && pin==revoked.version) {return}
    callbacks:=physical.callbacks
    _,revoked_code:=bridge_executor_test_exchange(t,wire,notification,"notification",p.owner_private,p.kr,p.host,"native_idle_revoked",
        launch_io=io,physical=true,notification_message=message,exchange_ctx=physical,exchange_fn=native_owner_fence_exchange)
    if !testing.expect(t,revoked_code!="ok" && physical.callbacks==callbacks,"old directory cannot restore the revoked owner or reach a nonce callback") {return}
    users,_,aborts:=native_owner_transcript(physical.native_path,message)
    authority,_:=owner.query(p.store.db,"SELECT (SELECT count(*) FROM local_leases),(SELECT count(*) FROM local_work_attempts),(SELECT count(*) FROM owner_execution_bootstraps)")
    tickets,_:=executor.query(bridge_executor_store.db,"SELECT result_json FROM executor_receipts WHERE kind='notification.ticket'")
    charge,_:=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources")
    if !testing.expect(t,users==0 && aborts==0 && native_owner_idle(physical.native_path) && len(tickets)==1 && tickets[0][0]==saved.body && charge[0][0]=="1" &&
        authority[0][0]==before[0][0] && authority[0][1]==before[0][1] && authority[0][2]==before[0][3],
        "idle/cancel/revoke probes write nothing and retain the one ticket,charge and task authority") {return}
    fmt.println("[native-owner] real idle refusal/cancellation/signed revocation PASS", "submissions",users,"aborts",aborts,
        "charge",charge[0][0],"cancel",cancel_code,"revoked",revoked_code,"pin",pin)
}

native_owner_transcript :: proc(path,message:string)->(users,starts,aborts:int) {
    bytes,err:=os.read_entire_file(path,context.temp_allocator)
    if err!=nil || len(bytes)>8*1024*1024 {return}
    events,responses:=0,0
    for line in strings.split(string(bytes),"\n",context.temp_allocator) {
        value,valid:=contracts.owner_content_document(line);row,object:=value.(json.Object)
        if !valid || !object do continue
        payload,_:=row["payload"].(json.Object)
        if contracts.owner_string(row,"type")=="event_msg" {
            kind:=contracts.owner_string(payload,"type")
            if kind=="task_started" do starts+=1
            if kind=="turn_aborted" && contracts.owner_string(payload,"reason")=="interrupted" do aborts+=1
            if kind=="user_message" && contracts.owner_string(payload,"message")==message do events+=1
        } else if contracts.owner_string(row,"type")=="response_item" &&
            contracts.owner_string(payload,"type")=="message" && contracts.owner_string(payload,"role")=="user" {
            content,_:=payload["content"].(json.Array)
            for item in content {
                text,_:=item.(json.Object)
                if contracts.owner_string(text,"text")==message do responses+=1
            }
        }
    }
    users=max(events,responses)
    return
}

native_owner_accept_result :: proc(t:^testing.T,p:^Native_Owner_Proof,claim:owner.Intent_Claim,
    notification:json.Object,message,scope:string)->(string,bool) {
    _,safe_owner_id:=keystore_test_bridge_ids()
    if p.key.principal_id!=safe_owner_id do return "",false
    // A second test-only Bridge identity owns the owner store. Pair it through
    // the same real test-root unseal path; never relabel the executor as owner.
    // The owner identity/fresh anti-rollback floor were created by normal
    // test enrollment before the device approved its key in the paired log.
    previous:=bridge_cfg().daemon_id;bridge_cfg().daemon_id=safe_owner_id
    defer {bridge_cfg().daemon_id=previous;bridge_unseal_forget_identity()}
    bridge_unseal_forget_identity()
    now:=bridge_executor_physical_clock(nil)
    payload:=test_create_unseal_v2_payload(safe_owner_id,p.kr,now,"native_owner_result_pair")
    bridge_unseal_init()
    unlocked,reason:=bridge_unseal_decrypt_and_verify(payload,safe_owner_id,now)
    fmt.println("[native-owner] owner pairing status:",unlocked,reason,"public_matches",bridge_identity_public_key_hex(safe_owner_id)==p.key.public_key)
    if !testing.expect(t,unlocked && bridge_identity_public_key_hex(safe_owner_id)==p.key.public_key) do return "",false
    cached,found:=bridge_runtime_cached_command("native_owner_notification_after_host_loss")
    if !found do return "",false
    pin:=Owner_Executor_Pin{key_id=p.host.key_id,generation=bridge_task_chain_search_generation(),
        notification=executor.encode(notification),message=message}
    envelope:=Owner_Executor_HTTP_Reply{data=Owner_Executor_Relay_Data{reply=cached,directory=p.directory}}
    outcome:=Owner_Executor_Outcome{scope=scope,body=executor.encode(envelope),code="response"}
    bad_scope,_:=contracts.executor_parse(scope,"transport_scope")
    bad_scope["input_digest"]=json.String(strings.repeat("0",64,context.temp_allocator))
    bad:=outcome;bad.scope=executor.encode(bad_scope)
    bad_read,bad_settled,bad_reason:=bridge_owner_executor_accept(nil,&p.store,claim,executor.encode(pin),executor.encode(bad),now)
    if !testing.expect(t,bad_read && !bad_settled && bad_reason=="invalid_notification_result") do return "",false
    // Production acceptance verifies the paired directory, original pending
    // scope/AAD, enrolled executor signature, current owner intent and result.
    read,settled,receipt:=bridge_owner_executor_accept(nil,&p.store,claim,executor.encode(pin),executor.encode(outcome),now)
    if !testing.expectf(t,read && settled && receipt!="invalid_notification_result",
        "production owner result read=%v settled=%v receipt=%s",read,settled,receipt) {return "",false}
    r,valid:=contracts.executor_parse(receipt,"notification_result")
    if !valid || contracts.owner_string(r,"status")!="delivered" do return "",false
    return receipt,true
}
