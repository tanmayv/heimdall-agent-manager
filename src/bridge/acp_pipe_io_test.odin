#+build !windows
package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import vm "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import local_socket "odin_test:lib/local_socket"

ACP_Test_Exit_Daemon :: struct { listener: local_socket.Socket, output: bool, errors: int }
acp_test_exit_daemon :: proc(data: rawptr) {
    context.allocator = runtime.heap_allocator()
    d := cast(^ACP_Test_Exit_Daemon)data
    fd, ok := local_socket.accept(d.listener); if !ok { d.errors += 1; return }
    defer local_socket.close(fd)
    local_socket.set_recv_timeout(fd, 5*time.Second)
    for n in 0..<2 {
        raw, read := pty_host_read_frame(fd)
        if !read { d.errors += 1; return }
        req, valid := pty_host_decode_pipe_request(raw); delete(raw)
        if !valid { d.errors += 1; return }
        if req.kind != .Attach || req.instance != "inst_exit" || req.generation != "generation_exit" || req.seq != 5 do d.errors += 1
        pty_host_pipe_request_delete(req)
        last := u64(6) if n == 1 && d.output else u64(5)
        if !acp_test_daemon_send(fd, {kind = .Pipe_Ready, instance = "inst_exit", generation = "generation_exit", last_seq = last}) do d.errors += 1
        if n == 1 && d.output {
            if !acp_test_daemon_send(fd, {kind = .Pipe_Output, instance = "inst_exit", generation = "generation_exit", seq = 6, stream = 1, data = transmute([]byte)string("final output\n")}) do d.errors += 1
        }
    }
}

@(test)
t4_acp_pipe_exit_drains_final_watermark_after_restored_cursor :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    cases := []bool{false, true}
    for output in cases {
        path := fmt.aprintf("/tmp/ham-acp-exit-%d.sock", time.tick_now()._nsec); defer delete(path); defer os.remove(path)
        listener, listening := local_socket.listen(path, 1)
        if !testing.expect(t, listening) do return
        defer local_socket.close(listener)
        d := ACP_Test_Exit_Daemon{listener = listener, output = output}
        server := thread.create_and_start_with_data(&d, acp_test_exit_daemon)
        io, opened := acp_pipe_io_open(path, "inst_exit", "generation_exit", "epoch_exit", "", 5)
        if !testing.expect(t, opened) { local_socket.shutdown(listener, .Both); thread.join(server); thread.destroy(server); return }
        a := cast(^ACP_Pipe_IO)io.data
        local_socket.set_recv_timeout(a.fd, 5*time.Second)
        // Deliberately leave initial Ready unread: it cannot be mistaken for
        // the second attachment's final watermark when the child exits early.
        testing.expect(t, acp_pipe_io_child_exited(a))
        frame, read := io.read(io.data)
        if output {
            testing.expect(t, read && frame.kind == .Stdout && frame.seq == 6 && frame.bytes == "final output\n")
            delete(frame.bytes); frame, read = io.read(io.data)
        }
        testing.expect(t, read && frame.kind == .Fault && frame.bytes == "acp_adapter_exited")
        delete(frame.bytes)
        io.close(io.data); io.destroy(io.data)
        thread.join(server); thread.destroy(server)
        testing.expect_value(t, d.errors, 0)
    }
}

ACP_Test_Daemon :: struct {
    listener: local_socket.Socket,
    state_path: string,
    inputs: int,
    acks: int, // atomic
    errors: int,
    eof: bool,
    bytes: int,
}

acp_test_daemon_send :: proc(fd: local_socket.Socket, reply: Pty_Host_Reply) -> bool {
    frame := pty_host_encode_pipe_reply(reply); defer delete(frame)
    return pty_host_send_all(fd, frame)
}
acp_test_daemon_run :: proc(data: rawptr) {
    context.allocator = runtime.heap_allocator()
    arena: vm.Arena; _ = vm.arena_init_growing(&arena); defer vm.arena_destroy(&arena)
    context.temp_allocator = vm.arena_allocator(&arena)
    d := cast(^ACP_Test_Daemon)data
    fd, ok := local_socket.accept(d.listener)
    if !ok { d.errors += 1; return }
    defer local_socket.close(fd)
    local_socket.set_recv_timeout(fd, 5*time.Second)
    first, got := pty_host_read_frame(fd)
    if !got { d.errors += 1; return }
    attach, valid := pty_host_decode_pipe_request(first); delete(first)
    if !valid || attach.kind != .Attach || attach.instance != "inst_test_acp" || attach.generation != "generation_test" || attach.seq != 0 {
        if valid do pty_host_pipe_request_delete(attach)
        d.errors += 1; return
    }
    pty_host_pipe_request_delete(attach)
    acp_test_daemon_send(fd, {kind = .Pipe_Ready, instance = "inst_test_acp", generation = "generation_test", first_seq = 1})
    line := make([dynamic]byte); defer delete(line)
    sent_response := false
    for {
        raw, read_ok := pty_host_read_frame(fd)
        if !read_ok { d.eof = true; return }
        req, request_ok := pty_host_decode_pipe_request(raw); delete(raw)
        if !request_ok { d.errors += 1; return }
        if req.instance != "inst_test_acp" || req.generation != "generation_test" do d.errors += 1
        #partial switch req.kind {
        case .Input:
            d.inputs += 1; d.bytes += len(req.data)
            // Verify the actual file (not just the checkpoint callback) exists
            // before bytes reach the daemon.
            s, state_ok := acp_state_read(d.state_path)
            found := false
            if state_ok {
                for w in s.pending_writes { if w.delivery_id == req.delivery_id && w.bytes == string(req.data) do found = true }
                acp_state_delete(&s)
            }
            if !state_ok || !found do d.errors += 1
            append(&line, ..req.data)
            acp_test_daemon_send(fd, {kind = .Pipe_Input_Done, instance = req.instance, generation = req.generation, delivery_id = req.delivery_id})
            if !sent_response && len(line) > 0 && line[len(line)-1] == '\n' {
                value, err := json.parse(string(line[:]), parse_integers = true)
                if err != nil { d.errors += 1 } else {
                    obj, object_ok := value.(json.Object)
                    if !object_ok { d.errors += 1 } else {
                        id, _ := obj["id"].(string)
                        response := acp_test_response(ACP_RPC_ID(id), `{"text":"🌍"}`)
                        split := strings.index(response, "🌍")+1
                        acp_test_daemon_send(fd, {kind = .Pipe_Output, instance = req.instance, generation = req.generation, seq = 1, stream = 1, data = transmute([]byte)response[:split]})
                        acp_test_daemon_send(fd, {kind = .Pipe_Output, instance = req.instance, generation = req.generation, seq = 0, stream = 2, data = transmute([]byte)string("diagnostic only")})
                        acp_test_daemon_send(fd, {kind = .Pipe_Output, instance = req.instance, generation = req.generation, seq = 2, stream = 1, data = transmute([]byte)response[split:]})
                        sent_response = true
                    }
                    json.destroy_value(value)
                }
            }
        case .Ack:
            s, state_ok := acp_state_read(d.state_path)
            if !state_ok || s.last_stdout_seq < req.seq do d.errors += 1
            if state_ok do acp_state_delete(&s)
            sync.atomic_add(&d.acks, 1)
        case: d.errors += 1 // Close/Signal is never a legal RPC detach operation
        }
        pty_host_pipe_request_delete(req)
    }
}

@(test)
acp_pipe_io_fake_daemon_chunking_receipts_ack_and_detach :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    nonce := time.to_unix_nanoseconds(time.now())
    socket_path := fmt.aprintf("/tmp/ham-acp-%d.sock", nonce); defer delete(socket_path)
    listener, ok := local_socket.listen(socket_path, 1)
    if !testing.expect(t, ok) do return
    defer local_socket.close(listener)
    defer os.remove(socket_path)
    root := fmt.aprintf("%s/.cache/heimdall-tests/acp-pipe-%d", os.get_env("HOME", context.temp_allocator), nonce)
    defer delete(root); defer os.remove_all(root)
    state_path, _ := acp_state_path(root, "inst_test_acp", "epoch_test"); defer delete(state_path)
    daemon := ACP_Test_Daemon{listener = listener, state_path = state_path}
    server := thread.create_and_start_with_data(&daemon, acp_test_daemon_run)
    io, opened := acp_pipe_io_open(socket_path, "inst_test_acp", "generation_test", "epoch_test", state_path, 0)
    if !testing.expect(t, opened) { local_socket.shutdown(listener, .Both); thread.join(server); thread.destroy(server); return }
    f: ACP_Test; defer acp_test_delete(&f)
    c, rpc_ok := acp_rpc_open(io, {data = &f, checkpoint = acp_test_checkpoint, fault = acp_test_fault})
    if !testing.expect(t, rpc_ok) { io.close(io.data); io.destroy(io.data); thread.join(server); thread.destroy(server); return }
    f.client = c
    text := make([]byte, 140000, context.temp_allocator)
    for &ch in text do ch = 'a'
    params := strings.concatenate({`{"text":"`, string(text), `"}`}, context.temp_allocator)
    id, requested := acp_rpc_request(c, "session/prompt", params, 0, acp_test_completion(&f))
    testing.expect(t, requested); delete(string(id))
    acp_test_wait(t, &f, .Results, 1)
    start := time.tick_now()
    for sync.atomic_load(&daemon.acks) < 2 && time.tick_since(start) < 5*time.Second do time.sleep(time.Millisecond)
    acp_rpc_close(c)
    thread.join(server); thread.destroy(server)
    testing.expect_value(t, daemon.inputs, 3)
    testing.expect_value(t, daemon.errors, 0)
    testing.expect_value(t, sync.atomic_load(&daemon.acks), 2)
    testing.expect(t, daemon.eof)
    testing.expect(t, daemon.bytes > 140000)
    testing.expect_value(t, f.faults, 0)
    testing.expect_value(t, len(f.results), 1)
    if len(f.results) == 1 {
        testing.expect(t, f.results[0].ok)
        value, err := json.parse(f.results[0].result_json, allocator = context.temp_allocator)
        testing.expect(t, err == nil)
        if obj, object_ok := value.(json.Object); object_ok {
            text, _ := obj["text"].(string); testing.expect_value(t, text, "🌍")
        } else { testing.expect(t, false) }
    }
    s, loaded := acp_state_read(state_path); testing.expect(t, loaded)
    if loaded {
        testing.expect_value(t, len(s.pending_writes), 0)
        testing.expect_value(t, len(s.completed_delivery_ids), 3)
        testing.expect_value(t, s.last_stdout_seq, u64(2)); acp_state_delete(&s)
    }
}

ACP_Test_Spawn_Daemon :: struct { listener: local_socket.Socket, wrong_pid: bool, errors: int }
acp_test_spawn_daemon :: proc(data: rawptr) {
    context.allocator = runtime.heap_allocator()
    d := cast(^ACP_Test_Spawn_Daemon)data
    for n in 0..<3 {
        fd, accepted := local_socket.accept(d.listener); if !accepted { d.errors += 1; return }
        local_socket.set_recv_timeout(fd, 5*time.Second)
        raw, read := pty_host_read_frame(fd)
        if !read { local_socket.close(fd); d.errors += 1; return }
        req, valid := pty_host_decode_pipe_request(raw); delete(raw)
        if !valid { local_socket.close(fd); d.errors += 1; return }
        if n == 0 {
            if req.kind != .Capabilities do d.errors += 1
            acp_test_daemon_send(fd, {kind = .Capabilities, piped_spawn_v1 = true})
        } else if n == 1 {
            if req.kind != .Spawn || req.spawn.instance != "inst_spawn" do d.errors += 1
            // Compatible Spawned ACK deliberately has no generation field.
            bytes := make([dynamic]byte); append(&bytes, PTY_HOST_T_SPAWNED)
            pty_host_put_str(&bytes, "inst_spawn"); pty_host_put_i32(&bytes, 42)
            frame := pty_host_frame(bytes[:]); pty_host_send_all(fd, frame)
            delete(frame); delete(bytes)
        } else {
            if req.kind != .List do d.errors += 1
            acp_test_daemon_send(fd, {kind = .Pipe_List, pipes = {
                {instance = "inst_other", generation = "unrelated", pid = 42},
                {instance = "inst_spawn", generation = "generation_spawn", pid = 99 if d.wrong_pid else 42, alive = true},
            }})
        }
        pty_host_pipe_request_delete(req)
        local_socket.close(fd)
    }
}

@(test)
t10_acp_spawn_resolves_generation_from_matching_instance_and_pid :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    for wrong_pid in ([]bool{false, true}) {
        path := fmt.aprintf("/tmp/ham-acp-spawn-%d.sock", time.tick_now()._nsec); defer delete(path); defer os.remove(path)
        listener, listening := local_socket.listen(path, 1); if !testing.expect(t, listening) do return
        defer local_socket.close(listener)
        d := ACP_Test_Spawn_Daemon{listener = listener, wrong_pid = wrong_pid}
        worker := thread.create_and_start_with_data(&d, acp_test_spawn_daemon)
        reply, received := pty_host_spawn_pipe(path, {instance = "inst_spawn", argv = {"unused"}})
        testing.expect(t, received && reply.kind == .Spawned && reply.pid == 42)
        testing.expect_value(t, reply.generation, "" if wrong_pid else "generation_spawn")
        pty_host_reply_delete(reply)
        thread.join(worker); thread.destroy(worker)
        testing.expect_value(t, d.errors, 0)
    }
}
