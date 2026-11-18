#+build !windows
package main

import "core:testing"
import "core:strings"
import "core:thread"
import "core:mem"
import "base:runtime"
import "core:sys/posix"
import "core:fmt"
import "core:time"
import local_socket "odin_test:lib/local_socket"

@(test)
pty_host_pipe_request_roundtrips_and_golden_vectors :: proc(t: ^testing.T) {
    requests := [?]Pty_Host_Pipe_Request{
        {kind = .Capabilities}, {kind = .List},
        {kind = .Spawn, spawn = {instance = "i", argv = {"cat"}, env = {{"K","V"}}, has_cwd = true, cwd = "/tmp", has_meta = true, meta_json = "{\"provider\":\"claude\"}", has_timeout_seconds = true, timeout_seconds = 10}},
        {kind = .Attach, instance = "i", generation = "g", seq = 9},
        {kind = .Input, instance = "i", generation = "g", delivery_id = "d", data = {0,255,10}},
        {kind = .Ack, instance = "i", generation = "g", seq = 10},
        {kind = .Detach, instance = "i", generation = "g"},
    }
    for req in requests {
        bytes := pty_host_encode_pipe_request(req); defer delete(bytes)
        payload := pty_host_test_reframe(t, bytes)
        decoded, ok := pty_host_decode_pipe_request(payload)
        testing.expect(t, ok)
        if !ok do continue
        again := pty_host_encode_pipe_request(decoded)
        testing.expect_value(t, string(again), string(bytes)); delete(again); pty_host_pipe_request_delete(decoded)
        for n in 0..<len(payload) {
            partial, valid := pty_host_decode_pipe_request(payload[:n])
            testing.expect(t, !valid)
            if valid do pty_host_pipe_request_delete(partial)
        }
        extra := make([]byte, len(payload)+1); copy(extra, payload)
        partial, valid := pty_host_decode_pipe_request(extra)
        testing.expect(t, !valid); if valid do pty_host_pipe_request_delete(partial)
        delete(extra)
    }
    attach := pty_host_encode_pipe_request({kind = .Attach, instance = "i", generation = "g", seq = 9}); defer delete(attach)
    expected := [?]byte{0,0,0,19,0x43,0,0,0,1,'i',0,0,0,1,'g',0,0,0,0,0,0,0,9}
    testing.expect_value(t, string(attach), string(expected[:]))
    // Legacy spawn body stays exactly the same; only the new tag implies Pipe.
    req := Pty_Host_Spawn_Request{instance = "i", argv = {"cat"}}
    old := pty_host_encode_spawn(req); defer delete(old)
    req.mode = .Pipe
    piped := pty_host_encode_spawn(req); defer delete(piped)
    testing.expect_value(t, old[4], u8(0x20)); testing.expect_value(t, piped[4], u8(0x41))
    testing.expect_value(t, string(old[5:]), string(piped[5:]))
    req.mode = cast(Pty_Host_Spawn_Mode)255
    testing.expect_value(t, len(pty_host_encode_spawn(req)), 0)
}

@(test)
pty_host_pipe_reply_roundtrips_strict_lengths_and_streams :: proc(t: ^testing.T) {
    replies := [?]Pty_Host_Reply{
        {kind = .Capabilities, piped_spawn_v1 = true},
        {kind = .Pipe_List, pipes = {{instance = "i", generation = "g", pid = 42, alive = false, has_exit_code = true, exit_code = -9, has_meta = true, meta_json = "{\"provider\":\"claude\"}"}}},
        {kind = .Pipe_Ready, instance = "i", generation = "g", first_seq = 1, last_seq = 10},
        {kind = .Pipe_Output, instance = "i", generation = "g", seq = 1, stream = 1, data = {0,255,10}},
        {kind = .Pipe_Output, instance = "i", generation = "g", seq = 0, stream = 2, data = {'d'}},
        {kind = .Pipe_Input_Done, instance = "i", generation = "g", delivery_id = "d"},
        {kind = .Pipe_Gap, instance = "i", generation = "g", first_seq = 2},
    }
    for r in replies {
        bytes := pty_host_encode_pipe_reply(r); defer delete(bytes)
        payload := pty_host_test_reframe(t, bytes)
        decoded, ok := pty_host_decode_reply(payload); testing.expect(t, ok)
        if !ok do continue
        again := pty_host_encode_pipe_reply(decoded)
        testing.expect_value(t, string(again), string(bytes)); delete(again); pty_host_reply_delete(decoded)
        for n in 0..<len(payload) {
            partial, valid := pty_host_decode_reply(payload[:n]); testing.expect(t, !valid)
            if valid do pty_host_reply_delete(partial)
        }
        extra := make([]byte, len(payload)+1); copy(extra, payload)
        partial, valid := pty_host_decode_reply(extra)
        testing.expect(t, !valid); if valid do pty_host_reply_delete(partial)
        delete(extra)
    }
    cap := pty_host_encode_pipe_reply({kind = .Capabilities, piped_spawn_v1 = true}); defer delete(cap)
    expected := [?]byte{0,0,0,2,0xC0,1}
    testing.expect_value(t, string(cap), string(expected[:]))
    invalids := [?][]byte{{0xC0,2}, {0xC1,255,255,255,255}, {0x47}}
    for payload in invalids { r, ok := pty_host_decode_reply(payload); testing.expect(t, !ok); if ok do pty_host_reply_delete(r) }
    output := pty_host_encode_pipe_reply({kind = .Pipe_Output, instance = "i", generation = "g", seq = 1, stream = 1, data = {1}}); defer delete(output)
    // Stream discriminator follows tag, two strings and seq (payload offset 19).
    output[4+19] = 3
    bad_stream, sok := pty_host_decode_reply(output[4:]); testing.expect(t, !sok); if sok do pty_host_reply_delete(bad_stream)
    oversized := make([]byte, PTY_HOST_MAX_PIPE_DATA+1); defer delete(oversized)
    testing.expect_value(t, len(pty_host_encode_pipe_request({kind = .Input, data = oversized})), 0)
    huge := make([]byte, PTY_HOST_MAX_FRAME_BYTES+1); defer delete(huge)
    huge[0] = 0xC0
    r, ok := pty_host_decode_reply(huge); testing.expect(t, !ok); if ok do pty_host_reply_delete(r)
}

@(test)
pty_host_pipe_old_host_is_unsupported_without_spawn :: proc(t: ^testing.T) {
    path := fmt.aprintf("/tmp/ham-old-pipe-%d-%d.sock", posix.getpid(), time.tick_now()); defer delete(path)
    fd, listening := local_socket.listen(path); testing.expect(t, listening)
    if !listening do return
    defer posix.close(fd); defer posix.unlink(strings.clone_to_cstring(path, context.temp_allocator))
    Ctx :: struct { listener: posix.FD, tag: byte, allocator: mem.Allocator }
    ctx := Ctx{listener = fd, allocator = runtime.heap_allocator()}
    previous := context.allocator
    context.allocator = runtime.heap_allocator()
    worker := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
        c := cast(^Ctx)data; context.allocator = c.allocator
        client := posix.accept(c.listener, nil, nil)
        if client < 0 do return
        defer posix.close(client)
        payload, ok := pty_host_read_frame(local_socket.Socket(client))
        if ok { if len(payload) > 0 do c.tag = payload[0]; delete(payload) }
        // Legacy daemon closes on unknown tag 0x40.
    })
    context.allocator = previous
    reply, ok := pty_host_spawn_pipe(path, {instance = "i", argv = {"cat"}})
    testing.expect(t, ok)
    testing.expect_value(t, reply.kind, Pty_Host_Reply_Kind.Error)
    testing.expect_value(t, reply.message, "unsupported_runtime_transport")
    pty_host_reply_delete(reply)
    thread.join(worker); thread.destroy(worker)
    testing.expect_value(t, ctx.tag, u8(0x40))
}
