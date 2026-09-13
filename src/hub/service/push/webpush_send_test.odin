package push

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// --- WP-SEND-2: payload construction (mirrors notificationMapper.ts) ---------

@(test)
build_chat_notification_plain :: proc(t: ^testing.T) {
	c := build_chat_notification("conv_1", "inst_1", "text", "hello world")
	defer free_notification_content(c)
	testing.expect_value(t, c.title, "New message")
	testing.expect_value(t, c.body, "hello world")
	// Tag keys on the conversation id (dedup), route keys on the INSTANCE id
	// because conversation routing is instance-id-only.
	testing.expect_value(t, c.tag, "heimdall:chat:conv_1")
	testing.expect_value(t, c.route, "/conversations/inst_1")
	testing.expect_value(t, c.category, Push_Category.Chat)
}

@(test)
build_chat_notification_route_keys_on_instance_not_conversation :: proc(t: ^testing.T) {
	// Regression: when BOTH ids are present, the deep-link route MUST use the
	// agent instance id, never the conversation id (conversation routing is
	// instance-id-only). The dedup tag still keys on the conversation id.
	c := build_chat_notification("conv_42", "inst_42", "text", "hi")
	defer free_notification_content(c)
	testing.expect_value(t, c.route, "/conversations/inst_42")
	testing.expect_value(t, c.tag, "heimdall:chat:conv_42")
}

@(test)
build_chat_notification_nudge_and_mention :: proc(t: ^testing.T) {
	n := build_chat_notification("conv_1", "inst_1", "nudge", "poke")
	defer free_notification_content(n)
	testing.expect_value(t, n.title, "Nudge")

	m := build_chat_notification("conv_1", "inst_1", "mention", "hey @you")
	defer free_notification_content(m)
	testing.expect_value(t, m.title, "You were mentioned")
}

@(test)
build_chat_notification_falls_back_to_instance :: proc(t: ^testing.T) {
	// No conversation id -> route + tag key on the agent instance id.
	c := build_chat_notification("", "inst_9", "text", "hi")
	defer free_notification_content(c)
	testing.expect_value(t, c.route, "/conversations/inst_9")
	testing.expect_value(t, c.tag, "heimdall:chat:inst_9")
}

@(test)
build_chat_notification_empty_ids_are_freeable :: proc(t: ^testing.T) {
	// Both ids empty -> static-looking fallbacks, but still heap-allocated so
	// free_notification_content is always safe (no delete() of a literal).
	c := build_chat_notification("", "", "text", "hi")
	defer free_notification_content(c)
	testing.expect_value(t, c.route, "/conversations")
	testing.expect_value(t, c.tag, "heimdall:chat:unknown")
}

@(test)
build_push_payload_json_shape_with_origin :: proc(t: ^testing.T) {
	c := Notification_Content{
		title = "New message",
		body = "hi there",
		tag = "heimdall:chat:conv_1",
		route = "/conversations/conv_1",
		category = .Chat,
	}
	got := build_push_payload_json(c, "https://heimdall.mundus.in")
	defer delete(got)
	// Field presence + the absolute href = origin + "/#" + route.
	testing.expect(t, strings.contains(got, "\"title\":\"New message\""))
	testing.expect(t, strings.contains(got, "\"category\":\"chat\""))
	testing.expect(t, strings.contains(got, "\"route\":\"/conversations/conv_1\""))
	testing.expect(t, strings.contains(got, "\"href\":\"https://heimdall.mundus.in/#/conversations/conv_1\""))
}

@(test)
build_push_payload_json_empty_href_without_origin :: proc(t: ^testing.T) {
	c := Notification_Content{title = "t", body = "b", tag = "g", route = "/conversations", category = .Attention}
	got := build_push_payload_json(c, "")
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"href\":\"\""))
	testing.expect(t, strings.contains(got, "\"category\":\"attention\""))
}

@(test)
push_preview_truncates_on_rune_boundary :: proc(t: ^testing.T) {
	// Collapses whitespace.
	c := push_preview("  a\t\n b  ", 140)
	defer delete(c)
	testing.expect_value(t, c, "a b")

	// Truncates with an ellipsis at max_len.
	long := strings.repeat("x", 200)
	defer delete(long)
	trunc := push_preview(long, 10)
	defer delete(trunc)
	// 9 x's + ellipsis rune.
	testing.expect(t, strings.has_suffix(trunc, "\u2026"))
	testing.expect(t, strings.count(trunc, "x") == 9)
}

// --- WP-SEND-1: endpoint splitting + disabled no-op --------------------------

@(test)
split_endpoint_parses_base_and_path :: proc(t: ^testing.T) {
	base, path, ok := split_endpoint("https://web.push.apple.com/abc/def?x=1")
	defer delete(base); defer delete(path)
	testing.expect(t, ok)
	testing.expect_value(t, base, "https://web.push.apple.com")
	testing.expect_value(t, path, "/abc/def?x=1")

	base2, path2, ok2 := split_endpoint("https://fcm.googleapis.com")
	defer delete(base2); defer delete(path2)
	testing.expect(t, ok2)
	testing.expect_value(t, base2, "https://fcm.googleapis.com")
	testing.expect_value(t, path2, "/")

	_, _, bad := split_endpoint("not-a-url")
	testing.expect(t, !bad)
}

// --- WP-SEND-1: async job ownership (P0 SIGSEGV regression) ------------------

@(private = "file")
ptr_in_arena :: proc(arena: ^virtual.Arena, p: rawptr) -> bool {
	addr := uintptr(p)
	for block := arena.curr_block; block != nil; block = block.prev {
		base := uintptr(rawptr(block.base))
		if addr >= base && addr < base + uintptr(block.committed) do return true
	}
	return false
}

@(test)
async_send_job_owns_copies_off_request_arena :: proc(t: ^testing.T) {
	// P0 REGRESSION (hub SIGSEGV in webpush_encrypt_with copy_slice):
	// send_to_user_async is called from an HTTP handler whose context.allocator is
	// the per-request virtual.Arena (MEM-4). That arena is destroyed the moment the
	// handler returns — but async_send_entry runs LATER on a spawned thread and
	// reads job.payload_json (the memmove in webpush_encrypt copies from it). If the
	// job/payload were cloned with the ambient (arena) allocator they dangle once
	// the request returns, so the worker copies from freed/unmapped pages -> SEGV.
	// The owned copies MUST live on the persistent heap, not the request arena.
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena, 64 * 1024) == nil)
	defer virtual.arena_destroy(&arena)

	// Build the args the way the handler does: on the request arena. Then make the
	// job while the arena is the ambient allocator — exactly the production path.
	prev := context.allocator
	context.allocator = virtual.arena_allocator(&arena)
	payload := strings.clone("{\"title\":\"hi\",\"body\":\"world\"}")
	owner := domain.User_ID(strings.clone("usr_arena"))
	job := async_send_job_make(nil, owner, payload)
	context.allocator = prev

	testing.expect(t, job != nil)
	// The retained copies must NOT point into the per-request arena.
	testing.expect(t, !ptr_in_arena(&arena, rawptr(raw_data(job.payload_json))),
		"async job payload retained per-request arena memory (use-after-free)")
	testing.expect(t, !ptr_in_arena(&arena, rawptr(raw_data(string(job.owner_user_id)))),
		"async job owner id retained per-request arena memory (use-after-free)")
	// And they must be independent, intact copies of the originals.
	testing.expect_value(t, job.payload_json, "{\"title\":\"hi\",\"body\":\"world\"}")
	testing.expect_value(t, string(job.owner_user_id), "usr_arena")

	async_send_job_destroy(job)
}

// The gate lets the spawned worker stay alive until the test has destroyed the
// request arena, so the test reproduces the exact prod ordering (arena freed
// while the thread is still running) before the worker returns and the trampoline
// writes t.flags.
@(private = "file")
async_thread_gate: sync.Sema

@(private = "file")
async_thread_gate_entry :: proc(data: rawptr) {
	sync.sema_wait(&async_thread_gate)
}

@(test)
async_push_thread_struct_off_request_arena :: proc(t: ^testing.T) {
	// P0 part-2 REGRESSION (hub SIGSEGV in the thread-entry trampoline after sends):
	// send_to_user_async spawns the push worker from an HTTP handler whose
	// context.allocator is the per-request virtual.Arena (MEM-4). thread.create
	// allocates the Thread struct with context.allocator and stores it as
	// t.creation_allocator (thread_unix.odin). An arena-backed Thread is freed the
	// instant the handler returns and the arena is destroyed — while the OS thread is
	// still running its ~9s of sends. The trampoline's post-proc `lock orb t.flags`
	// store (and self-cleanup's free(t, creation_allocator)) then hit freed memory ->
	// SIGSEGV. The Thread MUST be created on the persistent heap. This test mirrors
	// send_to_user_async's spawn discipline (context.allocator = heap before create)
	// and asserts the Thread does not live in the request arena.
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena, 64 * 1024) == nil)

	prev := context.allocator
	// Enter the request-arena context, exactly like an HTTP handler...
	context.allocator = virtual.arena_allocator(&arena)
	// ...then force the heap allocator before spawning, exactly like send_to_user_async.
	context.allocator = runtime.heap_allocator()
	th := thread.create_and_start_with_data(nil, async_thread_gate_entry, self_cleanup = false)
	context.allocator = prev

	testing.expect(t, th != nil)
	if th != nil {
		testing.expect(t, !ptr_in_arena(&arena, rawptr(th)),
			"async push Thread struct was allocated on the per-request arena (freed before the worker finishes -> UAF t.flags store)")
	}

	// Reproduce prod ordering: destroy the request arena while the worker is still
	// alive, THEN release it so the trampoline runs its post-proc bookkeeping.
	virtual.arena_destroy(&arena)
	sync.sema_post(&async_thread_gate)
	if th != nil {
		thread.destroy(th) // joins, then free(t, heap) — no leak, no double free
	}
}

@(test)
send_to_user_noop_when_disabled :: proc(t: ^testing.T) {
	// A service with no VAPID keypair must not attempt any delivery.
	repo: iface.Push_Repository
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	service := new_push_service(&repo, &clock, &ids) // empty Vapid_Config
	testing.expect(t, !push_send_enabled(&service))
	sent := send_to_user(&service, domain.User_ID("usr_1"), "{}")
	testing.expect_value(t, sent, 0)
}
