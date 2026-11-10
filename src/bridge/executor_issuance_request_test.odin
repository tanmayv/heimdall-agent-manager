package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:testing"
import channel "odin_test:lib/executor_channel"
import vault "odin_test:lib/vault"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

// bridge_executor_issuance_request: the owner Bridge's consent and relay for
// placing work on another Bridge of the account. The executor side
// (bridge_executor_issuance_handle) must accept exactly what this builds:
// the consent verifies against the owner Bridge key, names this Bridge as
// principal and owner, binds the selection, and travels in a scope the
// executor checks field by field.

executor_request_test_signer :: proc(ctx:rawptr,kind:string,o:json.Object)->(string,bool) {
    canonical,ok:=contracts.executor_canonical(kind,o)
    if !ok do return "",false
    sig,signed:=vault.sign_p256((^ecdsa.Private_Key)(ctx),transmute([]byte)canonical)
    if !signed do return "",false
    return vault.hex_encode_lower(sig.sig[:],context.temp_allocator),true
}

@(test)
test_executor_issuance_request_is_admitted_by_the_executor :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    owner_private:ecdsa.Private_Key
    if !testing.expect(t,vault.p256_private_key_generate(&owner_private)) do return
    defer ecdsa.private_key_clear(&owner_private)
    pub:[65]byte
    ecdsa.private_key_public_bytes(&owner_private,pub[:])
    owner_pub:=vault.hex_encode_lower(pub[:],context.temp_allocator)
    owner_key_id,_:=vault.device_id_from_sign_pub(owner_pub,context.temp_allocator)
    exec_id,exec_pub:=executor_consent_test_key(t)

    id:vault.Vault_Id;id[0]=7
    epoch_key:[32]byte;epoch_key[3]=9
    kr,kr_ok:=vault.keyring_from_single_key("acct_1",id,1,epoch_key[:])
    if !testing.expect(t,kr_ok) do return
    defer vault.keyring_wipe(&kr)

    selection:=make(json.Object)
    for pair in ([6][2]string{{"provider","claude"},{"model","default"},{"provider_profile","claude"},
        {"directory_id","dir_remote"},{"policy_revision","1"},{"slot_id","slot1"}}) {selection[pair[0]]=json.String(pair[1])}
    input:=Executor_Issuance_Request_Input{account="acct_1",owner_bridge="brg_owner",owner_key_id=owner_key_id,
        executor_bridge="brg_exec",executor_key_id=exec_id,chain_id="chain_1",task_id="task_1",agent_id="agt_1",
        configuration_revision="1",owner_incarnation="1",executor_incarnation="2",selection=selection,now=1_000_000}
    signer:=executor.Signer{&owner_private,executor_request_test_signer}
    request,ok:=bridge_executor_issuance_request(input,&kr,signer)
    if !testing.expect(t,ok,"the owner Bridge builds a request") do return
    get:=contracts.owner_string

    // The consent: this Bridge is principal and owner, and it verifies
    // against the owner Bridge key (contracts executor_signer_kind).
    consent:=request.consent_doc
    testing.expect_value(t,get(consent,"principal_id"),"brg_owner")
    testing.expect_value(t,get(consent,"owner_bridge_id"),"brg_owner")
    testing.expect_value(t,get(consent,"key_id"),owner_key_id)
    testing.expect_value(t,get(consent,"selection_digest"),contracts.owner_payload_digest(request.selection))
    owner_key:=contracts.Owner_Verified_Key{"acct_1","brg_owner",owner_key_id,owner_pub,"bridge",true,false}
    testing.expect(t,contracts.executor_verify("issuance_consent",consent,owner_key),"the owner Bridge key verifies its consent")
    other_key:=owner_key;other_key.principal_id="brg_other"
    testing.expect(t,!contracts.executor_verify("issuance_consent",consent,other_key),"no other Bridge verifies it")
    revoked:=owner_key;revoked.revoked=true
    testing.expect(t,!contracts.executor_verify("issuance_consent",consent,revoked),"a revoked owner key never verifies")

    // The executor resolves this Bridge as the consenter only when the Hub
    // stamped this Bridge as the relaying sender.
    dir:vault.Verified_Directory
    dir.trusted=make(map[string]vault.Verified_Directory_Device)
    dir.trusted[owner_key_id]={id=owner_key_id,kind="bridge",sign_public_key=owner_pub}
    dir.trusted[exec_id]={id=exec_id,kind="bridge",sign_public_key=exec_pub}
    key,admitted:=bridge_executor_consent_key(&dir,consent,"acct_1",exec_id,"brg_owner")
    testing.expect(t,admitted && key.public_key==owner_pub,"the executor admits the owner Bridge's consent")
    _,admitted=bridge_executor_consent_key(&dir,consent,"acct_1",exec_id,"brg_other")
    testing.expect(t,!admitted,"relayed by another Bridge it is refused")

    // The relay and exchange carry exactly what bridge_executor_issuance_handle checks.
    relay,relay_ok:=contracts.owner_parse(request.relay,"relay")
    if !testing.expect(t,relay_ok,"the relay parses") do return
    testing.expect_value(t,get(relay,"bridge_id"),"brg_exec")
    testing.expect_value(t,get(relay,"chain_id"),"chain_1")
    plain,opened:=vault.open(get(relay,"envelope"),&kr,context.temp_allocator)
    if !testing.expect(t,opened==.Ok) do return
    exchange,parsed:=contracts.executor_parse(plain,"issuance_exchange")
    scope,scoped:=contracts.executor_parse(get(exchange,"scope"),"transport_scope")
    if !testing.expect(t,parsed && scoped) do return
    testing.expect(t,get(scope,"method")=="enrollment" && get(scope,"direction")=="request","enrollment request scope")
    testing.expect(t,get(scope,"executor_bridge_id")=="brg_exec" && get(scope,"account_id")=="acct_1","scope names the executor and account")
    testing.expect_value(t,get(scope,"request_id"),get(relay,"request_id"))
    testing.expect(t,contracts.executor_number(scope,"request_expires_ms")<=contracts.executor_number(relay,"expires_ms"),"scope expires within the relay")
    testing.expect_value(t,get(scope,"executor_incarnation"),"2")
    testing.expect_value(t,get(exchange,"selection"),request.selection)
    raw,clear:=channel.open(get(exchange,"envelope"),&kr,scope,1_000_000)
    testing.expect(t,clear && raw==request.consent,"the sealed consent is the signed consent")
    verified,authenticated:=channel.open_signed(get(exchange,"envelope"),&kr,scope,key,1_000_000)
    testing.expect(t,authenticated && verified==request.consent,"the executor authenticates the sealed consent")

    // A retry reuses the consent's operation id.
    input.operation_id=get(consent,"operation_id")
    retry,retry_ok:=bridge_executor_issuance_request(input,&kr,signer)
    testing.expect(t,retry_ok && get(retry.consent_doc,"operation_id")==input.operation_id,"a retry keeps the operation id")

    // A reply that is not ok, for another request, or empty never opens.
    _,reply_ok:=bridge_executor_issuance_reply_open(request,"invalid_scope",get(request.scope,"request_id"),"x",&kr,owner_key,owner_key,1_000_000)
    testing.expect(t,!reply_ok,"a refused reply never opens")
    _,reply_ok=bridge_executor_issuance_reply_open(request,"ok","req_other","x",&kr,owner_key,owner_key,1_000_000)
    testing.expect(t,!reply_ok,"a reply for another request never opens")

    // The builder refuses self-placement and a non-selection.
    self:=input;self.executor_bridge="brg_owner"
    _,ok=bridge_executor_issuance_request(self,&kr,signer)
    testing.expect(t,!ok,"a Bridge never requests issuance on itself")
    same_key:=input;same_key.executor_key_id=owner_key_id
    _,ok=bridge_executor_issuance_request(same_key,&kr,signer)
    testing.expect(t,!ok,"the executor key is never the owner key")
    bad:=input;bad.selection=make(json.Object)
    _,ok=bridge_executor_issuance_request(bad,&kr,signer)
    testing.expect(t,!ok,"an invalid selection is refused")
    _,ok=bridge_executor_issuance_request(input,&kr,executor.Signer{})
    testing.expect(t,!ok,"no signer, no request")
}
