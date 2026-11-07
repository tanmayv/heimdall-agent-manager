package main

import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

// Local IPC adapter. Callers must retain intent/ticket durably and validate
// current immutable-owner and executor fences before mutating requests.
PTY_NOTIFICATION_PREPARE :: 0
PTY_NOTIFICATION_DISPATCH :: 1
PTY_NOTIFICATION_QUERY :: 2

pty_notification_get_str :: proc(bytes: []byte, offset: ^int) -> (string, bool) {
    size, ok:=pty_host_get_u32(bytes,offset)
    if !ok || size>256 || int(size)>len(bytes)-offset^ do return "",false
    text:=transmute(string)bytes[offset^:offset^+int(size)]
    if text!="" && !contracts.pty_notification_id_valid(text) do return "",false
    offset^+=int(size)
    return strings.clone(text),true
}

// Capture the generation of the exact assertion being spawned. Looking up just
// the latest instance record could relabel an old launch during token rotation.
bridge_pty_notification_spawn_fence :: proc(instance, agent_token: string) -> (epoch, count: string) {
    token_hash := bridge_local_hash_token(agent_token)
    defer delete(token_hash)
    sync.mutex_lock(&bridge_local_token_mutex)
    defer sync.mutex_unlock(&bridge_local_token_mutex)
    for i:=len(bridge_local_token_records)-1; i>=0; i-=1 {
        r:=bridge_local_token_records[i]
        if r.agent_instance_id != instance || r.token_hash != token_hash || r.role != .Agent || r.invalidated_at_unix_ms != 0 do continue
        if at:=strings.index(r.instance_token,"~"); at>=0 && at+1<len(r.instance_token) && r.run_count>0 {
            return strings.clone(r.instance_token[at+1:]),fmt.aprintf("%d",r.run_count)
        }
    }
    // Compatible legacy launch; notification prepare fails closed.
    return "",strings.clone("0")
}

pty_notification_pid :: proc(s: string) -> (i32, bool) {
    if !contracts.owner_field_valid(s,"positive") || len(s) > 10 do return 0, false
    n: i64
    for b in s do n = n*10+i64(b-'0')
    if n > 2147483647 do return 0, false
    return i32(n), true
}

pty_notification_encode :: proc(intent: contracts.PTY_Notification_Delivery, mode: u8, ticket: string) -> ([]byte, bool) {
    pid, ok := pty_notification_pid(intent.pid)
    if !ok || intent.protocol_version != 1 || !contracts.pty_notification_runtime_valid(intent.source) || !contracts.pty_notification_id_valid(intent.operation_id) || !contracts.pty_notification_id_valid(intent.delivery_id) || !contracts.pty_notification_id_valid(intent.launch_key) || !contracts.pty_notification_message_valid(intent.message) do return nil, false
    if mode > PTY_NOTIFICATION_QUERY || mode == PTY_NOTIFICATION_PREPARE && ticket != "" || mode != PTY_NOTIFICATION_PREPARE && !contracts.pty_notification_id_valid(ticket) do return nil, false
    payload := make([dynamic]byte)
    defer delete(payload)
    append(&payload, PTY_HOST_T_NOTIFICATION, mode)
    pty_host_put_str(&payload, ticket)
    pty_host_put_str(&payload, intent.source.agent_instance_id)
    pty_host_put_i32(&payload, pid)
    identity := []string{intent.launch_key, intent.source.launch_epoch, intent.source.run_count, intent.operation_id, intent.delivery_id}
    for s in identity do pty_host_put_str(&payload, s)
    append(&payload, u8(1) if intent.interrupt else u8(0))
    append(&payload, ..transmute([]byte)intent.message)
    return pty_host_frame(payload[:]), true
}

// Returned receipt borrows the immutable intent identity; ticket is owned.
// A failed socket request is uncertain: caller must query with the SAME saved
// ticket, never Prepare again or fall back to the ordinary one-way input path.
Bridge_PTY_Notification_Error :: enum { None, Invalid_Intent, Transport_Uncertain, Unsupported_Not_Delivered, Rejected, Invalid_Receipt }
Bridge_PTY_Notification_Result :: struct {
    receipt: contracts.PTY_Notification_Receipt,
    ticket, input_profile: string, // owned; persist together with immutable intent
    retry_after_ms: u32,
    error: Bridge_PTY_Notification_Error,
}
bridge_pty_notification_request :: proc(socket: string, intent: contracts.PTY_Notification_Delivery, mode: u8, saved_ticket: string, saved_profile := "") -> Bridge_PTY_Notification_Result {
    frame, valid := pty_notification_encode(intent, mode, saved_ticket)
    defer delete(frame)
    if !valid || intent.interrupt && mode!=PTY_NOTIFICATION_PREPARE && !contracts.pty_notification_id_valid(saved_profile) do return {error=.Invalid_Intent}
    reply, received := pty_host_request(socket, frame)
    if !received do return {error=.Transport_Uncertain}
    defer pty_host_reply_delete(reply)
    if reply.kind == .Error && reply.instance == intent.source.agent_instance_id {
        if reply.message == "notification: unsupported_not_delivered" || reply.message == "notification: literal_paste_unsupported_not_delivered" || reply.message == "notification: interrupt_profile_unsupported_not_delivered" do return {error=.Unsupported_Not_Delivered}
        return {error=.Rejected}
    }
    if reply.kind != .Notification_Receipt || reply.instance != intent.source.agent_instance_id || reply.notification_id != intent.delivery_id do return {error=.Invalid_Receipt}
    statuses := [4]string{"partial", "delivered", "recovery_required", "child_mismatch"}
    if reply.notification_status > 3 do return {error=.Invalid_Receipt}
    r := contracts.PTY_Notification_Receipt{
        protocol_version=1, delivery_id=intent.delivery_id, source=intent.source,
        pid=intent.pid, launch_key=intent.launch_key,
        esc_written=reply.notification_esc, message_bytes_written=fmt.tprintf("%d", reply.notification_bytes),
        enter_written=reply.notification_enter, status=statuses[reply.notification_status],
    }
    action := contracts.pty_notification_receipt_action(intent, r, true)
    if action == .Invalid || action == .Stale && r.status != "child_mismatch" do return {error=.Invalid_Receipt}
    if r.status == "partial" || r.status == "delivered" {
        if !contracts.pty_notification_id_valid(reply.notification_ticket) || mode != PTY_NOTIFICATION_PREPARE && reply.notification_ticket != saved_ticket do return {error=.Invalid_Receipt}
        if intent.interrupt && (!contracts.pty_notification_id_valid(reply.notification_profile) || mode!=PTY_NOTIFICATION_PREPARE && reply.notification_profile!=saved_profile) do return {error=.Invalid_Receipt}
        if reply.notification_retry_ms>0 && (!intent.interrupt || !r.esc_written || r.enter_written || reply.notification_bytes!=0) do return {error=.Invalid_Receipt}
    }
    return {receipt=r,ticket=strings.clone(reply.notification_ticket),input_profile=strings.clone(reply.notification_profile),retry_after_ms=reply.notification_retry_ms,error=.None}
}


// Authenticated main-child SessionStart observes a native session; it cannot
// choose a profile, override a bound session, or write/authorize notification.
bridge_pty_notification_session :: proc(rec:Bridge_Local_Agent_Token_Record,ev:contracts.Ext_Event) {
    if ev.provider!="codex" || ev.kind!=.Session || ev.session_phase!="start" ||
       ev.agent_id!="" || (ev.agent_type!="" && ev.agent_type!="main") ||
       !bridge_startup_rec_current(rec) { return }
    at:=strings.index(rec.instance_token,"~")
    if at<0 || at+1>=len(rec.instance_token) || rec.run_count<=0 do return
    epoch:=rec.instance_token[at+1:];count:=fmt.tprintf("%d",rec.run_count)
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    if !bridge_startup_rec_current(rec) do return
    socket:=pty_host_socket_path();defer delete(socket)
    pid,known:=bridge_pty_host_startup_launch(socket,rec.agent_instance_id,rec.token_hash)
    if !known || pid<=0 do return
    _=bridge_pty_notification_bind_session(socket,rec.agent_instance_id,pid,rec.token_hash,epoch,count,ev.session_id,ev.transcript_path,ev.session_source)
}

bridge_pty_notification_bind_session :: proc(socket,instance:string,pid:i32,key,epoch,count,session,path,source:string)->bool {
    if pid<=0 do return false
    for id in ([4]string{instance,key,epoch,count}) do if !contracts.pty_notification_id_valid(id) do return false
    // Runtime fences above are authority. Native observation fields are not:
    // authenticated malformed lifecycle input must poison the old binding,
    // rather than being discarded before the daemon can invalidate it.
    observed_session,observed_path,observed_source:=session,path,source
    if !contracts.pty_notification_id_valid(session) || len(path)>4096 || !contracts.pty_notification_id_valid(source) {
        observed_session="";observed_path="";observed_source="invalid"
    }
    payload:=make([dynamic]byte,context.temp_allocator)
    append(&payload,PTY_HOST_T_NOTIFICATION_SESSION)
    pty_host_put_str(&payload,instance);pty_host_put_i32(&payload,pid)
    for value in ([6]string{key,epoch,count,observed_session,observed_path,observed_source}) do pty_host_put_str(&payload,value)
    frame:=pty_host_frame(payload[:]);defer delete(frame)
    reply,received:=pty_host_request(socket,frame)
    if !received do return false
    defer pty_host_reply_delete(reply)
    return reply.kind==.Notification_Session_Bound && reply.instance==instance
}
