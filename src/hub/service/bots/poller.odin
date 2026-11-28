package bots

import "core:fmt"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"

// Map inbound rows and run side effects only after the cursor commits. The
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
	now := platform.clock_now(s.clock)
	rows: []domain.Channel_Message
	inserted: []string
	store_err: domain.Domain_Error
	{
		sync.mutex_lock(&s.mutex)
		defer sync.mutex_unlock(&s.mutex)
		map_err: domain.Domain_Error
		rows, map_err = bots_inbound_rows(s, s.adapter, batch, now)
		if map_err.code != .None do return 5 * time.Second, false
		inserted, store_err = iface.inbound_store_batch(s.repo, "telegram", rows, next, now)
	}
	defer {
		for id in inserted do delete(id)
		delete(inserted)
	}
	if store_err.code != .None {
		fmt.eprintln("bots: telegram batch commit failed")
		return 5 * time.Second, false
	}
	for update in batch {
		if e := bots_inbound_side_effect(s, s.adapter, update, now); e.code != .None do fmt.eprintf("bots: inbound side effect code=%v\n", e.code)
	}
	seen := make(map[string]bool, context.temp_allocator)
	for row in rows {
		new_row := false
		for id in inserted do if id == row.message_id do new_row = true
		if !new_row || seen[row.bot_id] do continue
		seen[row.bot_id] = true
		bots_publish_changed(s, row.owner_user_id, row.bot_id)
		fresh := make([dynamic]domain.Channel_Message, context.temp_allocator)
		for candidate in rows {
			if candidate.bot_id != row.bot_id do continue
			for id in inserted do if id == candidate.message_id {append(&fresh, candidate); break}
		}
		ms, _ := platform.rfc3339_to_unix_ms(now)
		if e := delivery_on_inbound(s, row.bot_id, ms, fresh[:]); e.code != .None do fmt.eprintf("bots: inbound delivery code=%v\n", e.code)
	}
	return 0, false
}
