package taskv2

import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import dbt "odin_test:hub/platform/dbtelemetry"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import project "odin_test:hub/service/project"

import lockorder "odin_test:lib/lockorder"
import jsonx "odin_test:lib/jsonx"

// Service is the Task System v2 engine: events + fold (M0), leases, timers and
// the matcher (M1). It sits BELOW the taskchain service (which calls into it on
// every chain/task mutation) and above the agent service (JIT instances, bridge
// lookups, wakes).
//
// Concurrency contract: every entry point that mutates state is exactly ONE
// unit of work (with_uow: begin_uow / end_uow) under sqlite.tx_mutex, and
// lockorder (src/lib/lockorder) enforces tx_mutex -> state_mutex. Nothing in a UoW
// touches the network; bridge wakes and user-event publishes are queued on an
// Effects list and flushed AFTER commit.
Service :: struct {
	// Unset keeps the catalog v1 legacy notices enabled during dual-run.
	legacy_event_notices: Maybe(bool),
	repo:                ^iface.Taskchain_Repository,
	agents:              ^iface.Agent_Repository,
	bridges:             ^iface.Bridge_Repository,
	clock:               ^platform.Clock,
	ids:                 ^platform.ID_Generator,
	// uow_factory may be nil (unit tests over fake repos): mutations then run
	// without a transaction, which is fine for in-memory fakes.
	uow_factory:         ^iface.Unit_Of_Work_Factory,
	agent_service:       ^agent.Agent_Service,
	bridge_command_sink: project.Bridge_Command_Sink,
	event_bus:           ^events.User_Event_Bus,
	// on_tasks_changed is called AFTER commit whenever a task of `chain_id`
	// reached a terminal state or left one, so the owning taskchain service can
	// auto-complete / reopen the chain (sync_chain_status_from_tasks). It is a
	// callback because taskchain imports taskv2, not the other way round.
	on_tasks_changed:     proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID),
	on_tasks_changed_ctx: rawptr,
	// M1 state (timers / lease cache) lives behind this mutex; see timers.odin.
	state_mutex:         sync.Mutex,
	timers:              Timer_Service,
	// recent_expiries: holder → expiry time (ms) for the lease.next refusal
	// window; guarded by state_mutex, keys heap-owned (lease.odin).
	recent_expiries:     map[string]i64,
	// pending_touches: instance ids with a queued implicit heartbeat, drained
	// by the timer thread; guarded by state_mutex, keys heap-owned. Only used
	// once touch_async is set (start_timer_thread); otherwise touches are
	// written inline (unit tests).
	pending_touches:     map[string]struct{},
	// Instance IDs whose reported terminal state needs PTY-host evidence.
	pending_terminal_probes: map[string]struct{},
	touch_async:         bool,
	// merges_inflight: task ids whose merge-back job is running (sent, reply
	// not yet recorded); guarded by state_mutex, keys heap-owned (merge.odin).
	// A second job for the same task would race the first on one command_id.
	merges_inflight:     map[string]struct{},
	// wake_observer sees every wake_agent push after commit (tests).
	wake_observer:       proc(ctx: rawptr, cmd: Wake_Command),
	wake_observer_ctx:   rawptr,
	// notify_observer sees every 1-line coordinator attention notification after commit (tests).
	notify_observer:     proc(ctx: rawptr, instance_id, trigger, line: string),
	notify_observer_ctx: rawptr,
	// wake_coordinator (REQ-CIS-2) tries to start a stopped coordinator that was
	// sent a [taskv2] notice and says whether to retry; nil disables the wake
	// (bare tests). Called from the timer thread, off every taskv2 lock and
	// outside any UoW (coordinator_wake.odin).
	wake_coordinator:     proc(ctx: rawptr, owner, instance_id: string, now_ms: i64) -> Coordinator_Wake_Reply,
	wake_coordinator_ctx: rawptr,
	// pending_coordinator_wakes: coordinator instance -> pending wake, queued by
	// flush_effects and drained by the timer thread; guarded by state_mutex,
	// keys and owners heap-owned.
	pending_coordinator_wakes: map[string]Pending_Coordinator_Wake,
	// on_instance_changed runs after commit for every instance whose current
	// task pointer or idle stamp changed (wiring publishes agent_instance).
	on_instance_changed:     proc(ctx: rawptr, instance_id, change: string),
	on_instance_changed_ctx: rawptr,
	// vcs_show_file resolves a file at a commit on a chain directory via the bridge (M3 R2.2).
	vcs_show_file:       proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, directory_id, rev, file_path: string) -> (string, bool, domain.Domain_Error),
	vcs_show_file_ctx:   rawptr,
	// attention re-projects the user's attention card of every task an
	// event touched (attention deck), after commit. nil in bare tests.
	attention:           ^contracts.Attention_Notifier,
	// hold_stale_seconds: how long a held, unleased task waits before (and
	// between) hold_stale reminders to the coordinator; <= 0 uses
	// HOLD_STALE_SECONDS.
	hold_stale_seconds:  int,
	// lease_stall_seconds: silence window before a confirmed work lease's
	// holder is nudged, and again before the coordinator is told
	// (lease_stall.odin). 0 uses LEASE_STALL_SECONDS; < 0 disables.
	lease_stall_seconds: int,
	// Coordinator idle-stop timers (coordinator_idle.odin, REQ-CIS-1): seconds
	// after the last user event; 0 disables. Wiring copies Hub_Config.
	coordinator_idle_completed_seconds: int,
	coordinator_idle_seconds:           int,
	// coordinator_stop replaces agent.stop_instance for idle stops (tests);
	// returns whether the stop was sent.
	coordinator_stop:     proc(ctx: rawptr, owner: domain.User_ID, instance_id, reason: string) -> bool,
	coordinator_stop_ctx: rawptr,
	// content: chat inbox reads for the idle-stop unread-user-input guard.
	// nil (bare tests) skips that guard.
	content:              ^iface.Content_Repository,
}

// state_lock / state_unlock take Service.state_mutex. They are sync.mutex_lock
// / unlock plus the opt-in lock-wait profile (dbtelemetry lock_profile.odin,
// off by default: one relaxed atomic load). Pair them:
// `held := state_lock(svc); defer state_unlock(svc, held)`.
state_lock :: #force_inline proc(svc: ^Service) -> i64 {
	return dbt.profiled_mutex_lock(&svc.state_mutex, .Taskv2_State)
}

state_unlock :: #force_inline proc(svc: ^Service, acquired: i64) {
	dbt.profiled_mutex_unlock(&svc.state_mutex, .Taskv2_State, acquired)
}

new_service :: proc(repo: ^iface.Taskchain_Repository, agents: ^iface.Agent_Repository, bridges: ^iface.Bridge_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Service {
	init_task_metrics()
	return Service{repo = repo, agents = agents, bridges = bridges, clock = clock, ids = ids}
}

// Trigger names the event that caused a chain re-evaluation; it labels
// heimdall_task_matcher_runs_total{trigger} (never an id).
Trigger :: enum {
	Boot,
	Chain_Published,
	Task_Published,
	Task_Created,
	Task_Updated,
	Dep_Added,
	Dep_Removed,
	Lease_Released,
	Lease_Expired,
	Review_Posted,
	Fleet_Changed,
	Instance_Terminal,
	Bridge_Hello,
	Chain_Closed,
	Task_Cancelled,
	Task_Reopened,
	Timer,
	Lease_Next,
	Start_Success,
}

trigger_label :: proc(t: Trigger) -> string {
	switch t {
	case .Boot: return "boot"
	case .Chain_Published: return "chain_published"
	case .Task_Published: return "task_published"
	case .Task_Created: return "task_created"
	case .Task_Updated: return "task_updated"
	case .Dep_Added: return "dep_added"
	case .Dep_Removed: return "dep_removed"
	case .Lease_Released: return "lease_released"
	case .Lease_Expired: return "lease_expired"
	case .Review_Posted: return "review_posted"
	case .Fleet_Changed: return "fleet_changed"
	case .Instance_Terminal: return "instance_terminal"
	case .Bridge_Hello: return "bridge_hello"
	case .Chain_Closed: return "chain_closed"
	case .Task_Cancelled: return "task_cancelled"
	case .Task_Reopened: return "task_reopened"
	case .Timer: return "timer"
	case .Lease_Next: return "lease_next"
	case .Start_Success: return "start_success"
	}
	return "unknown"
}

// ---- unit of work + post-commit effects ----------------------------------------

// Effects collects the side effects a UoW decided on; they run after COMMIT.
Effects :: struct {
 fenced_stops: [dynamic]Fenced_Stop,
 tickets: [dynamic]^agent.Start_Ticket,
	// wake runs/stops keyed by bridge id (see wake.odin, M1).
	runs:        map[string][dynamic]Lease_Wake,
	stops:       map[string][dynamic]string,
	// resource_changed publishes: (owner, resource, id, change)
	publishes:   [dynamic]Publish_Effect,
	// chains whose task set changed terminal-ness (→ on_tasks_changed).
	changed_chains: [dynamic]Changed_Chain,
	// JIT launch reservations taken in the bridge runtime registry during this
	// UoW; cancelled on rollback (the instance row is rolled back with the tx).
	reservations: [dynamic]Jit_Reservation,
	// 1-line coordinator attention notifications (M3 §3c), flushed after commit.
	notifications: [dynamic]Coordinator_Notification,
	// task-branch merge-backs for tasks that became done (merge.odin).
	merges: [dynamic]Merge_Effect,
	// one-line nudges typed into an agent's terminal (F2 resume after outage).
	nudges: [dynamic]Agent_Nudge,
	// tasks whose attention card may have changed (any event or projection
	// change); heap-cloned, deduplicated at flush.
	attention_tasks: [dynamic]Attention_Effect,
	// keys owns the (bridge × chain) map keys of runs/stops (heap-cloned per
	// UoW, freed in destroy_effects — never the request's temp allocator).
	keys: [dynamic]string,
	// Resolved wake selections must survive until the outer commit flushes.
	owned_strings: [dynamic]string,
	// instances this UoW created or whose current-task pointer it rewrote
	// (REQ-2); ids are owned by owned_strings, deduplicated per (id, change).
	instances: [dynamic]Instance_Effect,
}

// Coordinator_Notification is one [taskv2] notice. task_id + expected_state
// name the task it is about and the state that made it relevant; flush_effects
// re-reads the task after commit and drops the notice when the state moved
// (notice_still_relevant). Chain-scoped notices (proposal_decided, workflow_*,
// summary_overflow) carry an empty task_id and are not re-checked.
Coordinator_Notification :: struct {
	coordinator_instance_id: string,
	bridge_id:               string,
	chain_id:                string,
	owner:                   string,
	trigger:                 string,
	line:                    string,
	task_id:                 string,
	expected_state:          string,
}

// effects_key returns the owned "<bridge>\x00<chain>" key for runs/stops,
// cloning it once per UoW.
effects_key :: proc(e: ^Effects, bridge_id, chain_id: string) -> string {
	probe := fmt.tprintf("%s\x00%s", bridge_id, chain_id)
	for k in e.keys do if k == probe do return k
	owned := strings.clone(probe)
	append(&e.keys, owned)
	return owned
}

Jit_Reservation :: struct {
	bridge_id:   string,
	generation:  int,
	instance_id: string,
}

Attention_Effect :: struct {
	owner:   string,
	task_id: string,
}

// effect_attention queues `task` for an attention-card re-projection.
effect_attention :: proc(u: ^Uow, task: domain.Task) {
	if u == nil || task.task_id == "" do return
	for a in u.effects.attention_tasks do if a.task_id == string(task.task_id) do return
	append(&u.effects.attention_tasks, Attention_Effect{owner = strings.clone(string(task.owner_user_id)), task_id = strings.clone(string(task.task_id))})
}

Publish_Effect :: struct {
	owner:       string,
	resource:    string,
	resource_id: string,
	change:      string,
	chain_id:    string,
	// REQ-2: workflow events name their run (and, for stage_changed, the
	// stage); empty for ordinary task/chain publishes and then omitted.
	workflow_run_id: string,
	stage_key:       string,
	// task/facet_changed: which attempt facet was (re)written.
	attempt_no: int,
	facet_kind: string,
}

Changed_Chain :: struct {
	chain_id: domain.Task_Chain_ID,
	owner:    domain.User_ID,
}

Uow :: struct {
	tx:      iface.Unit_Of_Work,
	has_tx:  bool,
	effects: Effects,
	// actor_instance_id: the agent instance whose action this unit of work
	// records (first agent/coordinator actor of record_event, or the instance
	// reporting start-success). A notice is never sent to it: it caused the
	// change and already knows (rule c). Borrowed from the caller; only read
	// while the UoW is open.
	actor_instance_id: string,
	// scope: the match scope this unit of work owns (nil when nested).
	scope: ^Match_Scope,
}

// begin_uow opens the engine's unit of work (process-wide exclusive). A service
// without a uow_factory (tests) gets a no-op transaction.
begin_uow :: proc(svc: ^Service) -> (Uow, bool, domain.Domain_Error) {
	u := Uow{}
	u.effects.runs = make(map[string][dynamic]Lease_Wake)
	u.effects.stops = make(map[string][dynamic]string)
	u.effects.publishes = make([dynamic]Publish_Effect)
	u.effects.changed_chains = make([dynamic]Changed_Chain)
	u.effects.reservations = make([dynamic]Jit_Reservation)
	u.effects.notifications = make([dynamic]Coordinator_Notification)
	u.effects.merges = make([dynamic]Merge_Effect)
	u.effects.nudges = make([dynamic]Agent_Nudge)
	u.effects.attention_tasks = make([dynamic]Attention_Effect)
	u.effects.keys = make([dynamic]string)
	u.effects.instances = make([dynamic]Instance_Effect)
	if svc.uow_factory == nil {
		lockorder.assert_tx_mutex_allowed()
		u.scope = match_scope_begin()
		return u, true, domain.Domain_Error{}
	}
	tx, ok, err := iface.unit_of_work_begin(svc.uow_factory)
	if !ok do return u, false, err
	u.tx = tx
	u.has_tx = true
	// An outermost transaction never inherits a scope: one left behind by a
	// caller that skipped end_uow would otherwise shadow every later match.
	if !tx.nested do match_scope_reset()
	u.scope = match_scope_begin()
	return u, true, domain.Domain_Error{}
}

// end_uow commits (ok) or rolls back (!ok) and, on commit, flushes the effects
// — network I/O strictly after the lock is released. A NESTED unit of work
// (SAVEPOINT inside a caller's transaction) hands its effects to the outer
// transaction's after-commit hooks instead of flushing under the lock (S7).
end_uow :: proc(svc: ^Service, u: ^Uow, ok: bool) -> (bool, domain.Domain_Error) {
	committed := ok
	err := domain.Domain_Error{}
	nested := u.has_tx && u.tx.nested
	if u.has_tx {
		if ok && nested {
			// Register BEFORE the savepoint release so a failed release drops it.
			d := new(Deferred_Effects)
			d.svc = svc
			d.effects = u.effects
			if iface.unit_of_work_after_commit(&u.tx, iface.After_Commit_Hook{ctx = rawptr(d), run = deferred_effects_run, discard=deferred_effects_discard}) {
				u.effects = Effects{} // ownership moved
			} else {
				free(d)
				nested = false
			}
		}
		if ok {
			committed, err = iface.unit_of_work_commit(&u.tx)
		} else {
			iface.unit_of_work_rollback(&u.tx)
		}
		// A rolled-back savepoint took its events with it.
		if !committed do fold_cache_invalidate()
		u.has_tx = false
	}
	if committed && !nested do flush_effects(svc, &u.effects)
	else if !committed do cancel_reservations(svc, &u.effects)
	destroy_effects(&u.effects)
	match_scope_end(u.scope)
	u.scope = nil
	return committed, err
}

Deferred_Effects :: struct {
	svc:     ^Service,
	effects: Effects,
}

// Move a successfully released savepoint's effects into its parent. Payloads
// and owned map keys transfer with the arrays; only source containers are freed.
move_effects :: proc(dst, src: ^Effects) {
 append(&dst.tickets, ..src.tickets[:]); delete(src.tickets)
 append(&dst.fenced_stops,..src.fenced_stops[:]);delete(src.fenced_stops)
	for key, entries in src.runs {
		current := dst.runs[key]
		for entry in entries {
			replaced := false
			for &existing in current {
				if existing.agent_instance_id == entry.agent_instance_id { existing = entry; replaced = true }
			}
			if !replaced do append(&current, entry)
			// Preserve effect_wake_lease's restart-wins rule across the
			// savepoint boundary: a released old lease may have queued a stop.
			stops := dst.stops[key]
			for i := len(stops) - 1; i >= 0; i -= 1 {
				if stops[i] == entry.agent_instance_id do ordered_remove(&stops, i)
			}
			dst.stops[key] = stops
		}
		dst.runs[key] = current
		delete(entries)
	}
	for key, entries in src.stops {
		current := dst.stops[key]
		for entry in entries {
			already_present := false
			for run in dst.runs[key] do if run.agent_instance_id == entry { already_present = true; break }
			for stop in current do if stop == entry { already_present = true; break }
			if !already_present do append(&current, entry)
		}
		dst.stops[key] = current
		delete(entries)
	}
	delete(src.runs)
	delete(src.stops)
	append(&dst.publishes, ..src.publishes[:]); delete(src.publishes)
	append(&dst.changed_chains, ..src.changed_chains[:]); delete(src.changed_chains)
	append(&dst.reservations, ..src.reservations[:]); delete(src.reservations)
	append(&dst.notifications, ..src.notifications[:]); delete(src.notifications)
	append(&dst.merges, ..src.merges[:]); delete(src.merges)
	append(&dst.nudges, ..src.nudges[:]); delete(src.nudges)
	append(&dst.attention_tasks, ..src.attention_tasks[:]); delete(src.attention_tasks)
	append(&dst.keys, ..src.keys[:]); delete(src.keys)
	append(&dst.owned_strings, ..src.owned_strings[:]); delete(src.owned_strings)
	for e in src.instances { seen := false; for d in dst.instances do if d == e { seen = true; break }; if !seen do append(&dst.instances, e) }
	delete(src.instances)
	src^ = Effects{}
}

@(private = "file")
deferred_effects_run :: proc(ctx: rawptr) {
	d := (^Deferred_Effects)(ctx)
	if d == nil do return
	flush_effects(d.svc, &d.effects)
	destroy_effects(&d.effects)
	free(d)
}

@(private = "file")
deferred_effects_discard :: proc(ctx:rawptr) {
	d:=(^Deferred_Effects)(ctx)
	if d==nil do return
	cancel_reservations(d.svc,&d.effects)
	destroy_effects(&d.effects)
	free(d)
}

@(private = "package")
cancel_reservations :: proc(svc: ^Service, e: ^Effects) {
	if svc.agent_service == nil do return
	for ticket in e.tickets do agent.start_cancel(svc.agent_service, ticket)
	for r in e.reservations {
		project.bridge_runtime_instance_cancel_reservation(svc.agent_service.bridge_runtime_registry, r.bridge_id, r.generation, r.instance_id)
	}
}

@(private = "package")
destroy_effects :: proc(e: ^Effects) {
 for ticket in e.tickets { agent.start_ticket_destroy(ticket); free(ticket) }
 delete(e.tickets)
 delete(e.fenced_stops)
	for _, entries in e.runs do delete(entries)
	delete(e.runs)
	for _, entries in e.stops do delete(entries)
	delete(e.stops)
	delete(e.publishes)
	delete(e.changed_chains)
	delete(e.reservations)
	for n in e.notifications {
		delete(n.coordinator_instance_id)
		delete(n.bridge_id)
		delete(n.chain_id)
		delete(n.owner)
		delete(n.trigger)
		delete(n.line)
		delete(n.task_id)
		delete(n.expected_state)
	}
	delete(e.notifications)
	for m in e.merges do destroy_merge_effect(m)
	delete(e.merges)
	for n in e.nudges { delete(n.instance_id); delete(n.bridge_id); delete(n.line) }
	delete(e.nudges)
	for a in e.attention_tasks { delete(a.owner); delete(a.task_id) }
	delete(e.attention_tasks)
	for k in e.keys do delete(k)
	delete(e.keys)
	for s in e.owned_strings do delete(s)
	delete(e.owned_strings)
	delete(e.instances)
}

// agent_notice_command_json: a one-line notice for an agent's terminal, sent as
// the bridge's `notify_task_nudge` (task_id empty → never debounced), which
// delivers through the pty-host's agent path and SUBMITS it. Typing the line +
// "\r" as raw pty input does not: Claude's TUI takes a multi-byte write as a
// paste, so the "\r" became a newline and notices piled up unsent in the input
// box (found in the live solo check). Heap-allocated; the caller deletes it.
//
// notice_task_id / expected_state (N1): the task a [taskv2] notice is about and
// the state it was sent for, so the bridge can drop a queued notice that went
// stale before delivery. The top-level task_id stays empty on purpose: the
// bridge's 1.5 s per-(instance, task) debounce would DROP a second, different
// notice about the same task; the bridge decides how to coalesce (N2).
agent_notice_command_json :: proc(command_id, instance_id, chain_id, origin, line: string, notice_task_id := "", expected_state := "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"notify_task_nudge","origin":"`)
	contracts.write_json_string(&b, origin)
	strings.write_string(&b, `","command_id":"`)
	contracts.write_json_string(&b, command_id)
	strings.write_string(&b, `","agent_instance_id":"`)
	contracts.write_json_string(&b, instance_id)
	strings.write_string(&b, `","task_id":"","chain_id":"`)
	contracts.write_json_string(&b, chain_id)
	strings.write_string(&b, `","target_instance_id":"`)
	contracts.write_json_string(&b, instance_id)
	strings.write_string(&b, `","target_role":"`)
	contracts.write_json_string(&b, origin)
	strings.write_string(&b, `","action":"`)
	contracts.write_json_string(&b, origin)
	strings.write_string(&b, `","message":"`)
	contracts.write_json_string(&b, line)
	strings.write_string(&b, `","human_message":"`)
	contracts.write_json_string(&b, line)
	strings.write_string(&b, `","notice_task_id":"`)
	contracts.write_json_string(&b, notice_task_id)
	strings.write_string(&b, `","expected_state":"`)
	contracts.write_json_string(&b, expected_state)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

@(private = "file")
flush_effects :: proc(svc: ^Service, e: ^Effects) {
	flush_fenced_stops(svc,e)
	flush_wakes(svc, e)
	for n in e.notifications {
		if !notice_still_relevant(svc, n) {
			metric_notice_dropped(n.trigger)
			continue
		}
		if svc.notify_observer != nil {
			svc.notify_observer(svc.notify_observer_ctx, n.coordinator_instance_id, n.trigger, n.line)
		}
		queue_coordinator_wake(svc, n.coordinator_instance_id, n.owner)
		if n.bridge_id != "" && svc.bridge_command_sink.send_runtime_command != nil {
			cmd_id := platform.generate_id(svc.ids, "cmd_notify_")
			cmd_json := agent_notice_command_json(cmd_id, n.coordinator_instance_id, n.chain_id, n.trigger, n.line, n.task_id, n.expected_state)
			defer delete(cmd_json)
			_, _ = project.bridge_command_send_runtime(svc.bridge_command_sink, project.Runtime_Command{
				bridge_id  = n.bridge_id,
				command_id = cmd_id,
				body_json  = cmd_json,
			})
		}
		if svc.event_bus != nil {
			summary := fmt.tprintf("{{\"coordinator_instance_id\":\"%s\",\"chain_id\":\"%s\",\"trigger\":\"%s\",\"task_id\":\"%s\",\"expected_state\":\"%s\"}}", n.coordinator_instance_id, n.chain_id, n.trigger, n.task_id, n.expected_state)
			events.publish_resource_changed(svc.event_bus, n.owner, "coordinator_attention", n.coordinator_instance_id, n.trigger, summary)
		}
	}
	for p, i in e.publishes {
		if svc.event_bus == nil do continue
		// REQ-2/E12: a UoW that refolds a task several times (or writes several
		// facets of one kind) announces each distinct change once.
		duplicate := false
		for q in e.publishes[:i] do if q == p { duplicate = true; break }
		if duplicate do continue
		summary := fmt.tprintf("{{\"%s_id\":\"%s\",\"chain_id\":\"%s\"}}", p.resource, p.resource_id, p.chain_id)
		if p.resource == "workflow_run" {
			summary = fmt.tprintf("{{\"workflow_run_id\":\"%s\",\"chain_id\":\"%s\",\"stage_key\":\"%s\"}}", p.resource_id, p.chain_id, p.stage_key)
		} else if p.facet_kind != "" {
			summary = fmt.tprintf("{{\"task_id\":\"%s\",\"chain_id\":\"%s\",\"attempt_no\":%d,\"kind\":\"%s\"}}", p.resource_id, p.chain_id, p.attempt_no, p.facet_kind)
		} else if p.workflow_run_id != "" {
			summary = fmt.tprintf("{{\"%s_id\":\"%s\",\"chain_id\":\"%s\",\"workflow_run_id\":\"%s\"}}", p.resource, p.resource_id, p.chain_id, p.workflow_run_id)
		}
		events.publish_resource_changed(svc.event_bus, p.owner, p.resource, p.resource_id, p.change, summary)
	}
	if svc.on_instance_changed != nil {
		for i in e.instances do svc.on_instance_changed(svc.on_instance_changed_ctx, i.instance_id, i.change)
	}
	for c in e.changed_chains {
		if svc.on_tasks_changed != nil do svc.on_tasks_changed(svc.on_tasks_changed_ctx, c.chain_id, c.owner)
	}
	if svc.attention != nil {
		for a in e.attention_tasks do contracts.attention_notify(svc.attention, a.owner, contracts.ATTENTION_SOURCE_TASK, a.task_id)
	}
	flush_merges(svc, e)
	for n in e.nudges {
		if svc.bridge_command_sink.send_runtime_command == nil do break
		cmd_id := platform.generate_id(svc.ids, "cmd_nudge_")
		cmd_json := agent_notice_command_json(cmd_id, n.instance_id, "", "taskv2_nudge", n.line)
		defer delete(cmd_json)
		_, _ = project.bridge_command_send_runtime(svc.bridge_command_sink, project.Runtime_Command{bridge_id = n.bridge_id, command_id = cmd_id, body_json = cmd_json})
	}
}

Agent_Nudge :: struct {
	instance_id: string,
	bridge_id:   string,
	line:        string,
}

// effect_nudge_instance queues one line typed into an agent's terminal after
// commit; deduplicated per instance within the unit of work.
effect_nudge_instance :: proc(u: ^Uow, instance_id, bridge_id, line: string) {
	if u == nil || instance_id == "" || bridge_id == "" do return
	for n in u.effects.nudges do if n.instance_id == instance_id do return
	append(&u.effects.nudges, Agent_Nudge{instance_id = strings.clone(instance_id), bridge_id = strings.clone(bridge_id), line = strings.clone(first_line_trimmed(line))})
}

// effect_notify_coordinator queues a 1-line coordinator attention notification
// (plan §3c: proposal_decided, blocked_on human, budget_exhausted, oscillation,
// dispatch_failed, ready_unclaimed, chain_complete, review_requested_from_user, summary_overflow).
// task_id/expected_state make it re-checkable at send time (effect_notify_task
// fills them from a task); chain-scoped notices leave them empty. A notice
// addressed to the instance whose action this UoW records is dropped (rule c).
effect_notify_coordinator :: proc(svc: ^Service, u: ^Uow, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, trigger, line: string, task_id := "", expected_state := "") {
	if svc == nil || svc.repo == nil || u == nil || strings.trim_space(line) == "" do return
	if !legacy_event_notice_enabled(svc, trigger) do return
	coord_id := chain_coordinator_instance_id(svc, chain_id, owner)
	if coord_id == "" do return
	if u.actor_instance_id != "" && coord_id == u.actor_instance_id do return
	bridge_id := ""
	if svc.agents != nil {
		if inst, iok, _ := iface.agent_get_instance(svc.agents, coord_id); iok do bridge_id = inst.bridge_id
	}
	clean_line := first_line_trimmed(line)
	for existing in u.effects.notifications {
		if existing.coordinator_instance_id == coord_id && existing.trigger == trigger && existing.line == clean_line do return
	}
	append(&u.effects.notifications, Coordinator_Notification{
		coordinator_instance_id = strings.clone(coord_id),
		bridge_id               = strings.clone(bridge_id),
		chain_id                = strings.clone(string(chain_id)),
		owner                   = strings.clone(string(owner)),
		trigger                 = strings.clone(trigger),
		line                    = strings.clone(clean_line),
		task_id                 = strings.clone(task_id),
		expected_state          = strings.clone(expected_state),
	})
}

// effect_notify_task queues a notice about `task`, expecting it to still be in
// its current state when the notice is sent.
effect_notify_task :: proc(svc: ^Service, u: ^Uow, task: domain.Task, trigger, line: string) {
	effect_notify_coordinator(svc, u, task.chain_id, task.owner_user_id, trigger, line, string(task.task_id), domain.task_state_string(task.state))
}

// chain_coordinator_instance_id: the chain's coordinator column, else its
// coordinator member row; "" when the chain has none.
chain_coordinator_instance_id :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> string {
	chain, cok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	if !cok do return ""
	coord_id := strings.trim_space(chain.coordinator_agent_instance_id)
	if coord_id == "" {
		if members, merr := iface.taskchain_list_members_by_chain(svc.repo, chain_id, owner); merr.code == .None {
			for m in members do if m.role == "coordinator" && m.agent_instance_id != "" { coord_id = m.agent_instance_id; break }
		}
	}
	return coord_id
}

// notice_still_relevant (rule a) re-reads the task a notice is about AFTER
// commit and keeps the notice only while the task is still in the state it was
// queued for, plus per-trigger checks of what made it worth sending. A failed
// read keeps the notice: losing a relevant notice is worse than one extra turn.
// flush_effects also runs on persistent-heap threads (bridge WS reader, reaper,
// after-commit hooks), so the rows read here live in a scratch arena.
notice_still_relevant :: proc(svc: ^Service, n: Coordinator_Notification) -> bool {
	if n.task_id == "" || svc == nil || svc.repo == nil do return true
	scratch: Scratch
	context.allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	task, found, err := iface.taskchain_get_task(svc.repo, domain.Task_ID(n.task_id))
	if !found do return err.code != .None && err.code != .Not_Found
	if n.expected_state != "" && domain.task_state_string(task.state) != n.expected_state do return false
	switch n.trigger {
	case "coordinator_item_ready":
		// Still available after the matcher, and the coordinator still free
		// (REQ-SCHED-15): no lease of its own, and the item is not taken.
		if _, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, n.coordinator_instance_id); held do return false
		if task.state == .Ready {
			if leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id); lerr.code == .None {
				for l in leases do if l.kind == domain.LEASE_KIND_WORK do return false
			}
		} else if task.state == .In_Review {
			coord, cok, _ := iface.agent_get_instance(svc.agents, n.coordinator_instance_id)
			if !cok do return true
			if reviews, rerr := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id); rerr.code == .None && !agent_review_owed(reviews, task, coord.agent_id) do return false
		}
	case "hold_stale":
		if !task_is_held(task) do return false
	case "lease_stalled":
		if !lease_stall_notice_relevant(svc, task) do return false
	case "agent_not_running", "blocked_on human", "budget_exhausted", "oscillation":
		if strings.trim_space(task.blocked_on_json) == "" do return false
	case "review_requested_from_user":
		// A workflow gate may be the coordinator's to approve; its state check
		// above suffices. A ticket must still be the user's turn.
		if task.kind != .Gate && !awaits_user_review(svc, task) do return false
	}
	return true
}

first_line_trimmed :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if nl := strings.index_byte(t, '\n'); nl >= 0 do t = strings.trim_space(t[:nl])
	if cr := strings.index_byte(t, '\r'); cr >= 0 do t = strings.trim_space(t[:cr])
	return t
}

effect_publish_task :: proc(u: ^Uow, task: domain.Task, change: string) {
	append(&u.effects.publishes, Publish_Effect{owner = string(task.owner_user_id), resource = "task", resource_id = string(task.task_id), change = change, chain_id = string(task.chain_id)})
}

effect_publish_chain :: proc(u: ^Uow, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, change: string) {
	append(&u.effects.publishes, Publish_Effect{owner = string(owner), resource = "task_chain", resource_id = string(chain_id), change = change, chain_id = string(chain_id)})
}

// effect_instance_changed queues an after-commit agent_instance hint for an
// instance row this UoW rewrote; a rollback discards it with the rest.
// change is "current_task_changed" (pointer) or "created" (JIT instance).
effect_instance_changed :: proc(u: ^Uow, instance_id: string, change := "current_task_changed") {
	if u == nil || instance_id == "" do return
	for e in u.effects.instances do if e.instance_id == instance_id && e.change == change do return
	owned := strings.clone(instance_id)
	append(&u.effects.owned_strings, owned)
	append(&u.effects.instances, Instance_Effect{instance_id = owned, change = change})
}

Instance_Effect :: struct {
	instance_id: string,
	change:      string, // static literal, never freed
}

// effect_publish_workflow queues task_chain/workflow_<kind> naming the run, and
// effect_publish_workflow_stage queues workflow_run/stage_changed (REQ-2). The
// ids are cloned into owned_strings so they outlive the run rows they came from.
// effect_publish_facet queues task/facet_changed for an attempt facet write.
effect_publish_facet :: proc(u: ^Uow, task: domain.Task, attempt_no: int, kind: string) {
	if u == nil do return
	owned_kind := strings.clone(kind); append(&u.effects.owned_strings, owned_kind)
	append(&u.effects.publishes, Publish_Effect{owner = string(task.owner_user_id), resource = "task", resource_id = string(task.task_id), change = "facet_changed", chain_id = string(task.chain_id), attempt_no = attempt_no, facet_kind = owned_kind})
}

effect_publish_workflow :: proc(u: ^Uow, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, run_id: domain.Workflow_Run_ID, change: string) {
	if u == nil do return
	owned_run := strings.clone(string(run_id)); append(&u.effects.owned_strings, owned_run)
	owned_change := strings.clone(change); append(&u.effects.owned_strings, owned_change)
	append(&u.effects.publishes, Publish_Effect{owner = string(owner), resource = "task_chain", resource_id = string(chain_id), change = owned_change, chain_id = string(chain_id), workflow_run_id = owned_run})
}

effect_publish_workflow_stage :: proc(u: ^Uow, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, run_id: domain.Workflow_Run_ID, stage_key: string) {
	if u == nil || run_id == "" do return
	owned_run := strings.clone(string(run_id)); append(&u.effects.owned_strings, owned_run)
	owned_stage := strings.clone(stage_key); append(&u.effects.owned_strings, owned_stage)
	append(&u.effects.publishes, Publish_Effect{owner = string(owner), resource = "workflow_run", resource_id = owned_run, change = "stage_changed", chain_id = string(chain_id), stage_key = owned_stage})
}

// uow_note_actor remembers the first agent instance acting in this UoW (rule c).
uow_note_actor :: proc(u: ^Uow, actor: Actor) {
	if u == nil || u.actor_instance_id != "" || actor.id == "" do return
	if actor.kind == ACTOR_AGENT || actor.kind == ACTOR_COORDINATOR do u.actor_instance_id = actor.id
}

effect_tasks_changed :: proc(u: ^Uow, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) {
	for c in u.effects.changed_chains do if c.chain_id == chain_id do return
	append(&u.effects.changed_chains, Changed_Chain{chain_id = chain_id, owner = owner})
}

// ---- event recording + projection -----------------------------------------------

// record_event appends an event for `task` inside the current UoW and refolds
// the task's cached projection. It returns the refolded task row (saved) and
// its view. `tasks`/`deps` are the chain snapshot used for deps_done; pass nil
// to have them loaded.
record_event :: proc(svc: ^Service, u: ^Uow, task: domain.Task, actor: Actor, kind: string, payload_json: string, tasks: []domain.Task = nil, deps: []domain.Task_Dependency = nil) -> (domain.Task, Task_View, bool, domain.Domain_Error) {
	if _, ok, err := append_event(svc.repo, svc.clock, task, actor, kind, payload_json); !ok {
		return task, Task_View{}, false, err
	}
	uow_note_actor(u, actor)
	// Any event can change whether the task awaits the user — including ones
	// that leave the projection as it was (an agent's approve that hands the
	// gate to the user), so the card is re-projected per event, not per save.
	effect_attention(u, task)
	fresh, view, ok, err := refold_task(svc, u, task, tasks, deps)
	merge := task_merge_status(svc, fresh)
	if ok && (fresh.state == .Cancelled || (fresh.state == .Done && (merge.state == "none" || merge.state == "merged"))) {
		if !clear_task_claims_in_uow(svc, u, fresh) do return fresh, view, false, domain.domain_error(.Internal_Error, "failed to clear task claims")
	}
	return fresh, view, ok, err
}

// refold_task recomputes `task`'s view from its events and persists the
// projection fields when they changed. Terminal-ness changes are queued for the
// chain-status callback.
//
// With `skip_settled` (refold_chain inside after_chain_change) a task whose
// fold inputs are unchanged since its last refold in this call is returned
// as is, with an empty view: refolding it would be a no-op (see fold_cache).
refold_task :: proc(svc: ^Service, u: ^Uow, task: domain.Task, tasks: []domain.Task = nil, deps: []domain.Task_Dependency = nil, skip_settled := false) -> (domain.Task, Task_View, bool, domain.Domain_Error) {
	all_tasks := tasks
	all_deps := deps
	if all_tasks == nil {
		// Only this task's parents, never the whole chain (REQ-SCHED-38).
		parents, parent_deps, err := task_parent_rows(svc, task, all_deps)
		if err.code != .None do return task, Task_View{}, false, err
		all_tasks, all_deps = parents, parent_deps
	}
	have_deps := all_deps != nil
	if !have_deps do all_deps, have_deps = fold_cache_deps(task.chain_id, task.owner_user_id)
	if !have_deps {
		loaded, err := iface.taskchain_list_dependencies_by_chain(svc.repo, task.chain_id, task.owner_user_id)
		if err.code != .None do return task, Task_View{}, false, err
		all_deps = loaded
	}
	evs, ev_err := task_fold_events(svc, task)
	if ev_err.code != .None do return task, Task_View{}, false, ev_err
	deps_done, ready_err := task_dependencies_ready(svc, task, all_tasks, all_deps)
	if ready_err.code != .None do return task, Task_View{}, false, ready_err
	input := fold_input_for_task(task, deps_done)
	if skip_settled && fold_cache_settled(task, fold_key_for(task, evs, input)) do return task, Task_View{}, true, domain.Domain_Error{}
	view := fold_task(evs, input)
	now := platform.clock_now(svc.clock)
	next := apply_view_to_task(task, view, now)
	if projection_equal(task, next) {
		fold_cache_settle(task, fold_key_for(task, evs, input))
		return task, view, true, domain.Domain_Error{}
	}
	saved, ok, err := iface.taskchain_save_task(svc.repo, next)
	if !ok do return task, view, false, err
	match_scope_note_task(saved.chain_id, saved.task_id)
	fold_cache_settle(saved, fold_key_for(saved, evs, input))
	if cerr := catalog_task_projection(svc, task, saved, evs); cerr.code != .None do return task, view, false, cerr
	if saved.state != task.state {
		metric_task_transition(task.state, saved.state)
	}
	// Merge applicability is fixed at Done, before any later directory change.
	if saved.state == .Done && task.state != .Done {
		if serr := record_merge_snapshot(svc, saved); serr.code != .None do return task, view, false, serr
	}
	// Column-backed alerts: ready_unclaimed (ready_since) and blocked-on-human
	// re-alert (blocked_on_json) are armed whenever the column they key on moves.
	if saved.ready_since != task.ready_since || saved.blocked_on_json != task.blocked_on_json || saved.state != task.state {
		arm_task_timers(svc, saved)
	}
	if u != nil {
		effect_publish_task(u, saved, "updated")
		if domain.task_state_is_terminal(task.state) != domain.task_state_is_terminal(saved.state) {
			effect_tasks_changed(u, saved.chain_id, saved.owner_user_id)
		}
		// `tasks` (the caller's chain rows, or nil): all_tasks may hold only this
		// task's parents, which cannot say whether the whole batch finished.
		if cerr := check_coordinator_attention_on_refold(svc, u, task, saved, view, tasks); cerr.code != .None do return task, view, false, cerr
		if saved.state == .Done && task.state != .Done do effect_merge_worktree(svc, u, saved, evs)
		if (saved.state == .Ready || saved.state == .In_Review) && task.state != saved.state do nudge_coordinator_item(svc, u, task, saved)
	}
	return saved, view, true, domain.Domain_Error{}
}

// nudge_coordinator_item (REQ-SCHED-15): the hub never wakes a coordinator, so
// when an item for it becomes available — a task assigned to its agent becomes
// ready (published, unblocked, changes requested, handed back), or a task that
// lists its agent as a reviewer enters review — while it holds no lease, it is
// told once to pull. Tasks assigned to other agents never notify it.
//
// Queued once per transition (refold_task calls it only on that edge). Whether
// the item is still available — after match_chain_in_uow has run and the
// transaction committed — is decided at send time (notice_still_relevant). Not
// sent when the task just left an agent_not_running block naming the
// coordinator's own agent: that instance is (re)starting and pulls on bootstrap.
nudge_coordinator_item :: proc(svc: ^Service, u: ^Uow, before, task: domain.Task) {
	if u == nil || task.kind == .Gate do return
	chain, ok, _ := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !ok do return
	coord := chain.coordinator_agent_instance_id
	if coord == "" do return
	inst, iok, _ := iface.agent_get_instance(svc.agents, coord)
	if !iok || inst.agent_id == "" do return
	coord_agent := inst.agent_id
	line := ""
	switch task.state {
	case .Ready:
		if brief_assignee(task.brief_json) != coord_agent do return
		if is_agent_not_running_block(before.blocked_on_json) && jsonx.extract_string(before.blocked_on_json, "agent_id", "", true, context.temp_allocator) == coord_agent do return
		line = fmt.tprintf("[taskv2] ready for you: task %s (%s) — run `ham-ctl lease next`", task.task_id, task.title)
	case .In_Review:
		listed := false
		for id in required_reviewers(task, task_author_agent(svc, task)) do if id == coord_agent { listed = true; break }
		if !listed do return
		line = fmt.tprintf("[taskv2] ready for you: review of task %s (%s) — run `ham-ctl lease next`", task.task_id, task.title)
	case .Backlog, .In_Progress, .Done, .Cancelled:
		return
	}
	if _, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, coord); held do return
	effect_notify_task(svc, u, task, "coordinator_item_ready", line)
}

// block_names_coordinator: an agent_not_running block about the chain's own
// coordinator (same agent, same bridge when the block names one). That
// instance is the one that cannot be reached, so it is not told (rule g); the
// user's attention card carries the Start agent action.
@(private = "file")
block_names_coordinator :: proc(svc: ^Service, task: domain.Task) -> bool {
	coord_id := chain_coordinator_instance_id(svc, task.chain_id, task.owner_user_id)
	if coord_id == "" do return false
	inst, iok, _ := iface.agent_get_instance(svc.agents, coord_id)
	if !iok do return false
	agent_id := jsonx.extract_string(task.blocked_on_json, "agent_id", "", true, context.temp_allocator)
	bridge_id := jsonx.extract_string(task.blocked_on_json, "bridge_id", "", true, context.temp_allocator)
	return agent_id != "" && agent_id == inst.agent_id && (bridge_id == "" || bridge_id == inst.bridge_id)
}

@(private = "file")
check_coordinator_attention_on_refold :: proc(svc: ^Service, u: ^Uow, before, after: domain.Task, view: Task_View, tasks_in: []domain.Task) -> domain.Domain_Error {
	if u == nil do return {}
	all_tasks := tasks_in
	// A hold nested under another block is not a change of that block.
	if after.blocked_on_json != "" && blocked_on_without_hold(after.blocked_on_json) != blocked_on_without_hold(before.blocked_on_json) {
		if is_agent_not_running_block(after.blocked_on_json) {
			if !block_names_coordinator(svc, after) {
				reason := jsonx.extract_string(after.blocked_on_json, "reason", "", true, context.temp_allocator)
				effect_notify_task(svc, u, after, "agent_not_running", fmt.tprintf("[taskv2] agent_not_running: task %s (%s): %s", after.task_id, after.title, reason))
			}
		} else if view.budget_exhausted || strings.contains(after.blocked_on_json, `"budget_exhausted"`) {
			effect_notify_task(svc, u, after, "budget_exhausted", fmt.tprintf("[taskv2] budget_exhausted: task %s (%s) exhausted attempt budget (#%d)", after.task_id, after.title, after.attempt_no))
		} else if view.oscillating || strings.contains(after.blocked_on_json, `"oscillation"`) {
			effect_notify_task(svc, u, after, "oscillation", fmt.tprintf("[taskv2] oscillation: task %s (%s) parked after %d review rounds", after.task_id, after.title, view.review_rounds))
		} else if strings.contains(after.blocked_on_json, `"human"`) || strings.contains(after.blocked_on_json, `"user"`) {
			// `lease block --waiting-on user` (what TASK.md teaches) and the older
			// `human` both mean the task waits on the user, as the UI treats them.
			effect_notify_task(svc, u, after, "blocked_on human", fmt.tprintf("[taskv2] blocked_on human: task %s (%s) is waiting on human input", after.task_id, after.title))
		}
	}
	if after.state == .In_Review && before.state != .In_Review {
		// Notify coordinator when user approval is required and no reviewer agent is listed.
		if task_requires_user(after) && len(brief_reviewer_agents(after.brief_json, context.temp_allocator)) == 0 {
			notify_user_review_requested(svc, u, after, fmt.tprintf("[taskv2] review_requested_from_user: task %s (%s) is in_review and awaits user approval", after.task_id, after.title))
		}
	}
	if domain.task_state_is_terminal(after.state) && !domain.task_state_is_terminal(before.state) {
		// Only on the terminal edge: read the chain's tasks when the caller did
		// not pass them (refold_task of one task reads its parents only).
		if all_tasks == nil {
			loaded, err := iface.taskchain_list_tasks_by_chain(svc.repo, after.chain_id, after.owner_user_id)
			if err.code != .None do return err
			all_tasks = loaded
		}
	}
	if domain.task_state_is_terminal(after.state) && !domain.task_state_is_terminal(before.state) && len(all_tasks) > 0 {
		all_done := true
		for t in all_tasks {
			st := after.state if t.task_id == after.task_id else t.state
			if !domain.task_state_is_terminal(st) {
				all_done = false
				break
			}
		}
		if all_done {
			chain, cok, _ := iface.taskchain_get_chain(svc.repo, after.chain_id)
			if cok {
				runs, _ := iface.taskchain_list_workflow_runs(svc.repo, chain.chain_id, chain.owner_user_id)
				idle := true
				for run in runs {
					execution, ok, _ := iface.taskchain_get_workflow_execution(svc.repo, run.run_id, run.current_execution_no, chain.owner_user_id)
					if !ok || execution.state == "draft" || execution.state == "pending" || execution.state == "running" do idle = false
				}
				if idle {
					if cerr := catalog_work_finished(svc, chain, "work_batch_finished"); cerr.code != .None do return cerr
					effect_notify_task(svc, u, after, "work_batch_finished", "[taskv2] current batch finished; assess the goal, add work, or explicitly complete the chain")
				}
			}
		}
	}
	return {}
}

@(private = "file")
projection_equal :: proc(a, b: domain.Task) -> bool {
	return a.state == b.state && a.attempt_no == b.attempt_no && a.blocked_on_json == b.blocked_on_json && a.ready_since == b.ready_since && a.started_at == b.started_at && a.completed_at == b.completed_at
}

// refold_chain recomputes every task of `chain` until the projection is stable
// (a task becoming done can make its dependents ready, which is a second
// pass). Bounded by the number of tasks.
refold_chain :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain) -> ([]domain.Task, bool, domain.Domain_Error) {
	tasks, err := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return nil, false, err
	deps, dep_err := iface.taskchain_list_dependencies_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if dep_err.code != .None do return nil, false, dep_err
	// Inside after_chain_change: one edge read for the whole pass (refolds do
	// not change edges), and tasks whose inputs did not move are skipped.
	cache := tl_fold_cache
	if cache != nil && (cache.chain_id != chain.chain_id || cache.owner != chain.owner_user_id) do cache = nil
	if cache != nil {
		edges, eerr := iface.taskchain_list_work_dependencies(svc.repo, chain.chain_id, chain.owner_user_id)
		if eerr.code != .None do return nil, false, eerr
		cache.deps, cache.edges, cache.edges_loaded = deps, edges, true
	}
	defer if cache != nil {
		cache.deps, cache.edges, cache.edges_loaded = nil, nil, false
	}
	for pass := 0; pass < len(tasks) + 1; pass += 1 {
		changed := false
		for i in 0..<len(tasks) {
			before := tasks[i]
			after, _, ok, rerr := refold_task(svc, u, before, tasks, deps, skip_settled = true)
			if !ok do return tasks, false, rerr
			if after.state != before.state || after.attempt_no != before.attempt_no || after.blocked_on_json != before.blocked_on_json {
				changed = true
			}
			tasks[i] = after
		}
		if !changed do break
	}
	return tasks, true, domain.Domain_Error{}
}

// ---- chain-event entry points (called by the taskchain service) ------------------
// Each one is one UoW: event(s) → refold → match_chain (M1) → commit → effects.

task_created :: proc(svc: ^Service, task: domain.Task, actor: Actor) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	payload := json_begin()
	json_raw(&payload, "brief", task.brief_json)
	_, _, rok, rerr := record_event(svc, &u, task, actor, EV_CREATED, json_end(&payload))
	if rok && task.publish_state == .Published {
		fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
		_, _, rok, rerr = record_event(svc, &u, fresh, actor, EV_PUBLISHED, "{}")
	}
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Created)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

task_published :: proc(svc: ^Service, task: domain.Task, actor: Actor) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	_, _, rok, rerr := record_event(svc, &u, task, actor, EV_PUBLISHED, "{}")
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Published)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// chain_published records `published` for every task that just went live.
chain_published :: proc(svc: ^Service, chain: domain.Task_Chain, actor: Actor) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	rok := terr.code == .None
	rerr := terr
	if rok {
		for t in tasks {
			if !event_exists(svc, t, EV_PUBLISHED) {
				if _, aok, aerr := append_event(svc.repo, svc.clock, t, actor, EV_PUBLISHED, "{}"); !aok {
					rok = false
					rerr = aerr
					break
				}
			}
		}
	}
	if rok do rok, rerr = after_chain_change(svc, &u, chain.chain_id, chain.owner_user_id, .Chain_Published)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// task_updated records an audit event; `fields` names what changed.
task_updated :: proc(svc: ^Service, task: domain.Task, actor: Actor, fields: []string) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	payload := json_begin()
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for f, i in fields {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		strings.write_string(&b, f)
		strings.write_byte(&b, '"')
	}
	strings.write_byte(&b, ']')
	json_raw(&payload, "fields", strings.to_string(b))
	_, _, rok, rerr := record_event(svc, &u, task, actor, EV_UPDATED, json_end(&payload))
	reviewers_changed := false
	// Turning user approval off can satisfy a gate whose agent reviews are all
	// in; nothing else would decide it (no review lease is left to post).
	for f in fields do if f == "reviewers" || f == "brief" || f == "requires_user_approval" { reviewers_changed = true; break }
	if rok && reviewers_changed do rok, rerr = regate_after_reviewer_change(svc, &u, task, actor)
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Updated)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

dep_added :: proc(svc: ^Service, task: domain.Task, depends_on: domain.Task_ID, actor: Actor) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	payload := json_begin()
	json_str(&payload, "depends_on", string(depends_on))
	rok, rerr := on_dep_added_in_uow(svc, &u, task, actor)
	if rok {
		_, _, rok, rerr = record_event(svc, &u, task, actor, EV_DEP_ADDED, json_end(&payload))
	}
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Dep_Added)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

dep_removed :: proc(svc: ^Service, task: domain.Task, depends_on: domain.Task_ID, actor: Actor) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	payload := json_begin()
	json_str(&payload, "depends_on", string(depends_on))
	_, _, rok, rerr := record_event(svc, &u, task, actor, EV_DEP_REMOVED, json_end(&payload))
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Dep_Removed)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// fleet_changed re-evaluates the chain after a fleet row upsert/delete.
fleet_changed :: proc(svc: ^Service, chain: domain.Task_Chain, agent_id := "") -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	if agent_id != "" {
		retry_agent := false
		tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
		if terr.code != .None { _, _ = end_uow(svc, &u, false); return terr }
		for task in tasks {
			if !is_agent_not_running_block(task.blocked_on_json) do continue
			if jsonx.extract_string(task.blocked_on_json, "agent_id", "", true, context.temp_allocator) != agent_id do continue
			retry_agent = true
			if _, _, rok, rerr := record_event(svc, &u, task, hub_actor(), EV_ANSWERED, `{}`); !rok {
				_, _ = end_uow(svc, &u, false); return rerr
			}
		}
		if retry_agent {
			if reset, reset_err := reset_idle_agent_instances(svc, chain.owner_user_id, chain.chain_id, agent_id); !reset {
				_, _ = end_uow(svc, &u, false)
				return reset_err
			}
		}
	}
	// A row change affects that agent's items; a chain-level change (caps,
	// every row) affects any task.
	if agent_id != "" do match_scope_note_agent(chain.chain_id, agent_id)
	else do match_scope_note_full(chain.chain_id)
	// A fleet row added/removed changes who must review: re-evaluate the gate
	// of every in_review task before matching (plan §2.4).
	rok, rerr := reevaluate_gates_in_uow(svc, &u, chain)
	if rok do rok, rerr = after_chain_change(svc, &u, chain.chain_id, chain.owner_user_id, .Fleet_Changed)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// task_comment records a `comment` audit event (no wake, no state change).
task_comment :: proc(svc: ^Service, task: domain.Task, actor: Actor, comment_id: string) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	payload := json_begin()
	json_str(&payload, "comment_id", comment_id)
	_, aok, aerr := append_event(svc.repo, svc.clock, task, actor, EV_COMMENT, json_end(&payload))
	_, cerr := end_uow(svc, &u, aok)
	if !aok do return aerr
	return cerr
}

event_exists :: proc(svc: ^Service, task: domain.Task, kind: string) -> bool {
	evs, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return false
	for e in evs do if e.kind == kind do return true
	return false
}

// release_task_blocks_in_uow clears a `blocked_on {kind: "task", ref}` badge
// once the referenced task is done: the hub records `answered` on the agent's
// behalf, so the task is ready again without a human. Covers both a ref that
// completes later and one that was already done when the agent blocked (both
// paths run after_chain_change). A ref in another chain is picked up on this
// chain's next change or on boot. Returns whether any task was released.
release_task_blocks_in_uow :: proc(svc: ^Service, u: ^Uow, tasks: []domain.Task) -> (bool, bool, domain.Domain_Error) {
	released := false
	for t in tasks {
		if t.state != .Backlog || strings.trim_space(t.blocked_on_json) == "" do continue
		if jsonx.extract_string(t.blocked_on_json, "kind", "", true, context.temp_allocator) != "task" do continue
		ref := strings.trim_space(jsonx.extract_string(t.blocked_on_json, "ref", "", true, context.temp_allocator))
		if ref == "" || ref == string(t.task_id) do continue
		ref_done := false
		found := false
		for o in tasks do if string(o.task_id) == ref { found = true; ref_done = o.state == .Done; break }
		if !found {
			if o, ok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(ref)); ok && o.owner_user_id == t.owner_user_id do ref_done = o.state == .Done
		}
		if !ref_done do continue
		p := json_begin()
		json_bool(&p, "auto", true)
		json_str(&p, "reason", "ref_task_done")
		json_str(&p, "ref", ref)
		json_str(&p, "note", fmt.tprintf("referenced task %s is done", ref))
		if _, _, ok, err := record_event(svc, u, t, hub_actor(), EV_ANSWERED, json_end(&p), tasks); !ok do return released, false, err
		released = true
	}
	return released, true, domain.Domain_Error{}
}

// after_chain_change is the one place every chain mutation funnels through
// inside its UoW: refold the chain's projections, materialise ready workflow
// stages, trigger on_output workflow spawns, rebuild the mechanical chain
// summary on task transitions, then run the matcher.
//
// Each phase's in-transaction time and statement count is recorded
// (heimdall_db_phase_*, and the db_slow_request / db_slow_scope breakdown),
// including on an early error return.
after_chain_change :: proc(svc: ^Service, u: ^Uow, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, trigger: Trigger) -> (bool, domain.Domain_Error) {
	phases: dbt.Phase_Set
	defer dbt.phase_flush(&phases)
	// One batched event read serves every fold below; only dirty tasks refold.
	cache: Chain_Fold_Cache
	active, prev := fold_cache_begin(&cache, chain_id, owner)
	defer fold_cache_end(active, prev)
	chain, ok, err := iface.taskchain_get_chain(svc.repo, chain_id)
	if !ok do return false, err
	mark := dbt.phase_mark()
	requirement_tasks, req_err := iface.taskchain_list_tasks_by_chain(svc.repo, chain_id, owner)
	if req_err.code != .None { dbt.phase_record(&phases, .Requirements, mark); return false, req_err }
	for task in requirement_tasks {
		if rok, rerr := requirements_reconcile_in_uow(svc, u, task); !rok { dbt.phase_record(&phases, .Requirements, mark); return false, rerr }
	}
	dbt.phase_record(&phases, .Requirements, mark)
	// Settle run/task dependencies together; a successful run can release
	// another run or a ticket in this same transaction.
	for pass := 0; pass < 130; pass += 1 {
		mark = dbt.phase_mark()
		tasks, rok, rerr := refold_chain(svc, u, chain)
		dbt.phase_record(&phases, .Refold, mark)
		if !rok do return false, rerr
		mark = dbt.phase_mark()
		_, uok, uerr := release_task_blocks_in_uow(svc, u, tasks)
		if !uok { dbt.phase_record(&phases, .Release_Workflow, mark); return false, uerr }
		if tok, terr := trigger_on_output_workflows_in_uow(svc, u, chain, tasks); !tok { dbt.phase_record(&phases, .Release_Workflow, mark); return false, terr }
		changed, wok, werr := workflow_reconcile_chain(svc, u, chain)
		dbt.phase_record(&phases, .Release_Workflow, mark)
		if !wok do return false, werr
		if !changed do break
	}
	mark = dbt.phase_mark()
	settled, rok, rerr := refold_chain(svc, u, chain)
	dbt.phase_record(&phases, .Refold, mark)
	if !rok do return false, rerr
	#partial switch trigger {
	case .Lease_Released, .Lease_Expired, .Review_Posted, .Task_Reopened, .Task_Cancelled, .Chain_Published, .Task_Published:
		mark = dbt.phase_mark()
		rebuild_chain_summary_in_uow(svc, u, chain)
		dbt.phase_record(&phases, .Summary, mark)
	}
	mark = dbt.phase_mark()
	// Only what this unit of work's writes can affect is re-matched
	// (match_chain_scoped_in_uow); the refold's rows serve its lookups.
	mok, merr := match_chain_scoped_in_uow(svc, u, chain, trigger, settled)
	dbt.phase_record(&phases, .Match, mark)
	when FOLD_VERIFY { if mok do fold_verify_full_refold_is_noop(svc, chain_id, owner) }
	if !mok do return false, merr
	// No stop scan here: every stop is decided by the event that ends the
	// instance's responsibility (spec SCHED 8.3).
	return true, {}
}

// Catalog v1 migration switch. Other attention triggers remain on the old path.
legacy_event_notice_enabled :: proc(svc: ^Service, trigger: string) -> bool {
	enabled, set := svc.legacy_event_notices.?
	if !set || enabled do return true
	switch trigger {
	case "review_requested_from_user", "blocked_on human", "requirements_changed",
	     "merge_conflict", "work_batch_finished", "workflow_complete", "workflow_failed":
		return false
	}
	return true
}
