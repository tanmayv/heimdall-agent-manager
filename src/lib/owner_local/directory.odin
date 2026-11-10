package owner_local
import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// Persist a successfully verified paired directory independently of a command.
// Security observations survive even rejected commands and read-only replay.
// The caller must first verify_directory against the durable pin and root.
observe_directory :: proc(s:^Store,version:i64,hash:string) -> bool {
    if version<1 || hash=="" do return false
    tx:Transaction
    if !transaction_begin(s,&tx) do return false
    defer transaction_rollback(&tx)
    current,read:=query(s.db,"SELECT directory_version,directory_hash FROM runtime_database WHERE singleton=1")
    if !read || len(current)!=1 do return false
    if number(current[0][0])==version && current[0][1]==hash do return transaction_commit(&tx)
    rows,ok:=query(s.db,`UPDATE runtime_database SET directory_version=?,directory_hash=? WHERE singleton=1
      AND (directory_version<? OR (directory_version=? AND directory_hash=?)) RETURNING directory_version`,
      fmt.tprintf("%d",version),hash,fmt.tprintf("%d",version),fmt.tprintf("%d",version),hash)
    return ok && len(rows)==1 && transaction_commit(&tx)
}

// Only the caller's paired root and durable head are trusted. The relay's
// directory is signed evidence, never a caller-supplied key/grant assertion.
verify_directory :: proc(raw,account,owner,owner_public,principal,key_id:string,root:vault.Root_Pin,
    pin_seq:i64,pin_hash:string,kr:^vault.Vault_Keyring)->(contracts.Owner_Verified_Key,contracts.Owner_Verified_Key,i64,string,bool) {
    key,owner_key,version,head,code:=verify_directory_code(raw,account,owner,owner_public,principal,key_id,root,pin_seq,pin_hash,kr)
    return key,owner_key,version,head,code=="ok"
}

// verify_directory with the refusal reason: account_mismatch (a directory of
// another account), directory_unverified (no paired root, a bad signature, a
// pin rollback or another root: the evidence is unusable, not a refusal of the
// caller), invalid_scope (a verified directory that does not approve the
// signing device: unpaired, revoked or not a browser key signing for itself).
verify_directory_code :: proc(raw,account,owner,owner_public,principal,key_id:string,root:vault.Root_Pin,
    pin_seq:i64,pin_hash:string,kr:^vault.Vault_Keyring)->(contracts.Owner_Verified_Key,contracts.Owner_Verified_Key,i64,string,string) {
    if !root.set || len(raw)>2*1024*1024 do return {},{},0,"","directory_unverified"
    d:vault.Directory_Verification_Input
    if json.unmarshal_string(raw,&d,.JSON,context.temp_allocator)!=nil do return {},{},0,"","directory_unverified"
    if d.owner!=account do return {},{},0,"","account_mismatch"
    d.pin_seq=pin_seq;d.pin_hash=pin_hash
    dir,ok:=vault.directory_verify(d)
    if !ok || !vault.directory_verify_keyring(&dir,kr) do return {},{},0,"","directory_unverified"
    paired_root:=root
    pin,pinned:=vault.root_pin_from_hex(dir.root_device_id,vault.SIGN_ALG_ECDSA_P256_SHA256,dir.root_public_key)
    if !pinned || !vault.root_pin_equal(&paired_root,&pin) do return {},{},0,"","directory_unverified"
    owner_id,owner_id_ok:=vault.device_id_from_sign_pub(owner_public,context.temp_allocator)
    bridge,enrolled:=dir.trusted[owner_id]
    if !owner_id_ok || !enrolled || bridge.kind!="bridge" || bridge.sign_public_key!=owner_public do return {},{},0,"","directory_unverified"
    device,approved:=dir.trusted[principal]
    if !approved || device.kind!="browser" || key_id!=principal do return {},{},0,"","invalid_scope"
    return contracts.Owner_Verified_Key{account,principal,key_id,device.sign_public_key,"device",true,false},
      contracts.Owner_Verified_Key{account,owner,owner_id,owner_public,"bridge",true,false},dir.version,dir.head_hash,"ok"
}

// The signed device fleet.reserve configuration authorizes the Bridge ID/key
// pair. Directory approval alone never permits a remote key to claim another
// Bridge ID; execute verifies that device signature and the exact pairing.
verify_executor_directory :: proc(raw,account,executor,key_id:string,root:vault.Root_Pin,
    pin_seq:i64,pin_hash:string,kr:^vault.Vault_Keyring)->(contracts.Owner_Verified_Key,i64,string,bool) {
    if !root.set || len(raw)>2*1024*1024 || !contracts.owner_field_valid(executor,"id") do return {},0,"",false
    d:vault.Directory_Verification_Input
    if json.unmarshal_string(raw,&d,.JSON,context.temp_allocator)!=nil || d.owner!=account do return {},0,"",false
    d.pin_seq=pin_seq;d.pin_hash=pin_hash
    dir,ok:=vault.directory_verify(d)
    if !ok || !vault.directory_verify_keyring(&dir,kr) do return {},0,"",false
    pin,pinned:=vault.root_pin_from_hex(dir.root_device_id,vault.SIGN_ALG_ECDSA_P256_SHA256,dir.root_public_key)
    paired_root:=root
    if !pinned || !vault.root_pin_equal(&paired_root,&pin) do return {},0,"",false
    device,approved:=dir.trusted[key_id]
    derived,derived_ok:=vault.device_id_from_sign_pub(device.sign_public_key,context.temp_allocator)
    if !approved || device.kind!="bridge" || !derived_ok || derived!=key_id do return {},0,"",false
    return contracts.Owner_Verified_Key{account,executor,key_id,device.sign_public_key,"bridge",true,false},dir.version,dir.head_hash,true
}
