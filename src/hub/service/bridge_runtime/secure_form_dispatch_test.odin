package bridge_runtime

import "base:runtime"
import "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import project "odin_test:hub/service/project"

// The dispatch slot is process-wide, so tests that need admission must not run
// in parallel with each other. Each holds this lock and starts with a free slot.
_secure_form_dispatch_test_mu: sync.Mutex

secure_form_dispatch_test_begin :: proc() {
	sync.lock(&_secure_form_dispatch_test_mu)
	for _ in 0 ..< 400 {
		if sync.atomic_load(&_secure_form_dispatch_slot) == 0 do return
		time.sleep(5 * time.Millisecond)
	}
}

@(test)
test_secure_form_dispatch_stale_busy_and_interrupted_chunk :: proc(t: ^testing.T) {
	secure_form_dispatch_test_begin()
	defer sync.unlock(&_secure_form_dispatch_test_mu)
	registry: project.Bridge_Runtime_Registry
	destroyed := false
	defer if !destroyed do runtime_command_cache_destroy(&registry)
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, err == nil) do return
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)
	peer, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if !testing.expect(t, dial_err == nil) do return
	defer net.close(peer)
	socket, _, accept_err := net.accept_tcp(listener)
	if !testing.expect(t, accept_err == nil) do return
	defer net.close(socket)
	_ = net.set_option(peer, .Receive_Timeout, 30 * time.Millisecond)

	id := "brg_secure_form_test"
	hello, ok, _ := runtime_accept_hello(&registry, id, PROTOCOL_VERSION, "")
	if !testing.expect(t, ok) do return
	project.bridge_runtime_registry_set_command_socket(&registry, id, socket, hello.generation)
	connection := project.bridge_runtime_connection_acquire(&registry, id, hello.generation)
	if !testing.expect(t, connection != nil) do return

	body := `{"type":"secure_form_answer","payload":{"synthetic":"no-live-secret"}}`
	testing.expect_value(t, secure_form_dispatch(&registry, id, hello.generation + 1, body, nil, nil), Secure_Form_Dispatch_Result.Stale)
	sync.lock(&connection.writer_mutex)
	busy := secure_form_dispatch(&registry, id, hello.generation, body, nil, nil)
	sync.unlock(&connection.writer_mutex)
	testing.expect_value(t, busy, Secure_Form_Dispatch_Result.Busy)
	buffer: [1]byte
	n, _ := net.recv_tcp(peer, buffer[:])
	testing.expect_value(t, n, 0)
	project.bridge_runtime_connection_release(&registry, connection)

	// Fill the kernel buffer so completion cannot race ahead of peer teardown.
	_ = net.set_option(socket, .Send_Buffer_Size, 4096)
	_ = net.set_option(peer, .Receive_Buffer_Size, 4096)
	_ = net.set_option(peer, .Receive_Timeout, 2 * time.Second)
	large := strings.concatenate({`{"type":"secure_form_answer","payload":"`,
		strings.repeat("x", 1024*1024, context.temp_allocator), `"}`})
	defer delete(large)
	result := Command_Write_Result.Ok
	enqueued := secure_form_dispatch(&registry, id, hello.generation, large, proc(raw: rawptr, outcome: Command_Write_Result) {
		(^Command_Write_Result)(raw)^ = outcome
	}, &result)
	if !testing.expect_value(t, enqueued, Secure_Form_Dispatch_Result.Queued) do return
	got, _ := net.recv_tcp(peer, buffer[:])
	testing.expect_value(t, got, 1)
	testing.expect_value(t, buffer[0], byte(0x81))
	testing.expect_value(t, secure_form_dispatch(&registry, id, hello.generation, body, nil, nil), Secure_Form_Dispatch_Result.Busy)
	_ = net.shutdown(net.Any_Socket(peer), .Both)
	// Teardown waits for the dispatch reference, including its result callback.
	runtime_command_cache_destroy(&registry)
	destroyed = true
	testing.expect_value(t, result, Command_Write_Result.Send_Failed)
}

// Counts every allocation made through it, forwarding to a backing allocator.
Secure_Form_Counting_Allocator :: struct {
	backing: runtime.Allocator,
	allocations: int,
}

secure_form_counting_allocator_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	counter := (^Secure_Form_Counting_Allocator)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed: sync.atomic_add(&counter.allocations, 1)
	}
	return counter.backing.procedure(counter.backing.data, mode, size, alignment, old_memory, old_size, location)
}

Secure_Form_Test_Bridge :: struct {
	registry: project.Bridge_Runtime_Registry,
	listener: net.TCP_Socket,
	peer: net.TCP_Socket,
	socket: net.TCP_Socket,
	id: string,
	generation: int,
}

// A live bridge command socket whose peer does not read until told to, so a
// large dispatch blocks inside the writer.
secure_form_test_bridge_open :: proc(t: ^testing.T, b: ^Secure_Form_Test_Bridge, id: string) -> bool {
	err: net.Network_Error
	b.listener, err = net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, err == nil) do return false
	bound, _ := net.bound_endpoint(b.listener)
	b.peer, err = net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if !testing.expect(t, err == nil) do return false
	b.socket, _, err = net.accept_tcp(b.listener)
	if !testing.expect(t, err == nil) do return false
	_ = net.set_option(b.socket, .Send_Buffer_Size, 4096)
	_ = net.set_option(b.peer, .Receive_Buffer_Size, 4096)
	_ = net.set_option(b.peer, .Receive_Timeout, 2 * time.Second)
	b.id = id
	hello, ok, _ := runtime_accept_hello(&b.registry, id, PROTOCOL_VERSION, "")
	if !testing.expect(t, ok) do return false
	b.generation = hello.generation
	project.bridge_runtime_registry_set_command_socket(&b.registry, id, b.socket, hello.generation)
	return true
}

secure_form_test_bridge_close :: proc(b: ^Secure_Form_Test_Bridge) {
	_ = net.shutdown(net.Any_Socket(b.peer), .Both)
	// Teardown waits for every dispatch reference, including result callbacks.
	runtime_command_cache_destroy(&b.registry)
	net.close(b.peer)
	net.close(b.socket)
	net.close(b.listener)
}

secure_form_test_large_body :: proc(size: int) -> string {
	return strings.concatenate({`{"type":"secure_form_answer","payload":"`,
		strings.repeat("x", size, context.temp_allocator), `"}`}, context.temp_allocator)
}

secure_form_test_count_result :: proc(raw: rawptr, _: Command_Write_Result) {
	sync.atomic_add((^int)(raw), 1)
}

// Regression (P0 Hub segfault): HTTP handlers run on a per-request arena that is
// destroyed once the 202 is written. core:thread allocates its ^Thread from
// context.allocator, so dispatch must not draw anything from the caller's
// allocator: the detached thread outlives the request.
@(test)
test_secure_form_dispatch_never_allocates_from_caller_allocator :: proc(t: ^testing.T) {
	secure_form_dispatch_test_begin()
	defer sync.unlock(&_secure_form_dispatch_test_mu)
	b: Secure_Form_Test_Bridge
	if !secure_form_test_bridge_open(t, &b, "brg_secure_form_alloc") {
		runtime_command_cache_destroy(&b.registry)
		return
	}
	body := `{"type":"secure_form_answer","payload":{"synthetic":"no-live-secret"}}`
	completed := 0
	counter := Secure_Form_Counting_Allocator{backing = runtime.heap_allocator()}
	result: Secure_Form_Dispatch_Result
	{
		context.allocator = runtime.Allocator{secure_form_counting_allocator_proc, &counter}
		result = secure_form_dispatch(&b.registry, b.id, b.generation, body, secure_form_test_count_result, &completed)
	}
	testing.expect_value(t, result, Secure_Form_Dispatch_Result.Queued)
	testing.expect_value(t, sync.atomic_load(&counter.allocations), 0)
	secure_form_test_bridge_close(&b)
	testing.expect_value(t, sync.atomic_load(&completed), 1)
}

// Regression (P0 Hub segfault): reproduce the production sequence. The handler
// dispatches on a request arena, returns, and the arena is unmapped while the
// writer is still blocked on a slow Bridge. Before the fix the detached thread
// wrote its Done flag into the unmapped ^Thread and the process took SIGSEGV
// in __unix_thread_entry_proc.
@(test)
test_secure_form_dispatch_outlives_destroyed_request_arena :: proc(t: ^testing.T) {
	secure_form_dispatch_test_begin()
	defer sync.unlock(&_secure_form_dispatch_test_mu)
	b: Secure_Form_Test_Bridge
	if !secure_form_test_bridge_open(t, &b, "brg_secure_form_arena") {
		runtime_command_cache_destroy(&b.registry)
		return
	}
	large := secure_form_test_large_body(512 * 1024)
	completed := 0
	result: Secure_Form_Dispatch_Result
	{
		arena: virtual.Arena
		if !testing.expect(t, virtual.arena_init_growing(&arena, 256 * 1024) == nil) do return
		context.allocator = virtual.arena_allocator(&arena)
		result = secure_form_dispatch(&b.registry, b.id, b.generation, large, secure_form_test_count_result, &completed)
		virtual.arena_destroy(&arena)
	}
	testing.expect_value(t, result, Secure_Form_Dispatch_Result.Queued)
	// Drain the peer so the blocked writer completes after the arena is gone.
	buffer: [16 * 1024]byte
	received := 0
	for received < len(large) {
		n, err := net.recv_tcp(b.peer, buffer[:])
		if err != nil || n <= 0 do break
		received += n
	}
	testing.expect(t, received >= len(large))
	secure_form_test_bridge_close(&b)
	testing.expect_value(t, sync.atomic_load(&completed), 1)
	// The detached thread has released the slot; a new dispatch is admitted.
	for _ in 0 ..< 200 {
		if sync.atomic_load(&_secure_form_dispatch_slot) == 0 do break
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, sync.atomic_load(&_secure_form_dispatch_slot), 0)
}

Secure_Form_Stress :: struct {
	b: ^Secure_Form_Test_Bridge,
	body: string,
	iterations: int,
	queued: int,
	busy: int,
	stale: int,
	completed: int,
}

secure_form_stress_submitter :: proc(raw: rawptr) {
	s := (^Secure_Form_Stress)(raw)
	for _ in 0 ..< s.iterations {
		// Each submission runs like an HTTP handler on its own request arena,
		// destroyed as soon as the handler returns.
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena, 64 * 1024) != nil do continue
		context.allocator = virtual.arena_allocator(&arena)
		switch secure_form_dispatch(&s.b.registry, s.b.id, s.b.generation, s.body, secure_form_test_count_result, &s.completed) {
		case .Queued: sync.atomic_add(&s.queued, 1)
		case .Busy: sync.atomic_add(&s.busy, 1)
		case .Stale: sync.atomic_add(&s.stale, 1)
		}
		virtual.arena_destroy(&arena)
		context.allocator = runtime.heap_allocator()
		thread.yield()
	}
}

secure_form_stress_slow_reader :: proc(raw: rawptr) {
	peer := (^net.TCP_Socket)(raw)^
	buffer: [2048]byte
	for {
		n, err := net.recv_tcp(peer, buffer[:])
		if err != nil || n <= 0 do return
		time.sleep(50 * time.Microsecond)
	}
}

// Many concurrent submissions against a slow, then disconnecting, Bridge.
// Every admitted dispatch completes exactly once, nothing touches request
// memory, and the process-wide slot is released.
@(test)
test_secure_form_dispatch_concurrent_submit_stress :: proc(t: ^testing.T) {
	secure_form_dispatch_test_begin()
	defer sync.unlock(&_secure_form_dispatch_test_mu)
	b: Secure_Form_Test_Bridge
	if !secure_form_test_bridge_open(t, &b, "brg_secure_form_stress") {
		runtime_command_cache_destroy(&b.registry)
		return
	}
	stress := Secure_Form_Stress{b = &b, body = secure_form_test_large_body(96 * 1024), iterations = 400}
	reader := thread.create_and_start_with_data(&b.peer, secure_form_stress_slow_reader)
	SUBMITTERS :: 8
	submitters: [SUBMITTERS]^thread.Thread
	for i in 0 ..< SUBMITTERS do submitters[i] = thread.create_and_start_with_data(&stress, secure_form_stress_submitter)
	// Disconnect the Bridge while submissions are still in flight.
	time.sleep(150 * time.Millisecond)
	_ = net.shutdown(net.Any_Socket(b.peer), .Both)
	for s in submitters do if s != nil do thread.destroy(s)
	secure_form_test_bridge_close(&b)
	if reader != nil do thread.destroy(reader)

	total := sync.atomic_load(&stress.queued) + sync.atomic_load(&stress.busy) + sync.atomic_load(&stress.stale)
	testing.expect_value(t, total, SUBMITTERS * stress.iterations)
	testing.expect(t, sync.atomic_load(&stress.queued) > 0)
	testing.expect_value(t, sync.atomic_load(&stress.completed), sync.atomic_load(&stress.queued))
	for _ in 0 ..< 200 {
		if sync.atomic_load(&_secure_form_dispatch_slot) == 0 do break
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, sync.atomic_load(&_secure_form_dispatch_slot), 0)
}
