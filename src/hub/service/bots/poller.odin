package bots

import "core:fmt"
import "core:sync"
import "core:time"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"

// A5 replaces the empty row mapping and adds post-commit side effects. The
// repository cursor stays authoritative: never poll next before storing it.
bots_poller_thread :: proc(rt: ^Bots_Runtime) {
	backoff: time.Duration = time.Second
	for !sync.atomic_load(&rt.poller_stop) {
		delay, aborted := bots_poller_iteration(rt, &backoff)
		free_all(context.temp_allocator)
		if aborted || bots_runtime_wait(rt, &rt.poller_stop, delay) do return
	}
}

bots_poller_iteration :: proc(rt: ^Bots_Runtime, backoff: ^time.Duration) -> (time.Duration, bool) {
	s := rt.service
	a := s.adapter
	_, identity_err := a.identity(a.ctx)
	if identity_err.kind != .None {
		fmt.eprintf("bots: telegram identity kind=%v\n", identity_err.kind)
		return 30 * time.Second, false
	}
	cursor, _, cursor_err := iface.cursor_get(s.repo, "telegram")
	defer delete(cursor)
	if cursor_err.code != .None {
		fmt.eprintln("bots: telegram cursor read failed")
		return 5 * time.Second, false
	}
	batch, next, err := a.poll(a.ctx, cursor, &rt.poller_stop)
	defer channel.inbound_destroy_batch(batch)
	defer delete(next)
	if err.kind == .Aborted do return 0, true
	if err.kind == .Unauthorized {
		fmt.eprintln("telegram: token rejected")
		return 300 * time.Second, false
	}
	if err.kind != .None {
		fmt.eprintf("bots: telegram poll kind=%v\n", err.kind)
		wait := backoff^
		backoff^ = min(backoff^ * 2, 60 * time.Second)
		return wait, false
	}
	backoff^ = time.Second
	for update in batch do fmt.eprintf("bots: telegram update kind=%v\n", update.kind)
	// A4 deliberately commits only the cursor, with no inbound rows.
	inserted, store_err := iface.inbound_store_batch(s.repo, "telegram", {}, next, platform.clock_now(s.clock))
	defer {
		for id in inserted do delete(id)
		delete(inserted)
	}
	if store_err.code != .None {
		fmt.eprintln("bots: telegram batch commit failed")
		return 5 * time.Second, false
	}
	return 0, false
}
