package main

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import vm "core:mem/virtual"
import "core:strings"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

ACP_RPC_MAX_LINE :: 4*1024*1024
ACP_RPC_QUEUE_BYTES :: 1024*1024
// Active requests and replay history have independent count and byte budgets,
// covering whole-file replies as well as small permission results.
// An evicted completed ID is no longer eligible for cached duplicate replay.
ACP_RPC_MAX_PENDING_INBOUND :: 128
ACP_RPC_PENDING_INBOUND_BYTES :: 8*1024*1024
ACP_RPC_MAX_PENDING_OUTBOUND :: 128
ACP_RPC_PENDING_OUTBOUND_BYTES :: 8*1024*1024
ACP_RPC_RECENT_INBOUND_COUNT :: 64
ACP_RPC_RECENT_INBOUND_BYTES :: 8*1024*1024
ACP_RPC_COMPLETED_DELIVERY_COUNT :: 256
ACP_RPC_UNKNOWN_ID_COUNT :: 256
ACP_RPC_UNKNOWN_ID_BYTES :: 64*1024
ACP_RPC_UNKNOWN_ID_OVERFLOW :: `"<additional unknown response IDs suppressed>"`
ACP_RPC_ID :: distinct string
ACP_RPC_Role :: enum { Other, Initialize, New, Load, Config, Prompt, Steering }
ACP_RPC_Error :: struct { code: int, message: string, data_json: string }
ACP_RPC_Result :: struct { id: ACP_RPC_ID, result_json: string, error: ACP_RPC_Error, ok: bool, method: string }
ACP_RPC_Completion :: struct {
    callback: proc(data: rawptr, result: ACP_RPC_Result),
    data: rawptr,
}
ACP_RPC_Callbacks :: struct {
    data: rawptr,
    notification: proc(data: rawptr, method, params: string),
    // Return true if the method is supported. Reply may be made reentrantly.
    inbound_request: proc(data: rawptr, id_json, method, params: string) -> bool,
    fault: proc(data: rawptr, reason: string),
    // Dispatcher-owned timeout handling for adapter-specific inbound outcomes.
    inbound_timeout: proc(data: rawptr, id_json: string),
    // Receives a borrowed state on the dispatcher; may replace runtime fields
    // with heap-owned copies before the atomic write. Do not change RPC fields.
    // False prevents sends and PipeAck.
    checkpoint: proc(data: rawptr, state: ^ACP_State) -> bool,
    // After the journal write: commits state kept outside the journal (the
    // runtime's inbox file). False fails the checkpoint.
    committed: proc(data: rawptr) -> bool,
    restore_completion: proc(data: rawptr, role: ACP_RPC_Role, id: ACP_RPC_ID) -> ACP_RPC_Completion,
    // At most UNKNOWN_ID_COUNT distinct IDs/UNKNOWN_ID_BYTES of keys, then one
    // UNKNOWN_ID_OVERFLOW marker.
    unknown_response: proc(data: rawptr, id_json: string),
    // Frame admission may pause on a locked vault or bounded durable outbox.
    // Control commands remain dispatchable while the daemon queue backs up.
    can_process: proc(data: rawptr) -> bool,
    tick: proc(data: rawptr),
}
ACP_RPC_Frame_Kind :: enum { Stdout, Receipt, Diagnostic, Fault }
ACP_RPC_Frame :: struct { kind: ACP_RPC_Frame_Kind, bytes: string, seq: u64 }
ACP_RPC_IO :: struct {
    data: rawptr,
    launch_epoch: string,
    instance: string,
    state_path: string,
    // read returns a heap-owned frame. write sends bytes only; a durable stdin
    // receipt arrives via read as Receipt. close must wake blocked I/O without
    // closing its fd; destroy runs only after all three workers have joined.
    read: proc(data: rawptr) -> (ACP_RPC_Frame, bool),
    write: proc(data: rawptr, bytes, delivery_id: string) -> bool,
    ack: proc(data: rawptr, seq: u64) -> bool,
    close: proc(data: rawptr),
    destroy: proc(data: rawptr),
    now_ms: proc(data: rawptr) -> i64,
    // For embedders without a read worker. Set by open; copies input before
    // returning and applies bounded backpressure. Never call after close.
    feed: proc(c: ^ACP_RPC_Client, bytes: string, seq: u64) -> bool,
}

ACP_RPC_Command_Kind :: enum { Request, Notify, Reply, Reply_Error, Restore, Frame, Close, Runtime }
ACP_RPC_Command :: struct {
    runtime_work: proc(data: rawptr, client: ^ACP_RPC_Client, argument: string) -> bool,
    runtime_data: rawptr,
    kind: ACP_RPC_Command_Kind,
    a, b: string,
    err: ACP_RPC_Error,
    timeout_ms: i64,
    completion: ACP_RPC_Completion,
    frame: ACP_RPC_Frame,
    id: ACP_RPC_ID,
    ok: bool,
    done: bool,
    mu: sync.Mutex,
    cond: sync.Cond,
}
ACP_RPC_Work :: struct { bytes, delivery_id: string, ack: u64 }
ACP_RPC_Client :: struct {
    io: ACP_RPC_IO,
    callbacks: ACP_RPC_Callbacks,
    policy: ACP_RPC_Policy,
    state: ACP_State,
    // Only dispatcher accesses these maps or state. Queue locks never cover
    // callbacks or JSON/persistence/I/O work.
    outbound: map[string]int,
    inbound: map[string]int,
    recent_inbound: map[string]int,
    recent_inbound_bytes: int,
    completions: map[string]ACP_RPC_Completion,
    unknown_ids: map[string]bool,
    unknown_ids_overflow: bool,
    unknown_id_bytes: int,
    partial: [dynamic]byte,
    failed: bool,
    restored: bool,
    in_frame: bool,
    reader_enabled: bool, // atomic; restore must precede output dispatch
    closing: bool, // atomic, gates incoming producers
    dispatcher_id: int, // atomic
    mu: sync.Mutex,
    cond: sync.Cond,
    queue: [dynamic]^ACP_RPC_Command,
    queued_bytes: int,
    writer_mu: sync.Mutex,
    writer_cond: sync.Cond,
    writes: [dynamic]ACP_RPC_Work,
    writer_stop: bool,
    reader, writer, dispatcher: ^thread.Thread,
}

acp_rpc_open :: proc(io: ACP_RPC_IO, callbacks: ACP_RPC_Callbacks, policy: ACP_RPC_Policy = ACP_RPC_POLICY_ACP) -> (^ACP_RPC_Client, bool) {
    context.allocator = runtime.heap_allocator()
    if io.write == nil || io.close == nil || !acp_state_component_ok(io.launch_epoch) ||
       !acp_state_component_ok(io.instance) || (io.state_path == "" && callbacks.checkpoint == nil) { return nil, false }
    if policy.role == nil || policy.timeout == nil || policy.inbound_timeout == nil || policy.cancel_timeout == nil do return nil, false
    c := new(ACP_RPC_Client)
    c.policy = policy
    c.io = io
    c.io.launch_epoch = strings.clone(io.launch_epoch)
    c.io.instance = strings.clone(io.instance)
    c.io.state_path = strings.clone(io.state_path)
    c.io.feed = acp_rpc_feed
    c.callbacks = callbacks
    c.state = {schema_version = 1, instance = strings.clone(io.instance), launch_epoch = strings.clone(io.launch_epoch),
               effective_transport = strings.clone("acp"), next_rpc_id = 1, next_delivery_id = 1}
    c.outbound = make(map[string]int)
    c.inbound = make(map[string]int)
    c.recent_inbound = make(map[string]int)
    c.completions = make(map[string]ACP_RPC_Completion)
    c.unknown_ids = make(map[string]bool)
    c.writer = thread.create_and_start_with_data(c, acp_rpc_writer)
    c.dispatcher = thread.create_and_start_with_data(c, acp_rpc_dispatcher)
    if io.read != nil do c.reader = thread.create_and_start_with_data(c, acp_rpc_reader)
    return c, true
}

acp_rpc_request :: proc(c: ^ACP_RPC_Client, method, params_json: string, timeout_ms: i64, completion: ACP_RPC_Completion) -> (ACP_RPC_ID, bool) {
    cmd := ACP_RPC_Command{kind = .Request, a = method, b = params_json, timeout_ms = timeout_ms, completion = completion}
    acp_rpc_call(c, &cmd)
    return cmd.id, cmd.ok
}
acp_rpc_notify :: proc(c: ^ACP_RPC_Client, method, params_json: string) -> bool {
    cmd := ACP_RPC_Command{kind = .Notify, a = method, b = params_json}; acp_rpc_call(c, &cmd); return cmd.ok
}
acp_rpc_reply :: proc(c: ^ACP_RPC_Client, inbound_id_json, result_json: string) -> bool {
    cmd := ACP_RPC_Command{kind = .Reply, a = inbound_id_json, b = result_json}; acp_rpc_call(c, &cmd); return cmd.ok
}
acp_rpc_reply_error :: proc(c: ^ACP_RPC_Client, inbound_id_json: string, err: ACP_RPC_Error) -> bool {
    cmd := ACP_RPC_Command{kind = .Reply_Error, a = inbound_id_json, err = err}; acp_rpc_call(c, &cmd); return cmd.ok
}
acp_rpc_restore :: proc(c: ^ACP_RPC_Client, checkpoint_json: string) -> bool {
    cmd := ACP_RPC_Command{kind = .Restore, a = checkpoint_json}; acp_rpc_call(c, &cmd); return cmd.ok
}

// Callers must quiesce API producers before close and call it from the owner,
// not a callback (a callback cannot join its own dispatcher). I/O close only
// detaches this connection. No child lifecycle command exists in this module.
acp_rpc_close :: proc(c: ^ACP_RPC_Client) {
    if c == nil do return
    assert(sync.atomic_load(&c.dispatcher_id) != sync.current_thread_id())
    cmd := ACP_RPC_Command{kind = .Close}
    acp_rpc_call(c, &cmd)
    c.io.close(c.io.data)
    if c.reader != nil { thread.join(c.reader); thread.destroy(c.reader) }
    sync.mutex_lock(&c.writer_mu)
    c.writer_stop = true; sync.cond_broadcast(&c.writer_cond)
    sync.mutex_unlock(&c.writer_mu)
    thread.join(c.writer); thread.destroy(c.writer)
    thread.join(c.dispatcher); thread.destroy(c.dispatcher)
    context.allocator = runtime.heap_allocator()
    if c.io.destroy != nil do c.io.destroy(c.io.data)
    for cmd in c.queue { delete(cmd.frame.bytes); free(cmd) }
    for w in c.writes { delete(w.bytes); delete(w.delivery_id) }
    for key in c.unknown_ids do delete(key)
    for key in c.inbound do delete(key)
    for key in c.recent_inbound do delete(key)
    delete(c.queue); delete(c.writes); delete(c.partial)
    delete(c.outbound); delete(c.inbound); delete(c.completions); delete(c.unknown_ids)
    delete(c.recent_inbound)
    acp_state_delete(&c.state)
    delete(c.io.launch_epoch); delete(c.io.instance); delete(c.io.state_path)
    free(c)
}

acp_rpc_call :: proc(c: ^ACP_RPC_Client, cmd: ^ACP_RPC_Command) {
    context.allocator = runtime.heap_allocator()
    if c == nil || sync.atomic_load(&c.closing) do return
    if sync.atomic_load(&c.dispatcher_id) == sync.current_thread_id() {
        acp_rpc_execute(c, cmd); return
    }
    sync.mutex_lock(&c.mu)
    if sync.atomic_load(&c.closing) { sync.mutex_unlock(&c.mu); return }
    append(&c.queue, cmd); sync.cond_signal(&c.cond)
    sync.mutex_unlock(&c.mu)
    sync.mutex_lock(&cmd.mu)
    for !cmd.done do sync.cond_wait(&cmd.cond, &cmd.mu)
    sync.mutex_unlock(&cmd.mu)
}

acp_rpc_feed :: proc(c: ^ACP_RPC_Client, bytes: string, seq: u64) -> bool {
    return acp_rpc_enqueue_frame(c, {kind = .Stdout, bytes = bytes, seq = seq})
}
acp_rpc_enqueue_frame :: proc(c: ^ACP_RPC_Client, frame: ACP_RPC_Frame) -> bool {
    context.allocator = runtime.heap_allocator()
    if len(frame.bytes) > ACP_RPC_MAX_LINE do return false
    sync.mutex_lock(&c.mu)
    defer sync.mutex_unlock(&c.mu)
    for !sync.atomic_load(&c.closing) && c.queued_bytes > 0 && c.queued_bytes + len(frame.bytes) > ACP_RPC_QUEUE_BYTES do sync.cond_wait(&c.cond, &c.mu)
    if sync.atomic_load(&c.closing) do return false
    cmd := new(ACP_RPC_Command)
    cmd.kind = .Frame; cmd.frame = frame; cmd.frame.bytes = strings.clone(frame.bytes)
    append(&c.queue, cmd); c.queued_bytes += len(frame.bytes)
    sync.cond_signal(&c.cond)
    return true
}

acp_rpc_reader :: proc(data: rawptr) {
    context.allocator = runtime.heap_allocator()
    c := cast(^ACP_RPC_Client)data
    arena: vm.Arena; _ = vm.arena_init_growing(&arena); defer vm.arena_destroy(&arena)
    context.temp_allocator = vm.arena_allocator(&arena)
    sync.mutex_lock(&c.mu)
    for !sync.atomic_load(&c.closing) && !sync.atomic_load(&c.reader_enabled) do sync.cond_wait(&c.cond, &c.mu)
    sync.mutex_unlock(&c.mu)
    for !sync.atomic_load(&c.closing) {
        frame, ok := c.io.read(c.io.data)
        if !ok {
            acp_rpc_enqueue_frame(c, {kind = .Fault, bytes = "acp_pipe_lost"}); break
        }
        accepted := acp_rpc_enqueue_frame(c, frame)
        delete(frame.bytes)
        if !accepted do break
        mem.free_all(context.temp_allocator)
    }
}
acp_rpc_writer :: proc(data: rawptr) {
    context.allocator = runtime.heap_allocator()
    c := cast(^ACP_RPC_Client)data
    arena: vm.Arena; _ = vm.arena_init_growing(&arena); defer vm.arena_destroy(&arena)
    context.temp_allocator = vm.arena_allocator(&arena)
    for {
        sync.mutex_lock(&c.writer_mu)
        for len(c.writes) == 0 && !c.writer_stop do sync.cond_wait(&c.writer_cond, &c.writer_mu)
        if c.writer_stop { sync.mutex_unlock(&c.writer_mu); break }
        w := c.writes[0]; ordered_remove(&c.writes, 0)
        sync.mutex_unlock(&c.writer_mu)
        ok := true
        if w.ack != 0 {
            if c.io.ack != nil do ok = c.io.ack(c.io.data, w.ack)
        } else { ok = c.io.write(c.io.data, w.bytes, w.delivery_id) }
        delete(w.bytes); delete(w.delivery_id)
        if !ok { acp_rpc_enqueue_frame(c, {kind = .Fault, bytes = "acp_pipe_write_failed"}); break }
        mem.free_all(context.temp_allocator)
    }
}

acp_rpc_queue_work :: proc(c: ^ACP_RPC_Client, bytes, delivery_id: string, ack: u64 = 0) {
    sync.mutex_lock(&c.writer_mu)
    append(&c.writes, ACP_RPC_Work{strings.clone(bytes), strings.clone(delivery_id), ack})
    sync.cond_signal(&c.writer_cond)
    sync.mutex_unlock(&c.writer_mu)
}

acp_rpc_dispatcher :: proc(data: rawptr) {
    context.allocator = runtime.heap_allocator()
    c := cast(^ACP_RPC_Client)data
    sync.atomic_store(&c.dispatcher_id, sync.current_thread_id())
    arena: vm.Arena; _ = vm.arena_init_growing(&arena); defer vm.arena_destroy(&arena)
    context.temp_allocator = vm.arena_allocator(&arena)
    paused_at:i64
    for {
        sync.mutex_lock(&c.mu)
        if len(c.queue)==0 || paused_at!=0 do sync.cond_wait_with_timeout(&c.cond,&c.mu,10*time.Millisecond)
        sync.mutex_unlock(&c.mu)
        frames_ready := c.callbacks.can_process == nil || c.callbacks.can_process(c.callbacks.data)
        if !frames_ready && paused_at==0 do paused_at=acp_rpc_now(c)
        if frames_ready && paused_at!=0 {
            paused:=max(i64(0),acp_rpc_now(c)-paused_at)
            for &pending in c.state.pending_outbound do if pending.deadline_unix_ms!=0 do pending.deadline_unix_ms+=paused
            for &pending in c.state.pending_inbound do if pending.deadline_unix_ms!=0 do pending.deadline_unix_ms+=paused
            paused_at=0
        }
        sync.mutex_lock(&c.mu)
        cmd: ^ACP_RPC_Command
        index := -1
        for candidate,i in c.queue {
            if frames_ready || candidate.kind != .Frame { index=i;break }
        }
        if index >= 0 {
            cmd = c.queue[index]; ordered_remove(&c.queue, index)
            if cmd.kind == .Frame do c.queued_bytes -= len(cmd.frame.bytes)
        }
        sync.cond_broadcast(&c.cond)
        sync.mutex_unlock(&c.mu)
        if cmd != nil {
            acp_rpc_execute(c, cmd)
            if cmd.kind == .Frame { delete(cmd.frame.bytes); free(cmd) } else {
                closing := cmd.kind == .Close
                sync.mutex_lock(&cmd.mu); cmd.done = true; sync.cond_signal(&cmd.cond); sync.mutex_unlock(&cmd.mu)
                if closing do break
            }
        }
        if !c.failed && frames_ready do acp_rpc_expire(c)
        if !c.failed && frames_ready && c.callbacks.tick != nil do c.callbacks.tick(c.callbacks.data)
        mem.free_all(context.temp_allocator)
    }
}

acp_rpc_now :: proc(c: ^ACP_RPC_Client) -> i64 {
    if c.io.now_ms != nil do return c.io.now_ms(c.io.data)
    return time.to_unix_nanoseconds(time.now())/1_000_000
}
acp_rpc_deadline :: proc(c: ^ACP_RPC_Client, method: string, timeout_ms: i64) -> i64 {
    limit := c.policy.timeout(method)
    if limit == 0 do return 0
    if timeout_ms > 0 do limit = min(limit, timeout_ms)
    return acp_rpc_now(c) + limit
}
acp_rpc_checkpoint :: proc(c: ^ACP_RPC_Client) -> bool {
    encoded := base64.encode(c.partial[:], allocator = context.allocator)
    delete(c.state.partial_line_base64); c.state.partial_line_base64 = string(encoded)
    if c.callbacks.checkpoint != nil && !c.callbacks.checkpoint(c.callbacks.data, &c.state) do return false
    if c.io.state_path != "" && !acp_state_write(c.io.state_path, &c.state) do return false
    return c.callbacks.committed == nil || c.callbacks.committed(c.callbacks.data)
}

// Serialized outgoing envelope, with JSON raw values validated before use.
acp_rpc_json :: proc(raw: string) -> bool {
    _, ok := acp_rpc_parse(raw); return ok
}
// core:encoding/json defaults to JSON5 and parses a single leading value.
// Enforce the wire's JSON grammar, EOF and bounded nesting explicitly. The
// tokenizer pass also rejects trailing commas accepted by the core parser.
acp_rpc_parse :: proc(raw: string) -> (json.Value, bool) {
    if !utf8.valid_string(raw) do return {}, false
    context.allocator = context.temp_allocator
    tok := json.make_tokenizer(raw, .JSON, true)
    previous: json.Token_Kind
    depth := 0
    for {
        token, err := json.get_token(&tok)
        if token.kind == .EOF do break
        if err != nil do return {}, false
        if token.kind == .Open_Brace || token.kind == .Open_Bracket {
            depth += 1; if depth > 128 do return {}, false
        }
        if token.kind == .Close_Brace || token.kind == .Close_Bracket {
            if previous == .Comma do return {}, false
            depth -= 1
        }
        previous = token.kind
    }
    p := json.make_parser(raw, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
    value, err := json.parse_value(&p)
    return value, err == nil && p.curr_token.kind == .EOF
}
acp_rpc_internal_id :: proc(epoch: string, counter: u64) -> string {
    return fmt.tprintf("ham:%s:%d", epoch, counter)
}
// The wire token for an outgoing request: the quoted internal ID, or the bare
// counter for integer-ID codecs.
acp_rpc_wire_id :: proc(codec: ACP_RPC_Codec, internal_id: string, counter: u64) -> string {
    return fmt.tprintf("%d", counter) if codec.integer_ids else acp_rpc_quote(internal_id)
}
// Maps a response ID to the internal ID it correlates with. String codecs
// preserve the string/numeric distinction (a numeric echo never matches);
// integer codecs correlate only positive integers with that counter's ID.
acp_rpc_response_key :: proc(codec: ACP_RPC_Codec, epoch: string, id: json.Value) -> (string, bool) {
    if codec.integer_ids {
        counter, integer_id := id.(json.Integer)
        if !integer_id || counter <= 0 do return "", false
        return acp_rpc_internal_id(epoch, u64(counter)), true
    }
    key, string_id := id.(string)
    return key, string_id
}
acp_rpc_quote :: proc(s: string) -> string {
    b, _ := json.marshal(s, allocator = context.temp_allocator); return string(b)
}
acp_rpc_envelope :: proc(id_json, method, params, field, value: string, codec: ACP_RPC_Codec = ACP_RPC_POLICY_ACP.codec) -> string {
    b: strings.Builder; strings.builder_init(&b, context.temp_allocator)
    strings.write_string(&b, "{")
    if codec.jsonrpc_header do strings.write_string(&b, `"jsonrpc":"2.0",`)
    if id_json != "" { strings.write_string(&b, `"id":`); strings.write_string(&b, id_json); strings.write_string(&b, ",") }
    if method != "" {
        strings.write_string(&b, `"method":`); strings.write_string(&b, acp_rpc_quote(method))
        strings.write_string(&b, `,"params":`); strings.write_string(&b, params)
    } else {
        strings.write_string(&b, `"`); strings.write_string(&b, field); strings.write_string(&b, `":`); strings.write_string(&b, value)
    }
    strings.write_string(&b, "}\n"); return strings.to_string(b)
}

// Reserve all chunks in the same checkpoint as their semantic pending call.
// Restoring an unreceipted write always reuses the exact delivery id and bytes.
acp_rpc_stage :: proc(c: ^ACP_RPC_Client, line: string) -> (string, bool) {
    if len(line) > ACP_RPC_MAX_LINE+1 || len(line) == 0 do return "", false
    queued := 0
    for w in c.state.pending_writes do queued += len(w.bytes)
    if queued + len(line) > ACP_RPC_MAX_LINE do return "", false
    first := ""
    for offset := 0; offset < len(line); {
        end := min(offset+64*1024, len(line))
        id := strings.clone(fmt.tprintf("ham:%s:write:%d", c.state.launch_epoch, c.state.next_delivery_id))
        c.state.next_delivery_id += 1
        if first == "" do first = id
        append(&c.state.pending_writes, ACP_RPC_Write{id, strings.clone(line[offset:end])})
        offset = end
    }
    return first, true
}
acp_rpc_send_staged :: proc(c: ^ACP_RPC_Client, from: int) -> bool {
    if c.in_frame do return true
    if !acp_rpc_checkpoint(c) { acp_rpc_fail(c, "acp_state_write_failed"); return false }
    for w in c.state.pending_writes[from:] do acp_rpc_queue_work(c, w.bytes, w.delivery_id)
    acp_rpc_enable_reader(c)
    return true
}

acp_rpc_execute :: proc(c: ^ACP_RPC_Client, cmd: ^ACP_RPC_Command) {
    // Driver mutations share the RPC dispatcher and checkpoint transaction.
    // The owner may use this even after a fault to record stop intent safely.
    if cmd.kind == .Runtime {
        if cmd.runtime_work != nil do cmd.ok = cmd.runtime_work(cmd.runtime_data, c, cmd.a)
        return
    }
    if cmd.kind == .Close {
        sync.atomic_store(&c.closing, true)
        sync.mutex_lock(&c.mu); sync.cond_broadcast(&c.cond); sync.mutex_unlock(&c.mu)
        acp_rpc_reject_all(c, "acp_closed")
        cmd.ok = true; return
    }
    if c.failed do return
    #partial switch cmd.kind {
    case .Request, .Notify:
        if cmd.a == "" || !utf8.valid_string(cmd.a) || !acp_rpc_json(cmd.b) do return
        if !acp_rpc_params_ok(cmd.b) do return
        id: string
        if cmd.kind == .Request {
            pending_bytes := len(cmd.a)+len(cmd.b)+2*len(c.state.launch_epoch)+128
            for p in c.state.pending_outbound do pending_bytes += len(p.id)+len(p.method)+len(p.params_json)+len(p.delivery_id)
            if len(c.state.pending_outbound) >= ACP_RPC_MAX_PENDING_OUTBOUND || pending_bytes > ACP_RPC_PENDING_OUTBOUND_BYTES do return
            // Integer wire IDs are signed. Internal IDs stay epoch-scoped so
            // journals/completions retain the same identity on every codec.
            if c.policy.codec.integer_ids && c.state.next_rpc_id > u64(max(i64)) do return
            id = strings.clone(acp_rpc_internal_id(c.state.launch_epoch, c.state.next_rpc_id))
            c.state.next_rpc_id += 1
        }
        wire_id := acp_rpc_wire_id(c.policy.codec, id, c.state.next_rpc_id-1) if id != "" else ""
        line := acp_rpc_envelope(wire_id, cmd.a, cmd.b, "", "", c.policy.codec)
        start := len(c.state.pending_writes)
        delivery, ok := acp_rpc_stage(c, line)
        if !ok { delete(id); return }
        if cmd.kind == .Request {
            role := c.policy.role(cmd.a)
            c.outbound[id] = len(c.state.pending_outbound)
            append(&c.state.pending_outbound, ACP_RPC_Pending{id, strings.clone(cmd.a), strings.clone(cmd.b), acp_rpc_deadline(c, cmd.a, cmd.timeout_ms), strings.clone(delivery), role})
            c.completions[id] = cmd.completion
        } else if cancel_timeout := c.policy.cancel_timeout(cmd.a); cancel_timeout > 0 {
            for &p in c.state.pending_outbound { if p.role == .Prompt do p.deadline_unix_ms = acp_rpc_now(c)+cancel_timeout }
        }
        cmd.ok = acp_rpc_send_staged(c, start)
        if cmd.ok && id != "" do cmd.id = ACP_RPC_ID(strings.clone(id))
    case .Reply, .Reply_Error:
        key, valid := acp_rpc_id(cmd.a)
        if !valid do return
        idx, found := c.inbound[key]; if !found do return
        p := &c.state.pending_inbound[idx]
        if p.response_json != "" do return
        line: string
        if cmd.kind == .Reply {
            if !acp_rpc_json(cmd.b) do return
            line = acp_rpc_envelope(p.id_json, "", "", "result", cmd.b, c.policy.codec)
        } else {
            if !utf8.valid_string(cmd.err.message) || cmd.err.data_json != "" && !acp_rpc_json(cmd.err.data_json) do return
            error_json := strings.concatenate({`{"code":`, fmt.tprintf("%d", cmd.err.code), `,"message":`, acp_rpc_quote(cmd.err.message),
                `,"data":`, cmd.err.data_json if cmd.err.data_json != "" else "null", "}"}, context.temp_allocator)
            line = acp_rpc_envelope(p.id_json, "", "", "error", error_json, c.policy.codec)
        }
        pending_bytes := len(line)+len(c.state.launch_epoch)+64
        for pending in c.state.pending_inbound do pending_bytes += acp_rpc_inbound_bytes(pending)
        if pending_bytes > ACP_RPC_PENDING_INBOUND_BYTES do return
        start := len(c.state.pending_writes)
        _, ok := acp_rpc_stage(c, line); if !ok do return
        p.response_json = strings.clone(line)
        p.response_delivery_id = strings.clone(c.state.pending_writes[len(c.state.pending_writes)-1].delivery_id)
        cmd.ok = acp_rpc_send_staged(c, start)
    case .Restore:
        cmd.ok = acp_rpc_restore_state(c, cmd.a)
    case .Frame:
        #partial switch cmd.frame.kind {
        case .Fault:
            reason := "acp_pipe_lost"
            if cmd.frame.bytes == "acp_pipe_write_failed" || cmd.frame.bytes == "acp_adapter_exited" || cmd.frame.bytes == "acp_pipe_gap" do reason = cmd.frame.bytes
            acp_rpc_fail(c, reason)
        case .Stdout: acp_rpc_consume(c, cmd.frame.bytes, cmd.frame.seq)
        case .Receipt:
            for w, i in c.state.pending_writes {
                if w.delivery_id != cmd.frame.bytes do continue
                append(&c.state.completed_delivery_ids, w.delivery_id)
                if len(c.state.completed_delivery_ids) > ACP_RPC_COMPLETED_DELIVERY_COUNT {
                    delete(c.state.completed_delivery_ids[0])
                    ordered_remove(&c.state.completed_delivery_ids, 0)
                }
                delete(w.bytes); ordered_remove(&c.state.pending_writes, i)
                acp_rpc_retire_inbound(c, cmd.frame.bytes)
                if !acp_rpc_checkpoint(c) do acp_rpc_fail(c, "acp_state_write_failed")
                break
            }
        }
    }
}

acp_rpc_inbound_bytes :: proc(p: ACP_RPC_Inbound) -> int {
    return len(p.id_json)+len(p.method)+len(p.params_json)+len(p.response_json)+len(p.response_delivery_id)+len(p.blocker_id)
}

acp_rpc_reindex_inbound :: proc(index: ^map[string]int, entries: []ACP_RPC_Inbound) {
    for key in index^ do delete(key)
    clear(index)
    for p, i in entries {
        key, _ := acp_rpc_id(p.id_json)
        index^[strings.clone(key)] = i
    }
}

acp_rpc_duplicate_inbound :: proc(c: ^ACP_RPC_Client, p: ACP_RPC_Inbound, method, params: string) {
    if p.method != method || p.params_json != params { acp_rpc_fail(c, "acp_protocol_error"); return }
    if p.response_json == "" do return
    start := len(c.state.pending_writes)
    _, ok := acp_rpc_stage(c, p.response_json)
    if !ok { acp_rpc_fail(c, "acp_pipe_write_failed"); return }
    acp_rpc_send_staged(c, start)
}

// The final chunk receipt means the preceding serialized chunks reached stdin
// too. Earlier receipt notifications may still be queued; their delivery IDs
// remain in pending_writes until individually receipted and retain daemon dedup.
acp_rpc_retire_inbound :: proc(c: ^ACP_RPC_Client, delivery_id: string) {
    for pending, i in c.state.pending_inbound {
        p := pending
        if p.response_delivery_id != delivery_id do continue
        ordered_remove(&c.state.pending_inbound, i)
        acp_rpc_reindex_inbound(&c.inbound, c.state.pending_inbound[:])
        delete(p.response_delivery_id); p.response_delivery_id = ""
        p.deadline_unix_ms = 0
        size := acp_rpc_inbound_bytes(p)
        if size > ACP_RPC_RECENT_INBOUND_BYTES { acp_state_inbound_delete(p); return }
        for len(c.state.recent_inbound) > 0 && (len(c.state.recent_inbound) >= ACP_RPC_RECENT_INBOUND_COUNT || c.recent_inbound_bytes+size > ACP_RPC_RECENT_INBOUND_BYTES) {
            old := c.state.recent_inbound[0]
            c.recent_inbound_bytes -= acp_rpc_inbound_bytes(old)
            acp_state_inbound_delete(old)
            ordered_remove(&c.state.recent_inbound, 0)
        }
        append(&c.state.recent_inbound, p)
        c.recent_inbound_bytes += size
        acp_rpc_reindex_inbound(&c.recent_inbound, c.state.recent_inbound[:])
        return
    }
}

acp_rpc_params_ok :: proc(raw: string) -> bool {
    v, valid := acp_rpc_parse(raw)
    if !valid do return false
    #partial switch _ in v { case json.Object, json.Array: return true }
    return false
}
// Canonical keys isolate JSON string IDs from numeric IDs and normalize string
// escapes. The original inbound representation is retained separately for reply.
acp_rpc_id :: proc(raw: string) -> (string, bool) {
    v, valid := acp_rpc_parse(raw)
    if !valid do return "", false
    #partial switch x in v {
    case string: return strings.concatenate({"s:", x}, context.temp_allocator), true
    case json.Integer: return fmt.tprintf("n:%d", x), true
    case f64: return fmt.tprintf("n:%g", x), true
    }
    return "", false
}

acp_rpc_fail :: proc(c: ^ACP_RPC_Client, reason: string) {
    if c.failed do return
    c.failed = true
    acp_rpc_reject_all(c, reason)
    if c.callbacks.fault != nil do c.callbacks.fault(c.callbacks.data, strings.clone(reason))
    c.io.close(c.io.data)
}
acp_rpc_result_delete :: proc(r: ACP_RPC_Result) {
    delete(r.method, runtime.heap_allocator())
    delete(string(r.id), runtime.heap_allocator()); delete(r.result_json, runtime.heap_allocator())
    delete(r.error.message, runtime.heap_allocator()); delete(r.error.data_json, runtime.heap_allocator())
}
acp_rpc_deliver :: proc(c: ^ACP_RPC_Client, id: string, r: ACP_RPC_Result) {
    completion := c.completions[id]
    delete_key(&c.completions, id)
    if completion.callback != nil { completion.callback(completion.data, r) } else { acp_rpc_result_delete(r) }
}
acp_rpc_reject_all :: proc(c: ^ACP_RPC_Client, reason: string) {
    for p in c.state.pending_outbound {
        acp_rpc_deliver(c, p.id, {id = ACP_RPC_ID(strings.clone(p.id)), method = strings.clone(p.method), error = {code = -32000, message = strings.clone(reason)}})
    }
}

acp_rpc_expire :: proc(c: ^ACP_RPC_Client) {
    now := acp_rpc_now(c)
    for p in c.state.pending_outbound {
        if p.deadline_unix_ms != 0 && now >= p.deadline_unix_ms { acp_rpc_fail(c, "acp_rpc_timeout"); return }
    }
    for p in c.state.pending_inbound {
        if p.response_json == "" && p.deadline_unix_ms != 0 && now >= p.deadline_unix_ms {
            if c.callbacks.inbound_timeout != nil { c.callbacks.inbound_timeout(c.callbacks.data, p.id_json) }
            else { acp_rpc_reply_error(c, p.id_json, {code = -32000, message = "permission timeout"}) }
        }
    }
}

acp_rpc_value_json :: proc(v: json.Value) -> string {
    raw, _ := json.marshal(v, allocator = context.temp_allocator); return string(raw)
}

acp_rpc_consume :: proc(c: ^ACP_RPC_Client, bytes: string, seq: u64) {
    if seq == 0 || seq > c.state.last_stdout_seq+1 { acp_rpc_fail(c, "acp_protocol_error"); return }
    if seq <= c.state.last_stdout_seq do return // replay of an already durable frame
    start := len(c.state.pending_writes)
    c.in_frame = true
    defer c.in_frame = false
    for b in transmute([]byte)bytes {
        if b != '\n' {
            if len(c.partial) >= ACP_RPC_MAX_LINE { acp_rpc_fail(c, "acp_protocol_error"); return }
            append(&c.partial, b); continue
        }
        if len(c.partial) > 0 do acp_rpc_message(c, string(c.partial[:]))
        clear(&c.partial)
        if c.failed do return
    }
    c.state.last_stdout_seq = seq
    if !acp_rpc_checkpoint(c) { acp_rpc_fail(c, "acp_state_write_failed"); return }
    for w in c.state.pending_writes[start:] do acp_rpc_queue_work(c, w.bytes, w.delivery_id)
    acp_rpc_queue_work(c, "", "", seq)
}

acp_rpc_message :: proc(c: ^ACP_RPC_Client, line: string) {
    if !utf8.valid_string(line) { acp_rpc_fail(c, "acp_protocol_error"); return }
    v, valid_json := acp_rpc_parse(line)
    if !valid_json { acp_rpc_fail(c, "acp_protocol_error"); return }
    obj, object_ok := v.(json.Object)
    if !object_ok { acp_rpc_fail(c, "acp_protocol_error"); return }
    version, _ := obj["jsonrpc"].(string)
    _, has_version := obj["jsonrpc"]
    if (c.policy.codec.jsonrpc_header || has_version) && version != "2.0" { acp_rpc_fail(c, "acp_protocol_error"); return }
    method_value, has_method := obj["method"]
    id, has_id := obj["id"]
    result, has_result := obj["result"]
    error_value, has_error := obj["error"]
    if has_method {
        method, method_ok := method_value.(string)
        if !method_ok || method == "" || has_result || has_error { acp_rpc_fail(c, "acp_protocol_error"); return }
        params := "{}"
        if p, found := obj["params"]; found do params = acp_rpc_value_json(p)
        params_ok := acp_rpc_params_ok(params)
        if !has_id {
            if !params_ok {
                if !c.policy.codec.drop_malformed_notifications do acp_rpc_fail(c, "acp_protocol_error")
                return
            }
            if c.callbacks.notification != nil do c.callbacks.notification(c.callbacks.data, strings.clone(method), strings.clone(params))
            return
        }
        id_json := acp_rpc_raw_id(line)
        key, valid := acp_rpc_id(id_json)
        if !valid { acp_rpc_fail(c, "acp_protocol_error"); return }
        if i, exists := c.inbound[key]; exists {
            acp_rpc_duplicate_inbound(c, c.state.pending_inbound[i], method, params)
            return
        }
        if i, exists := c.recent_inbound[key]; exists {
            acp_rpc_duplicate_inbound(c, c.state.recent_inbound[i], method, params)
            return
        }
        pending_bytes := len(id_json)+len(method)+len(params)
        for p in c.state.pending_inbound do pending_bytes += acp_rpc_inbound_bytes(p)
        if len(c.state.pending_inbound) >= ACP_RPC_MAX_PENDING_INBOUND || pending_bytes > ACP_RPC_PENDING_INBOUND_BYTES {
            acp_rpc_fail(c, "acp_protocol_error"); return
        }
        deadline: i64
        if limit := c.policy.inbound_timeout(method); limit > 0 do deadline = acp_rpc_now(c)+limit
        c.inbound[strings.clone(key)] = len(c.state.pending_inbound)
        append(&c.state.pending_inbound, ACP_RPC_Inbound{id_json = strings.clone(id_json), method = strings.clone(method), params_json = strings.clone(params), deadline_unix_ms = deadline})
        if !params_ok { acp_rpc_reply_error(c, id_json, {code = -32602, message = "Invalid params"}); return }
        handled := false
        if c.callbacks.inbound_request != nil do handled = c.callbacks.inbound_request(c.callbacks.data, strings.clone(id_json), strings.clone(method), strings.clone(params))
        if !handled do acp_rpc_reply_error(c, id_json, {code = -32601, message = "Method not found"})
        return
    }
    if !has_id || has_result == has_error { acp_rpc_fail(c, "acp_protocol_error"); return }
    id_json := acp_rpc_value_json(id)
    _, valid := acp_rpc_id(id_json)
    if !valid { acp_rpc_fail(c, "acp_protocol_error"); return }
    rpc_error: ACP_RPC_Error
    if has_error {
        error_object, ok := error_value.(json.Object)
        if !ok { acp_rpc_fail(c, "acp_protocol_error"); return }
        code, code_ok := error_object["code"].(json.Integer)
        message, message_ok := error_object["message"].(string)
        if !code_ok || !message_ok { acp_rpc_fail(c, "acp_protocol_error"); return }
        rpc_error = {code = int(code), message = message}
        if data, present := error_object["data"]; present do rpc_error.data_json = acp_rpc_value_json(data)
    }
    outgoing_id, matching_type := acp_rpc_response_key(c.policy.codec, c.state.launch_epoch, id)
    idx, found := c.outbound[outgoing_id]
    if !matching_type || !found {
        if !c.unknown_ids[id_json] {
            if len(c.unknown_ids) < ACP_RPC_UNKNOWN_ID_COUNT && c.unknown_id_bytes+len(id_json) <= ACP_RPC_UNKNOWN_ID_BYTES {
                c.unknown_ids[strings.clone(id_json)] = true
                c.unknown_id_bytes += len(id_json)
                if c.callbacks.unknown_response != nil do c.callbacks.unknown_response(c.callbacks.data, strings.clone(id_json))
            } else if !c.unknown_ids_overflow {
                c.unknown_ids_overflow = true
                if c.callbacks.unknown_response != nil do c.callbacks.unknown_response(c.callbacks.data, strings.clone(ACP_RPC_UNKNOWN_ID_OVERFLOW))
            }
        }
        return
    }
    pending := c.state.pending_outbound[idx]
    if pending.deadline_unix_ms != 0 && acp_rpc_now(c) >= pending.deadline_unix_ms { acp_rpc_fail(c, "acp_rpc_timeout"); return }
    // Remove before dispatch, so reentrant callbacks cannot complete twice.
    ordered_remove(&c.state.pending_outbound, idx)
    delete_key(&c.outbound, outgoing_id)
    for p, i in c.state.pending_outbound do c.outbound[p.id] = i
    r := ACP_RPC_Result{id = ACP_RPC_ID(strings.clone(pending.id)), method = strings.clone(pending.method), ok = has_result}
    if has_result do r.result_json = strings.clone(acp_rpc_value_json(result))
    if has_error do r.error = {rpc_error.code, strings.clone(rpc_error.message), strings.clone(rpc_error.data_json)}
    acp_rpc_deliver(c, pending.id, r)
    delete(pending.id); delete(pending.method); delete(pending.params_json); delete(pending.delivery_id)
}

// The object has already passed the JSON parser. Retain the original ID token
// (including its numeric representation/string escaping), not a quoted string
// representation of that token. Nested objects and escaped quotes are skipped.
acp_rpc_raw_id :: proc(line: string) -> string {
    i := strings.index_byte(line, '{')+1
    for i < len(line) {
        for i < len(line) && (line[i] == ' ' || line[i] == '\t' || line[i] == '\r' || line[i] == ',') do i += 1
        if i >= len(line) || line[i] != '"' do break
        key_start := i; i += 1
        for i < len(line) {
            if line[i] == '\\' { i += 2; continue }
            if line[i] == '"' { i += 1; break }
            i += 1
        }
        key_json := line[key_start:i]
        for i < len(line) && line[i] != ':' do i += 1
        i += 1
        for i < len(line) && (line[i] == ' ' || line[i] == '\t' || line[i] == '\r') do i += 1
        start := i; depth := 0; quoted := false
        for i < len(line) {
            ch := line[i]
            if quoted {
                if ch == '\\' { i += 2; continue }
                if ch == '"' do quoted = false
            } else {
                if ch == '"' { quoted = true } else if ch == '[' || ch == '{' { depth += 1 } else if ch == ']' || ch == '}' {
                    if depth == 0 do break
                    depth -= 1
                } else if ch == ',' && depth == 0 do break
            }
            i += 1
        }
        key_value, _ := json.parse(key_json, allocator = context.temp_allocator)
        if key, ok := key_value.(string); ok && key == "id" do return strings.trim_space(line[start:i])
    }
    return ""
}

// Shared by normal restore and the one-time legacy binding migration. This
// validates framing, counters, identities and bounded queues without callbacks.
acp_rpc_restore_checkpoint_valid :: proc(state: ^ACP_State, restore_completion_available: bool, policy: ACP_RPC_Policy = ACP_RPC_POLICY_ACP) -> bool {
    if len(state.pending_inbound) > ACP_RPC_MAX_PENDING_INBOUND || len(state.recent_inbound) > ACP_RPC_RECENT_INBOUND_COUNT do return false
    if len(state.pending_outbound) > ACP_RPC_MAX_PENDING_OUTBOUND do return false
    // Validate the entire checkpoint before exposing any of it to callbacks.
    seen := make(map[string]bool, allocator = context.temp_allocator)
    outbound_bytes := 0
    for p in state.pending_outbound {
        if p.id == "" || seen[p.id] || !strings.has_prefix(p.id, fmt.tprintf("ham:%s:", state.launch_epoch)) || !acp_rpc_params_ok(p.params_json) || p.role != policy.role(p.method) do return false
        counter, counter_ok := strconv.parse_u64(strings.trim_prefix(p.id, fmt.tprintf("ham:%s:", state.launch_epoch)))
        if !counter_ok || counter == 0 || counter >= state.next_rpc_id do return false
        if !restore_completion_available do return false
        seen[p.id] = true
        outbound_bytes += len(p.id)+len(p.method)+len(p.params_json)+len(p.delivery_id)
    }
    if outbound_bytes > ACP_RPC_PENDING_OUTBOUND_BYTES do return false
    clear(&seen)
    pending_bytes := 0
    for p in state.pending_inbound {
        key, id_ok := acp_rpc_id(p.id_json)
        if !id_ok || seen[key] || p.method == "" || !acp_rpc_json(p.params_json) do return false
        if p.response_json != "" && (!strings.has_suffix(p.response_json, "\n") || !acp_rpc_json(strings.trim_space(p.response_json))) do return false
        if (p.response_json == "") != (p.response_delivery_id == "") do return false
        pending_bytes += acp_rpc_inbound_bytes(p)
        seen[key] = true
    }
    if pending_bytes > ACP_RPC_PENDING_INBOUND_BYTES do return false
    recent_bytes := 0
    for p in state.recent_inbound {
        key, id_ok := acp_rpc_id(p.id_json)
        if !id_ok || seen[key] || p.method == "" || !acp_rpc_json(p.params_json) || p.response_json == "" || p.response_delivery_id != "" do return false
        if !strings.has_suffix(p.response_json, "\n") || !acp_rpc_json(strings.trim_space(p.response_json)) do return false
        recent_bytes += acp_rpc_inbound_bytes(p)
        seen[key] = true
    }
    if recent_bytes > ACP_RPC_RECENT_INBOUND_BYTES do return false
    clear(&seen)
    queued := 0
    for w in state.pending_writes {
        if w.delivery_id == "" || seen[w.delivery_id] || len(w.bytes) == 0 || len(w.bytes) > 64*1024 do return false
        prefix := fmt.tprintf("ham:%s:write:", state.launch_epoch)
        if !strings.has_prefix(w.delivery_id, prefix) do return false
        counter, counter_ok := strconv.parse_u64(strings.trim_prefix(w.delivery_id, prefix))
        if !counter_ok || counter == 0 || counter >= state.next_delivery_id do return false
        seen[w.delivery_id] = true; queued += len(w.bytes)
    }
    if queued > ACP_RPC_MAX_LINE do return false
    for p in state.pending_inbound {
        if p.response_delivery_id != "" && !seen[p.response_delivery_id] do return false
    }
    // These are diagnostic recent receipts, not the daemon's deduplication
    // authority. Older journals may safely shed excess completed IDs on load.
    if len(state.completed_delivery_ids) > ACP_RPC_COMPLETED_DELIVERY_COUNT {
        drop := len(state.completed_delivery_ids)-ACP_RPC_COMPLETED_DELIVERY_COUNT
        for id in state.completed_delivery_ids[:drop] do delete(id)
        recent := make([dynamic]string, 0, ACP_RPC_COMPLETED_DELIVERY_COUNT)
        append(&recent, ..state.completed_delivery_ids[drop:])
        delete(state.completed_delivery_ids); state.completed_delivery_ids = recent
    }
    for id in state.completed_delivery_ids {
        if id == "" || seen[id] do return false
        seen[id] = true
    }
    return true
}

acp_rpc_restore_state :: proc(c: ^ACP_RPC_Client, raw: string) -> bool {
    // Restore is allowed only on a fresh connection, before AttachPipe output.
    if c.restored || c.state.next_rpc_id != 1 || c.state.last_stdout_seq != 0 || len(c.state.pending_writes) != 0 || len(c.state.pending_inbound) != 0 do return false
    state, ok := acp_state_decode(raw)
    if !ok do return false
    valid := false
    defer { if !valid do acp_state_delete(&state) }
    if state.instance != c.io.instance || state.launch_epoch != c.io.launch_epoch do return false
    if !acp_rpc_restore_checkpoint_valid(&state, c.callbacks.restore_completion != nil, c.policy) do return false
    partial, _ := base64.decode(state.partial_line_base64)
    defer delete(partial)
    acp_state_delete(&c.state); c.state = state
    valid = true; c.restored = true
    append(&c.partial, ..partial)
    for p, i in state.pending_outbound {
        c.outbound[p.id] = i
        completion := c.callbacks.restore_completion(c.callbacks.data, p.role, ACP_RPC_ID(strings.clone(p.id)))
        c.completions[p.id] = completion
    }
    acp_rpc_reindex_inbound(&c.inbound, state.pending_inbound[:])
    acp_rpc_reindex_inbound(&c.recent_inbound, state.recent_inbound[:])
    c.recent_inbound_bytes = 0
    for p in state.recent_inbound do c.recent_inbound_bytes += acp_rpc_inbound_bytes(p)
    // Restore is one transaction, including reconstituted blockers. An expired
    // setup call must fail before any old stdin bytes can be retried. Defer
    // reentrant replies until older chunks are queued in their original order.
    c.in_frame = true
    defer c.in_frame = false
    acp_rpc_expire(c)
    if c.failed do return false
    for p in c.state.pending_inbound {
        if p.response_json == "" && c.callbacks.inbound_request != nil {
            handled := c.callbacks.inbound_request(c.callbacks.data, strings.clone(p.id_json), strings.clone(p.method), strings.clone(p.params_json))
            if !handled do acp_rpc_reply_error(c, p.id_json, {code = -32601, message = "Method not found"})
        }
    }
    if !acp_rpc_checkpoint(c) { acp_rpc_fail(c, "acp_state_write_failed"); return false }
    // Never regenerate an RPC or delivery ID. Receipts suppress duplicate stdin.
    for w in c.state.pending_writes do acp_rpc_queue_work(c, w.bytes, w.delivery_id)
    acp_rpc_enable_reader(c)
    return !c.failed
}

acp_rpc_enable_reader :: proc(c: ^ACP_RPC_Client) {
    sync.mutex_lock(&c.mu)
    sync.atomic_store(&c.reader_enabled, true)
    sync.cond_broadcast(&c.cond)
    sync.mutex_unlock(&c.mu)
}
