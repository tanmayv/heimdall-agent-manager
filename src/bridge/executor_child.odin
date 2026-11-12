package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "core:crypto"
import "core:encoding/json"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import channel "odin_test:lib/executor_channel"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

// Caller owns executor serialization and resolves keys from the current paired
// directory. This is deliberately separate from legacy Hub agent-token auth.
// Startup invalidation and physical child observation share the I/O mutex.
bridge_executor_child_attest :: proc(s:^executor.Store,instance,secret,input,socket:string,
    owner_key,executor_key:contracts.Owner_Verified_Key,sign:executor.Signer)->executor.Result {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    raw,authenticated:=executor.child_bootstrap(s,instance,secret,time.to_unix_nanoseconds(time.now())/1000000)
    if !authenticated do return executor.Result{code="invalid_scope"}
    b,parsed:=contracts.executor_parse(raw,"bootstrap")
    if !parsed do return executor.Result{code="invalid_scope"}
    launch_key:=contracts.owner_string(b,"launch_key")
    pid,known:=bridge_pty_host_executor_query(socket,instance,launch_key)
    if !known || pid<=0 do return executor.Result{code="child_not_current"}
    return executor.attest_child_request(s,instance,secret,input,
        executor.Child_Observation{instance,launch_key,s.incarnation,true},owner_key,executor_key,
        time.to_unix_nanoseconds(time.now())/1000000,sign)
}

bridge_executor_child_keys :: proc(s:^executor.Store,b:json.Object,d:vault.Directory_Verification_Input,
    kr:^vault.Vault_Keyring)->(owner_key,executor_key:contracts.Owner_Verified_Key,valid:bool) {
    dir,trusted:=bridge_executor_directory(s,d,kr)
    if !trusted do return {},{},false
    get:=contracts.owner_string
    own,self_ok:=dir.trusted[s.operator_key]
    peer,owner_ok:=dir.trusted[get(b,"key_id")]
    public:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
    if !self_ok || own.kind!="bridge" || own.sign_public_key!=public || !owner_ok || peer.kind!="bridge" do return {},{},false
    host:=contracts.Owner_Verified_Key{s.account,s.executor,s.operator_key,public,"bridge",true,false}
    source:=contracts.Owner_Verified_Key{s.account,get(b,"owner_bridge_id"),peer.id,peer.sign_public_key,"bridge",true,false}
    return source,host,contracts.executor_verify("bootstrap",b,source)
}

// Fresh directory retrieval and the reverse owner exchange happen without the
// application executor mutex. The token stays local; only an exact signed
// child/input attestation crosses the encrypted transit channel.
Executor_Child_Transport :: struct {
    ctx:rawptr,
    directory:proc(rawptr,i64)->(vault.Directory_Verification_Input,bool),
    exchange:proc(rawptr,string,string,i64)->Executor_Fence_Outcome,
}
bridge_executor_child_fetch :: proc(_:rawptr,generation:i64)->(vault.Directory_Verification_Input,bool) {return bridge_executor_directory_fetch(generation)}
bridge_executor_child_send :: proc(_:rawptr,request,input:string,generation:i64)->Executor_Fence_Outcome {return bridge_executor_child_exchange(request,input,generation)}
bridge_executor_agent :: proc(request_id,input,secret:string,
    transport:Executor_Child_Transport={nil,bridge_executor_child_fetch,bridge_executor_child_send},socket_path:string="",method:string="agent.owner_local.lease")->(string,bool) {
    verb:=contracts.executor_agent_verb(method)
    input:=input
    chat:=method=="agent.chat.send"
    if method!="agent.owner_local.lease" && method!="agent.start_success" && method!="agent.extension.event" && !verb && !chat do return "",false
    generation:=bridge_task_chain_search_generation()
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    public:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
    self,self_ok:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    if !self_ok || account=="" do return "",false
    sync.mutex_lock(&bridge_executor_mutex)
    opened:=bridge_executor_open(account,self)
    instance,raw:string
    authenticated:=false
    if opened {instance,raw,authenticated=executor.child_token(&bridge_executor_store,secret,time.to_unix_nanoseconds(time.now())/1000000)}
    sync.mutex_unlock(&bridge_executor_mutex)
    if !authenticated do return "",false
    fail:=proc(id,code:string)->(string,bool) {return bridge_local_response_error(id,code,bridge_executor_refusal_reason(code)),true}
    // A remote child has no Hub agent identity to send chat as.
    if chat do return fail(request_id,"remote_chat_unavailable")
    if method=="agent.start_success" {
        value,parsed:=contracts.owner_content_document(input)
        params,is_object:=value.(json.Object)
        if !parsed || !is_object || len(params)!=0 do return fail(request_id,"malformed")
    }
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked do return fail(request_id,"vault_locked")
    if transport.directory==nil || (method=="agent.owner_local.lease" || verb) && transport.exchange==nil do return fail(request_id,"owner_unavailable")
    directory,fetched:=transport.directory(transport.ctx,generation)
    if !fetched do return fail(request_id,"directory_unavailable")
    b,parsed:=contracts.executor_parse(raw,"bootstrap")
    if !parsed do return fail(request_id,"invalid_scope")
    // An ordinary agent verb travels as the child's own chain/task/lease
    // input; the owner keeps it on that task and answers with the full
    // local response.
    if verb {
        params:=strings.trim_space(input)
        if params=="" do params="{}"
        doc:=make(json.Object,context.temp_allocator)
        for name in ([4]string{"chain_id","task_id","lease_id","configuration_revision"}) do doc[name]=b[name]
        doc["protocol_version"]=json.String("1");doc["method"]=json.String(method);doc["params"]=json.String(params)
        encoded,encoded_ok:=json.marshal(doc,allocator=context.temp_allocator)
        if encoded_ok!=nil do return fail(request_id,"malformed")
        input=string(encoded)
        if _,valid:=contracts.executor_parse(input,"agent_verb");!valid do return fail(request_id,"request_too_large")
    }
    sync.mutex_lock(&bridge_executor_mutex)
    source,host,trusted:=bridge_executor_child_keys(&bridge_executor_store,b,directory,&kr)
    attested:=executor.Result{code="invalid_scope"}
    if trusted && generation==bridge_task_chain_search_generation() {
        socket:=socket_path
        if socket=="" do socket=pty_host_socket_path()
        if method=="agent.start_success" {
            attested=bridge_executor_child_ready(&bridge_executor_store,instance,secret,socket,source,host)
        } else if method=="agent.extension.event" {
            attested=bridge_executor_child_notification_session(&bridge_executor_store,instance,secret,input,socket,source,host)
        } else {
            attested=bridge_executor_child_attest(&bridge_executor_store,instance,secret,input,socket,source,host,{nil,bridge_executor_sign})
        }
        if socket_path=="" do delete(socket)
    }
    sync.mutex_unlock(&bridge_executor_mutex)
    if attested.code!="ok" do return fail(request_id,attested.code)
    if method=="agent.start_success" || method=="agent.extension.event" {
        if generation!=bridge_task_chain_search_generation() do return fail(request_id,"vault_locked")
        if method=="agent.start_success" do _=bridge_startup_executor_ready(instance,secret,bridge_runtime_now_ms())
        return bridge_local_response_data(request_id,attested.body),true
    }
    // An attested verb is the child's readiness signal too (no start-success
    // timeout for a child that works without running start-success).
    _=bridge_startup_executor_ready(instance,secret,bridge_runtime_now_ms(),implicit=true)
    outcome:=transport.exchange(transport.ctx,attested.body,input,generation)
    if outcome.envelope=="" do return fail(request_id,"owner_unavailable")
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    current_source,current_host,current:=bridge_executor_child_keys(&bridge_executor_store,b,outcome.directory,&kr)
    _,still_authenticated:=executor.child_bootstrap(&bridge_executor_store,instance,secret,time.to_unix_nanoseconds(time.now())/1000000)
    if !current || !still_authenticated || current_source.public_key!=source.public_key || current_host.public_key!=host.public_key ||
       generation!=bridge_task_chain_search_generation() {return fail(request_id,"invalid_scope")}
    scope,scoped:=contracts.executor_parse(outcome.scope,"transport_scope")
    request,requested:=contracts.executor_parse(attested.body,"child_request")
    if !scoped || !requested do return fail(request_id,"invalid_scope")
    body,verified:=channel.open_child_result(outcome.envelope,&kr,scope,request,current_source,time.to_unix_nanoseconds(time.now())/1000000,context.temp_allocator)
    if !verified do return fail(request_id,"invalid_owner_result")
    defer crypto.zero_explicit(raw_data(body),len(body))
    result:owner.Result
    if json.unmarshal_string(body,&result,.JSON,context.temp_allocator)!=nil do return fail(request_id,"invalid_owner_result")
    if result.code!="ok" do return fail(request_id,result.code)
    if verb {
        delivered,reason:=bridge_executor_verb_deliver(instance,result.body)
        if delivered=="" do return bridge_local_response_error(request_id,"context_delivery_failed",reason),true
        return bridge_executor_verb_response(request_id,delivered),true
    }
    command,valid:=contracts.owner_parse(input,"lifecycle_input")
    if valid && contracts.owner_string(command,"method")=="requirements.present" && !result.replay {
        dir,within:=bridge_fs_run_dir_root(instance)
        if !within do return fail(request_id,"context_delivery_failed")
        defer delete(dir)
        command["instance_id"]=json.String(instance)
        // A no-directory chain placed here runs in this executor's per-chain
        // scratch directory: TASK.md names it as the Workdir (no branch, no
        // merge-back), as the owner Bridge does for its local agents.
        if contracts.owner_string(command,"workdir")=="" {
            if scratch:=bridge_executor_scratch_workdir(bridge_executor_store.account,contracts.owner_string(command,"chain_id"));scratch!="" {
                command["workdir"]=json.String(scratch);command["branch"]=json.String("")
            }
        }
        if !bridge_owner_materialize_context(dir,command,result.body) do return fail(request_id,"context_delivery_failed")
    }
    return bridge_local_response_data(request_id,body),true
}

// Current paired keys and exact daemon presence precede durable local readiness.
bridge_executor_child_ready :: proc(s:^executor.Store,instance,secret,socket:string,
    owner_key,executor_key:contracts.Owner_Verified_Key)->executor.Result {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    raw,authenticated:=executor.child_bootstrap(s,instance,secret,bridge_executor_physical_clock(nil))
    if !authenticated do return executor.Result{code="invalid_scope"}
    b,parsed:=contracts.executor_parse(raw,"bootstrap")
    if !parsed do return executor.Result{code="invalid_scope"}
    key:=contracts.owner_string(b,"launch_key")
    pid,known:=bridge_pty_host_executor_query(socket,instance,key)
    if !known || pid<=0 do return executor.Result{code="child_not_current"}
    return executor.child_ready(s,instance,secret,executor.Child_Observation{instance,key,s.incarnation,true},
        owner_key,executor_key,bridge_executor_physical_clock(nil))
}


// Only current remote-child native session observation is accepted here. This
// never installs a legacy Hub token, relays arbitrary extension effects, marks
// readiness, grants task authority, configures profiles or writes PTY input.
bridge_executor_child_notification_session :: proc(s:^executor.Store,instance,secret,input,socket:string,
    owner_key,executor_key:contracts.Owner_Verified_Key)->executor.Result {
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    raw,authenticated:=executor.child_bootstrap(s,instance,secret,bridge_executor_physical_clock(nil))
    if !authenticated do return {code="invalid_scope"}
    b,parsed:=contracts.executor_parse(raw,"bootstrap")
    if !parsed || !contracts.executor_verify("bootstrap",b,owner_key) ||
       contracts.owner_string(b,"executor_bridge_id")!=executor_key.principal_id { return {code="invalid_scope"} }
    pid,known:=bridge_pty_host_executor_query(socket,instance,contracts.owner_string(b,"launch_key"))
    if !known || pid<=0 do return {code="child_not_current"}
    raws,err:=contracts.ext_split_events(input)
    if err!=.None do return {code="malformed"}
    defer contracts.ext_split_events_destroy(raws)
    accepted:=0
    for value in raws {
        ev,parse_err:=contracts.ext_parse_event(value)
        if parse_err!=.None do return {code="malformed"}
        defer contracts.ext_event_destroy(&ev)
        if ev.provider!="codex" || ev.kind!=.Session || ev.session_phase!="start" ||
           ev.agent_id!="" || (ev.agent_type!="" && ev.agent_type!="main") { continue }
        // Repeat token/runtime fences immediately before the observation IPC.
        _,current:=executor.child_bootstrap(s,instance,secret,bridge_executor_physical_clock(nil))
        if !current do return {code="invalid_scope"}
        if !bridge_pty_notification_bind_session(socket,instance,pid,contracts.owner_string(b,"token_generation"),
            contracts.owner_string(b,"launch_epoch"),contracts.owner_string(b,"run_count"),ev.session_id,ev.transcript_path,ev.session_source) {
            return {code="notification_profile_unsupported"}
        }
        accepted+=1
    }
    return {code="ok",body=bridge_owner_json(struct{accepted,rejected:int}{accepted,0})}
}

// The owner's answer to an agent verb is a complete local response; only the
// request id is this caller's.
bridge_executor_verb_response :: proc(request_id,owner_response:string)->string {
    value,err:=json.parse_string(owner_response,.JSON,true,context.temp_allocator)
    o,is_object:=value.(json.Object)
    if err!=.None || !is_object do return bridge_local_response_error(request_id,"invalid_owner_result",bridge_executor_refusal_reason("invalid_owner_result"))
    if ok,_:=o["ok"].(json.Boolean);ok {
        data,_:=json.marshal(o["data"],allocator=context.temp_allocator)
        return bridge_local_response_data(request_id,string(data))
    }
    e,_:=o["error"].(json.Object)
    code,_:=e["code"].(json.String);message,_:=e["message"].(json.String)
    if code=="" do code="owner_refused"
    if message=="" do message=json.String(bridge_executor_refusal_reason(string(code)))
    return bridge_local_response_error(request_id,string(code),string(message))
}

// A refusal on the remote child path names why, so the agent can act on it
// instead of seeing a bare code.
bridge_executor_refusal_reason :: proc(code:string)->string {
    switch code {
    case "owner_unavailable": return "the owner Bridge did not answer through the Hub (offline, or the Hub relay failed); retry shortly"
    case "directory_unavailable": return "the account's paired-device directory could not be fetched from the Hub; retry shortly"
    case "vault_locked": return "this Bridge's vault is locked; unlock it to reach the owner Bridge"
    case "invalid_scope": return "this child or its lease is no longer current for the owner (stopped, relaunched or released), or the request names another task"
    case "child_not_current": return "this agent process is not the launch the owner placed (pty-host does not know it)"
    case "invalid_owner_result": return "the owner Bridge's answer could not be verified"
    case "malformed": return "the request is not a valid agent request"
    case "request_too_large": return "the request parameters exceed the executor document limit (32 KiB)"
    case "context_delivery_failed": return "the owner accepted the request but TASK.md could not be written here; run lease next again"
    case "expired": return "the request expired before the owner answered; retry"
    case "remote_chat_unavailable": return "chat is not available to agents running on a remote Bridge; use `task comment`, which notifies the coordinator"
    }
    return fmt.tprintf("the owner Bridge refused the request (%s)",code)
}

// G1: the owner's lease-next context, written here before success is
// reported: a work lease's presented requirements as TASK.md (as the
// requirements.present path above), or a reviewer's rendered review. Both are
// stripped from what the agent sees. Returns the response to report, or ""
// and why the delivery failed.
bridge_executor_verb_deliver :: proc(instance,owner_response:string)->(string,string) {
    value,err:=json.parse_string(owner_response,.JSON,true,context.temp_allocator)
    o,is_object:=value.(json.Object)
    if err!=.None || !is_object do return owner_response,""
    data,has_data:=o["data"].(json.Object)
    if !has_data do return owner_response,""
    task_context,has_task:=data["task_context"].(json.Object)
    review,has_review:=data["review_context"].(json.String)
    if !has_task && !has_review do return owner_response,""
    dir,within:=bridge_fs_run_dir_root(instance)
    if !within do return "","the run directory of this agent is unavailable; TASK.md was not updated (run lease next again)"
    defer delete(dir)
    if has_task {
        raw_command,_:=task_context["command"].(json.String)
        body,_:=task_context["body"].(json.String)
        cv,cerr:=json.parse_string(string(raw_command),.JSON,true,context.temp_allocator)
        command,command_ok:=cv.(json.Object)
        if cerr!=.None || !command_ok do return "","the owner's task context is malformed; TASK.md was not updated"
        command["instance_id"]=json.String(instance)
        // As the requirements.present path: a no-directory chain runs in this
        // executor's per-chain scratch directory (no branch, no merge-back).
        if contracts.owner_string(command,"workdir")=="" {
            if scratch:=bridge_executor_scratch_workdir(bridge_executor_store.account,contracts.owner_string(command,"chain_id"));scratch!="" {
                command["workdir"]=json.String(scratch);command["branch"]=json.String("")
            }
        }
        if !bridge_owner_materialize_context(dir,command,string(body)) do return "","TASK.md could not be written with the current requirements (run lease next again)"
        delete_key(&data,"task_context")
    }
    if has_review {
        if !bridge_owner_review_context_write(Owner_Review_Context{dir,string(review)}) do return "","the review TASK.md could not be written (run lease next again)"
        delete_key(&data,"review_context")
    }
    o["data"]=data
    return bridge_owner_json(o),""
}
