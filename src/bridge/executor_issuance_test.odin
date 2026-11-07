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
    callback_spec,callback_known:=bridge_command_spec("owner_executor_fence")
    testing.expect(t,callback_known && callback_spec.queued && callback_spec.class==.Interactive && callback_spec.key_kind==.None && callback_spec.retry_safe,
        "nonce callback must not wait behind an executor's Exclusive job or Bridge ordering key")
    activate_spec,activate_known:=bridge_command_spec("executor_activation")
    testing.expect(t,activate_known && activate_spec.queued && activate_spec.class==.General_IO && activate_spec.key_kind==.None && activate_spec.retry_safe)

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
    // Enroll a distinct owner signing key under the same real paired root.
    owner_private,owner_key:=bridge_executor_test_key("owner1","pending",2)
    defer ecdsa.private_key_clear(&owner_private)
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
        {"owner_bridge_id","owner1"},{"owner_key_id",owner_id},{"creator_id",g.subject_device_id},{"creator_key_id",g.subject_device_id},
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
            rows,_=executor.query(bridge_executor_store.db,"SELECT count(*) FROM executor_intents WHERE kind='launch'")
            testing.expect_value(t,rows[0][0],"1")
            // Trusted test-daemon absence drains the charge before the next
            // reservation. No physical provider/absence claim is inferred.
            testing.expect(t,executor.observe_child(&bridge_executor_store,get(prepared,"reservation_id"),
                {get(prepared,"instance_id"),get(accepted,"launch_key"),bridge_executor_store.incarnation,false}))
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
    dispatch_pin:=Owner_Executor_Pin{key_id,bridge_task_chain_search_generation()}
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
    private:^ecdsa.Private_Key,kr:^vault.Vault_Keyring,self:contracts.Owner_Verified_Key,id:string,probe:^Executor_Fence_Test_Probe=nil)->(json.Object,string) {
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
    outer,outer_ok:=vault.seal(transmute([]byte)exchange,kr);testing.expect(t,outer_ok)
    call:=wire;call.command_id=id
    call.relay=executor.encode(struct{protocol_version,chain_id,bridge_id,request_id,expires_ms,envelope:string}{
        "1",get(request,"chain_id"),get(request,"executor_bridge_id"),id,fmt.tprintf("%d",now+60000),outer})
    if probe==nil {bridge_executor_exchange_handle(nil,executor.encode(call))} else {
        bridge_executor_exchange_handle(nil,executor.encode(call),true,probe,bridge_executor_test_fence_callback)
    }
    cached,found:=bridge_runtime_cached_command(id)
    if !found do return nil,"test_no_reply"
    value,_:=contracts.owner_content_document(cached);response,_:=value.(json.Object)
    code:=get(response,"code")
    if code!="ok" do return nil,code
    scope["direction"]=json.String("response")
    plain,opened:=channel.open_signed(get(response,"envelope"),kr,scope,self,time.to_unix_nanoseconds(time.now())/1000000)
    if !opened do return nil,"test_bad_reply"
    receipt,valid:=contracts.executor_parse(plain,"receipt")
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
}
bridge_executor_test_fence_callback :: proc(ctx:rawptr,raw:string,generation:i64)->Executor_Fence_Outcome {
    p:=(^Executor_Fence_Test_Probe)(ctx);p.calls+=1
    q,valid:=contracts.executor_parse(raw,"fence_request")
    if !valid do return {}
    get:=contracts.owner_string
    now:=time.to_unix_nanoseconds(time.now())/1000000
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
    return {executor.encode(scope),token,p.directory}
}
