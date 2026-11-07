#+feature dynamic-literals
package main

import "core:crypto"
import "core:encoding/json"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import vault "odin_test:lib/vault"
import ws "odin_test:lib/ws"

// Resolve the preparing browser and this execution Bridge against the newest
// verified paired directory, never a draft-time key snapshot or account AEAD.
bridge_executor_local_keys :: proc(s:^executor.Store,o:json.Object,d:vault.Directory_Verification_Input,kr:^vault.Vault_Keyring)->(contracts.Owner_Verified_Key,bool) {
    dir,trusted:=bridge_executor_directory(s,d,kr)
    if !trusted do return {},false
    own,self_ok:=dir.trusted[s.operator_key]
    peer,device_ok:=dir.trusted[contracts.owner_string(o,"principal_id")]
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    if !self_ok || own.kind!="bridge" || own.sign_public_key!=public || !device_ok || peer.kind!="browser" ||
       peer.id!=contracts.owner_string(o,"key_id") {return {},false}
    key:=contracts.Owner_Verified_Key{s.account,peer.id,peer.id,peer.sign_public_key,"device",true,false}
    return key,contracts.executor_verify("local_draft",o,key)
}

Executor_Local_Apply :: #type proc(^executor.Store,string,json.Object,contracts.Owner_Verified_Key,^vault.Vault_Keyring,i64)->executor.Result

// Request and reply are encrypted with the current account epoch. Both sides
// additionally verify enrolled signatures and exact request/result digests.
// The Hub only routes bounded ciphertext and supplies paired-directory proof.
bridge_executor_local_handle :: proc(conn:^ws.Connection,text:string,apply:Executor_Local_Apply=bridge_executor_local_apply) {
    context.allocator=context.temp_allocator
    generation:=bridge_task_chain_search_generation()
    wire:Executor_Issuance_Wire
    if len(text)>3*1024*1024 || json.unmarshal_string(text,&wire,.JSON,context.temp_allocator)!=nil do return
    relay,valid:=contracts.executor_parse(wire.relay,"local_relay")
    if !valid do return
    get:=contracts.owner_string
    reply:=struct{type,command_id,request_id,code,envelope:string}{"command_result",wire.command_id,get(relay,"request_id"),"invalid_scope",""}
    defer {
        if bridge_task_chain_search_generation()!=generation {reply.code="vault_locked";reply.envelope=""}
        result:=bridge_owner_json(reply)
        bridge_runtime_cache_command(wire.command_id,result)
        if conn!=nil do _=bridge_hub_send(conn,result)
    }
    now:=bridge_executor_physical_clock(nil)
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    expires:=contracts.executor_number(relay,"expires_ms")
    if account=="" || wire.account_id!=account || get(relay,"bridge_id")!=bridge_config.daemon_id ||
       expires<=now || expires-now>contracts.EXECUTOR_TRANSPORT_TTL_MS {return}
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked {reply.code="vault_locked";return}
    raw,opened:=bridge_open_current_epoch_token(get(relay,"envelope"),&kr,context.temp_allocator)
    if !opened do return
    defer crypto.zero_explicit(raw_data(raw),len(raw))
    o,parsed:=contracts.executor_parse(raw,"local_draft")
    if !parsed || get(o,"account_id")!=account || get(o,"executor_bridge_id")!=bridge_config.daemon_id do return
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    key_id,key_ok:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !key_ok do return
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    if !bridge_executor_open(account,key_id) {reply.code="storage_error";return}
    s:=&bridge_executor_store
    key,authenticated:=bridge_executor_local_keys(s,o,wire.directory,&kr)
    if !authenticated do return
    // Startup serialization also covers explicit cancellation versus first I/O.
    // The production apply wrapper re-resolves resources and keys after any
    // delayed preparation and holds the vault gate through physical dispatch.
    result:=apply(s,raw,o,key,&kr,generation)
    reply.code=result.code
    body:=bridge_owner_json(struct{code,body:string}{result.code,result.body})
    issued:=time.to_unix_nanoseconds(time.now())/1000000
    if issued>=expires {reply.code="expired";return}
    receipt:=make(json.Object,context.temp_allocator)
    for pair in ([12][2]string{{"protocol_version","1"},{"account_id",account},{"executor_bridge_id",s.executor},
        {"principal_id",key.principal_id},{"operation_id",get(o,"operation_id")},{"request_id",get(relay,"request_id")},
        {"request_digest",""},{"result_digest",contracts.owner_payload_digest(body)},{"issued_ms",executor.encode(issued)},
        {"request_expires_ms",get(relay,"expires_ms")},{"key_id",key_id},{"signature",""}}) {
        receipt[pair[0]]=json.String(pair[1])
    }
    digest,_:=contracts.executor_digest("local_draft",o)
    receipt["request_digest"]=json.String(digest)
    // Signer validates shape, including its placeholder signature.
    receipt["signature"]=json.String("00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    signature,signed:=bridge_executor_sign(nil,"local_result",receipt)
    if !signed {reply.code="signing_failed";return}
    receipt["signature"]=json.String(signature)
    bundle:=bridge_owner_json(struct{receipt,body:string}{bridge_owner_json(receipt),body})
    reply.envelope,_=bridge_encrypt_vault_text(bundle,&kr,context.temp_allocator)
}

// Installed production entrypoint for lifecycle methods. Authorization is
// admitted by the same transaction as the draft and never implies readiness.
bridge_executor_local_apply :: proc(s:^executor.Store,raw:string,o:json.Object,key:contracts.Owner_Verified_Key,kr:^vault.Vault_Keyring,generation:i64)->executor.Result {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    if !bridge_executor_authority_begin(generation) do return executor.Result{code="vault_locked"}
    defer bridge_executor_authority_end()
    // Native startup/Spawn construction is not wired at this checkpoint.
    // In particular, authorize has no trusted resources and fails closed;
    // prepare/inspect/cancel operate on retained native drafts only.
    return executor.local_draft_command(s,raw,key,bridge_executor_physical_clock(nil))
}
