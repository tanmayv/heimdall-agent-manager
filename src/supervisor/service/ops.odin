package service

// The operation driver: everything from `requested` to `verified` (spec §6.2, §14, J1–J9,
// J27, J28, J35), then the engine's `activate` (gate, activation, handover).
//
// Durable fields an op needs after a crash ride on its own journal lines, because the
// intent file is deleted right after the `requested` line (J1):
//   install_version / retry_failed   `to.version` of the `requested` line
//   set_channel                      note "channel <stable|fast>"
//   set_auto_update                  note "auto_update <true|false>" (resolved at accept)
//   cancel                           note "target <op_id>"
// A resumed op in `downloading`/`verifying` reuses the `to.version` of that line instead of
// resolving again (J5, J6).

import "core:strings"
import lc "../../launcher/core"
import "../engine"
import "../fetch"
import "../resolver"

// drive advances the active op, if any, as far as it can go in this step. Side ops left
// non-terminal by a crash beside (or without) an installing op are finished first.
drive :: proc(s: ^Service) -> (x: engine.Exit, err: engine.Error) {
	// A side op left non-terminal by a crash beside an installing op (engine.pick_active):
	// finish it first; it never touches the active op except a cancel aimed at it.
	// engine.start drops a side op from `active`, so this is also how they resume.
	for l in engine.non_terminal_ops(&s.eng) {
		if !engine.is_side_action(l.action) do continue
		x, err = drive_side(s, l)
		if x != .Run || err != nil do return
	}
	op, ok := s.eng.active.?
	if !ok do return .Run, nil
	if engine.is_side_action(op.action) do return .Run, nil
	switch op.state {
	case "requested", "resolving", "downloading", "verifying":
		if expired(s, op) do return .Run, put(s, terminal(op, "expired"))
		switch op.action {
		case "rollback_to_previous":
			return run_local_rollback(s, op)
		case "update_now", "install_version", "repair":
			return run_install(s, op)
		case:
			return .Run, put(s, terminal(op, "failed", "unknown_action"))
		}
	case "verified":
		if expired(s, op) do return .Run, put(s, terminal(op, "expired"))
		if cancel_pending(s, op.op_id) do return .Run, nil // the inbox cancels it first
		return engine.activate(&s.eng)
	}
	return .Run, nil
}

// drive_side finishes a side op (check_now, set_channel, set_auto_update, retry_failed,
// cancel), whether it runs alone or beside the active op.
drive_side :: proc(s: ^Service, op: engine.Line) -> (x: engine.Exit, err: engine.Error) {
	if expired(s, op) {
		err = put(s, terminal(op, "expired"))
		end_side_op(s, op.op_id)
		return .Run, err
	}
	switch op.action {
	case "check_now":
		return run_check(s, op)
	case "cancel":
		return finish_cancel(s, op)
	}
	return finish_config(s, op)
}

// expired: J2/J26, only before `activating` and only for ops this process accepted.
@(private)
expired :: proc(s: ^Service, op: engine.Line) -> bool {
	at, ok := s.expires[op.op_id]
	return ok && at <= now(s)
}

// ---------------------------------------------------------------------------------------
// Installs: update_now (user or timer), install_version, repair
// ---------------------------------------------------------------------------------------

Install_Ctx :: struct {
	s:        ^Service,
	op:       engine.Line,
	verdict:  resolver.Verdict,
	code:     string, // noop / failed code from eligibility
	journal:  engine.Error, // a journal write inside a callback failed
	stopped:  bool, // service stop or a queued cancel: step back, no line (§7.5, §10)
}

@(private)
action_kind :: proc(op: engine.Line) -> resolver.Action {
	switch op.action {
	case "install_version":
		return .Install_Version
	case "repair":
		return .Repair
	}
	return .Timer if op.actor == "timer" else .Update_Now
}

@(private)
installed_id :: proc(s: ^Service) -> resolver.Release_Id {
	r, _ := engine.ref_of_tree(&s.eng, s.opts.launched)
	return resolver.Release_Id{version = r.version, sha256 = r.sha256}
}

// launcher_abi: <data>/launcher/launcher.json "abi"; missing = this build's ABI (Phase 1
// test roots have no installed launcher directory).
launcher_abi :: proc(s: ^Service) -> int {
	data, ok := lc.read_small_file(engine.join(s.opts.instance_root, "launcher", "launcher.json"), context.temp_allocator)
	if !ok do return lc.ABI
	if abi, found := json_int_field(data, "abi"); found do return int(abi)
	return lc.ABI
}

@(private)
eligible_cb :: proc(user: rawptr, m: ^fetch.Manifest) -> fetch.Error {
	c := (^Install_Ctx)(user)
	s := c.s
	pins := make([dynamic]resolver.Pin, context.temp_allocator)
	for p in engine.read_pins(&s.eng) do append(&pins, resolver.Pin{version = p.version, sha256 = p.sha256})
	offer := resolver.Offer {
		id = {version = m.version, sha256 = m.sha256, seq = 0},
		min_engine = int(m.min_engine),
		min_launcher_abi = int(m.min_launcher_abi),
	}
	c.verdict, c.code = resolver.check_eligibility(action_kind(c.op), installed_id(s), offer, pins[:], engine.ENGINE_VERSION, launcher_abi(s))
	if c.verdict != .Proceed do return fetch.Failure{code = .None, detail = "ineligible"}
	if stop_requested(s) || cancel_pending(s, c.op.op_id) {
		c.stopped = true
		return fetch.Failure{code = .Download_Failed, detail = "stepped back before the download"}
	}
	// J5: the line naming `to` precedes the bundle download.
	l := next_state(c.op, "downloading")
	l.to = engine.Ref{version = m.version, sha256 = m.sha256, tree = fetch.tree_base_name(m)}
	if err := put(s, l); err != nil {
		c.journal = err
		return fetch.Failure{code = .Fs_Error, detail = "journal"}
	}
	c.op = l
	return nil
}

@(private)
bundle_ready_cb :: proc(user: rawptr, m: ^fetch.Manifest) -> fetch.Error {
	c := (^Install_Ctx)(user)
	if stop_requested(c.s) || cancel_pending(c.s, c.op.op_id) {
		c.stopped = true
		return fetch.Failure{code = .Download_Failed, detail = "service stop"}
	}
	l := next_state(c.op, "verifying")
	if err := put(c.s, l); err != nil {
		c.journal = err
		return fetch.Failure{code = .Fs_Error, detail = "journal"}
	}
	c.op = l
	return nil
}

run_install :: proc(s: ^Service, op0: engine.Line) -> (x: engine.Exit, err: engine.Error) {
	op := op0
	tag, asset: string
	switch {
	case (op.state == "downloading" || op.state == "verifying") && op.to.version != "":
		// J5/J6: resume the download of the release the line names.
		tag = strings.concatenate({"v", op.to.version}, context.temp_allocator)
	case op.action == "install_version":
		ok: bool
		tag, _, ok = tag_version(op.to.version)
		if !ok do return .Run, put(s, terminal(op, "failed", "bad_version"))
	case op.action == "repair":
		// §16: the release of known-good (or, without one, of the running tree).
		base := engine.known_good_valid(&s.eng)
		if base == "" do base = s.opts.launched
		r, ok := engine.ref_of_tree(&s.eng, base)
		if !ok do return .Run, put(s, terminal(op, "failed", "no_known_good"))
		tag = strings.concatenate({"v", r.version}, context.temp_allocator)
	}

	if op.state == "requested" {
		op = next_state(op, "resolving")
		if err = put(s, op); err != nil do return
	}
	if tag == "" {
		// update_now (user or timer): resolve per channel (§13.1).
		res := resolve(s)
		if op.actor == "timer" {
			resolver.schedule_after(&s.cache, res, now(s), rand01(s))
			save_cache(s)
		}
		if stop_requested(s) do return .Run, nil // §7.5: abort, no line
		switch res.status {
		case .Incomplete:
			return .Run, put(s, terminal(op, "failed", "resolve_incomplete"))
		case .No_Candidate:
			return .Run, put(s, terminal(op, "noop", "", "no_candidate"))
		case .Candidate:
		}
		cand := res.candidate
		// Rule 3 without downloading the manifest: never a silent downgrade.
		if resolver.semver_compare_strings(cand.version, installed_id(s).version) < 0 {
			return .Run, put(s, terminal(op, "noop", "", "ahead_of_channel"))
		}
		tag = strings.clone(cand.tag, context.temp_allocator)
		asset = strings.clone(cand.bundle.name, context.temp_allocator)
	}
	if asset == "" do asset = resolver.bundle_asset_name(target(s), tag, context.temp_allocator)

	ctx := Install_Ctx{s = s, op = op}
	in_ := fetch.default_prepare_input()
	in_.instance_root = s.opts.instance_root
	in_.op_id = op.op_id
	in_.tag = tag
	in_.expected_asset = asset
	in_.downloader = s.opts.net.download
	in_.verify.target = target(s)
	in_.verify.now = now(s)
	in_.verify.check_expiry = true
	in_.verify.pins = s.opts.key_pins
	in_.eligible = eligible_cb
	in_.bundle_ready = bundle_ready_cb
	in_.eligible_user = &ctx
	in_.live = live_trees(s)
	in_.os_policy = s.opts.os_policy
	if s.opts.preflight_timeout_ms > 0 do in_.preflight_timeout_ms = s.opts.preflight_timeout_ms
	if s.opts.retry.budget_ms > 0 do in_.retry = s.opts.retry
	prepared, perr := fetch.prepare_release(in_, context.temp_allocator)
	if ctx.journal != nil do return .Run, ctx.journal
	op = ctx.op
	if perr != nil {
		if ctx.stopped || stop_requested(s) do return .Run, nil // §7.5: abort, no line
		switch ctx.verdict {
		case .Noop:
			return .Run, put(s, terminal(op, "noop", "", ctx.code))
		case .Failed:
			return .Run, put(s, terminal(op, "failed", ctx.code))
		case .Proceed:
		}
		logf(s, "op %s: %s", op.op_id, fetch.error_detail(perr))
		return .Run, put(s, terminal(op, "failed", fetch.code_name(fetch.error_code(perr))))
	}
	m := prepared.manifest
	to := engine.Ref{version = m.version, sha256 = m.sha256, tree = prepared.tree}
	if err = engine.mark_verified(&s.eng, to); err != nil do return
	if stop_requested(s) do return .Run, nil // §7.5: verified, no line; resumed at next start
	if cancel_pending(s, op.op_id) do return .Run, nil // §10: the inbox cancels it first
	return engine.activate(&s.eng)
}

// resolve runs §13.1 for the configured channel and persists the cache.
resolve :: proc(s: ^Service) -> resolver.Result {
	st := read_settings(s.opts.state_root)
	ch := resolver.Channel.Fast if st.channel == "fast" else resolver.Channel.Stable
	res := resolver.resolve(ch, target(s), &s.cache, s.opts.net.get, s.opts.net.get_user, now(s), context.temp_allocator)
	save_cache(s)
	return res
}

// check_now: requested -> resolving -> noop (with the available candidate) or failed.
run_check :: proc(s: ^Service, op0: engine.Line) -> (x: engine.Exit, err: engine.Error) {
	op := op0
	if op.state == "requested" {
		op = next_state(op, "resolving")
		if err = put(s, op); err != nil do return
	}
	res := resolve(s)
	if stop_requested(s) do return .Run, nil
	t: engine.Line
	switch res.status {
	case .Incomplete:
		t = terminal(op, "failed", "resolve_incomplete")
	case .No_Candidate:
		t = terminal(op, "noop", "", "no_candidate")
	case .Candidate:
		cmp := resolver.semver_compare_strings(res.candidate.version, installed_id(s).version)
		t = terminal(op, "noop", "", "available" if cmp > 0 else ("up_to_date" if cmp == 0 else "ahead_of_channel"))
		t.to = engine.Ref{version = res.candidate.version}
	}
	err = put(s, t)
	end_side_op(s, op.op_id)
	return
}

// rollback_to_previous resumed after a crash in requested/verifying (J28): rerun the
// read-only check, then the normal activation.
run_local_rollback :: proc(s: ^Service, op0: engine.Line) -> (x: engine.Exit, err: engine.Error) {
	op := op0
	if op.state == "requested" {
		op = next_state(op, "verifying")
		if err = put(s, op); err != nil do return
	}
	P := engine.previous_valid(&s.eng)
	C := engine.current_valid(&s.eng)
	if P == "" || P == C do return .Run, put(s, terminal(op, "failed", "no_previous"))
	if fetch.tree_check_sizes(engine.join(s.opts.instance_root, "releases", P)) != nil {
		return .Run, put(s, terminal(op, "failed", "tree_damaged"))
	}
	to, _ := engine.ref_of_tree(&s.eng, P)
	if err = engine.mark_verified(&s.eng, to); err != nil do return
	return engine.activate(&s.eng)
}

// ---------------------------------------------------------------------------------------
// Configuration ops (J27) and cancel (J35)
// ---------------------------------------------------------------------------------------

@(private)
note_value :: proc(note, key: string) -> string {
	prefix := strings.concatenate({key, " "}, context.temp_allocator)
	return note[len(prefix):] if strings.has_prefix(note, prefix) else ""
}

finish_config :: proc(s: ^Service, op: engine.Line) -> (x: engine.Exit, err: engine.Error) {
	switch op.action {
	case "set_channel", "set_auto_update":
		st := read_settings(s.opts.state_root)
		if st.last_op != op.op_id {
			if op.action == "set_channel" {
				st.channel = note_value(op.note, "channel")
				st.revision += 1 // only when the file is written for this op (J27)
			} else {
				st.auto_update = note_value(op.note, "auto_update") == "true"
			}
			st.actor = op.actor
			st.updated_at = now(s)
			st.last_op = op.op_id
			if err = write_settings(s.opts.state_root, st, s.eng.cfg.retry); err != nil do return
		}
	case "retry_failed":
		// Removing a pin is idempotent, so a replay needs no last_op marker.
		_, v, _ := tag_version(op.to.version)
		if err = engine.remove_pin(&s.eng, v, op.op_id); err != nil do return
	}
	err = put(s, terminal(op, "applied"))
	end_side_op(s, op.op_id)
	return
}

@(private)
cancellable :: proc(state: string) -> bool {
	switch state {
	case "requested", "resolving", "downloading", "verifying", "verified", "waiting_for_idle":
		return true
	}
	return false
}

// finish_cancel: a cancel op found non-terminal after a restart (J35 crash rows).
finish_cancel :: proc(s: ^Service, op: engine.Line) -> (x: engine.Exit, err: engine.Error) {
	target_id := note_value(op.note, "target")
	for l in engine.journal_lines(&s.eng) {
		if l.cancelled_by == op.op_id {
			// The target's `cancelled` line landed: finish the cancel op.
			err = put(s, terminal(op, "applied"))
			end_side_op(s, op.op_id)
			return
		}
	}
	// The target is the installing op beside it (pick_active never picks the cancel while
	// one exists); a cancel that is itself the active op has nothing left to cancel.
	tgt, has := s.eng.active.?
	if has && tgt.op_id == op.op_id do has = false
	code := ""
	switch {
	case !has || tgt.op_id != target_id:
		code = "nothing_to_cancel"
	case !cancellable(tgt.state):
		code = "past_point_of_no_return"
	}
	if code == "" {
		if err = engine.cancel_active(&s.eng, op.op_id, target_id); err != nil && engine.fatal(err) do return
		if err != nil do code = engine.error_code(err)
	}
	err = put(s, terminal(op, "rejected" if code != "" else "applied", code))
	end_side_op(s, op.op_id)
	return
}

// end_side_op: after a side op (one that ran beside an active op, or a short op on its
// own) is terminal, restore the engine's view of the active op from the journal.
end_side_op :: proc(s: ^Service, op_id: string) {
	engine.reload_active(&s.eng)
}
