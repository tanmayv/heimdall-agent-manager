#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:testing"
import vault "odin_test:lib/vault"

@(test)
remote_directory_requires_current_approved_bridge_key_and_paired_root :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    vector:struct {keyring_hex,device_id,bridge_device_id:string,job:vault.Control_Job}
    if !testing.expect(t,json.unmarshal_string(#load("../../../tests/fixtures/mcp_worker_v2.json",string),&vector,.JSON,context.temp_allocator)==nil) do return
    raw:=make([]byte,len(vector.keyring_hex)/2,context.temp_allocator)
    testing.expect(t,vault.hex_decode_into(raw,vector.keyring_hex))
    kr,parsed:=vault.keyring_parse(raw,vector.job.owner);defer vault.keyring_wipe(&kr)
    if !testing.expect(t,parsed) do return
    directory,verified:=vault.directory_verify(vector.job.directory)
    if !testing.expect(t,verified) do return
    root,pinned:=vault.root_pin_from_hex(directory.root_device_id,vault.SIGN_ALG_ECDSA_P256_SHA256,directory.root_public_key)
    if !testing.expect(t,pinned) do return
    proof:=encode(vector.job.directory)
    key,version,head,ok:=verify_executor_directory(proof,vector.job.owner,"explicit_executor",vector.bridge_device_id,root,directory.version,directory.head_hash,&kr)
    testing.expect(t,ok && key.kind=="bridge" && key.enrolled && key.principal_id=="explicit_executor" && key.key_id==vector.bridge_device_id && version==directory.version && head==directory.head_hash)
    _,_,_,ok=verify_executor_directory(proof,vector.job.owner,"explicit_executor",vector.device_id,root,directory.version,directory.head_hash,&kr)
    testing.expect(t,!ok,"an approved browser cannot attest a reserved executor")
    _,_,_,ok=verify_executor_directory(proof,vector.job.owner,"explicit_executor","unknown",root,directory.version,directory.head_hash,&kr)
    testing.expect(t,!ok)
    _,_,_,ok=verify_executor_directory(proof,vector.job.owner,"explicit_executor",vector.bridge_device_id,root,directory.version+1,directory.head_hash,&kr)
    testing.expect(t,!ok,"stale signed directories cannot undo a newer observed pin")
    _,_,_,ok=verify_executor_directory(proof,vector.job.owner,"explicit_executor",vector.bridge_device_id,root,directory.version,"fork",&kr)
    testing.expect(t,!ok)
    root.sign_pub[1]~=1
    _,_,_,ok=verify_executor_directory(proof,vector.job.owner,"explicit_executor",vector.bridge_device_id,root,directory.version,directory.head_hash,&kr)
    testing.expect(t,!ok)
}
