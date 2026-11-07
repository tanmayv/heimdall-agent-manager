package main

import "base:runtime"
import "core:encoding/json"
import "core:crypto"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import channel "odin_test:lib/executor_channel"
import httpc "odin_test:lib/httpc"
import vault "odin_test:lib/vault"

// One delivery owner retains both unchecked responses and interpreted outcomes
// across allocator resets. Nothing reads the Store while exchange is running.
Owner_Executor_Worker :: struct {
    mutex:sync.Mutex,
    pending,received:bool,
    claim:owner.Intent_Claim,
    snapshot,response:string,
    completed:i64,
    completions:owner.Intent_Completions,
}
Owner_Executor_Snapshot :: #type proc(rawptr,^owner.Store,owner.Intent_Claim,i64)->(string,bool)
Owner_Executor_Exchange :: #type proc(rawptr,owner.Intent_Claim,string)->(string,i64)
Owner_Executor_Accept :: #type proc(rawptr,^owner.Store,owner.Intent_Claim,string,string,i64)->(ready,success:bool,result:string)

bridge_owner_executor_worker:Owner_Executor_Worker
bridge_owner_executor_started:bool

bridge_owner_executor_clear :: proc(w:^Owner_Executor_Worker) {
    a:=runtime.default_allocator()
    if w.snapshot!="" do crypto.zero_explicit(raw_data(w.snapshot),len(w.snapshot))
    for value in ([9]string{w.claim.id,w.claim.chain,w.claim.kind,w.claim.destination,w.claim.fence,w.claim.payload,w.claim.digest,w.snapshot,w.response}) do delete(value,a)
    w.claim={};w.snapshot="";w.response="";w.completed=0;w.pending=false;w.received=false
}
bridge_owner_executor_keep :: proc(w:^Owner_Executor_Worker,c:owner.Intent_Claim,snapshot:string) {
    a:=runtime.default_allocator()
    w.claim=c
    w.claim.id=strings.clone(c.id,a);w.claim.chain=strings.clone(c.chain,a);w.claim.kind=strings.clone(c.kind,a)
    w.claim.destination=strings.clone(c.destination,a);w.claim.fence=strings.clone(c.fence,a)
    w.claim.payload=strings.clone(c.payload,a);w.claim.digest=strings.clone(c.digest,a)
    w.snapshot=strings.clone(snapshot,a);w.pending=true
}
bridge_owner_executor_destroy :: proc(w:^Owner_Executor_Worker) {
    bridge_owner_executor_clear(w)
    owner.intent_completions_destroy(&w.completions)
}

// The worker mutex prevents overlapping ticks for this delivery owner. The
// owner mutex protects only snapshot/recheck/persistence, never exchange.
// Failed recheck reads retain the full opaque outcome and do not redeliver.
bridge_owner_executor_batch :: proc(w:^Owner_Executor_Worker,s:^owner.Store,mutex:^sync.Mutex,now:i64,ctx:rawptr,
    snapshot:Owner_Executor_Snapshot,exchange:Owner_Executor_Exchange,accept:Owner_Executor_Accept)->bool {
    if !sync.mutex_try_lock(&w.mutex) do return false
    defer sync.mutex_unlock(&w.mutex)
    sync.mutex_lock(mutex)
    if w.completions.count>0 && w.pending {
        // Keep the full dispatch snapshot until the interpreted result commits,
        // so route/fence changes during a persistence outage are rechecked too.
        current,read:=owner.intent_claim_exact(s,w.claim)
        if !read {sync.mutex_unlock(mutex);return false}
        if !current {
            owner.intent_completions_destroy(&w.completions)
            bridge_owner_executor_clear(w)
        } else {
            if !owner.intent_completions_flush(s,&w.completions) {sync.mutex_unlock(mutex);return false}
            bridge_owner_executor_clear(w)
        }
    }
    if !w.pending {
        claims,ok:=owner.intent_claim_due(s,now,1,.Executor)
        if !ok || len(claims)==0 {sync.mutex_unlock(mutex);return ok}
        c:=claims[0]
        saved,ready:=snapshot(ctx,s,c,now)
        if !ready {
            bridge_owner_executor_keep(w,c,"")
            w.received=true;w.completed=now
            if !owner.intent_completion_keep(&w.completions,c,false,"owner_fence_not_current",now,runtime.default_allocator()) do panic("executor completion capacity")
            ok=owner.intent_completions_flush(s,&w.completions)
            if ok do bridge_owner_executor_clear(w)
            sync.mutex_unlock(mutex)
            return ok
        }
        bridge_owner_executor_keep(w,c,saved)
    }
    sync.mutex_unlock(mutex)
    if !w.received {
        response,completed:=exchange(ctx,w.claim,w.snapshot)
        // Bound untrusted transport output before retaining it.
        if len(response)>3*1024*1024 {response="";completed=now}
        if completed<0 || completed>0x7fffffffffffffff-60000 {response="";completed=now}
        w.response=strings.clone(response,runtime.default_allocator())
        w.completed=completed;w.received=true
    }
    sync.mutex_lock(mutex);defer sync.mutex_unlock(mutex)
    current,read:=owner.intent_claim_exact(s,w.claim)
    if !read do return false
    if !current {bridge_owner_executor_clear(w);return true}
    ready,success,result:=accept(ctx,s,w.claim,w.snapshot,w.response,max(now,w.completed))
    if !ready do return false
    if !owner.intent_completion_keep(&w.completions,w.claim,success,result,w.completed,runtime.default_allocator()) do panic("executor completion bounds")
    if !owner.intent_completions_flush(s,&w.completions) do return false
    bridge_owner_executor_clear(w)
    return true
}

Owner_Executor_Pin :: struct {key_id:string,generation:i64,bootstrap,body,notification,message,code:string}
Owner_Executor_Outcome :: struct {scope,body,code:string}
Owner_Executor_Relay_Data :: struct {reply:string,directory:vault.Directory_Verification_Input}
Owner_Executor_HTTP_Reply :: struct {data:Owner_Executor_Relay_Data}
Owner_Executor_Command_Reply :: struct {type,command_id,request_id,code,envelope:string}

bridge_owner_executor_snapshot :: proc(_:rawptr,s:^owner.Store,c:owner.Intent_Claim,now:i64)->(string,bool) {
    if c.kind=="executor.notification" {
        code:=owner.execution_notification_current(s,c,now)
        if code=="storage_error" do return "",false
        if code!="ok" do return bridge_owner_json(Owner_Executor_Pin{generation=bridge_task_chain_search_generation(),code=code}),true
    } else {
        current,_,_,_:=owner.execution_activation_fence(s,c,now)
        if !current do return "",false
    }
    p,parsed:=contracts.executor_parse(c.fence,"prepare")
    if !parsed do return "",false
    rows,ok:=owner.query(s.db,"SELECT payload_json FROM local_assignment_history WHERE chain_id=? AND task_id=? AND revision=?",
        contracts.owner_string(p,"chain_id"),contracts.owner_string(p,"task_id"),contracts.owner_string(p,"configuration_revision"))
    if !ok || len(rows)!=1 do return "",false
    config,valid:=owner.remote_assignment_configuration(rows[0][0])
    if !valid || contracts.owner_string(config,"executor_bridge_id")!=c.destination do return "",false
    if c.kind=="executor.heartbeat" {
        return bridge_owner_json(Owner_Executor_Pin{key_id=contracts.owner_string(config,"executor_key_id"),
            generation=bridge_task_chain_search_generation()}),true
    }
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    key:=contracts.Owner_Verified_Key{s.account,s.owner,s.owner_key,public,"bridge",true,false}
    if c.kind=="executor.notification" {
        result:=owner.execution_notification(s,c,key,now,{nil,bridge_owner_sign})
        if result.code!="ok" do return bridge_owner_json(Owner_Executor_Pin{generation=bridge_task_chain_search_generation(),code=result.code}),true
        value,decoded:=contracts.owner_content_document(result.body);bundle,object:=value.(json.Object)
        if !decoded || !object do return "",false
        return bridge_owner_json(Owner_Executor_Pin{key_id=contracts.owner_string(config,"executor_key_id"),generation=bridge_task_chain_search_generation(),
            notification=contracts.owner_string(bundle,"notification"),message=contracts.owner_string(bundle,"message")}),true
    }
    content:=owner.execution_bootstrap(s,c,"# Bridge-owned runtime worker\nRead TASK.md. Work only on the existing assigned lease. Use the owner-local lease/lifecycle API described there; task authority stays on the owner Bridge.\n","","[]",key,now,{nil,bridge_owner_sign})
    if content.code!="ok" do return "",false
    value,decoded:=contracts.owner_content_document(content.body);bundle,b_ok:=value.(json.Object)
    if !decoded || !b_ok do return "",false
    return bridge_owner_json(Owner_Executor_Pin{key_id=contracts.owner_string(config,"executor_key_id"),generation=bridge_task_chain_search_generation(),
        bootstrap=contracts.owner_string(bundle,"bootstrap"),body=contracts.owner_string(bundle,"body")}),true
}

// This function deliberately has no Store parameter. It may block on the Hub
// while the receiving executor calls back into owner handlers on another thread.
bridge_owner_executor_exchange :: proc(_:rawptr,c:owner.Intent_Claim,snapshot:string)->(string,i64) {
    now:=time.to_unix_nanoseconds(time.now())/1000000
    pin:Owner_Executor_Pin
    outcome:=Owner_Executor_Outcome{code="executor_unavailable"}
    if json.unmarshal_string(snapshot,&pin,.JSON,context.temp_allocator)!=nil ||
       pin.generation!=bridge_task_chain_search_generation() || sync.atomic_load(&bridge_hub_traffic_stopped) {return bridge_owner_json(outcome),now}
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked {outcome.code="vault_locked";return bridge_owner_json(outcome),now}
    if pin.code!="" {outcome.code=pin.code;return bridge_owner_json(outcome),now}
    kind:="notification" if c.kind=="executor.notification" else ("prepare" if c.kind=="executor.prepare" else "action")
    raw:=pin.notification if c.kind=="executor.notification" else c.payload
    action,parsed:=contracts.executor_parse(raw,kind)
    if !parsed do return bridge_owner_json(outcome),now
    get:=contracts.owner_string
    expires:=min(contracts.executor_number(action,"request_expires_ms"),now+contracts.EXECUTOR_TRANSPORT_TTL_MS)
    if expires<=now {outcome.code="expired";return bridge_owner_json(outcome),now}
    digest,_:=contracts.executor_digest(kind,action)
    request_id:=fmt.tprintf("executor_%d",time.to_unix_nanoseconds(time.now()))
    scope:=make(json.Object,context.temp_allocator)
    for name in ([7]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id","reservation_id","owner_incarnation"}) do scope[name]=action[name]
    scope["executor_incarnation"]=action["executor_incarnation"]
    scope["request_id"]=json.String(request_id);scope["method"]=json.String(kind);scope["direction"]=json.String("request")
    scope["input_digest"]=json.String(digest)
    scope["fence_digest"]=json.String(digest) if kind=="prepare" else action["prepare_digest"]
    scope["issued_ms"]=json.String(fmt.tprintf("%d",now));scope["request_expires_ms"]=json.String(fmt.tprintf("%d",expires))
    token,sealed:=channel.seal(raw,&kr,scope,now,context.temp_allocator)
    if !sealed do return bridge_owner_json(outcome),now
    exchange:=bridge_owner_json(struct{scope,envelope:string}{bridge_owner_json(scope),token})
    if c.kind=="executor.notification" {
        exchange=bridge_owner_json(struct{scope,envelope,message,claim_attempt:string}{bridge_owner_json(scope),token,pin.message,fmt.tprintf("%d",c.attempt)})
        if _,valid:=contracts.executor_parse(exchange,"notification_exchange");!valid {outcome.code="invalid_notification_exchange";return bridge_owner_json(outcome),now}
    }
    if c.kind=="executor.activate" {
        if pin.bootstrap=="" || pin.body=="" {outcome.code="bootstrap_unavailable";return bridge_owner_json(outcome),now}
        exchange=bridge_owner_json(struct{scope,envelope,intent_id,claim_attempt,bootstrap,body:string}{
            bridge_owner_json(scope),token,c.id,fmt.tprintf("%d",c.attempt),pin.bootstrap,pin.body})
        if _,valid:=contracts.executor_parse(exchange,"activation_bootstrap_exchange");!valid {outcome.code="bootstrap_too_large";return bridge_owner_json(outcome),now}
    }
    if c.kind=="executor.heartbeat" {
        exchange=bridge_owner_json(struct{scope,envelope,intent_id,claim_attempt:string}{
            bridge_owner_json(scope),token,c.id,fmt.tprintf("%d",c.attempt)})
    }
    outer,wrapped:=vault.seal(transmute([]byte)exchange,&kr,context.temp_allocator)
    if !wrapped do return bridge_owner_json(outcome),now
    relay:=struct{protocol_version,chain_id,bridge_id,request_id,expires_ms,envelope:string}{
        "1",c.chain,c.destination,request_id,fmt.tprintf("%d",expires),outer}
    credential:=bridge_credential_snapshot();defer delete(credential)
    headers:=[?]httpc.Header{httpc.bearer(credential)}
    if pin.generation!=bridge_task_chain_search_generation() || sync.atomic_load(&bridge_hub_traffic_stopped) {outcome.code="vault_locked";return bridge_owner_json(outcome),now}
    route:="activate" if c.kind=="executor.activate" || c.kind=="executor.heartbeat" else "relay"
    response,err:=bridge_http_request_retry({method=.POST,url=bridge_hub_url(),path={"api","v1","executor",route},headers=headers[:],body=httpc.json_body(relay),timeout_ms=10000},deadline_ns=expires*1000000)
    defer httpc.response_destroy(&response)
    completed:=time.to_unix_nanoseconds(time.now())/1000000
    // Save our exact pending scope, never a scope supplied by the relay.
    scope["direction"]=json.String("response")
    outcome.scope=bridge_owner_json(scope)
    if err==.None && response.status==200 && len(httpc.text(response))<=3*1024*1024 {
        outcome.body=httpc.text(response);outcome.code="response"
    }
    return bridge_owner_json(outcome),completed
}

// Observe revocations before peer admission. Rejected responses must not let a
// later older directory roll back a newer verified paired log.
bridge_owner_executor_directory :: proc(s:^owner.Store,input:vault.Directory_Verification_Input,pin:Owner_Executor_Pin,
    c:owner.Intent_Claim,kr:^vault.Vault_Keyring)->(contracts.Owner_Verified_Key,bool,bool) {
    floor,status:=keystore_read_epoch_floor(bridge_config.daemon_id)
    if status!=.Found || !floor.root.set || input.owner!=s.account do return {},false,true
    seq,head:=owner.directory_pin(s)
    if seq<0 do return {},false,false
    d:=input;d.pin_seq=seq;d.pin_hash=head
    dir,verified:=vault.directory_verify(d)
    if !verified do return {},false,true
    root,root_ok:=vault.root_pin_from_hex(dir.root_device_id,vault.SIGN_ALG_ECDSA_P256_SHA256,dir.root_public_key)
    paired:=floor.root
    if !root_ok || !vault.root_pin_equal(&paired,&root) do return {},false,true
    if !owner.observe_directory(s,dir.version,dir.head_hash) do return {},false,false
    if !vault.directory_verify_keyring(&dir,kr) do return {},false,true
    peer,enrolled:=dir.trusted[pin.key_id]
    own,owner_ok:=dir.trusted[s.owner_key]
    derived,derived_ok:=vault.device_id_from_sign_pub(peer.sign_public_key,context.temp_allocator)
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    if !enrolled || peer.kind!="bridge" || !derived_ok || derived!=pin.key_id || !owner_ok || own.kind!="bridge" || own.sign_public_key!=public do return {},false,true
    key:=contracts.Owner_Verified_Key{s.account,c.destination,pin.key_id,peer.sign_public_key,"bridge",true,false}
    p,parsed:=contracts.executor_parse(c.fence,"prepare")
    return key,parsed && owner.remote_assignment_key_matches(s,p,key),true
}

bridge_owner_executor_accept :: proc(_:rawptr,s:^owner.Store,c:owner.Intent_Claim,snapshot,response:string,now:i64)->(bool,bool,string) {
    pin:Owner_Executor_Pin;outcome:Owner_Executor_Outcome
    if json.unmarshal_string(snapshot,&pin,.JSON,context.temp_allocator)!=nil ||
       json.unmarshal_string(response,&outcome,.JSON,context.temp_allocator)!=nil {return true,false,"malformed_executor_response"}
    if pin.generation!=bridge_task_chain_search_generation() || sync.atomic_load(&bridge_hub_traffic_stopped) do return true,false,"vault_locked"
    if outcome.code!="response" do return true,c.kind=="executor.notification" && outcome.code=="no_current_target",outcome.code
    envelope:Owner_Executor_HTTP_Reply
    if json.unmarshal_string(outcome.body,&envelope,.JSON,context.temp_allocator)!=nil do return true,false,"malformed_executor_response"
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return true,false,"vault_locked"
    key,trusted,read:=bridge_owner_executor_directory(s,envelope.data.directory,pin,c,&kr)
    if !read do return false,false,"storage_error"
    if !trusted do return true,false,"invalid_executor_directory"
    scope,scoped:=contracts.executor_parse(outcome.scope,"transport_scope")
    reply:Owner_Executor_Command_Reply
    if !scoped || json.unmarshal_string(envelope.data.reply,&reply,.JSON,context.temp_allocator)!=nil ||
       reply.request_id!=contracts.owner_string(scope,"request_id") || reply.type!="command_result" {return true,false,"invalid_executor_reply"}
    if reply.code!="ok" do return true,false,"executor_rejected"
    receipt,authenticated:=channel.open_signed(reply.envelope,&kr,scope,key,now,context.temp_allocator)
    if c.kind=="executor.notification" {
        n,parsed:=contracts.executor_parse(pin.notification,"notification")
        r,valid:=contracts.executor_parse(receipt,"notification_result")
        if !authenticated || !parsed || !valid || !contracts.executor_notification_result_matches(r,n,pin.message,key,now) do return true,false,"invalid_notification_result"
        current:=owner.execution_notification_current(s,c,now)
        if current=="storage_error" do return false,false,current
        if current!="ok" do return true,true,current
        // Settling physical evidence neither acknowledges a source nor grants
        // work. Partial writes retry the same immutable daemon ticket.
        return true,contracts.owner_string(r,"status")!="partial",receipt
    }
    action,parsed:=contracts.executor_parse(c.payload,"action")
    r,valid:=contracts.executor_parse(receipt,"receipt")
    if !authenticated || !parsed || !valid || !contracts.executor_receipt_matches(r,action,"action",key,now,false) ||
       contracts.owner_string(r,"state")!="active" {return true,false,"invalid_executor_receipt"}
    // This settles delivery evidence only. It cannot create/renew a grant,
    // refund resources, or suppress an agent failure charge.
    current,_,_,_:=owner.execution_activation_fence(s,c,now)
    if !current do return true,false,"owner_fence_changed"
    if pin.generation!=bridge_task_chain_search_generation() do return true,false,"vault_locked"
    return true,true,receipt
}

bridge_owner_executor_once :: proc() {
    context.allocator=context.temp_allocator
    account:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
    public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
    key_id,valid:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !valid || account=="" do return
    sync.mutex_lock(&bridge_owner_mutex)
    opened:=bridge_owner_open(account,key_id)
    sync.mutex_unlock(&bridge_owner_mutex)
    if !opened do return
    bridge_owner_preparation_once(&bridge_owner_store)
    _=bridge_owner_executor_batch(&bridge_owner_executor_worker,&bridge_owner_store,&bridge_owner_mutex,
        time.to_unix_nanoseconds(time.now())/1000000,nil,bridge_owner_executor_snapshot,bridge_owner_executor_exchange,bridge_owner_executor_accept)
}
bridge_owner_executor_loop :: proc() {
    for {
        if sync.atomic_load(&bridge_hub_traffic_stopped) do return
        bridge_owner_executor_once()
        free_all(context.temp_allocator)
        time.sleep(time.Second)
    }
}
bridge_owner_executor_start :: proc() {
    if _,started:=sync.atomic_compare_exchange_strong(&bridge_owner_executor_started,false,true);started do thread.run(bridge_owner_executor_loop)
}
