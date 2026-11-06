package owner_local
import "core:encoding/json"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// Only the caller's paired root and durable head are trusted. The relay's
// directory is signed evidence, never a caller-supplied key/grant assertion.
verify_directory :: proc(raw,account,owner,owner_public,principal,key_id:string,root:vault.Root_Pin,
    pin_seq:i64,pin_hash:string,kr:^vault.Vault_Keyring)->(contracts.Owner_Verified_Key,contracts.Owner_Verified_Key,i64,string,bool) {
    if !root.set || len(raw)>2*1024*1024 do return {},{},0,"",false
    d:vault.Directory_Verification_Input
    if json.unmarshal_string(raw,&d,.JSON,context.temp_allocator)!=nil || d.owner!=account do return {},{},0,"",false
    d.pin_seq=pin_seq;d.pin_hash=pin_hash
    dir,ok:=vault.directory_verify(d)
    if !ok || !vault.directory_verify_keyring(&dir,kr) do return {},{},0,"",false
    paired_root:=root
    pin,pinned:=vault.root_pin_from_hex(dir.root_device_id,vault.SIGN_ALG_ECDSA_P256_SHA256,dir.root_public_key)
    if !pinned || !vault.root_pin_equal(&paired_root,&pin) do return {},{},0,"",false
    device,approved:=dir.trusted[principal]
    owner_id,owner_id_ok:=vault.device_id_from_sign_pub(owner_public,context.temp_allocator)
    bridge,enrolled:=dir.trusted[owner_id]
    if !approved || device.kind!="browser" || key_id!=principal || !owner_id_ok || !enrolled || bridge.kind!="bridge" || bridge.sign_public_key!=owner_public do return {},{},0,"",false
    return contracts.Owner_Verified_Key{account,principal,key_id,device.sign_public_key,"device",true,false},
      contracts.Owner_Verified_Key{account,owner,owner_id,owner_public,"bridge",true,false},dir.version,dir.head_hash,true
}
