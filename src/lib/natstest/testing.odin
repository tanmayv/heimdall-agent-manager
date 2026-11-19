package natstest

import "base:runtime"
import "core:testing"

// testing_url starts a real server which outlives fixture helper stack frames.
// Cleanup runs after the test's deferred graph shutdown, using its own heap context.
testing_url :: proc(t: ^testing.T) -> string {
	context.allocator = runtime.heap_allocator()
	s := new(Server)
	ok: bool
	s^, ok = start()
	testing.cleanup(t, proc(data: rawptr) { server := (^Server)(data); destroy(server); free(server) }, s)
	testing.expect(t, ok, "real NATS fixture starts")
	return s.url
}
