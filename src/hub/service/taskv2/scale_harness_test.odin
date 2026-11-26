package taskv2

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import dbt "odin_test:hub/platform/dbtelemetry"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import agent "odin_test:hub/service/agent"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"
import metrics "odin_test:lib/metrics"

// Scale H: opt-in load harness for the task engine (docs/reference/scale-harness.md).
//
// NOT part of any default test run: the test is only registered when the
// package is compiled with -define:HEIMDALL_SCALE_HARNESS=true (use
// scripts/scale-harness.sh). The helpers below always compile, so the harness
// cannot rot unnoticed.
//
// Scenario (sizes from the environment, defaults in brackets):
//   * HEIMDALL_SCALE_CHAINS [100] chains x HEIMDALL_SCALE_TASKS [1000] tasks,
//     seeded with SQL plus consistent event logs (fold-correct `migrated`
//     events): 70% done (created, migrated, submitted, approved, merged),
//     15% ready for the fleet worker agent, 15% in_review owed to an agent
//     outside the fleet.
//   * Per chain a fleet of agt_w (capacity 3) and agt_r (capacity 2): 3 worker
//     and 2 reviewer instances spread over 4 bridges, plus a coordinator.
//   * Phase 1 (serial): one caller drives HEIMDALL_SCALE_SERIAL_OPS [300]
//     lease next / submit / review events; every event is measured alone, so
//     its repository reads, SELECT statements and VM steps are exact.
//   * Phase 2 (concurrent): HEIMDALL_SCALE_THREADS [8] callers, each driving
//     HEIMDALL_SCALE_OPS [150] events over its share of the instances, while a
//     chaos thread takes bridges offline and back (instance terminal + bridge
//     hello) and fires due timers. Latency percentiles and lock waits come from
//     this phase.
//   * Phase 3 (boot): for each size in HEIMDALL_SCALE_BOOT [1000,10000,100000]
//     done tasks (over 100 chains, plus live ready/in_review work and confirmed
//     leases) a fresh Service runs rebuild_timers and then boot.
// Results are printed and written as JSON to HEIMDALL_SCALE_OUT (if set);
// scripts/scale_report.py turns two result files into the Markdown report.
// HEIMDALL_SCALE_DB_DIR puts the databases on disk (WAL, synchronous=NORMAL,
// as the hub runs them); unset uses :memory:.

SCALE_HARNESS :: #config(HEIMDALL_SCALE_HARNESS, false)

when SCALE_HARNESS {
	@(test)
	test_scale_harness :: proc(t: ^testing.T) {
		scale_harness_run(t)
	}
}

// ---- configuration ------------------------------------------------------------------

Scale_Config :: struct {
	label:      string,
	chains:     int,
	tasks:      int,
	threads:    int,
	ops:        int,
	serial_ops: int,
	boot_sizes: []int,
	db_dir:     string,
	out:        string,
}

scale_env_int :: proc(name: string, def: int) -> int {
	v := os.get_env(name, context.temp_allocator)
	if v == "" do return def
	n, ok := strconv.parse_int(v)
	return n if ok else def
}

scale_config :: proc() -> Scale_Config {
	c := Scale_Config{
		label      = strings.clone(os.get_env("HEIMDALL_SCALE_LABEL", context.temp_allocator)),
		chains     = scale_env_int("HEIMDALL_SCALE_CHAINS", 100),
		tasks      = scale_env_int("HEIMDALL_SCALE_TASKS", 1000),
		threads    = max(1, scale_env_int("HEIMDALL_SCALE_THREADS", 8)),
		ops        = scale_env_int("HEIMDALL_SCALE_OPS", 150),
		serial_ops = scale_env_int("HEIMDALL_SCALE_SERIAL_OPS", 300),
		db_dir     = strings.clone(os.get_env("HEIMDALL_SCALE_DB_DIR", context.temp_allocator)),
		out        = strings.clone(os.get_env("HEIMDALL_SCALE_OUT", context.temp_allocator)),
	}
	if c.label == "" do c.label = "run"
	sizes := os.get_env("HEIMDALL_SCALE_BOOT", context.temp_allocator)
	if sizes == "" do sizes = "1000,10000,100000"
	list := make([dynamic]int)
	for part in strings.split(sizes, ",", context.temp_allocator) {
		if n, ok := strconv.parse_int(strings.trim_space(part)); ok && n > 0 do append(&list, n)
	}
	c.boot_sizes = list[:]
	return c
}

// ---- event samples ------------------------------------------------------------------

Scale_Event :: enum u8 {
	Lease_Next_None,
	Lease_Next_Waiting,
	Lease_Next_Current,
	Lease_Next_Granted,
	Submit,
	Review,
	Bridge_Offline,
	Bridge_Hello,
	Timers,
}

SCALE_EVENT_LABELS := [Scale_Event]string {
	.Lease_Next_None    = "lease_next_none",
	.Lease_Next_Waiting = "lease_next_waiting",
	.Lease_Next_Current = "lease_next_current",
	.Lease_Next_Granted = "lease_next_granted",
	.Submit             = "submit",
	.Review             = "review",
	.Bridge_Offline     = "bridge_offline",
	.Bridge_Hello       = "bridge_hello",
	.Timers             = "timers",
}

Scale_Sample :: struct {
	kind:        Scale_Event,
	ok:          bool,
	ns:          i64,
	statements:  int,
	lock_wait:   i64, // app lock wait (tx_mutex and other DB-guarding app locks)
	conn_wait:   i64,
	exec_ns:     i64,
	match_ns:    i64,
	match_stmts: int,
	grants:      int, // instances woken with a run[] entry (grants pushed) by this event
	// serial phase only
	repo_reads:  int,
	task_rows:   int,
	selects:     u64,
	writes:      u64,
	vm_steps:    u64,
}

// Grants pushed by the matcher are observed as wake_agent run[] entries after
// commit, on the thread that ran the event.
@(thread_local) scale_tl_grants: int
scale_wakes_total: i64

scale_wake_observe :: proc(ctx: rawptr, cmd: Wake_Command) {
	run, ok := jsonx.extract_raw_array(cmd.body_json, "run", false, context.temp_allocator)
	if !ok do return
	n := strings.count(run, `"agent_instance_id"`)
	scale_tl_grants += n
	sync.atomic_add(&scale_wakes_total, i64(n))
}

// ---- sqlite statement counters (serial phase) ----------------------------------------

Scale_Sql_Counts :: struct { selects, writes, vm: u64 }

scale_sql_counts :: proc() -> (c: Scale_Sql_Counts) {
	m := &sqlite.sqlite_tm
	for k in sqlite.Conn_Kind {
		if s := m.statements[k][.Select]; s != nil do c.selects += sync.atomic_load(&s.value)
		for op in ([]sqlite.Op{.Insert, .Update, .Delete}) {
			if s := m.statements[k][op]; s != nil do c.writes += sync.atomic_load(&s.value)
		}
		if s := m.vm_steps[k][.Select]; s != nil do c.vm += sync.atomic_load(&s.value)
	}
	return
}

// ---- fixture ------------------------------------------------------------------------

Scale_Instance :: struct {
	id:       string,
	bridge:   int,
	reviewer: bool,
}

Scale_World :: struct {
	fx:        ^Fixture,
	log:       ^Wake_Log,
	path:      string,
	chains:    [dynamic]domain.Task_Chain,
	instances: [dynamic]Scale_Instance,
	bridges:   int,
	offline:   []bool, // bridge offline flags (atomic reads)
}

SCALE_BRIDGES :: 4

scale_open :: proc(t: ^testing.T, cfg: Scale_Config, tag: string) -> (^Scale_World, bool) {
	w := new(Scale_World)
	w.bridges = SCALE_BRIDGES
	w.offline = make([]bool, SCALE_BRIDGES)
	fx := new(Fixture)
	path := ":memory:"
	if cfg.db_dir != "" {
		path = fmt.aprintf("%s/scale_%s_%s.db", cfg.db_dir, cfg.label, tag)
		scale_remove_db(path)
	}
	w.path = path
	conn, opened, err := sqlite.open(path)
	if !testing.expectf(t, opened, "open %s: %s", path, err.message) do return w, false
	fx.conn = conn
	if !fixture_clone_migrated_into(t, &fx.conn) do return w, false
	if cfg.db_dir != "" {
		// The hub's production settings (app/wiring.odin).
		_ = sqlite.exec(&fx.conn, "PRAGMA journal_mode = WAL;")
		_ = sqlite.exec(&fx.conn, "PRAGMA synchronous = NORMAL;")
	}
	fixture_wire(fx)
	log := scale_attach_wake_log(fx)
	fx.svc.wake_observer = scale_wake_observe
	fx.svc.wake_observer_ctx = nil
	w.fx, w.log = fx, log
	return w, true
}

// scale_attach_wake_log wires the agent service exactly as lease_fixture
// (lease_test.odin) does; wakes are observed by scale_wake_observe.
scale_attach_wake_log :: proc(fx: ^Fixture) -> ^Wake_Log {
	log := new(Wake_Log)
	log.allocator = context.allocator
	log.cmds = make([dynamic]Wake_Command)
	log.providers = sqlite.new_provider_repository(&log.provider_impl, &fx.conn)
	log.projects = sqlite.new_project_repository(&log.project_impl, &fx.conn)
	log.content = sqlite.new_content_repository(&log.content_impl, &fx.conn)
	sink := project.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) { return true, {} }}
	log.service = agent.new_agent_service_with_runtime(&fx.agents, &fx.bridges, &log.projects, &log.content, &fx.repo, sink, &log.registry, &fx.clock, &fx.ids)
	log.service.providers = &log.providers
	fx.svc.agent_service = &log.service
	fx.svc.bridge_command_sink = sink
	init_task_metrics()
	return log
}

scale_remove_db :: proc(path: string) {
	os.remove(path)
	os.remove(fmt.tprintf("%s-journal", path))
	os.remove(fmt.tprintf("%s-wal", path))
	os.remove(fmt.tprintf("%s-shm", path))
}

scale_close :: proc(w: ^Scale_World) {
	path := w.path
	lease_fixture_close(w.fx, w.log)
	if path != ":memory:" do scale_remove_db(path)
}

scale_bridge_id :: proc(i: int) -> string { return fmt.tprintf("br_s%d", i) }

// Scale_Mix: background tasks per chain by seeded state.
Scale_Mix :: struct { done, ready, in_review: int }

// scale_mix_for: the main scenario's 70% done / 15% ready / 15% in_review.
scale_mix_for :: proc(tasks: int) -> Scale_Mix {
	done := tasks * 70 / 100
	ready := (tasks - done) / 2
	return Scale_Mix{done = done, ready = ready, in_review = tasks - done - ready}
}

// scale_seed builds `chains` chains with `mix` background tasks each, the
// fleets and instances, then lets the engine place work once per chain.
scale_seed :: proc(t: ^testing.T, w: ^Scale_World, chains: int, mix: Scale_Mix) -> bool {
	fx := w.fx
	for b in 0..<w.bridges do seed_bridge(fx, strings.clone(scale_bridge_id(b)))
	for a in ([]string{"agt_c", "agt_w", "agt_r", "agt_y"}) do seed_agent(fx, a)
	now := now_ms(&fx.clock)
	now_s := strings.clone(platform.clock_now(&fx.clock), runtime.heap_allocator())
	for c in 0..<chains {
		chain_id := fmt.aprintf("sc_%03d", c)
		chain := seed_chain(t, fx, chain_id, true)
		chain.coordinator_agent_instance_id = fmt.aprintf("co_%03d", c)
		_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
		append(&w.chains, chain)
		seed_instance(fx, chain, chain.coordinator_agent_instance_id, "agt_c", scale_bridge_id(c % w.bridges), "running", "coordinator")
		seed_fleet(fx, chain, "agt_w", capacity = 3)
		seed_fleet(fx, chain, "agt_r", capacity = 2)
		for k in 0..<3 {
			id := fmt.aprintf("w_%03d_%d", c, k)
			b := (c + k) % w.bridges
			seed_instance(fx, chain, id, "agt_w", scale_bridge_id(b), "idle")
			append(&w.instances, Scale_Instance{id = id, bridge = b})
		}
		for k in 0..<2 {
			id := fmt.aprintf("r_%03d_%d", c, k)
			b := (c + k + 3) % w.bridges
			seed_instance(fx, chain, id, "agt_r", scale_bridge_id(b), "idle")
			append(&w.instances, Scale_Instance{id = id, bridge = b, reviewer = true})
		}
		if !scale_seed_tasks(t, fx, chain_id, mix, now, now_s) do return false
		free_all(context.temp_allocator)
	}
	// One engine pass per chain places the ready work (warm-up, not measured).
	for chain in w.chains {
		err := fleet_changed(&fx.svc, chain)
		if !testing.expectf(t, err.code == .None, "fleet_changed %s: %s", chain.chain_id, err.message) do return false
		free_all(context.temp_allocator)
	}
	return true
}

// scale_seed_tasks inserts `n` tasks into `chain_id` and their event logs. The
// event logs fold to the seeded state (EV_MIGRATED carries it), so refold
// leaves the rows alone.
scale_seed_tasks :: proc(t: ^testing.T, fx: ^Fixture, chain_id: string, mix: Scale_Mix, now_ms_v: i64, now: string) -> bool {
	n := mix.done + mix.ready + mix.in_review
	if n <= 0 do return true
	done_n := mix.done
	ready_n := mix.ready
	prefix := fmt.tprintf("%s_t", chain_id)
	// state by index: [0, done_n) done, [done_n, done_n+ready_n) ready, rest in_review.
	sql := fmt.tprintf(`WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < %d)
INSERT INTO tasks (task_id, chain_id, owner_user_id, title, description, publish_state, state, kind, priority, attempt_no, brief_json, blocked_on_json, requires_user_approval, ready_since, bridge_id, stage_key, stage_index, generated_by_json, created_at, updated_at, published_at, started_at, completed_at, workflow_run_id, workflow_execution_no)
SELECT '%s' || printf('%%05d', i), '%s', 'u1', 'bg', '', 'published',
  CASE WHEN i < %d THEN 'done' WHEN i < %d THEN 'ready' ELSE 'in_review' END,
  'task', 'p2', CASE WHEN i < %d THEN 1 WHEN i < %d THEN 0 ELSE 1 END,
  CASE WHEN i < %d THEN '{{"goal":"g","assignee":"agt_w","reviewers":["agt_r"]}}' WHEN i < %d THEN '{{"goal":"g","assignee":"agt_w","reviewers":["agt_r"]}}' ELSE '{{"goal":"g","assignee":"agt_x","reviewers":["agt_y"]}}' END,
  '', 0, '%s', '', '', 0, '', '%s', '%s', '%s', '', CASE WHEN i < %d THEN '%s' ELSE '' END, '', 0 FROM n;`,
		n - 1, prefix, chain_id, done_n, done_n + ready_n, done_n, done_n + ready_n, done_n, done_n + ready_n, now, now, now, now, done_n, now)
	if !exec_ok(t, fx, sql) do return false
	ev := proc(t: ^testing.T, fx: ^Fixture, chain_id: string, ts: i64, kind, payload, where_clause: string) -> bool {
		return exec_ok(t, fx, fmt.tprintf(`INSERT INTO task_events (task_id, chain_id, owner_user_id, ts_ms, actor_kind, actor_id, kind, payload_json)
SELECT task_id, chain_id, owner_user_id, %d, 'hub', '', '%s', %s FROM tasks WHERE chain_id = '%s' AND %s ORDER BY task_id;`, ts, kind, payload, chain_id, where_clause))
	}
	ok := ev(t, fx, chain_id, now_ms_v, EV_CREATED, "'{}'", "1")
	ok = ok && ev(t, fx, chain_id, now_ms_v, EV_MIGRATED, `'{"from_status":"seed","published":true,"state":"' || state || '","attempt_no":' || attempt_no || '}'`, "1")
	ok = ok && ev(t, fx, chain_id, now_ms_v, EV_SUBMITTED, `'{"lease_id":"seed","attempt_no":1}'`, "state = 'done'")
	ok = ok && ev(t, fx, chain_id, now_ms_v, EV_APPROVED, `'{"attempt_no":1}'`, "state = 'done'")
	ok = ok && ev(t, fx, chain_id, now_ms_v, EV_MERGED, `'{"branch":"b","into":"main","head":"h","mode":"seed"}'`, "state = 'done'")
	return ok
}

// ---- driving one instance -------------------------------------------------------------

// scale_step drives one instance one step: lease next, then submit or review
// what it holds. Returns the samples (1 or 2).
scale_step :: proc(svc: ^Service, inst: Scale_Instance, out: ^[dynamic]Scale_Sample, serial: bool) {
	auth := inst_auth(inst.id)
	res: Lease_Next_Result
	ok: bool
	s := scale_measure(serial, proc(svc: ^Service, auth: rawptr, res: rawptr) -> bool {
		r, ok, _ := lease_next(svc, (^contracts_auth)(auth)^, {})
		(^Lease_Next_Result)(res)^ = r
		return ok
	}, svc, &auth, &res)
	ok = s.ok
	switch res.status {
	case "granted": s.kind = .Lease_Next_Granted
	case "current": s.kind = .Lease_Next_Current
	case "waiting": s.kind = .Lease_Next_Waiting
	case:           s.kind = .Lease_Next_None
	}
	append(out, s)
	if !ok || (res.status != "granted" && res.status != "current") || res.lease.phase != domain.LEASE_PHASE_ACTIVE do return
	lease := res.lease
	if lease.kind == domain.LEASE_KIND_WORK {
		sub_in := Submit_Input{lease_id = lease.lease_id, summary = "scale", vcs_json = GREEN_VCS}
		sub := scale_measure(serial, proc(svc: ^Service, auth: rawptr, input: rawptr) -> bool {
			_, ok, _ := lease_submit(svc, (^contracts_auth)(auth)^, (^Submit_Input)(input)^)
			return ok
		}, svc, &auth, &sub_in)
		sub.kind = .Submit
		append(out, sub)
	} else if lease.kind == domain.LEASE_KIND_REVIEW {
		rev_in := Review_Input{lease_id = lease.lease_id, verdict = "approve"}
		rev := scale_measure(serial, proc(svc: ^Service, auth: rawptr, input: rawptr) -> bool {
			_, ok, _ := review_post(svc, (^contracts_auth)(auth)^, (^Review_Input)(input)^)
			return ok
		}, svc, &auth, &rev_in)
		rev.kind = .Review
		append(out, rev)
	}
}

contracts_auth :: contracts.Auth_Context

// scale_measure runs one event inside a DB telemetry scope and, in the serial
// phase, also counts repository reads and SQL statements by kind.
scale_measure :: proc(serial: bool, call: proc(svc: ^Service, a, b: rawptr) -> bool, svc: ^Service, a, b: rawptr) -> Scale_Sample {
	s: Scale_Sample
	before: Scale_Sql_Counts
	if serial {
		if read_counter != nil do read_counter_reset(read_counter)
		before = scale_sql_counts()
	}
	scale_tl_grants = 0
	dbt.scope_begin(.Other)
	t0 := time.tick_now()
	s.ok = call(svc, a, b)
	s.ns = i64(time.tick_since(t0))
	totals, _ := dbt.scope_end()
	s.statements = totals.statements
	s.lock_wait = totals.component[.App_Lock_Wait]
	s.conn_wait = totals.component[.Conn_Wait]
	s.exec_ns = totals.component[.Exec_Excl_Busy]
	s.match_ns = totals.phase[.Match].ns
	s.match_stmts = totals.phase[.Match].statements
	s.grants = scale_tl_grants
	if serial {
		after := scale_sql_counts()
		s.selects = after.selects - before.selects
		s.writes = after.writes - before.writes
		s.vm_steps = after.vm - before.vm
		if read_counter != nil {
			s.repo_reads = len(read_counter.calls)
			s.task_rows = read_counter.task_rows
		}
	}
	return s
}

scale_bridge_offline :: proc(w: ^Scale_World, b: int) -> bool {
	return sync.atomic_load(&w.offline[b])
}

// ---- concurrent phase ------------------------------------------------------------------

Scale_Worker :: struct {
	w:       ^Scale_World,
	insts:   [dynamic]Scale_Instance,
	ops:     int,
	samples: [dynamic]Scale_Sample,
}

Scale_Chaos :: struct {
	w:       ^Scale_World,
	stop:    bool,
	samples: [dynamic]Scale_Sample,
}

scale_worker_proc :: proc(wk: ^Scale_Worker) {
	context.allocator = runtime.heap_allocator()
	svc := &wk.w.fx.svc
	done := 0
	for i := 0; done < wk.ops; i += 1 {
		inst := wk.insts[i % len(wk.insts)]
		if scale_bridge_offline(wk.w, inst.bridge) do continue
		scale_step(svc, inst, &wk.samples, false)
		done += 1
		if done % 25 == 0 do fmt.printf("scale: caller %p %d/%d events\n", wk, done, wk.ops)
		free_all(context.temp_allocator)
	}
}

scale_chaos_proc :: proc(ch: ^Scale_Chaos) {
	context.allocator = runtime.heap_allocator()
	w := ch.w
	fx := w.fx
	round := 0
	for !sync.atomic_load(&ch.stop) {
		time.sleep(40 * time.Millisecond)
		b := round % w.bridges
		bridge := scale_bridge_id(b)
		// A bridge drops: callers on it go quiet, its instances turn
		// unreachable and hit the terminal chokepoint.
		sync.atomic_store(&w.offline[b], true)
		s := scale_disconnect(w, bridge)
		append(&ch.samples, s)
		time.sleep(20 * time.Millisecond)
		// Time passes and timers fire (lease stall, ready_unclaimed, ...).
		sync.atomic_add(&fx.clock_state.unix_seconds, 30)
		tm := scale_fire_timers(w)
		append(&ch.samples, tm)
		// The bridge comes back with its instances alive.
		hello := scale_reconnect(w, b)
		append(&ch.samples, hello)
		sync.atomic_store(&w.offline[b], false)
		round += 1
		free_all(context.temp_allocator)
	}
}

scale_disconnect :: proc(w: ^Scale_World, bridge: string) -> Scale_Sample {
	scale_tl_grants = 0
	dbt.scope_begin(.Other)
	t0 := time.tick_now()
	bridge_disconnect(w.fx, bridge)
	s := Scale_Sample{kind = .Bridge_Offline, ok = true, ns = i64(time.tick_since(t0))}
	scale_fill_totals(&s)
	return s
}

scale_fire_timers :: proc(w: ^Scale_World) -> Scale_Sample {
	scale_tl_grants = 0
	dbt.scope_begin(.Timer)
	t0 := time.tick_now()
	_ = fire_due(&w.fx.svc, now_ms(&w.fx.clock))
	s := Scale_Sample{kind = .Timers, ok = true, ns = i64(time.tick_since(t0))}
	scale_fill_totals(&s)
	return s
}

scale_reconnect :: proc(w: ^Scale_World, b: int) -> Scale_Sample {
	ids := make([dynamic]string, context.temp_allocator)
	for inst in w.instances do if inst.bridge == b do append(&ids, inst.id)
	for c, i in w.chains do if i % w.bridges == b do append(&ids, c.coordinator_agent_instance_id)
	bridge := scale_bridge_id(b)
	scale_tl_grants = 0
	dbt.scope_begin(.Other)
	t0 := time.tick_now()
	bridge_reconnect(w.fx, bridge, ids[:])
	on_bridge_hello(&w.fx.svc, bridge, ids[:])
	s := Scale_Sample{kind = .Bridge_Hello, ok = true, ns = i64(time.tick_since(t0))}
	scale_fill_totals(&s)
	return s
}

scale_fill_totals :: proc(s: ^Scale_Sample) {
	totals, _ := dbt.scope_end()
	s.statements = totals.statements
	s.lock_wait = totals.component[.App_Lock_Wait]
	s.conn_wait = totals.component[.Conn_Wait]
	s.exec_ns = totals.component[.Exec_Excl_Busy]
	s.match_ns = totals.phase[.Match].ns
	s.match_stmts = totals.phase[.Match].statements
	s.grants = scale_tl_grants
}

// ---- statistics ------------------------------------------------------------------------

Scale_Stats :: struct {
	n:              int,
	failed:         int,
	p50, p95, p99:  f64, // ms
	max_ms:         f64,
	mean_ms:        f64,
	statements:     f64,
	lock_wait_ms:   f64,
	conn_wait_ms:   f64,
	exec_ms:        f64,
	match_ms:       f64,
	match_stmts:    f64,
	repo_reads:     f64,
	task_rows:      f64,
	selects:        f64,
	writes:         f64,
	vm_steps:       f64,
}

scale_stats :: proc(samples: []Scale_Sample, filter: proc(s: Scale_Sample) -> bool) -> Scale_Stats {
	st: Scale_Stats
	lat := make([dynamic]i64, context.temp_allocator)
	for s in samples {
		if !filter(s) do continue
		st.n += 1
		if !s.ok do st.failed += 1
		append(&lat, s.ns)
		st.statements += f64(s.statements)
		st.lock_wait_ms += f64(s.lock_wait) / 1e6
		st.conn_wait_ms += f64(s.conn_wait) / 1e6
		st.exec_ms += f64(s.exec_ns) / 1e6
		st.match_ms += f64(s.match_ns) / 1e6
		st.match_stmts += f64(s.match_stmts)
		st.repo_reads += f64(s.repo_reads)
		st.task_rows += f64(s.task_rows)
		st.selects += f64(s.selects)
		st.writes += f64(s.writes)
		st.vm_steps += f64(s.vm_steps)
		st.mean_ms += f64(s.ns) / 1e6
	}
	if st.n == 0 do return st
	slice.sort(lat[:])
	pct :: proc(v: []i64, q: f64) -> f64 { return f64(v[min(len(v) - 1, int(q * f64(len(v))))]) / 1e6 }
	st.p50, st.p95, st.p99 = pct(lat[:], 0.50), pct(lat[:], 0.95), pct(lat[:], 0.99)
	st.max_ms = f64(lat[len(lat) - 1]) / 1e6
	n := f64(st.n)
	st.mean_ms /= n; st.statements /= n; st.lock_wait_ms /= n; st.conn_wait_ms /= n; st.exec_ms /= n
	st.match_ms /= n; st.match_stmts /= n; st.repo_reads /= n; st.task_rows /= n
	st.selects /= n; st.writes /= n; st.vm_steps /= n
	return st
}

scale_json_stats :: proc(b: ^strings.Builder, name: string, st: Scale_Stats, first: bool) {
	if !first do strings.write_string(b, ",")
	fmt.sbprintf(b, `"%s":{{"n":%d,"failed":%d,"p50_ms":%.3f,"p95_ms":%.3f,"p99_ms":%.3f,"max_ms":%.3f,"mean_ms":%.3f,"statements":%.1f,"lock_wait_ms":%.3f,"conn_wait_ms":%.3f,"exec_ms":%.3f,"match_ms":%.3f,"match_statements":%.1f,"repo_reads":%.1f,"task_rows":%.1f,"selects":%.1f,"writes":%.1f,"vm_steps":%.0f}}`,
		name, st.n, st.failed, st.p50, st.p95, st.p99, st.max_ms, st.mean_ms, st.statements, st.lock_wait_ms, st.conn_wait_ms, st.exec_ms, st.match_ms, st.match_stmts, st.repo_reads, st.task_rows, st.selects, st.writes, st.vm_steps)
}

// scale_json_by_kind writes one stats object per event kind plus "grant" (every
// event that pushed at least one grant, and inline grants).
@(thread_local) scale_want_kind: Scale_Event

scale_json_by_kind :: proc(b: ^strings.Builder, samples: []Scale_Sample) {
	strings.write_string(b, "{")
	first := true
	for k in Scale_Event {
		scale_want_kind = k
		st := scale_stats(samples, proc(s: Scale_Sample) -> bool { return s.kind == scale_want_kind })
		if st.n == 0 do continue
		scale_json_stats(b, SCALE_EVENT_LABELS[k], st, first)
		first = false
	}
	grant := scale_stats(samples, proc(s: Scale_Sample) -> bool { return s.grants > 0 || s.kind == .Lease_Next_Granted })
	if grant.n > 0 { scale_json_stats(b, "grant", grant, first); first = false }
	all := scale_stats(samples, proc(s: Scale_Sample) -> bool { return true })
	scale_json_stats(b, "all", all, first)
	strings.write_string(b, "}")
}

scale_json_locks :: proc(b: ^strings.Builder, prof: [dbt.Profile_Lock]dbt.Lock_Profile, wall_ns: i64, threads: int) {
	strings.write_string(b, "{")
	for l, i in dbt.Profile_Lock {
		p := prof[l]
		if i > 0 do strings.write_string(b, ",")
		caller_ns := f64(wall_ns) * f64(threads)
		fmt.sbprintf(b, `"%s":{{"acquisitions":%d,"contended":%d,"wait_ms":%.3f,"max_wait_ms":%.3f,"hold_ms":%.3f,"wait_share_of_caller_time":%.5f,"hold_share_of_wall":%.5f}}`,
			dbt.PROFILE_LOCK_LABELS[l], p.acquisitions, p.contended, f64(p.wait_ns) / 1e6, f64(p.max_wait_ns) / 1e6, f64(p.hold_ns) / 1e6,
			f64(p.wait_ns) / caller_ns if caller_ns > 0 else 0, f64(p.hold_ns) / f64(wall_ns) if wall_ns > 0 else 0)
	}
	strings.write_string(b, "}")
}

// ---- the run -----------------------------------------------------------------------------

scale_harness_run :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	cfg := scale_config()
	reg := new(metrics.Registry)
	metrics.registry_init(reg, runtime.heap_allocator())
	dbt.set_mode(.Basic)
	dbt.init(reg)
	sqlite.sqlite_telemetry_init(reg)
	defer dbt.set_mode(.Off)

	out: strings.Builder
	strings.builder_init(&out)
	fmt.sbprintf(&out, `{{"label":"%s","chains":%d,"tasks_per_chain":%d,"threads":%d,"ops_per_thread":%d,"serial_ops":%d,"db":"%s"`,
		cfg.label, cfg.chains, cfg.tasks, cfg.threads, cfg.ops, cfg.serial_ops, "file-wal" if cfg.db_dir != "" else "memory")

	// Off-path cost of the lock profile (acceptance: no measurable cost when off).
	scale_profile_overhead(&out)

	if cfg.chains > 0 && cfg.tasks > 0 {
		if !scale_load(t, cfg, &out) do return
	}
	strings.write_string(&out, `,"boot":[`)
	for size, i in cfg.boot_sizes {
		if i > 0 do strings.write_string(&out, ",")
		if !scale_boot(t, cfg, size, &out) do return
	}
	strings.write_string(&out, "]}")
	result := strings.to_string(out)
	fmt.printf("SCALE_RESULT %s\n", result)
	if cfg.out != "" {
		werr := os.write_entire_file(cfg.out, transmute([]u8)result)
		testing.expectf(t, werr == nil, "write %s: %v", cfg.out, werr)
	}
}

// scale_profile_overhead times an uncontended mutex lock/unlock three ways:
// plain sync, the profiled wrappers with the profile off, and on.
scale_profile_overhead :: proc(out: ^strings.Builder) {
	N :: 5_000_000
	mu: sync.Mutex
	run :: proc(mu: ^sync.Mutex, mode: int) -> f64 {
		t0 := time.tick_now()
		for _ in 0..<N {
			switch mode {
			case 0:
				sync.mutex_lock(mu)
				sync.mutex_unlock(mu)
			case:
				h := dbt.profiled_mutex_lock(mu, .Taskv2_State)
				dbt.profiled_mutex_unlock(mu, .Taskv2_State, h)
			}
		}
		return f64(time.tick_since(t0)) / f64(N)
	}
	best :: proc(mu: ^sync.Mutex, mode: int) -> f64 {
		b := max(f64)
		for _ in 0..<5 do b = min(b, run(mu, mode))
		return b
	}
	dbt.set_lock_profile(false)
	plain := best(&mu, 0)
	off := best(&mu, 1)
	dbt.set_lock_profile(true)
	on := best(&mu, 1)
	dbt.set_lock_profile(false)
	dbt.lock_profile_reset()
	fmt.sbprintf(out, `,"lock_profile_overhead_ns":{{"plain":%.2f,"profile_off":%.2f,"profile_on":%.2f}}`, plain, off, on)
}

scale_load :: proc(t: ^testing.T, cfg: Scale_Config, out: ^strings.Builder) -> bool {
	seed_t0 := time.tick_now()
	w, ok := scale_open(t, cfg, "load")
	defer scale_close(w)
	if !ok do return false
	if !scale_seed(t, w, cfg.chains, scale_mix_for(cfg.tasks)) do return false
	seed_ms := f64(time.tick_since(seed_t0)) / 1e6
	fmt.printf("scale: seeded %d chains x %d tasks in %.0f ms\n", cfg.chains, cfg.tasks, seed_ms)
	fmt.sbprintf(out, `,"seed_ms":%.0f`, seed_ms)

	// Phase 1: serial, exact reads per event.
	counter := new(Read_Counter)
	read_counter_install(w.fx, counter)
	counter.calls = make([dynamic]string, runtime.heap_allocator())
	serial := make([dynamic]Scale_Sample)
	serial_t0 := time.tick_now()
	for i := 0; i < cfg.serial_ops; i += 1 {
		scale_step(&w.fx.svc, w.instances[(i * 7) % len(w.instances)], &serial, true)
		free_all(context.temp_allocator)
		if (i + 1) % 25 == 0 do fmt.printf("scale: serial %d/%d events (%.0f s)\n", i + 1, cfg.serial_ops, time.duration_seconds(time.tick_since(serial_t0)))
	}
	read_counter_uninstall(w.fx, counter)
	strings.write_string(out, `,"serial":`)
	scale_json_by_kind(out, serial[:])

	// Phase 2: concurrent callers + bridge chaos.
	workers := make([]Scale_Worker, cfg.threads)
	for &wk, i in workers {
		wk.w = w
		wk.ops = cfg.ops
		wk.insts = make([dynamic]Scale_Instance)
		wk.samples = make([dynamic]Scale_Sample)
		for inst, j in w.instances do if j % cfg.threads == i do append(&wk.insts, inst)
	}
	chaos := new(Scale_Chaos)
	chaos.w = w
	chaos.samples = make([dynamic]Scale_Sample)
	dbt.lock_profile_reset()
	dbt.set_lock_profile(true)
	grants_before := sync.atomic_load(&scale_wakes_total)
	wall0 := time.tick_now()
	threads := make([]^thread.Thread, cfg.threads)
	for &wk, i in workers do threads[i] = thread.create_and_start_with_poly_data(&wk, scale_worker_proc)
	ct := thread.create_and_start_with_poly_data(chaos, scale_chaos_proc)
	for th in threads { thread.join(th); thread.destroy(th) }
	sync.atomic_store(&chaos.stop, true)
	thread.join(ct)
	thread.destroy(ct)
	wall := i64(time.tick_since(wall0))
	dbt.set_lock_profile(false)
	prof := dbt.lock_profile_snapshot()
	grants := sync.atomic_load(&scale_wakes_total) - grants_before

	all := make([dynamic]Scale_Sample)
	for wk in workers do append(&all, ..wk.samples[:])
	append(&all, ..chaos.samples[:])
	events := len(all)
	fmt.sbprintf(out, `,"concurrent":{{"wall_ms":%.1f,"events":%d,"events_per_s":%.1f,"grants_pushed":%d,"by_kind":`, f64(wall) / 1e6, events, f64(events) / (f64(wall) / 1e9), grants)
	scale_json_by_kind(out, all[:])
	strings.write_string(out, `,"locks":`)
	scale_json_locks(out, prof, wall, cfg.threads)
	strings.write_string(out, "}")
	fmt.printf("scale: concurrent phase %d events in %.0f ms\n", events, f64(wall) / 1e6)
	return true
}

// scale_boot: `done` done tasks over 100 chains (each chain also has 10 ready
// and 10 in_review tasks and the fleet's confirmed leases), then a fresh
// Service (a hub restart) runs rebuild_timers alone and boot.
scale_boot :: proc(t: ^testing.T, cfg: Scale_Config, done: int, out: ^strings.Builder) -> bool {
	chains := 100
	per_chain := done / chains
	w, ok := scale_open(t, cfg, fmt.tprintf("boot_%d", done))
	defer scale_close(w)
	if !ok do return false
	if !scale_seed(t, w, chains, Scale_Mix{done = per_chain, ready = 10, in_review = 10}) do return false
	// Confirm the pushed grants (in_progress work with live leases).
	for inst in w.instances {
		_, _, _ = lease_next(&w.fx.svc, inst_auth(inst.id), {})
		free_all(context.temp_allocator)
	}
	heap := runtime.heap_allocator()
	done_rows := strings.clone(scalar_text(w.fx, "SELECT count(*) FROM tasks WHERE state = 'done';"), heap)
	events := strings.clone(scalar_text(w.fx, "SELECT count(*) FROM task_events;"), heap)
	leases := strings.clone(scalar_text(w.fx, "SELECT count(*) FROM task_leases;"), heap)

	fresh :: proc(w: ^Scale_World) -> ^Service {
		fx := w.fx
		svc := new(Service)
		svc^ = new_service(&fx.repo, &fx.agents, &fx.bridges, &fx.clock, &fx.ids)
		svc.uow_factory = &fx.uow
		svc.agent_service = fx.svc.agent_service
		svc.bridge_command_sink = fx.svc.bridge_command_sink
		svc.wake_observer = scale_wake_observe
		return svc
	}
	before := scale_sql_counts()
	r := fresh(w)
	dbt.scope_begin(.Other)
	t0 := time.tick_now()
	rebuild_timers(r)
	rebuild_ns := i64(time.tick_since(t0))
	rt, _ := dbt.scope_end()
	mid := scale_sql_counts()
	armed_rebuild := timers_armed_count(r)
	free_all(context.temp_allocator)

	b := fresh(w)
	dbt.scope_begin(.Other)
	t1 := time.tick_now()
	boot(b)
	boot_ns := i64(time.tick_since(t1))
	bt, _ := dbt.scope_end()
	after := scale_sql_counts()
	armed_boot := timers_armed_count(b)
	free_all(context.temp_allocator)

	fmt.sbprintf(out, `{{"done_tasks":%s,"events":%s,"leases":%s,"rebuild_timers_ms":%.2f,"rebuild_timers_statements":%d,"rebuild_timers_selects":%d,"rebuild_timers_vm_steps":%d,"timers_armed":%d,"boot_ms":%.2f,"boot_statements":%d,"boot_selects":%d,"boot_vm_steps":%d,"boot_timers_armed":%d}}`,
		done_rows, events, leases, f64(rebuild_ns) / 1e6, rt.statements, mid.selects - before.selects, mid.vm - before.vm, armed_rebuild,
		f64(boot_ns) / 1e6, bt.statements, after.selects - mid.selects, after.vm - mid.vm, armed_boot)
	fmt.printf("scale: boot at %s done tasks: rebuild_timers %.1f ms, boot %.1f ms\n", done_rows, f64(rebuild_ns) / 1e6, f64(boot_ns) / 1e6)
	return true
}
