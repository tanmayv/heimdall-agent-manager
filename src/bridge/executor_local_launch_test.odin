#+build !windows
#+feature dynamic-literals
package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

@(test)
bridge_executor_local_real_daemon_lost_observation_restart_and_exact_stop :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    binary:=os.get_env("HEIMDALL_EXECUTOR_TEST_PTY",context.temp_allocator)
    if binary=="" {
        when #config(EXECUTOR_TEST_REQUIRED,false) {testing.fail_now(t,"HEIMDALL_EXECUTOR_TEST_PTY must name the real daemon")}
        else {fmt.eprintln("[skip] local executor proof requires HEIMDALL_EXECUTOR_TEST_PTY");return}
    }
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    suffix:=fmt.tprintf("%d",time.to_unix_nanoseconds(time.now()))
    socket:=fmt.tprintf("/tmp/ham-local-executor-%s.sock",suffix)
    swap:=pty_host_test_install_socket(socket);defer pty_host_test_restore_socket(swap)
    process,err:=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",socket,"daemon"}})
    if !testing.expect(t,err==nil) do return
    process_live:=true
    defer {if process_live {_=os.process_kill(process);_,_=os.process_wait(process)};_=os.remove(socket)}
    ready:=false
    for _ in 0..<100 {if bridge_pty_host_ping(socket) {ready=true;break};time.sleep(10*time.Millisecond)}
    if !testing.expect(t,ready && bridge_pty_host_local_executor_capable(socket)) do return
    path:=fmt.tprintf("%s/.cache/heimdall-tests/local-live-%s.sqlite",os.get_env("HOME",context.temp_allocator),suffix)
    s:executor.Store
    if !testing.expect(t,executor.open(&s,path,"account","executor","operator")) do return
    defer {executor.close(&s);for ext in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,ext))}
    host_private,host:=bridge_executor_test_key("executor","operator",11);defer ecdsa.private_key_clear(&host_private)
    device_private,device:=bridge_executor_test_key("device","device_key",12);defer ecdsa.private_key_clear(&device_private)
    device.kind="device"
    now:=bridge_executor_physical_clock(nil)
    p:=bridge_executor_test_doc("policy")
    testing.expect_value(t,executor.install_policy(&s,bridge_executor_test_sign(p,"policy",&host_private),host,now).code,"ok")
    d:=bridge_executor_test_doc("directory")
    testing.expect_value(t,executor.install_directory(&s,bridge_executor_test_sign(d,"directory",&host_private),host,now,"/repo").code,"ok")
    req:=Pty_Host_Spawn_Request{instance="local_instance",argv=[]string{"sh"},rows=24,cols=80}
    c:=bridge_executor_test_doc("local_configuration")
    bridge_executor_test_set(c,"purpose","warm");bridge_executor_test_set(c,"provider_profile","default")
    bridge_executor_test_set(c,"directory_key",executor.directory_key("executor","/repo"))
    bridge_executor_test_set(c,"spawn_digest",bridge_executor_local_spawn_digest(req))
    configuration:=executor.encode(c)
    resources:=executor.Local_Resources{contracts.owner_payload_digest(configuration),contracts.owner_string(c,"spawn_digest"),"/repo",true}
    o:=bridge_executor_test_doc("local_launch")
    bridge_executor_test_set(o,"configuration_digest",resources.configuration_digest)
    bridge_executor_test_set(o,"issued_ms",fmt.tprintf("%d",now));bridge_executor_test_set(o,"request_expires_ms",fmt.tprintf("%d",now+60000))
    consent:=bridge_executor_test_sign(o,"local_launch",&device_private)
    admitted:=executor.admit_local(&s,consent,configuration,device,now,resources)
    if !testing.expect_value(t,admitted.code,"ok") do return
    v,_:=contracts.owner_content_document(admitted.body);body,_:=v.(json.Object)
    launch,found:=executor.local_launch(&s,contracts.owner_string(body,"launch_id"));testing.expect(t,found)
    // Simulate physical success followed by failed local confirmation commit.
    testing.expect(t,executor.exec(s.db,"CREATE TRIGGER fail_local_observation BEFORE INSERT ON executor_local_observations BEGIN SELECT RAISE(ABORT,'injected observation fault'); END;"))
    delivered,reason:=bridge_executor_local_dispatch(&s,launch,device,req,resources,socket)
    testing.expect(t,!delivered && reason=="observation_not_committed")
    pid,known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    if !testing.expect(t,known && pid>0) do return
    child_live:=true
    defer if child_live {_=bridge_pty_host_executor_close(socket,launch.instance,launch.launch_key);bridge_shell_test_kill_pid(int(pid))}
    testing.expect(t,executor.exec(s.db,"DROP TRIGGER fail_local_observation"))
    // Retrying even the old pre-dispatch snapshot cannot send Spawn again.
    delivered,reason=bridge_executor_local_dispatch(&s,launch,device,req,resources,socket)
    testing.expect(t,delivered && reason=="child_present")
    same_pid,same_known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    testing.expect(t,same_known && same_pid==pid)
    executor.close(&s);testing.expect(t,executor.open(&s,path,"account","executor","operator"))
    testing.expect(t,!executor.complete_recovery(&s,bridge_executor_physical_clock(nil)))
    next,reconciled:=bridge_executor_local_reconcile_batch(&s,socket,"")
    testing.expect(t,reconciled && next==launch.id)
    testing.expect(t,executor.complete_recovery(&s,bridge_executor_physical_clock(nil)))
    rows,_:=executor.query(s.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"1")
    recovered,loaded:=executor.local_launch(&s,launch.id);testing.expect(t,loaded)
    // A disconnected control endpoint is not trusted absence. Exercise the
    // actual failing socket path across ledger reopen, then queue an exact
    // stop while disconnected. Reconnecting must stop the original child,
    // without another Spawn or a capacity refund during the partition.
    disconnected:=fmt.tprintf("%s.disconnected",socket)
    for _ in 0..<2 {
        delivered,reason=bridge_executor_local_dispatch(&s,recovered,device,{}, {},disconnected)
        testing.expect(t,!delivered && reason=="executor_uncertain")
        rows,_=executor.query(s.db,"SELECT count(*) FROM executor_live_resources")
        testing.expect_value(t,rows[0][0],"1")
    }
    same_pid,same_known=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    testing.expect(t,same_known && same_pid==pid,"disconnected retries preserve the original child")
    testing.expect(t,executor.stop_local_launch(&s,recovered))
    _,reconciled=bridge_executor_local_reconcile_batch(&s,disconnected,"")
    testing.expect(t,reconciled)
    rows,_=executor.query(s.db,"SELECT count(*) FROM executor_live_resources")
    testing.expect(t,rows[0][0]=="1","unacknowledged stop retains capacity")
    executor.close(&s);testing.expect(t,executor.open(&s,path,"account","executor","operator"))
    testing.expect(t,!executor.complete_recovery(&s,bridge_executor_physical_clock(nil)))
    recovered,loaded=executor.local_launch(&s,launch.id);testing.expect(t,loaded)
    testing.expect_value(t,recovered.state,"stopping")
    _,reconciled=bridge_executor_local_reconcile_batch(&s,socket,"");testing.expect(t,reconciled)
    stopped,stopped_known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    testing.expect(t,stopped_known && stopped==0)
    rows,_=executor.query(s.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"0")
    child_live=false
    // A newly authorized replacement can reuse the slot, never the old key.
    bridge_executor_test_set(c,"executor_incarnation",fmt.tprintf("%d",s.incarnation))
    configuration=executor.encode(c);resources.configuration_digest=contracts.owner_payload_digest(configuration)
    bridge_executor_test_set(o,"configuration_digest",resources.configuration_digest)
    bridge_executor_test_set(o,"operation_id","replacement_local")
    consent=bridge_executor_test_sign(o,"local_launch",&device_private)
    admitted=executor.admit_local(&s,consent,configuration,device,bridge_executor_physical_clock(nil),resources)
    if !testing.expect_value(t,admitted.code,"ok") do return
    v,_=contracts.owner_content_document(admitted.body);body,_=v.(json.Object)
    replacement,replacement_found:=executor.local_launch(&s,contracts.owner_string(body,"launch_id"));testing.expect(t,replacement_found)
    delivered,reason=bridge_executor_local_dispatch(&s,replacement,device,req,resources,socket)
    testing.expect(t,delivered && reason=="child_present")
    pid,known=bridge_pty_host_executor_query(socket,replacement.instance,replacement.launch_key)
    if !testing.expect(t,known && pid>0) do return
    child_live=true
    testing.expect(t,!bridge_pty_host_executor_close(socket,recovered.instance,recovered.launch_key))
    same_pid,same_known=bridge_pty_host_executor_query(socket,replacement.instance,replacement.launch_key)
    testing.expect(t,same_known && same_pid==pid)
    // A late legacy stop, including force, cannot kill this exact retained
    // child once its instance target has crossed the permanent barrier. Zero
    // source generation must not turn this independently observed child idle.
    barrier:=executor.Legacy_Barrier{"source_chain","migration",contracts.owner_payload_digest("verified selection"),0}
    testing.expect_value(t,bridge_legacy_install_barrier(&s,barrier,[]executor.Legacy_Resource{{"instance",replacement.instance}}).code,"ok")
    testing.expect(t,!bridge_legacy_stop_target(&s,replacement.instance,true))
    same_pid,same_known=bridge_pty_host_executor_query(socket,replacement.instance,replacement.launch_key)
    testing.expect(t,same_known && same_pid==pid,"fenced legacy force-stop leaves exact child alive")
    launch=replacement;recovered=replacement
    // Daemon loss cannot prove absence or refund this warm charge.
    _=os.process_kill(process);_,_=os.process_wait(process);process_live=false
    bridge_shell_test_kill_pid(int(pid));child_live=false
    _=os.remove(socket)
    process,err=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",socket,"daemon"}})
    if !testing.expect(t,err==nil) do return
    process_live=true
    ready=false
    for _ in 0..<100 {if bridge_pty_host_ping(socket) {ready=true;break};time.sleep(10*time.Millisecond)}
    testing.expect(t,ready)
    delivered,reason=bridge_executor_local_dispatch(&s,recovered,device,{}, {},socket)
    testing.expect(t,!delivered && reason=="executor_uncertain")
    rows,_=executor.query(s.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"1")
    // A fresh daemon cannot close an unknown prior launch key or stop a replacement.
    testing.expect(t,executor.stop_local_launch(&s,recovered))
    _,reconciled=bridge_executor_local_reconcile_batch(&s,socket,"");testing.expect(t,reconciled)
    rows,_=executor.query(s.db,"SELECT state FROM executor_local_launches WHERE launch_id=?",recovered.id);testing.expect_value(t,rows[0][0],"stopping")
}

@(test)
bridge_executor_local_resolver_rechecks_catalog_mapping_and_full_spawn :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    st:=p1c_test_setup(t);defer p1c_test_teardown(st)
    saved_root:=bridge_fs_root
    root:=bridge_fs_canonicalize_existing(st.dir);defer delete(root)
    bridge_fs_root=root;defer {bridge_fs_root=saved_root}
    directory:=fmt.tprintf("%s/work",root)
    if !testing.expect(t,os.make_directory(directory)==nil) do return
    private,key:=bridge_executor_test_key("executor","operator",13);defer ecdsa.private_key_clear(&private)
    s:executor.Store
    if !testing.expect(t,executor.open(&s,fmt.tprintf("%s/local.sqlite",root),"account","executor","operator")) do return
    defer executor.close(&s)
    d:=bridge_executor_test_doc("directory");bridge_executor_test_set(d,"directory_path",directory)
    testing.expect_value(t,bridge_executor_install_directory(&s,bridge_executor_test_sign(d,"directory",&private),key,1000).code,"ok")
    req:=Pty_Host_Spawn_Request{instance="local_instance",argv=[]string{"trusted-provider"},rows=24,cols=80}
    c:=bridge_executor_test_doc("local_configuration")
    for pair in ([5][2]string{{"provider","claude"},{"model","seed"},{"provider_profile","claude"},{"directory_key",executor.directory_key("executor",directory)},{"spawn_digest",bridge_executor_local_spawn_digest(req)}}) do bridge_executor_test_set(c,pair[0],pair[1])
    testing.expect(t,bridge_executor_resolve_local(&s,executor.encode(c),req).resolved)
    changed:=req;changed.argv=[]string{"different-command"}
    testing.expect(t,!bridge_executor_resolve_local(&s,executor.encode(c),changed).resolved)
    changed=req;changed.env=[][2]string{{"HEIMDALL_EXECUTOR_LOCAL_LAUNCH","1"}}
    testing.expect(t,!bridge_executor_resolve_local(&s,executor.encode(c),changed).resolved)
    bridge_executor_test_set(c,"model","unknown")
    testing.expect(t,!bridge_executor_resolve_local(&s,executor.encode(c),req).resolved)
    bridge_executor_test_set(c,"model","seed")
    testing.expect(t,os.remove(directory)==nil)
    testing.expect(t,!bridge_executor_resolve_local(&s,executor.encode(c),req).resolved)
}

@(test)
bridge_legacy_barrier_prevents_native_first_io_after_signed_local_consent :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    binary:=os.get_env("HEIMDALL_EXECUTOR_TEST_PTY",context.temp_allocator)
    if binary=="" {
        when #config(EXECUTOR_TEST_REQUIRED,false) {testing.fail_now(t,"HEIMDALL_EXECUTOR_TEST_PTY must name the real daemon")}
        else {fmt.eprintln("[skip] local executor proof requires HEIMDALL_EXECUTOR_TEST_PTY");return}
    }
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    suffix:=fmt.tprintf("%d",time.to_unix_nanoseconds(time.now()))
    socket:=fmt.tprintf("/tmp/ham-local-barrier-%s.sock",suffix)
    swap:=pty_host_test_install_socket(socket);defer pty_host_test_restore_socket(swap)
    process,err:=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",socket,"daemon"}})
    if !testing.expect(t,err==nil) do return
    process_live:=true
    defer {if process_live {_=os.process_kill(process);_,_=os.process_wait(process)};_=os.remove(socket)}
    ready:=false
    for _ in 0..<100 {if bridge_pty_host_ping(socket) {ready=true;break};time.sleep(10*time.Millisecond)}
    if !testing.expect(t,ready && bridge_pty_host_local_executor_capable(socket)) do return
    path:=fmt.tprintf("%s/.cache/heimdall-tests/local-barrier-%s.sqlite",os.get_env("HOME",context.temp_allocator),suffix)
    s:executor.Store
    if !testing.expect(t,executor.open(&s,path,"account","executor","operator")) do return
    defer {executor.close(&s);for ext in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,ext))}
    host_private,host:=bridge_executor_test_key("executor","operator",11);defer ecdsa.private_key_clear(&host_private)
    device_private,device:=bridge_executor_test_key("device","device_key",12);defer ecdsa.private_key_clear(&device_private)
    device.kind="device"
    now:=bridge_executor_physical_clock(nil)
    p:=bridge_executor_test_doc("policy")
    testing.expect_value(t,executor.install_policy(&s,bridge_executor_test_sign(p,"policy",&host_private),host,now).code,"ok")
    d:=bridge_executor_test_doc("directory")
    testing.expect_value(t,executor.install_directory(&s,bridge_executor_test_sign(d,"directory",&host_private),host,now,"/repo").code,"ok")
    req:=Pty_Host_Spawn_Request{instance="local_instance",argv=[]string{"sh"},rows=24,cols=80}
    c:=bridge_executor_test_doc("local_configuration")
    bridge_executor_test_set(c,"purpose","warm");bridge_executor_test_set(c,"provider_profile","default")
    bridge_executor_test_set(c,"directory_key",executor.directory_key("executor","/repo"))
    bridge_executor_test_set(c,"spawn_digest",bridge_executor_local_spawn_digest(req))
    configuration:=executor.encode(c)
    resources:=executor.Local_Resources{contracts.owner_payload_digest(configuration),contracts.owner_string(c,"spawn_digest"),"/repo",true}
    o:=bridge_executor_test_doc("local_launch")
    bridge_executor_test_set(o,"configuration_digest",resources.configuration_digest)
    bridge_executor_test_set(o,"issued_ms",fmt.tprintf("%d",now));bridge_executor_test_set(o,"request_expires_ms",fmt.tprintf("%d",now+60000))
    consent:=bridge_executor_test_sign(o,"local_launch",&device_private)
    admitted:=executor.admit_local(&s,consent,configuration,device,now,resources)
    if !testing.expect_value(t,admitted.code,"ok") do return
    v,_:=contracts.owner_content_document(admitted.body);body,_:=v.(json.Object)
    launch,found:=executor.local_launch(&s,contracts.owner_string(body,"launch_id"));testing.expect(t,found)
    barrier:=executor.Legacy_Barrier{"source_chain","migration",contracts.owner_payload_digest("verified selection"),1}
    testing.expect_value(t,bridge_legacy_install_barrier(&s,barrier,[]executor.Legacy_Resource{{"instance",launch.instance}}).code,"ok")
    prepared:=false
    delivered,reason:=bridge_executor_local_dispatch(&s,launch,device,req,resources,socket,
        prepare_ctx=&prepared,prepare=proc(ctx:rawptr)->bool {(^bool)(ctx)^=true;return true})
    testing.expect(t,!delivered && reason=="legacy_fenced" && !prepared)
    listed,read:=bridge_pty_host_list(socket)
    testing.expect(t,read)
    if read {defer pty_host_reply_delete(listed);for agent in listed.agents do testing.expect(t,agent.instance_id!=launch.instance)}
    retained,loaded:=executor.local_launch(&s,launch.id)
    testing.expect(t,loaded && retained.state=="admitted","barrier consumes neither launch authority nor child charge")
    // Normal unfenced native launches/stops still work. Cancel only the
    // undispatched fixture admission, then obtain distinct fresh signed consent.
    testing.expect(t,executor.cancel_local_admission(&s,launch.id))
    req.instance="unfenced_native"
    bridge_executor_test_set(c,"instance_id",req.instance)
    bridge_executor_test_set(c,"spawn_digest",bridge_executor_local_spawn_digest(req))
    configuration=executor.encode(c)
    resources=executor.Local_Resources{contracts.owner_payload_digest(configuration),contracts.owner_string(c,"spawn_digest"),"/repo",true}
    bridge_executor_test_set(o,"operation_id","normal_after_fenced")
    bridge_executor_test_set(o,"configuration_digest",resources.configuration_digest)
    consent=bridge_executor_test_sign(o,"local_launch",&device_private)
    normal_result:=executor.admit_local(&s,consent,configuration,device,bridge_executor_physical_clock(nil),resources)
    if !testing.expect_value(t,normal_result.code,"ok") do return
    normal_doc,_:=contracts.owner_content_document(normal_result.body);normal_body,_:=normal_doc.(json.Object)
    normal,normal_found:=executor.local_launch(&s,contracts.owner_string(normal_body,"launch_id"))
    if !testing.expect(t,normal_found) do return
    delivered,reason=bridge_executor_local_dispatch(&s,normal,device,req,resources,socket)
    if !testing.expect(t,delivered && reason=="child_present") do return
    normal_pid,normal_known:=bridge_pty_host_executor_query(socket,normal.instance,normal.launch_key)
    if !testing.expect(t,normal_known && normal_pid>0) do return
    defer {_=bridge_pty_host_executor_close(socket,normal.instance,normal.launch_key);bridge_shell_test_kill_pid(int(normal_pid))}
    stop_packet:=strings.concatenate({`{"type":"stop_agent","command_id":"native_stop","agent_instance_id":"`,normal.instance,`"}`},context.temp_allocator)
    stop_spec,_:=bridge_command_spec("stop_agent")
    stop_action,stop_prepared:=bridge_legacy_dispatch_prepare(stop_packet,"stop_agent",stop_spec,&s)
    testing.expect(t,stop_prepared)
    stop_job:=Bridge_Dispatch_Job{text=stop_packet,command_type="stop_agent",legacy_action=stop_action}
    testing.expect(t,bridge_legacy_dispatch_start(&stop_job,&s))
    stop_digest:=contracts.owner_payload_digest(stop_packet)
    testing.expect(t,executor.exec(s.db,"CREATE TRIGGER refuse_stop_observation BEFORE INSERT ON executor_legacy_action_effects BEGIN SELECT RAISE(ABORT,'stop journal fault'); END;"))
    testing.expect(t,!bridge_legacy_stop_target(&s,normal.instance,false,stop_action,-1,stop_digest))
    still_pid,still_known:=bridge_pty_host_executor_query(socket,normal.instance,normal.launch_key)
    testing.expect(t,still_known && still_pid==normal_pid,"journal failure leaves the exact native child alive")
    testing.expect(t,executor.exec(s.db,"DROP TRIGGER refuse_stop_observation"))
    testing.expect(t,bridge_legacy_dispatch_end(stop_action,true,&s))
    // The live wake handler must retain the original stop[] entry identity,
    // rather than substituting a synthetic launch/direct-stop packet.
    stop_entry:=fmt.tprintf(`"%s"`,normal.instance)
    wake_packet:=strings.concatenate({`{"type":"wake_agent","payload":{"run":[],"stop":[ `,stop_entry,` ]}}`},context.temp_allocator)
    _,wake_valid:=contracts.owner_content_document(wake_packet)
    testing.expect(t,wake_valid,wake_packet)
    wake_observations,wake_observed:=bridge_legacy_wake_observations(wake_packet)
    testing.expect(t,wake_observed && len(wake_observations)==0,"empty run array remains a valid stop-only wake")
    wake_spec,_:=bridge_command_spec("wake_agent")
    wake_action,wake_prepared:=bridge_legacy_dispatch_prepare(wake_packet,"wake_agent",wake_spec,&s)
    testing.expect(t,wake_prepared)
    wake_job:=Bridge_Dispatch_Job{text=wake_packet,command_type="wake_agent",legacy_action=wake_action}
    testing.expect(t,bridge_legacy_dispatch_start(&wake_job,&s))
    bridge_hub_handle_wake_agent(nil,wake_packet,&s,wake_action)
    stop_rows,stop_read:=executor.query(s.db,"SELECT effect_kind,json_extract(evidence,'$.launch_key'),json_extract(evidence,'$.child_pid'),entry_digest FROM executor_legacy_action_effects")
    testing.expect(t,stop_read && len(stop_rows)==1 && stop_rows[0][0]=="stop" && stop_rows[0][1]==normal.launch_key && stop_rows[0][2]==fmt.tprintf("%d",normal_pid) && stop_rows[0][3]==contracts.owner_payload_digest(stop_entry))
    testing.expect(t,!bridge_legacy_stop_target(&s,normal.instance,false,wake_action,0,contracts.owner_payload_digest(stop_entry)),"historical observation cannot authorize a second physical invocation")
    testing.expect(t,bridge_legacy_dispatch_end(wake_action,true,&s))
    stopped,stopped_known:=bridge_pty_host_executor_query(socket,normal.instance,normal.launch_key)
    testing.expect(t,stopped_known && stopped==0)
    // A child predating the native admission ledger has no authenticated
    // exact close identity. Legacy force-stop must refuse it, not infer drain
    // from the current instance name or send a broad signal.
    unknown:=Pty_Host_Spawn_Request{instance="historical_unknown",argv=[]string{"sh"},rows=24,cols=80}
    unknown_pid,spawned:=bridge_pty_host_spawn(socket,unknown)
    if !testing.expect(t,spawned && unknown_pid>0) do return
    defer {_=bridge_pty_host_close(socket,unknown.instance);bridge_shell_test_kill_pid(int(unknown_pid))}
    testing.expect(t,!bridge_legacy_stop_target(&s,unknown.instance,true))
    current,listed_ok:=bridge_pty_host_list(socket)
    if !testing.expect(t,listed_ok) do return
    defer pty_host_reply_delete(current)
    still_live:=false
    for child in current.agents do if child.instance_id==unknown.instance && child.alive do still_live=true
    testing.expect(t,still_live,"unknown pre-upgrade child remains unresolved and alive")
}
