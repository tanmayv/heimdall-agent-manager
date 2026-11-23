package service

// The intent inbox (spec §10): <data>/supervisor/intents/inbox/<op_id>.json, scanned at
// start and every 2 s. Order per intent (J1/J30/J31/J35): journal line(s) first, then the
// op index (the engine writes it after every terminal line), then the file is deleted.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../engine"

INBOX_DIR :: "intents/inbox"

// Actions J25 still accepts while the instance is in rollback_failed.
ROLLBACK_FAILED_ACTIONS :: []string{"repair", "rollback_to_previous", "install_version", "cancel", "check_now"}

@(private)
Inbox_Entry :: struct {
	name:       string,
	path:       string,
	created_at: i64,
}

inbox_dir :: proc(s: ^Service) -> string {
	return sup_path(s, "intents", "inbox")
}

// scan_inbox handles every queued intent, oldest first.
scan_inbox :: proc(s: ^Service) -> (x: engine.Exit, err: engine.Error) {
	dir := inbox_dir(s)
	entries, rerr := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if rerr != nil do return .Run, nil
	list := make([dynamic]Inbox_Entry, context.temp_allocator)
	t := now(s)
	for ent in entries {
		if strings.has_prefix(ent.name, "bad-") {
			// J31: unparseable intents are kept 7 days for diagnosis, then GC'd.
			if t - ent.modification_time._nsec / 1_000_000_000 > BAD_INTENT_TTL_S {
				_ = os.remove(engine.join(dir, ent.name))
			}
			continue
		}
		if !strings.has_suffix(ent.name, ".json") || ent.type != .Regular do continue
		path := engine.join(dir, ent.name)
		data, ferr := os.read_entire_file(path, context.temp_allocator)
		if ferr != nil do continue
		it, st, _ := parse_intent(data)
		created := it.created_at if st == .Ok else 0
		append(&list, Inbox_Entry{ent.name, path, created})
	}
	slice.sort_by(list[:], proc(a, b: Inbox_Entry) -> bool {
		if a.created_at != b.created_at do return a.created_at < b.created_at
		return a.name < b.name
	})
	for ent in list {
		x, err = handle_intent_file(s, ent.path)
		if x != .Run || err != nil do return
		if stop_requested(s) do return
	}
	return .Run, nil
}

@(private)
move_bad :: proc(s: ^Service, path: string) {
	dir := inbox_dir(s)
	t := now(s)
	for i in 0 ..< 100 {
		name := fmt.tprintf("bad-%d.json", t) if i == 0 else fmt.tprintf("bad-%d-%d.json", t, i)
		dst := engine.join(dir, name)
		if os.exists(dst) do continue
		if os.rename(path, dst) == nil do return
		break
	}
	_ = os.remove(path)
}

@(private)
done_with :: proc(path: string) {
	_ = os.remove(path)
}

// handle_intent_file: one intent (§10 table and coalescing rules).
handle_intent_file :: proc(s: ^Service, path: string) -> (x: engine.Exit, err: engine.Error) {
	data, ferr := os.read_entire_file(path, context.temp_allocator)
	if ferr != nil do return .Run, nil
	it, st, schema_ok := parse_intent(data)
	if st == .Bad {
		move_bad(s, path)
		return .Run, nil
	}
	// J1/J31/J35 replay: the op already ran (terminal: index) or is running (a line exists).
	if in_index(s, it.op_id) || in_journal(s, it.op_id) {
		done_with(path)
		return .Run, nil
	}
	reason := validate_intent(it, schema_ok, s.instance.instance_id, now(s))
	if reason == "" && s.eng.phase == .Rollback_Failed {
		allowed := false
		for a in ROLLBACK_FAILED_ACTIONS do if a == it.action do allowed = true
		if !allowed do reason = "rollback_failed"
	}
	base := engine.Line{op_id = it.op_id, action = journal_action(it.action), actor = journal_actor(it.actor)}
	if reason != "" {
		// J31: a single terminal line.
		if err = put(s, terminal(base, "rejected", reason)); err != nil do return
		done_with(path)
		return .Run, nil
	}
	s.expires[strings.clone(it.op_id)] = it.expires_at

	if it.action == "cancel" do return accept_cancel(s, it, base, path)

	active, has_active := s.eng.active.?
	if has_active && engine.is_side_action(active.action) do has_active = false

	if is_config_action(it.action) || it.action == "check_now" {
		// Short ops: applied at once, beside an active op if there is one (§10).
		req := requested_line(s, it, base)
		if err = put(s, req); err != nil do return
		done_with(path)
		return drive_side(s, req)
	}

	// Installing actions.
	if has_active {
		if it.action == "update_now" && active.state == "waiting_for_idle" {
			// J30: the waiting op activates now; this intent is answered `noop superseded_by`.
			x, err = engine.interrupt(&s.eng, it.op_id, it.actor)
			if engine.error_code(err) == "no_op" {
				// The waiting op ended in its pre-gate check: run this intent on its own.
				err = nil
			} else {
				if err == nil || !engine.fatal(err) do done_with(path)
				if err != nil && !engine.fatal(err) {
					// bad_state: it moved on in between; answer busy like any install.
					err = put(s, busy_line(base, active.op_id))
				}
				return
			}
		} else {
			// §10: any other installing action while an op is active.
			if err = put(s, busy_line(base, active.op_id)); err != nil do return
			done_with(path)
			return .Run, nil
		}
	}
	if it.action == "rollback_to_previous" {
		// J28: the engine journals requested -> verifying -> verified and activates.
		x, err = engine.rollback_to_previous(&s.eng, it.op_id, base.actor)
		if err == nil || !engine.fatal(err) do done_with(path)
		return
	}
	req := requested_line(s, it, base)
	if err = put(s, req); err != nil do return
	done_with(path)
	return drive(s)
}

@(private)
busy_line :: proc(base: engine.Line, active_op: string) -> engine.Line {
	return terminal(base, "cancelled", "busy", fmt.tprintf("active_op %s", active_op))
}

// requested_line: the J1 line, carrying what the op needs after a crash (see ops.odin).
@(private)
requested_line :: proc(s: ^Service, it: Intent, base: engine.Line) -> engine.Line {
	l := base
	l.state = "requested"
	switch it.action {
	case "install_version", "retry_failed":
		_, v, _ := tag_version(it.version)
		l.to = engine.Ref{version = v}
	case "set_channel":
		l.note = fmt.tprintf("channel %s", it.channel)
	case "set_auto_update":
		val, given := it.auto_update.?
		if !given do val = !read_settings(s.opts.state_root).auto_update
		l.note = fmt.tprintf("auto_update %v", val)
	}
	return l
}

// accept_cancel (J35): rejections are a single line; otherwise cancel `requested` ->
// target `cancelled` (cancelled_by) -> cancel `applied` -> index -> file deleted.
@(private)
accept_cancel :: proc(s: ^Service, it: Intent, base: engine.Line, path: string) -> (x: engine.Exit, err: engine.Error) {
	active, has := s.eng.active.?
	if has && engine.is_side_action(active.action) do has = false
	code := ""
	switch {
	case !has:
		code = "nothing_to_cancel"
	case it.target_op_id != "" && it.target_op_id != active.op_id:
		code = "op_mismatch"
	case !cancellable(active.state):
		code = "past_point_of_no_return"
	}
	if code != "" {
		if err = put(s, terminal(base, "rejected", code)); err != nil do return
		done_with(path)
		return .Run, nil
	}
	req := base
	req.state = "requested"
	req.note = fmt.tprintf("target %s", active.op_id)
	if err = put(s, req); err != nil do return
	done_with(path)
	return finish_cancel(s, req)
}
