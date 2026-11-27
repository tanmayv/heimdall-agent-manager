package fleet_application

import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import fleet "odin_test:hub/service/fleet_settings"
import ownership "odin_test:hub/service/ownership"

Service :: struct {
	settings: fleet.Service,
	agents: ^agent.Agent_Service,
	factory: ^iface.Unit_Of_Work_Factory,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	mutex: sync.Mutex,
	event_ctx: rawptr,
	on_changed: proc(ctx: rawptr, owner: domain.User_ID, application: domain.Fleet_Application, settings_changed: bool),
	// Public grant bindings only. Revalidated on recovery before NEW native work.
	authority_ctx: rawptr,
	authority_check: proc(ctx:rawptr,owner:domain.User_ID,binding:string)->domain.Domain_Error,
}
Authorization :: struct {binding:string,ctx:rawptr,check:proc(ctx:rawptr)->domain.Domain_Error}

read_settings :: proc(s: ^Service, auth: contracts.Auth_Context, bridge_id: string) -> (domain.Fleet_Settings, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, err
	return iface.fleet_settings_get(s.settings.bridges, owner, bridge_id)
}
read_application :: proc(s: ^Service, auth: contracts.Auth_Context, bridge_id, id: string) -> (domain.Fleet_Application_Record, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, false, err
	return iface.fleet_application_get(s.settings.bridges, owner, bridge_id, id)
}

fleet_desired_runtime :: proc(snapshot: domain.Fleet_Settings, agent_id: string) -> domain.Fleet_Runtime {
	for override in snapshot.overrides do if override.agent_id == agent_id do return override.runtime
	return snapshot.default_runtime
}

Fleet_Target_Facts :: map[[32]byte]bool

// Read candidate generations in a short transaction. Probe outside that
// transaction, then recheck each fact's identity in preview/Apply's atomic
// snapshot. Nested callers may only use already observed evidence.
observe_targets :: proc(s: ^Service, owner: domain.User_ID, bridge_id: string, snapshot: domain.Fleet_Settings) -> (Fleet_Target_Facts, domain.Domain_Error) {
	u, begun, err := iface.unit_of_work_begin(s.factory)
	if !begun do return nil, err
	settings := s.settings
	if u.repos != nil { settings.bridges = &u.repos.bridges; settings.agents = &u.repos.agents }
	bridge, found, read_err := iface.bridge_get_bridge(settings.bridges, bridge_id)
	defer domain.bridge_destroy(&bridge)
	if !found || bridge.owner_user_id != owner {
		iface.unit_of_work_rollback(&u)
		return nil, read_err if !found else domain.domain_error(.Not_Found, "bridge not found")
	}
	instances, list_err := iface.agent_list_instances_by_bridge(settings.agents, bridge_id)
	nested := u.nested
	iface.unit_of_work_rollback(&u)
	if list_err.code != .None do return nil, list_err
	defer { for &inst in instances do domain.agent_instance_destroy(&inst); delete(instances) }
	facts := make(Fleet_Target_Facts, context.temp_allocator)
	for inst in instances {
		if inst.owner_user_id != owner || inst.bridge_id != bridge_id || inst.stopped_by != "" ||
		   domain.fleet_runtime_equal({inst.provider, inst.provider_profile, inst.model}, fleet_desired_runtime(snapshot, inst.agent_id)) { continue }
		fact := agent.agent_liveness(s.agents, inst, cache_only = nested)
		if fact.state == .Alive && fact.ready do facts[agent.agent_liveness_key(inst)] = true
	}
	return facts, {}
}

// One classifier for preview and Apply. Results borrow the instance/snapshot
// strings and have no operation IDs, persistence or lifecycle effects.
select_targets :: proc(settings: ^fleet.Service, owner: domain.User_ID, bridge_id: string, snapshot: domain.Fleet_Settings, instances: []domain.Agent_Instance, facts: Fleet_Target_Facts) -> ([]domain.Fleet_Application_Target, domain.Domain_Error) {
	targets := make([dynamic]domain.Fleet_Application_Target, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for inst in instances {
		if inst.owner_user_id != owner || inst.bridge_id != bridge_id || !facts[agent.agent_liveness_key(inst)] || inst.stopped_by != "" || seen[inst.agent_instance_id] do continue
		seen[inst.agent_instance_id] = true
		included, scope_err := iface.fleet_scope_get(settings.bridges, inst)
		if scope_err.code != .None do return nil, scope_err
		if !included do continue
		desired := fleet_desired_runtime(snapshot, inst.agent_id)
		actual := domain.Fleet_Runtime{inst.provider, inst.provider_profile, inst.model}
		if domain.fleet_runtime_equal(actual, desired) do continue
		append(&targets, domain.Fleet_Application_Target{agent_instance_id=inst.agent_instance_id,agent_id=inst.agent_id,configuration_revision=inst.configuration_revision,run_count=inst.run_count,launch_epoch=inst.launch_epoch,project_id=string(inst.project_id),before=actual,desired=desired,state="pending"})
	}
	return targets[:], {}
}

preview :: proc(s: ^Service, auth: contracts.Auth_Context, bridge_id: string, draft: domain.Fleet_Settings_Draft) -> (contracts.Fleet_Preview, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, err
	if draft.expected_revision < 0 do return {}, domain.domain_error(.Validation_Failed, "nonnegative expected_revision is required")
	snapshot := domain.Fleet_Settings{bridge_id=bridge_id,default_runtime=draft.default_runtime,overrides=draft.overrides}
	facts, fact_err := observe_targets(s, owner, bridge_id, snapshot)
	if fact_err.code != .None do return {}, fact_err
	u, begun, ue := iface.unit_of_work_begin(s.factory)
	if !begun do return {}, ue
	// Always roll back: even semantic no-ops must not write or publish.
	defer iface.unit_of_work_rollback(&u)
	settings := s.settings
	if u.repos != nil {settings.bridges = &u.repos.bridges; settings.agents = &u.repos.agents}
	if e := fleet.validate(&settings, owner, bridge_id, draft); e.code != .None do return {}, e
	current, ce := iface.fleet_settings_get(settings.bridges, owner, bridge_id)
	if ce.code != .None do return {}, ce
	defer domain.fleet_settings_destroy(current)
	if current.revision != draft.expected_revision do return {}, domain.domain_error(.Conflict, "Fleet settings revision changed", `{"code":"fleet_revision_conflict"}`)
	instances, ie := iface.agent_list_instances_by_bridge(settings.agents, bridge_id)
	if ie.code != .None do return {}, ie
	defer {for &inst in instances do domain.agent_instance_destroy(&inst); delete(instances)}
	targets, te := select_targets(&settings, owner, bridge_id, snapshot, instances, facts)
	if te.code != .None do return {}, te
	return {bridge_id, draft.expected_revision, len(targets)}, {}
}

canonical_request :: proc(input: domain.Fleet_Apply_Input) -> string {
	next := input
	next.default_runtime.provider_profile = domain.profile_effective_id(next.default_runtime.provider, next.default_runtime.provider_profile)
	next.overrides = make([]domain.Fleet_Agent_Override, len(input.overrides), context.temp_allocator)
	copy(next.overrides, input.overrides)
	for &o in next.overrides do o.runtime.provider_profile = domain.profile_effective_id(o.runtime.provider, o.runtime.provider_profile)
	slice.sort_by(next.overrides, proc(a, b: domain.Fleet_Agent_Override) -> bool {return a.agent_id < b.agent_id})
	data, _ := json.marshal(next, allocator=context.temp_allocator)
	return string(data)
}

// Settings, immutable request and the complete target snapshot share one UOW.
// Native lifecycle work is only registered here; it cannot run before COMMIT.
apply :: proc(s: ^Service, auth: contracts.Auth_Context, bridge_id: string, input: domain.Fleet_Apply_Input, authorization:=Authorization{}) -> (domain.Fleet_Application_Record, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, false, err
	if strings.trim_space(input.request_id) == "" || len(input.request_id) > 128 || input.expected_revision < 0 do return {}, false, domain.domain_error(.Validation_Failed, "request_id and nonnegative expected_revision are required")
	facts, fact_err := observe_targets(s, owner, bridge_id, {bridge_id=bridge_id,default_runtime=input.default_runtime,overrides=input.overrides})
	if fact_err.code != .None do return {}, false, fact_err
	u, begun, ue := iface.unit_of_work_begin(s.factory)
	if !begun do return {}, false, ue
	finished := false
	defer if !finished do iface.unit_of_work_rollback(&u)
	if u.nested && authorization.check!=nil do return {},false,domain.domain_error(.Conflict,"delegated Fleet Apply must own its acceptance transaction")
	if authorization.check!=nil {if e:=authorization.check(authorization.ctx);e.code!=.None do return {},false,e}
	if authorization.binding!="" {
		if s.authority_check==nil do return {},false,domain.domain_error(.Forbidden,"delegated Fleet authority unavailable")
		if e:=s.authority_check(s.authority_ctx,owner,authorization.binding);e.code!=.None do return {},false,e
	}
	settings := s.settings
	if u.repos != nil {settings.bridges = &u.repos.bridges; settings.agents = &u.repos.agents}
	canonical := canonical_request(input)
	prior, exists, pe := iface.fleet_application_get(settings.bridges, owner, bridge_id, input.request_id, by_request=true)
	if exists {
		if prior.request_json != canonical {
			domain.fleet_application_record_destroy(&prior)
			return {}, false, domain.domain_error(.Conflict, "request_id belongs to a different Fleet draft", `{"code":"fleet_request_conflict"}`)
		}
		return prior, true, {}
	}
	if pe.code != .Not_Found do return {}, false, pe
	snapshot, changed, se := fleet.save(&settings, owner, bridge_id, {input.expected_revision, input.default_runtime, input.overrides})
	if se.code != .None do return {}, false, se
	defer domain.fleet_settings_destroy(snapshot)
	instances, ie := iface.agent_list_instances_by_bridge(settings.agents, bridge_id)
	if ie.code != .None do return {}, false, ie
	defer {for &inst in instances do domain.agent_instance_destroy(&inst); delete(instances)}
	targets, te := select_targets(&settings, owner, bridge_id, snapshot, instances, facts)
	if te.code != .None do return {}, false, te
	// One lease read for the whole snapshot instead of one lookup per target.
	holders, he := lease_ids_by_holder(s, targets)
	if he.code != .None do return {}, false, he
	for &target in targets {
		target.lease_id = holders[target.agent_instance_id]
		target.operation_key = platform.generate_id(s.ids,"fleet_target_")
	}
	now := platform.clock_now(s.clock)
	a := domain.Fleet_Application{application_id=platform.generate_id(s.ids,"fleet_apply_"),bridge_id=bridge_id,request_id=input.request_id,settings_revision=snapshot.revision,revision=1,settings_saved=true,state="pending" if len(targets)>0 else "ready",created_at=now,updated_at=now,targets=targets}
	record := domain.Fleet_Application_Record{owner_user_id=owner,request_json=canonical,authority_json=authorization.binding,application=a}
	if saved, e := iface.fleet_application_put(settings.bridges, record, 0); !saved do return {}, false, e
	hook := new(After_Apply)
	hook^ = {s,strings.clone(string(owner)),strings.clone(bridge_id),strings.clone(a.application_id),changed,authorization}
	if !iface.unit_of_work_after_commit(&u, {ctx=hook,run=after_apply,discard=discard_apply}) {
		discard_apply(hook)
		return {}, false, domain.domain_error(.Internal_Error, "Fleet Apply requires post-commit lifecycle hooks")
	}
	finished = true
	committed, ce := iface.unit_of_work_commit(&u)
	if !committed do return {}, false, ce
	return iface.fleet_application_get(s.settings.bridges, owner, bridge_id, a.application_id)
}

After_Apply :: struct {s: ^Service, owner, bridge_id, id: string, changed: bool,authorization:Authorization}
discard_apply :: proc(ctx: rawptr) {
	h := (^After_Apply)(ctx)
	delete(h.owner); delete(h.bridge_id); delete(h.id); free(h)
}
after_apply :: proc(ctx: rawptr) {
	h := (^After_Apply)(ctx)
	defer discard_apply(ctx)
	r, found, _ := iface.fleet_application_get(h.s.settings.bridges, domain.User_ID(h.owner), h.bridge_id, h.id)
	if found {
		if h.s.on_changed != nil do h.s.on_changed(h.s.event_ctx, r.owner_user_id, r.application, h.changed)
		domain.fleet_application_record_destroy(&r)
	}
	reconcile_one(h.s, domain.User_ID(h.owner), h.bridge_id, h.id,authorization=h.authorization)
}

set_text :: proc(dst: ^string, value: string) {delete(dst^); dst^ = strings.clone(value)}
fail :: proc(t: ^domain.Fleet_Application_Target, code, message: string, retryable := true) {
	set_text(&t.state, "failed"); set_text(&t.error_code, code); set_text(&t.error_message, message); t.retryable = retryable
}
Guard :: struct {s: ^Service, record: ^domain.Fleet_Application_Record, target: ^domain.Fleet_Application_Target, recovering: bool,authorization:Authorization, observed_key:[32]byte, observed_ready:bool}
guard_target :: proc(ctx: rawptr) -> domain.Domain_Error {
	g := (^Guard)(ctx); r := g.record; t := g.target
	// Guards of one pass run on parallel native-start workers; the shared
	// record is read-only to them except for this cancellation flag.
	if sync.atomic_load(&r.application.cancelled) do return domain.domain_error(.Forbidden,"Fleet application was cancelled")
	if g.authorization.check!=nil {
		if e:=g.authorization.check(g.authorization.ctx);e.code!=.None {sync.atomic_store(&r.application.cancelled,true);return e}
	}
	if r.authority_json!="" {
		if g.s.authority_check==nil do return domain.domain_error(.Forbidden,"delegated Fleet authority unavailable")
		if e:=g.s.authority_check(g.s.authority_ctx,r.owner_user_id,r.authority_json);e.code!=.None do return e
	}
	current, ce := iface.fleet_settings_get(g.s.settings.bridges, r.owner_user_id, r.application.bridge_id)
	if ce.code != .None do return ce
	defer domain.fleet_settings_destroy(current)
	if current.revision != r.application.settings_revision do return domain.domain_error(.Conflict, "Fleet application was superseded by newer settings")
	inst, found, err := iface.agent_get_instance(g.s.settings.agents, t.agent_instance_id)
	if !found do return err if err.code != .None else domain.domain_error(.Not_Found, "instance not found")
	defer domain.agent_instance_destroy(&inst)
	included, scope_err := iface.fleet_scope_get(g.s.settings.bridges, inst)
	if scope_err.code != .None do return scope_err
	if inst.owner_user_id != r.owner_user_id || inst.bridge_id != r.application.bridge_id || !included || inst.agent_id != t.agent_id || string(inst.project_id) != t.project_id || inst.stopped_by == "user" do return domain.domain_error(.Conflict, "Fleet target ownership, scope, location or stop intent changed")
	if g.s.agents.taskchains != nil {
		lease, held, le := iface.taskchain_get_lease_by_holder(g.s.agents.taskchains, t.agent_instance_id)
		if !held && le.code != .None && le.code != .Not_Found do return le
		if (held && lease.lease_id != t.lease_id) || (!held && t.lease_id != "") do return domain.domain_error(.Conflict, "Fleet target claim changed after Apply")
	}
	if !g.recovering && (!g.observed_ready || g.observed_key != agent.agent_liveness_key(inst) || inst.configuration_revision != t.configuration_revision || inst.launch_epoch != t.launch_epoch || inst.run_count != t.run_count) do return domain.domain_error(.Conflict, "Fleet target runtime changed after Apply")
	return {}
}

// FLEET_RESTART_CONCURRENCY bounds the native starts (guard + begin/retry)
// that one application pass runs at once. A native start can wait on a bridge
// round-trip (project-path preflight) before it takes reconfiguration_mutex,
// so a serial loop made every Apply and retry linear in bridge latency. An
// application targets exactly one bridge and Service.mutex serialises passes,
// so this is also the per-bridge and process-wide bound for Fleet. SQL still
// serialises on tx_mutex (one connection); only bridge waits overlap.
FLEET_RESTART_CONCURRENCY :: 8

Native_Step :: enum {None, Begin, Retry}
Native_Job :: struct {s: ^Service, r: ^domain.Fleet_Application_Record, t: ^domain.Fleet_Application_Target, step: Native_Step, op_revision: int, authorization: Authorization, result: domain.Fleet_Application_Target}
Native_Pool :: struct {jobs: []Native_Job, next: int}
Native_Worker :: struct {pool: ^Native_Pool, arena: virtual.Arena}

// lease_ids_by_holder maps each target instance -> held lease with one read,
// replacing a per-target taskchain_get_lease_by_holder. The listing is hub-wide
// and its rows are owned heap clones, so it is read in a scratch arena that is
// released here; only this snapshot's holders are copied (temp allocator) and
// other owners' leases never leave the arena.
lease_ids_by_holder :: proc(s: ^Service, targets: []domain.Fleet_Application_Target) -> (map[string]string, domain.Domain_Error) {
	holders := make(map[string]string, len(targets), context.temp_allocator)
	if len(targets) == 0 || s.agents.taskchains == nil do return holders, {}
	for t in targets do holders[t.agent_instance_id] = ""
	scratch: virtual.Arena
	if e := virtual.arena_init_growing(&scratch); e != nil do return holders, domain.domain_error(.Internal_Error, "Fleet lease scratch unavailable")
	defer virtual.arena_destroy(&scratch)
	err: domain.Domain_Error
	{
		context.allocator = virtual.arena_allocator(&scratch)
		leases: []domain.Task_Lease
		leases, err = iface.taskchain_list_all_leases(s.agents.taskchains)
		if err.code == .None do for l in leases {
			if l.holder_instance_id == "" || l.holder_instance_id not_in holders do continue
			holders[l.holder_instance_id] = strings.clone(l.lease_id, context.temp_allocator)
		}
	}
	if err.code != .None && err.code != .Not_Found do return holders, err
	return holders, {}
}

// active_operations reads the owner's in-flight native operations once per
// pass, keyed by operation key. Targets whose operation left the active set
// (ready/failed) fall back to one exact read at that terminal transition.
active_operations :: proc(s: ^Service, r: ^domain.Fleet_Application_Record) -> map[string]domain.Instance_Reconfiguration {
	ops := make(map[string]domain.Instance_Reconfiguration)
	needed := false
	for t in r.application.targets do needed = needed || (t.state != "ready" && t.operation_key != "")
	if !needed || s.agents.agents == nil || s.agents.agents.reconfiguration_list == nil do return ops
	list, err := iface.instance_reconfiguration_list(s.agents.agents, string(r.owner_user_id), "", true)
	defer delete(list)
	for &op in list {
		// A failed listing only costs the exact per-target reads below.
		if err.code != .None || op.idempotency_key in ops {domain.instance_reconfiguration_destroy(&op); continue}
		ops[op.idempotency_key] = op
	}
	return ops
}
active_operations_destroy :: proc(ops: ^map[string]domain.Instance_Reconfiguration) {
	for _, &op in ops do domain.instance_reconfiguration_destroy(&op)
	delete(ops^)
}

target_apply_phase :: proc(t: ^domain.Fleet_Application_Target, op: domain.Instance_Reconfiguration) {
	switch op.phase {
	case .Ready:
		set_text(&t.state,"ready"); set_text(&t.error_code,""); set_text(&t.error_message,""); t.retryable=false
	case .Recovery_Required:
		fail(t,op.failure_code,op.failure_message,op.failure_code!="force_stopping")
	case .Failed:
		fail(t,op.failure_code,op.failure_message,false)
	case .Prepared, .Stopping, .Source_Stopped, .Launching:
		set_text(&t.state,"restarting"); set_text(&t.error_code,""); set_text(&t.error_message,""); t.retryable=false
	}
}

// plan_target folds durable native state into t without any bridge work and
// returns the native start the target still needs (run by run_native_jobs).
plan_target :: proc(s: ^Service, r: ^domain.Fleet_Application_Record, t: ^domain.Fleet_Application_Target, retry: bool, active: ^map[string]domain.Instance_Reconfiguration) -> (Native_Step, int) {
	if t.state == "ready" do return .None, 0
	op: domain.Instance_Reconfiguration; found := false; owned := false; err: domain.Domain_Error
	if cached, hit := active[t.operation_key]; hit && cached.agent_instance_id == t.agent_instance_id {
		op, found = cached, true
	} else {
		op, found, err = iface.instance_reconfiguration_get(s.agents.agents, string(r.owner_user_id), t.agent_instance_id, t.operation_key)
		owned = found
	}
	defer if owned do domain.instance_reconfiguration_destroy(&op)
	if !found && err.code != .Not_Found {fail(t,"storage_error",err.message); return .None, 0}
	if !found && t.state == "failed" && !retry do return .None, 0
	if !found do return .Begin, 0
	if retry && op.phase == .Recovery_Required do return .Retry, op.revision
	target_apply_phase(t, op)
	return .None, 0
}

// run_native performs one target's guarded native start. It never writes the
// shared record: the outcome goes to job.result (allocated with the running
// thread's allocator) and the caller folds it after every job finished. The
// record is otherwise read-only to workers apart from the atomic cancel flag.
run_native :: proc(job: ^Native_Job) {
	s, r, t, out := job.s, job.r, job.t, &job.result
	g := Guard{s=s,record=r,target=t,recovering=job.step == .Retry,authorization=job.authorization}
	if !g.recovering {
		inst, found, _ := iface.agent_get_instance(s.settings.agents, t.agent_instance_id)
		defer domain.agent_instance_destroy(&inst)
		if found && inst.owner_user_id == r.owner_user_id && inst.bridge_id == r.application.bridge_id {
			fact := agent.agent_liveness(s.agents, inst)
			g.observed_key, g.observed_ready = agent.agent_liveness_key(inst), fact.state == .Alive && fact.ready
		}
	}
	if e := guard_target(&g); e.code != .None {fail(out,"target_changed",e.message,false); return}
	auth := contracts.Auth_Context{kind=.Internal_User,user_id=string(r.owner_user_id)}
	op: domain.Instance_Reconfiguration; accepted: bool; ne: domain.Domain_Error
	if job.step == .Begin {
		op, accepted, ne = agent.begin_instance_reconfiguration(s.agents, auth, t.agent_instance_id, {bridge_id=r.application.bridge_id,project_id=t.project_id,provider=t.desired.provider,provider_profile=t.desired.provider_profile,model=t.desired.model,idempotency_key=t.operation_key,expected_revision=t.configuration_revision}, &g, guard_target, s.factory)
	} else {
		op, accepted, ne = agent.retry_instance_reconfiguration(s.agents, auth, t.agent_instance_id, t.operation_key, job.op_revision, &g, guard_target, s.factory)
	}
	if !accepted {fail(out,domain.error_code_string(ne.code),ne.message); return}
	defer domain.instance_reconfiguration_destroy(&op)
	target_apply_phase(out, op)
}

// fold_native_results copies each outcome into its target with the caller's
// allocator. free_results releases outcomes made with that same allocator
// (inline path); worker outcomes live in worker arenas freed by the caller.
fold_native_results :: proc(jobs: []Native_Job, free_results: bool) {
	for &job in jobs {
		t, out := job.t, &job.result
		set_text(&t.state,out.state); set_text(&t.error_code,out.error_code); set_text(&t.error_message,out.error_message); t.retryable = out.retryable
		if free_results {delete(out.state); delete(out.error_code); delete(out.error_message); out^ = {}}
	}
}

native_worker :: proc(data: rawptr) {
	w := (^Native_Worker)(data)
	// Hub callers run on per-request/per-pass arenas that are not thread-safe;
	// each worker allocates only from its own arena, released by the caller.
	context.allocator = virtual.arena_allocator(&w.arena)
	for {
		i := sync.atomic_add(&w.pool.next, 1)
		if i >= len(w.pool.jobs) do return
		run_native(&w.pool.jobs[i])
		free_all(context.temp_allocator)
	}
}

// A pass entered from inside the caller's unit of work must stay on that
// thread: workers would block on the tx_mutex the joining caller holds (and a
// nested native acceptance is refused anyway). Unknown -> stay inline.
// Unit_Of_Work_Factory exposes no "in transaction" probe, so this opens and
// rolls back an empty unit: one BEGIN/ROLLBACK per parallel pass (>=2 native
// starts), against at least two acceptance transactions it parallelises.
native_starts_inline :: proc(factory: ^iface.Unit_Of_Work_Factory) -> bool {
	if factory == nil do return true
	u, begun, _ := iface.unit_of_work_begin(factory)
	if !begun do return true
	nested := u.nested
	iface.unit_of_work_rollback(&u)
	return nested
}

// run_native_jobs runs at most FLEET_RESTART_CONCURRENCY native starts at a
// time and returns after all of them finished, so the caller folds every
// per-target result into one application write.
run_native_jobs :: proc(s: ^Service, jobs: []Native_Job) {
	count := min(len(jobs), FLEET_RESTART_CONCURRENCY)
	if count <= 1 || native_starts_inline(s.factory) {
		for &job in jobs do run_native(&job)
		fold_native_results(jobs, true)
		return
	}
	pool := Native_Pool{jobs=jobs}
	workers := make([]Native_Worker, count, context.temp_allocator)
	ready := 0
	for &w in workers {
		if virtual.arena_init_growing(&w.arena) != nil do break
		w.pool = &pool; ready += 1
	}
	threads := make([dynamic]^thread.Thread, 0, count, context.temp_allocator)
	{
		// context changes are block-scoped: the fold below runs with the
		// caller's allocator again. Thread records must not live in the caller's arena (see the app
		// thread-spawn guard); workers start with heap + fresh temp allocators.
		context.allocator = runtime.heap_allocator()
		ctx := runtime.default_context()
		ctx.allocator = runtime.heap_allocator(); ctx.logger = context.logger
		for k in 0..<ready {
			th := thread.create_and_start_with_data(&workers[k], native_worker, init_context=ctx)
			if th == nil do break
			append(&threads, th)
		}
		for th in threads {thread.join(th); thread.destroy(th)}
	}
	// Started workers drain every job. Spawn/arena failure (no worker ran)
	// degrades to the serial path; a job is never dropped.
	if len(threads) == 0 {
		for &job in jobs do run_native(&job)
		fold_native_results(jobs, true)
	} else do fold_native_results(jobs, false)
	for &w in workers[:ready] do virtual.arena_destroy(&w.arena)
}

application_in_flight :: proc(a: domain.Fleet_Application) -> bool {
	for t in a.targets do if t.state == "pending" || t.state == "restarting" do return true
	return false
}

// Reads never start work. Reaper and committed mutations drive this pass;
// operation keys close the crash window between native accept and target CAS.
reconcile_one :: proc(s: ^Service, owner: domain.User_ID, bridge_id, id: string, retry := false,authorization:=Authorization{}) {
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	r, found, _ := iface.fleet_application_get(s.settings.bridges, owner, bridge_id, id)
	if !found do return
	defer domain.fleet_application_record_destroy(&r)
	before, _ := json.marshal(r.application, allocator=context.temp_allocator)
	active := active_operations(s, &r)
	defer active_operations_destroy(&active)
	jobs := make([dynamic]Native_Job, 0, len(r.application.targets), context.temp_allocator)
	for &t in r.application.targets {
		step, revision := plan_target(s,&r,&t,retry && t.retryable,&active)
		if step != .None do append(&jobs, Native_Job{s=s,r=&r,t=&t,step=step,op_revision=revision,authorization=authorization})
	}
	run_native_jobs(s, jobs[:])
	pending, failed, restarting := false, false, false
	for t in r.application.targets {pending = pending || t.state=="pending"; failed=failed || t.state=="failed"; restarting=restarting || t.state=="restarting"}
	state := "pending" if pending else "restarting" if restarting else "partial_failure" if failed else "ready"
	set_text(&r.application.state,state)
	after, _ := json.marshal(r.application, allocator=context.temp_allocator)
	if string(before) == string(after) do return
	prior := r.application.revision; r.application.revision += 1
	set_text(&r.application.updated_at,platform.clock_now(s.clock))
	if saved, _ := iface.fleet_application_put(s.settings.bridges,r,prior); saved && s.on_changed != nil do s.on_changed(s.event_ctx,owner,r.application,false)
}
// Only applications with pending or restarting targets have anything to
// observe; settled partial failures move again only through retry_application.
reconcile :: proc(s: ^Service) {
	if s == nil || s.agents == nil || s.settings.bridges == nil do return
	rows, err := iface.fleet_application_list_active(s.settings.bridges)
	if err.code != .None do return
	defer {for &r in rows do domain.fleet_application_record_destroy(&r); delete(rows)}
	for r in rows do if application_in_flight(r.application) do reconcile_one(s,r.owner_user_id,r.application.bridge_id,r.application.application_id)
}
retry_application :: proc(s: ^Service, auth: contracts.Auth_Context, bridge_id, id: string,authorization:=Authorization{}) -> (domain.Fleet_Application_Record, bool, domain.Domain_Error) {
	r, found, err := read_application(s,auth,bridge_id,id)
	if !found do return {},false,err
	if authorization.binding!="" && r.authority_json!=authorization.binding {domain.fleet_application_record_destroy(&r);return {},false,domain.domain_error(.Forbidden,"Fleet application belongs to another authorization")}
	owner := r.owner_user_id
	reconcile_one(s,owner,bridge_id,id,retry=true,authorization=authorization)
	domain.fleet_application_record_destroy(&r)
	return read_application(s,auth,bridge_id,id)
}
