package owner_local

import "core:crypto"
import "core:encoding/json"
import contracts "odin_test:contracts"
import channel "odin_test:lib/executor_channel"
import vault "odin_test:lib/vault"

// Current enrolled keys and the durably observed directory come from the
// caller's paired-root verification. The encrypted scope is still untrusted:
// authenticate it and the exact claimed intent before signing any fence reply.
execution_fence_channel_reply :: proc(s:^Store,token:string,scope:json.Object,executor_key,owner_key:contracts.Owner_Verified_Key,
    directory_version:i64,directory_hash:string,now:i64,kr:^vault.Vault_Keyring,sign:Signer)->Result {
    now:=store_now(s,now) // C1: the store's single clock source
    if field(scope,"method")!="fence_request" || field(scope,"direction")!="request" do return fail("invalid_scope")
    raw,authenticated:=channel.open_signed(token,kr,scope,executor_key,now,context.temp_allocator)
    if !authenticated do return fail("invalid_scope")
    defer crypto.zero_explicit(raw_data(raw),len(raw))
    result:=execution_fence_reply(s,raw,executor_key,owner_key,directory_version,directory_hash,now,sign)
    if result.code!="ok" do return result
    // Do not mutate the caller's saved request scope.
    response:=make(json.Object,context.temp_allocator)
    for name,value in scope do response[name]=value
    response["direction"]=json.String("response")
    sealed,ok:=channel.seal(result.body,kr,response,now,context.temp_allocator)
    if !ok do return fail("expired")
    result.body=sealed
    return result
}
