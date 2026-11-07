package main

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import channel "odin_test:lib/executor_channel"
import executor "odin_test:lib/executor_local"
import vault "odin_test:lib/vault"

Executor_Notification_Observation :: struct {
    pid,ticket,input_profile,status,message_bytes_written:string,
    esc_written,enter_written:bool,
}
bridge_executor_notification_finish :: proc(n:json.Object,message:string,o:Executor_Notification_Observation,self:contracts.Owner_Verified_Key)->executor.Result {
    now:=bridge_executor_physical_clock(nil)
    r:=make(json.Object,context.temp_allocator)
    for f in contracts.executor_schema("notification_result") do r[f.name]=json.String(contracts.owner_string(n,f.name))
    digest,_:=contracts.executor_digest("notification",n)
    values:=[11][2]string{{"input_digest",digest},{"pid",o.pid},{"ticket",o.ticket},{"input_profile",o.input_profile},
        {"esc_written","1" if o.esc_written else "0"},{"message_bytes_written",o.message_bytes_written},
        {"enter_written","1" if o.enter_written else "0"},{"status",o.status},{"issued_ms",fmt.tprintf("%d",now)},
        {"request_expires_ms",contracts.owner_string(n,"request_expires_ms")},{"key_id",self.key_id}}
    for pair in values do r[pair[0]]=json.String(pair[1])
    r["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    signature,signed:=bridge_executor_sign(nil,"notification_result",r)
    if !signed do return {code="signer_unavailable"}
    r["signature"]=json.String(signature)
    if !contracts.executor_notification_result_matches(r,n,message,self,now) do return {code="invalid_notification_result"}
    return {code="ok",body=bridge_owner_json(r)}
}
bridge_executor_notification_observation :: proc(result:Bridge_PTY_Notification_Result)->Executor_Notification_Observation {
    r:=result.receipt
    return {r.pid,result.ticket,result.input_profile,r.status,r.message_bytes_written,r.esc_written,r.enter_written}
}

// Caller holds the executor application mutex. No mutex spans the owner HTTP
// callback. All physical observation and writes share startup I/O serialization.
bridge_executor_notification_dispatch :: proc(s:^executor.Store,raw,message:string,attempt:i64,
    owner_key,self:contracts.Owner_Verified_Key,kr:^vault.Vault_Keyring,generation:i64,
    callback_ctx:rawptr,fence_exchange:Executor_Fence_Exchange,io:Executor_Launch_IO)->executor.Result {
    n,parsed:=contracts.executor_parse(raw,"notification")
    now:=bridge_executor_physical_clock(nil)
    if !parsed || !executor.notification_current(s,n,message,owner_key,now) do return {code="no_current_target"}
    when ODIN_OS==.Windows {
        return bridge_executor_notification_finish(n,message,{"0","","","unsupported_not_delivered","0",false,false},self)
    }
    finished:=executor.notification_stage(s,n,message,owner_key,"result",now)
    if finished.code=="ok" {
        o:Executor_Notification_Observation
        if json.unmarshal_string(finished.body,&o,.JSON,context.temp_allocator)!=nil do return {code="invalid_saved_result"}
        return bridge_executor_notification_finish(n,message,o,self)
    }
    if finished.code!="not_found" do return finished
    socket:=io.socket
    owned:=socket==""
    if owned do socket=pty_host_socket_path()
    defer {if owned do delete(socket)}
    ticket:executor.Notification_Ticket
    physical:contracts.PTY_Notification_Delivery
    {
        sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
        if !bridge_executor_authority_begin(generation) do return {code="vault_locked"}
        defer bridge_executor_authority_end()
        now=bridge_executor_physical_clock(nil)
        if !executor.notification_current(s,n,message,owner_key,now) do return {code="no_current_target"}
        pid,known:=bridge_pty_host_executor_query(socket,contracts.owner_string(n,"instance_id"),contracts.owner_string(n,"launch_key"))
        if !known do return {code="child_unavailable"}
        if pid==0 do return bridge_executor_notification_finish(n,message,{"0","","","child_mismatch","0",false,false},self)
        saved:=executor.notification_stage(s,n,message,owner_key,"ticket",now)
        if saved.code=="ok" {
            if json.unmarshal_string(saved.body,&ticket,.JSON,context.temp_allocator)!=nil do return {code="invalid_saved_ticket"}
        } else if saved.code!="not_found" {return saved}
        physical=contracts.PTY_Notification_Delivery{
            protocol_version=1,source={contracts.owner_string(n,"instance_id"),contracts.owner_string(n,"launch_epoch"),contracts.owner_string(n,"run_count")},
            pid=fmt.tprintf("%d",pid),launch_key=contracts.owner_string(n,"token_generation"),
            operation_id=contracts.owner_string(n,"intent_id"),delivery_id=contracts.owner_string(n,"intent_id"),message=message,interrupt=true,
        }
        if ticket.ticket=="" {
            // Prepare writes nothing. A lost Prepare reply can only retrieve
            // the same daemon delivery ID; Dispatch never precedes persistence.
            prepared:=bridge_pty_notification_request(socket,physical,PTY_NOTIFICATION_PREPARE,"")
            defer delete(prepared.ticket);defer delete(prepared.input_profile)
            if prepared.error==.Unsupported_Not_Delivered {
                return bridge_executor_notification_finish(n,message,{"0","","","unsupported_not_delivered","0",false,false},self)
            }
            if prepared.error!=.None || prepared.receipt.status!="partial" do return {code="notification_prepare_uncertain"}
            ticket={physical.pid,prepared.ticket,prepared.input_profile,raw,message}
            stored:=executor.notification_record(s,n,message,owner_key,"ticket",bridge_owner_json(ticket),bridge_executor_physical_clock(nil))
            if stored.code!="ok" do return stored
            if json.unmarshal_string(stored.body,&ticket,.JSON,context.temp_allocator)!=nil do return {code="invalid_saved_ticket"}
        }
        if ticket.pid!=physical.pid do return bridge_executor_notification_finish(n,message,{"0","","","child_mismatch","0",false,false},self)
    }
    if fence_exchange==nil do return {code="owner_fence_not_current"}
    pending,ready:=executor.notification_challenge(s,raw,message,attempt,owner_key,self,bridge_executor_physical_clock(nil),{nil,bridge_executor_sign})
    if !ready do return {code="owner_fence_not_current"}
    defer executor.fence_challenge_destroy(&pending)
    sync.mutex_unlock(&bridge_executor_mutex)
    callback:=fence_exchange(callback_ctx,pending.request,generation)
    sync.mutex_lock(&bridge_executor_mutex)
    if generation!=bridge_task_chain_search_generation() do return {code="vault_locked"}
    directory,trusted:=bridge_executor_directory(s,callback.directory,kr)
    own,self_current:=directory.trusted[self.key_id];peer,owner_current:=directory.trusted[owner_key.key_id]
    if !trusted || !self_current || own.kind!="bridge" || own.sign_public_key!=self.public_key ||
       !owner_current || peer.kind!="bridge" || peer.sign_public_key!=owner_key.public_key ||
       !executor.owner_bound(s,n,"notification",owner_key) {return {code="invalid_scope"}}
    scope,scoped:=contracts.executor_parse(callback.scope,"transport_scope")
    if !scoped || contracts.owner_string(scope,"method")!="notification_fence_request" ||
       contracts.owner_string(scope,"direction")!="response" {return {code="invalid_owner_fence"}}
    reply,authenticated:=channel.open_signed(callback.envelope,kr,scope,owner_key,bridge_executor_physical_clock(nil),context.temp_allocator)
    if !authenticated do return {code="invalid_owner_fence"}
    defer crypto.zero_explicit(raw_data(reply),len(reply))
    proof:=executor.notification_fence_accept(s,&pending,reply,message,owner_key,self,bridge_executor_physical_clock(nil))
    if !proof.current do return {code="owner_fence_not_current"}
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    if !bridge_executor_authority_begin(generation) do return {code="vault_locked"}
    defer bridge_executor_authority_end()
    q,_:=contracts.executor_parse(pending.request,"notification_fence_request")
    elapsed:=time.tick_since(pending.started)
    if elapsed<0 || elapsed>=time.Duration(contracts.executor_number(q,"request_expires_ms")-contracts.executor_number(q,"issued_ms"))*time.Millisecond do return {code="owner_fence_not_current"}
    if !executor.notification_current(s,n,message,owner_key,bridge_executor_physical_clock(nil)) do return {code="no_current_target"}
    pid,known:=bridge_pty_host_executor_query(socket,physical.source.agent_instance_id,contracts.owner_string(n,"launch_key"))
    if !known do return {code="child_unavailable"}
    if fmt.tprintf("%d",pid)!=ticket.pid do return bridge_executor_notification_finish(n,message,{"0","","","child_mismatch","0",false,false},self)
    // Query the saved ticket first, including after every lost reply/restart.
    observed:=bridge_pty_notification_request(socket,physical,PTY_NOTIFICATION_QUERY,ticket.ticket,ticket.input_profile)
    defer delete(observed.ticket);defer delete(observed.input_profile)
    if observed.error!=.None do return {code="notification_query_uncertain"}
    if observed.receipt.status=="partial" {
        marker:=executor.notification_record(s,n,message,owner_key,"dispatch","{}",bridge_executor_physical_clock(nil))
        if marker.code!="ok" do return marker
        dispatched:=bridge_pty_notification_request(socket,physical,PTY_NOTIFICATION_DISPATCH,ticket.ticket,ticket.input_profile)
        defer delete(dispatched.ticket);defer delete(dispatched.input_profile)
        if dispatched.error==.Unsupported_Not_Delivered {
            return bridge_executor_notification_finish(n,message,{"0","","","unsupported_not_delivered","0",false,false},self)
        }
        if dispatched.error!=.None do return {code="notification_dispatch_uncertain"}
        o:=bridge_executor_notification_observation(dispatched)
        if o.status!="partial" {
            stored:=executor.notification_record(s,n,message,owner_key,"result",bridge_owner_json(o),bridge_executor_physical_clock(nil))
            if stored.code!="ok" do return stored
        }
        return bridge_executor_notification_finish(n,message,o,self)
    }
    o:=bridge_executor_notification_observation(observed)
    stored:=executor.notification_record(s,n,message,owner_key,"result",bridge_owner_json(o),bridge_executor_physical_clock(nil))
    if stored.code!="ok" do return stored
    return bridge_executor_notification_finish(n,message,o,self)
}
