package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// `lease next` cost (spec SCHED 10 and 14.5, REQ-SCHED-38..40). A counting
// wrapper around the repository interfaces records every read `lease next`
// issues. The same scenario runs on a 10-task, 1-chain hub and on a hub where
// the caller's chain has 1,000 tasks and there are 100 chains: every path must
// issue the same reads with the same number of task rows, within the bounds of
// table 10.3. The background rows are inserted with SQL after the engine set-up,
// so they are exactly the "other work" `lease next` must not look at.

// ---- counting wrapper -------------------------------------------------------------

Read_Counter :: struct {
	inner:     iface.Taskchain_Repository,
	agents:    iface.Agent_Repository,
	calls:     [dynamic]string,
	task_rows: int,
}

@(thread_local)
read_counter: ^Read_Counter

@(private = "file")
rc_note :: proc(name: string, task_rows := 0) {
	if read_counter == nil do return
	append(&read_counter.calls, name)
	read_counter.task_rows += task_rows
}

// read_counter_install wraps the read procs of fx.repo and fx.agents (the
// service holds pointers to both); everything else passes through untouched.
read_counter_install :: proc(fx: ^Fixture, counter: ^Read_Counter) {
	counter.inner = fx.repo
	counter.agents = fx.agents
	counter.calls = make([dynamic]string, context.temp_allocator)
	read_counter = counter
	r := &fx.repo
	r.get_chain = proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
		rc_note("get_chain"); return read_counter.inner.get_chain(ctx, id)
	}
	r.get_task = proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
		t, ok, e := read_counter.inner.get_task(ctx, id); rc_note("get_task", 1 if ok else 0); return t, ok, e
	}
	r.list_tasks_by_chain = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID) -> ([]domain.Task, domain.Domain_Error) {
		out, e := read_counter.inner.list_tasks_by_chain(ctx, c, o); rc_note("list_tasks_by_chain", len(out)); return out, e
	}
	r.list_owed_reviews = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID, a: string, limit: int) -> ([]domain.Task, domain.Domain_Error) {
		out, e := read_counter.inner.list_owed_reviews(ctx, c, o, a, limit); rc_note("list_owed_reviews", len(out)); return out, e
	}
	r.list_assigned_ready = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID, a: string, limit: int) -> ([]domain.Task, domain.Domain_Error) {
		out, e := read_counter.inner.list_assigned_ready(ctx, c, o, a, limit); rc_note("list_assigned_ready", len(out)); return out, e
	}
	r.list_events_by_task = proc(ctx: rawptr, id: domain.Task_ID, o: domain.User_ID) -> ([]domain.Task_Event, domain.Domain_Error) {
		rc_note("list_events_by_task"); return read_counter.inner.list_events_by_task(ctx, id, o)
	}
	r.latest_event_id = proc(ctx: rawptr, id: domain.Task_ID, o: domain.User_ID) -> (i64, domain.Domain_Error) {
		rc_note("latest_event_id"); return read_counter.inner.latest_event_id(ctx, id, o)
	}
	r.list_fold_events_by_chain = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID) -> ([]domain.Task_Event, domain.Domain_Error) {
		rc_note("list_fold_events_by_chain"); return read_counter.inner.list_fold_events_by_chain(ctx, c, o)
	}
	r.list_ownership_stop_events = proc(ctx: rawptr, o: domain.User_ID) -> ([]domain.Task_Event, domain.Domain_Error) {
		rc_note("list_ownership_stop_events"); return read_counter.inner.list_ownership_stop_events(ctx, o)
	}
	r.list_attempts_by_task = proc(ctx: rawptr, id: domain.Task_ID, o: domain.User_ID) -> ([]domain.Task_Attempt, domain.Domain_Error) {
		rc_note("list_attempts_by_task"); return read_counter.inner.list_attempts_by_task(ctx, id, o)
	}
	r.list_facets_by_task = proc(ctx: rawptr, id: domain.Task_ID, o: domain.User_ID) -> ([]domain.Task_Attempt_Facet, domain.Domain_Error) {
		rc_note("list_facets_by_task"); return read_counter.inner.list_facets_by_task(ctx, id, o)
	}
	r.get_lease = proc(ctx: rawptr, id: string) -> (domain.Task_Lease, bool, domain.Domain_Error) {
		rc_note("get_lease"); return read_counter.inner.get_lease(ctx, id)
	}
	r.get_lease_by_holder = proc(ctx: rawptr, id: string) -> (domain.Task_Lease, bool, domain.Domain_Error) {
		rc_note("get_lease_by_holder"); return read_counter.inner.get_lease_by_holder(ctx, id)
	}
	r.list_leases_by_task = proc(ctx: rawptr, id: domain.Task_ID) -> ([]domain.Task_Lease, domain.Domain_Error) {
		rc_note("list_leases_by_task"); return read_counter.inner.list_leases_by_task(ctx, id)
	}
	r.list_leases_by_chain = proc(ctx: rawptr, c: domain.Task_Chain_ID) -> ([]domain.Task_Lease, domain.Domain_Error) {
		rc_note("list_leases_by_chain"); return read_counter.inner.list_leases_by_chain(ctx, c)
	}
	r.list_reviews_by_task = proc(ctx: rawptr, id: domain.Task_ID, o: domain.User_ID) -> ([]domain.Task_Review, domain.Domain_Error) {
		rc_note("list_reviews_by_task"); return read_counter.inner.list_reviews_by_task(ctx, id, o)
	}
	r.get_chain_summary = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID) -> (domain.Chain_Summary, bool, domain.Domain_Error) {
		rc_note("get_chain_summary"); return read_counter.inner.get_chain_summary(ctx, c, o)
	}
	r.list_fleets_by_chain = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID) -> ([]domain.Task_Chain_Fleet, domain.Domain_Error) {
		rc_note("list_fleets_by_chain"); return read_counter.inner.list_fleets_by_chain(ctx, c, o)
	}
	r.list_directories_by_chain = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID) -> ([]domain.Task_Chain_Directory, domain.Domain_Error) {
		rc_note("list_directories_by_chain"); return read_counter.inner.list_directories_by_chain(ctx, c, o)
	}
	r.list_members_by_chain = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
		rc_note("list_members_by_chain"); return read_counter.inner.list_members_by_chain(ctx, c, o)
	}
	r.list_dependencies_by_chain = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
		rc_note("list_dependencies_by_chain"); return read_counter.inner.list_dependencies_by_chain(ctx, c, o)
	}
	r.list_dependencies_by_task = proc(ctx: rawptr, id: domain.Task_ID, o: domain.User_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
		rc_note("list_dependencies_by_task"); return read_counter.inner.list_dependencies_by_task(ctx, id, o)
	}
	r.list_work_dependencies = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID) -> ([]domain.Work_Dependency, domain.Domain_Error) {
		rc_note("list_work_dependencies"); return read_counter.inner.list_work_dependencies(ctx, c, o)
	}
	r.list_work_dependencies_by_dependent = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID, item: domain.Work_Item_Ref) -> ([]domain.Work_Dependency, domain.Domain_Error) {
		rc_note("list_work_dependencies_by_dependent"); return read_counter.inner.list_work_dependencies_by_dependent(ctx, c, o, item)
	}
	r.list_work_receipts_by_dependent = proc(ctx: rawptr, c: domain.Task_Chain_ID, o: domain.User_ID, item: domain.Work_Item_Ref) -> ([]domain.Work_Input_Receipt, domain.Domain_Error) {
		rc_note("list_work_receipts_by_dependent"); return read_counter.inner.list_work_receipts_by_dependent(ctx, c, o, item)
	}
	a := &fx.agents
	a.get_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
		rc_note("agent_get_instance"); return read_counter.agents.get_instance(ctx, id)
	}
	a.list_instances_by_chain = proc(ctx: rawptr, o: domain.User_ID, c: string) -> ([]domain.Agent_Instance, domain.Domain_Error) {
		rc_note("agent_list_instances_by_chain"); return read_counter.agents.list_instances_by_chain(ctx, o, c)
	}
}

read_counter_uninstall :: proc(fx: ^Fixture, counter: ^Read_Counter) {
	fx.repo = counter.inner
	fx.agents = counter.agents
	read_counter = nil
}

read_counter_reset :: proc(counter: ^Read_Counter) {
	clear(&counter.calls)
	counter.task_rows = 0
}

// Lease_Next_Cost: what one `lease next` read.
Lease_Next_Cost :: struct {
	calls:     []string,
	task_rows: int,
	status:    string,
	pack:      bool,
	version:   string,
}

measure_lease_next :: proc(t: ^testing.T, fx: ^Fixture, counter: ^Read_Counter, inst: string, version := "") -> Lease_Next_Cost {
	read_counter_reset(counter)
	res, ok, err := lease_next(&fx.svc, inst_auth(inst), Lease_Next_Input{pack_version = version})
	testing.expectf(t, ok, "lease next %s: %s", inst, err.message)
	calls := make([]string, len(counter.calls), context.temp_allocator)
	copy(calls, counter.calls[:])
	return Lease_Next_Cost{calls = calls, task_rows = counter.task_rows, status = res.status, pack = res.pack_json != "", version = res.pack_version}
}

// ---- scenario ---------------------------------------------------------------------

// seed_background_tasks inserts `n` tasks into `chain_id` with SQL: done tasks
// assigned to the caller agent agt_c (reviewed by agt_r), backlog, ready work for
// another agent and reviews owed by another agent. None of them is the caller's
// work, so `lease next` must not read them.
seed_background_tasks :: proc(t: ^testing.T, fx: ^Fixture, chain_id, prefix: string, n: int) {
	if n <= 0 do return
	now := platform.clock_now(&fx.clock)
	sql := fmt.tprintf(`WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < %d)
INSERT INTO tasks (task_id, chain_id, owner_user_id, title, description, publish_state, state, kind, priority, attempt_no, brief_json, blocked_on_json, requires_user_approval, ready_since, bridge_id, stage_key, stage_index, generated_by_json, created_at, updated_at, published_at, started_at, completed_at, workflow_run_id, workflow_execution_no)
SELECT '%s' || i, '%s', 'u1', 'bg', '', 'published',
  CASE i %% 4 WHEN 0 THEN 'done' WHEN 1 THEN 'backlog' WHEN 2 THEN 'ready' ELSE 'in_review' END,
  'task', 'p0', 1,
  CASE i %% 4 WHEN 0 THEN '{"goal":"g","assignee":"agt_c","reviewers":["agt_r"]}' WHEN 2 THEN '{"goal":"g","assignee":"agt_x"}' ELSE '{"goal":"g","assignee":"agt_x","reviewers":["agt_y"]}' END,
  '', 0, '2000-01-01T00:00:00Z', '', '', 0, '', '%s', '%s', '%s', '', '', '', 0 FROM n;`, n - 1, prefix, chain_id, now, now, now)
	testing.expect(t, exec_ok(t, fx, sql), "seed background tasks")
}

Cost_Scenario :: struct {
	idle, waiting_full, waiting_same, grant, current_same, current_full: Lease_Next_Cost,
}

// run_cost_scenario: caller chain with `chain_tasks` tasks in all, plus
// `other_chains` chains of `chain_tasks` tasks each.
run_cost_scenario :: proc(t: ^testing.T, tag: string, chain_tasks, other_chains: int) -> (Cost_Scenario, bool) {
	out: Cost_Scenario
	fx, log, ok := lease_fixture(t, tag)
	defer lease_fixture_close(fx, log)
	if !ok do return out, false
	chain := seed_live_chain(t, fx, "chain_cost")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	// A worker whose submitted task waits for the user (waiting claim).
	_ = publish_task(t, fx, chain, "task_w", brief = `{"goal":"g","assignee":"agt_w","reviewers":["user"]}`)
	confirm_holder(fx, "inst_w1")
	if _, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "done", vcs_json = GREEN_VCS}); !testing.expectf(t, sok, "submit: %s", serr.message) do return out, false
	// Two tasks the coordinator pulls.
	_ = publish_task(t, fx, chain, "task_a", brief = `{"goal":"g","assignee":"agt_c","reviewers":["user"]}`)
	_ = publish_task(t, fx, chain, "task_b", brief = `{"goal":"g","assignee":"agt_c","reviewers":["user"]}`)
	seed_background_tasks(t, fx, "chain_cost", "bg_", chain_tasks - 3)
	for c in 0 ..< other_chains {
		other := seed_chain(t, fx, fmt.tprintf("chain_other_%d", c), true)
		seed_background_tasks(t, fx, string(other.chain_id), fmt.tprintf("bg_%d_", c), chain_tasks)
	}

	counter := new(Read_Counter, context.temp_allocator)
	read_counter_install(fx, counter)
	defer read_counter_uninstall(fx, counter)
	out.idle = measure_lease_next(t, fx, counter, "inst_r1")
	out.waiting_full = measure_lease_next(t, fx, counter, "inst_w1")
	out.waiting_same = measure_lease_next(t, fx, counter, "inst_w1", out.waiting_full.version)
	out.grant = measure_lease_next(t, fx, counter, "inst_coord")
	out.current_same = measure_lease_next(t, fx, counter, "inst_coord", out.grant.version)
	out.current_full = measure_lease_next(t, fx, counter, "inst_coord")
	return out, true
}

expect_same_cost :: proc(t: ^testing.T, path: string, small, large: Lease_Next_Cost) {
	same := len(small.calls) == len(large.calls)
	if same do for c, i in small.calls do if c != large.calls[i] { same = false; break }
	testing.expectf(t, same, "%s: reads differ with chain size\n  10 tasks/1 chain:      %v\n  1000 tasks/100 chains: %v", path, small.calls, large.calls)
	testing.expectf(t, small.task_rows == large.task_rows, "%s: task rows %d (small) vs %d (large)", path, small.task_rows, large.task_rows)
	testing.expectf(t, small.status == large.status, "%s: status %s vs %s", path, small.status, large.status)
	for c in large.calls {
		testing.expectf(t, c != "list_tasks_by_chain" && c != "list_dependencies_by_chain" && c != "list_work_dependencies" && c != "list_fold_events_by_chain", "%s reads the whole chain: %s", path, c)
	}
}

expect_reads_at_most :: proc(t: ^testing.T, path: string, cost: Lease_Next_Cost, bound: int) {
	testing.expectf(t, len(cost.calls) <= bound, "%s: %d reads > %d: %v", path, len(cost.calls), bound, cost.calls)
}

@(test)
test_lease_next_reads_do_not_grow_with_tasks_or_chains :: proc(t: ^testing.T) {
	small, sok := run_cost_scenario(t, "lease_next_cost_small", 10, 0)
	if !sok do return
	large, lok := run_cost_scenario(t, "lease_next_cost_large", 1000, 99)
	if !lok do return

	// The scenario reached every path.
	testing.expect_value(t, large.idle.status, "none")
	testing.expect_value(t, large.waiting_full.status, "waiting")
	testing.expect_value(t, large.waiting_same.status, "waiting")
	testing.expect_value(t, large.grant.status, "granted")
	testing.expect_value(t, large.current_same.status, "current")
	testing.expect_value(t, large.current_full.status, "current")

	// The wrapper saw the reads (an empty list would make every comparison pass).
	has :: proc(cost: Lease_Next_Cost, name: string) -> bool {
		for c in cost.calls do if c == name do return true
		return false
	}
	testing.expect(t, has(large.idle, "list_owed_reviews") && has(large.idle, "list_assigned_ready"), "idle uses the two index lookups")
	testing.expect(t, has(large.grant, "list_assigned_ready") && has(large.grant, "list_events_by_task"), "grant reads its candidate")
	testing.expect(t, has(large.waiting_same, "get_lease_by_holder") && has(large.current_same, "latest_event_id"), "held paths read the version inputs")

	expect_same_cost(t, "idle", small.idle, large.idle)
	expect_same_cost(t, "waiting (pack built)", small.waiting_full, large.waiting_full)
	expect_same_cost(t, "waiting (unchanged pack)", small.waiting_same, large.waiting_same)
	expect_same_cost(t, "grant", small.grant, large.grant)
	expect_same_cost(t, "current (unchanged pack)", small.current_same, large.current_same)
	expect_same_cost(t, "current (pack built)", small.current_full, large.current_full)

	// REQ-SCHED-40: the idle path reads no task row besides the two index
	// lookups (which found nothing) and builds no pack.
	testing.expect_value(t, large.idle.task_rows, 0)
	testing.expect(t, !large.idle.pack, "idle builds no pack")
	for c in large.idle.calls do testing.expectf(t, c != "get_task" && c != "list_events_by_task", "idle reads a task: %s", c)
	// Table 10.3 bounds. The counts include the caller's own instance lookup
	// (instance_from_auth), which the table does not list: idle <= 6 and
	// current <= 6 as in the table, waiting <= 5 + that lookup.
	expect_reads_at_most(t, "idle", large.idle, 6)
	expect_reads_at_most(t, "waiting (unchanged pack)", large.waiting_same, 5 + 1)
	expect_reads_at_most(t, "current (unchanged pack)", large.current_same, 6)
	// REQ-SCHED-39: an unchanged version builds nothing.
	testing.expect(t, large.waiting_full.pack && !large.waiting_same.pack, "waiting: pack only when the version changed")
	testing.expect(t, large.grant.pack && !large.current_same.pack && large.current_full.pack, "current: pack only when the version changed")
	testing.expect_value(t, large.current_same.version, large.grant.version)
	for c in large.waiting_same.calls do testing.expectf(t, c != "list_directories_by_chain" && c != "list_attempts_by_task", "unchanged pack still built: %s", c)
}

// ---- pack_version -----------------------------------------------------------------

// Every version input changes the version (spec SCHED 10.2 risk: a stale
// TASK.md if the version misses an input).
@(test)
test_pack_version_changes_with_each_input :: proc(t: ^testing.T) {
	task := domain.Task{task_id = "task_1", updated_at = "2026-01-01T00:00:00Z", state = .In_Progress, attempt_no = 1}
	lease := domain.Task_Lease{lease_id = "lease_1", phase = domain.LEASE_PHASE_ACTIVE}
	base := pack_version_from(task, lease, 10, 3)
	testing.expect_value(t, pack_version_from(task, lease, 10, 3), base)
	testing.expect(t, strings.has_prefix(base, "pv"), "versioned")
	variants := make([dynamic]string, context.temp_allocator)
	{ x := task; x.task_id = "task_2"; append(&variants, pack_version_from(x, lease, 10, 3)) }
	append(&variants, pack_version_from(task, lease, 11, 3))
	{ x := lease; x.lease_id = "lease_2"; append(&variants, pack_version_from(task, x, 10, 3)) }
	{ x := lease; x.phase = domain.LEASE_PHASE_WAITING; append(&variants, pack_version_from(task, x, 10, 3)) }
	append(&variants, pack_version_from(task, lease, 10, 4))
	{ x := task; x.updated_at = "2026-01-01T00:00:01Z"; append(&variants, pack_version_from(x, lease, 10, 3)) }
	{ x := task; x.state = .In_Review; append(&variants, pack_version_from(x, lease, 10, 3)) }
	{ x := task; x.attempt_no = 2; append(&variants, pack_version_from(x, lease, 10, 3)) }
	for v, i in variants {
		testing.expectf(t, v != base, "input %d does not change the version", i)
		for w, j in variants do if j != i do testing.expectf(t, v != w, "inputs %d and %d collide", i, j)
	}
}

// Through the engine: a requirements change, a task event and a chain summary
// change each move the version, so `lease next` sends a fresh pack; otherwise
// the pack is omitted.
@(test)
test_pack_version_follows_requirements_events_and_summary :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "pack_version_inputs")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_pack_version")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"]}`)
	confirm_holder(fx, "inst_w1")
	// The fixture chain is seeded published, so no publish rebuilt its summary;
	// a versioned pack needs the row (test_pack_version_empty_without_summary_row).
	if _, sok, serr := chain_summary_set(&fx.svc, user_auth(), chain.chain_id, "first note"); !testing.expectf(t, sok, "summary: %s", serr.message) do return
	auth := inst_auth("inst_w1")
	first, fok, ferr := lease_next(&fx.svc, auth, {})
	if !testing.expectf(t, fok && first.status == "current", "first: %s %s", first.status, ferr.message) do return
	testing.expect(t, first.pack_json != "" && first.pack_version != "", "a caller without a version gets the pack")
	same, _, _ := lease_next(&fx.svc, auth, {pack_version = first.pack_version})
	testing.expect_value(t, same.pack_version, first.pack_version)
	testing.expect_value(t, same.pack_json, "")

	// Requirements revision.
	requirements_test_change(t, fx, "task_1", `{"goal":"g2","acceptance":["a","b"]}`, 1)
	req, _, _ := lease_next(&fx.svc, auth, {pack_version = first.pack_version})
	testing.expect(t, req.pack_version != first.pack_version, "a requirements change moves the version")
	testing.expect(t, strings.contains(req.pack_json, `"revision":2`), "the fresh pack carries the new revision")
	settled, _, _ := lease_next(&fx.svc, auth, {pack_version = req.pack_version})
	testing.expect_value(t, settled.pack_json, "")

	// A task event (a heartbeat note).
	if _, hok, herr := lease_heartbeat(&fx.svc, auth, {note = "half way"}); !testing.expectf(t, hok, "heartbeat: %s", herr.message) do return
	beat, _, _ := lease_next(&fx.svc, auth, {pack_version = settled.pack_version})
	if beat.pack_version == settled.pack_version {
		// A heartbeat that writes no event leaves the pack as it was.
		testing.expect_value(t, beat.pack_json, "")
	} else {
		testing.expect(t, beat.pack_json != "", "a moved version sends the pack")
	}

	// Chain summary.
	if _, sok, serr := chain_summary_set(&fx.svc, user_auth(), chain.chain_id, "curated note"); !testing.expectf(t, sok, "summary: %s", serr.message) do return
	summ, _, _ := lease_next(&fx.svc, auth, {pack_version = beat.pack_version})
	testing.expect(t, summ.pack_version != beat.pack_version, "a chain summary change moves the version")
	testing.expect(t, strings.contains(summ.pack_json, "curated note"), "the fresh pack carries the summary")

	// A peek is never short-circuited by a stale version.
	peek, _, _ := lease_next(&fx.svc, auth, {peek = true})
	testing.expect(t, peek.pack_json != "", "peek without a version returns the pack")
}

// Spec 10.1 step 2: a review the agent's other instance already holds is not a
// candidate, so k leased items can never hide the (k+1)th owed review.
@(test)
test_owed_review_lookup_skips_reviews_leased_by_the_agent :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "owed_review_leased")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_owed_leased")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "running")
	now := platform.clock_now(&fx.clock)
	for id in ([]string{"task_r1", "task_r2"}) {
		task := seed_task(t, fx, chain, id, `{"goal":"g","assignee":"agt_w","reviewers":["agt_r"]}`)
		task.state = .In_Review
		task.publish_state = .Published
		task.attempt_no = 1
		_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	}
	_, lok, lerr := iface.taskchain_save_lease(&fx.repo, domain.Task_Lease{lease_id = "lease_r1", task_id = "task_r1", chain_id = chain.chain_id, owner_user_id = "u1", holder_instance_id = "inst_r1", kind = domain.LEASE_KIND_REVIEW, attempt_no = 1, bridge_id = "br_1", granted_at = now, confirmed_at = now, last_beat_at = now, phase = domain.LEASE_PHASE_ACTIVE, delivery = domain.LEASE_DELIVERY_INLINE})
	if !testing.expectf(t, lok, "save lease: %s", lerr.message) do return
	owed, err := iface.taskchain_list_owed_reviews(&fx.repo, chain.chain_id, "u1", "agt_r", 1)
	testing.expect(t, err.code == .None, err.message)
	if testing.expect_value(t, len(owed), 1) do testing.expect_value(t, string(owed[0].task_id), "task_r2")
}

// Without a chain_summaries row the pack shows the mechanical summary, which
// has no version: no version is returned and the pack is always built.
@(test)
test_pack_version_empty_without_summary_row :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "pack_version_no_summary")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_no_summary")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1")
	confirm_holder(fx, "inst_w1")
	testing.expect(t, exec_ok(t, fx, "DELETE FROM chain_summaries WHERE chain_id = 'chain_no_summary';"), "drop summary row")
	first, fok, ferr := lease_next(&fx.svc, inst_auth("inst_w1"), {})
	if !testing.expectf(t, fok, "lease next: %s", ferr.message) do return
	testing.expect_value(t, first.pack_version, "")
	again, _, _ := lease_next(&fx.svc, inst_auth("inst_w1"), {pack_version = "pv1-stale"})
	testing.expect(t, again.pack_json != "", "without a version the pack is always built")
}
