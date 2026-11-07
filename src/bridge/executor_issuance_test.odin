#+build !windows
#+feature dynamic-literals
package main
import "core:crypto"
import "core:crypto/ecdsa"
import "core:os"
import "core:fmt"
import "core:testing"
import "core:sync"
import "core:time"
import "core:encoding/json"
import channel "odin_test:lib/executor_channel"
import vault "odin_test:lib/vault"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

@(test)
test_executor_issuance_resolves_signed_directory_catalog_and_profile :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    st:=p1c_test_setup(t);defer p1c_test_teardown(st)
    saved_root:=bridge_fs_root
    root:=bridge_fs_canonicalize_existing(st.dir);defer delete(root)
    bridge_fs_root=root;defer {bridge_fs_root=saved_root}
    directory:=fmt.tprintf("%s/work",root)
    if !testing.expect(t,os.make_directory(directory)==nil) do return
    private,key:=bridge_executor_test_key("executor","operator",7);defer ecdsa.private_key_clear(&private)
    store:executor.Store
    if !testing.expect(t,executor.open(&store,fmt.tprintf("%s/executor.sqlite",root),"account","executor","operator")) do return
    defer executor.close(&store)
    record:=bridge_executor_test_doc("directory")
    bridge_executor_test_set(record,"directory_path",directory)
    raw:=bridge_executor_test_sign(record,"directory",&private)
    testing.expect_value(t,bridge_executor_install_directory(&store,raw,key,1000).code,"ok")
    selected:=bridge_executor_test_doc("issuance_selection")
    bridge_executor_test_set(selected,"provider","claude");bridge_executor_test_set(selected,"model","seed")
    bridge_executor_test_set(selected,"provider_profile","claude")
    resources:=bridge_executor_resolve_issuance(&store,executor.encode(selected))
    testing.expect(t,resources.resolved && resources.directory_path==directory && resources.directory_key==executor.directory_key("executor",directory))
    for pair in ([3][2]string{{"model","not-in-catalog"},{"provider_profile","unknown-profile"},{"directory_id","not-provisioned"}}) {
        old:=contracts.owner_string(selected,pair[0]);bridge_executor_test_set(selected,pair[0],pair[1])
        testing.expect(t,!bridge_executor_resolve_issuance(&store,executor.encode(selected)).resolved,pair[0])
        bridge_executor_test_set(selected,pair[0],old)
    }
    // A previously signed path is not enough after its local target vanishes.
    testing.expect(t,os.remove(directory)==nil)
    testing.expect(t,!bridge_executor_resolve_issuance(&store,executor.encode(selected)).resolved)
    testing.expect(t,os.make_directory(directory)==nil)
    testing.expect(t,bridge_executor_resolve_issuance(&store,executor.encode(selected)).resolved)
    // Raw caller path records have no host authority and cannot provision.
    bridge_executor_test_set(record,"directory_path",fmt.tprintf("%s/missing",root))
    bridge_executor_test_set(record,"revision","2")
    testing.expect_value(t,bridge_executor_install_directory(&store,bridge_executor_test_sign(record,"directory",&private),key,1000).code,"invalid_resources")
}

@(test)
test_executor_issuance_mounted_handler_paired_consent_replay_and_rejection :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    spec,queued:=bridge_command_spec("executor_issuance")
    testing.expect(t,queued && spec.queued && spec.class==.Exclusive && spec.retry_safe,"filesystem/SQLite issuance must leave the WebSocket reader")

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
    device:=contracts.Owner_Verified_Key{TEST_VAULT_USER_ID,g.subject_device_id,g.subject_device_id,g.subject_sign_pub,"device",true,false}
    selection:=bridge_executor_test_doc("issuance_selection")
    bridge_executor_test_set(selection,"provider","claude");bridge_executor_test_set(selection,"model","seed");bridge_executor_test_set(selection,"provider_profile","claude")
    selected:=executor.encode(selection)
    consent:=bridge_executor_test_doc("issuance_consent")
    for pair in ([7][2]string{{"account_id",TEST_VAULT_USER_ID},{"executor_bridge_id",id},{"executor_key_id",key_id},{"principal_id",g.subject_device_id},
        {"key_id",g.subject_device_id},{"issued_ms",fmt.tprintf("%d",now)},{"request_expires_ms",fmt.tprintf("%d",now+300000)}}) {bridge_executor_test_set(consent,pair[0],pair[1])}
    bridge_executor_test_set(consent,"selection_digest",contracts.owner_payload_digest(selected))
    consent_raw:=bridge_executor_test_sign(consent,"issuance_consent",&device_private)
    digest,_:=contracts.executor_digest("issuance_consent",consent)
    scope:=bridge_executor_test_doc("transport_scope")
    for pair in ([10][2]string{{"account_id",TEST_VAULT_USER_ID},{"executor_bridge_id",id},{"method","enrollment"},{"reservation_id",""},{"request_id","mounted_issuance"},
        {"input_digest",digest},{"fence_digest",get(consent,"selection_digest")},{"issued_ms",fmt.tprintf("%d",now)},
        {"request_expires_ms",fmt.tprintf("%d",now+60000)},{"executor_incarnation","1"}}) {bridge_executor_test_set(scope,pair[0],pair[1])}
    token,token_ok:=channel.seal(consent_raw,&kr,scope,now);testing.expect(t,token_ok)
    exchange:=executor.encode(struct{scope,envelope,selection:string}{executor.encode(scope),token,selected})
    outer,outer_ok:=vault.seal(transmute([]byte)exchange,&kr);testing.expect(t,outer_ok)
    relay:=executor.encode(struct{protocol_version,chain_id,bridge_id,request_id,expires_ms,envelope:string}{"1","chain",id,"mounted_issuance",fmt.tprintf("%d",now+60000),outer})
    wire:=Executor_Issuance_Wire{"executor_issuance","mounted_issuance",TEST_VAULT_USER_ID,relay,directory}
    bridge_executor_issuance_handle(nil,executor.encode(wire))
    cached,found:=bridge_runtime_cached_command(wire.command_id);if !testing.expect(t,found) do return
    response_value,_:=contracts.owner_content_document(cached);response,_:=response_value.(json.Object)
    if !testing.expect_value(t,get(response,"code"),"ok") do return
    reply_scope:=scope;reply_scope["direction"]=json.String("response")
    plain,verified:=channel.open_issuance(get(response,"envelope"),&kr,reply_scope,consent,selected,device,host,time.to_unix_nanoseconds(time.now())/1000000)
    if !testing.expect(t,verified) do return
    rows,_:=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_issuances")
    testing.expect_value(t,rows[0][0],"1")
    wire.command_id="mounted_retry"
    bridge_executor_issuance_handle(nil,executor.encode(wire))
    cached,found=bridge_runtime_cached_command(wire.command_id);testing.expect(t,found)
    response_value,_=contracts.owner_content_document(cached);response,_=response_value.(json.Object)
    same:string
    same,verified=channel.open_issuance(get(response,"envelope"),&kr,reply_scope,consent,selected,device,host,time.to_unix_nanoseconds(time.now())/1000000)
    testing.expect(t,verified && plain==same)
    // Current paired-directory verification cannot be replaced by an account
    // encryption key and a caller-supplied approved row.
    wire.command_id="mounted_bad_directory";wire.directory.log[1].signature="{}"
    bridge_executor_issuance_handle(nil,executor.encode(wire))
    cached,found=bridge_runtime_cached_command(wire.command_id);testing.expect(t,found)
    response_value,_=contracts.owner_content_document(cached);response,_=response_value.(json.Object)
    testing.expect_value(t,get(response,"code"),"invalid_scope")
    rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_issuances")
    testing.expect_value(t,rows[0][0],"1")
}
