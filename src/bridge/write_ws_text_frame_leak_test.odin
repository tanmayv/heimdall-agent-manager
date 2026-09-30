package main

// REQ-SHELL-52 AC4 — the COMMITTED GUARD for the `defer delete(frame)` in write_ws_text
// (main.odin:684). Sibling of src/lib/ws/send_text_frame_leak_test.odin; the rationale for
// why an uncommitted probe was not good enough is written out there and not repeated here.
//
// THE TWO FILES ARE DELIBERATELY SEPARATE TESTS OF SEPARATE LINES. This is the point the
// coordinator sharpened and it is the right formulation: one test that caught both
// removals together would still pass if only ONE `defer` were ever deleted, and deleting
// one is the realistic regression — five near-identical copies of this writer are exactly
// how this family diverged. So each `defer` has its own test in its own package, and each
// was mutation-verified on its own.
//
// ASSERTS BOTH HALVES, same reason as the ws side: bridge_tcp_send_all (main.odin:516-524)
// BORROWS the slice and frees on neither exit, so a leak-only check would read clean if a
// future change made the sender free it, and the symptom of that would be a double free in
// the live bridge rather than a test failure.
//
// A NOTE ON THE MUTEX, because it would be an unpleasant false trail. write_ws_text takes
// the package-global `bridge_ws_send_mutex` (main.odin:53). No other test in this package
// touches that mutex today — `grep -rn bridge_ws_send_mutex src/bridge/*_test.odin` is
// empty, and write_ws_text has no other caller in the tree — so these tests cannot contend
// at any thread count. If a future test does take it and this file HANGS rather than
// fails, suspect the mutex before suspecting the fix, and note that a hang reports NO
// RESULT, which on this chain reads like the REQ-SHELL-49 crash signature.

import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
Frame_Leak_Pair :: struct {
	listener: net.TCP_Socket,
	peer:     net.TCP_Socket,
	hub:      net.TCP_Socket,
}

// 4 MiB each way, so no write in this file can block on a peer that is not reading and be
// mistaken for a slow free.
@(private = "file")
FRAME_LEAK_PAIR_BUFFER_BYTES :: 4 * 1024 * 1024

@(private = "file")
frame_leak_make_pair :: proc(t: ^testing.T) -> Frame_Leak_Pair {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "fixture: could not listen on loopback")
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "fixture: could not read the bound endpoint")
	}
	peer, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "fixture: could not dial loopback")
	}
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(peer)
		testing.fail_now(t, "fixture: could not accept on loopback")
	}
	_ = net.set_option(hub, .Send_Buffer_Size, FRAME_LEAK_PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Buffer_Size, FRAME_LEAK_PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Timeout, 2 * time.Second)
	return Frame_Leak_Pair{listener = listener, peer = peer, hub = hub}
}

@(private = "file")
frame_leak_close_pair :: proc(p: ^Frame_Leak_Pair) {
	net.close(p.hub)
	net.close(p.peer)
	net.close(p.listener)
}

@(private = "file")
frame_leak_expect_heap_restored :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator, baseline_allocs: int, what: string) {
	testing.expectf(t, len(track.allocation_map) == baseline_allocs,
		"%s: LEAK — %d live allocations, expected the baseline %d. write_ws_text's `defer delete(frame)` is the only thing that frees this; bridge_tcp_send_all borrows.",
		what, len(track.allocation_map), baseline_allocs)
	testing.expectf(t, len(track.bad_free_array) == 0,
		"%s: %d BAD FREES — the frame was freed twice, or with the wrong allocator. bridge_tcp_send_all must not free a slice write_ws_text owns.",
		what, len(track.bad_free_array))
}

@(private = "file")
FRAME_LEAK_REPEATS :: 64

// Both header widths, for the same reason as the ws side: `len(text) > 125` selects a
// different `make` size on a different branch.
@(test)
test_write_ws_text_frees_its_frame_on_the_success_path :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	pair := frame_leak_make_pair(t)
	defer frame_leak_close_pair(&pair)

	big := strings.repeat("x", 1000)
	defer delete(big)

	baseline_allocs := len(track.allocation_map)
	{
		for _ in 0 ..< FRAME_LEAK_REPEATS {
			testing.expect(t, write_ws_text(pair.hub, "short"), "fixture: the 2-byte-header write must succeed on a drained loopback")
			testing.expect(t, write_ws_text(pair.hub, big), "fixture: the 4-byte-header write must succeed on a drained loopback")
		}
	}
	frame_leak_expect_heap_restored(t, &track, baseline_allocs, "write_ws_text success path")
}

// bridge_tcp_send_all's failure exit (`err != nil || sent <= 0`) is below the allocation,
// so it is a path the frame has to survive. Closed socket, for the same
// deterministic-and-no-SIGPIPE reason as the ws side.
@(test)
test_write_ws_text_frees_its_frame_when_the_write_fails :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	pair := frame_leak_make_pair(t)
	frame_leak_close_pair(&pair)

	big := strings.repeat("y", 1000)
	defer delete(big)

	baseline_allocs := len(track.allocation_map)
	{
		for _ in 0 ..< FRAME_LEAK_REPEATS {
			testing.expect(t, !write_ws_text(pair.hub, big),
				"a write on a closed socket must report failure — if this passes, the test is no longer exercising the failure exit")
		}
	}
	frame_leak_expect_heap_restored(t, &track, baseline_allocs, "write_ws_text failure path")
}

// The one exit ABOVE the allocation. Pinned so the baselines above stay meaningful, and
// because the 65535 refusal on this channel is the deliberate 16-bit invariant rather than
// an oversight — REQ-SHELL-36 exists because lifting it would kill the connection.
@(test)
test_write_ws_text_allocates_nothing_when_it_refuses_an_oversized_payload :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	pair := frame_leak_make_pair(t)
	defer frame_leak_close_pair(&pair)

	oversized := strings.repeat("z", 65536)
	defer delete(oversized)

	baseline_allocs := len(track.allocation_map)
	{
		testing.expect(t, !write_ws_text(pair.hub, oversized),
			"65536 bytes must be refused: this is the hub<->bridge channel and its reader treats a 64-bit length as fatal")
	}
	frame_leak_expect_heap_restored(t, &track, baseline_allocs, "write_ws_text oversized refusal")
}
