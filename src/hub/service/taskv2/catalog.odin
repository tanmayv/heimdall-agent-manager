package taskv2

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

// Catalog writes are synchronous SQLite operations only. Callers propagate
// errors to their owning UoW
// Network I/O happens only in the relay after commit.
catalog_emit :: proc(
	repo: ^iface.Taskchain_Repository,
	clock: ^platform.Clock,
	owner: domain.User_ID,
	chain_id: domain.Task_Chain_ID,
	task_id: domain.Task_ID,
	typ, class, data, actor: string,
	topic_suffix := "",
	replace_open := false,
) -> (
	string,
	domain.Domain_Error,
) {
	if repo == nil || repo.catalog.append == nil do return "", {}
	event_id := platform.time_id_generate(nil, "evt_")
	topic := ""
	generation: i64
	if topic_suffix != "" {
		topic = fmt.tprintf("task.%s.%s", task_id, topic_suffix)
		g, opened, err := repo.catalog.open_topic(repo.catalog.ctx, string(owner), topic, event_id, replace_open)
		if err.code != .None do return "", err
		if !opened do return "", {}
		generation = g
	}
	kind := "task" if task_id != "" else "chain"
	id := string(task_id) if task_id != "" else string(chain_id)
	version, err := repo.catalog.next_version(repo.catalog.ctx, string(owner), kind, id)
	if err.code != .None do return "", err
	at := platform.clock_now(clock)
	p := json_begin()
	json_str(&p, "event_id", event_id)
	json_str(&p, "type", typ)
	json_str(&p, "class", class)
	json_str(&p, "owner_user_id", string(owner))
	json_str(&p, "chain_id", string(chain_id))
	json_str(&p, "task_id", string(task_id))
	json_int(&p, "entity_version", version)
	if topic != "" {json_str(&p, "topic_key", topic)
		json_int(&p, "topic_generation", generation)}
	json_raw(&p, "data", data)
	json_str(&p, "actor", actor)
	json_str(&p, "occurred_at", at)
	suffix := strings.trim_prefix(typ, fmt.tprintf("%s.", kind))
	subject := fmt.tprintf("ev.%s.chain.%s.%s", owner, chain_id, suffix)
	if task_id != "" {
		subject = fmt.tprintf("ev.%s.chain.%s.task.%s.%s", owner, chain_id, task_id, suffix)
	}
	row := domain.Event_Outbox_Row {
		event_id      = event_id,
		owner_user_id = string(owner),
		subject       = subject,
		envelope_json = json_end(&p),
		headers_json  = `{"Nats-Rollup":"sub"}` if class == "state" else "{}",
		created_at    = at,
	}
	return event_id, repo.catalog.append(repo.catalog.ctx, row)
}

catalog_actor :: proc(actor: Actor, agent_id := "") -> string {
	if actor.kind == ACTOR_USER || actor.kind == ACTOR_COORDINATOR && actor.id == "user" do return "user"
	if strings.has_prefix(agent_id, "agt_") do return agent_id
	if strings.has_prefix(actor.id, "agt_") do return actor.id
	return "hub"
}

catalog_resolve :: proc(
	repo: ^iface.Taskchain_Repository,
	clock: ^platform.Clock,
	task: domain.Task,
	suffix, event_id: string,
) -> domain.Domain_Error {
	if repo.catalog.resolve_topic == nil do return {}
	return repo.catalog.resolve_topic(
		repo.catalog.ctx,
		string(task.owner_user_id),
		fmt.tprintf("task.%s.%s", task.task_id, suffix),
		platform.clock_now(clock),
		event_id,
	)
}

// Chain row mutations are owned by taskchain as well as taskv2.
catalog_chain_state :: proc(
	repo: ^iface.Taskchain_Repository,
	clock: ^platform.Clock,
	before, after: domain.Task_Chain,
) -> domain.Domain_Error {
	if before.status == after.status && before.publish_state == after.publish_state do return {}
	// Cancelled is not part of the v1 chain-state catalog.
	state := "active"
	switch after.status {
	case .Active:
		state = "active"
	case .Completed:
		state = "completed"
	case .Archived:
		state = "archived"
	case .Cancelled:
		return {}
	}
	p := json_begin()
	json_str(&p, "state", state)
	json_str(&p, "completed_at", after.completed_at)
	json_str(&p, "updated_at", after.updated_at)
	_, err := catalog_emit(
		repo,
		clock,
		after.owner_user_id,
		after.chain_id,
		"",
		"chain.state",
		"state",
		json_end(&p),
		"hub",
	)
	return err
}

catalog_task_event :: proc(
	repo: ^iface.Taskchain_Repository,
	clock: ^platform.Clock,
	task: domain.Task,
	actor: Actor,
	kind, payload: string,
	audit_id: i64,
) -> domain.Domain_Error {
	data := json_begin()
	event_id := fmt.tprintf("task_event_%d", audit_id)
	switch kind {
	case EV_REQUIREMENTS_CHANGED:
		json_int(&data, "revision", i64(jsonx.extract_int(payload, "revision", 0, true)))
		id, err := catalog_emit(
			repo,
			clock,
			task.owner_user_id,
			task.chain_id,
			task.task_id,
			"task.requirements_changed",
			"occurrence",
			json_end(&data),
			catalog_actor(actor),
		)
		if err.code != .None do return err
		return catalog_resolve(repo, clock, task, "review_request", id)
	case EV_REVIEW_POSTED:
		json_str(&data, "verdict", jsonx.extract_string(payload, "verdict", "", true, context.temp_allocator))
		json_str(&data, "role", jsonx.extract_string(payload, "role", "", true, context.temp_allocator))
		id, err := catalog_emit(
			repo,
			clock,
			task.owner_user_id,
			task.chain_id,
			task.task_id,
			"task.review_verdict",
			"occurrence",
			json_end(&data),
			catalog_actor(actor, jsonx.extract_string(payload, "reviewer_agent_id", "", true, context.temp_allocator)),
		)
		if err.code != .None do return err
		human :=
			actor.kind == ACTOR_USER ||
			jsonx.extract_string(payload, "on_behalf_of", "", true, context.temp_allocator) == "user"
		if human do return catalog_resolve(repo, clock, task, "review_request", id)
	case EV_BLOCKED:
		waiting, _ := jsonx.extract_raw_object(payload, "waiting_on", true, context.temp_allocator)
		human := jsonx.extract_string(waiting, "kind", "", true, context.temp_allocator)
		if human == "user" || human == "human" {
			_, err := catalog_emit(
				repo,
				clock,
				task.owner_user_id,
				task.chain_id,
				task.task_id,
				"task.blocked_on_human",
				"resolvable",
				"{}",
				catalog_actor(actor),
				"blocked_on_human",
				true,
			)
			return err
		}
	case EV_MERGE_CONFLICT:
		_, err := catalog_emit(
			repo,
			clock,
			task.owner_user_id,
			task.chain_id,
			task.task_id,
			"task.merge_conflict",
			"resolvable",
			"{}",
			"hub",
			"merge_conflict",
			true,
		)
		return err
	case EV_MERGED:
		return catalog_resolve(repo, clock, task, "merge_conflict", event_id)
	case EV_CANCELLED:
		for suffix in ([]string{"review_request", "blocked_on_human", "merge_conflict"}) {
			if err := catalog_resolve(repo, clock, task, suffix, event_id); err.code != .None do return err
		}
	}
	return {}
}

catalog_review_request :: proc(svc: ^Service, task: domain.Task) -> domain.Domain_Error {
	_, err := catalog_emit(
		svc.repo,
		svc.clock,
		task.owner_user_id,
		task.chain_id,
		task.task_id,
		"task.review_requested_from_user",
		"resolvable",
		"{}",
		"hub",
		"review_request",
	)
	return err
}

catalog_work_finished :: proc(svc: ^Service, chain: domain.Task_Chain, outcome: string) -> domain.Domain_Error {
	p := json_begin()
	json_str(&p, "outcome", outcome)
 current, found, read_err := iface.taskchain_get_chain(svc.repo, chain.chain_id)
 if read_err.code != .None do return read_err
 if !found do return domain.domain_error(.Not_Found, "chain not found")
 json_int(&p, "work_revision", current.work_revision)
	_, err := catalog_emit(
		svc.repo,
		svc.clock,
		chain.owner_user_id,
		chain.chain_id,
		"",
		"chain.work_finished",
		"occurrence",
		json_end(&p),
		"hub",
	)
	return err
}

// Projection changes are observed once at their durable write. Re-evaluating
// an unchanged fold does not produce an event or advance its counter.
catalog_task_projection :: proc(
	svc: ^Service,
	before, after: domain.Task,
	evs: []domain.Task_Event,
) -> domain.Domain_Error {
	audit_id: i64
	if len(evs) > 0 do audit_id = evs[len(evs) - 1].event_id
	resolving_id := fmt.tprintf("task_event_%d", audit_id)
	if blocked_on_without_hold(after.blocked_on_json) != blocked_on_without_hold(before.blocked_on_json) {
		human := jsonx.extract_string(
			blocked_on_without_hold(after.blocked_on_json),
			"kind",
			"",
			true,
			context.temp_allocator,
		)
		if human != "user" && human != "human" {
			if err := catalog_resolve(svc.repo, svc.clock, after, "blocked_on_human", resolving_id); err.code != .None do return err
		}
	}
	if before.state != after.state {
		if before.state == .In_Review {
			if err := catalog_resolve(svc.repo, svc.clock, after, "review_request", resolving_id); err.code != .None do return err
		}
		p := json_begin()
		json_str(&p, "state", domain.task_state_string(after.state))
		if _, err := catalog_emit(svc.repo, svc.clock, after.owner_user_id, after.chain_id, after.task_id, "task.state", "state", json_end(&p), "hub"); err.code != .None do return err
	}
	return {}
}
