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
    // F4 (B), Mundus .14: the issued selection is re-resolved at prepare; an
    // active account-catalog model this Bridge has not observed (claude
    // reports aliases only) resolves as it did at issuance; a retired one does not.
    bridge_provider_catalog_default_hook=[]Bridge_Catalog_Provider{{provider="claude",state="active",models=[]Bridge_Catalog_Model{{model_id="claude-sonnet-5-5",state="active"},{model_id="claude-old",state="retired"}}}}
    bridge_executor_test_set(selected,"model","claude-sonnet-5-5")
    testing.expect(t,bridge_executor_resolve_issuance(&store,executor.encode(selected)).resolved,"an active catalog model the Bridge has not observed resolves at prepare")
    bridge_executor_test_set(selected,"model","claude-old")
    testing.expect(t,!bridge_executor_resolve_issuance(&store,executor.encode(selected)).resolved,"a retired catalog model is still refused")
    bridge_provider_catalog_default_hook=nil
    bridge_executor_test_set(selected,"model","seed")
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
    bridge_executor_issuance_mounted_scenario(t)
}

@(test)
test_executor_original_owner_native_notification :: proc(t:^testing.T) {
    when #config(EXECUTOR_NATIVE_OWNER,false) {bridge_executor_issuance_mounted_scenario(t,true)}
    else {fmt.eprintln("[skip] actual native owner proof requires EXECUTOR_NATIVE_OWNER=true")}
}
@(test)
test_executor_original_owner_remote_stop :: proc(t:^testing.T) {
    bridge_executor_issuance_mounted_scenario(t,true,true)
}
bridge_executor_issuance_mounted_scenario :: proc(t:^testing.T,native:=false,stop_only:=false) {
    context.allocator=context.temp_allocator
    spec,queued:=bridge_command_spec("executor_issuance")
    testing.expect(t,queued && spec.queued && spec.class==.Exclusive && spec.retry_safe,"filesystem/SQLite issuance must leave the WebSocket reader")
    callback_spec,callback_known:=bridge_command_spec("owner_executor_fence")
    testing.expect(t,callback_known && callback_spec.queued && callback_spec.class==.Interactive && callback_spec.key_kind==.None && callback_spec.retry_safe,
        "nonce callback must not wait behind an executor's Exclusive job or Bridge ordering key")
    activate_spec,activate_known:=bridge_command_spec("executor_activation")
    testing.expect(t,activate_known && activate_spec.queued && activate_spec.class==.General_IO && activate_spec.key_kind==.None && activate_spec.retry_safe)

    st:=p1c_test_setup(t);defer p1c_test_teardown(st)
    selected_provider,selected_model:="claude","seed"
    if native && !stop_only {
        selected_provider="codex";selected_model=bridge_env_get("HEIMDALL_NATIVE_MODEL",context.temp_allocator)
        binary:=bridge_env_get("HEIMDALL_NATIVE_CODEX",context.temp_allocator)
        if !testing.expect(t,binary!="" && selected_model!="","explicit native executable/model required") do return
        bridge_provider_catalog_snapshot.providers[0].provider="codex"
        bridge_provider_catalog_snapshot.providers[0].binary=binary
        bridge_provider_catalog_snapshot.providers[0].models[0].model_id=selected_model
        bridge_provider_catalog_snapshot.providers[0].model_flag="--model"
        bridge_provider_catalog_snapshot.providers[1].provider="claude"
        profile:=Provider_Profile{profile_id="codex",provider="codex",enabled=true,config=Provider_Profile_Config{binary_path=binary}}
        if !testing.expect_value(t,profile_upsert(&profile,nil,bridge_executor_physical_clock(nil)),Profile_Error.None) do return
    }
    sync.mutex_lock(&keystore_test_mutex);defer sync.mutex_unlock(&keystore_test_mutex)
    id,owner_runtime_id:=keystore_test_bridge_ids()
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
    bridge_executor_test_set(policy,"slots_json",executor.encode([]struct{slot_id,provider_profile,enabled:string}{{"slot1",selected_provider,"1"}}))
    testing.expect_value(t,executor.install_policy(&bridge_executor_store,bridge_executor_test_sign(policy,"policy",&host_private),host,now).code,"ok")
    mapping:=bridge_executor_test_doc("directory")
    for pair in ([4][2]string{{"account_id",TEST_VAULT_USER_ID},{"executor_bridge_id",id},{"key_id",key_id},{"directory_path",work}}) do bridge_executor_test_set(mapping,pair[0],pair[1])
    testing.expect_value(t,bridge_executor_install_directory(&bridge_executor_store,bridge_executor_test_sign(mapping,"directory",&host_private),host,now).code,"ok")
    device:=contracts.Owner_Verified_Key{TEST_VAULT_USER_ID,g.subject_device_id,g.subject_device_id,g.subject_sign_pub,"device",true,false}
    selection:=bridge_executor_test_doc("issuance_selection")
    bridge_executor_test_set(selection,"provider",selected_provider);bridge_executor_test_set(selection,"model",selected_model);bridge_executor_test_set(selection,"provider_profile",selected_provider)
    selected:=executor.encode(selection)
    consent:=bridge_executor_test_doc("issuance_consent")
    for pair in ([7][2]string{{"account_id",TEST_VAULT_USER_ID},{"executor_bridge_id",id},{"executor_key_id",key_id},{"principal_id",g.subject_device_id},
        {"key_id",g.subject_device_id},{"issued_ms",fmt.tprintf("%d",now)},{"request_expires_ms",fmt.tprintf("%d",now+300000)}}) {bridge_executor_test_set(consent,pair[0],pair[1])}
    bridge_executor_test_set(consent,"selection_digest",contracts.owner_payload_digest(selected))
    if native do bridge_executor_test_set(consent,"owner_bridge_id",owner_runtime_id)
    consent_raw:=bridge_executor_test_sign(consent,"issuance_consent",&device_private)
    digest,_:=contracts.executor_digest("issuance_consent",consent)
    scope:=bridge_executor_test_doc("transport_scope")
    for pair in ([10][2]string{{"account_id",TEST_VAULT_USER_ID},{"executor_bridge_id",id},{"method","enrollment"},{"reservation_id",""},{"request_id","mounted_issuance"},
        {"input_digest",digest},{"fence_digest",get(consent,"selection_digest")},{"issued_ms",fmt.tprintf("%d",now)},
        {"request_expires_ms",fmt.tprintf("%d",now+60000)},{"executor_incarnation","1"}}) {bridge_executor_test_set(scope,pair[0],pair[1])}
    bridge_executor_test_set(scope,"owner_bridge_id",get(consent,"owner_bridge_id"))
    token,token_ok:=channel.seal(consent_raw,&kr,scope,now);testing.expect(t,token_ok)
    exchange:=executor.encode(struct{scope,envelope,selection:string}{executor.encode(scope),token,selected})
    outer,outer_ok:=vault.seal(transmute([]byte)exchange,&kr);testing.expect(t,outer_ok)
    relay:=executor.encode(struct{protocol_version,chain_id,bridge_id,request_id,expires_ms,envelope:string}{"1","chain",id,"mounted_issuance",fmt.tprintf("%d",now+60000),outer})
    wire:=Executor_Issuance_Wire{"executor_issuance","mounted_issuance",TEST_VAULT_USER_ID,"",relay,"",directory}
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
    // Enroll a distinct owner signing key under the same real paired root.
    owner_private,owner_key:=bridge_executor_test_key("owner1","pending",2)
    defer ecdsa.private_key_clear(&owner_private)
    if native {
        owner_key.principal_id=owner_runtime_id
        prior_native_id:=bridge_cfg().daemon_id
        bridge_cfg().daemon_id=owner_runtime_id
        defer {bridge_cfg().daemon_id=prior_native_id;bridge_unseal_forget_identity()}
        keystore_lock_and_purge(owner_runtime_id);_=keystore_delete_identity_key(owner_runtime_id)
        bridge_unseal_forget_identity()
        if !testing.expect(t,test_provision_identity(owner_runtime_id)) do return
        record:Bridge_Identity_Record
        if !testing.expect(t,keystore_read_identity(owner_runtime_id,&record)==.Found) do return
        defer crypto.zero_explicit(&record,size_of(record))
        ecdsa.private_key_clear(&owner_private)
        if !testing.expect(t,ecdsa.private_key_set_bytes(&owner_private,.SECP256R1,record.scalar[:])) do return
        owner_key.public_key=bridge_identity_public_key_hex(owner_runtime_id)
    }
    defer {if native {keystore_lock_and_purge(owner_runtime_id);_=keystore_delete_identity_key(owner_runtime_id)}}
    owner_id,_:=vault.device_id_from_sign_pub(owner_key.public_key,context.temp_allocator)
    owner_key.key_id=owner_id;owner_key.account_id=TEST_VAULT_USER_ID
    owner_approval:=vault.Statement{type="approve",user_id=TEST_VAULT_USER_ID,seq="3",prev_hash=directory.head_hash,
        issuer_device_id=g.subject_device_id,issued_at_ms="4",subject_device_id=owner_id,subject_kind="bridge",
        subject_sign_pub=owner_key.public_key,subject_sign_alg=vault.SIGN_ALG_ECDSA_P256_SHA256,subject_label_b64="b3duZXI",
        epoch="1",epoch_commit=g.epoch_commit}
    owner_text,_:=vault.statement_canonical(&owner_approval,context.temp_allocator)
    owner_sig,_:=vault.sign_p256(&device_private,transmute([]byte)owner_text)
    owner_signature,_:=vault.signature_object(&owner_sig,context.temp_allocator)
    peer_directory:=directory;peer_directory.version=3;peer_directory.head_hash=vault.log_entry_hash(owner_text,context.temp_allocator)
    peer_directory.log=make([]vault.Directory_Log_Item,3,context.temp_allocator)
    copy(peer_directory.log,directory.log);peer_directory.log[2]={3,owner_text,owner_signature}
    peer_directory.devices=make([]vault.Directory_Device_Item,3,context.temp_allocator)
    copy(peer_directory.devices,directory.devices);peer_directory.devices[2]={owner_id,"bridge",vault.SIGN_ALG_ECDSA_P256_SHA256,"",owner_key.public_key,"",true,false}
    genesis_owner:=make(json.Object,context.temp_allocator)
    for pair in ([11][2]string{{"protocol_version","1"},{"account_id",TEST_VAULT_USER_ID},{"chain_id","chain"},{"creation_op","owner_genesis"},
        {"owner_bridge_id",owner_key.principal_id},{"owner_key_id",owner_id},{"creator_id",g.subject_device_id},{"creator_key_id",g.subject_device_id},
        {"schema_version","1"},{"creator_signature",strings.repeat("0",128,context.temp_allocator)},{"owner_signature",strings.repeat("0",128,context.temp_allocator)}}) {
        genesis_owner[pair[0]]=json.String(pair[1])
    }
    canonical_genesis,_:=contracts.owner_canonical("genesis",genesis_owner)
    creator_signature,_:=vault.sign_p256(&device_private,transmute([]byte)canonical_genesis)
    owner_genesis_signature,_:=vault.sign_p256(&owner_private,transmute([]byte)canonical_genesis)
    genesis_owner["creator_signature"]=json.String(vault.hex_encode_lower(creator_signature.sig[:],context.temp_allocator))
    genesis_owner["owner_signature"]=json.String(vault.hex_encode_lower(owner_genesis_signature.sig[:],context.temp_allocator))
    request_value,_:=contracts.owner_content_document(plain);issued_bundle,_:=request_value.(json.Object)
    config,_:=contracts.owner_parse(get(issued_bundle,"configuration"),"remote_configuration")
    if native {
        bridge_executor_original_owner_native(t,peer_directory,executor.encode(genesis_owner),config,issued_bundle,
            device,owner_key,host,&device_private,&owner_private,&kr,work,stop_only)
        return
    }
    prepared:=bridge_executor_test_doc("prepare")
    for name in ([14]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id","instance_id",
        "launch_epoch","run_count","token_generation","configuration_revision","executor_incarnation","policy_revision","slot_id","provider_profile"}) {prepared[name]=config[name]}
    prepared["directory_key"]=config["directory_key"];prepared["key_id"]=json.String(owner_id)
    prepare_now:=time.to_unix_nanoseconds(time.now())/1000000
    prepared["prepare_until_ms"]=json.String(fmt.tprintf("%d",prepare_now+30000))
    prepared["request_expires_ms"]=json.String(fmt.tprintf("%d",prepare_now+60000))
    prepared["hard_ms"]=json.String(fmt.tprintf("%d",prepare_now+600000))
    peer_wire:=Executor_Exchange_Wire{"executor_exchange","",TEST_VAULT_USER_ID,"",executor.encode(genesis_owner),peer_directory}
    prepared_receipt,prepare_code:=bridge_executor_test_exchange(t,peer_wire,prepared,"prepare",&owner_private,&kr,host,"mounted_prepare")
    if !testing.expect_value(t,prepare_code,"ok") do return
    testing.expect_value(t,get(prepared_receipt,"state"),"prepared")
    testing.expect_value(t,get(prepared_receipt,"historical"),"0")
    repeated,repeat_code:=bridge_executor_test_exchange(t,peer_wire,prepared,"prepare",&owner_private,&kr,host,"mounted_prepare_retry")
    testing.expect_value(t,repeat_code,"ok");testing.expect_value(t,get(repeated,"historical"),"1")
    prepare_digest,_:=contracts.executor_digest("prepare",prepared)
    action:=bridge_executor_test_doc("action")
    for name in ([7]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation","executor_incarnation"}) do action[name]=prepared[name]
    action["prepare_digest"]=json.String(prepare_digest);action["key_id"]=json.String(owner_id)
    action["method"]=json.String("query");action["operation_id"]=json.String("query_exact")
    action["request_expires_ms"]=prepared["request_expires_ms"];action["hard_ms"]=prepared["hard_ms"]
    action["expires_ms"]=json.String(fmt.tprintf("%d",prepare_now+300000))
    queried,query_code:=bridge_executor_test_exchange(t,peer_wire,action,"action",&owner_private,&kr,host,"mounted_query")
    testing.expect_value(t,query_code,"ok");testing.expect_value(t,get(queried,"state"),"prepared")
    action["method"]=json.String("activate");action["operation_id"]=json.String("activate_exact")
    _,activate_code:=bridge_executor_test_exchange(t,peer_wire,action,"action",&owner_private,&kr,host,"mounted_activate_closed")
    testing.expect_value(t,activate_code,"owner_fence_not_current")
    rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_intents")
    testing.expect_value(t,rows[0][0],"0")
    action["method"]=json.String("stop");action["operation_id"]=json.String("stop_exact")
    stopped,stop_code:=bridge_executor_test_exchange(t,peer_wire,action,"action",&owner_private,&kr,host,"mounted_stop")
    testing.expect_value(t,stop_code,"ok");testing.expect_value(t,get(stopped,"state"),"released")

    // Exercise the production activation ingress with a signed encrypted owner
    // callback. The injected transport is not an enrolled network proof.
    for mode in 0..<3 {
        prepared["reservation_id"]=json.String(fmt.tprintf("activation_reservation_%d",mode))
        prepared["operation_id"]=json.String(fmt.tprintf("activation_prepare_%d",mode))
        _,code:=bridge_executor_test_exchange(t,peer_wire,prepared,"prepare",&owner_private,&kr,host,fmt.tprintf("activation_prepare_call_%d",mode))
        if !testing.expect_value(t,code,"ok") do return
        prepare_digest,_=contracts.executor_digest("prepare",prepared)
        action["reservation_id"]=prepared["reservation_id"];action["prepare_digest"]=json.String(prepare_digest)
        action["method"]=json.String("activate");action["operation_id"]=json.String(fmt.tprintf("activate_nonce_%d",mode))
        probe:=Executor_Fence_Test_Probe{private=&owner_private,kr=&kr,directory=peer_directory,action=action,owner_key=owner_key,cancel=mode==0,restart=mode==2}
        accepted,activation_code:=bridge_executor_test_exchange(t,peer_wire,action,"action",&owner_private,&kr,host,
            fmt.tprintf("activation_nonce_call_%d",mode),&probe)
        testing.expect(t,probe.calls==1 && probe.unlocked,"nonce callback releases the executor mutex")
        if mode==0 {
            testing.expect_value(t,activation_code,"operation_conflict")
            rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_intents WHERE kind='launch'")
            testing.expect(t,rows[0][0]=="0","cancel during callback cannot create a launch")
        } else if mode==1 {
            testing.expect_value(t,activation_code,"ok");testing.expect_value(t,get(accepted,"state"),"active")
            replay,replay_code:=bridge_executor_test_exchange(t,peer_wire,action,"action",&owner_private,&kr,host,"activation_nonce_retry",&probe)
            testing.expect_value(t,replay_code,"ok");testing.expect_value(t,get(replay,"historical"),"1")
            testing.expect_value(t,probe.calls,1)
            b:=make(json.Object,context.temp_allocator)
            for entry in contracts.executor_schema("bootstrap") {
                value:=get(prepared,entry.name)
                if value=="" do value=get(action,entry.name)
                b[entry.name]=json.String(value)
            }
            content:=executor.encode(struct{agents_md,memory_md,task_md,skills_json:string}{"# Owner worker","","# Existing lease","[]"})
            ad,_:=contracts.executor_digest("action",action)
            issued:=time.to_unix_nanoseconds(time.now())/1000000
            b["prepare_digest"]=json.String(prepare_digest);b["action_digest"]=json.String(ad)
            b["configuration_digest"]=json.String(contracts.owner_payload_digest(get(issued_bundle,"configuration")))
            b["body_digest"]=json.String(contracts.owner_payload_digest(content));b["launch_key"]=accepted["launch_key"]
            b["issued_ms"]=json.String(fmt.tprintf("%d",issued));b["request_expires_ms"]=json.String(fmt.tprintf("%d",issued+4000))
            bootstrap:=bridge_executor_test_sign(b,"bootstrap",&owner_private)
            _,bootstrap_code:=bridge_executor_test_exchange(t,peer_wire,action,"action",&owner_private,&kr,host,"activation_bootstrap_call",&probe,bootstrap,content)
            testing.expect_value(t,bootstrap_code,"ok")
            testing.expect_value(t,probe.calls,2)
            rows,_=executor.query(bridge_executor_store.db,"SELECT document,body FROM executor_bootstraps WHERE reservation_id=?",get(prepared,"reservation_id"))
            testing.expect(t,len(rows)==1 && rows[0][0]==bootstrap && rows[0][1]==content)
            _,duplicate_code:=bridge_executor_test_exchange(t,peer_wire,action,"action",&owner_private,&kr,host,"activation_bootstrap_duplicate",&probe,bootstrap,content)
            testing.expect_value(t,duplicate_code,"ok")
            _,substitution_code:=bridge_executor_test_exchange(t,peer_wire,action,"action",&owner_private,&kr,host,"activation_bootstrap_substitution",&probe,bootstrap,"changed")
            testing.expect_value(t,substitution_code,"operation_conflict")
            rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_intents WHERE kind='launch'")
            testing.expect_value(t,rows[0][0],"1")
            // Trusted test-daemon absence drains the charge before the next
            // reservation. No physical provider/absence claim is inferred.
            if bridge_env_get("HEIMDALL_EXECUTOR_TEST_PTY",context.temp_allocator)!="" {
                bridge_executor_test_bootstrap_real_child(t,peer_wire,prepared,action,&owner_private,owner_key,peer_directory,&kr)
            } else {
                when #config(EXECUTOR_TEST_REQUIRED,false) {testing.fail_now(t,"real bootstrap daemon required")}
                testing.expect(t,executor.observe_child(&bridge_executor_store,get(prepared,"reservation_id"),
                    {get(prepared,"instance_id"),get(accepted,"launch_key"),bridge_executor_store.incarnation,false}))
            }
        } else {
            testing.expect_value(t,activation_code,"stale_incarnation")
            rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_intents WHERE kind='launch' AND state!='settled'")
            testing.expect_value(t,rows[0][0],"0")
        }
    }

    // The outbound worker revalidates paired-directory evidence against the
    // immutable accepted assignment before it can interpret an executor reply.
    response_owner:owner.Store
    if !testing.expect(t,owner.open(&response_owner,fmt.tprintf("%s/owner-response.sqlite",root),TEST_VAULT_USER_ID,id,key_id)) do return
    defer owner.close(&response_owner)
    testing.expect(t,owner.exec(response_owner.db,"INSERT INTO task_chains VALUES('chain','device','device','title','description',1); INSERT INTO tasks VALUES('chain','task','title','body',1);"))
    reservation_snapshot:=bridge_owner_json(contracts.Owner_Remote_Reservation{get(issued_bundle,"configuration"),get(issued_bundle,"attestation")})
    assignment_snapshot:=bridge_owner_json(contracts.Owner_Remote_Assignment_Snapshot{"{}",reservation_snapshot})
    _,history_written:=owner.query(response_owner.db,"INSERT INTO local_assignment_history VALUES('chain','task',1,'device','assign','{}',?,'{}')",assignment_snapshot)
    testing.expect(t,history_written)
    dispatch_claim:=owner.Intent_Claim{destination=id,fence=bridge_owner_json(prepared)}
    dispatch_pin:=Owner_Executor_Pin{key_id=key_id,generation=bridge_task_chain_search_generation()}
    checked_key,trusted_peer,read_peer:=bridge_owner_executor_directory(&response_owner,peer_directory,dispatch_pin,dispatch_claim,&kr)
    testing.expect(t,read_peer && trusted_peer && checked_key.key_id==key_id)
    wrong_pin:=dispatch_pin;wrong_pin.key_id=owner_id
    _,trusted_peer,read_peer=bridge_owner_executor_directory(&response_owner,peer_directory,wrong_pin,dispatch_claim,&kr)
    testing.expect(t,read_peer && !trusted_peer,"another enrolled Bridge cannot substitute for the assignment key")
    callback_owner,callback_version,callback_head,callback_trusted:=bridge_owner_fence_directory(&response_owner,peer_directory,&kr)
    testing.expect(t,callback_trusted && callback_owner.key_id==key_id && callback_version==3 && callback_head==peer_directory.head_hash)

    // A signed newer directory is a security observation even when its content
    // key has not arrived. Rejecting the request must still prevent rollback.
    rotation:=vault.Statement{type="rotate",user_id=TEST_VAULT_USER_ID,seq="4",prev_hash=peer_directory.head_hash,
        issuer_device_id=g.subject_device_id,issued_at_ms="5",epoch="2",epoch_commit=strings.repeat("c",64,context.temp_allocator)}
    rotation_text,_:=vault.statement_canonical(&rotation,context.temp_allocator)
    rotation_signature,_:=vault.sign_p256(&device_private,transmute([]byte)rotation_text)
    rotation_sig,_:=vault.signature_object(&rotation_signature,context.temp_allocator)
    rotated:=peer_directory;rotated.version=4;rotated.current_epoch=2
    rotated.head_hash=vault.log_entry_hash(rotation_text,context.temp_allocator)
    rotated.log=make([]vault.Directory_Log_Item,4,context.temp_allocator);copy(rotated.log,peer_directory.log)
    rotated.log[3]={4,rotation_text,rotation_sig}
    _,rotation_open:=bridge_executor_directory(&bridge_executor_store,rotated,&kr)
    testing.expect(t,!rotation_open,"missing current content epoch denies admission")
    pinned_version,_,pin_ok:=executor.enrollment_pin(&bridge_executor_store)
    testing.expect(t,pin_ok && pinned_version==4,"verified newer directory survives rejected admission")
    _,trusted_peer,read_peer=bridge_owner_executor_directory(&response_owner,rotated,dispatch_pin,dispatch_claim,&kr)
    owner_pin_seq,owner_pin_hash:=owner.directory_pin(&response_owner)
    testing.expect(t,read_peer && !trusted_peer && owner_pin_seq==4 && owner_pin_hash==rotated.head_hash)
    _,_,_,callback_trusted=bridge_owner_fence_directory(&response_owner,peer_directory,&kr)
    testing.expect(t,!callback_trusted,"owner nonce callback cannot restore an older enrolled directory")
    _,trusted_peer,read_peer=bridge_owner_executor_directory(&response_owner,peer_directory,dispatch_pin,dispatch_claim,&kr)
    testing.expect(t,read_peer && !trusted_peer,"late older response cannot roll back observed content-key rotation")
    _,rolled_back:=bridge_executor_directory(&bridge_executor_store,peer_directory,&kr)
    testing.expect(t,!rolled_back,"old correctly signed directory cannot restore revoked authority")

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

// Drives the production executor handler with real inner signatures and channel
// encryption. It does not stand in for a network/Hub enrollment demonstration.
bridge_executor_test_exchange :: proc(t:^testing.T,wire:Executor_Exchange_Wire,request:json.Object,kind:string,
    private:^ecdsa.Private_Key,kr:^vault.Vault_Keyring,self:contracts.Owner_Verified_Key,id:string,probe:^Executor_Fence_Test_Probe=nil,bootstrap:string="",body:string="",
    launch_io:Executor_Launch_IO={},physical:bool=false,notification_message:string="",
    exchange_ctx:rawptr=nil,exchange_fn:Executor_Fence_Exchange=nil,owner_intent:string="",scope_out:^string=nil)->(json.Object,string) {
    get:=contracts.owner_string
    now:=time.to_unix_nanoseconds(time.now())/1000000
    raw:=bridge_executor_test_sign(request,kind,private)
    digest,_:=contracts.executor_digest(kind,request)
    scope:=bridge_executor_test_doc("transport_scope")
    for name in ([7]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation","executor_incarnation"}) do scope[name]=request[name]
    bridge_executor_test_set(scope,"method",kind);bridge_executor_test_set(scope,"request_id",id)
    bridge_executor_test_set(scope,"input_digest",digest)
    bridge_executor_test_set(scope,"fence_digest",digest if kind=="prepare" else get(request,"prepare_digest"))
    bridge_executor_test_set(scope,"issued_ms",fmt.tprintf("%d",now))
    bridge_executor_test_set(scope,"request_expires_ms",fmt.tprintf("%d",now+60000))
    encrypted,encrypted_ok:=channel.seal(raw,kr,scope,now);testing.expect(t,encrypted_ok)
    exchange:=executor.encode(struct{scope,envelope:string}{executor.encode(scope),encrypted})
    if probe!=nil do exchange=executor.encode(struct{scope,envelope,intent_id,claim_attempt:string}{executor.encode(scope),encrypted,strings.repeat("a",64,context.temp_allocator),"1"})
    if bootstrap!="" {
        exchange=executor.encode(struct{scope,envelope,intent_id,claim_attempt,bootstrap,body:string}{
            executor.encode(scope),encrypted,owner_intent if owner_intent!="" else strings.repeat("a",64,context.temp_allocator),"1",bootstrap,body})
    }
    if kind=="notification" {
        exchange=executor.encode(struct{scope,envelope,message,claim_attempt:string}{executor.encode(scope),encrypted,notification_message,"1"})
    }
    outer,outer_ok:=vault.seal(transmute([]byte)exchange,kr);testing.expect(t,outer_ok)
    call:=wire;call.command_id=id
    call.relay=executor.encode(struct{protocol_version,chain_id,bridge_id,request_id,expires_ms,envelope:string}{
        "1",get(request,"chain_id"),get(request,"executor_bridge_id"),id,fmt.tprintf("%d",now+60000),outer})
    if exchange_fn!=nil {
        bridge_executor_exchange_handle(nil,executor.encode(call),kind!="notification",exchange_ctx,exchange_fn,bridge_executor_activate_dispatch,launch_io)
    } else if probe==nil {bridge_executor_exchange_handle(nil,executor.encode(call),false,nil,bridge_executor_fence_exchange,bridge_executor_activate_dispatch,launch_io)} else {
        if physical {
            bridge_executor_exchange_handle(nil,executor.encode(call),true,probe,bridge_executor_test_fence_callback,bridge_executor_activate_dispatch,launch_io)
        } else {
            bridge_executor_exchange_handle(nil,executor.encode(call),true,probe,bridge_executor_test_fence_callback,bridge_executor_test_accept_bootstrap_only)
        }
    }
    cached,found:=bridge_runtime_cached_command(id)
    if !found do return nil,"test_no_reply"
    value,_:=contracts.owner_content_document(cached);response,_:=value.(json.Object)
    code:=get(response,"code")
    if code!="ok" do return nil,code
    scope["direction"]=json.String("response")
    if scope_out!=nil do scope_out^=executor.encode(scope)
    plain,opened:=channel.open_signed(get(response,"envelope"),kr,scope,self,time.to_unix_nanoseconds(time.now())/1000000,
        query_discovery=kind=="action" && get(request,"method")=="query")
    if !opened do return nil,"test_bad_reply"
    receipt,valid:=contracts.executor_parse(plain,"notification_result" if kind=="notification" else "receipt")
    return receipt,("ok" if valid else "test_bad_receipt")
}

Executor_Fence_Test_Probe :: struct {
    private:^ecdsa.Private_Key,
    kr:^vault.Vault_Keyring,
    directory:vault.Directory_Verification_Input,
    action:json.Object,
    owner_key:contracts.Owner_Verified_Key,
    cancel,restart,unlocked:bool,
    calls:int,
    invalidate_at:int,
    startup_unlocked,prepared_before_callback:bool,
    prepare_probe:^Executor_Test_Prepare,
    resource_mutation,resource_path:string,
}
bridge_executor_test_fence_callback :: proc(ctx:rawptr,raw:string,generation:i64)->Executor_Fence_Outcome {
    p:=(^Executor_Fence_Test_Probe)(ctx);p.calls+=1
    q,valid:=contracts.executor_parse(raw,"fence_request")
    if !valid do return {}
    get:=contracts.owner_string
    now:=time.to_unix_nanoseconds(time.now())/1000000
    p.startup_unlocked=sync.mutex_try_lock(&bridge_startup_io_mutex)
    if p.startup_unlocked do sync.mutex_unlock(&bridge_startup_io_mutex)
    if p.prepare_probe!=nil do p.prepared_before_callback=p.prepare_probe.calls>0
    p.unlocked=sync.mutex_try_lock(&bridge_executor_mutex)
    if p.unlocked {
        if p.cancel {
            stop:=make(json.Object,context.temp_allocator)
            for name,value in p.action do stop[name]=value
            stop["method"]=json.String("stop");stop["operation_id"]=json.String("cancel_in_callback")
            result:=executor.action(&bridge_executor_store,bridge_executor_test_sign(stop,"action",p.private),p.owner_key,now)
            if result.code!="ok" do panic("callback cancellation failed")
        }
        if p.restart {
            account:=strings.clone(bridge_executor_store.account,context.temp_allocator)
            operator:=strings.clone(bridge_executor_store.operator_key,context.temp_allocator)
            executor.close(&bridge_executor_store)
            if !bridge_executor_open(account,operator) do panic("callback restart failed")
        }
        sync.mutex_unlock(&bridge_executor_mutex)
    }
    if p.resource_mutation!="" && p.calls==1 {
        switch p.resource_mutation {
        case "catalog":
            sync.rw_mutex_lock(&bridge_launch_configuration_mutex)
            bridge_provider_catalog_snapshot.providers[0].state="disabled"
            sync.rw_mutex_unlock(&bridge_launch_configuration_mutex)
        case "profile":
            profile,err:=profile_lookup("claude","claude",prepare_runtime=false)
            if err!=.None do panic("profile lookup")
            // Any existing executable that differs from the fixture's
            // profile; /bin/false is absent on NixOS hosts (only /bin/sh).
            profile.config.binary_path="/bin/sh"
            if e:=profile_upsert(&profile,nil,now);e!=.None do panic(fmt.tprintf("profile mutation %v",e))
        case "missing","replacement":
            if os.rename(p.resource_path,fmt.tprintf("%s.saved",p.resource_path))!=nil do panic("directory rename")
            if p.resource_mutation=="replacement" && os.make_directory(p.resource_path)!=nil do panic("directory replacement")
        }
    }
    reply:=bridge_executor_test_doc("fence_reply")
    for name in ([7]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation","executor_incarnation"}) do reply[name]=q[name]
    digest,_:=contracts.executor_digest("fence_request",q)
    reply["request_digest"]=json.String(digest);reply["action_digest"]=q["action_digest"];reply["challenge"]=q["challenge"]
    reply["prepare_digest"]=p.action["prepare_digest"];reply["owner_commit_seq"]=p.action["owner_commit_seq"]
    reply["checked_ms"]=json.String(fmt.tprintf("%d",now));reply["request_expires_ms"]=q["request_expires_ms"]
    reply["key_id"]=json.String(p.owner_key.key_id)
    reply_raw:=bridge_executor_test_sign(reply,"fence_reply",p.private)
    scope:=bridge_executor_test_doc("transport_scope")
    for name in ([7]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation","executor_incarnation"}) do scope[name]=q[name]
    scope["method"]=json.String("fence_request");scope["direction"]=json.String("response")
    scope["input_digest"]=json.String(digest);scope["fence_digest"]=q["action_digest"]
    scope["issued_ms"]=q["issued_ms"];scope["request_expires_ms"]=q["request_expires_ms"]
    token,sealed:=channel.seal(reply_raw,p.kr,scope,now,context.temp_allocator)
    if !sealed do return {}
    if p.invalidate_at>0 && p.calls==p.invalidate_at do bridge_task_chain_search_lock()
    return {executor.encode(scope),token,p.directory}
}

bridge_executor_test_bootstrap_real_child :: proc(t:^testing.T,wire:Executor_Exchange_Wire,p,a:json.Object,owner_private:^ecdsa.Private_Key,owner_key:contracts.Owner_Verified_Key,
    directory:vault.Directory_Verification_Input,kr:^vault.Vault_Keyring) {
    binary:=bridge_env_get("HEIMDALL_EXECUTOR_TEST_PTY",context.temp_allocator)
    if !testing.expect(t,binary!="","real bootstrap integration requires the built PTY daemon") do return
    suffix:=fmt.tprintf("%d",time.to_unix_nanoseconds(time.now()))
    socket:=fmt.tprintf("/tmp/ham-bootstrap-%s.sock",suffix)
    swap:=pty_host_test_install_socket(socket);defer pty_host_test_restore_socket(swap)
    process,err:=os.process_start(os.Process_Desc{command=[]string{binary,"--socket",socket,"daemon"}})
    if !testing.expect(t,err==nil) do return
    defer {_=os.process_kill(process);_,_=os.process_wait(process);_=os.remove(socket)}
    ready:=false
    for _ in 0..<100 {if bridge_pty_host_ping(socket) {ready=true;break};time.sleep(10*time.Millisecond)}
    if !testing.expect(t,ready) do return
    now:=time.to_unix_nanoseconds(time.now())/1000000
    intent,claimed:=executor.take_intent(&bridge_executor_store,now)
    if !testing.expect(t,claimed) do return
    defer _=bridge_pty_host_executor_close(socket,intent.instance,intent.launch_key)
    material,available:=executor.launch_material(&bridge_executor_store,intent,now)
    if !testing.expect(t,available) do return
    dir:=fmt.tprintf("%s/.cache/heimdall-tests/bootstrap-live-%s",bridge_env_get("HOME",context.temp_allocator),suffix)
    defer bridge_prespawn_rmdir_all(dir)
    prev,had:=bridge_env_lookup("HEIMDALL_HAM_CTL_BIN",context.temp_allocator)
    defer {if had {bridge_test_env_set("HEIMDALL_HAM_CTL_BIN",prev)} else {bridge_test_env_unset("HEIMDALL_HAM_CTL_BIN")}}
    bridge_test_env_set("HEIMDALL_HAM_CTL_BIN","/bin/sh")
    result,written:=bridge_executor_materialize(dir,"unix:/isolated-bootstrap-child.sock",material,"claude")
    if !testing.expect(t,written) do return
    defer bridge_prespawn_result_delete(result)
    env:=bridge_pty_host_env_pairs(result.env)
    defer {for pair in env {delete(pair[0]);delete(pair[1])};delete(env)}
    prepare_probe:=Executor_Test_Prepare{dir,0}
    launch_io:=Executor_Launch_IO{&prepare_probe,bridge_executor_test_physical_prepare,socket}
    fence_probe:=Executor_Fence_Test_Probe{private=owner_private,kr=kr,directory=directory,action=a,owner_key=owner_key,prepare_probe=&prepare_probe}
    self_key:=contracts.Owner_Verified_Key{bridge_executor_store.account,bridge_executor_store.executor,bridge_executor_store.operator_key,
        bridge_identity_public_key_hex(bridge_cfg().daemon_id),"bridge",true,false}
    config,_:=contracts.owner_parse(material.configuration,"remote_configuration")
    mapping,_:=executor.directory_mapping(&bridge_executor_store,contracts.owner_string(config,"directory_id"))
    original_profile,profile_error:=profile_lookup("claude","claude",prepare_runtime=false)
    if !testing.expect(t,profile_error==.None) do return
    for mutation in ([4]string{"catalog","profile","missing","replacement"}) {
        fence_probe.calls=0;fence_probe.resource_mutation=mutation;fence_probe.resource_path=mapping.path
        _,rejected:=bridge_executor_test_exchange(t,wire,a,"action",owner_private,kr,self_key,
            fmt.tprintf("physical_resource_%s",mutation),&fence_probe,material.bootstrap,material.body,launch_io,true)
        testing.expect_value(t,rejected,"invalid_resources")
        refused_pid,refused_known:=bridge_pty_host_executor_query(socket,intent.instance,intent.launch_key)
        // The daemon never spawned this key: it reports trusted absence.
        testing.expect(t,refused_known && refused_pid==0,"resource changes reject before first Spawn")
        switch mutation {
        case "catalog":
            sync.rw_mutex_lock(&bridge_launch_configuration_mutex)
            bridge_provider_catalog_snapshot.providers[0].state="active"
            sync.rw_mutex_unlock(&bridge_launch_configuration_mutex)
        case "profile":
            testing.expect(t,profile_upsert(&original_profile,nil,bridge_executor_physical_clock(nil))==.None)
        case "missing","replacement":
            if mutation=="replacement" do testing.expect(t,os.remove(mapping.path)==nil)
            testing.expect(t,os.rename(fmt.tprintf("%s.saved",mapping.path),mapping.path)==nil)
        }
    }
    fence_probe.resource_mutation="";fence_probe.calls=0;prepare_probe.calls=0
    _,launch_code:=bridge_executor_test_exchange(t,wire,a,"action",owner_private,kr,self_key,"physical_activation",
        &fence_probe,material.bootstrap,material.body,launch_io,true)
    if !testing.expect_value(t,launch_code,"ok") do return
    delivered:=true;reason:="child_present"
    testing.expect(t,fence_probe.calls==1 && fence_probe.unlocked && fence_probe.startup_unlocked &&
        fence_probe.prepared_before_callback && prepare_probe.calls==1,"nonce follows file I/O and releases executor/startup gates")
    pid,known:=bridge_pty_host_executor_query(socket,intent.instance,intent.launch_key)
    testing.expect(t,known && pid>0)
    _,available=executor.launch_material(&bridge_executor_store,intent,now)
    testing.expect(t,!available,"a confirmed child cannot be rematerialized")
    _,launch_code=bridge_executor_test_exchange(t,wire,a,"action",owner_private,kr,self_key,"physical_activation_retry",
        &fence_probe,material.bootstrap,material.body,launch_io,true)
    testing.expect(t,launch_code=="ok" && prepare_probe.calls==1 && fence_probe.calls==1,
        "confirmed activation replay only queries the exact child without file I/O or a new nonce")
    again,queried:=bridge_pty_host_executor_query(socket,intent.instance,intent.launch_key)
    testing.expect(t,queried && again==pid)
    bootstrap,_:=contracts.executor_parse(material.bootstrap,"bootstrap")
    notice:=contracts.PTY_Notification_Delivery{
        protocol_version=1,source={intent.instance,contracts.owner_string(bootstrap,"launch_epoch"),contracts.owner_string(bootstrap,"run_count")},
        pid=fmt.tprintf("%d",pid),launch_key=contracts.owner_string(bootstrap,"token_generation"),operation_id="bootstrap_notice",delivery_id="bootstrap_notice_delivery",
        message="Inspect the owner checkpoint.",
    }
    prepared_notice:=bridge_pty_notification_request(socket,notice,PTY_NOTIFICATION_PREPARE,"")
    defer delete(prepared_notice.ticket);defer delete(prepared_notice.input_profile)
    testing.expect(t,prepared_notice.error==.None && prepared_notice.receipt.status=="partial" && prepared_notice.ticket!="",
        "real remote child retains the exact bootstrap notification identity without local token records")
    stale_notice:=notice;stale_notice.source.launch_epoch="replacement_epoch"
    rejected_notice:=bridge_pty_notification_request(socket,stale_notice,PTY_NOTIFICATION_QUERY,prepared_notice.ticket)
    defer delete(rejected_notice.ticket);defer delete(rejected_notice.input_profile)
    testing.expect(t,rejected_notice.error!=.None || rejected_notice.receipt.status=="child_mismatch",
        "replacement epoch cannot query the original child ticket")
    notification:=make(json.Object,context.temp_allocator)
    for entry in contracts.executor_schema("notification") do notification[entry.name]=bootstrap[entry.name]
    message:="[owner-local] task.hold checkpoint € 日本語 😀\n"
    bridge_executor_test_set(notification,"intent_id",strings.repeat("b",64,context.temp_allocator))
    bridge_executor_test_set(notification,"owner_commit_seq","17")
    bridge_executor_test_set(notification,"message_digest",contracts.owner_payload_digest(message))
    bridge_executor_test_set(notification,"issued_ms",fmt.tprintf("%d",time.to_unix_nanoseconds(time.now())/1000000))
    bridge_executor_test_set(notification,"request_expires_ms",fmt.tprintf("%d",time.to_unix_nanoseconds(time.now())/1000000+4000))
    physical_result,notification_code:=bridge_executor_test_exchange(t,wire,notification,"notification",owner_private,kr,self_key,"physical_notification_unsupported",
        nil,"","",Executor_Launch_IO{socket=socket},false,message)
    if !testing.expect_value(t,notification_code,"ok") do return
    testing.expect(t,contracts.executor_notification_result_matches(physical_result,notification,message,self_key,time.to_unix_nanoseconds(time.now())/1000000))
    testing.expect(t,contracts.owner_string(physical_result,"status")=="unsupported_not_delivered" &&
        contracts.owner_string(physical_result,"message_bytes_written")=="0","unvalidated real child fails closed with a signed exact zero-progress result")
    changed_notification:=make(json.Object,context.temp_allocator)
    for k,v in notification do changed_notification[k]=v
    bridge_executor_test_set(changed_notification,"launch_epoch","replacement_epoch")
    _,stale_notification:=bridge_executor_test_exchange(t,wire,changed_notification,"notification",owner_private,kr,self_key,"physical_notification_replacement",
        nil,"","",Executor_Launch_IO{socket=socket},false,message)
    testing.expect_value(t,stale_notification,"no_current_target")
    input:=executor.encode(contracts.Owner_Lease_Input{"1",contracts.owner_string(bootstrap,"chain_id"),contracts.owner_string(bootstrap,"task_id"),
        contracts.owner_string(bootstrap,"lease_id"),contracts.owner_string(bootstrap,"configuration_revision"),"1","live_child_hb","lease.heartbeat",
        contracts.owner_string(a,"request_expires_ms"),"existing_capability"})
    self:=contracts.Owner_Verified_Key{bridge_executor_store.account,bridge_executor_store.executor,bridge_executor_store.operator_key,
        bridge_identity_public_key_hex(bridge_cfg().daemon_id),"bridge",true,false}
    attested:=bridge_executor_child_attest(&bridge_executor_store,intent.instance,material.token_secret,input,socket,owner_key,self,{nil,bridge_executor_sign})
    if !testing.expect_value(t,attested.code,"ok") do return
    child_request,valid:=contracts.executor_parse(attested.body,"child_request")
    testing.expect(t,valid && contracts.executor_child_request_matches(child_request,bootstrap,input,self,owner_key,time.to_unix_nanoseconds(time.now())/1000000))
    probe:=Executor_Child_Test_Transport{t,directory,kr,owner_private,owner_key,0,0}
    transport:=Executor_Child_Transport{&probe,bridge_executor_test_child_directory,bridge_executor_test_child_exchange}
    native_event:=`{"schema":"ham.ext.v1","provider":"codex","ext_version":"0.1.0","event":"session","ts":"2026-11-07T00:00:00Z","session_id":"native_session","transcript_path":"/not-a-native-session.jsonl","payload":{"phase":"start","source":"startup"}}`
    native_params_value,_:=contracts.owner_content_document(native_event)
    native_params,_:=native_params_value.(json.Object)
    native_line:=executor.encode(struct{v:int,id,token,method:string,params:json.Object}{
        1,"native_session",material.token_secret,"agent.extension.event",native_params})
    native_response:=bridge_local_endpoint_handle_jsonl_line(native_line,transport,socket)
    testing.expectf(t,strings.contains(native_response,"notification_profile_unsupported") && probe.exchanges==0,
        "current remote child observes only its own native session; no legacy token or owner relay: %s",native_response)
    wrong_native:=executor.encode(struct{v:int,id,token,method:string,params:json.Object}{
        1,"native_wrong","wrong_secret","agent.extension.event",native_params})
    testing.expect(t,strings.contains(bridge_local_endpoint_handle_jsonl_line(wrong_native,transport,socket),"unauthenticated"))
    ready_line:=executor.encode(struct{v:int,id,token,method:string,params:json.Object}{
        1,"ready_local",material.token_secret,"agent.start_success",make(json.Object,context.temp_allocator)})
    readiness:=bridge_local_endpoint_handle_jsonl_line(ready_line,transport,socket)
    testing.expectf(t,strings.contains(readiness,`"accepted":true`) && probe.exchanges==0,
        "executor readiness uses exact live child without owner relay: %s",readiness)
    ready_rows,_:=executor.query(bridge_executor_store.db,"SELECT count(*),min(ready_ms) FROM executor_readiness")
    testing.expect(t,ready_rows[0][0]=="1")
    replay_readiness:=bridge_local_endpoint_handle_jsonl_line(ready_line,transport,socket)
    testing.expect(t,replay_readiness==readiness && probe.exchanges==0,"exact ready retry returns original local acknowledgement")
    ready_rows_after,_:=executor.query(bridge_executor_store.db,"SELECT count(*),min(ready_ms) FROM executor_readiness")
    testing.expect(t,ready_rows_after[0][0]=="1" && ready_rows_after[0][1]==ready_rows[0][1])
    bad_params:=make(json.Object,context.temp_allocator);bad_params["run_count"]=json.String("99")
    bad_ready:=executor.encode(struct{v:int,id,token,method:string,params:json.Object}{
        1,"ready_spoof",material.token_secret,"agent.start_success",bad_params})
    rejected_ready:=bridge_local_endpoint_handle_jsonl_line(bad_ready,transport,socket)
    testing.expect(t,strings.contains(rejected_ready,"malformed") && probe.exchanges==0,"readiness accepts no caller-selected launch fields")
    bad_ready=executor.encode(struct{v:int,id,token,method:string,params:json.Object}{
        1,"ready_wrong","wrong_secret","agent.start_success",make(json.Object,context.temp_allocator)})
    rejected_ready=bridge_local_endpoint_handle_jsonl_line(bad_ready,transport,socket)
    testing.expect(t,strings.contains(rejected_ready,"unauthenticated") && probe.exchanges==0)
    local,handled:=bridge_executor_agent("child_local",input,material.token_secret,transport,socket)
    testing.expectf(t,handled && strings.contains(local,`"code":"ok"`) && probe.exchanges==1,"mounted child endpoint: handled=%v exchanges=%d response=%s",handled,probe.exchanges,local)
    testing.expect(t,!strings.contains(local,material.token_secret),"child credential stays local")
    for mode in 1..=2 {
        probe.mode=mode
        local,handled=bridge_executor_agent("child_local_bad",input,material.token_secret,transport,socket)
        testing.expectf(t,handled && strings.contains(local,"invalid_owner_result"),"corrupted result or scope rejected: %s",local)
    }
    // Exercise signed renewal through the mounted encrypted ingress and exact
    // real daemon. Lose the local confirmation after IPC, then retry the same
    // signed version with a fresh nonce; neither path may rematerialize/spawn.
    renewal:=make(json.Object,context.temp_allocator)
    for name,value in a do renewal[name]=value
    renewal["method"]=json.String("heartbeat");renewal["operation_id"]=json.String("physical_renewal")
    renewal["deadline_version"]=json.String("2")
    renewal["owner_commit_seq"]=json.String("2")
    renewal["expires_ms"]=json.String(fmt.tprintf("%d",contracts.executor_number(a,"expires_ms")+10000))
    fence_probe.action=renewal
    testing.expect(t,executor.exec(bridge_executor_store.db,"CREATE TRIGGER fail_renewal_confirm BEFORE UPDATE ON executor_renewals BEGIN SELECT RAISE(ABORT,'lost confirmation'); END"))
    _,renew_code:=bridge_executor_test_exchange(t,wire,renewal,"action",owner_private,kr,self_key,"physical_renew_lost",
        &fence_probe,"","",launch_io,true)
    testing.expect_value(t,renew_code,"renewal_not_committed")
    _,auth_before_confirm:=executor.child_bootstrap(&bridge_executor_store,intent.instance,material.token_secret,time.to_unix_nanoseconds(time.now())/1000000)
    testing.expect(t,!auth_before_confirm,"pending renewal cannot authenticate a child")
    _,pending_relay:=bridge_executor_test_exchange(t,wire,renewal,"action",owner_private,kr,self_key,"physical_renew_generic_pending")
    testing.expect_value(t,pending_relay,"signer_unavailable")
    testing.expect(t,executor.exec(bridge_executor_store.db,"DROP TRIGGER fail_renewal_confirm"))
    renewed,renew_retry:=bridge_executor_test_exchange(t,wire,renewal,"action",owner_private,kr,self_key,"physical_renew_retry",
        &fence_probe,"","",launch_io,true)
    testing.expect(t,renew_retry=="ok" && contracts.owner_string(renewed,"deadline_version")=="2")
    calls_after_renewal:=fence_probe.calls
    _,renew_again:=bridge_executor_test_exchange(t,wire,renewal,"action",owner_private,kr,self_key,"physical_renew_exact",
        &fence_probe,"","",launch_io,true)
    testing.expect(t,renew_again=="ok" && fence_probe.calls==calls_after_renewal+1 &&
        prepare_probe.calls==1 && fence_probe.unlocked && fence_probe.startup_unlocked,
        "each physical renewal retry requires a fresh nonce and never prepares another child")
    same_pid,same_child:=bridge_pty_host_executor_query(socket,intent.instance,intent.launch_key)
    testing.expect(t,same_child && same_pid==pid)
    renewed_attestation:=bridge_executor_child_attest(&bridge_executor_store,intent.instance,material.token_secret,input,socket,owner_key,self,{nil,bridge_executor_sign})
    testing.expect_value(t,renewed_attestation.code,"ok")
    renewed_request,renewed_valid:=contracts.executor_parse(renewed_attestation.body,"child_request")
    signed_renewal,_:=contracts.executor_parse(bridge_executor_test_sign(renewal,"action",owner_private),"action")
    testing.expect(t,renewed_valid && contracts.executor_child_request_matches(renewed_request,bootstrap,input,self,owner_key,time.to_unix_nanoseconds(time.now())/1000000,signed_renewal))
    // Invalidate vault authority after the logical version commits but before
    // the second, physical nonce callback returns. No daemon version may move.
    blocked:=make(json.Object,context.temp_allocator)
    for name,value in renewal do blocked[name]=value
    blocked["operation_id"]=json.String("physical_renew_invalidated")
    blocked["deadline_version"]=json.String("3")
    blocked["owner_commit_seq"]=json.String("3")
    blocked["expires_ms"]=json.String(fmt.tprintf("%d",contracts.executor_number(a,"expires_ms")+20000))
    fence_probe.action=blocked;fence_probe.invalidate_at=fence_probe.calls+2
    _,blocked_code:=bridge_executor_test_exchange(t,wire,blocked,"action",owner_private,kr,self_key,"physical_renew_invalidate",
        &fence_probe,"","",launch_io,true)
    testing.expect_value(t,blocked_code,"vault_locked")
    controls,_:=executor.query(bridge_executor_store.db,"SELECT renewal_secret FROM executor_controls WHERE reservation_id=?",intent.reservation)
    _,still_version2:=bridge_pty_host_executor_renew(socket,intent.instance,intent.launch_key,controls[0][0],2,
        contracts.executor_number(renewal,"expires_ms"),contracts.executor_number(renewal,"hard_ms"))
    testing.expect(t,still_version2 && prepare_probe.calls==1,"vault invalidation cannot move daemon version or spawn")
    fence_probe.invalidate_at=0
    _,recovered_code:=bridge_executor_test_exchange(t,wire,blocked,"action",owner_private,kr,self_key,"physical_renew_after_invalidate",
        &fence_probe,"","",launch_io,true)
    testing.expect(t,recovered_code=="ok" && prepare_probe.calls==1,
        "new current generation and a fresh nonce may deliver only the same pending version")

    // The ledger still says confirmed, but physical absence must reject the
    // credential before any executor-attested owner request can be signed.
    testing.expect(t,bridge_pty_host_executor_close(socket,intent.instance,intent.launch_key))
    readiness=bridge_local_endpoint_handle_jsonl_line(ready_line,transport,socket)
    testing.expect(t,strings.contains(readiness,"child_not_current") && !strings.contains(readiness,`"accepted":true`),
        "durable ready evidence cannot replay after exact physical absence")
    attested=bridge_executor_child_attest(&bridge_executor_store,intent.instance,material.token_secret,input,socket,owner_key,self,{nil,bridge_executor_sign})
    testing.expect_value(t,attested.code,"child_not_current")
    stop:=make(json.Object,context.temp_allocator)
    for name,value in a do stop[name]=value
    stop["method"]=json.String("stop");stop["operation_id"]=json.String("bootstrap_real_stop");stop["deadline_version"]=json.String("3")
    now=time.to_unix_nanoseconds(time.now())/1000000
    stopped:=executor.action(&bridge_executor_store,bridge_executor_test_sign(stop,"action",owner_private),owner_key,now)
    testing.expect_value(t,stopped.code,"ok")
    stop_intent,taken:=executor.take_intent(&bridge_executor_store,now)
    if !testing.expect(t,taken && stop_intent.kind=="stop") do return
    delivered,reason=bridge_executor_dispatch(&bridge_executor_store,stop_intent,now,socket,{},nil,nil,&now,bridge_executor_test_clock)
    testing.expect(t,delivered && reason=="child_absent")
    absent,observed:=bridge_pty_host_executor_query(socket,intent.instance,intent.launch_key)
    testing.expect(t,observed && absent==0)
    _=p
}

Executor_Child_Test_Transport :: struct {
    t:^testing.T,directory:vault.Directory_Verification_Input,kr:^vault.Vault_Keyring,
    private:^ecdsa.Private_Key,key:contracts.Owner_Verified_Key,mode,exchanges:int,
}
bridge_executor_test_child_directory :: proc(ctx:rawptr,_:i64)->(vault.Directory_Verification_Input,bool) {
    p:=(^Executor_Child_Test_Transport)(ctx)
    unlocked:=sync.mutex_try_lock(&bridge_executor_mutex)
    testing.expect(p.t,unlocked,"directory HTTP must not hold executor mutex")
    if unlocked do sync.mutex_unlock(&bridge_executor_mutex)
    return p.directory,true
}
bridge_executor_test_child_sign :: proc(ctx:rawptr,kind:string,o:json.Object)->(string,bool) {
    name:=strings.trim_prefix(kind,"executor.")
    raw:=bridge_executor_test_sign(o,name,(^ecdsa.Private_Key)(ctx))
    signed,valid:=contracts.executor_parse(raw,name)
    return contracts.owner_string(signed,"signature"),valid
}
bridge_executor_test_child_exchange :: proc(ctx:rawptr,raw,input:string,_:i64)->Executor_Fence_Outcome {
    p:=(^Executor_Child_Test_Transport)(ctx);p.exchanges+=1
    unlocked:=sync.mutex_try_lock(&bridge_executor_mutex)
    testing.expect(p.t,unlocked,"owner HTTP must not hold executor mutex")
    if unlocked do sync.mutex_unlock(&bridge_executor_mutex)
    request,valid:=contracts.executor_parse(raw,"child_request")
    testing.expect(p.t,valid && contracts.owner_string(request,"input_digest")==contracts.owner_payload_digest(input))
    scope:=make(json.Object,context.temp_allocator)
    for name in ([8]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation","executor_incarnation"}) do scope[name]=request[name]
    digest,_:=contracts.executor_digest("child_request",request)
    scope["request_id"]=json.String("child_test");scope["method"]=json.String("child_request");scope["direction"]=json.String("request")
    scope["input_digest"]=json.String(digest);scope["fence_digest"]=request["prepare_digest"]
    scope["issued_ms"]=request["issued_ms"];scope["request_expires_ms"]=request["request_expires_ms"]
    body:=bridge_owner_json(owner.Result{code="ok",body="native owner result"})
    token,sealed:=owner.execution_child_result(request,body,scope,p.key,time.to_unix_nanoseconds(time.now())/1000000,p.kr,{p.private,bridge_executor_test_child_sign})
    testing.expect(p.t,sealed)
    scope["direction"]=json.String("response")
    if p.mode==1 do token=fmt.tprintf("%sx",token)
    if p.mode==2 do scope["input_digest"]=json.String(strings.repeat("0",64,context.temp_allocator))
    return {bridge_owner_json(scope),token,p.directory}
}

// This mounted-handler fixture isolates signature/storage acceptance. Physical
// dispatch is exercised separately below against the same retained bootstrap.
bridge_executor_test_accept_bootstrap_only :: proc(_: ^executor.Store,_:string,_:json.Object,
    _:contracts.Owner_Verified_Key,_:contracts.Owner_Verified_Key,_:^vault.Vault_Keyring,_:i64,
    _:rawptr,_:Executor_Fence_Exchange,_:Executor_Launch_IO)->(bool,string) {return true,"accepted"}

Executor_Test_Prepare :: struct {dir:string,calls:int}
bridge_executor_test_physical_prepare :: proc(ctx:rawptr,s:^executor.Store,intent:executor.Intent,now:i64)->(Pty_Host_Spawn_Request,string,bool) {
    p:=(^Executor_Test_Prepare)(ctx);p.calls+=1
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    sync.rw_mutex_shared_lock(&bridge_launch_configuration_mutex);defer sync.rw_mutex_shared_unlock(&bridge_launch_configuration_mutex)
    pin,current:=bridge_executor_launch_resource_pin(s,intent,now)
    if !current do return {},"",false
    material,available:=executor.launch_material(s,intent,now)
    if !available do return {},"",false
    result,written:=bridge_executor_materialize(p.dir,"unix:/isolated-bootstrap-child.sock",material,"claude")
    if !written do return {},"",false
    defer bridge_prespawn_result_delete(result)
    env:=bridge_pty_host_env_pairs(result.env)
    argv:=make([]string,1);argv[0]=strings.clone("sh")
    request:=Pty_Host_Spawn_Request{instance=strings.clone(intent.instance),argv=argv,cwd=strings.clone(p.dir),has_cwd=true,env=env,
        rows=24,cols=80,has_timeout_seconds=true,timeout_seconds=30}
    b,parsed:=contracts.executor_parse(material.bootstrap,"bootstrap")
    if !parsed || !bridge_executor_bind_notification_spawn(&request,b,material.token_secret) {
        bridge_pty_host_spawn_request_delete(request)
        return {},"",false
    }
    return request,pin,true
}
