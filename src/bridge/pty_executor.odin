package main

import contracts "odin_test:contracts"
// 0x3C is reserved for the selected notification adapter; keep executor controls
// disjoint. The daemon echoes the exact key in its query response.
PTY_HOST_T_EXECUTOR_READY :: 0x3D
PTY_HOST_T_EXECUTOR_CLOSE :: 0x3E
PTY_HOST_T_EXECUTOR_LAUNCH :: 0x3F
pty_host_encode_executor_control :: proc(tag:u8,instance,key:string)->[]byte {
    if (tag!=PTY_HOST_T_EXECUTOR_CLOSE && tag!=PTY_HOST_T_EXECUTOR_LAUNCH) ||
       !contracts.owner_field_valid(instance,"id") || !contracts.owner_field_valid(key,"hash") {return nil}
    payload:=make([dynamic]byte);defer delete(payload)
    append(&payload,tag);pty_host_put_str(&payload,instance);pty_host_put_str(&payload,key)
    return pty_host_frame(payload[:])
}
bridge_pty_host_executor_query :: proc(socket,instance,key:string)->(i32,bool) {
    frame:=pty_host_encode_executor_control(PTY_HOST_T_EXECUTOR_LAUNCH,instance,key);defer delete(frame)
    if len(frame)==0 do return 0,false
    reply,ok:=pty_host_request(socket,frame)
    if !ok do return 0,false
    defer pty_host_reply_delete(reply)
    if reply.kind!=.Startup_Launch || reply.instance!=instance || reply.startup_key!=key || reply.pid<0 do return 0,false
    return reply.pid,true
}
bridge_pty_host_executor_close :: proc(socket,instance,key:string)->bool {
    frame:=pty_host_encode_executor_control(PTY_HOST_T_EXECUTOR_CLOSE,instance,key);defer delete(frame)
    if len(frame)==0 do return false
    reply,ok:=pty_host_request(socket,frame)
    if !ok do return false
    defer pty_host_reply_delete(reply)
    return reply.kind==.Closed && reply.instance==instance
}

// Old daemons reject this tag. Never send a fenced Spawn until this exact
// capability handshake succeeds, even though legacy Spawn itself is compatible.
bridge_pty_host_executor_capable :: proc(socket:string)->bool {
    frame:=pty_host_frame([]byte{PTY_HOST_T_EXECUTOR_READY});defer delete(frame)
    reply,ok:=pty_host_request(socket,frame)
    if !ok do return false
    defer pty_host_reply_delete(reply)
    return reply.kind==.Pong
}
