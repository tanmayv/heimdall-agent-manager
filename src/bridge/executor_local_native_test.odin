#+build !windows
#+feature dynamic-literals
package main
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
test_executor_local_native_pending_fresh_resources_and_real_dispatch :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    st:=p1c_test_setup(t);defer p1c_test_teardown(st)
    sync.mutex_lock(&keystore_test_mutex);defer sync.mutex_unlock(&keystore_test_mutex)
    id,_:=keystore_test_bridge_ids()
    prior_id:=keystore_test_set_daemon_id(id);defer {bridge_config.daemon_id=prior_id}
    keystore_lock_and_purge(id);_=keystore_delete_identity_key(id);bridge_unseal_forget_identity()
    unseal_nonce_cache_clear(&g_unseal_nonce_cache);bridge_unseal_init()
    if !testing.expect(t,test_provision_identity(id)) do return
    defer {keystore_lock_and_purge(id);_=keystore_delete_identity_key(id);bridge_unseal_forget_identity()}
    kr:=test_keyring_from_hex(TEST_VAULT_KEY_HEX);defer vault.keyring_wipe(&kr)
    now:=time.to_unix_nanoseconds(time.now())/1000000
    payload:=test_create_unseal_v2_payload(id,&kr,now,"issuance_mounted_pair")
    unsealed,_:=bridge_unseal_decrypt_and_verify(payload,id,now)
    if !testing.expect(t,unsealed) do return
    proof_value,_:=contracts.owner_content_document(test_chain_proof(id,&kr));proof,_:=proof_value.(json.Object)
    genesis,_:=proof["genesis"].(json.Object);approval,_:=proof["subject_approval"].(json.Object)
    get:=contracts.owner_string
    g_text,a_text:=get(genesis,"statement"),get(approval,"statement")
    g,g_ok:=vault.statement_parse(g_text);a,a_ok:=vault.statement_parse(a_text)
    if !testing.expect(t,g_ok && a_ok) do return
    scalar:[32]byte;_=vault.hex_decode_into(scalar[:],TEST_ACCOUNT_ROOT_SCALAR)
    device_private:ecdsa.Private_Key;_=ecdsa.private_key_set_bytes(&device_private,.SECP256R1,scalar[:]);defer ecdsa.private_key_clear(&device_private)
    // The unseal proof deliberately omits the full-directory epoch commit.
    // Build a genuine complete approval and sign it with the paired root.
    a.epoch_commit=g.epoch_commit
    a_text,_=vault.statement_canonical(&a,context.temp_allocator)
    approval_signature,_:=vault.sign_p256(&device_private,transmute([]byte)a_text)
    a_sig,_:=vault.signature_object(&approval_signature,context.temp_allocator)
    directory:=vault.Directory_Verification_Input{
        owner=TEST_VAULT_USER_ID,root_device_id=g.subject_device_id,version=2,current_epoch=1,
        head_hash=vault.log_entry_hash(a_text,context.temp_allocator),
        log=[]vault.Directory_Log_Item{{1,g_text,get(genesis,"signature")},{2,a_text,a_sig}},
        devices=[]vault.Directory_Device_Item{
            {g.subject_device_id,"browser",g.subject_sign_alg,g.subject_wrap_alg,g.subject_sign_pub,g.subject_ecdh_pub,true,false},
            {a.subject_device_id,"bridge",a.subject_sign_alg,a.subject_wrap_alg,a.subject_sign_pub,"",true,false},
        },
    }
    _,dir_ok:=vault.directory_verify(directory);if !testing.expect(t,dir_ok) do return
    prior_root:=bridge_fs_root;root:=bridge_fs_canonicalize_existing(st.dir);defer delete(root)
    bridge_fs_root=root;defer {bridge_fs_root=prior_root}
    work:=fmt.tprintf("%s/work",root);testing.expect(t,os.make_directory(work)==nil)
    public:=bridge_identity_public_key_hex(id);key_id,_:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    host:=contracts.Owner_Verified_Key{TEST_VAULT_USER_ID,id,key_id,public,"bridge",true,false}
    if !testing.expect(t,bridge_executor_open(TEST_VAULT_USER_ID,key_id)) do return
    defer {
        executor.close(&bridge_executor_store)
        dir,found:=bridge_vault_bridge_dir(id,context.temp_allocator)
        if found do _=os.remove_all(fmt.tprintf("%sexecutor-local-%s",dir,contracts.owner_payload_digest(TEST_VAULT_USER_ID)))
    }
    unconfigured:=executor.encode(struct{type,agent_instance_id,provider,model,provider_profile:string,run_count:int}{
        "launch_provider_test","unconfigured_local_instance","claude","seed","claude",1})
    before_config,selection,_:=bridge_runtime_launch_provider_test("unconfigured",unconfigured)
    testing.expect(t,!before_config && selection=="directory_selection_required","no automatic resource provisioning")
    now=time.to_unix_nanoseconds(time.now())/1000000
    identity_record:Bridge_Identity_Record
    if !testing.expect(t,keystore_read_identity(id,&identity_record)==.Found) do return
    defer crypto.zero_explicit(&identity_record,size_of(identity_record))
    host_private:ecdsa.Private_Key
    if !testing.expect(t,ecdsa.private_key_set_bytes(&host_private,.SECP256R1,identity_record.scalar[:])) do return
    defer ecdsa.private_key_clear(&host_private)
    policy:=bridge_executor_test_doc("policy")
    bridge_executor_test_set(policy,"account_id",TEST_VAULT_USER_ID);bridge_executor_test_set(policy,"executor_bridge_id",id)
    bridge_executor_test_set(policy,"key_id",key_id)
    bridge_executor_test_set(policy,"slots_json",`[{"slot_id":"slot1","provider_profile":"claude","enabled":"1"}]`)
    policy_raw:=bridge_executor_test_operator_provision(t,"policy",executor.encode(policy),root)
    forged:=policy;forged["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    forged_params:=struct{kind,document:string}{"policy",executor.encode(forged)}
    forged_wire:=executor.encode(struct{v:int,id,method,token:string,params:type_of(forged_params)}{1,"forged","executor.operator.install","agent-token-is-not-operator",forged_params})
    rejection:=bridge_local_endpoint_handle_jsonl_line(forged_wire)
    testing.expect(t,strings.contains(rejection,"invalid_scope"),"agent transport cannot replace pinned operator signature")
    sign_wire:=executor.encode(struct{v:int,id,method,token:string,params:type_of(forged_params)}{1,"no-sign-rpc","executor.operator.sign","agent-token-is-not-operator",forged_params})
    testing.expect(t,strings.contains(bridge_local_endpoint_handle_jsonl_line(sign_wire),"unauthenticated"),"no signing RPC")
    mapping:=bridge_executor_test_doc("directory")
    for pair in ([4][2]string{{"account_id",TEST_VAULT_USER_ID},{"executor_bridge_id",id},{"key_id",key_id},{"directory_path",work}}) do bridge_executor_test_set(mapping,pair[0],pair[1])
    mapping_raw:=bridge_executor_test_operator_provision(t,"directory",executor.encode(mapping),root)


    old_run_dir:=bridge_config.local_endpoint_run_dir
    bridge_config.local_endpoint_run_dir=fmt.tprintf("%s/runtime",root)
    defer {bridge_config.local_endpoint_run_dir=old_run_dir}
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/instances",bridge_config.local_endpoint_run_dir))==nil)
    pp:=Provider_Profile{profile_id="claude",provider="claude",enabled=true,config=Provider_Profile_Config{binary_path="/bin/sh"}}
    bridge_provider_catalog_snapshot.providers[0].model_flag="-s"
    testing.expect_value(t,profile_upsert(&pp,nil,now),Profile_Error.None)
    instance:="native_local_instance"
    command_json:=executor.encode(struct{type,command_id,agent_instance_id,provider,model,provider_profile:string,run_count:int}{
        "launch_provider_test","native_first",instance,"claude","seed","claude",1})
    run_dir:=bridge_runtime_default_run_dir(instance);defer delete(run_dir)
    testing.expect(t,bridge_make_directory_all(run_dir)==nil)
    marker:=fmt.tprintf("%s/keep.txt",run_dir)
    testing.expect(t,os.write_entire_file(marker,"previous-bootstrap")==nil)
    previous:=bridge_agent_token_issue(instance,"old-hub-assertion",.Agent,0)
    staged,detail,_:=bridge_runtime_launch_provider_test("native_first",command_json)
    testing.expect(t,!staged)
    pending_value,parsed:=contracts.owner_content_document(detail);pending,_:=pending_value.(json.Object)
    if !testing.expect(t,parsed && get(pending,"code")=="launch_authorization_required",detail) do return
    draft,found:=executor.local_draft_native(&bridge_executor_store,get(pending,"draft_id"))
    if !testing.expect(t,found) do return
    m,material_ok:=bridge_executor_local_material(draft)
    testing.expect(t,material_ok && len(m.token)==69 && m.assertion=="" && m.run_count==1)
    _,old_valid:=bridge_agent_token_verify(previous.plaintext_token)
    _,new_active:=bridge_agent_token_verify(m.token)
    testing.expect(t,old_valid && !new_active && os.exists(marker),"unsigned launch is inert")
    changed_transport,_:=strings.replace_all(command_json,"native_first","native_second",context.temp_allocator)
    _,retry_detail,_:=bridge_runtime_launch_provider_test("native_second",changed_transport)
    testing.expect_value(t,retry_detail,detail)
    retained,_:=executor.local_draft_source(&bridge_executor_store,bridge_executor_local_source(changed_transport,"provider_test"))
    testing.expect_value(t,retained.material,draft.material)

    command:=bridge_executor_test_doc("local_draft")
    now=bridge_executor_physical_clock(nil)
    for pair in ([][2]string{{"account_id",TEST_VAULT_USER_ID},{"executor_bridge_id",id},{"principal_id",g.subject_device_id},
        {"key_id",g.subject_device_id},{"draft_id",draft.id},{"configuration_digest",contracts.owner_payload_digest(draft.configuration)},
        {"issued_ms",fmt.tprintf("%d",now)},{"request_expires_ms",fmt.tprintf("%d",now+60000)}}) {bridge_executor_test_set(command,pair[0],pair[1])}
    device:=contracts.Owner_Verified_Key{TEST_VAULT_USER_ID,g.subject_device_id,g.subject_device_id,g.subject_sign_pub,"device",true,false}
    wire:=Executor_Issuance_Wire{"executor_local_launch","",TEST_VAULT_USER_ID,"",directory}
    command["method"]=json.String("prepare");command["operation_id"]=json.String("native_prepare")
    _,code:=bridge_executor_test_local_exchange(t,wire,bridge_executor_test_sign(command,"local_draft",&device_private),&kr,host,"native_prepare")
    if !testing.expect_value(t,code,"ok") do return
    command["method"]=json.String("authorize");command["operation_id"]=json.String("native_authorize")
    raw:=bridge_executor_test_sign(command,"local_draft",&device_private)

    probe:=Executor_Local_Test_IO{directory=directory}
    bridge_executor_local_test_io=&probe;defer {bridge_executor_local_test_io=nil}
    // A catalog disabled during slow preparation is rejected before admission
    // and before touching either the old token or the existing bootstrap.
    probe.disable_catalog=true
    _,code=bridge_executor_test_local_exchange(t,wire,raw,&kr,host,"native_disable",bridge_executor_local_test_apply)
    testing.expect_value(t,code,"invalid_resources")
    _,old_valid=bridge_agent_token_verify(previous.plaintext_token)
    rows,_:=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources")
    testing.expect(t,old_valid && os.exists(marker) && rows[0][0]=="0")
    bridge_provider_catalog_snapshot.providers[0].state="active"
    probe.disable_catalog=false

    expiring:=make(json.Object,context.temp_allocator)
    for name,value in command do expiring[name]=value
    delayed_now:=bridge_executor_physical_clock(nil)
    expiring["operation_id"]=json.String("native_delayed_consent")
    expiring["issued_ms"]=json.String(fmt.tprintf("%d",delayed_now))
    expiring["request_expires_ms"]=json.String(fmt.tprintf("%d",delayed_now+10))
    probe.delay_ms=25
    _,code=bridge_executor_test_local_exchange(t,wire,bridge_executor_test_sign(expiring,"local_draft",&device_private),&kr,host,"native_delayed_consent",bridge_executor_local_test_apply)
    testing.expect_value(t,code,"expired")
    probe.delay_ms=0
    _,old_valid=bridge_agent_token_verify(previous.plaintext_token)
    testing.expect(t,old_valid && os.exists(marker),"delayed expired consent cannot touch startup")

    // A freshly root-signed revocation observed after preparation fences even
    // a request whose original relay carried an older valid paired directory.
    revoke:=vault.Statement{type="revoke",user_id=TEST_VAULT_USER_ID,seq="3",prev_hash=directory.head_hash,
        issuer_device_id=g.subject_device_id,subject_device_id=a.subject_device_id,issued_at_ms="5",
        subject_kind=a.subject_kind,subject_sign_pub=a.subject_sign_pub,subject_ecdh_pub=a.subject_ecdh_pub,
        subject_sign_alg=a.subject_sign_alg,subject_wrap_alg=a.subject_wrap_alg,subject_label_b64=a.subject_label_b64,
        epoch="2",epoch_commit=strings.repeat("c",64,context.temp_allocator)}
    revoke_text,_:=vault.statement_canonical(&revoke,context.temp_allocator)
    revoked_sig,_:=vault.sign_p256(&device_private,transmute([]byte)revoke_text)
    revoke_signature,_:=vault.signature_object(&revoked_sig,context.temp_allocator)
    revoked:=directory;revoked.version=3;revoked.current_epoch=2;revoked.head_hash=vault.log_entry_hash(revoke_text,context.temp_allocator)
    revoked.log=make([]vault.Directory_Log_Item,3,context.temp_allocator);copy(revoked.log,directory.log)
    revoked.log[2]={3,revoke_text,revoke_signature}
    revoked.devices=make([]vault.Directory_Device_Item,2,context.temp_allocator);copy(revoked.devices,directory.devices)
    revoked.devices[1].approved=false
    _,revoked_valid:=vault.directory_verify(revoked)
    testing.expect(t,revoked_valid)
    probe.directory=revoked
    _,code=bridge_executor_test_local_exchange(t,wire,raw,&kr,host,"native_revoked",bridge_executor_local_test_apply)
    testing.expect_value(t,code,"invalid_scope")
    pin,_,pinned:=executor.enrollment_pin(&bridge_executor_store)
    testing.expect(t,pinned && pin==3)
    // Rollback of the paired directory cannot restore this authorization.
    probe.directory=directory
    bridge_executor_local_handle(nil,executor.encode(wire))
    // Continue the independent native resource/physical proof in a fresh
    // fixture store, preserving the revocation evidence above.
    executor.close(&bridge_executor_store)
    state_dir,_:=bridge_vault_bridge_dir(id,context.temp_allocator)
    testing.expect(t,os.remove_all(fmt.tprintf("%sexecutor-local-%s",state_dir,contracts.owner_payload_digest(TEST_VAULT_USER_ID)))==nil)
    testing.expect(t,bridge_executor_open(TEST_VAULT_USER_ID,key_id))
    now=bridge_executor_physical_clock(nil)
    bridge_executor_test_operator_import(t,"policy",policy_raw)
    bridge_executor_test_operator_import(t,"directory",mapping_raw)
    _,detail,_=bridge_runtime_launch_provider_test("native_fresh_store",command_json)
    pending_value,_=contracts.owner_content_document(detail);pending,_=pending_value.(json.Object)
    draft,_=executor.local_draft_native(&bridge_executor_store,get(pending,"draft_id"))
    command["draft_id"]=json.String(draft.id);command["configuration_digest"]=json.String(contracts.owner_payload_digest(draft.configuration))
    command["method"]=json.String("prepare");command["operation_id"]=json.String("native_prepare_again")
    _,code=bridge_executor_test_local_exchange(t,wire,bridge_executor_test_sign(command,"local_draft",&device_private),&kr,host,"native_prepare_again")
    testing.expect_value(t,code,"ok")
    command["method"]=json.String("authorize");command["operation_id"]=json.String("native_authorize_again")
    raw=bridge_executor_test_sign(command,"local_draft",&device_private)
    testing.expect(t,executor.exec(bridge_executor_store.db,"CREATE TRIGGER fail_native_admission BEFORE INSERT ON executor_local_draft_receipts BEGIN SELECT RAISE(ABORT,'native admission rollback'); END"))
    _,code=bridge_executor_test_local_exchange(t,wire,raw,&kr,host,"actual_admission_rollback",bridge_executor_local_test_apply)
    testing.expect_value(t,code,"storage_error")
    rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"0")
    _,old_valid=bridge_agent_token_verify(previous.plaintext_token)
    testing.expect(t,old_valid && os.exists(marker),"uncommitted admission never mutates startup")
    testing.expect(t,executor.exec(bridge_executor_store.db,"DROP TRIGGER fail_native_admission"))
    // Replace the signed mapping while preparation has released executor_mutex.
    replacement:=mapping;replacement["revision"]=json.String("2")
    new_path:=fmt.tprintf("%s/replacement",root);testing.expect(t,os.make_directory(new_path)==nil)
    replacement["directory_path"]=json.String(new_path)
    probe.replace_mapping=bridge_executor_test_sign(replacement,"directory",&host_private);probe.host=host
    _,code=bridge_executor_test_local_exchange(t,wire,raw,&kr,host,"native_mapping_replaced",bridge_executor_local_test_apply)
    testing.expect_value(t,code,"invalid_resources")
    testing.expect(t,os.exists(marker))
    rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"0")

    binary:=os.get_env("HEIMDALL_EXECUTOR_TEST_PTY",context.temp_allocator)
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
    probe.socket=socket;probe.replace_mapping=""
    // A new exact generation proposes the current replacement mapping.
    next_command,_:=strings.replace_all(command_json,`"run_count":1`,`"run_count":2`,context.temp_allocator)
    _,detail,_=bridge_runtime_launch_provider_test("native_actual",next_command)
    pending_value,_=contracts.owner_content_document(detail);pending,_=pending_value.(json.Object)
    draft,found=executor.local_draft_native(&bridge_executor_store,get(pending,"draft_id"))
    if !testing.expect(t,found) do return
    m,material_ok=bridge_executor_local_material(draft)
    testing.expect(t,material_ok && m.run_count==2)
    // The native endpoint is already running in production. Keep this hermetic
    // provider-test child isolated from the host Bridge's listeners and vault.
    saved_started,saved_endpoint:=bridge_runtime_local_endpoint_started,bridge_runtime_local_endpoint_descriptor
    bridge_runtime_local_endpoint_started=true;bridge_runtime_local_endpoint_descriptor=m.endpoint
    defer {bridge_runtime_local_endpoint_started=saved_started;bridge_runtime_local_endpoint_descriptor=saved_endpoint}
    old_ctl,had_ctl:=os.lookup_env("HEIMDALL_HAM_CTL_BIN",context.temp_allocator)
    _=os.set_env("HEIMDALL_HAM_CTL_BIN","/bin/sh")
    defer {if had_ctl {_=os.set_env("HEIMDALL_HAM_CTL_BIN",old_ctl)} else {os.unset_env("HEIMDALL_HAM_CTL_BIN")}}
    command["draft_id"]=json.String(draft.id);command["configuration_digest"]=json.String(contracts.owner_payload_digest(draft.configuration))
    command["method"]=json.String("prepare");command["operation_id"]=json.String("actual_prepare")
    _,code=bridge_executor_test_local_exchange(t,wire,bridge_executor_test_sign(command,"local_draft",&device_private),&kr,host,"actual_prepare")
    if !testing.expect_value(t,code,"ok") do return
    command["method"]=json.String("authorize");command["operation_id"]=json.String("actual_authorize")
    raw=bridge_executor_test_sign(command,"local_draft",&device_private)
    // Force a lost local observation after the physical Spawn. The exact
    // operation's committed authorization must never cause a second Spawn.
    testing.expect(t,executor.exec(bridge_executor_store.db,"CREATE TRIGGER fail_native_observe BEFORE INSERT ON executor_local_observations BEGIN SELECT RAISE(ABORT,'lost native observation'); END"))
    _,code=bridge_executor_test_local_exchange(t,wire,raw,&kr,host,"actual_lost_observe",bridge_executor_local_test_apply)
    testing.expect_value(t,code,"observation_not_committed")
    current,_:=executor.local_draft_native(&bridge_executor_store,draft.id)
    launch,_:=executor.local_launch(&bridge_executor_store,current.launch_id)
    pid,known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    if !testing.expect(t,known && pid>0) do return
    defer {_=bridge_pty_host_executor_close(socket,launch.instance,launch.launch_key);bridge_shell_test_kill_pid(int(pid))}
    _,old_valid=bridge_agent_token_verify(previous.plaintext_token)
    _,new_active=bridge_agent_token_verify(m.token)
    testing.expect(t,!old_valid,"signed dispatch invalidates previous token")
    testing.expect(t,new_active,"signed dispatch activates the retained random token")
    testing.expect(t,!os.exists(marker),"signed dispatch replaces previous bootstrap")
    testing.expect(t,executor.exec(bridge_executor_store.db,"DROP TRIGGER fail_native_observe"))
    _,code=bridge_executor_test_local_exchange(t,wire,raw,&kr,host,"actual_retry",bridge_executor_local_test_apply)
    testing.expect_value(t,code,"ok")
    same_pid,same_known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    testing.expect(t,same_known && same_pid==pid)
    busy_policy:=policy;busy_policy["policy_revision"]=json.String("2")
    signed_busy,busy_signed:=bridge_executor_operator_sign_record("policy",executor.encode(busy_policy))
    testing.expect_value(t,busy_signed,"ok")
    busy_params:=executor.encode(struct{kind,document:string}{"policy",signed_busy})
    busy_rejection:=bridge_executor_operator_handle("busy-policy","executor.operator.install",busy_params)
    testing.expect(t,strings.contains(busy_rejection,"resources_not_drained"),"operator reallocation cannot borrow a live charge")
    resumed,_,_:=bridge_executor_local_stage(next_command,"provider_test",{&probe,bridge_executor_local_test_directory,bridge_executor_local_test_files,socket})
    testing.expect(t,resumed,"native retry reuses the original current signed authorization")
    same_pid,same_known=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    testing.expect(t,same_known && same_pid==pid,"native retry cannot replace the exact live child")
    rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"1")
    // Reopen with a live exact child. Cancellation must retain the charge until
    // exact stop/absence is committed, including an observation COMMIT fault.
    executor.close(&bridge_executor_store);testing.expect(t,bridge_executor_open(TEST_VAULT_USER_ID,key_id))
    testing.expect(t,executor.exec(bridge_executor_store.db,"CREATE TRIGGER fail_native_cancel BEFORE INSERT ON executor_local_observations BEGIN SELECT RAISE(ABORT,'lost native stop observation'); END"))
    command["method"]=json.String("cancel");command["operation_id"]=json.String("actual_cancel")
    cancel:=bridge_executor_test_sign(command,"local_draft",&device_private)
    _,code=bridge_executor_test_local_exchange(t,wire,cancel,&kr,host,"actual_cancel",bridge_executor_local_test_apply)
    testing.expect_value(t,code,"ok")
    rows,_=executor.query(bridge_executor_store.db,"SELECT state FROM executor_local_launches WHERE launch_id=?",launch.id);testing.expect_value(t,rows[0][0],"stopping")
    _,cancelled_token:=bridge_agent_token_verify(m.token)
    testing.expect(t,!cancelled_token,"signed cancellation revokes only this exact startup credential")
    rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"1")
    testing.expect(t,executor.exec(bridge_executor_store.db,"DROP TRIGGER fail_native_cancel"))
    _,code=bridge_executor_test_local_exchange(t,wire,cancel,&kr,host,"actual_cancel_retry",bridge_executor_local_test_apply)
    testing.expect_value(t,code,"ok")
    rows,_=executor.query(bridge_executor_store.db,"SELECT state FROM executor_local_launches WHERE launch_id=?",launch.id);testing.expect_value(t,rows[0][0],"released")
    rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"0")
    _,code=bridge_executor_test_local_exchange(t,wire,raw,&kr,host,"actual_authorize_after_cancel",bridge_executor_local_test_apply)
    testing.expect_value(t,code,"ok")
    stopped,stopped_known:=bridge_pty_host_executor_query(socket,launch.instance,launch.launch_key)
    testing.expect(t,stopped_known && stopped==0)

    // Ordinary manual launch uses the real conditional bootstrap HTTP path,
    // cached content-addressed template, native materializer and daemon Spawn.
    _,_=bridge_executor_local_reconcile_batch(&bridge_executor_store,socket,"")
    http_listener,http_error:=net.listen_tcp(net.Endpoint{address=net.IP4_Loopback,port=0})
    if !testing.expect(t,http_error==nil) do return
    defer net.close(http_listener)
    _=net.set_option(http_listener,.Receive_Timeout,5*time.Second)
    bound,_:=net.bound_endpoint(http_listener)
    old_url,old_credential:=bridge_config.daemon_url,bridge_config.bridge_token
    bridge_config.daemon_url=fmt.tprintf("http://127.0.0.1:%d",bound.port);bridge_config.bridge_token="isolated-test-only"
    defer {bridge_config.daemon_url=old_url;bridge_config.bridge_token=old_credential}
    old_cache:=bootstrap_global_cache;bootstrap_global_cache={}
    bootstrap_cache_init(&bootstrap_global_cache,fmt.tprintf("%s/native-cache",root),1024*1024)
    defer {bootstrap_global_cache=old_cache}
    template:="# Approved native manual agent\nUse the protected workspace.\n"
    hash:=test_bootstrap_sha256(template)
    testing.expect(t,bootstrap_cache_put(&bootstrap_global_cache,hash,template))
    Http :: struct{listener:net.TCP_Socket,hash:string,served:bool}
    http:=Http{http_listener,hash,false}
    http_worker:=thread.create_and_start_with_data(&http,proc(ctx:rawptr) {
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
    manual:=bridge_wake_launch_command_json("manual","native_manual_instance","","worker","claude","seed","native_agent","Native agent","","","","",new_path,
        run_count=1,provider_profile="claude",instance_token="isolated-hub-assertion",launch_epoch="native_epoch")
    ready,manual_detail,_:=bridge_runtime_launch_agent("manual",manual)
    testing.expect(t,!ready)
    pending_value,_=contracts.owner_content_document(manual_detail);pending,_=pending_value.(json.Object)
    manual_draft,manual_found:=executor.local_draft_native(&bridge_executor_store,get(pending,"draft_id"))
    if !testing.expect(t,manual_found,manual_detail) do return
    status:=bridge_instance_status_json("native_manual_instance")
    testing.expect(t,extract_json_string(status,"launch_epoch","")=="native_epoch","pending status carries proposed epoch without activating credentials")
    command["draft_id"]=json.String(manual_draft.id);command["configuration_digest"]=json.String(contracts.owner_payload_digest(manual_draft.configuration))
    command["method"]=json.String("prepare");command["operation_id"]=json.String("manual_prepare")
    _,code=bridge_executor_test_local_exchange(t,wire,bridge_executor_test_sign(command,"local_draft",&device_private),&kr,host,"manual_prepare")
    if !testing.expect_value(t,code,"ok") do return
    command["method"]=json.String("authorize");command["operation_id"]=json.String("manual_authorize")
    manual_raw:=bridge_executor_test_sign(command,"local_draft",&device_private)
    probe.native_files=true
    _,code=bridge_executor_test_local_exchange(t,wire,manual_raw,&kr,host,"manual_authorize",bridge_executor_local_test_apply)
    if !testing.expect_value(t,code,"ok") do return
    testing.expect(t,http.served)
    manual_current,_:=executor.local_draft_native(&bridge_executor_store,manual_draft.id)
    manual_launch,_:=executor.local_launch(&bridge_executor_store,manual_current.launch_id)
    manual_pid,manual_known:=bridge_pty_host_executor_query(socket,manual_launch.instance,manual_launch.launch_key)
    if !testing.expect(t,manual_known && manual_pid>0) do return
    defer {_=bridge_pty_host_executor_close(socket,manual_launch.instance,manual_launch.launch_key);bridge_shell_test_kill_pid(int(manual_pid))}
    material,_:=bridge_executor_local_material(manual_draft)
    instructions,instructions_read:=os.read_entire_file(fmt.tprintf("%s/CLAUDE.md",material.run_dir),context.temp_allocator)
    testing.expect(t,instructions_read==nil && strings.contains(string(instructions),"Approved native manual agent"))
    // Lose the projection, then ordinary warm transport reuses the exact signed
    // generation and original material without requesting another approval.
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id==manual_launch.instance {inst.startup.generation=0;inst.pty_process_alive=false}
    sync.mutex_unlock(&bridge_runtime_mutex)
    warm:=bridge_wake_launch_command_json("warm",manual_launch.instance,"","worker","claude","seed","native_agent","Native agent","","","","",new_path,
        pack_json=`{"delivery":"new task context"}`,run_count=1,provider_profile="claude",instance_token="isolated-hub-assertion",launch_epoch="native_epoch")
    ready,_,_=bridge_executor_local_stage(warm,"warm",{&probe,bridge_executor_local_test_directory,bridge_executor_local_test_files,socket})
    testing.expect(t,ready)
    same_pid,same_known=bridge_pty_host_executor_query(socket,manual_launch.instance,manual_launch.launch_key)
    testing.expect(t,same_known && same_pid==manual_pid)
    recovered,projection:=bridge_runtime_instance_snapshot(manual_launch.instance)
    testing.expect(t,projection && recovered.startup.generation>0 && recovered.startup.pty_pid==manual_pid && recovered.startup.armed_at_ms>0)
    command["method"]=json.String("cancel");command["operation_id"]=json.String("manual_cancel")
    _,code=bridge_executor_test_local_exchange(t,wire,bridge_executor_test_sign(command,"local_draft",&device_private),&kr,host,"manual_cancel",bridge_executor_local_test_apply)
    testing.expect_value(t,code,"ok")
}
Executor_Local_Test_IO :: struct {directory:vault.Directory_Verification_Input,disable_catalog,native_files:bool,replace_mapping:string,host:contracts.Owner_Verified_Key,socket:string,delay_ms:i64}
bridge_executor_local_test_io:^Executor_Local_Test_IO
bridge_executor_local_test_directory :: proc(ctx:rawptr,_:i64)->(vault.Directory_Verification_Input,bool) {
    p:=(^Executor_Local_Test_IO)(ctx)
    if p.delay_ms>0 do time.sleep(time.Duration(p.delay_ms)*time.Millisecond)
    return p.directory,true
}
bridge_executor_local_test_files :: proc(ctx:rawptr,m:Executor_Local_Material)->([dynamic]Bridge_Bootstrap_File,bool) {
    p:=(^Executor_Local_Test_IO)(ctx)
    if p.native_files do return bridge_executor_local_files(nil,m)
    if p.disable_catalog {
        sync.rw_mutex_lock(&bridge_launch_configuration_mutex)
        bridge_provider_catalog_snapshot.providers[0].state="deprecated"
        sync.rw_mutex_unlock(&bridge_launch_configuration_mutex)
    }
    if p.replace_mapping!="" {
        sync.mutex_lock(&bridge_executor_mutex)
        _=bridge_executor_install_directory(&bridge_executor_store,p.replace_mapping,p.host,bridge_executor_physical_clock(nil))
        sync.mutex_unlock(&bridge_executor_mutex)
    }
    return nil,true
}
bridge_executor_local_test_apply :: proc(s:^executor.Store,raw:string,o:json.Object,key:contracts.Owner_Verified_Key,kr:^vault.Vault_Keyring,generation:i64)->executor.Result {
    p:=bridge_executor_local_test_io
    return bridge_executor_local_apply_io(s,raw,o,key,kr,generation,{p,bridge_executor_local_test_directory,bridge_executor_local_test_files,p.socket})
}

// Exercise the native CLI sign/export and import/inspect over an isolated real
// local socket. Only production signature validation mutates the live journal.
bridge_executor_test_operator_provision :: proc(t:^testing.T,kind,raw,root:string)->string {
    context.allocator=context.temp_allocator
    config:=fmt.tprintf("%s/operator.toml",root)
    content:=fmt.tprintf("[daemon]\ndaemon_id = \"%s\"\ndata_dir = \"%s\"\n[wrapper]\ndaemon_url = \"%s\"\n[bridge]\nfs_root = \"%s\"\n",bridge_config.daemon_id,bridge_config.data_dir,bridge_keystore_hub(),root)
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
        worker:=thread.create_and_start_with_data(&listener,proc(ctx:rawptr) {
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
