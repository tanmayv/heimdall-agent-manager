package bridge_runtime

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import project "odin_test:hub/service/project"

@(test)
test_secure_form_dispatch_stale_busy_and_interrupted_chunk :: proc(t: ^testing.T) {
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
