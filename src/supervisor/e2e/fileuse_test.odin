// T15 (spec §5 W1-W9, §17 "verify in T15", §18): Windows file-in-use and antivirus delay,
// run on every OS (the rules are the same everywhere; only Windows enforces them):
//   1. a straggler process runs from v0.6.0's tree (its exe is in use) through all of it;
//   2. antivirus delay on the staging rename: while v0.6.1 is extracted, a handle on its
//      `.staging-<op>/bin` is held for 3 s; the rename waits (W3) and the op commits;
//   3. antivirus delay on the pointer replace: `current` is held from before v0.6.2's
//      activation until 3 s after `pointers_begin`; the switch waits and commits;
//   4. GC with the straggler alive: after v0.6.3, v0.6.0 is no longer live and is the
//      oldest of 4 trees. POSIX deletes it; Windows cannot (its exe runs) and leaves it
//      (or its .trash-*) for later (W5); the straggler keeps running (W4);
//   5. the straggler exits; the next supervisor start's GC removes what was left.
package e2e

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_file_in_use_and_antivirus_delay :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s: Suite
	defer suite_close(&s)
	if !suite_open(&s, t, "fileuse") do return
	a := new_inst(&s, "a")
	a.first_check_s = NEVER
	t0 := strings.clone(publish(&s, "v0.6.0"))
	defer delete(t0)
	if !install(a, "v0.6.0") do return

	// 1. Straggler from t0.
	straggler, serr := os.process_start({command = {pj(a.data, "releases", t0, "bin", exe("ham-bridge")), "--hold", "600"}})
	if !testing.expectf(t, serr == nil, "straggler: %v", serr) do return
	defer {
		_ = os.process_kill(straggler)
		_, _ = os.process_wait(straggler, 5 * time.Second)
	}

	// 2. Staging rename held (a big bundle so extraction takes a while).
	t1 := strings.clone(publish(&s, "v0.6.1", {stable = true, pad_bytes = 64 << 20}))
	defer delete(t1)
	send_intent(a, "op_av_stage", "install_version", `,"version":"v0.6.1"`)
	stage_bin := pj(a.data, "releases", ".staging-op_av_stage", "bin")
	caught := false
	start := time.tick_now()
	for time.tick_since(start) < 90 * time.Second && !op_done(a, "op_av_stage") {
		if os.exists(stage_bin) {
			h, ok := hold_open(stage_bin, true)
			if ok {
				caught = true
				time.sleep(3 * time.Second)
				renamed := os.exists(pj(a.data, "releases", t1))
				hold_close(&h)
				log.infof("staging held 3 s; final tree present while held: %v", renamed)
				if HOLDS_BLOCK do testing.expect(t, !renamed, "the staging rename waited while its tree was held")
				break
			}
		}
	}
	if HOLDS_BLOCK do testing.expect(t, caught, "caught the staging dir to hold it")
	g_want = t1
	if !wait_for(a, "v0.6.1 committed after the held rename", 150 * time.Second, proc(i: ^Inst) -> bool {return known_good(i) == g_want}) do return
	st, code, _ := op_final(a, "op_av_stage")
	testing.expectf(t, st == "committed", "op_av_stage %s %s", st, code)

	// 3. Pointer replace held.
	t2 := strings.clone(publish(&s, "v0.6.2"))
	defer delete(t2)
	cur_path := pj(a.data, "current.json") if ODIN_OS == .Windows else pj(a.data, "current")
	ph, pok := hold_open(cur_path)
	if HOLDS_BLOCK do testing.expectf(t, pok, "hold %s", cur_path)
	send_intent(a, "op_av_ptr", "install_version", `,"version":"v0.6.2"`)
	has_sub :: proc(i: ^Inst, op, sub: string) -> bool {
		for l in journal(i) do if l.op_id == op && l.sub == sub do return true
		return false
	}
	at_begin :: proc(i: ^Inst) -> bool {return has_sub(i, "op_av_ptr", "pointers_begin") || op_done(i, "op_av_ptr")}
	if !wait_for(a, "op_av_ptr at pointers_begin", 120 * time.Second, at_begin) {
		hold_close(&ph)
		return
	}
	time.sleep(3 * time.Second)
	switched := has_sub(a, "op_av_ptr", "pointers_done")
	hold_close(&ph)
	log.infof("current held 3 s past pointers_begin; pointers_done while held: %v", switched)
	if HOLDS_BLOCK do testing.expect(t, !switched, "the pointer replace waited while current was held")
	g_want = t2
	if !wait_for(a, "v0.6.2 committed after the held replace", 120 * time.Second, proc(i: ^Inst) -> bool {return known_good(i) == g_want}) do return
	st, code, _ = op_final(a, "op_av_ptr")
	testing.expectf(t, st == "committed", "op_av_ptr %s %s", st, code)

	// 4. GC while the straggler runs from t0.
	t3 := strings.clone(publish(&s, "v0.6.3"))
	defer delete(t3)
	send_intent(a, "op_gc", "install_version", `,"version":"v0.6.3"`)
	g_want = t3
	if !wait_for(a, "v0.6.3 committed", 120 * time.Second, proc(i: ^Inst) -> bool {return known_good(i) == g_want}) do return
	time.sleep(5 * time.Second) // gc runs on the tick after the terminal op
	_, still := os.process_wait(straggler, 0)
	testing.expect(t, still != nil, "the straggler from v0.6.0 keeps running (W4)")
	left := leftovers(a, t0)
	log.infof("after GC with the straggler alive: %v", left)
	if HOLDS_BLOCK {
		testing.expectf(t, len(left) > 0, "Windows: v0.6.0's tree (or its trash) stays while its exe runs (W5): %v", left)
	} else {
		testing.expectf(t, len(left) == 0, "POSIX: v0.6.0's tree deleted by GC: %v", left)
	}
	testing.expect(t, os.exists(pj(a.data, "releases", t1, ".complete")), "v0.6.1 kept (3 trees)")

	// 5. Straggler gone; the next start's GC finishes the job.
	_ = os.process_kill(straggler)
	_, _ = os.process_wait(straggler, 10 * time.Second)
	testing.expect_value(t, stop_launcher(a), 0)
	start_launcher(a)
	@(static) gone_tree: string
	gone_tree = t0
	if !wait_for(a, "v0.6.0 leftovers removed at start", 60 * time.Second, proc(i: ^Inst) -> bool {return len(leftovers(i, gone_tree)) == 0}) do return
	testing.expect_value(t, stop_launcher(a), 0)
}

// leftovers: releases/ entries that are `tree` or trash / staging dirs.
leftovers :: proc(i: ^Inst, tree: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	entries, _ := os.read_directory_by_path(pj(i.data, "releases"), -1, context.temp_allocator)
	for e in entries {
		if e.name == tree || strings.has_prefix(e.name, ".trash-") do append(&out, strings.clone(e.name, context.temp_allocator))
	}
	return out[:]
}
