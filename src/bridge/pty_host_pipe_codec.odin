package main

// Pipe-only extensions to pty_host_client. Every owned value uses the same
// caller allocator as the legacy codecs; delete replies with pty_host_reply_delete.
import "core:encoding/json"
import "core:strings"

Pty_Host_Pipe_Request_Kind :: enum u8 {
    Capabilities = 0x40, Spawn = 0x41, List = 0x42, Attach = 0x43,
    Input = 0x44, Ack = 0x45, Detach = 0x46,
}
Pty_Host_Pipe_Request :: struct {
    kind: Pty_Host_Pipe_Request_Kind,
    spawn: Pty_Host_Spawn_Request,
    instance, generation, delivery_id: string,
    seq: u64,
    data: []byte,
}

pty_host_encode_pipe_request :: proc(req: Pty_Host_Pipe_Request) -> []byte {
    if req.kind == .Spawn {
        spawn := req.spawn
        spawn.mode = .Pipe
        return pty_host_encode_spawn(spawn)
    }
    if u8(req.kind) < 0x40 || u8(req.kind) > 0x46 || len(req.data) > PTY_HOST_MAX_PIPE_DATA do return nil
    p := make([dynamic]byte); defer delete(p)
    append(&p, u8(req.kind))
    #partial switch req.kind {
    case .Attach, .Input, .Ack, .Detach:
        pty_host_put_str(&p, req.instance); pty_host_put_str(&p, req.generation)
    }
    #partial switch req.kind {
    case .Attach, .Ack: pty_host_put_u64(&p, req.seq)
    case .Input:
        pty_host_put_str(&p, req.delivery_id)
        pty_host_put_u32(&p, u32(len(req.data))); append(&p, ..req.data)
    }
    if len(p) > PTY_HOST_MAX_FRAME_BYTES do return nil
    return pty_host_frame(p[:])
}

pty_host_pipe_get_bool :: proc(b: []byte, off: ^int) -> (bool, bool) {
    if off^ >= len(b) || b[off^] > 1 do return false, false
    result := b[off^] == 1; off^ += 1; return result, true
}

pty_host_pipe_get_opt_str :: proc(b: []byte, off: ^int) -> (string, bool, bool) {
    present, ok := pty_host_pipe_get_bool(b, off)
    if !ok do return "", false, false
    if !present do return "", false, true
    value, vok := pty_host_get_str(b, off); return value, true, vok
}

pty_host_pipe_get_data :: proc(b: []byte, off: ^int) -> ([]byte, bool) {
    length, ok := pty_host_get_u32(b, off)
    if !ok || length > PTY_HOST_MAX_PIPE_DATA || int(length) > len(b)-off^ do return nil, false
    data := make([]byte, int(length)); copy(data, b[off^:off^+int(length)])
    off^ += int(length); return data, true
}

pty_host_pipe_request_delete :: proc(r: Pty_Host_Pipe_Request) {
    delete(r.instance); delete(r.generation); delete(r.delivery_id); delete(r.data)
    s := r.spawn
    delete(s.instance); for arg in s.argv do delete(arg); delete(s.argv)
    for kv in s.env { delete(kv[0]); delete(kv[1]) }; delete(s.env)
    delete(s.cwd); delete(s.detect); delete(s.display_name); delete(s.kind)
    delete(s.label); delete(s.meta_json); delete(s.tee_path)
}

pty_host_decode_pipe_request :: proc(payload: []byte) -> (request: Pty_Host_Pipe_Request, ok: bool) {
    r: Pty_Host_Pipe_Request
    defer { if !ok do pty_host_pipe_request_delete(r) }
    if len(payload) < 1 || len(payload) > PTY_HOST_MAX_FRAME_BYTES || payload[0] < 0x40 || payload[0] > 0x46 do return {}, false
    r.kind = Pty_Host_Pipe_Request_Kind(payload[0])
    off := 1
    valid := true
    #partial switch r.kind {
    case .Capabilities, .List:
    case .Attach, .Input, .Ack, .Detach:
        r.instance, valid = pty_host_get_str(payload, &off); if !valid do return {}, false
        r.generation, valid = pty_host_get_str(payload, &off); if !valid do return {}, false
        #partial switch r.kind {
        case .Attach, .Ack:
            r.seq, valid = pty_host_get_u64(payload, &off); if !valid do return {}, false
        case .Input:
            r.delivery_id, valid = pty_host_get_str(payload, &off); if !valid do return {}, false
            r.data, valid = pty_host_pipe_get_data(payload, &off); if !valid do return {}, false
        }
    case .Spawn:
        s := &r.spawn
        s.mode = .Pipe
        s.instance, valid = pty_host_get_str(payload, &off); if !valid do return {}, false
        n, nok := pty_host_get_u16(payload, &off); if !nok || int(n) > (len(payload)-off)/4 do return {}, false
        s.argv = make([]string, int(n))
        for i in 0..<int(n) { s.argv[i], valid = pty_host_get_str(payload, &off); if !valid do return {}, false }
        s.cwd, s.has_cwd, valid = pty_host_pipe_get_opt_str(payload, &off); if !valid do return {}, false
        ne, neok := pty_host_get_u16(payload, &off); if !neok || int(ne) > (len(payload)-off)/8 do return {}, false
        s.env = make([][2]string, int(ne))
        for i in 0..<int(ne) {
            s.env[i][0], valid = pty_host_get_str(payload, &off); if !valid do return {}, false
            s.env[i][1], valid = pty_host_get_str(payload, &off); if !valid do return {}, false
        }
        s.detect, s.has_detect, valid = pty_host_pipe_get_opt_str(payload, &off); if !valid do return {}, false
        s.rows, valid = pty_host_get_u16(payload, &off); if !valid do return {}, false
        s.cols, valid = pty_host_get_u16(payload, &off); if !valid do return {}, false
        s.display_name, s.has_display_name, valid = pty_host_pipe_get_opt_str(payload, &off); if !valid do return {}, false
        s.kind, s.has_kind, valid = pty_host_pipe_get_opt_str(payload, &off); if !valid do return {}, false
        s.label, s.has_label, valid = pty_host_pipe_get_opt_str(payload, &off); if !valid do return {}, false
        s.meta_json, s.has_meta, valid = pty_host_pipe_get_opt_str(payload, &off); if !valid do return {}, false
        if s.has_meta {
            value, err := json.parse(s.meta_json); if err != nil do return {}, false
            json.destroy_value(value)
        }
        s.tee_path, s.has_tee_path, valid = pty_host_pipe_get_opt_str(payload, &off); if !valid do return {}, false
        s.has_timeout_seconds, valid = pty_host_pipe_get_bool(payload, &off); if !valid do return {}, false
        if s.has_timeout_seconds { s.timeout_seconds, valid = pty_host_get_u64(payload, &off); if !valid do return {}, false }
    }
    if off != len(payload) do return {}, false
    return r, true
}

pty_host_encode_pipe_reply :: proc(r: Pty_Host_Reply) -> []byte {
    p := make([dynamic]byte); defer delete(p)
    #partial switch r.kind {
    case .Capabilities: append(&p, PTY_HOST_T_CAPABILITIES_REPLY, 1 if r.piped_spawn_v1 else 0)
    case .Pipe_List:
        append(&p, PTY_HOST_T_PIPE_LIST); pty_host_put_u32(&p, u32(len(r.pipes)))
        for row in r.pipes {
            pty_host_put_str(&p, row.instance); pty_host_put_str(&p, row.generation)
            pty_host_put_i32(&p, row.pid); append(&p, 1 if row.alive else 0, 1 if row.has_exit_code else 0)
            if row.has_exit_code do pty_host_put_i32(&p, row.exit_code)
            pty_host_put_opt_str(&p, row.has_meta, row.meta_json)
        }
    case .Pipe_Ready, .Pipe_Output, .Pipe_Input_Done, .Pipe_Gap:
        tag: byte
        #partial switch r.kind {
        case .Pipe_Ready: tag = PTY_HOST_T_PIPE_READY
        case .Pipe_Output: tag = PTY_HOST_T_PIPE_OUTPUT
        case .Pipe_Input_Done: tag = PTY_HOST_T_PIPE_INPUT_DONE
        case .Pipe_Gap: tag = PTY_HOST_T_PIPE_GAP
        }
        append(&p, tag); pty_host_put_str(&p, r.instance); pty_host_put_str(&p, r.generation)
        #partial switch r.kind {
        case .Pipe_Ready: pty_host_put_u64(&p, r.first_seq); pty_host_put_u64(&p, r.last_seq)
        case .Pipe_Output:
            if len(r.data) > PTY_HOST_MAX_PIPE_DATA || r.stream != 1 && r.stream != 2 || r.stream == 1 && r.seq == 0 || r.stream == 2 && r.seq != 0 do return nil
            pty_host_put_u64(&p, r.seq); append(&p, r.stream)
            pty_host_put_u32(&p, u32(len(r.data))); append(&p, ..r.data)
        case .Pipe_Input_Done: pty_host_put_str(&p, r.delivery_id)
        case .Pipe_Gap: pty_host_put_u64(&p, r.first_seq)
        }
    case: return nil
    }
    return pty_host_frame(p[:])
}

pty_host_decode_pipe_reply :: proc(payload: []byte) -> (reply: Pty_Host_Reply, ok: bool) {
    r: Pty_Host_Reply
    defer { if !ok do pty_host_reply_delete(r) }
    if len(payload) < 1 || len(payload) > PTY_HOST_MAX_FRAME_BYTES do return {}, false
    off := 1
    switch payload[0] {
    case PTY_HOST_T_CAPABILITIES_REPLY:
        r.kind = .Capabilities
        valid: bool
        r.piped_spawn_v1, valid = pty_host_pipe_get_bool(payload, &off)
        if !valid do return {}, false
    case PTY_HOST_T_PIPE_LIST:
        r.kind = .Pipe_List
        n, valid := pty_host_get_u32(payload, &off)
        if !valid || int(n) > (len(payload)-off)/15 do return {}, false
        r.pipes = make([]Pty_Host_Pipe_Info, int(n))
        for i in 0..<int(n) {
            row := &r.pipes[i]
            row.instance, valid = pty_host_get_str(payload, &off); if !valid do return {}, false
            row.generation, valid = pty_host_get_str(payload, &off); if !valid do return {}, false
            row.pid, valid = pty_host_get_i32(payload, &off); if !valid do return {}, false
            row.alive, valid = pty_host_pipe_get_bool(payload, &off); if !valid do return {}, false
            row.has_exit_code, valid = pty_host_pipe_get_bool(payload, &off); if !valid do return {}, false
            if row.has_exit_code { row.exit_code, valid = pty_host_get_i32(payload, &off); if !valid do return {}, false }
            row.meta_json, row.has_meta, valid = pty_host_pipe_get_opt_str(payload, &off); if !valid do return {}, false
            if row.has_meta {
                value, err := json.parse(row.meta_json); if err != nil do return {}, false
                json.destroy_value(value)
            }
        }
    case PTY_HOST_T_PIPE_READY, PTY_HOST_T_PIPE_OUTPUT, PTY_HOST_T_PIPE_INPUT_DONE, PTY_HOST_T_PIPE_GAP:
        valid: bool
        r.instance, valid = pty_host_get_str(payload, &off); if !valid do return {}, false
        r.generation, valid = pty_host_get_str(payload, &off); if !valid do return {}, false
        switch payload[0] {
        case PTY_HOST_T_PIPE_READY:
            r.kind = .Pipe_Ready
            r.first_seq, valid = pty_host_get_u64(payload, &off); if !valid do return {}, false
            r.last_seq, valid = pty_host_get_u64(payload, &off); if !valid do return {}, false
        case PTY_HOST_T_PIPE_OUTPUT:
            r.kind = .Pipe_Output
            r.seq, valid = pty_host_get_u64(payload, &off); if !valid do return {}, false
            if off >= len(payload) do return {}, false
            r.stream = payload[off]; off += 1
            if r.stream != 1 && r.stream != 2 || r.stream == 1 && r.seq == 0 || r.stream == 2 && r.seq != 0 do return {}, false
            r.data, valid = pty_host_pipe_get_data(payload, &off); if !valid do return {}, false
        case PTY_HOST_T_PIPE_INPUT_DONE:
            r.kind = .Pipe_Input_Done
            r.delivery_id, valid = pty_host_get_str(payload, &off); if !valid do return {}, false
        case PTY_HOST_T_PIPE_GAP:
            r.kind = .Pipe_Gap
            r.first_seq, valid = pty_host_get_u64(payload, &off); if !valid do return {}, false
        }
    case: return {}, false
    }
    if off != len(payload) do return {}, false
    return r, true
}

// Explicitly negotiate support before sending a new tag. An old daemon closing
// the socket, timing out, or returning Error always means unsupported.
pty_host_supports_pipes :: proc(socket_path: string) -> bool {
    frame := pty_host_encode_pipe_request({kind = .Capabilities}); defer delete(frame)
    reply, ok := pty_host_request_deadline(socket_path, frame, 2000)
    if !ok do return false
    defer pty_host_reply_delete(reply)
    return reply.kind == .Capabilities && reply.piped_spawn_v1
}

pty_host_spawn_pipe :: proc(socket_path: string, req: Pty_Host_Spawn_Request) -> (Pty_Host_Reply, bool) {
    if !pty_host_supports_pipes(socket_path) {
        return {kind = .Error, instance = strings.clone(req.instance), message = strings.clone("unsupported_runtime_transport")}, true
    }
    frame := pty_host_encode_pipe_request({kind = .Spawn, spawn = req})
    if len(frame) == 0 do return {}, false
    defer delete(frame)
    return pty_host_request_deadline(socket_path, frame, 5000)
}
