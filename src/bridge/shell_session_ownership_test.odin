package main

// REQ-SHELL-11: the session map's ownership rule, asserted rather than documented.
//
// WHAT THIS FILE IS FOR. bridge_shell_session_register used to LEAK the strings it
// superseded, because every getter returned Bridge_Shell_Session by value and so
// handed out borrowed pointers into the stored allocation. The getters now clone,
// register frees, and these tests are what keep that true.
//
// WHY THE ASSERTIONS ARE ON POINTERS, NOT BYTES. A value check ("the holder still
// sees the right shell_id") is GREEN OVER THE VERY BUG IT IS MEANT TO CATCH: freed
// memory usually still holds the right bytes, so a borrowed read passes. This chain
// already hit exactly that on REQ-SHELL-2, where the value reads passed over a real
// use-after-free and only pointer-identity told the truth. So the primary assertion
// is raw_data(held) != raw_data(stored): a borrowed string IS the stored pointer, so
// that comparison cannot pass unless the clone is real. Byte equality is kept as the
// secondary check — the pointer proves it is a clone, the bytes prove it is a correct
// one.
//
// Every test here stands up its OWN Bridge_Shell_Session_Map on a
// mem.Tracking_Allocator rather than touching the process-wide map, which gives the
// negative half for free: a double free or an allocator mismatch shows up as
// bad_free_array, and a leak as a non-empty allocation_map. Precedent for the idiom
// is artifact_repo_test.odin's test_artifact_repo_sqlite_tracking_allocator.

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// _ownership_session builds a session whose strings all come from `m`'s allocator,
// which is what register requires of its caller.
@(private = "file")
_ownership_session :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, shell_id: string, status: Bridge_Shell_Session_Status, pid: int) -> Bridge_Shell_Session {
	a := bridge_shell_session_map_allocator(m)
	return Bridge_Shell_Session{
		session_id = strings.clone(session_id, a),
		kind       = .Run,
		cmd        = strings.clone("sleep 600", a),
		cwd        = strings.clone("/tmp", a),
		bridge_id  = strings.clone("brg_own", a),
		label      = strings.clone("ownership", a),
		status     = status,
		pid        = pid,
		shell_id   = strings.clone(shell_id, a),
		started_at = strings.clone("2026-09-28T09:00:00Z", a),
		pty_host   = true,
		pty_host_provenance_known = true,
	}
}

// AC2/AC3, the core assertion: what a reader holds is NOT the map's memory.
//
// It checks all three read shapes, because a single borrowing exit reintroduces the
// whole problem: the narrow shell_id accessor, the full snapshot, and the list
// snapshot. The scalar accessor needs no check — it copies no pointers at all, which
// is precisely why it is the one to prefer.
@(test)
bridge_shell11_reads_never_alias_map_memory :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m := Bridge_Shell_Session_Map{allocator = mem.tracking_allocator(&track)}
	defer bridge_shell_session_map_destroy(&m)

	sess := _ownership_session(&m, "sh_alias", "sh_alias", .Running, 111)
	bridge_shell_session_register(&m, &sess)

	// The pointer the map itself holds. Read under the lock, never handed out.
	stored_shell_id: string
	stored_cmd: string
	sync.mutex_lock(&m.mu)
	if s, ok := m.sessions["sh_alias"]; ok {
		stored_shell_id = s.shell_id
		stored_cmd      = s.cmd
	}
	sync.mutex_unlock(&m.mu)
	testing.expect(t, stored_shell_id != "", "the session is registered")

	// 1. the narrow accessor
	key, have_key := bridge_shell_session_shell_id(&m, "sh_alias")
	testing.expect(t, have_key, "the daemon key is readable")
	testing.expect(t, raw_data(key) != raw_data(stored_shell_id),
		"bridge_shell_session_shell_id returns a CLONE, not a pointer into the map entry")
	testing.expect_value(t, key, stored_shell_id) // secondary: the clone is correct
	bridge_shell_session_str_delete(&m, key)

	// 2. the full snapshot
	snap, have_snap := bridge_shell_session_snapshot(&m, "sh_alias")
	testing.expect(t, have_snap, "the snapshot is readable")
	testing.expect(t, raw_data(snap.shell_id) != raw_data(stored_shell_id),
		"a snapshot's shell_id is a clone")
	testing.expect(t, raw_data(snap.cmd) != raw_data(stored_cmd),
		"and so is every other string field — cmd checked as the second witness")
	testing.expect_value(t, snap.cmd, stored_cmd)
	bridge_shell_session_snapshot_destroy(&m, snap)

	// 3. the list snapshot — the exit that used to copy structs into a slice and hand
	//    out twelve borrowed pointers per entry.
	list := bridge_shell_session_list_snapshot(&m)
	testing.expect_value(t, len(list), 1)
	testing.expect(t, raw_data(list[0].shell_id) != raw_data(stored_shell_id),
		"a listed session's strings are clones too")
	testing.expect(t, raw_data(list[0].cmd) != raw_data(stored_cmd), "cmd included")
	bridge_shell_session_list_destroy(&m, list)

	// 4. the by-shell-id lookup
	by_shell, have_by_shell := bridge_shell_session_snapshot_by_shell_id(&m, "sh_alias")
	testing.expect(t, have_by_shell, "the by-shell-id lookup finds it")
	testing.expect(t, raw_data(by_shell.shell_id) != raw_data(stored_shell_id),
		"and clones as well")
	bridge_shell_session_snapshot_destroy(&m, by_shell)

	testing.expect_value(t, len(track.bad_free_array), 0)
}

// AC1: replacing an entry FREES the superseded strings. Measured as live bytes, not
// as an absence of crashes — the leak this task exists to end was invisible except
// as growth.
//
// Also covers the delete_key-then-insert guard: the map key aliased the OLD entry's
// session_id, and Odin keeps the existing key when assigning to an occupied slot, so
// a plain assignment plus a free would have left the map keyed by freed memory. If
// that guard were missing, the lookup after the replace would read a dangling key and
// the tracking allocator would report the mismatch.
@(test)
bridge_shell11_register_frees_superseded_strings :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m := Bridge_Shell_Session_Map{allocator = mem.tracking_allocator(&track)}
	defer bridge_shell_session_map_destroy(&m)

	sess := _ownership_session(&m, "sh_replace", "sh_replace", .Running, 1)
	bridge_shell_session_register(&m, &sess)
	after_first := track.current_memory_allocated

	// Twenty replacements of the SAME key, each with a fresh string set — which is
	// exactly the reconcile survivor path the old comment bounded at "one string set
	// per session per hub WS reconnect".
	for i in 0 ..< 20 {
		sess := _ownership_session(&m, "sh_replace", "sh_replace", .Running, i + 2)
		bridge_shell_session_register(&m, &sess)
	}
	after_replacements := track.current_memory_allocated

	testing.expect_value(t, after_replacements, after_first)
	if after_replacements != after_first {
		fmt.printfln("live bytes after 1 register: %d, after 21: %d (delta %d)",
			after_first, after_replacements, after_replacements - after_first)
	}
	testing.expect_value(t, len(m.sessions), 1)

	// The key still resolves, i.e. it is not the freed allocation from the first
	// register (the delete_key-then-insert guard).
	sc, ok := bridge_shell_session_scalars(&m, "sh_replace")
	testing.expect(t, ok, "the replaced session is still findable by its id")
	testing.expect_value(t, sc.pid, 21)

	testing.expect_value(t, len(track.bad_free_array), 0)
}

// AC1 guard 2: a re-register that ALIASES a stored string must not free memory the
// new entry still holds. Nothing in the tree does this today — every getter clones —
// but the guard is what keeps a future caller from turning it into a double free,
// and an untested guard is a guess.
@(test)
bridge_shell11_aliasing_reregister_is_not_a_double_free :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m := Bridge_Shell_Session_Map{allocator = mem.tracking_allocator(&track)}
	defer bridge_shell_session_map_destroy(&m)

	sess := _ownership_session(&m, "sh_alias2", "sh_alias2", .Running, 7)
	bridge_shell_session_register(&m, &sess)

	// Deliberately re-register a struct that SHARES the stored allocations, the shape
	// the old by-value getter produced on every call.
	aliased: Bridge_Shell_Session
	sync.mutex_lock(&m.mu)
	aliased = m.sessions["sh_alias2"]
	sync.mutex_unlock(&m.mu)
	aliased.status = .Killed
	bridge_shell_session_register(&m, &aliased)

	sc, ok := bridge_shell_session_scalars(&m, "sh_alias2")
	testing.expect(t, ok, "the session survives an aliasing re-register")
	testing.expect(t, sc.status == .Killed, "and carries the new status")

	// The strings are still live and still correct — not freed out from under the
	// entry that now owns them.
	snap, have := bridge_shell_session_snapshot(&m, "sh_alias2")
	testing.expect(t, have)
	testing.expect_value(t, snap.cmd, "sleep 600")
	testing.expect_value(t, snap.shell_id, "sh_alias2")
	bridge_shell_session_snapshot_destroy(&m, snap)

	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(private = "file")
Churn_Ctx :: struct {
	m:        ^Bridge_Shell_Session_Map,
	rounds:   int,
	stop:     bool,
	// held_intact records whether every read the reader thread held across a
	// simulated blocking call still matched its own bytes afterwards.
	held_intact:  bool,
	// held_aliased records whether any read ever handed back the map's own pointer.
	held_aliased: bool,
	reads:    int,
}

// _churn_rereg_worker replays the reconcile survivor path: the SAME session_id
// re-registered again and again from another thread, with a fresh string set each
// time, which is what frees the previous set.
@(private = "file")
_churn_rereg_worker :: proc(data: rawptr) {
	ctx := (^Churn_Ctx)(data)
	for i in 0 ..< ctx.rounds {
		sess := _ownership_session(ctx.m, "sh_race", "sh_race", .Running, i + 1)
		bridge_shell_session_register(ctx.m, &sess)
		time.sleep(50 * time.Microsecond)
	}
	ctx.stop = true
}

// AC3: the window the OLD COMMENT NAMED BY NAME — the kill/signal handlers reading
// sess.shell_id across a bridge_pty_host_ensure_daemon call that can block for up to
// 5s, while reconcile re-registers the same session from another thread.
//
// The daemon call is stood in for by a sleep, deliberately: what is under test is the
// OWNERSHIP of the string across a blocking gap, not the pty-host protocol. Making it
// a real daemon call would add a dependency on a running daemon to a test about
// memory.
//
// The assertions are, in order of what they actually prove:
//   1. the held string is NOT the map's pointer (this is the one that catches the bug)
//   2. it still reads correctly AFTER the concurrent re-registers (the clone is intact)
//   3. zero bad frees across the whole race (no double free, no allocator mismatch)
@(test)
bridge_shell11_kill_path_key_survives_concurrent_reregister :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m := Bridge_Shell_Session_Map{allocator = mem.tracking_allocator(&track)}
	defer bridge_shell_session_map_destroy(&m)

	sess := _ownership_session(&m, "sh_race", "sh_race", .Running, 1)
	bridge_shell_session_register(&m, &sess)

	ctx := Churn_Ctx{m = &m, rounds = 200, held_intact = true, held_aliased = false}
	th := thread.create_and_start_with_data(rawptr(&ctx), _churn_rereg_worker)
	defer thread.destroy(th)

	// The reader plays bridge_hub_handle_shell_kill: take the daemon key, then block
	// as bridge_pty_host_ensure_daemon would, then use it.
	for !ctx.stop {
		key, ok := bridge_shell_session_shell_id(&m, "sh_race")
		if !ok do continue

		// Is this the map's own pointer? Under the old by-value getter it would be.
		sync.mutex_lock(&m.mu)
		if s, has := m.sessions["sh_race"]; has {
			if raw_data(key) == raw_data(s.shell_id) do ctx.held_aliased = true
		}
		sync.mutex_unlock(&m.mu)

		// THE WINDOW. Re-registers land here, freeing the string set this key would
		// have pointed into.
		time.sleep(200 * time.Microsecond)

		if key != "sh_race" do ctx.held_intact = false
		ctx.reads += 1
		bridge_shell_session_str_delete(&m, key)
	}
	thread.join(th)

	testing.expect(t, ctx.reads > 0, "the reader actually got reads in during the churn")
	testing.expect(t, !ctx.held_aliased,
		"the daemon key handed to the kill path is NEVER the map's own pointer — this is the assertion the old borrow fails")
	testing.expect(t, ctx.held_intact,
		"and it still reads correctly after the concurrent re-registers freed the entry it was cloned from")
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect_value(t, len(m.sessions), 1)
}

// ---- THE WRITE SIDE (REQ-SHELL-11 review) ---------------------------------
//
// The read-side race test above passed over a real defect, because it only ever
// exercised the ACCESSORS. Handing a struct to register and then reading it again is
// the same borrow with the roles swapped, and it is the more dangerous half: the
// hazard is not this register freeing your strings, it is the NEXT register of the
// same session_id making your just-handed-over set the superseded one.

// register CONSUMES its argument: the caller's copy is zeroed, so a post-register read
// fails loudly (empty id, zero status) instead of silently reading memory another
// thread may have freed. This is the structural half of the fix — asserted, because a
// guarantee nothing checks is a comment.
@(test)
bridge_shell11_register_consumes_its_argument :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m := Bridge_Shell_Session_Map{allocator = mem.tracking_allocator(&track)}
	defer bridge_shell_session_map_destroy(&m)

	sess := _ownership_session(&m, "sh_consumed", "sh_consumed", .Running, 99)
	bridge_shell_session_register(&m, &sess)

	testing.expect_value(t, sess.session_id, "")
	testing.expect_value(t, sess.shell_id, "")
	testing.expect_value(t, sess.cmd, "")
	testing.expect_value(t, sess.pid, 0)
	testing.expect(t, sess.status == .Starting, "and the status is the zero value, not the registered one")

	// The session really did land, i.e. zeroing the caller's copy did not zero the entry.
	sc, ok := bridge_shell_session_scalars(&m, "sh_consumed")
	testing.expect(t, ok, "the session is in the map")
	testing.expect_value(t, sc.pid, 99)

	// Replacing takes the other branch of register (delete_key + free_superseded), which
	// returns early — the zeroing must happen there too.
	again := _ownership_session(&m, "sh_consumed", "sh_consumed", .Killed, 100)
	bridge_shell_session_register(&m, &again)
	testing.expect_value(t, again.session_id, "")
	testing.expect_value(t, again.pid, 0)

	testing.expect_value(t, len(track.bad_free_array), 0)
}

// WHY THE ZEROING IS NOT ENOUGH ON ITS OWN, pinned down so nobody relies on it.
//
// The reconcile shape is `updated := s` — a copy taken BEFORE the call, sharing every
// string with `s`. register zeroes `updated`; `s` still points at the same data, which
// the map now owns. This test asserts that alias EXISTS (so the danger is real and not
// theoretical) and that cloning the id first — what the two reconcile paths now do —
// produces a pointer the map cannot free.
@(test)
bridge_shell11_precall_copy_still_aliases_so_reconcile_clones_first :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m := Bridge_Shell_Session_Map{allocator = mem.tracking_allocator(&track)}
	defer bridge_shell_session_map_destroy(&m)

	spec := _ownership_session(&m, "sh_precopy", "sh_precopy", .Running, 5)

	// What the reconcile paths do FIRST, and the whole point of doing it:
	sid := strings.clone(spec.session_id, bridge_shell_session_map_allocator(&m))
	defer delete(sid, bridge_shell_session_map_allocator(&m))

	updated := spec // the aliasing copy
	updated.status = .Failed
	bridge_shell_session_register(&m, &updated)

	// The pre-call copy is NOT protected by the zeroing — it still holds the map's pointer.
	sync.mutex_lock(&m.mu)
	stored := m.sessions["sh_precopy"]
	sync.mutex_unlock(&m.mu)
	testing.expect(t, raw_data(spec.session_id) == raw_data(stored.session_id),
		"the pre-call copy DOES alias map memory — this is why zeroing register's argument is not sufficient")

	// The clone taken beforehand does not, which is what makes delete_spec /
	// wait_signal_exit / the event json safe on those paths.
	testing.expect(t, raw_data(sid) != raw_data(stored.session_id),
		"the id cloned before register is independent of the map")
	testing.expect_value(t, sid, "sh_precopy")

	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(private = "file")
Writer_Race_Ctx :: struct {
	m:            ^Bridge_Shell_Session_Map,
	rounds:       int,
	stop:         bool,
	held_aliased: bool,
	held_intact:  bool,
	reads:        int,
}

// _writer_race_rereg_worker is the OTHER writer — the one that turns a
// just-registered string set into the superseded one and frees it.
@(private = "file")
_writer_race_rereg_worker :: proc(data: rawptr) {
	ctx := (^Writer_Race_Ctx)(data)
	for i in 0 ..< ctx.rounds {
		sess := _ownership_session(ctx.m, "sh_wrace", "sh_wrace", .Running, i + 1)
		bridge_shell_session_register(ctx.m, &sess)
		time.sleep(50 * time.Microsecond)
	}
	ctx.stop = true
}

// THE WRITE-SIDE RACE, asserted the way AC3 is: pointer identity plus zero bad frees.
//
// The reader plays the reconcile orphan path exactly as it is now written — clone the
// id, register the session, then use the clone for delete_spec / wait_signal_exit / the
// event json — while another thread re-registers the SAME session_id and frees what the
// reader just handed over. Before the fix the reader used s.session_id there, which is
// the map's pointer; the clone is what makes the gap survivable.
@(test)
bridge_shell11_writer_path_id_survives_concurrent_reregister :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m := Bridge_Shell_Session_Map{allocator = mem.tracking_allocator(&track)}
	defer bridge_shell_session_map_destroy(&m)
	allocator := bridge_shell_session_map_allocator(&m)

	seed := _ownership_session(&m, "sh_wrace", "sh_wrace", .Running, 1)
	bridge_shell_session_register(&m, &seed)

	ctx := Writer_Race_Ctx{m = &m, rounds = 200, held_intact = true}
	th := thread.create_and_start_with_data(rawptr(&ctx), _writer_race_rereg_worker)
	defer thread.destroy(th)

	for !ctx.stop {
		spec := _ownership_session(&m, "sh_wrace", "sh_wrace", .Failed, 7)

		// The production shape: clone the id BEFORE handing the session over.
		sid := strings.clone(spec.session_id, allocator)

		updated := spec
		bridge_shell_session_register(&m, &updated)

		// Is the id we are about to use the map's own pointer? With s.session_id it was.
		sync.mutex_lock(&m.mu)
		if stored, has := m.sessions["sh_wrace"]; has {
			if raw_data(sid) == raw_data(stored.session_id) do ctx.held_aliased = true
		}
		sync.mutex_unlock(&m.mu)

		// THE WINDOW: delete_spec, wait_signal_exit and the event json all happen here,
		// and re-registers land in it, freeing the set this iteration just handed over.
		time.sleep(200 * time.Microsecond)

		if sid != "sh_wrace" do ctx.held_intact = false
		ctx.reads += 1
		delete(sid, allocator)
	}
	thread.join(th)

	testing.expect(t, ctx.reads > 0, "the writer path actually ran during the churn")
	testing.expect(t, !ctx.held_aliased,
		"the id used after register is NEVER the map's own pointer — the assertion the old s.session_id read fails")
	testing.expect(t, ctx.held_intact,
		"and it still reads correctly after concurrent re-registers freed the set it was cloned from")
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect_value(t, len(m.sessions), 1)
}

// AC4: no unbounded growth under churn. Create, replace and terminate many sessions
// and assert LIVE BYTES return to a fixed baseline rather than scaling with the
// number of rounds.
//
// HOW IT IS MEASURED: mem.Tracking_Allocator's current_memory_allocated (live bytes,
// not total ever allocated) and allocation_map (live allocations), sampled after each
// round. Not RSS — RSS is dominated by the allocator's own retention and would hide a
// per-round leak of a few strings, which is exactly the size of the leak this task
// removes.
@(test)
bridge_shell11_no_growth_under_session_churn :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m := Bridge_Shell_Session_Map{allocator = mem.tracking_allocator(&track)}
	defer bridge_shell_session_map_destroy(&m)

	round :: proc(m: ^Bridge_Shell_Session_Map, id: string) {
		// born
		born := _ownership_session(m, id, id, .Starting, 1)
		bridge_shell_session_register(m, &born)
		// replaced twice, as reconcile does on reconnect
		again := _ownership_session(m, id, id, .Running, 2)
		bridge_shell_session_register(m, &again)
		once_more := _ownership_session(m, id, id, .Running, 3)
		bridge_shell_session_register(m, &once_more)
		// read through every shape, so a leaking accessor shows up here too
		if key, ok := bridge_shell_session_shell_id(m, id); ok do bridge_shell_session_str_delete(m, key)
		if snap, ok := bridge_shell_session_snapshot(m, id); ok do bridge_shell_session_snapshot_destroy(m, snap)
		list := bridge_shell_session_list_snapshot(m)
		bridge_shell_session_list_destroy(m, list)
		// terminated
		bridge_shell_session_update_status(m, id, .Exited, 0, true)
	}

	// One warm-up round so the baseline includes the map's own bucket allocation
	// rather than counting it as growth.
	round(&m, "sh_churn_warm")
	bridge_shell_session_map_reset(&m)
	baseline := track.current_memory_allocated
	baseline_allocs := len(track.allocation_map)

	ROUNDS :: 200
	for i in 0 ..< ROUNDS {
		id := fmt.tprintf("sh_churn_%d", i)
		round(&m, id)
		bridge_shell_session_map_reset(&m)

		// Checked EVERY round, not only at the end: a leak that is cleaned up by the
		// final reset would otherwise pass, and the whole point is that the steady
		// state does not grow.
		if track.current_memory_allocated != baseline {
			testing.expectf(t, false,
				"live bytes grew at round %d: baseline %d, now %d (delta %d)",
				i, baseline, track.current_memory_allocated,
				track.current_memory_allocated - baseline)
			break
		}
	}

	testing.expect_value(t, track.current_memory_allocated, baseline)
	testing.expect_value(t, len(track.allocation_map), baseline_allocs)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// EVERY MIGRATED CALL SITE follows the same shape: acquire, guard the failure with an
// early return, THEN defer the release. That shape is only correct if the FAILURE path
// allocated nothing — otherwise each of the 16 acquisition sites leaks whenever its
// session is missing, and "no growth under churn" would hold only for the paths the
// churn test happens to drive.
//
// This asserts that directly, for every accessor that can allocate, against an empty
// map: live bytes and live allocation count unchanged, no bad frees. The failure branch
// of each accessor returns before it clones, and this is what keeps that true.
@(test)
bridge_shell11_failed_reads_allocate_nothing :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m := Bridge_Shell_Session_Map{allocator = mem.tracking_allocator(&track)}
	defer bridge_shell_session_map_destroy(&m)

	// One real session, then reset, so the map's own hash table is inside the baseline.
	sess := _ownership_session(&m, "sh_present", "sh_present", .Running, 1)
	bridge_shell_session_register(&m, &sess)
	bridge_shell_session_map_reset(&m)
	baseline := track.current_memory_allocated
	baseline_allocs := len(track.allocation_map)

	MISSING :: "sh_definitely_not_registered"
	for i in 0 ..< 50 {
		key, key_ok := bridge_shell_session_shell_id(&m, MISSING)
		testing.expect(t, !key_ok, "the daemon key of a missing session is not found")
		testing.expect_value(t, key, "")

		snap, snap_ok := bridge_shell_session_snapshot(&m, MISSING)
		testing.expect(t, !snap_ok, "nor is a snapshot")
		testing.expect_value(t, snap.session_id, "")

		by_shell, by_shell_ok := bridge_shell_session_snapshot_by_shell_id(&m, MISSING)
		testing.expect(t, !by_shell_ok, "nor a by-shell-id lookup")
		testing.expect_value(t, by_shell.session_id, "")

		_, scalars_ok := bridge_shell_session_scalars(&m, MISSING)
		testing.expect(t, !scalars_ok, "nor the scalars")

		_, port_ok := bridge_shell_session_set_server_port(&m, MISSING, 8080)
		testing.expect(t, !port_ok, "setting a port on a missing session returns nothing to free")

		_, bg_ok := bridge_shell_session_mark_background(&m, MISSING)
		testing.expect(t, !bg_ok, "and so does backgrounding one")

		// The empty-map list snapshot allocates a zero-length slice, which IS released
		// by list_destroy — checked here rather than exempted.
		empty := bridge_shell_session_list_snapshot(&m)
		testing.expect_value(t, len(empty), 0)
		bridge_shell_session_list_destroy(&m, empty)

		// The releases a caller would run on a failed read must also be no-ops, since
		// every migrated site defers them AFTER the guard and some pass the zero value.
		bridge_shell_session_str_delete(&m, key)
		bridge_shell_session_snapshot_destroy(&m, snap)
		bridge_shell_session_snapshot_destroy(&m, by_shell)
	}

	testing.expect_value(t, track.current_memory_allocated, baseline)
	testing.expect_value(t, len(track.allocation_map), baseline_allocs)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// bridge_shell_session_map_reset FREES entries rather than clearing them. Asserted
// separately because it is what makes the churn test above measure anything at all:
// a reset that leaked would make every round's growth look like the reset's fault.
@(test)
bridge_shell11_map_reset_frees_entries :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m := Bridge_Shell_Session_Map{allocator = mem.tracking_allocator(&track)}
	defer bridge_shell_session_map_destroy(&m)

	fill :: proc(m: ^Bridge_Shell_Session_Map, n: int) {
		for i in 0 ..< n {
			sess := _ownership_session(m, fmt.tprintf("sh_reset_%d", i), "sh_reset", .Running, i)
			bridge_shell_session_register(m, &sess)
		}
	}

	// THE WARM-UP IS A FULL ROUND, not a single session. reset frees the ENTRIES but
	// keeps the map's own hash table, which grows as sessions are added — so a
	// baseline taken at capacity-for-one would count that one-off growth as a leak.
	// Warming up with the same count the measured round uses leaves only the entries
	// varying between the two samples, which is what is under test.
	fill(&m, 25)
	bridge_shell_session_map_reset(&m)
	baseline := track.current_memory_allocated

	fill(&m, 25)
	testing.expect(t, track.current_memory_allocated > baseline, "25 sessions do occupy memory")

	bridge_shell_session_map_reset(&m)
	testing.expect_value(t, len(m.sessions), 0)
	testing.expect_value(t, track.current_memory_allocated, baseline)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
