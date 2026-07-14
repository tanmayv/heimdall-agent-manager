package main

// teams-v2 Phase 1: durable agent identity tier (`Agent_Id_Record`).
//
// Three-tier identity model:
//   agent_id            durable identity (name + role/template + defaults + memory target)
//   agent_instance_id   = agent_id@project, runtime binding, 1:1 with a live session
//   (chains)            served by an instance via association records
//
// The agent_id record is the durable "who" that survives across projects and
// restarts. Instance records (agent_store.odin) reference it via `agent_id` and
// hold the per-(agent,project) runtime binding. Under Rule A the instance's home
// project is authoritative for restart.
//
// This store is append-only (JSONL) and mirrors the style of agent_store.odin so
// it replays deterministically on daemon start. It is intentionally in-memory +
// event-log (no sqlite) to match the instance store.

import "core:fmt"
import "core:os"
import "core:strings"

AGENT_ID_MAX_RECORDS :: 1024
AGENT_ID_MAX_EVENTS :: 4096

AGENT_ID_STATE_ACTIVE :: "active"
AGENT_ID_STATE_ARCHIVED :: "archived"

Agent_Id_Record :: struct {
	agent_id: string,
	display_name: string,
	template_id: string,
	agent_role: string,
	default_provider_profile: string,
	default_model_tier: string,
	state: string,
	created_unix_ms: i64,
	updated_unix_ms: i64,
	archived_at_unix_ms: i64,
	order: int,
}

Agent_Id_Event_Kind :: enum { Agent_Id_Upserted, Agent_Id_Archived }
Agent_Id_Event :: struct {
	event_id: string,
	kind: Agent_Id_Event_Kind,
	agent_id: string,
	display_name: string,
	template_id: string,
	agent_role: string,
	default_provider_profile: string,
	default_model_tier: string,
	state: string,
	author: string,
	created_unix_ms: i64,
	order: int,
}

agent_id_records: [AGENT_ID_MAX_RECORDS]Agent_Id_Record
agent_id_record_count: int
agent_id_events_path: string
agent_id_store_sequence: i64

agent_id_store_init :: proc(store_dir: string) {
	agent_id_record_count = 0
	agent_id_store_sequence = 0
	agent_id_events_path = strings.clone(fmt.tprintf("%s/id-events.jsonl", store_dir))
	agent_id_store_replay()
}

agent_id_store_replay :: proc() {
	data, err := os.read_entire_file(agent_id_events_path, context.allocator)
	if err != nil do return
	for line in strings.split(string(data), "\n") {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		if ev, ok := agent_id_event_from_json(trimmed); ok do agent_id_apply_event(ev)
	}
}

agent_id_store_next_sequence :: proc() -> i64 { agent_id_store_sequence += 1; return agent_id_store_sequence }

agent_id_index :: proc(agent_id: string) -> int {
	for i in 0..<agent_id_record_count { if agent_id_records[i].agent_id == agent_id do return i }
	return -1
}

agent_id_exists :: proc(agent_id: string) -> bool { return agent_id_index(agent_id) >= 0 }

agent_id_is_active :: proc(agent_id: string) -> bool {
	idx := agent_id_index(agent_id)
	return idx >= 0 && agent_id_records[idx].archived_at_unix_ms == 0
}

// Derive the durable agent_id from an agent_instance_id. Reserved identities
// (operator@local, user_proxy) map to themselves. Otherwise the id is the prefix
// before the first '@' (the instance's home-project separator).
agent_id_from_instance_id :: proc(agent_instance_id: string) -> string {
	if agent_instance_id_is_reserved(agent_instance_id) do return strings.clone(agent_instance_id)
	if at := strings.index_byte(agent_instance_id, '@'); at >= 0 {
		return strings.clone(agent_instance_id[:at])
	}
	return strings.clone(agent_instance_id)
}

// Compose an agent_instance_id from a durable agent_id and a project.
// project_id "" yields the bare agent_id (a not-yet-bound identity).
agent_instance_id_compose :: proc(agent_id, project_id: string) -> string {
	if project_id == "" do return strings.clone(agent_id)
	return strings.clone(fmt.tprintf("%s@%s", agent_id, project_id))
}

agent_id_append_event :: proc(event: Agent_Id_Event) -> bool {
	ev := agent_id_event_clone(event)
	if ev.event_id == "" do ev.event_id = strings.clone(fmt.tprintf("agent_id_evt_%d_%d", router_now_unix_ms(), agent_id_store_next_sequence()))
	if ev.created_unix_ms == 0 do ev.created_unix_ms = router_now_unix_ms()
	file, err := os.open(agent_id_events_path, os.O_CREATE | os.O_APPEND | os.O_WRONLY)
	if err != nil do return false
	defer os.close(file)
	os.write_string(file, agent_id_event_json(ev)); os.write_string(file, "\n")
	return agent_id_apply_event(ev)
}

agent_id_apply_event :: proc(event: Agent_Id_Event) -> bool {
	idx := agent_id_index(event.agent_id)
	if idx < 0 {
		if agent_id_record_count >= AGENT_ID_MAX_RECORDS do return false
		idx = agent_id_record_count; agent_id_record_count += 1
		agent_id_records[idx].agent_id = strings.clone(event.agent_id)
		agent_id_records[idx].created_unix_ms = event.created_unix_ms
	}
	rec := &agent_id_records[idx]
	if event.kind == .Agent_Id_Archived {
		rec.archived_at_unix_ms = event.created_unix_ms
		rec.updated_unix_ms = event.created_unix_ms
		rec.state = strings.clone(AGENT_ID_STATE_ARCHIVED)
		return true
	}
	rec.display_name = strings.clone(event.display_name)
	rec.template_id = strings.clone(event.template_id)
	role := event.agent_role
	if role == "" do role = agent_role_from_template(event.template_id)
	rec.agent_role = strings.clone(agent_role_normalize(role))
	rec.default_provider_profile = strings.clone(event.default_provider_profile)
	tier := event.default_model_tier
	if tier != "" do tier = normalize_model_tier(tier)
	rec.default_model_tier = strings.clone(tier)
	state := event.state
	if state == "" do state = rec.state
	if state == "" do state = AGENT_ID_STATE_ACTIVE
	if rec.archived_at_unix_ms != 0 do state = AGENT_ID_STATE_ARCHIVED
	rec.state = strings.clone(state)
	if rec.created_unix_ms == 0 do rec.created_unix_ms = event.created_unix_ms
	rec.updated_unix_ms = event.created_unix_ms
	rec.order = event.order
	return true
}

// Idempotent backfill: ensure an Agent_Id_Record exists for the given id.
// Called from instance event replay so every pre-existing instance gets a
// durable identity. Does not overwrite an already-present record's fields
// (identity defaults are authoritative once created); only fills blanks.
agent_id_ensure_backfill :: proc(agent_id, display_name, template_id, provider_profile, model_tier: string, created_unix_ms: i64, agent_role: string = "") {
	if agent_id == "" do return
	if agent_instance_id_is_reserved(agent_id) do return
	idx := agent_id_index(agent_id)
	if idx >= 0 {
		// Fill any blanks discovered from later instance events.
		rec := &agent_id_records[idx]
		changed := false
		if rec.display_name == "" && display_name != "" { rec.display_name = strings.clone(display_name); changed = true }
		if rec.template_id == "" && template_id != "" { rec.template_id = strings.clone(template_id); changed = true }
		if rec.agent_role == "" { rec.agent_role = strings.clone(agent_role_normalize(agent_role if agent_role != "" else agent_role_from_template(template_id))); changed = true }
		if rec.default_provider_profile == "" && provider_profile != "" { rec.default_provider_profile = strings.clone(provider_profile); changed = true }
		if rec.default_model_tier == "" && model_tier != "" { rec.default_model_tier = strings.clone(normalize_model_tier(model_tier)); changed = true }
		if changed do agent_id_append_event(agent_id_record_to_event(rec^, "backfill"))
		return
	}
	dn := display_name; if dn == "" do dn = agent_id
	ts := created_unix_ms; if ts == 0 do ts = router_now_unix_ms()
	agent_id_append_event(Agent_Id_Event{
		kind = .Agent_Id_Upserted,
		agent_id = agent_id,
		display_name = dn,
		template_id = template_id,
		agent_role = agent_role_normalize(agent_role if agent_role != "" else agent_role_from_template(template_id)),
		default_provider_profile = provider_profile,
		default_model_tier = model_tier,
		state = AGENT_ID_STATE_ACTIVE,
		author = "backfill",
		created_unix_ms = ts,
	})
}

// Explicit create/update from the API (Create Agent button).
agent_id_upsert :: proc(agent_id, display_name, template_id, default_provider_profile, default_model_tier, author: string, agent_role: string = "") -> bool {
	if agent_id == "" do return false
	tier := default_model_tier; if tier != "" do tier = normalize_model_tier(tier)
	return agent_id_append_event(Agent_Id_Event{
		kind = .Agent_Id_Upserted,
		agent_id = agent_id,
		display_name = display_name,
		template_id = template_id,
		agent_role = agent_role_normalize(agent_role if agent_role != "" else agent_role_from_template(template_id)),
		default_provider_profile = default_provider_profile,
		default_model_tier = tier,
		state = AGENT_ID_STATE_ACTIVE,
		author = author,
	})
}

agent_id_record_to_event :: proc(rec: Agent_Id_Record, author: string) -> Agent_Id_Event {
	return Agent_Id_Event{
		kind = .Agent_Id_Upserted,
		agent_id = rec.agent_id,
		display_name = rec.display_name,
		template_id = rec.template_id,
		agent_role = rec.agent_role,
		default_provider_profile = rec.default_provider_profile,
		default_model_tier = rec.default_model_tier,
		state = rec.state,
		author = author,
		order = rec.order,
	}
}

agent_id_event_clone :: proc(e: Agent_Id_Event) -> Agent_Id_Event {
	out := e
	out.event_id = strings.clone(e.event_id)
	out.agent_id = strings.clone(e.agent_id)
	out.display_name = strings.clone(e.display_name)
	out.template_id = strings.clone(e.template_id)
	out.agent_role = strings.clone(e.agent_role)
	out.default_provider_profile = strings.clone(e.default_provider_profile)
	out.default_model_tier = strings.clone(e.default_model_tier)
	out.state = strings.clone(e.state)
	out.author = strings.clone(e.author)
	return out
}

agent_id_event_json :: proc(event: Agent_Id_Event) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"event_id":"`); json_write_string(&b, event.event_id)
	strings.write_string(&b, `","kind":"`); json_write_string(&b, fmt.tprintf("%v", event.kind))
	strings.write_string(&b, `","agent_id":"`); json_write_string(&b, event.agent_id)
	strings.write_string(&b, `","display_name":"`); json_write_string(&b, event.display_name)
	strings.write_string(&b, `","template_id":"`); json_write_string(&b, event.template_id)
	strings.write_string(&b, `","agent_role":"`); json_write_string(&b, agent_role_normalize(event.agent_role))
	strings.write_string(&b, `","default_provider_profile":"`); json_write_string(&b, event.default_provider_profile)
	strings.write_string(&b, `","default_model_tier":"`); json_write_string(&b, event.default_model_tier)
	strings.write_string(&b, `","state":"`); json_write_string(&b, event.state)
	strings.write_string(&b, `","author":"`); json_write_string(&b, event.author)
	strings.write_string(&b, `","order":`); strings.write_string(&b, fmt.tprintf("%d", event.order))
	strings.write_string(&b, `,"created_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", event.created_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

// teams-v2 Phase 1: deterministic provider/tier resolution for launching an
// instance. First non-empty wins:
//   1. explicit request value
//   2. the instance record's resolved value
//   3. the agent_id's durable default
//   4. the template default
//   5. config global default
// Note: in this repo `pi` IS a runnable provider profile (config.toml
// [wrapper.agent-cmd.pi], default_agent = "pi"), so template seeds using "pi"
// are valid and are intentionally NOT changed.
agent_resolve_provider_profile :: proc(agent_id, request_value, instance_value: string) -> string {
	if request_value != "" do return strings.clone(request_value)
	if instance_value != "" do return strings.clone(instance_value)
	if idx := agent_id_index(agent_id); idx >= 0 && agent_id_records[idx].default_provider_profile != "" {
		return strings.clone(agent_id_records[idx].default_provider_profile)
	}
	if tid := agent_id_template_id(agent_id); tid != "" {
		if tidx := agent_template_index(tid); tidx >= 0 && agent_template_records[tidx].default_provider_profile != "" {
			return strings.clone(agent_template_records[tidx].default_provider_profile)
		}
	}
	if server_config.daemon.default_agent_provider_profile != "" do return strings.clone(server_config.daemon.default_agent_provider_profile)
	if server_config.wrapper.default_agent != "" do return strings.clone(server_config.wrapper.default_agent)
	return ""
}

agent_resolve_model_tier :: proc(agent_id, request_value, instance_value: string) -> string {
	if request_value != "" && valid_model_tier(request_value) do return normalize_model_tier(request_value)
	if instance_value != "" do return normalize_model_tier(instance_value)
	if idx := agent_id_index(agent_id); idx >= 0 && agent_id_records[idx].default_model_tier != "" {
		return normalize_model_tier(agent_id_records[idx].default_model_tier)
	}
	if tid := agent_id_template_id(agent_id); tid != "" {
		if tidx := agent_template_index(tid); tidx >= 0 && agent_template_records[tidx].suggested_model_tier != "" {
			return normalize_model_tier(agent_template_records[tidx].suggested_model_tier)
		}
	}
	return normalize_model_tier("normal")
}

// Resolve the template id for an agent_id: prefer the durable record, else fall
// back to the id itself (legacy agents used the class-as-template convention).
agent_id_template_id :: proc(agent_id: string) -> string {
	if idx := agent_id_index(agent_id); idx >= 0 && agent_id_records[idx].template_id != "" {
		return agent_id_records[idx].template_id
	}
	return agent_id
}

agent_id_event_from_json :: proc(line: string) -> (Agent_Id_Event, bool) {
	kind := Agent_Id_Event_Kind.Agent_Id_Upserted
	if extract_json_string(line, "kind", "") == "Agent_Id_Archived" do kind = .Agent_Id_Archived
	ev := Agent_Id_Event{
		event_id = extract_json_string(line, "event_id", ""),
		kind = kind,
		agent_id = extract_json_string(line, "agent_id", ""),
		display_name = extract_json_string(line, "display_name", ""),
		template_id = extract_json_string(line, "template_id", ""),
		default_provider_profile = extract_json_string(line, "default_provider_profile", ""),
		default_model_tier = extract_json_string(line, "default_model_tier", ""),
		state = extract_json_string(line, "state", ""),
		author = extract_json_string(line, "author", ""),
		order = extract_json_int(line, "order", 0),
		created_unix_ms = i64(extract_json_int(line, "created_unix_ms", 0)),
	}
	return ev, ev.agent_id != ""
}
