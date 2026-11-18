package taskv2

// REQ-OVF-1 / REQ-OVF-4: summary_overflow is one notice per continuous overflow
// episode, latched durably in chain_summaries.overflow_active so the latch
// survives summary set, rebuilds, a new Service over the same database (restart)
// and a reconstructed summary row; a resolved episode notifies again later.

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

@(private = "file")
Overflow_Capture :: struct {
	lines: [dynamic]string,
}

@(private = "file")
overflow_observe :: proc(ctx: rawptr, coord_id, trigger, line: string) {
	if trigger != "summary_overflow" do return
	c := (^Overflow_Capture)(ctx)
	append(&c.lines, strings.clone(line, context.temp_allocator))
}

@(private = "file")
Overflow_Fixture :: struct {
	fx:      ^Fixture,
	log:     ^Wake_Log,
	chain:   domain.Task_Chain,
	task:    domain.Task,
	cap:     Overflow_Capture,
	attempt: int,
}

@(private = "file")
overflow_fixture :: proc(t: ^testing.T, tag: string) -> (^Overflow_Fixture, bool) {
	of := new(Overflow_Fixture)
	fx, log, ok := lease_fixture(t, tag)
	of.fx = fx
	of.log = log
	if !ok do return of, false
	of.cap.lines = make([dynamic]string, context.temp_allocator)
	overflow_wire_observer(of, &fx.svc)
	of.chain = seed_live_chain(t, fx, fmt.tprintf("chain_%s", tag))
	of.task = seed_task(t, fx, of.chain, fmt.tprintf("task_%s", tag))
	return of, true
}

@(private = "file")
overflow_wire_observer :: proc(of: ^Overflow_Fixture, svc: ^Service) {
	svc.notify_observer_ctx = &of.cap
	svc.notify_observer = overflow_observe
}

@(private = "file")
overflow_fixture_close :: proc(of: ^Overflow_Fixture) {
	// fixture_close resets the tracking allocator, so free the wrapper first.
	fx, log := of.fx, of.log
	free(of)
	lease_fixture_close(fx, log)
}

// add_dead_ends records n dead ends in one more handoff facet (a new attempt).
@(private = "file")
add_dead_ends :: proc(t: ^testing.T, of: ^Overflow_Fixture, n: int) {
	of.attempt += 1
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"summary":"attempt","dead_ends":[`)
	for i in 0 ..< n {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `"dead end %d.%d"`, of.attempt, i)
	}
	strings.write_string(&b, `]}`)
	ok, err := iface.taskchain_save_facet(&of.fx.repo, domain.Task_Attempt_Facet{
		task_id = of.task.task_id, attempt_no = of.attempt, chain_id = of.chain.chain_id, owner_user_id = of.chain.owner_user_id,
		kind = FACET_HANDOFF, v = 1, body_json = strings.to_string(b), writer = FACET_WRITER_AGENT, written_at = platform.clock_now(&of.fx.clock),
	})
	testing.expectf(t, ok, "save handoff facet: %s", err.message)
}

@(private = "file")
rebuild :: proc(t: ^testing.T, svc: ^Service, chain: domain.Task_Chain, commit := true) {
	u, began, berr := begin_uow(svc)
	if !testing.expectf(t, began, "begin uow: %s", berr.message) do return
	rebuild_chain_summary_in_uow(svc, &u, chain)
	_, _ = end_uow(svc, &u, commit)
}

@(private = "file")
overflow_events :: proc(of: ^Overflow_Fixture) -> int {
	return scalar_int(of.fx, fmt.tprintf("SELECT COUNT(*) FROM task_events WHERE chain_id = '%s' AND kind = 'summary_overflow';", of.chain.chain_id))
}

@(private = "file")
stored_summary :: proc(t: ^testing.T, of: ^Overflow_Fixture) -> domain.Chain_Summary {
	row, ok, _ := iface.taskchain_get_chain_summary(&of.fx.repo, of.chain.chain_id, of.chain.owner_user_id)
	testing.expect(t, ok, "chain summary row exists")
	return row
}

@(test)
test_summary_overflow_boundary_and_single_notice_per_episode :: proc(t: ^testing.T) {
	of, ok := overflow_fixture(t, "ovf_episode")
	defer overflow_fixture_close(of)
	if !ok do return

	// Boundary: title + "## Dead Ends" + 58 dead ends is exactly 60 lines -> fits.
	add_dead_ends(t, of, 58)
	rebuild(t, &of.fx.svc, of.chain)
	fit := stored_summary(t, of)
	testing.expect(t, !fit.overflow_active, "58 dead ends fit: no overflow episode")
	testing.expect_value(t, fit.line_count, CHAIN_SUMMARY_MAX_LINES)
	testing.expect(t, strings.contains(fit.body, "dead end 1.57") && !strings.contains(fit.body, DEAD_ENDS_OMITTED_SUFFIX), "every dead end rendered, no omission marker")
	testing.expect_value(t, overflow_events(of), 0)
	testing.expect_value(t, len(of.cap.lines), 0)

	// 59 dead ends overflow. A rolled-back rebuild records and announces nothing.
	add_dead_ends(t, of, 1)
	rebuild(t, &of.fx.svc, of.chain, commit = false)
	testing.expect(t, !stored_summary(t, of).overflow_active, "rolled-back rebuild leaves the latch closed")
	testing.expect_value(t, overflow_events(of), 0)
	testing.expect_value(t, len(of.cap.lines), 0)

	// First overflow: exactly one event + one notice, latch open, summary bounded.
	rebuild(t, &of.fx.svc, of.chain)
	first := stored_summary(t, of)
	testing.expect(t, first.overflow_active, "59 dead ends open an overflow episode")
	testing.expect(t, first.line_count <= CHAIN_SUMMARY_MAX_LINES, "rendered summary stays bounded")
	testing.expect(t, strings.contains(first.body, fmt.tprintf("%s2 %s", DEAD_ENDS_OMITTED_PREFIX, DEAD_ENDS_OMITTED_SUFFIX)), "last slot names the 2 dead ends not shown")
	testing.expect_value(t, overflow_events(of), 1)
	if testing.expect_value(t, len(of.cap.lines), 1) {
		line := of.cap.lines[0]
		testing.expect(t, strings.contains(line, "59 dead ends"), "notice states the retained count")
		testing.expect(t, strings.contains(line, "task-chain summary get"), "notice points at the read-only summary get")
		testing.expect(t, strings.contains(line, "facet:<task-id>:<attempt>:handoff"), "notice points at the retained handoff facets")
		testing.expect(t, !strings.contains(line, "summary set` to compact"), "notice no longer asks for an impossible compaction")
	}
	// Retained history: the handoff facets still carry every dead end.
	facets, _ := iface.taskchain_list_facets_by_task(&of.fx.repo, of.task.task_id, of.chain.owner_user_id)
	testing.expect_value(t, len(facets), 2)

	// Repeated rebuilds during the episode stay silent.
	rebuild(t, &of.fx.svc, of.chain)
	add_dead_ends(t, of, 3)
	rebuild(t, &of.fx.svc, of.chain)
	testing.expect_value(t, overflow_events(of), 1)
	testing.expect_value(t, len(of.cap.lines), 1)

	// summary set during the episode keeps the latch and renders at once: the
	// curated note is visible next to the mechanical sections and survives
	// every later rebuild, without the mechanical marker being re-absorbed.
	set_row, set_ok, set_err := chain_summary_set(&of.fx.svc, inst_auth("inst_coord"), of.chain.chain_id, "Curated: keep it short")
	testing.expectf(t, set_ok, "summary set: %s", set_err.message)
	testing.expect(t, set_row.overflow_active && stored_summary(t, of).overflow_active, "summary set preserves the open episode")
	testing.expect(t, strings.contains(set_row.body, "Curated: keep it short") && strings.contains(set_row.body, "## Dead Ends"), "set renders curated + mechanical sections immediately")
	testing.expect_value(t, set_row.curated_body, "Curated: keep it short")
	testing.expect_value(t, overflow_events(of), 1)
	testing.expect_value(t, len(of.cap.lines), 1)
	for round in 0 ..< 2 {
		rebuild(t, &of.fx.svc, of.chain)
		after_set := stored_summary(t, of)
		testing.expectf(t, after_set.overflow_active, "rebuild %d after set keeps the episode open", round)
		testing.expectf(t, strings.contains(after_set.body, "Curated: keep it short"), "rebuild %d keeps the curated note rendered: %s", round, after_set.body)
		testing.expect_value(t, after_set.curated_body, "Curated: keep it short")
		testing.expect_value(t, strings.count(after_set.body, DEAD_ENDS_OMITTED_SUFFIX), 1)
		testing.expect_value(t, after_set.line_count, CHAIN_SUMMARY_MAX_LINES)
	}
	testing.expect_value(t, overflow_events(of), 1)
	testing.expect_value(t, len(of.cap.lines), 1)

	// Restart: a brand-new Service over the same database reads the durable latch.
	restarted := new_service(&of.fx.repo, &of.fx.agents, &of.fx.bridges, &of.fx.clock, &of.fx.ids)
	restarted.uow_factory = &of.fx.uow
	overflow_wire_observer(of, &restarted)
	rebuild(t, &restarted, of.chain)
	testing.expect_value(t, overflow_events(of), 1)
	testing.expect_value(t, len(of.cap.lines), 1)
	testing.expect(t, strings.contains(stored_summary(t, of).body, "Curated: keep it short"), "curated note survives the restart rebuild")

	// Reconstruction: with the summary row gone the latch is seeded from the
	// recorded summary_overflow event, so the episode is not announced again.
	testing.expect(t, exec_ok(t, of.fx, fmt.tprintf("DELETE FROM chain_summaries WHERE chain_id = '%s';", of.chain.chain_id)), "drop summary row")
	rebuild(t, &restarted, of.chain)
	testing.expect(t, stored_summary(t, of).overflow_active, "reconstructed row keeps the episode open")
	testing.expect_value(t, overflow_events(of), 1)
	testing.expect_value(t, len(of.cap.lines), 1)

	// Resolution: once everything fits again the episode closes silently ...
	testing.expect(t, exec_ok(t, of.fx, fmt.tprintf("DELETE FROM task_attempt_facets WHERE task_id = '%s';", of.task.task_id)), "simulate dead ends fitting again")
	add_dead_ends(t, of, 2)
	rebuild(t, &of.fx.svc, of.chain)
	testing.expect(t, !stored_summary(t, of).overflow_active, "fitting summary closes the episode")
	testing.expect_value(t, overflow_events(of), 1)
	testing.expect_value(t, len(of.cap.lines), 1)

	// ... and a later overflow is a new episode with exactly one more notice.
	add_dead_ends(t, of, 60)
	rebuild(t, &of.fx.svc, of.chain)
	rebuild(t, &of.fx.svc, of.chain)
	testing.expect(t, stored_summary(t, of).overflow_active, "later overflow reopens the episode")
	testing.expect_value(t, overflow_events(of), 2)
	testing.expect_value(t, len(of.cap.lines), 2)
}

@(test)
test_summary_set_without_overflow_keeps_latch_closed :: proc(t: ^testing.T) {
	of, ok := overflow_fixture(t, "ovf_set_closed")
	defer overflow_fixture_close(of)
	if !ok do return
	add_dead_ends(t, of, 3)
	rebuild(t, &of.fx.svc, of.chain)
	row, set_ok, set_err := chain_summary_set(&of.fx.svc, inst_auth("inst_coord"), of.chain.chain_id, "Curated")
	testing.expectf(t, set_ok, "summary set: %s", set_err.message)
	testing.expect(t, !row.overflow_active && !stored_summary(t, of).overflow_active, "set never opens an episode")
	rebuild(t, &of.fx.svc, of.chain)
	testing.expect_value(t, overflow_events(of), 0)
	testing.expect_value(t, len(of.cap.lines), 0)
}

// The schema upgrade adds the latch and curated columns to an existing
// database, idempotently, and opens
// it for chains that already reported an overflow, so upgrading does not
// re-notify them; other chains start closed.
@(test)
test_summary_overflow_latch_upgrade_backfill :: proc(t: ^testing.T) {
	fx, ok := fixture_open(t, "ovf_upgrade", stop_before = "208_extension_version_sync_0_5_54.sql")
	defer fixture_close(fx)
	if !ok do return
	testing.expect_value(t, scalar_int(fx, "SELECT COUNT(*) FROM pragma_table_info('chain_summaries') WHERE name = 'overflow_active';"), 0)
	now := platform.clock_now(&fx.clock)
	exec_ok(t, fx, fmt.tprintf("INSERT INTO chain_summaries(chain_id, owner_user_id, body, updated_at) VALUES ('c_over','u1','b','%s'), ('c_fit','u1','b','%s');", now, now))
	exec_ok(t, fx, "INSERT INTO task_events(task_id, chain_id, owner_user_id, ts_ms, kind, payload_json) VALUES ('t1','c_over','u1',1,'summary_overflow','{}'), ('t2','c_other_owner','u2',1,'summary_overflow','{}');")
	mig_ok, mig_err := sqlite.run_migrations(&fx.conn)
	if !testing.expectf(t, mig_ok, "upgrade migrations: %s", mig_err.message) do return
	testing.expect_value(t, scalar_int(fx, "SELECT overflow_active FROM chain_summaries WHERE chain_id = 'c_over';"), 1)
	testing.expect_value(t, scalar_int(fx, "SELECT overflow_active FROM chain_summaries WHERE chain_id = 'c_fit';"), 0)
	over, _, _ := iface.taskchain_get_chain_summary(&fx.repo, "c_over", "u1")
	testing.expect(t, over.overflow_active, "repository reads the backfilled latch")
	testing.expect(t, !over.curated_stored && over.curated_body == "", "upgraded rows are legacy until their next rebuild stores the notes")
	testing.expect_value(t, scalar_int(fx, "SELECT COUNT(*) FROM pragma_table_info('chain_summaries') WHERE name IN ('overflow_active', 'curated_body', 'curated_stored');"), 3)
	// The upgrade is idempotent: running it again changes nothing.
	again_ok, again_err := sqlite.run_migrations(&fx.conn)
	testing.expectf(t, again_ok, "re-run upgrade: %s", again_err.message)
	testing.expect_value(t, scalar_int(fx, "SELECT overflow_active FROM chain_summaries WHERE chain_id = 'c_over';"), 1)
}

// Review finding: curated notes keep a guaranteed share of the cap during
// overflow, notes beyond it are stored in full (never silently dropped), and a
// set that leaves no room for every dead end opens one episode.
@(test)
test_summary_curated_notes_budget_during_overflow :: proc(t: ^testing.T) {
	of, ok := overflow_fixture(t, "ovf_curated")
	defer overflow_fixture_close(of)
	if !ok do return

	// 13 curated lines (the reported chain's size) with 40 dead ends fit: 1 + 13 + 41 <= 60.
	notes := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 13 do append(&notes, fmt.tprintf("note %02d", i))
	thirteen := strings.join(notes[:], "\n", context.temp_allocator)
	add_dead_ends(t, of, 40)
	_, set_ok, set_err := chain_summary_set(&of.fx.svc, inst_auth("inst_coord"), of.chain.chain_id, thirteen)
	testing.expectf(t, set_ok, "summary set: %s", set_err.message)
	rebuild(t, &of.fx.svc, of.chain)
	fit := stored_summary(t, of)
	testing.expect(t, !fit.overflow_active && strings.contains(fit.body, "note 12") && strings.contains(fit.body, "dead end 1.39"), "13 notes + 40 dead ends all render")
	testing.expect_value(t, overflow_events(of), 0)

	// Dead ends grow past the cap: all 13 notes stay rendered, one notice.
	add_dead_ends(t, of, 30)
	rebuild(t, &of.fx.svc, of.chain)
	rebuild(t, &of.fx.svc, of.chain)
	over := stored_summary(t, of)
	testing.expect(t, over.overflow_active, "70 dead ends overflow")
	testing.expect_value(t, over.line_count, CHAIN_SUMMARY_MAX_LINES)
	for i in 0 ..< 13 do testing.expectf(t, strings.contains(over.body, fmt.tprintf("note %02d", i)), "note %02d rendered during overflow", i)
	testing.expect(t, strings.contains(over.body, fmt.tprintf("%s%d %s", DEAD_ENDS_OMITTED_PREFIX, 70 - 44, DEAD_ENDS_OMITTED_SUFFIX)), "60 = title + 13 notes + header + 44 dead ends + marker")
	testing.expect_value(t, overflow_events(of), 1)
	testing.expect_value(t, len(of.cap.lines), 1)
	if len(of.cap.lines) == 1 do testing.expect(t, strings.contains(of.cap.lines[0], "up to 20 lines"), "notice states the curated budget")

	// Longer notes: the first 20 always render; the rest are stored in full and
	// come back once dead ends shrink. Still the same episode: no new notice.
	notes = make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 30 do append(&notes, fmt.tprintf("long %02d", i))
	thirty := strings.join(notes[:], "\n", context.temp_allocator)
	_, long_ok, long_err := chain_summary_set(&of.fx.svc, inst_auth("inst_coord"), of.chain.chain_id, thirty)
	testing.expectf(t, long_ok, "summary set: %s", long_err.message)
	rebuild(t, &of.fx.svc, of.chain)
	long_row := stored_summary(t, of)
	testing.expect(t, strings.contains(long_row.body, "long 19") && !strings.contains(long_row.body, "long 20"), "exactly the guaranteed 20 notes render while dead ends overflow")
	testing.expect_value(t, long_row.curated_body, thirty)
	testing.expect_value(t, long_row.line_count, CHAIN_SUMMARY_MAX_LINES)
	testing.expect_value(t, overflow_events(of), 1)
	testing.expect(t, exec_ok(t, of.fx, fmt.tprintf("DELETE FROM task_attempt_facets WHERE task_id = '%s';", of.task.task_id)), "simulate dead ends shrinking")
	add_dead_ends(t, of, 5)
	rebuild(t, &of.fx.svc, of.chain)
	back := stored_summary(t, of)
	testing.expect(t, !back.overflow_active && strings.contains(back.body, "long 29"), "stored notes beyond the guarantee render again once there is room")

	// A set that crowds out dead ends opens a (single) new episode itself.
	add_dead_ends(t, of, 30) // 35 dead ends; 30 notes reserve 20 -> capacity 39 lines for header + dead ends
	rebuild(t, &of.fx.svc, of.chain)
	testing.expect(t, !stored_summary(t, of).overflow_active, "35 dead ends fit next to 20 reserved notes")
	add_dead_ends(t, of, 4) // 39 dead ends + header = 40 > 39
	_, crowd_ok, _ := chain_summary_set(&of.fx.svc, inst_auth("inst_coord"), of.chain.chain_id, thirty)
	testing.expect(t, crowd_ok && stored_summary(t, of).overflow_active, "set that leaves no room for every dead end opens an episode")
	rebuild(t, &of.fx.svc, of.chain)
	testing.expect_value(t, overflow_events(of), 2)
	testing.expect_value(t, len(of.cap.lines), 2)
}

// A legacy row (curated notes only inside the rendered body) has its notes
// extracted once and stored; they then survive overflow like any others.
@(test)
test_summary_legacy_curated_notes_are_stored_once :: proc(t: ^testing.T) {
	of, ok := overflow_fixture(t, "ovf_legacy")
	defer overflow_fixture_close(of)
	if !ok do return
	_, saved, _ := iface.taskchain_save_chain_summary(&of.fx.repo, domain.Chain_Summary{
		chain_id = of.chain.chain_id, owner_user_id = of.chain.owner_user_id, version = 3, updated_at = "2026-11-18T00:00:00Z",
		body = fmt.tprintf("# Chain %s: c\nLegacy curated line\n## Dead Ends", of.chain.chain_id),
	})
	testing.expect(t, saved, "legacy row saved")
	add_dead_ends(t, of, 70)
	rebuild(t, &of.fx.svc, of.chain)
	rebuild(t, &of.fx.svc, of.chain)
	row := stored_summary(t, of)
	testing.expect(t, row.curated_stored, "legacy notes are now stored")
	testing.expect_value(t, row.curated_body, "Legacy curated line")
	testing.expect(t, row.overflow_active && strings.contains(row.body, "Legacy curated line"), "legacy note survives overflow rebuilds")
	testing.expect_value(t, row.version, 5)
}

// Review finding (round 2): `summary set` with a body round-tripped from
// `summary get` stores only the note lines; the mechanical title, section
// headers, task and dead-end bullets and the omission marker are dropped, so
// a render never duplicates them. Covers both the fitting and the overflow case.
@(test)
test_summary_set_round_trip_stores_only_notes :: proc(t: ^testing.T) {
	for dead_ends in ([]int{3, 70}) {
		of, ok := overflow_fixture(t, fmt.tprintf("ovf_round_trip_%d", dead_ends))
		if !ok {
			overflow_fixture_close(of)
			return
		}
		add_dead_ends(t, of, dead_ends)
		_, a_ok, a_err := chain_summary_set(&of.fx.svc, inst_auth("inst_coord"), of.chain.chain_id, "Note A")
		testing.expectf(t, a_ok, "set Note A: %s", a_err.message)
		rendered := stored_summary(t, of).body
		testing.expect(t, strings.contains(rendered, "## Dead Ends"), "rendered body carries mechanical sections")
		if dead_ends > 60 do testing.expect(t, strings.contains(rendered, DEAD_ENDS_OMITTED_SUFFIX), "overflow body carries the omission marker")

		edited := strings.concatenate({rendered, "\nNote B"}, context.temp_allocator)
		row, b_ok, b_err := chain_summary_set(&of.fx.svc, inst_auth("inst_coord"), of.chain.chain_id, edited)
		testing.expectf(t, b_ok, "set round-tripped body: %s", b_err.message)
		testing.expect_value(t, row.curated_body, "Note A\nNote B")
		rebuild(t, &of.fx.svc, of.chain)
		after := stored_summary(t, of)
		testing.expect_value(t, after.curated_body, "Note A\nNote B")
		testing.expectf(t, strings.count(after.body, "# Chain ") == 1, "exactly one title (%d dead ends): %s", dead_ends, after.body)
		testing.expectf(t, strings.count(after.body, "## Dead Ends") == 1, "exactly one Dead Ends header (%d dead ends)", dead_ends)
		testing.expect(t, strings.count(after.body, "## Active & Pending") <= 1, "at most one Active & Pending header")
		testing.expectf(t, strings.count(after.body, "dead end 1.0") == 1, "dead-end bullet rendered once (%d dead ends)", dead_ends)
		testing.expect(t, strings.count(after.body, DEAD_ENDS_OMITTED_SUFFIX) == (1 if dead_ends > 60 else 0), "omission marker never duplicated")
		testing.expect(t, strings.contains(after.body, "Note A\nNote B"), "notes render together under the title")
		testing.expect(t, after.line_count <= CHAIN_SUMMARY_MAX_LINES, "bounded")
		testing.expect_value(t, overflow_events(of), 1 if dead_ends > 60 else 0)
		overflow_fixture_close(of)
	}
}
