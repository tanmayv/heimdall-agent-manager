package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"
import httpc "odin_test:lib/httpc"
import ws "odin_test:lib/ws"

// R3 one-shot legacy import, owner Bridge side. The Hub relays a device-signed
// selection and genesis plus the manifest digest; this Bridge fetches the
// frozen export document by document (no 64 KiB command cap), verifies every
// hash and imports in one local transaction. Activation is never taken from
// the relay: it is re-derived from Hub state (`imported`) on every nudge and
// periodically, so a restart between Hub cutover and local activation never
// yields two writers or a partial import.
Owner_Migration_Import_Wire :: struct {
    type,command_id,account_id,migration_id,chain_id,selection,genesis,manifest_digest:string,
    directory:vault.Directory_Verification_Input,
}
Owner_Migration_State_Wire :: struct { migration_id,chain_id,state,manifest_digest,owner_bridge_id:string }
Owner_Migration_Part_Wire :: struct { migration_id,manifest_digest,part,body:string }

bridge_owner_migration_last_reconcile:i64

bridge_owner_migration_fetch :: proc(migration,part:string)->(Owner_Migration_Part_Wire,bool) {
    token:=bridge_credential_snapshot();defer delete(token)
    headers:=[?]httpc.Header{httpc.bearer(token)}
    query:=[?]httpc.Query_Param{{"migration_id",migration},{"part",part}}
    response,err:=bridge_http_request_retry({method=.GET,url=bridge_hub_url(),path={"api","v1","owner-local","migrations","export"},query=query[:],headers=headers[:],timeout_ms=30000})
    defer httpc.response_destroy(&response)
    if err!=.None || response.status!=200 || len(httpc.text(response))>2*contracts.OWNER_MIGRATION_DOCUMENT_MAX do return {},false
    wire:struct{data:Owner_Migration_Part_Wire}
    if json.unmarshal_string(httpc.text(response),&wire,.JSON,context.temp_allocator)!=nil || wire.data.migration_id!=migration || wire.data.part!=part do return {},false
    return wire.data,true
}

bridge_owner_migration_state :: proc(_:rawptr,migration:string)->(Owner_Migration_State_Wire,bool) {
    token:=bridge_credential_snapshot();defer delete(token)
    headers:=[?]httpc.Header{httpc.bearer(token)}
    query:=[?]httpc.Query_Param{{"migration_id",migration}}
    response,err:=bridge_http_request_retry({method=.GET,url=bridge_hub_url(),path={"api","v1","owner-local","migrations","state"},query=query[:],headers=headers[:],timeout_ms=10000})
    defer httpc.response_destroy(&response)
    // An authenticated 404 means the Hub has no such migration for this owner:
    // it was aborted before cutover and can never be imported.
    if err==.None && response.status==404 do return Owner_Migration_State_Wire{migration_id=migration,state="absent"},true
    if err!=.None || response.status!=200 || len(httpc.text(response))>65536 do return {},false
    wire:struct{data:Owner_Migration_State_Wire}
    if json.unmarshal_string(httpc.text(response),&wire,.JSON,context.temp_allocator)!=nil do return {},false
    return wire.data,true
}

// Fetches the manifest and every document, checking each against the
// manifest digest the Hub committed to in the relay.
bridge_owner_migration_download :: proc(migration,manifest_digest:string)->(string,[]string,bool) {
    head,ok:=bridge_owner_migration_fetch(migration,"manifest")
    if !ok || head.manifest_digest!=manifest_digest || contracts.owner_payload_digest(head.body)!=manifest_digest do return "",nil,false
    manifest,valid:=contracts.owner_migration_manifest_parse(head.body)
    if !valid do return "",nil,false
    documents:=make([]string,len(manifest.documents),context.temp_allocator)
    for ref,i in manifest.documents {
        part,got:=bridge_owner_migration_fetch(migration,fmt.tprintf("%d",i))
        if !got || part.manifest_digest!=manifest_digest || i64(len(part.body))!=ref.bytes || contracts.owner_payload_digest(part.body)!=ref.sha256 do return "",nil,false
        documents[i]=part.body
    }
    return head.body,documents,true
}

bridge_owner_migration_import_handle :: proc(conn:^ws.Connection,text:string) {
    context.allocator=context.temp_allocator
    wire:Owner_Migration_Import_Wire
    if json.unmarshal_string(text,&wire,.JSON,context.temp_allocator)!=nil do return
    reply:=struct{type,command_id,code,receipt,genesis:string}{"command_result",wire.command_id,"invalid_scope","",""}
    defer {
        result:=bridge_owner_json(reply)
        bridge_runtime_cache_command(wire.command_id,result)
        if conn!=nil do _=bridge_hub_send(conn,result)
    }
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    selection,sel_ok:=contracts.owner_parse(wire.selection,"migration_selection")
    genesis,gen_ok:=contracts.owner_parse(wire.genesis,"genesis")
    get:=contracts.owner_string
    if !sel_ok || !gen_ok || wire.account_id!=account || get(selection,"account_id")!=account || get(selection,"owner_bridge_id")!=bridge_config.daemon_id ||
       get(selection,"migration_id")!=wire.migration_id || get(selection,"chain_id")!=wire.chain_id || !contracts.owner_hex(wire.manifest_digest,64) { return }
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked { reply.code="vault_locked";return }
    owner_pub:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    owner_id,id_ok:=vault.device_id_from_sign_pub(owner_pub,context.temp_allocator)
    if !id_ok do return
    // A replay needs no download: the stored receipt and owner genesis answer.
    sync.mutex_lock(&bridge_owner_mutex)
    if !bridge_owner_open(account,owner_id) { sync.mutex_unlock(&bridge_owner_mutex);reply.code="storage_error";return }
    receipt,lookup:=owner.migration_import_lookup(&bridge_owner_store,wire.migration_id,wire.chain_id,wire.manifest_digest)
    sync.mutex_unlock(&bridge_owner_mutex)
    if lookup=="ok" {
        reply.code="ok";reply.receipt=receipt;reply.genesis=owner.genesis_for(&bridge_owner_store,wire.chain_id)
        return
    }
    if lookup!="miss" { reply.code=lookup;return }
    manifest,documents,downloaded:=bridge_owner_migration_download(wire.migration_id,wire.manifest_digest)
    if !downloaded { reply.code="digest_mismatch";return }
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    floor,status:=keystore_read_epoch_floor(bridge_config.daemon_id)
    if status!=.Found || !floor.root.set do return
    pin_seq,pin_hash:=owner.directory_pin(&bridge_owner_store)
    key,owner_key,version,head,trusted:=owner.verify_directory(bridge_owner_json(wire.directory),account,bridge_config.daemon_id,owner_pub,get(selection,"principal_id"),get(selection,"key_id"),floor.root,pin_seq,pin_hash,&kr)
    if !trusted || !owner.observe_directory(&bridge_owner_store,version,head) do return
    if get(genesis,"owner_bridge_id")!=bridge_config.daemon_id || get(genesis,"owner_key_id")!=owner_key.key_id || !contracts.owner_verify_signature("genesis",genesis,"creator_signature",key) do return
    signature,signed:=bridge_owner_sign(nil,"genesis",genesis)
    if !signed do return
    genesis["owner_signature"]=json.String(signature)
    now:=time.to_unix_nanoseconds(time.now())/1000000
    result:=owner.migration_import(&bridge_owner_store,owner.Migration_Import_Input{wire.selection,bridge_owner_json(genesis),manifest,documents},key,owner_key,version,head,now,&kr,owner.Signer{nil,bridge_owner_sign})
    reply.code=result.code
    if result.code=="ok" {
        reply.receipt=result.body
        // The stored bytes, so a later replay returns the identical genesis.
        reply.genesis=owner.genesis_for(&bridge_owner_store,wire.chain_id)
    }
}

// The nudge carries no authority: it only triggers a Hub state check.
bridge_owner_migration_activate_handle :: proc(conn:^ws.Connection,text:string) {
    context.allocator=context.temp_allocator
    wire:struct{type,command_id,account_id,migration_id,chain_id,manifest_digest:string}
    if json.unmarshal_string(text,&wire,.JSON,context.temp_allocator)!=nil do return
    activated:=bridge_owner_migration_reconcile(true)
    result:=bridge_owner_json(struct{type,command_id,code:string,activated:int}{"command_result",wire.command_id,"ok",activated})
    bridge_runtime_cache_command(wire.command_id,result)
    if conn!=nil do _=bridge_hub_send(conn,result)
}

// Re-derives activation from Hub state. Rate limited unless forced.
bridge_owner_migration_reconcile :: proc(force:bool) -> int {
    now:=time.to_unix_nanoseconds(time.now())/1000000
    last:=sync.atomic_load(&bridge_owner_migration_last_reconcile)
    if !force && now-last<30000 do return 0
    sync.atomic_store(&bridge_owner_migration_last_reconcile,now)
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    owner_id,id_ok:=vault.device_id_from_sign_pub(bridge_identity_public_key_hex(bridge_config.daemon_id),context.temp_allocator)
    if account=="" || !id_ok do return 0
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return 0
    sync.mutex_lock(&bridge_owner_mutex)
    opened:=bridge_owner_open(account,owner_id)
    sync.mutex_unlock(&bridge_owner_mutex)
    if !opened do return 0
    activated:=bridge_owner_migration_reconcile_store(&bridge_owner_store,&bridge_owner_mutex,nil,bridge_owner_migration_state,now,&kr,owner.Signer{nil,bridge_owner_sign})
    if activated>0 {
        sync.mutex_lock(&bridge_owner_mutex)
        bridge_owner_publish()
        sync.mutex_unlock(&bridge_owner_mutex)
    }
    return activated
}

// Activates only imports the Hub reports `imported` with the same chain and
// manifest digest. Network lookups run outside the owner mutex.
bridge_owner_migration_reconcile_store :: proc(s:^owner.Store,mutex:^sync.Mutex,ctx:rawptr,lookup:proc(rawptr,string)->(Owner_Migration_State_Wire,bool),
    now:i64,kr:^vault.Vault_Keyring,sign:owner.Signer) -> int {
    sync.mutex_lock(mutex)
    pending,ok:=owner.migration_pending(s)
    sync.mutex_unlock(mutex)
    if !ok do return 0
    activated:=0
    for p in pending {
        state,found:=lookup(ctx,p[0])
        if found && state.state=="absent" {
            sync.mutex_lock(mutex)
            _=owner.migration_abandon(s,p[0])
            sync.mutex_unlock(mutex)
            continue
        }
        if !found || state.state!="imported" || state.chain_id!=p[1] || state.manifest_digest!=p[2] do continue
        sync.mutex_lock(mutex)
        result:=owner.migration_activate(s,p[0],p[2],now,kr,sign)
        sync.mutex_unlock(mutex)
        if result.code=="ok" && !result.replay do activated+=1
    }
    return activated
}
