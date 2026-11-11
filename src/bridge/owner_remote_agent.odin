package main

// Cross-Bridge agent access, owner side (owner.remote_agent_admit). Another
// paired Bridge of the account relays one of its agents' read/comment verbs on
// a chain this Bridge owns through the Hub (POST /api/v1/owner-local/agent-relay,
// Bridge token only). The Hub sets from_bridge_id from the caller's token and
// routes only to the chain's registered owner; this Bridge still verifies the
// request itself: the signing key is an approved Bridge key of this account in
// the current directory, the request is fresh and names this account and this
// Bridge, and the verb is account-wide (show a chain or task, read or post task
// comments) or a review post by one of the task's reviewers (the store trusts
// a relayed reviewer by agent id, relayed_reviewer_authorized). The verb then runs exactly like a local agent's, signed by this
// Bridge's owner key in agent mode, so agent_authorize re-checks it.
//
// Lock order is the owner one: bridge_owner_mutex -> bridge_startup_io_mutex
// -> bridge_local_token_mutex (the remote child needs no token lookup, so only
// the owner mutex is held).

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"
import owner "odin_test:lib/owner_local"
import ws "odin_test:lib/ws"
import httpc "odin_test:lib/httpc"

Owner_Remote_Agent_Command :: struct {
    type,command_id,account_id,from_bridge_id:string,
    // The request JSON sealed with the account vault, and the sender's
    // signature over owner.remote_agent_message(request).
    request,signature:string,
    directory:vault.Directory_Verification_Input,
}

bridge_owner_remote_agent_handle :: proc(conn:^ws.Connection,text:string) {
    context.allocator=context.temp_allocator
    wire:Owner_Remote_Agent_Command
    if json.unmarshal_string(text,&wire,.JSON,context.temp_allocator)!=nil do return
    code,envelope:=bridge_owner_remote_agent(wire)
    result:=bridge_owner_json(struct{type,command_id,code,envelope:string}{"command_result",wire.command_id,code,envelope})
    bridge_runtime_cache_command(wire.command_id,result)
    if conn!=nil do _=bridge_hub_send(conn,result)
}

// Returns a refusal code, or "ok" and the sealed local-response JSON of the verb
// (its own ok/error inside, exactly what a local agent would get).
bridge_owner_remote_agent :: proc(wire:Owner_Remote_Agent_Command) -> (string,string) {
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    if account=="" || wire.account_id!=account do return "account_mismatch",""
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return "vault_locked",""
    request,opened:=vault.open(wire.request,&kr,context.temp_allocator)
    if opened!=.Ok do return "stale_epoch",""
    owner_pub:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
    owner_id,id_ok:=vault.device_id_from_sign_pub(owner_pub,context.temp_allocator)
    if !id_ok do return "malformed",""
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if !bridge_owner_open(account,owner_id) do return "storage_error",""
    floor,status:=keystore_read_epoch_floor(bridge_cfg().daemon_id)
    if status!=.Found || !floor.root.set do return "directory_unverified",""
    pin_seq,pin_hash:=owner.directory_pin(&bridge_owner_store)
    now:=time.to_unix_nanoseconds(time.now())/1000000
    r,child,_,code:=owner.remote_agent_admit(bridge_owner_json(wire.directory),account,bridge_cfg().daemon_id,request,wire.signature,floor.root,pin_seq,pin_hash,&kr,now)
    if code!="ok" do return code,""
    // The Hub authenticated the sending Bridge; its signed claim must match.
    if r.from_bridge_id!=wire.from_bridge_id do return "invalid_scope",""
    p:=bridge_owner_params(r.params)
    // A remote agent names its target: it has no chain context here.
    if bridge_owner_pstr(p,"chain_id")=="" && bridge_owner_pstr(p,"task_id")=="" do return "malformed",""
    key:=contracts.Owner_Verified_Key{account,bridge_cfg().daemon_id,owner_id,owner_pub,"bridge",true,false}
    ctx:=Owner_Agent_Ctx{request_id=r.request_id,store=&bridge_owner_store,child=child,key=key,kr=&kr,now=now}
    response,refused:=bridge_owner_remote_agent_exec(&ctx,r.method,p,r.from_bridge_id)
    if refused!="" do return refused,""
    bridge_owner_publish()
    sealed,ok:=vault.seal(transmute([]byte)response,&kr,context.temp_allocator)
    if !ok do return "storage_error",""
    return "ok",sealed
}

// An admitted relayed verb, under the owner mutex. Returns the local-response
// JSON, or a refusal code for the relay envelope.
bridge_owner_remote_agent_exec :: proc(ctx:^Owner_Agent_Ctx,method:string,p:json.Object,from_bridge:string) -> (response,refused:string) {
    if method=="agent.lease.next" {
        // Review-lease discovery (gap 5): the relaying Bridge names the chain;
        // the reply is a review lease this reviewer owes, or none. A work
        // lease is never handed out over the relay (owner.lease_next is not
        // called), and peek is not served.
        chain:=bridge_owner_pstr(p,"chain_id")
        if chain=="" do return "","malformed"
        _,found,read:=owner.agent_chain_revision(ctx.store,chain)
        if !read do return "","storage_error"
        if !found do return "","not_found"
    } else {
        owned,read:=bridge_owner_targets(ctx.store,method,p,"")
        if !read do return "","storage_error"
        if !owned do return "","not_found"
    }
    // A relayed review is the reviewer's own verdict, never the user's.
    if method=="agent.review.post" && bridge_owner_pstr(p,"on_behalf_of")!="" do return "","invalid_scope"
    // The store trusts the relayed reviewer by agent id for this call only
    // (relayed_reviewer_authorized); every other verb keeps its checks.
    ctx.store.relayed_from=from_bridge
    defer ctx.store.relayed_from=""
    if method!="agent.lease.next" do return bridge_owner_agent_exec(ctx,method,p),""
    response=bridge_owner_review_next(ctx)
    // The relaying Bridge writes the reviewer's TASK.md from this text
    // (bridge_owner_remote_review_context_write); there is no run_dir here.
    if ctx.review_context.text=="" do return response,""
    envelope:=bridge_owner_result_object(response)
    data,_:=envelope["data"].(json.Object)
    if data==nil do return response,""
    data["review_context"]=json.String(ctx.review_context.text)
    return bridge_local_response_data(ctx.request_id,bridge_owner_json(data)),""
}

// Sender side: an agent of THIS Bridge names a chain or task this Bridge does
// not own. If another Bridge of the account owns it (the Hub routes by its
// registry), the verb is relayed there instead of reaching the Hub's removed
// chain engine. handled=false keeps the old fall-through (no such chain in the
// account, or a verb a remote agent may not use).
bridge_owner_remote_agent_send :: proc(request_id,method,params:string,rec:Bridge_Local_Agent_Token_Record) -> (string,bool) {
    if !owner.remote_agent_method(method) do return "",false
    p:=bridge_owner_params(params)
    chain,task:=bridge_owner_pstr(p,"chain_id"),bridge_owner_pstr(p,"task_id")
    if chain=="" && task=="" do return "",false
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    if account=="" do return "",false
    pub:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
    key_id,key_ok:=vault.device_id_from_sign_pub(pub,context.temp_allocator)
    if !key_ok do return "",false
    // The signed request names its owner Bridge (the owner checks it), so look
    // the owner up in the account registry first. An unreadable registry or an
    // unknown id keeps the old route.
    owner_bridge,found,lookup_err:=bridge_owner_remote_lookup(chain,task)
    if lookup_err!="" || !found || owner_bridge==bridge_cfg().daemon_id do return "",false
    // Prove the exact live child, as a local owner verb does; no lock is held
    // across the Hub round trip.
    child:owner.Child
    current:bool
    {
        sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
        sync.mutex_lock(&bridge_local_token_mutex);defer sync.mutex_unlock(&bridge_local_token_mutex)
        child,current=bridge_owner_child_locked(rec.agent_instance_id,rec.token_hash)
    }
    if !current do return bridge_local_response_error(request_id,"invalid_scope","owner chain: current launched child required"),true
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return bridge_local_response_error(request_id,"vault_locked","this Bridge's vault is locked"),true
    req:=owner.Remote_Agent_Request{account_id=account,owner_bridge_id=owner_bridge,from_bridge_id=bridge_cfg().daemon_id,from_key_id=key_id,
        request_id=request_id,method=method,params=params,expires_ms=time.to_unix_nanoseconds(time.now())/1000000+30000,
        instance=child.instance,epoch=child.epoch,token_generation=child.token_generation,agent_id=child.agent_id,run_count=child.run_count}
    raw:=bridge_owner_json(req)
    signature,signed:=bridge_identity_sign_bytes(owner.remote_agent_message(raw))
    if !signed do return bridge_local_response_error(request_id,"storage_error","could not sign the relayed request"),true
    sealed,sealed_ok:=vault.seal(transmute([]byte)raw,&kr,context.temp_allocator)
    if !sealed_ok do return bridge_local_response_error(request_id,"storage_error","could not seal the relayed request"),true
    token:=bridge_credential_snapshot();defer delete(token)
    headers:=[?]httpc.Header{httpc.bearer(token)}
    body:=bridge_owner_json(struct{chain_id,task_id,request,signature:string}{chain,task,sealed,signature})
    response,err:=bridge_hub_http_send({method=.POST,url=bridge_hub_url(),path={"api","v1","owner-local","agent-relay"},headers=headers[:],body=httpc.json_body(body)})
    defer httpc.response_destroy(&response)
    if err!=.None || response.status!=200 do return bridge_local_response_error(request_id,"owner_unavailable",fmt.tprintf("the owner Bridge %s could not be reached (%d)",owner_bridge,response.status)),true
    envelope:struct{data:struct{code,envelope:string}}
    if json.unmarshal(response.body,&envelope,.JSON,context.temp_allocator)!=nil do return bridge_local_response_error(request_id,"owner_unavailable","malformed relay reply"),true
    if envelope.data.code!="ok" do return bridge_local_response_error(request_id,envelope.data.code,fmt.tprintf("the owner Bridge %s refused the relayed request (%s)",owner_bridge,envelope.data.code)),true
    plain,opened:=vault.open(envelope.data.envelope,&kr,context.temp_allocator)
    if opened!=.Ok do return bridge_local_response_error(request_id,"stale_epoch","the relayed reply could not be opened"),true
    if method=="agent.lease.next" do return bridge_owner_remote_review_context_write(request_id,strings.clone(plain,context.temp_allocator),rec.agent_instance_id),true
    return strings.clone(plain,context.temp_allocator),true
}

// A relayed review lease (gap 5): the owner's review context becomes the
// reviewer's TASK.md in its run directory on this Bridge, as the owner writes
// it for a local reviewer; the text is dropped from the agent's reply.
// Without a run directory the reply is returned unchanged.
bridge_owner_remote_review_context_write :: proc(request_id,response,instance:string) -> string {
    envelope:=bridge_owner_result_object(response)
    data,_:=envelope["data"].(json.Object)
    if data==nil do return response
    text,has:=data["review_context"].(json.String)
    if !has || text=="" do return response
    delete_key(&data,"review_context")
    run_dir:=""
    if launch,launched:=bridge_runtime_get_launch(instance);launched do run_dir=strings.clone(launch.run_dir,context.temp_allocator)
    if run_dir=="" || !bridge_owner_review_context_write(Owner_Review_Context{run_dir,string(text)}) {
        data["review_context_written"]=json.Boolean(false)
    }
    return bridge_local_response_data(request_id,bridge_owner_json(data))
}

// The account's owner Bridge for a chain or task, from the Hub registry listing.
bridge_owner_remote_lookup :: proc(chain,task:string) -> (string,bool,string) {
    token:=bridge_credential_snapshot();defer delete(token)
    headers:=[?]httpc.Header{httpc.bearer(token)}
    q:=make([dynamic]httpc.Query_Param,context.temp_allocator)
    // headers_only lists chain rows only; a task-only lookup needs task rows.
    if chain!="" { append(&q,httpc.Query_Param{"headers_only","1"});append(&q,httpc.Query_Param{"chain_id",chain}) }
    response,err:=bridge_hub_http_send({method=.GET,url=bridge_hub_url(),path={"api","v1","owner-local","chains"},query=q[:],headers=headers[:]})
    defer httpc.response_destroy(&response)
    if err!=.None || response.status!=200 do return "",false,fmt.tprintf("the Hub owner registry could not be read (%d)",response.status)
    listing:struct{data:[]Owner_Remote_Registry_Row}
    if json.unmarshal(response.body,&listing,.JSON,context.temp_allocator)!=nil do return "",false,"malformed owner registry listing"
    owner_bridge,found:=bridge_owner_remote_match(listing.data,chain,task)
    return owner_bridge,found,""
}

Owner_Remote_Registry_Row :: struct{chain_id,task_id,owner_bridge_id:string}

// The owner Bridge of a chain (its chain row, or a task row of that chain) or
// of a task named alone (its task row). A row with no owner never matches.
bridge_owner_remote_match :: proc(rows:[]Owner_Remote_Registry_Row,chain,task:string) -> (string,bool) {
    for row in rows {
        if row.owner_bridge_id=="" do continue
        if chain!="" && row.chain_id==chain && (task=="" || row.task_id==task || row.task_id=="") do return row.owner_bridge_id,true
        if chain=="" && task!="" && row.task_id==task do return row.owner_bridge_id,true
    }
    return "",false
}
