package service

// Timer (§13.3) and garbage collection (§15).

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../engine"
import "../fetch"
import "../resolver"

// timer starts a timer op (`update_now`, actor `timer`) when the cadence says so, the
// instance is idle and auto_update is on. `auto_update: false` disables only this.
timer :: proc(s: ^Service) -> (x: engine.Exit, err: engine.Error) {
	if s.eng.phase != .Idle do return .Run, nil
	if _, active := s.eng.active.?; active do return .Run, nil
	t := now(s)
	if !resolver.check_due(s.cache, t) do return .Run, nil
	if !read_settings(s.opts.state_root).auto_update {
		s.cache.next_check_at = t + resolver.CHECK_INTERVAL
		save_cache(s)
		return .Run, nil
	}
	req := engine.Line {
		op_id  = fmt.tprintf("op_timer_%d_%d", t, s.eng.last_seq + 1),
		action = "update_now",
		actor  = "timer",
		state  = "requested",
	}
	if err = put(s, req); err != nil do return
	return drive(s)
}

@(private)
Tree_Dir :: struct {
	name:  string,
	mtime: i64,
}

// gc (§15): delete non-live trees beyond TREES_KEPT (oldest first), incomplete non-live
// trees, `.staging-*` of ops that are not active, `.trash-*`, `downloads/*` of terminal ops
// and every snapshot of a terminal op but the latest. Every delete follows W5: a failure
// leaves the directory for the next start. Best effort, never an error.
gc :: proc(s: ^Service) {
	live := live_trees(s)
	active_ids := make([dynamic]string, context.temp_allocator)
	for l in engine.non_terminal_ops(&s.eng) do append(&active_ids, l.op_id)
	is_live :: proc(live: []string, name: string) -> bool {
		for t in live do if t == name do return true
		return false
	}
	is_active :: proc(ids: []string, id: string) -> bool {
		for a in ids do if a == id do return true
		return false
	}
	releases := engine.join(s.opts.instance_root, "releases")
	op_tag := fmt.tprintf("gc%d", now(s))
	entries, _ := os.read_directory_by_path(releases, -1, context.temp_allocator)
	trees := make([dynamic]Tree_Dir, context.temp_allocator)
	total := 0
	for ent in entries {
		if ent.type != .Directory do continue
		name := ent.name
		switch {
		case strings.has_prefix(name, ".trash-"):
			_ = os.remove_all(engine.join(releases, name))
		case strings.has_prefix(name, ".staging-"):
			if !is_active(active_ids[:], name[len(".staging-"):]) do _ = os.remove_all(engine.join(releases, name))
		case strings.has_prefix(name, "."):
		case:
			total += 1
			if is_live(live, name) do continue
			if !os.exists(engine.join(releases, name, ".complete")) {
				// Half-built and not live (W2/W5): never valid, delete.
				if fetch.remove_tree(releases, name, op_tag, gc_retry()) == nil do total -= 1
				continue
			}
			append(&trees, Tree_Dir{name, ent.modification_time._nsec})
		}
	}
	slice.sort_by(trees[:], proc(a, b: Tree_Dir) -> bool {return a.mtime < b.mtime})
	for t in trees {
		if total <= TREES_KEPT do break
		if fetch.remove_tree(releases, t.name, op_tag, gc_retry()) == nil {
			total -= 1
			logf(s, "gc: removed release tree %s", t.name)
		}
	}

	downloads := sup_path(s, "downloads")
	if dl, derr := os.read_directory_by_path(downloads, -1, context.temp_allocator); derr == nil {
		for ent in dl do if !is_active(active_ids[:], ent.name) do _ = os.remove_all(engine.join(downloads, ent.name))
	}

	snapshots := sup_path(s, "snapshots")
	if sn, serr := os.read_directory_by_path(snapshots, -1, context.temp_allocator); serr == nil {
		latest := ""
		latest_t: i64 = -1
		for ent in sn {
			if is_active(active_ids[:], ent.name) do continue
			if ent.modification_time._nsec > latest_t {
				latest_t = ent.modification_time._nsec
				latest = ent.name
			}
		}
		for ent in sn {
			if ent.name == latest || is_active(active_ids[:], ent.name) do continue
			_ = os.remove_all(engine.join(snapshots, ent.name))
		}
	}
}

// gc_retry: GC never waits out the full W3 budget; a busy tree is retried at the next start.
@(private)
gc_retry :: proc() -> fetch.Retry_Policy {
	p := fetch.DEFAULT_RETRY
	p.budget_ms = 2_000
	return p
}
