package taskv2

import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Scale B: hub boot (rebuild_timers) and bridge hello (requeue_pending_merges)
// read only the Done tasks the tasks.merge_pending projection marks, so their
// cost does not grow with Done history. The same scenario runs with 10 and
// with 5,000 settled Done tasks (each with a submitted + merged event log, as
// real history has); the reads must be identical.

@(private = "file")
Boot_Cost :: struct {
	boot_calls:  []string,
	hello_calls: []string,
	queued:      int,
	stalled:     int,
}

@(private = "file")
mp_restart :: proc(fx: ^Fixture) {
	for &timer in fx.svc.timers.heap do timer_destroy(&timer)
	delete(fx.svc.timers.heap)
	fx.svc.timers = Timer_Service{}
	rebuild_timers(&fx.svc)
}

// mp_pending_prereq: task_a Done with its merge pending (git directory, no
// bridge reply), task_b waiting only on that merge.
@(private = "file")
mp_pending_prereq :: proc(t: ^testing.T, fx: ^Fixture, chain_id: string) -> bool {
	chain := seed_live_chain(t, fx, chain_id)
	seed_directory(fx, chain, "dir_git", "br_1", "git")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_a")
	_ = publish_task(t, fx, chain, "task_b")
	_, added, aerr := work_dependency_add(&fx.svc, "u1", Actor{kind = ACTOR_USER, id = "u1"}, chain.chain_id,
		domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = "task_b"},
		domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = "task_a"})
	if !testing.expectf(t, added, "edge b→a: %s", aerr.message) do return false
	confirm_holder(fx, "inst_w1")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "a", vcs_json = `{"head":"ha","dirty":false}`})
	if !testing.expectf(t, sok, "submit a: %s", serr.message) do return false
	done_a := get_task(fx, "task_a")
	if !testing.expect_value(t, done_a.state, domain.Task_State.Done) do return false
	return testing.expect_value(t, task_merge_status(&fx.svc, done_a).state, "pending")
}

// mp_seed_done_history: `n` Done tasks whose merges settled long ago, with
// their event logs, inserted with SQL in a chain of their own.
@(private = "file")
mp_seed_done_history :: proc(t: ^testing.T, fx: ^Fixture, n: int) -> bool {
	hist := seed_chain(t, fx, "chain_hist", true)
	now := platform.clock_now(&fx.clock)
	tasks := fmt.tprintf(`WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < %d)
INSERT INTO tasks (task_id, chain_id, owner_user_id, title, description, publish_state, state, kind, priority, attempt_no, brief_json, blocked_on_json, requires_user_approval, ready_since, bridge_id, stage_key, stage_index, generated_by_json, created_at, updated_at, published_at, started_at, completed_at, workflow_run_id, workflow_execution_no)
SELECT 'hist_' || i, '%s', 'u1', 'old', '', 'published', 'done', 'task', 'p0', 1, '{"goal":"g"}', '', 0, '', 'br_1', '', 0, '', '%s', '%s', '%s', '%s', '%s', '', 0 FROM n;`, n - 1, hist.chain_id, now, now, now, now, now)
	events := fmt.tprintf(`WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < %d)
INSERT INTO task_events (task_id, chain_id, owner_user_id, ts_ms, actor_kind, actor_id, kind, payload_json)
SELECT 'hist_' || i, '%s', 'u1', 1, 'hub', '', k.kind, '{}' FROM n, (SELECT 'submitted' AS kind UNION ALL SELECT 'merged') k ORDER BY i, k.kind DESC;`, n - 1, hist.chain_id)
	return testing.expect(t, exec_ok(t, fx, tasks) && exec_ok(t, fx, events), "seed done history")
}

@(private = "file")
mp_calls :: proc(counter: ^Read_Counter) -> []string {
	calls := make([]string, len(counter.calls), context.temp_allocator)
	copy(calls, counter.calls[:])
	return calls
}

@(private = "file")
run_boot_cost :: proc(t: ^testing.T, tag: string, history: int) -> (Boot_Cost, bool) {
	out: Boot_Cost
	fx, log, ok := lease_fixture(t, tag)
	defer lease_fixture_close(fx, log)
	if !ok do return out, false
	if !mp_pending_prereq(t, fx, "chain_boot") do return out, false
	if !mp_seed_done_history(t, fx, history) do return out, false

	counter := new(Read_Counter, context.temp_allocator)
	read_counter_install(fx, counter)
	defer read_counter_uninstall(fx, counter)
	// The two lookups this change is about, on top of the shared wrapper.
	fx.repo.list_merge_pending_done_tasks = proc(ctx: rawptr) -> ([]domain.Task, domain.Domain_Error) {
		out, e := read_counter.inner.list_merge_pending_done_tasks(ctx)
		append(&read_counter.calls, "list_merge_pending_done_tasks"); read_counter.task_rows += len(out)
		return out, e
	}
	fx.repo.list_tasks_by_state = proc(ctx: rawptr, s: domain.Task_State) -> ([]domain.Task, domain.Domain_Error) {
		out, e := read_counter.inner.list_tasks_by_state(ctx, s)
		append(&read_counter.calls, fmt.tprintf("list_tasks_by_state:%s", domain.task_state_string(s))); read_counter.task_rows += len(out)
		return out, e
	}

	read_counter_reset(counter)
	mp_restart(fx)
	out.boot_calls = mp_calls(counter)

	read_counter_reset(counter)
	u, uok, _ := begin_uow(&fx.svc)
	if !testing.expect(t, uok, "begin uow") do return out, false
	requeue_pending_merges(&fx.svc, &u, "br_1")
	out.queued = len(u.effects.merges)
	_, _ = end_uow(&fx.svc, &u, false)
	out.hello_calls = mp_calls(counter)

	// Dependency_Stalled is still armed from the rebuilt timers alone.
	fixture_advance(fx, DEPENDENCY_STALLED_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	out.stalled = count_events(fx, "task_b", EV_DEPENDENCY_STALLED)
	return out, true
}

@(private = "file")
mp_count :: proc(calls: []string, name: string) -> int {
	n := 0
	for c in calls do if c == name do n += 1
	return n
}

@(private = "file")
mp_same :: proc(a, b: []string) -> bool {
	if len(a) != len(b) do return false
	for c, i in a do if c != b[i] do return false
	return true
}

@(test)
test_boot_and_hello_reads_flat_as_done_history_grows :: proc(t: ^testing.T) {
	small, sok := run_boot_cost(t, "mp_boot_small", 10)
	if !sok do return
	large, lok := run_boot_cost(t, "mp_boot_large", 5000)
	if !lok do return

	// The wrapper saw the lookups (an empty list would make the comparison pass).
	for path in ([]struct{ name: string, calls: []string }{{"boot", large.boot_calls}, {"hello", large.hello_calls}}) {
		testing.expectf(t, mp_count(path.calls, "list_merge_pending_done_tasks") == 1, "%s uses the projection: %v", path.name, path.calls)
		testing.expectf(t, mp_count(path.calls, "list_tasks_by_state:done") == 0, "%s lists every Done task: %v", path.name, path.calls)
		testing.expectf(t, mp_count(path.calls, "list_events_by_task") >= 1, "%s reads the pending task's events: %v", path.name, path.calls)
	}
	testing.expectf(t, mp_same(small.boot_calls, large.boot_calls), "boot reads differ with Done history\n  10:   %v\n  5000: %v", small.boot_calls, large.boot_calls)
	testing.expectf(t, mp_same(small.hello_calls, large.hello_calls), "hello reads differ with Done history\n  10:   %v\n  5000: %v", small.hello_calls, large.hello_calls)
	testing.expect_value(t, mp_count(large.boot_calls, "list_events_by_task"), mp_count(small.boot_calls, "list_events_by_task"))

	// Behaviour unchanged: the pending merge is re-sent once on hello and the
	// dependent is reported stalled after a restart.
	testing.expect_value(t, small.queued, 1)
	testing.expect_value(t, large.queued, 1)
	testing.expect_value(t, small.stalled, 1)
	testing.expect_value(t, large.stalled, 1)
}

// Restart across the merge lifecycle: pending → re-armed and requeued; a
// recorded merge clears the projection, so the next boot neither re-arms
// Dependency_Stalled nor requeues; a reopen + new completion sets it again.
@(test)
test_merge_pending_projection_across_restart :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "mp_restart")
	defer lease_fixture_close(fx, log)
	if !ok do return
	if !mp_pending_prereq(t, fx, "chain_mp_restart") do return
	listed :: proc(fx: ^Fixture) -> int {
		tasks, _ := iface.taskchain_list_merge_pending_done_tasks(&fx.repo)
		return len(tasks)
	}
	queued :: proc(fx: ^Fixture) -> int {
		u, _, _ := begin_uow(&fx.svc)
		requeue_pending_merges(&fx.svc, &u, "br_1")
		n := len(u.effects.merges)
		_, _ = end_uow(&fx.svc, &u, false)
		return n
	}
	// Set in the submit's unit of work.
	testing.expect_value(t, listed(fx), 1)
	mp_restart(fx)
	testing.expect_value(t, queued(fx), 1)
	fixture_advance(fx, DEPENDENCY_STALLED_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_b", EV_DEPENDENCY_STALLED), 1)

	// The merge settles (as run_merge records it): cleared in the same append.
	a := get_task(fx, "task_a")
	u, uok, _ := begin_uow(&fx.svc)
	if !testing.expect(t, uok, "begin uow") do return
	_, _, rok, rerr := record_event(&fx.svc, &u, a, hub_actor(), EV_MERGED, `{"branch":"b","into":"r","head":"h","mode":"ff"}`)
	_, _ = end_uow(&fx.svc, &u, rok)
	if !testing.expectf(t, rok, "record merged: %s", rerr.message) do return
	testing.expect_value(t, task_merge_status(&fx.svc, get_task(fx, "task_a")).state, "merged")
	testing.expect_value(t, listed(fx), 0)
	mp_restart(fx)
	testing.expect_value(t, queued(fx), 0)
	fixture_advance(fx, 2 * DEPENDENCY_STALLED_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, count_events(fx, "task_b", EV_DEPENDENCY_STALLED), 1)

	// A failed merge does not settle it (hello retries a failed merge).
	if !testing.expect(t, exec_ok(t, fx, "UPDATE tasks SET merge_pending = 0 WHERE task_id = 'task_a';"), "reset") do return
	_, aok, aerr := append_event(&fx.repo, &fx.clock, a, hub_actor(), EV_APPROVED, `{"attempt_no":1}`)
	if !testing.expectf(t, aok, "approved: %s", aerr.message) do return
	_, fok, ferr := append_event(&fx.repo, &fx.clock, a, hub_actor(), EV_MERGE_FAILED, `{"detail":"offline"}`)
	if !testing.expectf(t, fok, "merge failed: %s", ferr.message) do return
	testing.expect_value(t, listed(fx), 1)
	mp_restart(fx)
	testing.expect_value(t, queued(fx), 1)
}
