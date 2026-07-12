package main

import "core:fmt"
import "core:os"
import "core:strings"

AGENT_MAX_RECORDS :: 1024
AGENT_MAX_EVENTS :: 4096

// Persisted identity + configuration for an agent. NEVER add runtime or session
// fields here (pid, tmux_pane, exec_state, last_heartbeat_*) — those go on
// Agent_Record in registry.odin so they stay in-memory only. Daemon is the
// source of truth for everything in this struct; wrapper-supplied values that
// disagree are sent back as corrections, not persisted.
Agent_Instance_Record :: struct {
	agent_record_id: string,
	agent_instance_id: string,
	display_name: string,
	template_id: string,
	provider_profile: string,
	project_id: string,
	run_dir: string,
	model_tier: string,
	created_unix_ms: i64,
	updated_unix_ms: i64,
	archived_at_unix_ms: i64,
	current_task_id: string,
	current_task_since: i64,
	last_needed_at_unix_ms: i64,
	order: int,
}

Agent_Instance_Event_Kind :: enum { Agent_Instance_Upserted, Agent_Instance_Archived }
Agent_Instance_Event :: struct {
	event_id: string,
	kind: Agent_Instance_Event_Kind,
	agent_record_id: string,
	agent_instance_id: string,
	display_name: string,
	template_id: string,
	provider_profile: string,
	project_id: string,
	run_dir: string,
	model_tier: string,
	current_task_id: string,
	current_task_since: i64,
	last_needed_at_unix_ms: i64,
	author: string,
	created_unix_ms: i64,
	order: int,
}

agent_instance_records: [AGENT_MAX_RECORDS]Agent_Instance_Record
agent_instance_record_count: int
agent_instance_events: [AGENT_MAX_EVENTS]Agent_Instance_Event
agent_instance_event_count: int
agent_store_dir: string
agent_instance_events_path: string

agent_store_init :: proc(data_dir: string) {
	agent_instance_record_count = 0
	agent_instance_event_count = 0
	agent_store_dir = strings.clone(fmt.tprintf("%s/agents", expand_home(data_dir)))
	agent_instance_events_path = strings.clone(fmt.tprintf("%s/instance-events.jsonl", agent_store_dir))
	_ = os.make_directory_all(agent_store_dir)
	agent_store_replay()
	agent_template_store_init(data_dir)
}

agent_store_append_event :: proc(event: Agent_Instance_Event) -> bool {
	ev := agent_instance_event_clone(event)
	if ev.event_id == "" do ev.event_id = strings.clone(fmt.tprintf("agent_evt_%d", router_now_unix_ms()))
	if ev.created_unix_ms == 0 do ev.created_unix_ms = router_now_unix_ms()
	file, err := os.open(agent_instance_events_path, os.O_CREATE | os.O_APPEND | os.O_WRONLY)
	if err != nil do return false
	defer os.close(file)
	os.write_string(file, agent_instance_event_json(ev)); os.write_string(file, "\n")
	return agent_store_apply_event(ev)
}

agent_store_replay :: proc() {
	data, err := os.read_entire_file(agent_instance_events_path, context.allocator)
	if err != nil do return
	for line in strings.split(string(data), "\n") {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		if ev, ok := agent_instance_event_from_json(trimmed); ok do agent_store_apply_event(ev)
	}
}

agent_store_apply_event :: proc(event: Agent_Instance_Event) -> bool {
	if agent_instance_event_count < AGENT_MAX_EVENTS { agent_instance_events[agent_instance_event_count] = agent_instance_event_clone(event); agent_instance_event_count += 1 }
	idx := agent_record_index(event.agent_record_id)
	if idx < 0 && event.agent_instance_id != "" do idx = agent_record_index_by_instance(event.agent_instance_id)
	if idx < 0 {
		if agent_instance_record_count >= AGENT_MAX_RECORDS do return false
		idx = agent_instance_record_count; agent_instance_record_count += 1
		agent_instance_records[idx].agent_record_id = strings.clone(event.agent_record_id)
		agent_instance_records[idx].created_unix_ms = event.created_unix_ms
	}
	rec := &agent_instance_records[idx]
	if event.kind == .Agent_Instance_Archived {
		rec.archived_at_unix_ms = event.created_unix_ms
		rec.updated_unix_ms = event.created_unix_ms
		return true
	}
	rec.agent_record_id = strings.clone(event.agent_record_id)
	rec.agent_instance_id = strings.clone(event.agent_instance_id)
	rec.display_name = strings.clone(event.display_name)
	rec.template_id = strings.clone(event.template_id)
	rec.provider_profile = strings.clone(event.provider_profile)
	rec.project_id = strings.clone(event.project_id)
	rec.run_dir = strings.clone(event.run_dir)
	tier := normalize_model_tier(event.model_tier)
	rec.model_tier = strings.clone(tier)
	if event.current_task_since == -1 {
		rec.current_task_id = ""
		rec.current_task_since = 0
	} else if event.current_task_id != "" || event.current_task_since != 0 {
		rec.current_task_id = strings.clone(event.current_task_id)
		rec.current_task_since = event.current_task_since
	}
	if event.last_needed_at_unix_ms != 0 do rec.last_needed_at_unix_ms = event.last_needed_at_unix_ms
	if rec.created_unix_ms == 0 do rec.created_unix_ms = event.created_unix_ms
	rec.updated_unix_ms = event.created_unix_ms
	rec.order = event.order
	return true
}

agent_record_index :: proc(agent_record_id: string) -> int { for i in 0..<agent_instance_record_count { if agent_instance_records[i].agent_record_id == agent_record_id do return i }; return -1 }
agent_record_index_by_instance :: proc(agent_instance_id: string) -> int { for i in 0..<agent_instance_record_count { if agent_instance_records[i].agent_instance_id == agent_instance_id do return i }; return -1 }

agent_instance_event_clone :: proc(e: Agent_Instance_Event) -> Agent_Instance_Event { out := e; out.event_id = strings.clone(e.event_id); out.agent_record_id = strings.clone(e.agent_record_id); out.agent_instance_id = strings.clone(e.agent_instance_id); out.display_name = strings.clone(e.display_name); out.template_id = strings.clone(e.template_id); out.provider_profile = strings.clone(e.provider_profile); out.project_id = strings.clone(e.project_id); out.run_dir = strings.clone(e.run_dir); out.model_tier = strings.clone(e.model_tier); out.current_task_id = strings.clone(e.current_task_id); out.author = strings.clone(e.author); return out }

agent_instance_event_json :: proc(event: Agent_Instance_Event) -> string {
	b := strings.builder_make(); strings.write_string(&b, `{"event_id":"`); json_write_string(&b, event.event_id); strings.write_string(&b, `","kind":"`); json_write_string(&b, fmt.tprintf("%v", event.kind)); strings.write_string(&b, `","agent_record_id":"`); json_write_string(&b, event.agent_record_id); strings.write_string(&b, `","agent_instance_id":"`); json_write_string(&b, event.agent_instance_id); strings.write_string(&b, `","display_name":"`); json_write_string(&b, event.display_name); strings.write_string(&b, `","template_id":"`); json_write_string(&b, event.template_id); strings.write_string(&b, `","provider_profile":"`); json_write_string(&b, event.provider_profile); strings.write_string(&b, `","project_id":"`); json_write_string(&b, event.project_id); strings.write_string(&b, `","run_dir":"`); json_write_string(&b, event.run_dir); strings.write_string(&b, `","model_tier":"`); json_write_string(&b, event.model_tier); strings.write_string(&b, `","current_task_id":"`); json_write_string(&b, event.current_task_id); strings.write_string(&b, `","current_task_since":`); strings.write_string(&b, fmt.tprintf("%d", event.current_task_since)); strings.write_string(&b, `,"last_needed_at_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", event.last_needed_at_unix_ms)); strings.write_string(&b, `,"order":`); strings.write_string(&b, fmt.tprintf("%d", event.order)); strings.write_string(&b, `,"author":"`); json_write_string(&b, event.author); strings.write_string(&b, `","created_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", event.created_unix_ms)); strings.write_string(&b, `}`); return strings.to_string(b)
}

agent_instance_event_from_json :: proc(line: string) -> (Agent_Instance_Event, bool) {
	kind := Agent_Instance_Event_Kind.Agent_Instance_Upserted
	if extract_json_string(line, "kind", "") == "Agent_Instance_Archived" do kind = .Agent_Instance_Archived
	ev := Agent_Instance_Event{event_id = extract_json_string(line, "event_id", ""), kind = kind, agent_record_id = extract_json_string(line, "agent_record_id", ""), agent_instance_id = extract_json_string(line, "agent_instance_id", ""), display_name = extract_json_string(line, "display_name", ""), template_id = extract_json_string(line, "template_id", ""), provider_profile = extract_json_string(line, "provider_profile", ""), project_id = extract_json_string(line, "project_id", ""), run_dir = extract_json_string(line, "run_dir", ""), model_tier = extract_json_string(line, "model_tier", ""), current_task_id = extract_json_string(line, "current_task_id", ""), current_task_since = i64(extract_json_int(line, "current_task_since", 0)), last_needed_at_unix_ms = i64(extract_json_int(line, "last_needed_at_unix_ms", 0)), author = extract_json_string(line, "author", ""), created_unix_ms = i64(extract_json_int(line, "created_unix_ms", 0)), order = extract_json_int(line, "order", 0)}
	return ev, ev.agent_record_id != "" || ev.agent_instance_id != ""
}

agent_new_record_id :: proc() -> string { return fmt.tprintf("agent_rec_%d", router_now_unix_ms()) }

agent_generated_instance_id :: proc(name, project_id: string) -> string {
	prefix := name; if prefix == "" do prefix = "agent"
	suffix := project_id; if suffix == "" do suffix = "default"
	return fmt.tprintf("%s@%s", safe_agent_id_part(prefix), safe_agent_id_part(suffix))
}

safe_agent_id_part :: proc(value: string) -> string {
	b := strings.builder_make()
	for ch in value {
		switch ch { case 'a'..='z', 'A'..='Z', '0'..='9', '-': strings.write_rune(&b, ch); case '_', ' ', '.', '@', '/': strings.write_string(&b, "-"); case: }
	}
	out := strings.to_string(b); if out == "" do return "agent"; return out
}

AGENT_TEMPLATE_MAX_RECORDS :: 256
AGENT_TEMPLATE_MAX_MEMORY_TEMPLATES :: 16

Agent_Template_Record :: struct {
	template_id: string,
	display_name: string,
	description: string,
	persona: string,
	instructions: string,
	role_hint: string,
	parent_template_id: string,
	default_provider_profile: string,
	bootstrap_defaults: string,
	suggested_model_tier: string,
	memory_templates: [AGENT_TEMPLATE_MAX_MEMORY_TEMPLATES]string,
	memory_template_count: int,
	created_unix_ms: i64,
	updated_unix_ms: i64,
	archived_at_unix_ms: i64,
	is_customized: bool,
}

Agent_Template_Event_Kind :: enum { Agent_Template_Upserted, Agent_Template_Archived }
Agent_Template_Event :: struct {
	event_id: string,
	kind: Agent_Template_Event_Kind,
	template_id: string,
	display_name: string,
	description: string,
	persona: string,
	instructions: string,
	role_hint: string,
	parent_template_id: string,
	default_provider_profile: string,
	bootstrap_defaults: string,
	suggested_model_tier: string,
	memory_templates: [AGENT_TEMPLATE_MAX_MEMORY_TEMPLATES]string,
	memory_template_count: int,
	author: string,
	created_unix_ms: i64,
}

agent_template_records: [AGENT_TEMPLATE_MAX_RECORDS]Agent_Template_Record
agent_template_record_count: int
agent_template_events: [AGENT_MAX_EVENTS]Agent_Template_Event
agent_template_event_count: int
agent_template_events_path: string

agent_template_store_init :: proc(data_dir: string) {
	agent_template_record_count = 0
	agent_template_event_count = 0
	if !agent_template_db_init(data_dir) {
		fmt.println("WARNING: agent_template_db_init failed, templates will not persist across restarts")
		return
	}
	_ = agent_template_db_load_all()
}

agent_template_append_event :: proc(event: Agent_Template_Event) -> bool {
	ev := agent_template_event_clone(event)
	if ev.event_id == "" do ev.event_id = strings.clone(fmt.tprintf("agent_template_evt_%d", router_now_unix_ms()))
	if ev.created_unix_ms == 0 do ev.created_unix_ms = router_now_unix_ms()
	
	if !agent_template_apply_event(ev) do return false
	
	idx := agent_template_index(ev.template_id)
	if idx >= 0 {
		return agent_template_db_save(agent_template_records[idx])
	}
	return false
}

agent_template_apply_event :: proc(event: Agent_Template_Event) -> bool {
	if agent_template_event_count < AGENT_MAX_EVENTS { agent_template_events[agent_template_event_count] = agent_template_event_clone(event); agent_template_event_count += 1 }
	idx := agent_template_index(event.template_id)
	if idx < 0 {
		if agent_template_record_count >= AGENT_TEMPLATE_MAX_RECORDS do return false
		idx = agent_template_record_count; agent_template_record_count += 1
		agent_template_records[idx].template_id = strings.clone(event.template_id)
		agent_template_records[idx].created_unix_ms = event.created_unix_ms
	}
	rec := &agent_template_records[idx]
	if event.kind == .Agent_Template_Archived {
		rec.archived_at_unix_ms = event.created_unix_ms
		rec.updated_unix_ms = event.created_unix_ms
		return true
	}
	rec.template_id = strings.clone(event.template_id)
	rec.display_name = strings.clone(event.display_name)
	rec.description = strings.clone(event.description)
	rec.persona = strings.clone(event.persona)
	rec.instructions = strings.clone(event.instructions)
	rec.role_hint = strings.clone(event.role_hint)
	rec.parent_template_id = strings.clone(event.parent_template_id)
	rec.default_provider_profile = strings.clone(event.default_provider_profile)
	rec.bootstrap_defaults = strings.clone(event.bootstrap_defaults)
	rec.suggested_model_tier = strings.clone(event.suggested_model_tier)
	rec.memory_template_count = event.memory_template_count
	if event.author == "api" {
		rec.is_customized = true
	}
	for i in 0..<event.memory_template_count do rec.memory_templates[i] = strings.clone(event.memory_templates[i])
	if rec.created_unix_ms == 0 do rec.created_unix_ms = event.created_unix_ms
	rec.updated_unix_ms = event.created_unix_ms
	rec.archived_at_unix_ms = 0
	return true
}

agent_template_index :: proc(template_id: string) -> int { for i in 0..<agent_template_record_count { if agent_template_records[i].template_id == template_id do return i }; return -1 }

agent_template_event_clone :: proc(e: Agent_Template_Event) -> Agent_Template_Event {
	out := e
	out.event_id = strings.clone(e.event_id); out.template_id = strings.clone(e.template_id); out.display_name = strings.clone(e.display_name); out.description = strings.clone(e.description); out.persona = strings.clone(e.persona); out.instructions = strings.clone(e.instructions); out.role_hint = strings.clone(e.role_hint); out.parent_template_id = strings.clone(e.parent_template_id); out.default_provider_profile = strings.clone(e.default_provider_profile); out.bootstrap_defaults = strings.clone(e.bootstrap_defaults); out.suggested_model_tier = strings.clone(e.suggested_model_tier); out.author = strings.clone(e.author)
	for i in 0..<e.memory_template_count do out.memory_templates[i] = strings.clone(e.memory_templates[i])
	return out
}

agent_template_event_json :: proc(event: Agent_Template_Event) -> string {
	b := strings.builder_make(); strings.write_string(&b, `{"event_id":"`); json_write_string(&b, event.event_id); strings.write_string(&b, `","kind":"`); json_write_string(&b, fmt.tprintf("%v", event.kind)); strings.write_string(&b, `","template_id":"`); json_write_string(&b, event.template_id); strings.write_string(&b, `","display_name":"`); json_write_string(&b, event.display_name); strings.write_string(&b, `","description":"`); json_write_string(&b, event.description); strings.write_string(&b, `","persona":"`); json_write_string(&b, event.persona); strings.write_string(&b, `","instructions":"`); json_write_string(&b, event.instructions); strings.write_string(&b, `","role_hint":"`); json_write_string(&b, event.role_hint); strings.write_string(&b, `","parent_template_id":"`); json_write_string(&b, event.parent_template_id); strings.write_string(&b, `","default_provider_profile":"`); json_write_string(&b, event.default_provider_profile); strings.write_string(&b, `","bootstrap_defaults":"`); json_write_string(&b, event.bootstrap_defaults); strings.write_string(&b, `","suggested_model_tier":"`); json_write_string(&b, event.suggested_model_tier); strings.write_string(&b, `","author":"`); json_write_string(&b, event.author); strings.write_string(&b, `","created_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", event.created_unix_ms)); strings.write_string(&b, `,"memory_templates":[`)
	for i in 0..<event.memory_template_count { if i > 0 do strings.write_string(&b, `,`); strings.write_string(&b, `"`); json_write_string(&b, event.memory_templates[i]); strings.write_string(&b, `"`) }
	strings.write_string(&b, `]}`); return strings.to_string(b)
}

agent_template_event_from_json :: proc(line: string) -> (Agent_Template_Event, bool) {
	kind := Agent_Template_Event_Kind.Agent_Template_Upserted
	if extract_json_string(line, "kind", "") == "Agent_Template_Archived" do kind = .Agent_Template_Archived
	ev := Agent_Template_Event{event_id = extract_json_string(line, "event_id", ""), kind = kind, template_id = extract_json_string(line, "template_id", ""), display_name = extract_json_string(line, "display_name", ""), description = extract_json_string(line, "description", ""), persona = extract_json_string(line, "persona", ""), instructions = extract_json_string(line, "instructions", ""), role_hint = extract_json_string(line, "role_hint", ""), parent_template_id = extract_json_string(line, "parent_template_id", ""), default_provider_profile = extract_json_string(line, "default_provider_profile", ""), bootstrap_defaults = extract_json_string(line, "bootstrap_defaults", ""), suggested_model_tier = extract_json_string(line, "suggested_model_tier", "normal"), author = extract_json_string(line, "author", ""), created_unix_ms = i64(extract_json_int(line, "created_unix_ms", 0))}
	agent_parse_string_array_field(line, "memory_templates", &ev.memory_templates, &ev.memory_template_count)
	return ev, ev.template_id != ""
}

agent_parse_string_array_field :: proc(body, key: string, out: ^[AGENT_TEMPLATE_MAX_MEMORY_TEMPLATES]string, count: ^int) {
	count^ = 0
	start := json_value_start(body, key)
	if start < 0 || start >= len(body) || body[start] != '[' do return
	idx := start + 1
	for idx < len(body) && count^ < AGENT_TEMPLATE_MAX_MEMORY_TEMPLATES {
		for idx < len(body) && (body[idx] == ' ' || body[idx] == '\t' || body[idx] == '\n' || body[idx] == '\r' || body[idx] == ',') do idx += 1
		if idx >= len(body) || body[idx] == ']' do break
		if body[idx] != '"' {
			end := strings.index_byte(body[idx:], ',')
			if end < 0 do break
			idx += end + 1
			continue
		}
		idx += 1
		value_start := idx
		escaped := false
		for idx < len(body) {
			ch := body[idx]
			if escaped {
				escaped = false
			} else if ch == '\\' {
				escaped = true
			} else if ch == '"' {
				out[count^] = strings.clone(json_unescape(body[value_start:idx]))
				count^ += 1
				idx += 1
				break
			}
			idx += 1
		}
	}
}

parse_json_array_string :: proc(value: string) -> string {
	v := strings.trim_space(value)
	if len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"' do return v[1:len(v)-1]
	return v
}

agent_store_update_work_state :: proc(agent_instance_id, current_task_id: string, set_current: bool, touch_needed: bool) -> bool {
	idx := agent_record_index_by_instance(agent_instance_id)
	if idx < 0 do return false
	rec := agent_instance_records[idx]
	now := router_now_unix_ms()
	event := Agent_Instance_Event{kind=.Agent_Instance_Upserted, agent_record_id=rec.agent_record_id, agent_instance_id=rec.agent_instance_id, display_name=rec.display_name, template_id=rec.template_id, provider_profile=rec.provider_profile, project_id=rec.project_id, run_dir=rec.run_dir, model_tier=rec.model_tier, current_task_id=rec.current_task_id, current_task_since=rec.current_task_since, last_needed_at_unix_ms=rec.last_needed_at_unix_ms, author="autoscaler"}
	if set_current {
		event.current_task_id = current_task_id
		event.current_task_since = now
	}
	if current_task_id == "" && set_current {
		event.current_task_since = -1
	}
	if touch_needed do event.last_needed_at_unix_ms = now
	ok := agent_store_append_event(event)
	if ok {
		if updated_idx := agent_record_index_by_instance(agent_instance_id); updated_idx >= 0 do agent_store_emit_agent_update(agent_instance_records[updated_idx])
	}
	return ok
}

agent_store_touch_needed :: proc(agent_instance_id: string) -> bool { return agent_store_update_work_state(agent_instance_id, "", false, true) }
agent_store_set_current_task :: proc(agent_instance_id, task_id: string) -> bool { return agent_store_update_work_state(agent_instance_id, task_id, true, true) }
agent_store_clear_current_task :: proc(agent_instance_id: string) -> bool { return agent_store_update_work_state(agent_instance_id, "", true, true) }
agent_store_clear_current_task_if_matches :: proc(agent_instance_id, task_id: string) -> bool {
	idx := agent_record_index_by_instance(agent_instance_id)
	if idx < 0 do return false
	if agent_instance_records[idx].current_task_id != task_id do return false
	return agent_store_update_work_state(agent_instance_id, "", true, true)
}

agent_store_emit_agent_update :: proc(rec: Agent_Instance_Record) {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"agent_update","agent_instance_id":"`); json_write_string(&b, rec.agent_instance_id)
	strings.write_string(&b, `","agent_record_id":"`); json_write_string(&b, rec.agent_record_id)
	strings.write_string(&b, `","display_name":"`); json_write_string(&b, rec.display_name)
	strings.write_string(&b, `","current_task_id":"`); json_write_string(&b, rec.current_task_id)
	strings.write_string(&b, `","current_task_since":`); strings.write_string(&b, fmt.tprintf("%d", rec.current_task_since))
	strings.write_string(&b, `,"state":"`); json_write_string(&b, agent_store_agent_state(rec))
	strings.write_string(&b, `"}`)
	user_client_fanout_all_ws_text(strings.to_string(b))
}

agent_store_agent_state :: proc(rec: Agent_Instance_Record) -> string {
	return agent_runtime_tracker_agent_state(rec.agent_instance_id, rec.current_task_id != "")
}
