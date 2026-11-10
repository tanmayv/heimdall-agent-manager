package owner_local

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// Cross-Bridge agent access (origin/main parity: the Hub served every Bridge of
// the account). An agent on another paired Bridge of this account (Bridge B)
// reads a chain this Bridge owns, or comments on one of its tasks. B proves its
// own live child from the agent's instance token, then signs this request with
// its enrolled Bridge identity key and seals it with the account vault; the Hub
// only routes it. The owner Bridge admits it when:
//   - the signing key is an approved Bridge key in the current directory of
//     THIS account, verified against the paired root (another account,
//     unpaired or revoked keys never verify);
//   - the signature covers the exact request bytes (domain separated);
//   - the request names this account and this owner Bridge, is fresh (at most
//     60s ahead) and carries a valid child;
//   - the method is one any agent of the account may use on any owner chain
//     (agent_account_verb): show a chain or task, read or post task comments.
// The child is B's attestation, never a member here, so agent_authorize grants
// it only those account-wide verbs. Assignment and placement on another Bridge
// are not admitted here.
REMOTE_AGENT_DOMAIN :: "heimdall-owner-local/remote_agent/v1\n"
REMOTE_AGENT_TTL_MS :: 60000

Remote_Agent_Request :: struct {
    account_id,owner_bridge_id,from_bridge_id,from_key_id,request_id,method,params:string,
    expires_ms:i64,
    instance,epoch,token_generation,agent_id:string,
    run_count:i64,
}

// The agent verbs a remote Bridge may relay, all mapped onto agent_account_verb.
remote_agent_method :: proc(method:string) -> bool {
    switch method {
    case "agent.task.show","agent.task.comments","agent.task.comment","agent.task_chain.show": return true
    }
    return false
}

// The exact bytes a remote Bridge signs.
remote_agent_message :: proc(request_raw:string) -> []byte {
    return transmute([]byte)strings.concatenate({REMOTE_AGENT_DOMAIN,request_raw},context.temp_allocator)
}

// Returns the parsed request, its attested child and "ok", or a refusal code:
// malformed, account_mismatch, owner_mismatch, expired, directory_unverified,
// invalid_scope (key not an approved Bridge key of this account, or a verb a
// remote agent may not use), bad_signature.
remote_agent_admit :: proc(directory_raw,account,owner_bridge,request_raw,signature_hex:string,root:vault.Root_Pin,
    pin_seq:i64,pin_hash:string,kr:^vault.Vault_Keyring,now:i64) -> (Remote_Agent_Request,Child,contracts.Owner_Verified_Key,string) {
    r,child,code:=remote_agent_parse(account,owner_bridge,request_raw,now)
    if code!="ok" do return {},{},{},code
    if !root.set do return {},{},{},"directory_unverified"
    key,_,_,approved:=verify_executor_directory(directory_raw,account,r.from_bridge_id,r.from_key_id,root,pin_seq,pin_hash,kr)
    if !approved do return {},{},{},"invalid_scope"
    if code=remote_agent_signed(request_raw,signature_hex,key);code!="ok" do return {},{},{},code
    return r,child,key,"ok"
}

// The request's own checks, before any key is looked up.
remote_agent_parse :: proc(account,owner_bridge,request_raw:string,now:i64) -> (Remote_Agent_Request,Child,string) {
    r:Remote_Agent_Request
    if len(request_raw)>contracts.OWNER_DOCUMENT_MAX || json.unmarshal_string(request_raw,&r,.JSON,context.temp_allocator)!=nil do return {},{},"malformed"
    if r.account_id!=account do return {},{},"account_mismatch"
    if r.owner_bridge_id!=owner_bridge do return {},{},"owner_mismatch"
    if r.expires_ms<=now || r.expires_ms-now>REMOTE_AGENT_TTL_MS do return {},{},"expired"
    child:=Child{r.instance,r.epoch,r.token_generation,r.run_count,r.agent_id}
    if !agent_child_valid(child) || !contracts.owner_field_valid(r.from_bridge_id,"id") || r.from_bridge_id==owner_bridge do return {},{},"malformed"
    if !remote_agent_method(r.method) do return {},{},"invalid_scope"
    return r,child,"ok"
}

// The signature of a directory-verified, enrolled, unrevoked Bridge key over
// the exact request bytes.
remote_agent_signed :: proc(request_raw,signature_hex:string,key:contracts.Owner_Verified_Key) -> string {
    if key.kind!="bridge" || !key.enrolled || key.revoked do return "invalid_scope"
    sig,sig_ok:=vault.signature_text_from_parts("ecdsa-p256-sha256",signature_hex,context.temp_allocator)
    if !sig_ok || !vault.verify("ecdsa-p256-sha256",key.public_key,remote_agent_message(request_raw),sig) do return "bad_signature"
    return "ok"
}
