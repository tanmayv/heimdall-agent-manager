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

	// summary set during the episode keeps the latch; the next rebuild is silent
	// and keeps the curated note without re-absorbing the mechanical marker.
	_, set_ok, set_err := chain_summary_set(&of.fx.svc, inst_auth("inst_coord"), of.chain.chain_id, "Curated: keep it short")
	testing.expectf(t, set_ok, "summary set: %s", set_err.message)
	testing.expect(t, stored_summary(t, of).overflow_active, "summary set preserves the open episode")
	rebuild(t, &of.fx.svc, of.chain)
	after_set := stored_summary(t, of)
	testing.expect(t, after_set.overflow_active, "rebuild after set keeps the episode open")
	testing.expect_value(t, strings.count(after_set.body, DEAD_ENDS_OMITTED_SUFFIX), 1)
	testing.expect(t, after_set.line_count <= CHAIN_SUMMARY_MAX_LINES, "bounded after set")
	testing.expect_value(t, overflow_events(of), 1)
	testing.expect_value(t, len(of.cap.lines), 1)

	// Restart: a brand-new Service over the same database reads the durable latch.
	restarted := new_service(&of.fx.repo, &of.fx.agents, &of.fx.bridges, &of.fx.clock, &of.fx.ids)
	restarted.uow_factory = &of.fx.uow
	overflow_wire_observer(of, &restarted)
	rebuild(t, &restarted, of.chain)
	testing.expect_value(t, overflow_events(of), 1)
	testing.expect_value(t, len(of.cap.lines), 1)

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

// The schema upgrade adds the latch column to an existing database and opens
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
}
