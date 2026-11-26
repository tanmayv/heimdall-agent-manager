package taskv2

import "core:fmt"
import json "core:encoding/json"
import "core:slice"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// SCHED-0a one-shot data mapping (spec art_18eb828949cd9431, section 11.1,
// REQ-SCHED-10). Migration 257 adds the schema, snapshots every fleet row's role
// data into sched0_fleet_roles and leaves the sched0_migration_pending marker
// (only on a database that already had task-system data). The first boot after
// it runs this step inside the boot UoW, before boot_regate:
//
//   * review roles are folded into brief.reviewers: every agent whose fleet row
//     held one of the brief's review_roles becomes a named reviewer, the role
//     description becomes brief.review_focus[agent], review_roles is removed;
//   * the assignee is never in its own reviewer list;
//   * an open unassigned task is assigned to the coordinator's agent only in a
//     true soloist chain (the Soloist agent coordinates, or the coordinator's
//     agent is the only agent of the chain's fleet);
//   * a task that cannot be mapped is held (`sched0_migration: <causes>`) and
//     never reassigned or approved by accident;
//   * agent verdicts on the current attempt collapse to one row per agent, live
//     review leases cover exactly that row, and parked review claims go;
//   * running workflow runs get their stage mapping recorded (their spec
//     snapshot is immutable) and listed for the coordinator;
//   * each affected chain's coordinator gets one migration_hold notice.
//
// Every task whose brief changes gets a sched0_migrated event with the before
// and after values. Taking the marker is the idempotence guard: a second boot
// finds no marker and changes nothing.
//
// Agent verdicts are collapsed under domain.SCHED0_REVIEW_ROLE ("review", the
// role every agent verdict carries since SCHED-0b). A fleet row the
// coordinator's agent may still have is ignored for launching (spec 6.1), and
// chain defaults_json.review_roles is no longer read by anything.

// The pre-SCHED-0b role vocabulary, read only by this one-shot mapping.
@(private = "file")
SCHED0_LEGACY_NAMED_ROLE :: "named"
@(private = "file")
SCHED0_LEGACY_NAMED_REVIEWER_ROW :: "named-reviewer"
@(private = "file")
SCHED0_LEGACY_DEFAULT_ROLES_JSON :: `["worker"]`

// sched0_legacy_brief_roles: a pre-0b brief's review_roles.
@(private = "file")
sched0_legacy_brief_roles :: proc(brief_json: string, allocator := context.allocator) -> [dynamic]string {
	return jsonx.extract_string_array(brief_json, "review_roles", true, allocator)
}

// sched0_legacy_role_description: chain.defaults_json.review_roles.<name>.description.
@(private = "file")
sched0_legacy_role_description :: proc(defaults_json, role: string) -> string {
	roles_obj, ok := jsonx.extract_raw_object(defaults_json, "review_roles", true, context.temp_allocator)
	if !ok do return ""
	entry, eok := jsonx.extract_raw_object(roles_obj, role, true, context.temp_allocator)
	if !eok do return ""
	return jsonx.extract_string(entry, "description", "", true, context.temp_allocator)
}

EV_SCHED0_MIGRATED :: "sched0_migrated" // {before, after, assigned_to_coordinator, causes}
SCHED0_HOLD_PREFIX :: "sched0_migration: "
NOTICE_MIGRATION_HOLD :: "migration_hold"

// Causes recorded in the hold reason and the sched0_migrated event.
SCHED0_CAUSE_NO_ASSIGNEE :: "no_assignee"
SCHED0_CAUSE_ASSIGNEE_MISSING :: "assignee_missing"
SCHED0_CAUSE_ROLE_UNHELD :: "review_role_unheld"
SCHED0_CAUSE_REVIEWER_MISSING :: "reviewer_missing"

@(private = "file")
Sched0_Chain :: struct {
	chain:          domain.Task_Chain,
	found:          bool,
	resolved:       bool,
	coord_agent:    string,
	soloist:        bool,
	fleets:         [dynamic]domain.Sched0_Fleet_Roles,
	held:           [dynamic]string,
	unmapped_draft: [dynamic]string,
	partial_paused: [dynamic]string,
	workflow:       [dynamic]string,
}

@(private = "file")
Sched0_Run :: struct {
	svc:    ^Service,
	u:      ^Uow,
	chains: map[domain.Task_Chain_ID]^Sched0_Chain,
	agents: map[string]bool, // agent id → exists for the owner (keyed "owner|agent")
	order:  [dynamic]domain.Task_Chain_ID,
}

// sched0_migrate_in_uow runs the mapping once. A repository without the marker
// (bare test services) or a database without one is a no-op. A failed read or
// write returns false so boot rolls back and the marker stays for the next boot.
sched0_migrate_in_uow :: proc(svc: ^Service, u: ^Uow) -> (bool, domain.Domain_Error) {
	taken, terr := iface.taskchain_take_sched0_migration(svc.repo)
	if terr.code != .None || !taken do return true, {}
	snapshot, serr := iface.taskchain_list_sched0_fleet_roles(svc.repo)
	if serr.code != .None do return false, serr

	run := Sched0_Run{
		svc = svc, u = u,
		chains = make(map[domain.Task_Chain_ID]^Sched0_Chain, context.temp_allocator),
		agents = make(map[string]bool, context.temp_allocator),
		order = make([dynamic]domain.Task_Chain_ID, context.temp_allocator),
	}
	for row in snapshot {
		st := sched0_chain(&run, row.chain_id)
		append(&st.fleets, row)
	}
	// Coordinator and soloist need the full fleet, so resolve after the snapshot.
	for id in run.order do sched0_resolve_chain(&run, run.chains[id])
	for id in run.order {
		st := run.chains[id]
		for row in st.fleets do if desc, partial := sched0_partial_pause(row); partial do append(&st.partial_paused, desc)
	}

	for state in domain.Task_State {
		tasks, lerr := iface.taskchain_list_tasks_by_state(svc.repo, state)
		if lerr.code != .None do return false, lerr
		for task in tasks {
			if ok, err := sched0_map_task(&run, task); !ok do return false, err
		}
	}

	if ok, err := sched0_map_review_leases(&run); !ok do return false, err

	for id in run.order {
		if ok, err := sched0_map_workflow_runs(&run, run.chains[id]); !ok do return false, err
	}

	for id in run.order do sched0_alert(&run, run.chains[id])
	if cerr := iface.taskchain_clear_sched0_fleet_roles(svc.repo); cerr.code != .None do return false, cerr
	return true, {}
}

@(private = "file")
sched0_chain :: proc(run: ^Sched0_Run, chain_id: domain.Task_Chain_ID) -> ^Sched0_Chain {
	if st, ok := run.chains[chain_id]; ok do return st
	st := new(Sched0_Chain, context.temp_allocator)
	st.fleets = make([dynamic]domain.Sched0_Fleet_Roles, context.temp_allocator)
	st.held = make([dynamic]string, context.temp_allocator)
	st.unmapped_draft = make([dynamic]string, context.temp_allocator)
	st.partial_paused = make([dynamic]string, context.temp_allocator)
	st.workflow = make([dynamic]string, context.temp_allocator)
	run.chains[chain_id] = st
	append(&run.order, chain_id)
	st.chain, st.found, _ = iface.taskchain_get_chain(run.svc.repo, chain_id)
	return st
}

@(private = "file")
sched0_resolve_chain :: proc(run: ^Sched0_Run, st: ^Sched0_Chain) {
	if st.resolved || !st.found do return
	st.resolved = true
	st.coord_agent = chain_coordinator_agent_id(run.svc, st.chain)
	if st.coord_agent == "" do return
	if ag, aok, _ := iface.agent_get(run.svc.agents, st.coord_agent); aok && (ag.slug == SOLOIST_AGENT_SLUG || ag.template_id == domain.TEMPLATE_SOLOIST_ID) {
		st.soloist = true
		return
	}
	// The coordinator's agent is the only agent of the chain's fleet: a chain
	// that can only ever have been worked by its coordinator.
	st.soloist = len(st.fleets) > 0
	for row in st.fleets do if row.agent_id != st.coord_agent { st.soloist = false; break }
}

// sched0_partial_pause: a row paused for some but not all of its roles. The
// migration paused it fully (fail closed); the coordinator is told.
@(private = "file")
sched0_partial_pause :: proc(row: domain.Sched0_Fleet_Roles) -> (string, bool) {
	raw := strings.trim_space(row.paused_roles_json)
	if raw == "" || raw == "[]" do return "", false
	paused := jsonx.decode_string_array(raw, context.temp_allocator)
	for p in paused do if p == "*" do return "", false
	roles := jsonx.decode_string_array(row.roles_json if strings.trim_space(row.roles_json) != "" else SCHED0_LEGACY_DEFAULT_ROLES_JSON, context.temp_allocator)
	all := true
	for r in roles {
		if !slice.contains(paused[:], r) { all = false; break }
	}
	if all do return "", false
	return fmt.tprintf("%s (was paused for %s only)", row.agent_id, strings.join(paused[:], ",", context.temp_allocator)), true
}

@(private = "file")
sched0_holders :: proc(st: ^Sched0_Chain, role: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	for row in st.fleets {
		roles := jsonx.decode_string_array(row.roles_json if strings.trim_space(row.roles_json) != "" else SCHED0_LEGACY_DEFAULT_ROLES_JSON, context.temp_allocator)
		if slice.contains(roles[:], role) && !slice.contains(out[:], row.agent_id) do append(&out, row.agent_id)
	}
	return out
}

// sched0_agent_exists: an agent id owned by `owner`. A read error fails the step.
@(private = "file")
sched0_agent_exists :: proc(run: ^Sched0_Run, owner: domain.User_ID, agent_id: string) -> (bool, domain.Domain_Error) {
	key := fmt.tprintf("%s|%s", owner, agent_id)
	if v, ok := run.agents[key]; ok do return v, {}
	ag, found, err := iface.agent_get(run.svc.agents, agent_id)
	if err.code != .None && err.code != .Not_Found do return false, err
	exists := found && ag.owner_user_id == owner
	run.agents[key] = exists
	return exists, {}
}

@(private = "file")
Sched0_Brief :: struct {
	assignee:     string,
	reviewers:    [dynamic]string,
	review_roles: [dynamic]string,
	focus:        map[string]string,
}

// sched0_mapped_brief computes the new assignee, reviewers and review_focus and
// the causes that make an open task unmappable.
@(private = "file")
sched0_mapped_brief :: proc(run: ^Sched0_Run, st: ^Sched0_Chain, task: domain.Task, open: bool) -> (before, after: Sched0_Brief, assigned_to_coordinator: bool, causes: [dynamic]string, ok: bool, err: domain.Domain_Error) {
	causes = make([dynamic]string, context.temp_allocator)
	before.assignee = brief_assignee(task.brief_json)
	before.reviewers = make([dynamic]string, context.temp_allocator)
	for r in jsonx.extract_string_array(task.brief_json, "reviewers", true, context.temp_allocator) {
		id := strings.trim_space(r)
		if id != "" && !slice.contains(before.reviewers[:], id) do append(&before.reviewers, id)
	}
	before.review_roles = sched0_legacy_brief_roles(task.brief_json, context.temp_allocator)

	after.assignee = before.assignee
	after.focus = make(map[string]string, context.temp_allocator)
	if raw, fok := jsonx.extract_raw_object(task.brief_json, "review_focus", true, context.temp_allocator); fok {
		for k, v in jsonx_top_level_members(raw) do after.focus[k] = jsonx.json_unescape_string(strings.trim(v, `"`), context.temp_allocator)
	}
	if open && task.kind != .Gate && after.assignee == "" {
		if st.soloist && st.coord_agent != "" {
			after.assignee = st.coord_agent
			assigned_to_coordinator = true
		} else {
			append(&causes, SCHED0_CAUSE_NO_ASSIGNEE)
		}
	}
	if open && task.kind != .Gate && after.assignee != "" {
		exists, aerr := sched0_agent_exists(run, task.owner_user_id, after.assignee)
		if aerr.code != .None do return before, after, false, causes, false, aerr
		if !exists do append(&causes, fmt.tprintf("%s %s", SCHED0_CAUSE_ASSIGNEE_MISSING, after.assignee))
	}

	after.reviewers = make([dynamic]string, context.temp_allocator)
	add :: proc(list: ^[dynamic]string, id, assignee: string) {
		if id == "" || id == assignee || slice.contains(list[:], id) do return
		append(list, id)
	}
	for r in before.reviewers do add(&after.reviewers, r, after.assignee)
	for role in before.review_roles {
		role := strings.trim_space(role)
		if role == "" || role == SCHED0_LEGACY_NAMED_ROLE || role == SCHED0_LEGACY_NAMED_REVIEWER_ROW do continue
		desc := sched0_legacy_role_description(st.chain.defaults_json, role) if st.found else ""
		mapped := 0
		for holder in sched0_holders(st, role) {
			if holder == after.assignee do continue
			mapped += 1
			add(&after.reviewers, holder, after.assignee)
			if strings.trim_space(desc) == "" do continue
			if prev, has := after.focus[holder]; has && prev != "" && !strings.contains(prev, desc) {
				after.focus[holder] = fmt.tprintf("%s\n%s", prev, desc)
			} else if !has || prev == "" {
				after.focus[holder] = desc
			}
		}
		if mapped == 0 && open do append(&causes, fmt.tprintf("%s %s", SCHED0_CAUSE_ROLE_UNHELD, role))
	}
	if open {
		for r in after.reviewers {
			if r == "user" do continue
			exists, rerr := sched0_agent_exists(run, task.owner_user_id, r)
			if rerr.code != .None do return before, after, assigned_to_coordinator, causes, false, rerr
			if !exists do append(&causes, fmt.tprintf("%s %s", SCHED0_CAUSE_REVIEWER_MISSING, r))
		}
	}
	return before, after, assigned_to_coordinator, causes, true, {}
}

@(private = "file")
sched0_string_array :: proc(items: []string) -> json.Value {
	arr := make(json.Array, 0, len(items), context.temp_allocator)
	for it in items do append(&arr, json.String(it))
	return arr
}

// sched0_rewrite_brief returns brief_json with assignee, reviewers and
// review_focus replaced and review_roles removed; other keys are kept.
@(private = "file")
sched0_rewrite_brief :: proc(brief_json: string, after: Sched0_Brief) -> (string, bool) {
	parsed, perr := json.parse_string(brief_json if strings.trim_space(brief_json) != "" else "{}", parse_integers = true, allocator = context.temp_allocator)
	if perr != nil do return brief_json, false
	obj, is_obj := parsed.(json.Object)
	if !is_obj do return brief_json, false
	delete_key(&obj, "review_roles")
	if after.assignee != "" do obj["assignee"] = json.String(after.assignee)
	obj["reviewers"] = sched0_string_array(after.reviewers[:])
	if len(after.focus) > 0 {
		focus := make(json.Object, len(after.focus), context.temp_allocator)
		for k, v in after.focus do focus[k] = json.String(v)
		obj["review_focus"] = focus
	}
	out, merr := json.marshal(json.Value(obj), {sort_maps_by_key = true}, context.temp_allocator)
	if merr != nil do return brief_json, false
	return string(out), true
}

@(private = "file")
sched0_brief_json :: proc(b: Sched0_Brief, with_roles: bool) -> string {
	p := json_begin()
	json_str(&p, "assignee", b.assignee)
	json_raw(&p, "reviewers", sched0_json_array(b.reviewers[:]))
	if with_roles do json_raw(&p, "review_roles", sched0_json_array(b.review_roles[:]))
	if !with_roles && len(b.focus) > 0 {
		f := json_begin()
		keys := make([dynamic]string, context.temp_allocator)
		for k in b.focus do append(&keys, k)
		slice.sort(keys[:])
		for k in keys do json_str(&f, k, b.focus[k])
		json_raw(&p, "review_focus", json_end(&f))
	}
	return json_end(&p)
}

@(private = "file")
sched0_json_array :: proc(items: []string) -> string {
	out, err := json.marshal(sched0_string_array(items), {}, context.temp_allocator)
	return string(out) if err == nil else "[]"
}

@(private = "file")
sched0_same :: proc(a, b: []string) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if b[i] != x do return false
	return true
}

@(private = "file")
sched0_map_task :: proc(run: ^Sched0_Run, task_in: domain.Task) -> (bool, domain.Domain_Error) {
	svc, u := run.svc, run.u
	task := task_in
	st := sched0_chain(run, task.chain_id)
	sched0_resolve_chain(run, st)
	open := !domain.task_state_is_terminal(task.state)
	before, after, assigned, causes, ok, err := sched0_mapped_brief(run, st, task, open)
	if !ok do return false, err

	changed := len(before.review_roles) > 0 || after.assignee != before.assignee || !sched0_same(before.reviewers[:], after.reviewers[:])
	if changed {
		rewritten, rok := sched0_rewrite_brief(task.brief_json, after)
		if !rok {
			// An unparseable brief cannot be mapped; an open one is held.
			changed = false
			if open do append(&causes, "brief_unreadable")
		} else {
			task.brief_json = rewritten
			saved, sok, serr := iface.taskchain_save_task(svc.repo, task)
			if !sok do return false, serr
			task = saved
		}
	}
	if changed || len(causes) > 0 {
		p := json_begin()
		json_raw(&p, "before", sched0_brief_json(before, true))
		json_raw(&p, "after", sched0_brief_json(after, false))
		json_bool(&p, "assigned_to_coordinator", assigned)
		json_raw(&p, "causes", sched0_json_array(causes[:]))
		if _, aok, aerr := append_event(svc.repo, svc.clock, task, hub_actor(), EV_SCHED0_MIGRATED, json_end(&p)); !aok do return false, aerr
		effect_publish_task(u, task, EV_SCHED0_MIGRATED)
	}
	if !open || len(causes) == 0 do return true, {}

	// Unmappable open task: hold it. A draft cannot be dispatched, and a gate
	// cannot be held; both are listed for the coordinator instead.
	if task.publish_state != .Published || task.kind == .Gate {
		append(&st.unmapped_draft, string(task.task_id))
		return true, {}
	}
	append(&st.held, string(task.task_id))
	if task_is_held(task) do return true, {}
	h := json_begin()
	json_str(&h, "reason", strings.concatenate({SCHED0_HOLD_PREFIX, strings.join(causes[:], "; ", context.temp_allocator)}, context.temp_allocator))
	json_str(&h, "by", ACTOR_HUB)
	if _, _, hok, herr := record_event(svc, u, task, hub_actor(), EV_HELD, json_end(&h)); !hok do return false, herr
	return true, {}
}

// sched0_map_review_leases: parked review claims are deleted (a posted review no
// longer keeps a lease, REQ-SCHED-21). Then each in-review task's current
// attempt keeps one verdict per agent, its live review leases cover that single
// row, and its gate is re-evaluated under the mapped reviewers. Held tasks keep
// their gate as it is.
@(private = "file")
sched0_map_review_leases :: proc(run: ^Sched0_Run) -> (bool, domain.Domain_Error) {
	svc, u := run.svc, run.u
	leases, lerr := iface.taskchain_list_all_leases(svc.repo)
	if lerr.code != .None do return false, lerr
	for lease in leases {
		if lease.kind != domain.LEASE_KIND_REVIEW do continue
		if lease.phase == domain.LEASE_PHASE_WAITING {
			if _, derr := iface.taskchain_delete_lease(svc.repo, lease.lease_id); derr.code != .None do return false, derr
			if inst, iok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); iok && inst.current_task_id == string(lease.task_id) {
				mark_instance_idle(svc, u, lease.holder_instance_id, platform.clock_now(svc.clock))
			}
		}
	}
	tasks, terr := iface.taskchain_list_tasks_by_state(svc.repo, .In_Review)
	if terr.code != .None do return false, terr
	actor := Actor{kind = ACTOR_HUB, id = "sched0_migration"}
	for task in tasks {
		if _, nerr := iface.taskchain_sched0_normalize_reviews(svc.repo, task.task_id, task.attempt_no); nerr.code != .None do return false, nerr
		if task_is_held(task) do continue
		st := sched0_chain(run, task.chain_id)
		if !st.found do continue
		if _, ok, err := evaluate_gate_in_uow(svc, u, st.chain, task, actor); !ok {
			fmt.eprintfln("[taskv2] sched0 gate re-evaluation failed for %s: %s", task.task_id, err.message)
		}
	}
	return true, {}
}

// sched0_map_workflow_runs handles runs whose current execution is pending or
// running. Their spec snapshot is immutable (workflow_runs_identity_immutable,
// migration 097), so it is not rewritten: the role → agent mapping of every
// stage that names review roles is recorded as a sched0_migrated run event, the
// durable input for mapping the stage when its task is created (SCHED-0b), and
// the stages are listed for the coordinator. Stages are not tasks yet, so
// nothing can be held.
@(private = "file")
sched0_map_workflow_runs :: proc(run: ^Sched0_Run, st: ^Sched0_Chain) -> (bool, domain.Domain_Error) {
	if !st.found do return true, {}
	svc := run.svc
	runs, rerr := iface.taskchain_list_workflow_runs(svc.repo, st.chain.chain_id, st.chain.owner_user_id)
	if rerr.code != .None do return true, {} // bare repositories without workflow runs
	for wf in runs {
		exec, eok, eerr := iface.taskchain_get_workflow_execution(svc.repo, wf.run_id, wf.current_execution_no, wf.owner_user_id)
		if eerr.code != .None && eerr.code != .Not_Found do return false, eerr
		if !eok || (exec.state != domain.WORKFLOW_EXECUTION_PENDING && exec.state != domain.WORKFLOW_EXECUTION_RUNNING) do continue
		parsed, perr := json.parse_string(wf.spec_json, parse_integers = true, allocator = context.temp_allocator)
		if perr != nil do continue
		root, is_obj := parsed.(json.Object)
		if !is_obj do continue
		stages, has_stages := root["stages"].(json.Array)
		if !has_stages do continue
		mapping := json_begin()
		mapped_any := false
		for stage_value in stages {
			stage, sok := stage_value.(json.Object)
			if !sok do continue
			brief, bok := stage["brief"].(json.Object)
			if !bok do continue
			key, _ := stage["key"].(json.String)
			if key == "" { if id, iok := stage["id"].(json.String); iok do key = id }
			kind, _ := stage["kind"].(json.String)
			assignee, _ := brief["assignee"].(json.String)
			if strings.trim_space(string(assignee)) == "" && kind != "gate" {
				append(&st.workflow, fmt.tprintf("%s/%s: no assignee", wf.run_id, key))
			}
			roles_v, has_roles := brief["review_roles"].(json.Array)
			if !has_roles || len(roles_v) == 0 do continue
			reviewers := make([dynamic]string, context.temp_allocator)
			if existing, xok := brief["reviewers"].(json.Array); xok {
				for v in existing do if r, rok := v.(json.String); rok && string(r) != "" && !slice.contains(reviewers[:], string(r)) do append(&reviewers, string(r))
			}
			unmapped := make([dynamic]string, context.temp_allocator)
			for rv in roles_v {
				role, rok := rv.(json.String)
				if !rok || string(role) == "" || string(role) == SCHED0_LEGACY_NAMED_ROLE || string(role) == SCHED0_LEGACY_NAMED_REVIEWER_ROW do continue
				if strings.contains(string(role), "{{") { append(&unmapped, string(role)); continue }
				mapped := 0
				for h in sched0_holders(st, string(role)) {
					if h == string(assignee) do continue
					mapped += 1
					if !slice.contains(reviewers[:], h) do append(&reviewers, h)
				}
				if mapped == 0 do append(&unmapped, string(role))
			}
			entry := json_begin()
			json_raw(&entry, "reviewers", sched0_json_array(reviewers[:]))
			json_raw(&entry, "unmapped_roles", sched0_json_array(unmapped[:]))
			json_raw(&mapping, string(key), json_end(&entry))
			mapped_any = true
			if len(unmapped) > 0 {
				append(&st.workflow, fmt.tprintf("%s/%s: review roles %s have no holder", wf.run_id, key, strings.join(unmapped[:], ",", context.temp_allocator)))
			} else {
				append(&st.workflow, fmt.tprintf("%s/%s: review roles map to %s", wf.run_id, key, strings.join(reviewers[:], ",", context.temp_allocator)))
			}
		}
		if !mapped_any do continue
		payload := json_begin()
		json_raw(&payload, "stages", json_end(&mapping))
		if _, aok, aerr := iface.taskchain_append_workflow_run_event(svc.repo, domain.Workflow_Run_Event{
			run_id = wf.run_id, execution_no = wf.current_execution_no, chain_id = wf.chain_id, owner_user_id = wf.owner_user_id,
			ts_ms = now_ms(svc.clock), actor_kind = ACTOR_HUB, actor_id = "sched0_migration", kind = EV_SCHED0_MIGRATED, payload_json = json_end(&payload),
		}); !aok do return false, aerr
		effect_publish_workflow(run.u, st.chain.chain_id, st.chain.owner_user_id, wf.run_id, EV_SCHED0_MIGRATED)
	}
	return true, {}
}

// sched0_alert: one notice per chain with held tasks, unmappable drafts or
// workflow stages, or a row whose partial pause became a full pause. The held
// tasks also carry the cause in their held event, which the UI shows.
@(private = "file")
sched0_alert :: proc(run: ^Sched0_Run, st: ^Sched0_Chain) {
	if !st.found do return
	if len(st.held) == 0 && len(st.unmapped_draft) == 0 && len(st.partial_paused) == 0 && len(st.workflow) == 0 do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "[taskv2] %s: %d tasks need an assignee or reviewers", NOTICE_MIGRATION_HOLD, len(st.held))
	if len(st.held) > 0 do fmt.sbprintf(&b, ": %s", strings.join(st.held[:], ", ", context.temp_allocator))
	fmt.sbprintf(&b, ". Fix with `ham-ctl task update <id> --assignee <agt_…> --reviewer <agt_…|user>`, then `ham-ctl task release <id>`.")
	if len(st.unmapped_draft) > 0 do fmt.sbprintf(&b, " Unpublished or gate tasks to fix before publishing: %s.", strings.join(st.unmapped_draft[:], ", ", context.temp_allocator))
	if len(st.partial_paused) > 0 do fmt.sbprintf(&b, " Fleet rows now fully paused: %s.", strings.join(st.partial_paused[:], "; ", context.temp_allocator))
	if len(st.workflow) > 0 do fmt.sbprintf(&b, " Workflow stages to fix: %s.", strings.join(st.workflow[:], "; ", context.temp_allocator))
	effect_notify_coordinator(run.svc, run.u, st.chain.chain_id, st.chain.owner_user_id, NOTICE_MIGRATION_HOLD, strings.to_string(b))
	effect_publish_chain(run.u, st.chain.chain_id, st.chain.owner_user_id, NOTICE_MIGRATION_HOLD)
}
