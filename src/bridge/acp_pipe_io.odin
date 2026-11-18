package main

import "base:runtime"
import "core:strings"
import "core:sync"
import local_socket "odin_test:lib/local_socket"

// One dedicated attachment per ACP child. This adapter never owns the child.
// shutdown -> join (RPC close) -> destroy/close is intentional; see
// docs/socket-lifetime.md. The mutex serializes all wire frames, including ACKs.
ACP_Pipe_IO :: struct {
    fd: local_socket.Socket,
    instance, generation: string,
    mu: sync.Mutex,
    stopped: bool,
}

acp_pipe_io_open :: proc(socket_path, instance, generation, epoch, state_path: string, after_seq: u64) -> (ACP_RPC_IO, bool) {
    context.allocator = runtime.heap_allocator()
    fd, ok := pty_host_dial(socket_path)
    if !ok do return {}, false
    a := new(ACP_Pipe_IO)
    a.fd = fd; a.instance = strings.clone(instance); a.generation = strings.clone(generation)
    frame := pty_host_encode_pipe_request({kind = .Attach, instance = instance, generation = generation, seq = after_seq})
    defer delete(frame)
    if !pty_host_send_all(fd, frame) { acp_pipe_io_destroy(a); return {}, false }
    // Ready is consumed by the reader. This avoids blocking open when the
    // caller needs to restore a checkpoint before any output is dispatched.
    return {data = a, instance = instance, launch_epoch = epoch, state_path = state_path,
        read = acp_pipe_io_read, write = acp_pipe_io_write, ack = acp_pipe_io_ack,
        close = acp_pipe_io_close, destroy = acp_pipe_io_destroy}, true
}

acp_pipe_io_send :: proc(a: ^ACP_Pipe_IO, r: Pty_Host_Pipe_Request) -> bool {
    sync.mutex_lock(&a.mu); defer sync.mutex_unlock(&a.mu)
    if sync.atomic_load(&a.stopped) do return false
    frame := pty_host_encode_pipe_request(r)
    defer delete(frame)
    return len(frame) != 0 && pty_host_send_all(a.fd, frame)
}
acp_pipe_io_write :: proc(data: rawptr, bytes, delivery_id: string) -> bool {
    a := cast(^ACP_Pipe_IO)data
    return acp_pipe_io_send(a, {kind = .Input, instance = a.instance, generation = a.generation, delivery_id = delivery_id, data = transmute([]byte)bytes})
}
acp_pipe_io_ack :: proc(data: rawptr, seq: u64) -> bool {
    a := cast(^ACP_Pipe_IO)data
    return acp_pipe_io_send(a, {kind = .Ack, instance = a.instance, generation = a.generation, seq = seq})
}
acp_pipe_io_read :: proc(data: rawptr) -> (ACP_RPC_Frame, bool) {
    a := cast(^ACP_Pipe_IO)data
    for !sync.atomic_load(&a.stopped) {
        raw, ok := pty_host_read_frame(a.fd)
        if !ok do return {}, false
        r, valid := pty_host_decode_reply(raw)
        delete(raw)
        if !valid do return {}, false
        matching := r.instance == a.instance && r.generation == a.generation
        frame: ACP_RPC_Frame
        deliver := false
        #partial switch r.kind {
        case .Pipe_Ready:
            if !matching { pty_host_reply_delete(r); return {}, false }
        case .Pipe_Output:
            if !matching { pty_host_reply_delete(r); return {}, false }
            frame.kind = .Stdout if r.stream == 1 else .Diagnostic
            frame.bytes = strings.clone(string(r.data)); frame.seq = r.seq; deliver = true
        case .Pipe_Input_Done:
            if !matching { pty_host_reply_delete(r); return {}, false }
            frame = {kind = .Receipt, bytes = strings.clone(r.delivery_id)}; deliver = true
        case .Pipe_Gap, .Error: pty_host_reply_delete(r); return {}, false
        case: pty_host_reply_delete(r); return {}, false
        }
        pty_host_reply_delete(r)
        if deliver do return frame, true
    }
    return {}, false
}
acp_pipe_io_close :: proc(data: rawptr) {
    a := cast(^ACP_Pipe_IO)data
    // Do not acquire the send mutex before shutdown: a blocked send must also
    // wake so the joining owner can reclaim this descriptor.
    if !sync.atomic_exchange(&a.stopped, true) do local_socket.shutdown(a.fd, .Both)
}
acp_pipe_io_destroy :: proc(data: rawptr) {
    context.allocator = runtime.heap_allocator()
    a := cast(^ACP_Pipe_IO)data
    local_socket.close(a.fd)
    delete(a.instance); delete(a.generation); free(a)
}
