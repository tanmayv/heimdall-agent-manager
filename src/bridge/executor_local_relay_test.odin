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
import "core:encoding/json"
import channel "odin_test:lib/executor_channel"
import vault "odin_test:lib/vault"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import owner "odin_test:lib/owner_local"

@(test)
test_executor_local_mounted_signed_prepare_inspect_cancel_restart :: proc(t:^testing.T) {
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
    testing.expect_value(t,executor.install_policy(&bridge_executor_store,bridge_executor_test_sign(policy,"policy",&host_private),host,now).code,"ok")
    mapping:=bridge_executor_test_doc("directory")
    for pair in ([4][2]string{{"account_id",TEST_VAULT_USER_ID},{"executor_bridge_id",id},{"key_id",key_id},{"directory_path",work}}) do bridge_executor_test_set(mapping,pair[0],pair[1])
    testing.expect_value(t,bridge_executor_install_directory(&bridge_executor_store,bridge_executor_test_sign(mapping,"directory",&host_private),host,now).code,"ok")

    c:=bridge_executor_test_doc("local_configuration")
    for pair in ([8][2]string{{"account_id",TEST_VAULT_USER_ID},{"executor_bridge_id",id},{"provider","claude"},
        {"model","seed"},{"provider_profile","claude"},{"directory_key",executor.directory_key(id,work)},
        {"executor_incarnation",fmt.tprintf("%d",bridge_executor_store.incarnation)},{"slot_id","slot1"}}) {bridge_executor_test_set(c,pair[0],pair[1])}
    configuration:=executor.encode(c)
    d,draft_code:=executor.stage_local_draft(&bridge_executor_store,contracts.owner_payload_digest("mounted-local"),configuration,
        "{\"token\":\"native-startup-secret\",\"bootstrap\":\"native-bootstrap\"}")
    if !testing.expect_value(t,draft_code,"ok") do return
    command:=bridge_executor_test_doc("local_draft")
    for pair in ([8][2]string{{"account_id",TEST_VAULT_USER_ID},{"executor_bridge_id",id},{"principal_id",g.subject_device_id},
        {"key_id",g.subject_device_id},{"draft_id",d.id},{"configuration_digest",contracts.owner_payload_digest(configuration)},
        {"issued_ms",fmt.tprintf("%d",now)},{"request_expires_ms",fmt.tprintf("%d",now+60000)}}) {bridge_executor_test_set(command,pair[0],pair[1])}
    device:=contracts.Owner_Verified_Key{TEST_VAULT_USER_ID,g.subject_device_id,g.subject_device_id,g.subject_sign_pub,"device",true,false}
    spec,queued:=bridge_command_spec("executor_local_launch")
    testing.expect(t,queued && spec.queued && spec.class==.Exclusive && spec.retry_safe)
    wire:=Executor_Issuance_Wire{"executor_local_launch","",TEST_VAULT_USER_ID,"",directory}
    first:=""
    for method,i in ([3]string{"prepare","inspect","prepare"}) {
        command["method"]=json.String(method);command["operation_id"]=json.String("local_prepare" if i!=1 else "local_inspect")
        raw:=bridge_executor_test_sign(command,"local_draft",&device_private)
        result,code:=bridge_executor_test_local_exchange(t,wire,raw,&kr,host,fmt.tprintf("local_call_%d",i))
        testing.expect_value(t,code,"ok")
        if i==0 {first=result}
        if i==2 do testing.expect_value(t,result,first)
        testing.expect(t,!strings.contains(result,"native-startup-secret") && !strings.contains(result,"native-bootstrap") && !strings.contains(result,"launch_key"))
    }
    // Native-only resources permit admission here without pretending the
    // ordinary production launch wrapper is wired. Cancellation below uses
    // the real authenticated relay, gates, ownership and journal transaction.
    command["method"]=json.String("authorize");command["operation_id"]=json.String("local_authorize")
    raw:=bridge_executor_test_sign(command,"local_draft",&device_private)
    resources:=executor.Local_Resources{contracts.owner_payload_digest(configuration),get(c,"spawn_digest"),work,true}
    admitted:=executor.local_draft_command(&bridge_executor_store,raw,device,bridge_executor_physical_clock(nil),resources)
    if !testing.expect_value(t,admitted.code,"ok") do return
    // Reopen after admission-before-dispatch, exactly the audited P3 boundary.
    executor.close(&bridge_executor_store)
    testing.expect(t,bridge_executor_open(TEST_VAULT_USER_ID,key_id))
    retained,found:=executor.local_draft_native(&bridge_executor_store,d.id)
    testing.expect(t,found && retained.material==d.material && retained.state=="authorized")
    command["method"]=json.String("cancel");command["operation_id"]=json.String("local_cancel")
    raw=bridge_executor_test_sign(command,"local_draft",&device_private)
    cancelled,code:=bridge_executor_test_local_exchange(t,wire,raw,&kr,host,"local_cancel_after_restart")
    testing.expect_value(t,code,"ok")
    view_value,_:=contracts.owner_content_document(cancelled);view,_:=view_value.(json.Object)
    testing.expect_value(t,get(view,"state"),"cancelled");testing.expect_value(t,get(view,"launch_state"),"released")
    replay,replay_code:=bridge_executor_test_local_exchange(t,wire,raw,&kr,host,"local_cancel_replay")
    testing.expect_value(t,replay_code,"ok");testing.expect_value(t,replay,cancelled)
    rows,_:=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_live_resources");testing.expect_value(t,rows[0][0],"0")
    command["draft_revision"]=json.String("2");command["operation_id"]=json.String("local_bad_revision")
    _,conflict:=bridge_executor_test_local_exchange(t,wire,bridge_executor_test_sign(command,"local_draft",&device_private),&kr,host,"local_bad_revision")
    testing.expect_value(t,conflict,"draft_conflict")
    // AEAD possession does not turn an invalid device signature into consent.
    command["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    envelope,sealed:=bridge_encrypt_vault_text(executor.encode(command),&kr,context.temp_allocator)
    testing.expect(t,sealed)
    relay:=executor.encode(struct{protocol_version,bridge_id,request_id,expires_ms,envelope:string}{"1",id,"unsigned_local",fmt.tprintf("%d",now+60000),envelope})
    wire.command_id="unsigned_local";wire.relay=relay
    bridge_executor_local_handle(nil,executor.encode(wire))
    response,cached:=bridge_runtime_cached_command("unsigned_local")
    testing.expect(t,cached && extract_json_string(response,"code","")=="invalid_scope")
}

bridge_executor_test_local_exchange :: proc(t:^testing.T,template:Executor_Issuance_Wire,raw:string,kr:^vault.Vault_Keyring,host:contracts.Owner_Verified_Key,request_id:string,apply:Executor_Local_Apply=bridge_executor_local_apply)->(string,string) {
    now:=bridge_executor_physical_clock(nil)
    token,sealed:=bridge_encrypt_vault_text(raw,kr,context.temp_allocator)
    if !testing.expect(t,sealed) do return "","test_seal_failed"
    wire:=template
    wire.command_id=request_id
    wire.relay=executor.encode(struct{protocol_version,bridge_id,request_id,expires_ms,envelope:string}{
        "1",host.principal_id,request_id,fmt.tprintf("%d",now+60000),token})
    bridge_executor_local_handle(nil,executor.encode(wire),apply)
    response,cached:=bridge_runtime_cached_command(request_id)
    if !testing.expect(t,cached) do return "","test_reply_missing"
    get:=contracts.owner_string
    reply_value,_:=contracts.owner_content_document(response);reply,_:=reply_value.(json.Object)
    plain,opened:=bridge_open_current_epoch_token(get(reply,"envelope"),kr,context.temp_allocator)
    if !testing.expect(t,opened) do return "",get(reply,"code")
    bundle,valid:=contracts.executor_parse(plain,"local_bundle")
    receipt,parsed:=contracts.executor_parse(get(bundle,"receipt"),"local_result")
    testing.expect(t,valid && parsed && contracts.executor_verify("local_result",receipt,host))
    command,_:=contracts.executor_parse(raw,"local_draft")
    digest,_:=contracts.executor_digest("local_draft",command)
    testing.expect(t,get(receipt,"request_digest")==digest && get(receipt,"result_digest")==contracts.owner_payload_digest(get(bundle,"body")) &&
        get(receipt,"request_id")==request_id && get(receipt,"principal_id")==get(command,"principal_id") &&
        get(receipt,"operation_id")==get(command,"operation_id"))
    result_value,_:=contracts.owner_content_document(get(bundle,"body"));result,_:=result_value.(json.Object)
    testing.expect_value(t,get(result,"code"),get(reply,"code"))
    return get(result,"body"),get(result,"code")
}
