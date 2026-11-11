#+build !windows
#+feature dynamic-literals
package main
import "base:runtime"
import "core:crypto"
import "core:crypto/ecdsa"
import "core:os"
import "core:fmt"
import "core:testing"
import "core:strings"
import "core:sync"
import "core:time"
import "core:thread"
import "core:net"
import "core:encoding/json"
import channel "odin_test:lib/executor_channel"
import vault "odin_test:lib/vault"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import owner "odin_test:lib/owner_local"
import local_socket "odin_test:lib/local_socket"

@(test)
test_executor_local_native_launch_without_policy_directory_or_approval :: proc(t:^testing.T) {
    bridge_executor_local_native_scenario(t)
}
@(test)
test_executor_local_native_custom_profile_model_dispatch :: proc(t:^testing.T) {
    bridge_executor_local_native_scenario(t,model_mode="custom")
}
@(test)
test_executor_local_native_discovered_profile_model_dispatch :: proc(t:^testing.T) {
    bridge_executor_local_native_scenario(t,model_mode="discovered")
}

bridge_executor_local_native_scenario :: proc(t:^testing.T,model_mode:string="") {
    context.allocator=context.temp_allocator
    st:=p1c_test_setup(t);defer p1c_test_teardown(st)
    {
        context.allocator=runtime.default_allocator()
        bridge_agent_wake_init()
    }
    sync.mutex_lock(&bridge_wake_mutex)
    saved_wakes:=bridge_agent_wake
    bridge_agent_wake=make(map[string]Bridge_Wake_State,allocator=runtime.heap_allocator())
    sync.mutex_unlock(&bridge_wake_mutex)
    defer {
        bridge_agent_wake_reset()
        sync.mutex_lock(&bridge_wake_mutex)
        delete(bridge_agent_wake)
        bridge_agent_wake=saved_wakes
        sync.mutex_unlock(&bridge_wake_mutex)
    }
    // Bootstrap publication uses the scenario allocator, so each scenario
    // must own its map until that allocator is reset by the test runner.
    sync.mutex_lock(&bridge_bootstrap_fileset_mutex)
    saved_filesets:=bridge_bootstrap_filesets
    bridge_bootstrap_filesets=nil
    sync.mutex_unlock(&bridge_bootstrap_fileset_mutex)
    defer {
        sync.mutex_lock(&bridge_bootstrap_fileset_mutex)
        bridge_bootstrap_filesets=saved_filesets
        sync.mutex_unlock(&bridge_bootstrap_fileset_mutex)
    }
    // Legacy fixture issuance uses the test allocator. Keep its records local
    // to this scenario rather than leaving them in the process-global store
    // after the test allocator is reset between parameterized scenarios.
    sync.mutex_lock(&bridge_local_token_mutex)
    saved_tokens:=bridge_local_token_records
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record,allocator=runtime.default_allocator())
    sync.mutex_unlock(&bridge_local_token_mutex)
    defer {
        sync.mutex_lock(&bridge_local_token_mutex)
        current_tokens:=bridge_local_token_records
        bridge_local_token_records=saved_tokens
        sync.mutex_unlock(&bridge_local_token_mutex)
        delete(current_tokens)
    }
    sync.mutex_lock(&keystore_test_mutex);defer sync.mutex_unlock(&keystore_test_mutex)
    id,_:=keystore_test_bridge_ids()
    prior_id:=keystore_test_set_daemon_id(id);defer {bridge_cfg().daemon_id=prior_id}
    keystore_lock_and_purge(id);_=keystore_delete_identity_key(id);bridge_unseal_forget_identity()
    unseal_nonce_cache_clear(&g_unseal_nonce_cache);bridge_unseal_init()
    if !testing.expect(t,test_provision_identity(id)) do return
    defer {keystore_lock_and_purge(id);_=keystore_delete_identity_key(id);bridge_unseal_forget_identity()}
    kr:=test_keyring_from_hex(TEST_VAULT_KEY_HEX);defer vault.keyring_wipe(&kr)
    now:=time.to_unix_nanoseconds(time.now())/1000000
    payload:=test_create_unseal_v2_payload(id,&kr,now,"issuance_mounted_pair")
    unsealed,_:=bridge_unseal_decrypt_and_verify(payload,id,now)
    if !testing.expect(t,unsealed) do return
    get:=contracts.owner_string
    // Until the real daemon is started below, every pty-host dial goes to an
    // absent test socket (never a live Bridge's daemon).
    absent:=fmt.tprintf("/tmp/ham-native-absent-%d.sock",time.to_unix_nanoseconds(time.now()))
    absent_swap:=pty_host_test_install_socket(absent);defer pty_host_test_restore_socket(absent_swap)
    prior_root:=bridge_fs_root;root:=bridge_fs_canonicalize_existing(st.dir);defer delete(root)
    bridge_fs_root=root;defer {bridge_fs_root=prior_root}
    work:=fmt.tprintf("%s/work",root);testing.expect(t,os.make_directory(work)==nil)
    public:=bridge_identity_public_key_hex(id);key_id,_:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !testing.expect(t,bridge_executor_open(TEST_VAULT_USER_ID,key_id)) do return
    defer {
        executor.close(&bridge_executor_store)
        dir,found:=bridge_vault_bridge_dir(id,context.temp_allocator)
        if found do _=os.remove_all(fmt.tprintf("%sexecutor-local-%s",dir,contracts.owner_payload_digest(TEST_VAULT_USER_ID)))
    }
    identity_record:Bridge_Identity_Record
    if !testing.expect(t,keystore_read_identity(id,&identity_record)==.Found) do return
    defer crypto.zero_explicit(&identity_record,size_of(identity_record))
    selected_profile:="claude" if model_mode=="" else "claude_selected"
    selected_model:="seed"
    if model_mode=="custom" do selected_model="custom-review-model"
    if model_mode=="discovered" do selected_model="profile-only-model"
    policy:=bridge_executor_test_doc("policy")
    bridge_executor_test_set(policy,"account_id",TEST_VAULT_USER_ID);bridge_executor_test_set(policy,"executor_bridge_id",id)
    bridge_executor_test_set(policy,"key_id",key_id)
    bridge_executor_test_set(policy,"slots_json",executor.encode([]struct{slot_id,provider_profile,enabled:string}{{"slot1",selected_profile,"1"}}))
    // The host-operator CLI still signs/imports policy records (used by the
    // cross-Bridge reservation path). Ordinary local launches never read them.
    _=bridge_executor_test_operator_provision(t,"policy",executor.encode(policy),root)
    forged:=policy;forged["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    forged_params:=struct{kind,document:string}{"policy",executor.encode(forged)}
    forged_wire:=executor.encode(struct{v:int,id,method,token:string,params:type_of(forged_params)}{1,"forged","executor.operator.install","agent-token-is-not-operator",forged_params})
    rejection:=bridge_local_endpoint_handle_jsonl_line(forged_wire)
    testing.expect(t,strings.contains(rejection,"invalid_scope"),"agent transport cannot replace pinned operator signature")
    sign_wire:=executor.encode(struct{v:int,id,method,token:string,params:type_of(forged_params)}{1,"no-sign-rpc","executor.operator.sign","agent-token-is-not-operator",forged_params})
    testing.expect(t,strings.contains(bridge_local_endpoint_handle_jsonl_line(sign_wire),"unauthenticated"),"no signing RPC")
    old_run_dir:=bridge_cfg().local_endpoint_run_dir
    bridge_cfg().local_endpoint_run_dir=fmt.tprintf("%s/runtime",root)
    defer {bridge_cfg().local_endpoint_run_dir=old_run_dir}
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/instances",bridge_cfg().local_endpoint_run_dir))==nil)
    pp:=Provider_Profile{profile_id=selected_profile,provider="claude",enabled=true,config=Provider_Profile_Config{binary_path="/bin/sh"}}
    if model_mode=="custom" do pp.config.custom_models=[]string{selected_model}
    bridge_provider_catalog_snapshot.providers[0].model_flag="-s"
    testing.expect_value(t,profile_upsert(&pp,nil,now),Profile_Error.None)
    if model_mode=="discovered" {
        bridge_models_save(Bridge_Provider_Models{provider="claude",profile_id=selected_profile,has_snapshot=true,
            models=[]Bridge_Discovered_Model{{model_id=selected_model,label=selected_model}}})
    }
    variant:=model_mode if model_mode!="" else "default"
    // Unsupported provider and disabled catalog entries are still refused
    // before any draft, token or bootstrap is created.
    unsupported:=executor.encode(struct{type,agent_instance_id,provider,model,provider_profile:string,run_count:int}{
        "launch_provider_test","native_unsupported","nonexistent","seed","nonexistent",1})
    refused,refusal,refusal_err:=bridge_runtime_launch_provider_test("unsupported",unsupported)
    testing.expect(t,!refused && refusal_err.reason==.unsupported,refusal)
    unknown_model:=executor.encode(struct{type,agent_instance_id,provider,model,provider_profile:string,run_count:int}{
        "launch_provider_test","native_unknown_model","claude","not-a-model",selected_profile,1})
    refused,refusal,refusal_err=bridge_runtime_launch_provider_test("unknown_model",unknown_model)
    testing.expect(t,!refused && strings.contains(refusal,"model") && refusal_err.class==.retriable,refusal)
    // A project outside the Bridge filesystem root is still refused.
    outside:=bridge_fs_canonicalize_existing(fmt.tprintf("%s/..",root));defer delete(outside)
    outside_cmd:=bridge_wake_launch_command_json("outside","native_outside","","worker","claude",selected_model,"native_agent","Native agent","","","","",outside,
        run_count=1,provider_profile=selected_profile,launch_epoch="outside_epoch")
    refused,refusal,refusal_err=bridge_runtime_launch_agent("outside",outside_cmd)
    testing.expect(t,!refused && refusal_err.reason==.denied && strings.contains(refusal,"filesystem root"),refusal)
    // A superseded generation is still refused.
    _=bridge_agent_token_issue("native_superseded","superseded-assertion",.Agent,3)
    superseded:=executor.encode(struct{type,agent_instance_id,provider,model,provider_profile:string,run_count:int}{
        "launch_provider_test","native_superseded","claude",selected_model,selected_profile,2})
    refused,refusal,_=bridge_runtime_launch_provider_test("superseded",superseded)
    testing.expect_value(t,refusal,"superseded startup generation")
    testing.expect(t,!refused)
    for refused_instance in ([4]string{"native_unsupported","native_unknown_model","native_outside","native_superseded"}) {
        rows,_:=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_local_drafts WHERE json_extract(configuration,'$.instance_id')=?",refused_instance)
        testing.expect_value(t,rows[0][0],"0")
    }

    instance:=fmt.tprintf("native_local_%s",variant)
    command_json:=executor.encode(struct{type,command_id,agent_instance_id,provider,model,provider_profile:string,run_count:int}{
        "launch_provider_test","native_first",instance,"claude",selected_model,selected_profile,1})
    run_dir:=bridge_runtime_default_run_dir(instance);defer delete(run_dir)
    testing.expect(t,bridge_make_directory_all(run_dir)==nil)
    marker:=fmt.tprintf("%s/keep.txt",run_dir)
    testing.expect(t,os.write_entire_file(marker,"previous-bootstrap")==nil)
    previous:=bridge_agent_token_issue(instance,"old-hub-assertion",.Agent,0)
    // No policy, slot or directory mapping exists and nobody approves: the
    // Bridge stages and admits the exact generation itself. Without a daemon
    // the dispatch is uncertain, before any token/bootstrap mutation.
    probe:=Executor_Local_Test_IO{socket=absent}
    staged,detail,stage_err:=bridge_executor_local_stage(command_json,"provider_test",{&probe,bridge_executor_local_test_files,absent})
    if !staged do bridge_executor_local_note_failure(command_json,detail,stage_err)
    testing.expect(t,!staged)
    testing.expect_value(t,detail,"executor_uncertain")
    testing.expect(t,!strings.contains(detail,"launch_authorization_required") && !strings.contains(detail,"selection_required"))
    draft,found:=executor.local_draft_source(&bridge_executor_store,bridge_executor_local_source(command_json,"provider_test"))
    if !testing.expect(t,found && draft.state=="authorized" && draft.launch_id!="") do return
    first_launch,_:=executor.local_launch(&bridge_executor_store,draft.launch_id)
    testing.expect_value(t,first_launch.state,"admitted")
    m,material_ok:=bridge_executor_local_material(draft)
    testing.expect(t,material_ok && len(m.token)==69 && m.assertion=="" && m.run_count==1)
    _,old_valid:=bridge_agent_token_verify(previous.plaintext_token)
    _,new_active:=bridge_agent_token_verify(m.token)
    testing.expect(t,old_valid && !new_active && os.exists(marker),"an undispatched admission is inert")
    rows,_:=executor.query(bridge_executor_store.db,"SELECT (SELECT count(*) FROM executor_policies),(SELECT count(*) FROM executor_directories),(SELECT count(*) FROM executor_live_resources)")
    testing.expect_value(t,encode_rows(rows),"1|0|0")
    changed_transport,_:=strings.replace_all(command_json,"native_first","native_second",context.temp_allocator)
    _,retry_detail,_:=bridge_executor_local_stage(changed_transport,"provider_test",{&probe,bridge_executor_local_test_files,absent})
    testing.expect_value(t,retry_detail,detail)
    retained,_:=executor.local_draft_source(&bridge_executor_store,bridge_executor_local_source(changed_transport,"provider_test"))
    testing.expect(t,retained.material==draft.material && retained.launch_id==draft.launch_id,"a retry reuses the generation and its single admission")
    rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_local_launches WHERE instance_id=?",instance)
    testing.expect_value(t,rows[0][0],"1")
    // A disabled catalog entry is refused at the dispatch boundary too.
    probe.disable_catalog=true
    next_command,_:=strings.replace_all(command_json,`"run_count":1`,`"run_count":2`,context.temp_allocator)
    disabled,disabled_detail,disabled_err:=bridge_executor_local_stage(next_command,"provider_test",{&probe,bridge_executor_local_test_files,absent})
    testing.expect(t,!disabled && disabled_detail=="provider profile unavailable" && disabled_err.class==.recoverable,disabled_detail)
    bridge_provider_catalog_snapshot.providers[0].state="active"
    probe.disable_catalog=false
    _,old_valid=bridge_agent_token_verify(previous.plaintext_token)
    testing.expect(t,old_valid && os.exists(marker))
    // Restart with the first generation still only admitted: reopening the
    // journal releases it, and a retry of that generation is a fatal (never
    // auto-retried) "generation already ran" instead of a stuck instance.
    executor.close(&bridge_executor_store)
    if !testing.expect(t,bridge_executor_open(TEST_VAULT_USER_ID,key_id)) do return
    reopened,_:=executor.local_launch(&bridge_executor_store,first_launch.id)
    testing.expect_value(t,reopened.state,"released")
    closed,closed_detail,closed_err:=bridge_executor_local_stage(command_json,"provider_test",{&probe,bridge_executor_local_test_files,absent})
    testing.expect(t,!closed && strings.contains(closed_detail,"already ran") && closed_err.class==.fatal,closed_detail)
    rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_local_launches WHERE instance_id=? AND state!='released'",instance)
    testing.expect_value(t,rows[0][0],"0")
    // A generation staged before the restart but never admitted is closed too.
    stale,stale_detail,stale_err:=bridge_executor_local_stage(next_command,"provider_test",{&probe,bridge_executor_local_test_files,absent})
    testing.expect(t,!stale && strings.contains(stale_detail,"already ran") && stale_err.class==.fatal,stale_detail)

    binary:=bridge_env_get("HEIMDALL_EXECUTOR_TEST_PTY",context.temp_allocator)
    if binary=="" {
        when #config(EXECUTOR_TEST_REQUIRED,false) {testing.fail_now(t,"real native dispatch requires HEIMDALL_EXECUTOR_TEST_PTY")}
        else {fmt.eprintln("[skip] native actual-launch proof requires HEIMDALL_EXECUTOR_TEST_PTY");return}
    }
    socket:=fmt.tprintf("/tmp/ham-native-local-%d.sock",time.to_unix_nanoseconds(time.now()))
    swap:=pty_host_test_install_socket(socket);defer pty_host_test_restore_socket(swap)
    daemon,daemon_error:=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",socket,"daemon"}})
    if !testing.expect(t,daemon_error==nil) do return
    defer {_=os.process_kill(daemon);_,_=os.process_wait(daemon);_=os.remove(socket)}
    daemon_ready:=false
    for _ in 0..<100 {if bridge_pty_host_ping(socket) {daemon_ready=true;break};time.sleep(10*time.Millisecond)}
    if !testing.expect(t,daemon_ready) do return
    probe.socket=socket
    live_command,_:=strings.replace_all(command_json,`"run_count":1`,`"run_count":3`,context.temp_allocator)
    // The native endpoint is already running in production. Keep this hermetic
    // provider-test child isolated from the host Bridge's listeners and vault.
    saved_started,saved_endpoint:=bridge_runtime_local_endpoint_started,bridge_runtime_local_endpoint_descriptor
    bridge_runtime_local_endpoint_started=true;bridge_runtime_local_endpoint_descriptor=m.endpoint
    defer {bridge_runtime_local_endpoint_started=saved_started;bridge_runtime_local_endpoint_descriptor=saved_endpoint}
    old_ctl,had_ctl:=bridge_env_lookup("HEIMDALL_HAM_CTL_BIN",context.temp_allocator)
    bridge_test_env_set("HEIMDALL_HAM_CTL_BIN","/bin/sh")
    defer {if had_ctl {bridge_test_env_set("HEIMDALL_HAM_CTL_BIN",old_ctl)} else {bridge_test_env_unset("HEIMDALL_HAM_CTL_BIN")}}
    // A newer generation releases the undispatched first admission and starts
    // the exact child with no approval.
    // Force a lost local observation after the physical Spawn. The committed
    // admission must never cause a second Spawn.
    testing.expect(t,executor.exec(bridge_executor_store.db,"CREATE TRIGGER fail_native_observe BEFORE INSERT ON executor_local_observations BEGIN SELECT RAISE(ABORT,'lost native observation'); END"))
    launched,launch_detail,_:=bridge_executor_local_stage(live_command,"provider_test",{&probe,bridge_executor_local_test_files,socket})
    testing.expect(t,!launched && launch_detail=="observation_not_committed",launch_detail)
    released,_:=executor.local_launch(&bridge_executor_store,first_launch.id)
    testing.expect_value(t,released.state,"released")
    draft,found=executor.local_draft_source(&bridge_executor_store,bridge_executor_local_source(live_command,"provider_test"))
    if !testing.expect(t,found && draft.launch_id!="") do return
    m,material_ok=bridge_executor_local_material(draft)
    testing.expect(t,material_ok && m.run_count==3)
    launch,_:=executor.local_launch(&bridge_executor_store,draft.launch_id)
    pid,known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    if !testing.expect(t,known && pid>0) do return
    defer {_=bridge_pty_host_executor_close(socket,launch.instance,launch.launch_key);bridge_shell_test_kill_pid(int(pid))}
    _,old_valid=bridge_agent_token_verify(previous.plaintext_token)
    _,new_active=bridge_agent_token_verify(m.token)
    testing.expect(t,!old_valid,"native dispatch invalidates previous token")
    testing.expect(t,new_active,"native dispatch activates the retained random token")
    testing.expect(t,!os.exists(marker),"native dispatch replaces previous bootstrap")
    testing.expect(t,executor.exec(bridge_executor_store.db,"DROP TRIGGER fail_native_observe"))
    resumed,_,_:=bridge_executor_local_stage(live_command,"provider_test",{&probe,bridge_executor_local_test_files,socket})
    testing.expect(t,resumed,"native retry observes the exact child")
    same_pid,same_known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    testing.expect(t,same_known && same_pid==pid,"native retry cannot replace the exact live child")
    // Native launches hold no policy charge: operator reallocation needs no drain.
    busy_policy:=policy;busy_policy["policy_revision"]=json.String("2")
    signed_busy,busy_signed:=bridge_executor_operator_sign_record("policy",executor.encode(busy_policy))
    testing.expect_value(t,busy_signed,"ok")
    busy_params:=executor.encode(struct{kind,document:string}{"policy",signed_busy})
    busy_reply:=bridge_executor_operator_handle("busy-policy","executor.operator.install",busy_params)
    testing.expect(t,!strings.contains(busy_reply,"resources_not_drained"),busy_reply)
    // task_18e70f303f8384fe: a newer generation for the same live instance (a
    // restart) stops and releases the old child, then starts at once; it never
    // loops on instance_not_drained.
    third_command,_:=strings.replace_all(command_json,`"run_count":1`,`"run_count":4`,context.temp_allocator)
    unblocked,unblocked_detail,_:=bridge_executor_local_stage(third_command,"provider_test",{&probe,bridge_executor_local_test_files,socket})
    testing.expect(t,unblocked,unblocked_detail)
    rows,_=executor.query(bridge_executor_store.db,"SELECT state FROM executor_local_launches WHERE launch_id=?",launch.id);testing.expect_value(t,rows[0][0],"released")
    stopped,stopped_known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    testing.expect(t,stopped_known && stopped==0,"the old live child was stopped")
    third_draft,third_found:=executor.local_draft_source(&bridge_executor_store,bridge_executor_local_source(third_command,"provider_test"))
    if testing.expect(t,third_found && third_draft.launch_id!="") {
        third_launch,_:=executor.local_launch(&bridge_executor_store,third_draft.launch_id)
        third_pid,third_known:=bridge_pty_host_executor_query(socket,third_launch.instance,third_launch.launch_key)
        testing.expect(t,third_known && third_pid>0)
        testing.expect(t,executor.stop_local_launch(&bridge_executor_store,third_launch))
        _,_=bridge_executor_local_reconcile_batch(&bridge_executor_store,socket,"")
        if third_pid>0 do bridge_shell_test_kill_pid(int(third_pid))
    }

    // Ordinary manual launch uses the real conditional bootstrap HTTP path,
    // cached content-addressed template, native materializer and daemon Spawn.
    http_listener,http_error:=net.listen_tcp(net.Endpoint{address=net.IP4_Loopback,port=0})
    if !testing.expect(t,http_error==nil) do return
    defer net.close(http_listener)
    _=net.set_option(http_listener,.Receive_Timeout,5*time.Second)
    bound,_:=net.bound_endpoint(http_listener)
    old_url,old_credential:=bridge_cfg().daemon_url,bridge_cfg().bridge_token
    bridge_cfg().daemon_url=fmt.tprintf("http://127.0.0.1:%d",bound.port);bridge_cfg().bridge_token="isolated-test-only"
    defer {bridge_cfg().daemon_url=old_url;bridge_cfg().bridge_token=old_credential}
    old_cache:=bootstrap_global_cache;bootstrap_global_cache={}
    bootstrap_cache_init(&bootstrap_global_cache,fmt.tprintf("%s/native-cache",root),1024*1024)
    defer {bootstrap_global_cache=old_cache}
    template:="# Approved native manual agent\nUse the protected workspace.\n"
    hash:=test_bootstrap_sha256(template)
    testing.expect(t,bootstrap_cache_put(&bootstrap_global_cache,hash,template))
    Http :: struct{listener:net.TCP_Socket,hash:string,served:bool}
    http:=Http{http_listener,hash,false}
    http_worker:=bridge_thread_start_with_data(&http,proc(ctx:rawptr) {
        context.allocator=context.temp_allocator
        p:=(^Http)(ctx)
        client,_,err:=net.accept_tcp(p.listener);if err!=nil do return
        defer net.close(client)
        _=net.set_option(client,.Receive_Timeout,5*time.Second)
        buffer:[8192]byte;n,_:=net.recv_tcp(client,buffer[:]);if n<=0 do return
        manifest:=strings.concatenate({`{"protocol":2,"version":"native-proof","agent_id":"native_agent","files":[{"kind":"AGENTS_MD","relative_path":"CLAUDE.md","assembly":[]}],"template":{"kind":"AGENTS_TEMPLATE","hash":"`,p.hash,`"},"variables":[]}`},context.temp_allocator)
        body:=strings.concatenate({`{"data":`,manifest,"}"},context.temp_allocator)
        response:=fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",len(body),body)
        _,_=net.send_tcp(client,transmute([]byte)response);p.served=true
    })
    defer {thread.join(http_worker);thread.destroy(http_worker)}
    manual_instance:=fmt.tprintf("native_manual_%s",variant)
    manual:=bridge_wake_launch_command_json("manual",manual_instance,"","worker","claude",selected_model,"native_agent","Native agent","","","","",work,
        run_count=1,provider_profile=selected_profile,instance_token="isolated-hub-assertion",launch_epoch="native_epoch")
    // An ordinary manual launch from the conversation page starts directly.
    ready,manual_detail,_:=bridge_runtime_launch_agent("manual",manual)
    if !testing.expect(t,ready,manual_detail) do return
    testing.expect(t,http.served)
    manual_draft,manual_found:=executor.local_draft_source(&bridge_executor_store,bridge_executor_local_source(manual,"manual"))
    if !testing.expect(t,manual_found) do return
    manual_current,_:=executor.local_draft_native(&bridge_executor_store,manual_draft.id)
    manual_launch,_:=executor.local_launch(&bridge_executor_store,manual_current.launch_id)
    manual_pid,manual_known:=bridge_pty_host_executor_query(socket,manual_launch.instance,manual_launch.launch_key)
    if !testing.expect(t,manual_known && manual_pid>0) do return
    defer {_=bridge_pty_host_executor_close(socket,manual_launch.instance,manual_launch.launch_key);bridge_shell_test_kill_pid(int(manual_pid))}
    material,_:=bridge_executor_local_material(manual_draft)
    instructions,instructions_read:=os.read_entire_file(fmt.tprintf("%s/CLAUDE.md",material.run_dir),context.temp_allocator)
    testing.expect(t,instructions_read==nil && strings.contains(string(instructions),"Approved native manual agent"))
    // Lose the projection, then ordinary warm transport reuses the exact native
    // generation and original material; it never spawns a second child.
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id==manual_launch.instance {inst.startup.generation=0;inst.pty_process_alive=false}
    sync.mutex_unlock(&bridge_runtime_mutex)
    warm:=bridge_wake_launch_command_json("warm",manual_launch.instance,"","worker","claude",selected_model,"native_agent","Native agent","","","","",work,
        pack_json=`{"delivery":"new task context"}`,run_count=1,provider_profile=selected_profile,instance_token="isolated-hub-assertion",launch_epoch="native_epoch")
    ready,_,_=bridge_executor_local_stage(warm,"warm",{&probe,bridge_executor_local_test_files,socket})
    testing.expect(t,ready)
    same_pid,same_known=bridge_pty_host_executor_query(socket,manual_launch.instance,manual_launch.launch_key)
    testing.expect(t,same_known && same_pid==manual_pid)
    recovered,projection:=bridge_runtime_instance_snapshot(manual_launch.instance)
    testing.expect(t,projection && recovered.startup.generation>0 && recovered.startup.pty_pid==manual_pid && recovered.startup.armed_at_ms>0)
    // Observe exact native presence before an incoming live-child task nudge.
    nudge_entry:=executor.encode(struct{agent_instance_id,task_id:string,run_count:int}{manual_launch.instance,"nudge_task",1})
    nudge_parent:=strings.concatenate({`{"type":"wake_agent","payload":{"run":[`,nudge_entry,`]}}`},context.temp_allocator)
    nudge_spec,_:=bridge_command_spec("wake_agent")
    nudge_action,nudge_prepared:=bridge_legacy_dispatch_prepare(nudge_parent,"wake_agent",nudge_spec,&bridge_executor_store)
    testing.expect(t,nudge_prepared)
    nudge_job:=Bridge_Dispatch_Job{text=nudge_parent,command_type="wake_agent",legacy_action=nudge_action}
    testing.expect(t,bridge_legacy_dispatch_start(&nudge_job,&bridge_executor_store))
    nudge_digest:=contracts.owner_payload_digest(nudge_entry)
    testing.expect(t,bridge_wake_nudge_live_child(manual_launch.instance,"nudge_task","worker","nudge_lease",1,`{"task_id":"nudge_task"}`,&bridge_executor_store,
        observation_action=nudge_action,observation_entry_index=0,observation_entry_digest=nudge_digest))
    testing.expect(t,bridge_legacy_dispatch_end(nudge_action,true,&bridge_executor_store))
    nudge_rows,nudge_read:=executor.query(bridge_executor_store.db,"SELECT launch_key,child_pid,entry_digest FROM executor_legacy_action_nudges WHERE action_id=?",fmt.tprintf("%d",nudge_action.id))
    testing.expect(t,nudge_read && len(nudge_rows)==1 && nudge_rows[0][0]==manual_launch.launch_key && executor.number(nudge_rows[0][1])==i64(manual_pid) && nudge_rows[0][2]==nudge_digest,
        "actual native key query and durable presence precede task pack and keystroke")
    context_before,context_err:=os.read_entire_file(fmt.tprintf("%s/TASK.md",material.run_dir),context.temp_allocator)
    testing.expect(t,context_err==nil)
    testing.expect(t,executor.exec(bridge_executor_store.db,"CREATE TRIGGER fail_nudge_observation BEFORE INSERT ON executor_legacy_action_nudges BEGIN SELECT RAISE(ABORT,'test persistence fault'); END;"))
    refused_action,refused_prepared:=bridge_legacy_dispatch_prepare(nudge_parent,"wake_agent",nudge_spec,&bridge_executor_store)
    testing.expect(t,refused_prepared)
    nudge_job.legacy_action=refused_action
    testing.expect(t,bridge_legacy_dispatch_start(&nudge_job,&bridge_executor_store))
    testing.expect(t,bridge_wake_nudge_live_child(manual_launch.instance,"nudge_task","worker","refused_lease",1,`{"task_id":"refused_task"}`,&bridge_executor_store,
        observation_action=refused_action,observation_entry_index=0,observation_entry_digest=nudge_digest))
    testing.expect(t,bridge_legacy_dispatch_end(refused_action,true,&bridge_executor_store))
    context_after,context_after_err:=os.read_entire_file(fmt.tprintf("%s/TASK.md",material.run_dir),context.temp_allocator)
    testing.expect(t,context_after_err==nil && string(context_before)==string(context_after),"failed exact nudge observation leaves live task context unchanged")
    same_pid,same_known=bridge_pty_host_executor_query(socket,manual_launch.instance,manual_launch.launch_key)
    testing.expect(t,same_known && same_pid==manual_pid,"refused nudge never falls through to replacing the child")
    testing.expect(t,executor.exec(bridge_executor_store.db,"DROP TRIGGER fail_nudge_observation"))
    binary_fixture:=bridge_test_dispatch_save()
    defer bridge_test_dispatch_restore(binary_fixture)
    binary_counter:=test_pty_input_next_counter()
    binary_salt:[vault.PTY_V2_SALT_BYTES]byte
    crypto.rand_bytes(binary_salt[:])
    binary_cipher,binary_sealed:=test_pty_input_payload_with("",TEST_VAULT_KEY_HEX,1,manual_launch.instance,binary_salt,binary_counter,bridge_unseal_boot_id())
    testing.expect(t,binary_sealed)
    binary_frame:=contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_INPUT,contracts.PTY_WIRE_FLAG_ENCRYPTED,manual_launch.instance,binary_cipher,context.temp_allocator)
    binary_action,binary_fenced:=bridge_test_binary_execute(t,&bridge_executor_store,binary_frame)
    testing.expect(t,binary_action.id>0 && !binary_fenced)
    sync.mutex_lock(&bridge_pty_input_replay_mu)
    replay_after_binary,binary_seen:=bridge_pty_input_replay[manual_launch.instance]
    sync.mutex_unlock(&bridge_pty_input_replay_mu)
    binary_counter_seen:=false
    for entry in replay_after_binary.entries do if entry.used && entry.salt==binary_salt && entry.last==binary_counter do binary_counter_seen=true
    testing.expect(t,binary_seen && binary_counter_seen,"actual native worker opens the unchanged encrypted binary frame")
    testing.expect(t,len(bridge_dispatch_outputs)==0,"successful native binary input has no synthetic command result")
    // Startup reminders are a separate physical producer. Match the exact
    // retained native material/run/child and refuse a current migration fence.
    sync.mutex_lock(&bridge_executor_mutex)
    sync.mutex_lock(&bridge_startup_io_mutex)
    startup_current,startup_exists:=bridge_runtime_instance_snapshot(manual_launch.instance)
    testing.expect(t,startup_exists)
    sync.mutex_lock(&bridge_legacy_physical_mutex)
    testing.expect(t,bridge_legacy_startup_input_allowed_locked(&bridge_executor_store,startup_current,socket),"native startup producer matches current exact child and resources")
    startup_changed:=startup_current
    startup_changed.startup.pty_pid+=1
    testing.expect(t,!bridge_legacy_startup_input_allowed_locked(&bridge_executor_store,startup_changed,socket),"replacement PID cannot inherit a startup write")
    startup_changed=startup_current
    startup_changed.startup.rec.run_count+=1
    testing.expect(t,!bridge_legacy_startup_input_allowed_locked(&bridge_executor_store,startup_changed,socket),"changed run cannot inherit a startup write")
    sync.mutex_unlock(&bridge_legacy_physical_mutex)
    startup_barrier:=executor.Legacy_Barrier{"startup_source","startup_migration",contracts.owner_payload_digest("startup selection"),0}
    canonical_startup_dir,startup_dir_known:=bridge_executor_canonical_directory(material.run_dir)
    testing.expect(t,startup_dir_known)
    testing.expect_value(t,bridge_legacy_install_barrier(&bridge_executor_store,startup_barrier,[]executor.Legacy_Resource{{"workdir_hash",contracts.owner_payload_digest(canonical_startup_dir)}}).code,"ok")
    sync.mutex_lock(&bridge_legacy_physical_mutex)
    testing.expect(t,!bridge_legacy_startup_input_allowed_locked(&bridge_executor_store,startup_current,socket),"generation-zero barrier blocks reminder to a surviving child")
    sync.mutex_unlock(&bridge_legacy_physical_mutex)
    sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.mutex_unlock(&bridge_executor_mutex)
    testing.expect(t,bridge_wake_nudge_live_child(manual_launch.instance,"unfenced_task_claim","worker","unfenced_lease_claim",1,`{"task_id":"must_not_replace_context"}`,&bridge_executor_store),
        "shared native resource refusal handles wake without replacement fallback")
    protected_context,protected_context_err:=os.read_entire_file(fmt.tprintf("%s/TASK.md",material.run_dir),context.temp_allocator)
    testing.expect(t,protected_context_err==nil && string(protected_context)==string(context_after),"pack with no placement cannot hide the current native protected directory")
    for kind in ([4]Bridge_Legacy_Agent_Delivery_Kind{.Message,.Task_Nudge,.Notice,.Resize}) {
        delivered_notice,refused_notice:=bridge_legacy_agent_delivery({kind=kind,instance=manual_launch.instance,text="must not reach child",rows=30,cols=100},&bridge_executor_store,socket)
        testing.expect(t,!delivered_notice && refused_notice,"queued/rollover producer cannot bypass the migration barrier or replace a child")
    }
    same_pid,same_known=bridge_pty_host_executor_query(socket,manual_launch.instance,manual_launch.launch_key)
    testing.expect(t,same_known && same_pid==manual_pid,"refused alternate inputs keep the exact surviving child")
    later_counter:=test_pty_input_next_counter()
    later_cipher,later_sealed:=test_pty_input_payload_with("",TEST_VAULT_KEY_HEX,1,manual_launch.instance,binary_salt,later_counter,bridge_unseal_boot_id())
    testing.expect(t,later_sealed)
    later_frame:=contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_INPUT,contracts.PTY_WIRE_FLAG_ENCRYPTED,manual_launch.instance,later_cipher,context.temp_allocator)
    later_action,later_fenced:=bridge_test_binary_execute(t,&bridge_executor_store,later_frame)
    testing.expect(t,later_action.id>0 && later_fenced,"installed migration barrier refuses native binary input before decryption or PTY I/O")
    sync.mutex_lock(&bridge_pty_input_replay_mu)
    replay_after_refusal:=bridge_pty_input_replay[manual_launch.instance]
    sync.mutex_unlock(&bridge_pty_input_replay_mu)
    testing.expect(t,replay_after_refusal==replay_after_binary,"refused worker does not consume the later encrypted input counter")
    binary_rows,binary_read:=executor.query(bridge_executor_store.db,"SELECT command_id,chain_claim,state FROM executor_legacy_actions WHERE command_kind=? ORDER BY action_id",BRIDGE_DISPATCH_BINARY_INPUT_KIND)
    testing.expect(t,binary_read && len(binary_rows)==2 && binary_rows[0][0]=="" && binary_rows[0][1]=="" && binary_rows[0][2]=="returned" && binary_rows[1][2]=="discarded")
    // Exact stop and reconciliation release the manual child.
    manual_live,_:=executor.local_launch(&bridge_executor_store,manual_launch.id)
    testing.expect(t,executor.stop_local_launch(&bridge_executor_store,manual_live))
    _,reconciled:=bridge_executor_local_reconcile_batch(&bridge_executor_store,socket,"")
    testing.expect(t,reconciled)
    rows,_=executor.query(bridge_executor_store.db,"SELECT state FROM executor_local_launches WHERE launch_id=?",manual_launch.id)
    testing.expect_value(t,rows[0][0],"released")
    {
    // The bootstrap server served its one manual request. Refuse further
    // manifest fetches immediately instead of waiting on a closed backlog.
    bridge_cfg().daemon_url="http://127.0.0.1:1"
    // Actual wake ingress must retain the original parent/entry bytes in
    // the immutable native draft.
    observed_instance:=fmt.tprintf("native_observed_%s",variant)
    proposed:=bridge_wake_launch_command_json("proposed",observed_instance,"observed_task","worker","claude",selected_model,"native_agent","Observed agent","legacy_chain","Legacy","","",work,
        lease_id="observed_lease",pack_json=`{"n":9007199254740993}`,run_count=1,provider_profile=selected_profile,instance_token="isolated-hub-assertion",launch_epoch="observed_epoch")
    raw_entry,entry_ok:=contracts.owner_content_member_bytes(proposed,"payload")
    if !testing.expect(t,entry_ok) do return
    parent:=strings.concatenate({` {"type":"wake_agent","command_id":"observed_parent","chain_id":"legacy_chain","payload":{"run":[ `,raw_entry,` ],"stop":[]}} `},context.temp_allocator)
    observed_spec,_:=bridge_command_spec("wake_agent")
    action,action_prepared:=bridge_legacy_dispatch_prepare(parent,"wake_agent",observed_spec,&bridge_executor_store)
    testing.expect(t,action_prepared)
    observed_job:=Bridge_Dispatch_Job{text=parent,command_type="wake_agent",legacy_action=action}
    testing.expect(t,bridge_legacy_dispatch_start(&observed_job,&bridge_executor_store))
    bridge_hub_handle_wake_agent(nil,parent,&bridge_executor_store,observation_action=action)
    testing.expect(t,bridge_legacy_dispatch_end(action,true,&bridge_executor_store))
    observed_draft,observed_found:=executor.local_draft_source(&bridge_executor_store,bridge_executor_local_source(proposed,"warm"))
    if !testing.expect(t,observed_found,"actual wake stages immutable observed draft") do return
    observed_material,observed_ok:=bridge_executor_local_material(observed_draft)
    testing.expect(t,observed_ok && observed_material.origin.version=="1" && observed_material.origin.account==bridge_executor_store.account)
    testing.expect_value(t,observed_material.origin.parent_digest,contracts.owner_payload_digest(parent))
    testing.expect_value(t,observed_material.origin.entry_digest,contracts.owner_payload_digest(raw_entry))
    testing.expect_value(t,observed_material.origin.native_command_digest,contracts.owner_payload_digest(observed_material.command))
    testing.expect(t,strings.contains(observed_material.command,"9007199254740993"),"synthetic pack keeps unsafe integer token intact")
    second_parent,_:=strings.replace_all(parent,"observed_parent","later_parent",context.temp_allocator)
    later_action,later_prepared:=bridge_legacy_dispatch_prepare(second_parent,"wake_agent",observed_spec,&bridge_executor_store)
    testing.expect(t,later_prepared)
    observed_job.legacy_action=later_action;observed_job.text=second_parent
    testing.expect(t,bridge_legacy_dispatch_start(&observed_job,&bridge_executor_store))
    bridge_hub_handle_wake_agent(nil,second_parent,&bridge_executor_store,observation_action=later_action)
    testing.expect(t,bridge_legacy_dispatch_end(later_action,true,&bridge_executor_store))
    same_draft,same_draft_found:=executor.local_draft_source(&bridge_executor_store,bridge_executor_local_source(proposed,"warm"))
    testing.expect(t,same_draft_found && same_draft.id==observed_draft.id && same_draft.material==observed_draft.material,"later source claim cannot rewrite the first retained observation")
    associations,associations_read:=executor.query(bridge_executor_store.db,"SELECT parent_command_id,parent_digest,entry_digest FROM executor_legacy_observations WHERE draft_id=? ORDER BY parent_command_id",observed_draft.id)
    testing.expect(t,associations_read && len(associations)==2,"actual retry retains both original packet associations independently of first material")
    if len(associations)==2 {
        testing.expect_value(t,associations[0][0],"later_parent")
        testing.expect_value(t,associations[0][1],contracts.owner_payload_digest(second_parent))
        testing.expect_value(t,associations[1][0],"observed_parent")
        testing.expect_value(t,associations[1][1],contracts.owner_payload_digest(parent))
        testing.expect_value(t,associations[0][2],contracts.owner_payload_digest(raw_entry))
    }
    idless_parent:=strings.concatenate({`{"type":"wake_agent","payload":{"run":[`,raw_entry,`],"stop":[]}}`},context.temp_allocator)
    idless_action,idless_prepared:=bridge_legacy_dispatch_prepare(idless_parent,"wake_agent",observed_spec,&bridge_executor_store)
    testing.expect(t,idless_prepared)
    observed_job.legacy_action=idless_action;observed_job.text=idless_parent
    testing.expect(t,bridge_legacy_dispatch_start(&observed_job,&bridge_executor_store))
    bridge_hub_handle_wake_agent(nil,idless_parent,&bridge_executor_store,observation_action=idless_action)
    testing.expect(t,bridge_legacy_dispatch_end(idless_action,true,&bridge_executor_store))
    selected_rows,selected_read:=executor.query(bridge_executor_store.db,
        "SELECT a.command_id,a.chain_claim,a.packet_digest,d.entry_digest,d.instance_id,d.configuration_digest,d.material_digest FROM executor_legacy_action_drafts d JOIN executor_legacy_actions a USING(action_id) WHERE d.draft_id=? ORDER BY a.action_id",observed_draft.id)
    testing.expect(t,selected_read && len(selected_rows)==3,"scoped and idless actual wake occurrences bind the same selected native draft")
    if len(selected_rows)==3 {
        testing.expect_value(t,selected_rows[2][0],"")
        testing.expect_value(t,selected_rows[2][1],"")
        testing.expect_value(t,selected_rows[2][2],contracts.owner_payload_digest(idless_parent))
        for row in selected_rows {
            testing.expect_value(t,row[3],contracts.owner_payload_digest(raw_entry))
            testing.expect_value(t,row[4],observed_instance)
            testing.expect_value(t,row[5],contracts.owner_payload_digest(observed_draft.configuration))
            testing.expect_value(t,row[6],contracts.owner_payload_digest(observed_draft.material))
        }
    }
    retained_after_idless,retained_idless_found:=executor.local_draft_native(&bridge_executor_store,observed_draft.id)
    testing.expect(t,retained_idless_found && retained_after_idless.material==observed_draft.material,
        "occurrence evidence never changes the first material")
    _,rewritten:=executor.query(bridge_executor_store.db,"UPDATE executor_local_drafts SET material='{}' WHERE draft_id=?",observed_draft.id)
    testing.expect(t,!rewritten,"retained source/target material cannot be rewritten")
    if retained_after_idless.launch_id!="" {
        observed_launch,_:=executor.local_launch(&bridge_executor_store,retained_after_idless.launch_id)
        _=bridge_pty_host_executor_close(socket,observed_launch.instance,observed_launch.launch_key)
    }
    }
}
Executor_Local_Test_IO :: struct {
    disable_catalog,native_files:bool,socket:string,
}
bridge_executor_local_test_files :: proc(ctx:rawptr,m:Executor_Local_Material)->([dynamic]Bridge_Bootstrap_File,bool) {
    p:=(^Executor_Local_Test_IO)(ctx)
    if p.native_files do return bridge_executor_local_files(nil,m)
    if p.disable_catalog {
        sync.rw_mutex_lock(&bridge_launch_configuration_mutex)
        bridge_provider_catalog_snapshot.providers[0].state="deprecated"
        sync.rw_mutex_unlock(&bridge_launch_configuration_mutex)
    }
    return nil,true
}
encode_rows :: proc(rows:[dynamic][]string)->string {
    if len(rows)!=1 do return ""
    return strings.join(rows[0],"|",context.temp_allocator)
}

// Exercise the native CLI sign/export and import/inspect over an isolated real
// local socket. Only production signature validation mutates the live journal.
bridge_executor_test_operator_provision :: proc(t:^testing.T,kind,raw,root:string)->string {
    context.allocator=context.temp_allocator
    config:=fmt.tprintf("%s/operator.toml",root)
    content:=fmt.tprintf("[daemon]\ndaemon_id = \"%s\"\ndata_dir = \"%s\"\n[wrapper]\ndaemon_url = \"%s\"\n[bridge]\nfs_root = \"%s\"\n",bridge_cfg().daemon_id,bridge_cfg().data_dir,bridge_keystore_hub(),root)
    testing.expect(t,os.write_entire_file(config,content)==nil)
    input:=fmt.tprintf("%s/%s-input.json",root,kind)
    output:=fmt.tprintf("%s/%s-signed.json",root,kind)
    testing.expect(t,os.write_entire_file(input,raw)==nil)
    args:=[]string{"ham-bridge","executor","sign","--config",config,"--kind",kind,"--file",input,"--output",output}
    if !testing.expect(t,bridge_executor_operator_command(args)) do return ""
    bytes,read:=os.read_entire_file(output,context.temp_allocator)
    if !testing.expect(t,read==nil) do return ""
    run:=fmt.tprintf("%s/operator-run",root)
    testing.expect(t,bridge_make_directory_all(run)==nil)
    endpoint:=bridge_local_endpoint_config_default(run,0)
    for verb in ([2]string{"import","inspect"}) {
        listener,listening:=local_socket.listen(endpoint.unix_socket_path,2)
        if !testing.expect(t,listening) do return ""
        worker:=bridge_thread_start_with_data(&listener,proc(ctx:rawptr) {
            context.allocator=context.temp_allocator
            listener:=(^local_socket.Socket)(ctx)^
            client,connected:=local_socket.accept(listener)
            if !connected do return
            defer local_socket.close(client)
            local_socket.set_recv_timeout(client,5*time.Second)
            data:=make([dynamic]byte,context.temp_allocator);buffer:[4096]byte
            for len(data)<2*contracts.EXECUTOR_DOCUMENT_MAX {
                n:=local_socket.recv(client,buffer[:]);if n<=0 do return
                append(&data,..buffer[:n])
                if strings.index_byte(string(data[:]),'\n')<0 do continue
                reply:=bridge_local_endpoint_handle_jsonl_line(strings.trim_space(string(data[:])))
                line:=strings.concatenate({reply,"\n"},context.temp_allocator)
                _=local_socket.send(client,transmute([]byte)line)
                return
            }
        })
        call:=[]string{"ham-bridge","executor",verb,"--config",config,"--kind",kind,"--file",output,"--local-run-dir",run}
        testing.expect(t,bridge_executor_operator_command(call),verb)
        thread.join(worker);thread.destroy(worker);local_socket.close(listener);_=os.remove(endpoint.unix_socket_path)
    }
    return string(bytes)
}
bridge_executor_test_operator_import :: proc(t:^testing.T,kind,raw:string) {
    params:=struct{kind,document:string}{kind,raw}
    wire:=executor.encode(struct{v:int,id,method,token:string,params:type_of(params)}{1,"operator-test","executor.operator.install","not-operator-authority",params})
    reply:=bridge_local_endpoint_handle_jsonl_line(wire)
    testing.expect(t,!strings.contains(reply,"\"error\":"),reply)
}
