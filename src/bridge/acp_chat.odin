package main

import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import vm "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

ACP_CHAT_OUTBOX_MAX :: 4*1024*1024
ACP_CHAT_OUTBOX_ITEMS_MAX :: 128
// A frame may close an acknowledged segment and start another. Reserve room
// for both snapshots; the aggregate plaintext turn remains capped at 1 MiB.
ACP_CHAT_FRAME_RESERVE :: 1536*1024
ACP_Chat_Durable :: struct {
    turn_id, message_id, text, status, stop_reason, flushed_status: string,
    revision: i64,
    flushed_bytes: int,
    session_announced: bool,
    remote_terminal,publication_failed:bool,
    segment_index, turn_bytes: int,
    split_pending: bool,
    deferred_text: string,
    outbox: [dynamic]contracts.ACP_Assistant_Message_Input,
    // User inputs the current segment answers; next_input_ids apply to the
    // segment opened after an injected steer.
    input_ids, next_input_ids: [dynamic]string,
}
ACP_Chat :: struct {
    r: ^ACP_Runtime,
    worker: ^thread.Thread,
    stop, fetch: bool,
    d: ACP_Chat_Durable,
    text_buffer:[dynamic]byte,
    text_buffer_ready:bool,
    last_flush: i64,
    // This exchange is owned by worker -> dispatcher -> worker in acp_rpc_call.
    publication: string,
    retry_after: i64,
    // Worker-owned failure retry state; fetch itself is an atomic edge latch.
    input_retry_after, input_retry_delay: i64,
    vault_blocked: bool,
    blocker_id: string,
}

acp_chat_relay := bridge_local_relay_agent_envelope
acp_chat_keyring := bridge_read_vault_keyring

acp_chat_run :: proc(r:^ACP_Runtime) {
    context.allocator=runtime.heap_allocator()
    if r.chat!=nil && r.chat.worker==nil do r.chat.worker=thread.create_and_start_with_data(r.chat,acp_chat_worker)
}

acp_chat_can_process :: proc(data:rawptr) -> bool {
    r:=cast(^ACP_Runtime)data
    if r.quiescing || r.chat==nil do return true
    unlocked:=acp_chat_vault_ready()
    acp_chat_vault_blocker(r,!unlocked)
    return unlocked && r.chat.d.deferred_text=="" &&
        acp_chat_assistant_items(r.chat)<=ACP_CHAT_OUTBOX_ITEMS_MAX-2 &&
        acp_chat_bytes(r.chat)<=ACP_CHAT_OUTBOX_MAX-ACP_CHAT_FRAME_RESERVE
}

acp_chat_vault_blocker :: proc(r:^ACP_Runtime,blocked:bool) {
    chat:=r.chat
    if chat.vault_blocked==blocked do return
    context.allocator=runtime.heap_allocator()
    if blocked {
        if chat.blocker_id=="" {
            digest:=bridge_local_hash_token(r.epoch);defer delete(digest)
            chat.blocker_id=strings.concatenate({"acpvault_",strings.trim_prefix(digest,"sha1:")})
        }
        bridge_permission_register({request_id=chat.blocker_id,agent_instance_id=r.instance,provider=r.provider,kind="startup",summary="Bridge vault locked. Unlock this bridge to resume the ACP session.",input=`{"reason":"vault_locked","actions":[]}`,created_unix_ms=bridge_runtime_now_ms(),generation=1})
    } else { bridge_permission_remove(r.instance,chat.blocker_id) }
    chat.vault_blocked=blocked
}

acp_chat_open_metadata :: proc(value:json.Value,kr:^vault.Vault_Keyring) -> (json.Value,bool) {
    switch v in value {
    case json.String:
        text,ok:=bridge_vault_decrypt_field(string(v),kr,context.temp_allocator)
        return json.String(text),ok
    case json.Object:
        obj:=make(json.Object,allocator=context.temp_allocator)
        for key,item in v {
            opened,ok:=acp_chat_open_metadata(item,kr);if !ok do return json.Null(nil),false
            obj[key]=opened
        }
        return obj,true
    case json.Array:
        items:=make(json.Array,allocator=context.temp_allocator)
        for item in v {
            opened,ok:=acp_chat_open_metadata(item,kr);if !ok do return json.Null(nil),false
            append(&items,opened)
        }
        return items,true
    case json.Null,json.Integer,json.Float,json.Boolean: return value,true
    }
    return json.Null(nil),false
}

acp_chat_notify :: proc(instance:string) -> bool {
    sync.mutex_lock(&acp_runtime_mu);defer sync.mutex_unlock(&acp_runtime_mu)
    r:=acp_runtimes[instance]
    if r==nil || r.chat==nil do return false
    sync.atomic_store(&r.chat.fetch,true)
    return true
}

// The ready handshake closes the gap for messages sent while Hub WS was down.
// Only latch work here: HTTP and durable queue work stay on each chat worker.
acp_chat_hub_reconnected :: proc() {
    sync.mutex_lock(&acp_runtime_mu);defer sync.mutex_unlock(&acp_runtime_mu)
    for _,r in acp_runtimes {
        if r!=nil && r.chat!=nil && !sync.atomic_load(&r.chat.stop) do sync.atomic_store(&r.chat.fetch,true)
    }
}

acp_chat_fetch_due :: proc(chat:^ACP_Chat,now:i64) -> bool {
    notified:=sync.atomic_exchange(&chat.fetch,false)
    // A fresh push/ready edge signals connectivity and must not wait behind an
    // old failure deadline. Without an edge, only the bounded retry is due.
    return notified || (chat.input_retry_after!=0 && now>=chat.input_retry_after)
}

acp_chat_fetch_finished :: proc(chat:^ACP_Chat,ok:bool,now:i64) {
    if ok { chat.input_retry_after=0;chat.input_retry_delay=0;return }
    chat.input_retry_delay=min(30000,max(1000,chat.input_retry_delay*2))
    chat.input_retry_after=now+chat.input_retry_delay
    // Do not clear fetch: a notification during the HTTP drain must survive.
}

acp_chat_vault_ready :: proc() -> bool {
    kr,ok:=acp_chat_keyring(); defer vault.keyring_wipe(&kr); return ok
}

// Delivery reports coalesce and stay small; only assistant rows count against
// the item budget that pauses frame admission.
acp_chat_assistant_items :: proc(chat:^ACP_Chat) -> int {
    n:=0;for entry in chat.d.outbox do if entry.kind=="" do n+=1
    return n
}

acp_chat_ids_replace :: proc(target:^[dynamic]string,ids:[]string) {
    context.allocator=runtime.heap_allocator()
    for id in target do delete(id)
    clear(target)
    for id in ids do append(target,strings.clone(id))
}

acp_chat_set_next_inputs :: proc(r:^ACP_Runtime,ids:[]string) {
    if r.chat==nil do return
    acp_chat_ids_replace(&r.chat.d.next_input_ids,ids)
}

acp_chat_bytes :: proc(chat:^ACP_Chat) -> int {
    total:=0;for entry in chat.d.outbox do total+=len(entry.body)
    return total
}

acp_chat_reset_text :: proc(chat:^ACP_Chat) {
    if cap(chat.text_buffer)>0 do crypto.zero_explicit(raw_data(chat.text_buffer),cap(chat.text_buffer))
    clear(&chat.text_buffer);chat.d.text=""
}

// Grow geometrically, wiping the old allocation before releasing it. The
// durable text field borrows this buffer; checkpointing alone serializes it.
acp_chat_append_text :: proc(chat:^ACP_Chat,text:string) {
    context.allocator=runtime.heap_allocator()
    needed:=len(chat.text_buffer)+len(text)
    if cap(chat.text_buffer)<needed {
        size:=min(contracts.ACP_ASSISTANT_MAX_BYTES,max(needed,max(256,2*cap(chat.text_buffer))))
        next:=make([dynamic]byte,0,size)
        append(&next,..chat.text_buffer[:])
        if cap(chat.text_buffer)>0 do crypto.zero_explicit(raw_data(chat.text_buffer),cap(chat.text_buffer))
        delete(chat.text_buffer);chat.text_buffer=next
    }
    append(&chat.text_buffer,..transmute([]byte)text)
    chat.d.text=string(chat.text_buffer[:])
}

acp_chat_prompt_started :: proc(r:^ACP_Runtime,input_id:string) {
    if r.chat==nil || r.d.replay_only do return
    d:=&r.chat.d
    acp_runtime_replace(&d.turn_id,fmt.tprintf("ham:%s:%d",r.epoch,r.client.state.next_rpc_id))
    d.segment_index=0;d.turn_bytes=0;d.split_pending=false
    acp_chat_message_id(r)
    acp_chat_reset_text(r.chat);d.remote_terminal=false
    acp_runtime_replace(&d.flushed_status,""); acp_runtime_replace(&d.status,"pending"); acp_runtime_replace(&d.stop_reason,"")
    d.revision=0;d.flushed_bytes=0;r.chat.last_flush=0
    acp_chat_ids_replace(&d.input_ids,acp_delivery_members(r,input_id))
    acp_chat_ids_replace(&d.next_input_ids,nil)
    // Same checkpoint as the outgoing prompt RPC; ahead of any assistant text.
    acp_delivery_prompt_started(r,input_id,d.turn_id)
}

// Segment zero retains the old wire turn ID, including when restoring a
// pre-segmentation journal. Later IDs are deterministic publication identities,
// not additional ACP prompts or activity/budget boundaries.
acp_chat_wire_turn :: proc(d:^ACP_Chat_Durable) -> string {
    if d.segment_index==0 do return d.turn_id
    return fmt.tprintf("%s:s%d",d.turn_id,d.segment_index)
}

acp_chat_message_id :: proc(r:^ACP_Runtime) {
    d:=&r.chat.d
    digest:=bridge_local_hash_token(fmt.tprintf("%s:%s",r.instance,acp_chat_wire_turn(d)));defer delete(digest)
    hex:=strings.trim_prefix(digest,"sha1:")
    acp_runtime_replace(&d.message_id,fmt.tprintf("msg_%s",hex[:16]))
}

acp_chat_boundary :: proc(r:^ACP_Runtime) {
    if r.chat==nil || r.d.replay_only do return
    d:=&r.chat.d
    // Wait for nonempty continuation before terminalizing the previous row.
    // A tool-only ending must still put the real stop reason on the last row,
    // whose terminal status the Hub makes immutable.
    if d.status=="pending" && d.text!="" do d.split_pending=true
}

acp_chat_continue :: proc(r:^ACP_Runtime,text:string) -> bool {
    chat:=r.chat;d:=&chat.d
    if d.split_pending {
        acp_runtime_replace(&d.status,"complete")
        if !acp_chat_flush(r,true,checkpoint=false) { acp_runtime_replace(&d.status,"pending");return false }
        d.segment_index+=1;acp_chat_message_id(r)
        acp_chat_reset_text(chat);d.remote_terminal=false;d.split_pending=false
        d.revision=0;d.flushed_bytes=0;chat.last_flush=0
        acp_runtime_replace(&d.flushed_status,"");acp_runtime_replace(&d.status,"pending")
        if len(d.next_input_ids)>0 { acp_chat_ids_replace(&d.input_ids,d.next_input_ids[:]); acp_chat_ids_replace(&d.next_input_ids,nil) }
    }
    acp_chat_append_text(chat,text)
    return true
}

acp_chat_resume_deferred :: proc(r:^ACP_Runtime) -> bool {
    d:=&r.chat.d
    if d.deferred_text=="" do return true
    // Stop/error control commands can finalize while frame admission is paused.
    status:=strings.clone(d.status,context.temp_allocator)
    reason:=strings.clone(d.stop_reason,context.temp_allocator)
    text:=d.deferred_text;d.deferred_text=""
    acp_runtime_replace(&d.stop_reason,"")
    ok:=acp_chat_continue(r,text)
    acp_runtime_replace(&d.status,status);acp_runtime_replace(&d.stop_reason,reason)
    if !ok { d.deferred_text=text;return false }
    crypto.zero_explicit(raw_data(text),len(text));delete(text)
    // Closing and appending must reach disk atomically, including from a tick
    // outside a daemon frame; otherwise a crash could lose the deferred text.
    return r.client==nil || r.client.in_frame || acp_rpc_checkpoint(r.client)
}

acp_chat_chunk :: proc(r:^ACP_Runtime,text:string) {
    if !r.d.replay_only && text!="" do bridge_runtime_emit(r.instance,.Turn_Output)
    if r.chat==nil || r.d.replay_only || r.chat.d.status!="pending" || r.chat.d.remote_terminal || r.chat.d.publication_failed || text=="" do return
    d:=&r.chat.d
    if d.turn_bytes+len(text)>contracts.ACP_ASSISTANT_MAX_BYTES {
        // Keep the last valid partial snapshot; an oversized turn never succeeds.
        acp_runtime_replace(&d.status,"failed"); acp_runtime_replace(&d.stop_reason,"assistant_message_too_large")
        acp_tools_finish(r,"assistant_message_too_large")
        acp_chat_flush(r,true)
        acp_runtime_driver(r).cancel(r)
        return
    }
    d.turn_bytes+=len(text)
    // If vault sealing fails after frame admission, retain the continuation in
    // the journal and pause frames until chat_tick can close the old segment.
    if !acp_chat_continue(r,text) { acp_runtime_replace(&d.deferred_text,text);return }
    acp_chat_flush(r,false)
}

acp_chat_prompt_finished :: proc(r:^ACP_Runtime,input_id,result,error:string) {
    if r.chat==nil || r.d.replay_only do return
    d:=&r.chat.d
    if d.status!="failed" {
        acp_runtime_replace(&d.status,"failed" if error!="" else "complete")
        reason:=acp_event_string(acp_event_object(result),"stopReason")
        if error!="" do reason=error
        acp_runtime_replace(&d.stop_reason,reason)
    }
    acp_chat_flush(r,true)
}

acp_chat_flush :: proc(r:^ACP_Runtime,final:bool,checkpoint:=true) -> bool {
    chat:=r.chat; if chat==nil do return true
    if chat.d.deferred_text!="" do return false
    d:=&chat.d
    if d.text=="" || d.turn_id=="" || d.remote_terminal || d.publication_failed do return true
    now:=bridge_runtime_now_ms()
    if !final && d.status==d.flushed_status && (len(d.text)==d.flushed_bytes || (now-chat.last_flush<100 && len(d.text)-d.flushed_bytes<8192)) do return true
    // Once a terminal snapshot exists, periodic ticks must not create revisions.
    if len(d.text)==d.flushed_bytes && d.revision>0 && d.flushed_status==d.status do return true
    kr,unlocked:=acp_chat_keyring(); defer vault.keyring_wipe(&kr)
    if !unlocked do return false
    sealed,encrypted:=bridge_encrypt_vault_text(d.text,&kr); if !encrypted do return false
    context.allocator=runtime.heap_allocator()
    old:=-1
    for entry,i in d.outbox do if entry.message_id==d.message_id do old=i
    required:=acp_chat_bytes(chat)+len(sealed)
    if old>=0 do required-=len(d.outbox[old].body)
    if required>ACP_CHAT_OUTBOX_MAX || (old<0 && acp_chat_assistant_items(chat)>=ACP_CHAT_OUTBOX_ITEMS_MAX) { delete(sealed); return false }
    d.revision+=1
    ids:=make([]string,len(d.input_ids))
    for id,i in d.input_ids do ids[i]=strings.clone(id)
    entry:=contracts.ACP_Assistant_Message_Input{launch_epoch=strings.clone(r.epoch),turn_id=strings.clone(acp_chat_wire_turn(d)),message_id=strings.clone(d.message_id),revision=d.revision,body=sealed,message_status=strings.clone(d.status),stop_reason=strings.clone(d.stop_reason),input_ids=ids}
    if old>=0 { acp_chat_entry_delete(d.outbox[old]);d.outbox[old]=entry } else { append(&d.outbox,entry) }
    d.flushed_bytes=len(d.text);acp_runtime_replace(&d.flushed_status,d.status);chat.last_flush=now
    acp_runtime_replace(&r.saved_outbox,acp_event_json(chat.d))
    return !checkpoint || r.client == nil || r.client.in_frame || acp_rpc_checkpoint(r.client)
}

acp_chat_entry_delete :: proc(entry:contracts.ACP_Assistant_Message_Input) {
    delete(entry.launch_epoch);delete(entry.turn_id);delete(entry.message_id);delete(entry.body);delete(entry.message_status);delete(entry.stop_reason)
    for id in entry.input_ids do delete(id)
    delete(entry.input_ids);delete(entry.kind)
}

acp_chat_prepare :: proc(r:^ACP_Runtime) -> bool {
    context.allocator=runtime.heap_allocator()
    if r.chat!=nil do return true
    chat:=new(ACP_Chat);chat.r=r;r.chat=chat
    raw:=r.saved_outbox
    if raw!="" && (len(raw)>12*1024*1024 || json.unmarshal_string(raw,&chat.d)!=nil) { acp_chat_destroy(r); return false }
    d:=&chat.d
    // Older journals did not track aggregate bytes and contain one segment.
    if d.turn_bytes==0 && d.segment_index==0 do d.turn_bytes=len(d.text)
    if len(d.text)>contracts.ACP_ASSISTANT_MAX_BYTES || len(d.deferred_text)>contracts.ACP_ASSISTANT_MAX_BYTES ||
        d.turn_bytes<len(d.text)+len(d.deferred_text) || d.turn_bytes>contracts.ACP_ASSISTANT_MAX_BYTES ||
        d.segment_index<0 || d.segment_index>d.turn_bytes || len(acp_chat_wire_turn(d))>256 || len(d.message_id)>256 ||
        len(d.outbox)>2*ACP_CHAT_OUTBOX_ITEMS_MAX || acp_chat_assistant_items(chat)>ACP_CHAT_OUTBOX_ITEMS_MAX || acp_chat_bytes(chat)>ACP_CHAT_OUTBOX_MAX || d.revision<0 ||
        len(d.input_ids)>contracts.ACP_SEND_NOW_MAX_MEMBERS+128 || len(d.next_input_ids)>contracts.ACP_SEND_NOW_MAX_MEMBERS+128 { acp_chat_destroy(r);return false }
    for entry in d.outbox {
        if entry.kind==contracts.ACP_OUTBOX_INPUT_STATE {
            if entry.launch_epoch!=r.epoch || entry.revision<1 || entry.message_id=="" || len(entry.body)>256*1024 { acp_chat_destroy(r);return false }
            continue
        }
        if entry.kind!="" || entry.launch_epoch!=r.epoch || entry.revision<1 || entry.message_id=="" || entry.turn_id=="" || len(entry.turn_id)>256 || len(entry.input_ids)>contracts.ACP_SEND_NOW_MAX_MEMBERS+128 || (entry.message_status!="pending" && entry.message_status!="complete" && entry.message_status!="failed") { acp_chat_destroy(r);return false }
    }
    owned:=d.text;d.text="";chat.text_buffer_ready=true
    acp_chat_append_text(chat,owned)
    if owned!="" do crypto.zero_explicit(raw_data(owned),len(owned))
    delete(owned)
    sync.atomic_store(&chat.fetch,true)
    return true
}

acp_chat_destroy :: proc(r:^ACP_Runtime) {
    context.allocator=runtime.heap_allocator()
    chat:=r.chat;if chat==nil do return
    acp_chat_stop(r)
    d:=&chat.d
    delete(d.turn_id);delete(d.message_id);delete(d.status);delete(d.stop_reason);delete(d.flushed_status)
    if d.deferred_text!="" do crypto.zero_explicit(raw_data(d.deferred_text),len(d.deferred_text))
    delete(d.deferred_text)
    if chat.text_buffer_ready { acp_chat_reset_text(chat);delete(chat.text_buffer) }
    else { if d.text!="" do crypto.zero_explicit(raw_data(d.text),len(d.text));delete(d.text) }
    for entry in d.outbox do acp_chat_entry_delete(entry)
    for id in d.input_ids do delete(id)
    for id in d.next_input_ids do delete(id)
    delete(d.input_ids);delete(d.next_input_ids)
    if chat.vault_blocked do bridge_permission_remove(r.instance,chat.blocker_id)
    delete(chat.blocker_id);delete(d.outbox);delete(chat.publication);free(chat);r.chat=nil
}

acp_chat_stop :: proc(r:^ACP_Runtime) {
    chat:=r.chat;if chat==nil do return
    sync.atomic_store(&chat.stop,true)
    if chat.worker!=nil { thread.join(chat.worker);thread.destroy(chat.worker) }
    chat.worker=nil
}

acp_chat_call :: proc(chat:^ACP_Chat,argument:string) -> bool {
    cmd:=ACP_RPC_Command{kind=.Runtime,a=argument,runtime_work=acp_runtime_work,runtime_data=chat.r}
    acp_rpc_call(chat.r.client,&cmd);return cmd.ok
}

ACP_Chat_Publication_Result :: enum { Retry, Saved, Terminal, Rejected }
acp_chat_publication_result :: proc(reply:Bridge_Local_Relay_Result) -> ACP_Chat_Publication_Result {
    if reply.ok && (reply.status==200 || reply.status==201) do return .Saved
    if reply.status==409 && strings.contains(reply.body,"assistant terminal status is immutable") do return .Terminal
    if reply.status>=400 && reply.status<500 && reply.status!=408 && reply.status!=429 do return .Rejected
    return .Retry
}

// Routes one outbox entry: assistant revisions to assistant-message, delivery
// reports (body = report JSON) to input-state. A rejected report is dropped
// rather than failing the runtime: evidence must never stop the agent.
acp_chat_publish_entry :: proc(publication:string,rec:Bridge_Local_Agent_Token_Record) -> ACP_Chat_Publication_Result {
    obj:=acp_event_object(publication)
    if acp_event_string(obj,"kind")==contracts.ACP_OUTBOX_INPUT_STATE {
        reply:=acp_chat_relay(route_path("api","v1","agent-actions","chat","input-state"),"agent.chat.input_state",acp_event_string(obj,"body"),rec,5000)
        defer delete(reply.body)
        result:=acp_chat_publication_result(reply)
        if result==.Rejected || result==.Terminal {
            fmt.println("ACP delivery report rejected",reply.status)
            return .Saved
        }
        return result
    }
    reply:=acp_chat_relay(route_path("api","v1","agent-actions","chat","assistant-message"),"agent.chat.assistant_message",publication,rec,5000)
    defer delete(reply.body)
    return acp_chat_publication_result(reply)
}

acp_chat_publish :: proc(chat:^ACP_Chat) -> ACP_Chat_Publication_Result {
    result:=acp_chat_publish_entry(chat.publication,chat.r.rec)
    switch result {
    case .Saved: acp_chat_call(chat,strings.concatenate({"chat_saved:",chat.publication},context.temp_allocator))
    case .Terminal: acp_chat_call(chat,strings.concatenate({"chat_terminal:",chat.publication},context.temp_allocator))
    case .Rejected: acp_chat_call(chat,"chat_rejected")
    case .Retry:
    }
    return result
}

acp_chat_worker :: proc(data:rawptr) {
    context.allocator=runtime.heap_allocator()
    arena:vm.Arena;_=vm.arena_init_growing(&arena);defer vm.arena_destroy(&arena)
    context.temp_allocator=vm.arena_allocator(&arena)
    chat:=cast(^ACP_Chat)data
    for !sync.atomic_load(&chat.stop) {
        mem.free_all(context.temp_allocator)
        if !acp_chat_vault_ready() { time.sleep(100*time.Millisecond);continue }
        if !acp_chat_call(chat,"chat_tick") { time.sleep(100*time.Millisecond);continue }
        if chat.publication!="" && bridge_runtime_now_ms()>=chat.retry_after {
            if acp_chat_publish(chat)!=.Retry {
                chat.retry_after=0
            } else {
                chat.retry_after=bridge_runtime_now_ms()+1000
            }
        }
        now:=bridge_runtime_now_ms()
        if acp_chat_fetch_due(chat,now) {
            ok:=acp_chat_fetch_inputs(chat)
            acp_chat_fetch_finished(chat,ok,bridge_runtime_now_ms())
        }
        time.sleep(50*time.Millisecond)
    }
}

acp_chat_work :: proc(r:^ACP_Runtime,argument:string) -> bool {
    chat:=r.chat;if chat==nil do return false
    if strings.has_prefix(argument,"chat_queue:") {
        if r.quiescing || !acp_chat_vault_ready() do return false
        raw:=argument[len("chat_queue:"):]
        return acp_runtime_work(r,r.client,raw)
    }
    if strings.has_prefix(argument,"chat_ack:") {
        obj:=acp_event_object(argument[len("chat_ack:"):])
        ids,_:=obj["ack_message_ids"].(json.Array)
        for value in ids {
            id,_:=value.(json.String)
            for saved,i in r.client.state.queued_input_message_ids {
                if saved==string(id) { delete(saved);ordered_remove(&r.client.state.queued_input_message_ids,i);break }
            }
        }
        return acp_rpc_checkpoint(r.client)
    }
    if argument=="chat_tick" {
        if r.quiescing || chat.d.publication_failed do return false
        if !acp_chat_resume_deferred(r) do return false
        if !acp_chat_flush(r,false) do return false
        acp_runtime_replace(&chat.publication,"")
        if len(chat.d.outbox)>0 do acp_runtime_replace(&chat.publication,acp_event_json(chat.d.outbox[0]))
        acp_runtime_drain(r)
        return true
    }
    if argument=="chat_rejected" {
        chat.d.publication_failed=true
        acp_runtime_error(r,"acp_chat_publish_rejected")
        return acp_rpc_checkpoint(r.client)
    }
    terminal:=strings.has_prefix(argument,"chat_terminal:")
    if terminal || strings.has_prefix(argument,"chat_saved:") {
        prefix:="chat_terminal:" if terminal else "chat_saved:"
        obj:=acp_event_object(argument[len(prefix):])
        id:=acp_event_string(obj,"message_id")
        rev,_:=obj["revision"].(json.Float)
        for entry,i in chat.d.outbox {
            if entry.message_id!=id || (!terminal && entry.revision!=i64(rev)) do continue
            acp_chat_entry_delete(entry);ordered_remove(&chat.d.outbox,i);break
        }
        if terminal && chat.d.message_id==id do chat.d.remote_terminal=true
        return acp_rpc_checkpoint(r.client)
    }
    return false
}

acp_chat_fetch_inputs :: proc(chat:^ACP_Chat) -> bool {
    // Draining/acknowledging each oldest batch avoids timestamp-only pagination
    // gaps when many input rows share the same created_at.
    for batch in 0..<32 {
        if sync.atomic_load(&chat.stop) do return false
        params:=acp_event_json(contracts.ACP_Chat_Input_Fetch{input_source=contracts.ACP_CHAT_INPUT_SOURCE,unread_only=true,receiver_only=true,oldest_first=true,limit=100})
        reply:=acp_chat_relay(route_path("api","v1","agent-actions","chat","read"),"agent.chat.read",params,chat.r.rec,5000)
        defer delete(reply.body)
        if !reply.ok || reply.status!=200 do return false
        parsed,err:=json.parse(reply.body,allocator=context.temp_allocator)
        root,object:=parsed.(json.Object);if err!=nil || !object do return false
        data,has_data:=root["data"].(json.Object);if !has_data do return false
        rows,has_rows:=data["messages"].(json.Array);if !has_rows do return false
        if len(rows)==0 do return true
        kr,unlocked:=acp_chat_keyring();if !unlocked do return false
        ids:=make([dynamic]string,allocator=context.temp_allocator)
        accepted:=true
        for value in rows {
            row,_:=value.(json.Object)
            id:=acp_event_string(row,"message_id")
            text,opened:=acp_chat_input_text(row,&kr)
            if !opened || id=="" { accepted=false;break }
            raw:=acp_event_json(struct{id,text:string}{id,text})
            queued:=acp_chat_call(chat,strings.concatenate({"chat_queue:",raw},context.temp_allocator))
            crypto.zero_explicit(raw_data(raw),len(raw));crypto.zero_explicit(raw_data(text),len(text))
            if !queued { accepted=false;break }
            append(&ids,id)
        }
        vault.keyring_wipe(&kr)
        // A partially queued batch is retried from the durable inbox; its queued
        // IDs are deduplicated by the driver. Never ack an unqueued row.
        if !accepted do return false
        ack:=acp_event_json(struct{ack_message_ids:[]string}{ids[:]})
        receipt:=acp_chat_relay(route_path("api","v1","agent-actions","chat","read"),"agent.chat.read",ack,chat.r.rec,5000)
        acked:=receipt.ok && receipt.status==200;delete(receipt.body)
        if !acked do return false
        if !acp_chat_call(chat,strings.concatenate({"chat_ack:",ack},context.temp_allocator)) do return false
    }
    return false
}

acp_chat_input_text :: proc(row:json.Object,kr:^vault.Vault_Keyring) -> (string,bool) {
    body,opened:=bridge_vault_decrypt_field(acp_event_string(row,"body"),kr,context.temp_allocator)
    if !opened do return "",false
    defer crypto.zero_explicit(raw_data(body),len(body))
    metadata:=row["metadata"]
    // Walk JSON values so quotes/newlines in decrypted answers remain escaped.
    opened_metadata,metadata_ok:=acp_chat_open_metadata(metadata,kr)
    if !metadata_ok do return "",false
    decrypted:=acp_event_json(opened_metadata)
    defer crypto.zero_explicit(raw_data(decrypted),len(decrypted))
    sender:=acp_event_string(row,"sender_agent_instance_id")
    if acp_event_string(row,"direction")=="user_to_agent" do sender="user"
    if sender=="" do sender=acp_event_string(row,"direction")
    return fmt.tprintf("[Heimdall message context]\nsender: %s\nmessage_id: %s\nanswer_metadata: %s\nartifact_refs: %s\nAttachments are fetchable artifact references. Inline images/resources are not supplied in this text prompt.\n[/Heimdall message context]\n\n%s",sender,acp_event_string(row,"message_id"),decrypted,acp_chat_artifact_refs_text(row),body),true
}

// acp_chat_artifact_refs_text renders the prompt's artifact_refs value as
// `[art_x (voice, audio/ogg), art_y (file)]` from the hub's `artifacts`
// descriptors so an agent can tell a voice note from a document (REQ-VOICE-5).
// Rows without descriptors (older hubs) fall back to the bare artifact_ids list.
acp_chat_artifact_refs_text :: proc(row:json.Object) -> string {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_byte(&b,'[')
    count:=0
    if refs,ok:=row["artifacts"].(json.Array);ok && len(refs)>0 {
        for v in refs {
            ref,is_obj:=v.(json.Object)
            if !is_obj do continue
            id:=acp_event_string(ref,"artifact_id")
            if id=="" do continue
            if count>0 do strings.write_string(&b,", ")
            count+=1
            strings.write_string(&b,id)
            kind:=acp_event_string(ref,"kind")
            mime:=acp_event_string(ref,"mime")
            available,has_available:=ref["available"].(json.Boolean)
            switch {
            case has_available && !available: strings.write_string(&b," (unavailable)")
            case kind!="" && mime!="": fmt.sbprintf(&b," (%s, %s)",kind,mime)
            case kind!="": fmt.sbprintf(&b," (%s)",kind)
            case mime!="": fmt.sbprintf(&b," (%s)",mime)
            }
        }
    } else if ids,ok:=row["artifact_ids"].(json.Array);ok {
        for v in ids {
            id,is_str:=v.(json.String)
            if !is_str || id=="" do continue
            if count>0 do strings.write_string(&b,", ")
            count+=1
            strings.write_string(&b,string(id))
        }
    }
    strings.write_byte(&b,']')
    return strings.to_string(b)
}
