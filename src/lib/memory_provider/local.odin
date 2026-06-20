package memory_provider

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"

MEMORY_MAX_EVENTS :: 20_000
MEMORY_MAX_RECORDS :: 2_000

Local_Memory_State :: struct {
	events: [MEMORY_MAX_EVENTS]contracts.Memory_Event,
	event_count: int,
	records: [MEMORY_MAX_RECORDS]contracts.Memory_Record,
	record_count: int,
	store_dir: string,
	events_path: string,
}

local_capabilities := [?]contracts.Memory_Provider_Capability{.Append_Event, .Replay, .List_Records, .History}
local_memory_state: Local_Memory_State

new_local_provider :: proc(data_dir: string) -> Memory_Provider {
	local_memory_state = Local_Memory_State{}
	local_memory_state.store_dir = strings.clone(fmt.tprintf("%s/memory", data_dir))
	local_memory_state.events_path = strings.clone(fmt.tprintf("%s/events.jsonl", local_memory_state.store_dir))
	_ = os.make_directory_all(local_memory_state.store_dir)
	provider := Memory_Provider{name = "local-memory", capabilities = local_capabilities[:], state = rawptr(&local_memory_state), append_event = local_append_event, replay = local_replay, list_records = local_list_records, history = local_history}
	local_replay(rawptr(&local_memory_state))
	return provider
}

local_append_event :: proc(state: rawptr, event: contracts.Memory_Event) -> contracts.Memory_Append_Response {
	st := transmute(^Local_Memory_State)state
	ev := memory_event_stable(event)
	if ev.event_id == "" do ev.event_id = strings.clone(fmt.tprintf("memory_evt_%d", memory_now_unix_ms()))
	if ev.created_unix_ms == 0 do ev.created_unix_ms = memory_now_unix_ms()
	if ev.memory_id == "" do ev.memory_id = strings.clone(fmt.tprintf("mem_%d", ev.created_unix_ms))
	if ev.proposal_id == "" && ev.kind == .Memory_Proposed do ev.proposal_id = strings.clone(fmt.tprintf("proposal_%d", ev.created_unix_ms))
	if ev.version == 0 do ev.version = 1
	if !local_can_apply_event(st, ev) do return contracts.Memory_Append_Response{ok = false, message = "memory projection full", event_id = ev.event_id, memory_id = ev.memory_id, proposal_id = ev.proposal_id}
	file, err := os.open(st.events_path, os.O_CREATE | os.O_APPEND | os.O_WRONLY)
	if err != nil do return contracts.Memory_Append_Response{ok = false, message = "open memory event log failed", event_id = ev.event_id, memory_id = ev.memory_id, proposal_id = ev.proposal_id}
	defer os.close(file)
	os.write_string(file, memory_event_json(ev))
	os.write_string(file, "\n")
	if !local_apply_event(st, ev) do return contracts.Memory_Append_Response{ok = false, message = "memory projection full after append", event_id = ev.event_id, memory_id = ev.memory_id, proposal_id = ev.proposal_id}
	return contracts.Memory_Append_Response{ok = true, message = "appended", event_id = ev.event_id, memory_id = ev.memory_id, proposal_id = ev.proposal_id}
}

local_replay :: proc(state: rawptr) -> contracts.Memory_Replay_Response {
	st := transmute(^Local_Memory_State)state
	st.event_count = 0
	st.record_count = 0
	data, err := os.read_entire_file(st.events_path, context.allocator)
	if err != nil do return contracts.Memory_Replay_Response{ok = true, message = "no memory event log", event_count = 0, record_count = 0}
	lines := strings.split(string(data), "\n")
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		event, ok := memory_event_from_json(trimmed)
		if ok do local_apply_event(st, event)
	}
	return contracts.Memory_Replay_Response{ok = true, message = "replayed", event_count = st.event_count, record_count = st.record_count}
}

local_can_apply_event :: proc(st: ^Local_Memory_State, event: contracts.Memory_Event) -> bool {
	if st.event_count >= MEMORY_MAX_EVENTS do return false
	if memory_record_index(st, event.memory_id) < 0 && st.record_count >= MEMORY_MAX_RECORDS do return false
	return true
}

local_apply_event :: proc(st: ^Local_Memory_State, event: contracts.Memory_Event) -> bool {
	if !local_can_apply_event(st, event) do return false
	ev := memory_event_stable(event)
	if st.event_count < MEMORY_MAX_EVENTS {
		st.events[st.event_count] = ev
		st.event_count += 1
	}
	idx := memory_record_index(st, ev.memory_id)
	if idx < 0 {
		if st.record_count >= MEMORY_MAX_RECORDS do return false
		idx = st.record_count
		st.record_count += 1
		st.records[idx] = contracts.Memory_Record{memory_id = strings.clone(ev.memory_id), proposal_id = strings.clone(ev.proposal_id), status = .Pending, version = ev.version, created_unix_ms = ev.created_unix_ms}
	}
	rec := &st.records[idx]
	#partial switch ev.kind {
	case .Memory_Proposed:
		rec.proposal_id = strings.clone(ev.proposal_id)
		rec.subject_agent = strings.clone(ev.subject_agent)
		rec.scope = strings.clone(ev.scope)
		rec.type = ev.type
		rec.title = strings.clone(ev.title)
		rec.body = strings.clone(ev.body)
		rec.status = .Pending
		rec.reason = strings.clone(ev.reason)
		rec.evidence = strings.clone(ev.evidence)
		rec.metadata_json = strings.clone(ev.metadata_json)
		rec.source_task_id = strings.clone(ev.source_task_id)
		rec.version = ev.version
		rec.updated_unix_ms = ev.created_unix_ms
	case .Memory_Approved:
		if rec.type == .Expertise do memory_archive_active_expertise(st, rec.subject_agent, rec.scope, rec.memory_id, ev.created_unix_ms)
		rec.status = .Active
		rec.version += 1
		rec.updated_unix_ms = ev.created_unix_ms
	case .Memory_Rejected:
		rec.status = .Rejected
		rec.updated_unix_ms = ev.created_unix_ms
	case .Memory_Archived:
		rec.status = .Archived
		rec.version += 1
		rec.updated_unix_ms = ev.created_unix_ms
	}
	return true
}

memory_archive_active_expertise :: proc(st: ^Local_Memory_State, subject_agent, scope, keep_memory_id: string, at_unix_ms: i64) {
	for i in 0..<st.record_count {
		rec := &st.records[i]
		if rec.memory_id == keep_memory_id do continue
		if rec.type == .Expertise && rec.status == .Active && rec.subject_agent == subject_agent && rec.scope == scope {
			rec.status = .Archived
			rec.version += 1
			rec.updated_unix_ms = at_unix_ms
		}
	}
}

local_list_records :: proc(state: rawptr, request: contracts.Memory_List_Request) -> contracts.Memory_List_Response {
	st := transmute(^Local_Memory_State)state
	result := make([dynamic]contracts.Memory_Record, 0, st.record_count)
	for i in 0..<st.record_count {
		rec := st.records[i]
		if request.subject_agent != "" && rec.subject_agent != request.subject_agent do continue
		if request.scope != "" && rec.scope != request.scope do continue
		if !request.include_all_statuses && rec.status != request.status do continue
		append(&result, rec)
	}
	return contracts.Memory_List_Response{ok = true, message = "listed", records = result[:]}
}

local_history :: proc(state: rawptr, request: contracts.Memory_History_Request) -> contracts.Memory_History_Response {
	st := transmute(^Local_Memory_State)state
	result := make([dynamic]contracts.Memory_Event, 0, st.event_count)
	for i in 0..<st.event_count {
		if st.events[i].memory_id == request.memory_id do append(&result, st.events[i])
	}
	return contracts.Memory_History_Response{ok = true, message = "history", events = result[:]}
}

memory_record_index :: proc(st: ^Local_Memory_State, memory_id: string) -> int {
	for i in 0..<st.record_count {
		if st.records[i].memory_id == memory_id do return i
	}
	return -1
}

memory_event_stable :: proc(event: contracts.Memory_Event) -> contracts.Memory_Event {
	return contracts.Memory_Event{event_id = strings.clone(event.event_id), kind = event.kind, memory_id = strings.clone(event.memory_id), proposal_id = strings.clone(event.proposal_id), subject_agent = strings.clone(event.subject_agent), scope = strings.clone(event.scope), type = event.type, title = strings.clone(event.title), body = strings.clone(event.body), status = event.status, reason = strings.clone(event.reason), evidence = strings.clone(event.evidence), metadata_json = strings.clone(event.metadata_json), author = strings.clone(event.author), source_task_id = strings.clone(event.source_task_id), version = event.version, created_unix_ms = event.created_unix_ms}
}

memory_event_json :: proc(event: contracts.Memory_Event) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"event_id":"`); memory_json_write_string(&b, event.event_id)
	strings.write_string(&b, `","kind":"`); memory_json_write_string(&b, memory_event_kind_string(event.kind))
	strings.write_string(&b, `","memory_id":"`); memory_json_write_string(&b, event.memory_id)
	strings.write_string(&b, `","proposal_id":"`); memory_json_write_string(&b, event.proposal_id)
	strings.write_string(&b, `","subject_agent":"`); memory_json_write_string(&b, event.subject_agent)
	strings.write_string(&b, `","scope":"`); memory_json_write_string(&b, event.scope)
	strings.write_string(&b, `","type":"`); memory_json_write_string(&b, memory_type_string(event.type))
	strings.write_string(&b, `","title":"`); memory_json_write_string(&b, event.title)
	strings.write_string(&b, `","body":"`); memory_json_write_string(&b, event.body)
	strings.write_string(&b, `","status":"`); memory_json_write_string(&b, memory_status_string(event.status))
	strings.write_string(&b, `","reason":"`); memory_json_write_string(&b, event.reason)
	strings.write_string(&b, `","evidence":"`); memory_json_write_string(&b, event.evidence)
	strings.write_string(&b, `","metadata_json":"`); memory_json_write_string(&b, event.metadata_json)
	strings.write_string(&b, `","author":"`); memory_json_write_string(&b, event.author)
	strings.write_string(&b, `","source_task_id":"`); memory_json_write_string(&b, event.source_task_id)
	strings.write_string(&b, `","version":`); strings.write_string(&b, fmt.tprintf("%d", event.version))
	strings.write_string(&b, `,"created_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", event.created_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

memory_event_from_json :: proc(line: string) -> (contracts.Memory_Event, bool) {
	kind := memory_event_kind_from_string(memory_extract_json_string(line, "kind", ""))
	ev := contracts.Memory_Event{event_id = memory_extract_json_string(line, "event_id", ""), kind = kind, memory_id = memory_extract_json_string(line, "memory_id", ""), proposal_id = memory_extract_json_string(line, "proposal_id", ""), subject_agent = memory_extract_json_string(line, "subject_agent", ""), scope = memory_extract_json_string(line, "scope", ""), type = memory_type_from_string(memory_extract_json_string(line, "type", "")), title = memory_extract_json_string(line, "title", ""), body = memory_extract_json_string(line, "body", ""), status = memory_status_from_string(memory_extract_json_string(line, "status", "")), reason = memory_extract_json_string(line, "reason", ""), evidence = memory_extract_json_string(line, "evidence", ""), metadata_json = memory_extract_json_string(line, "metadata_json", ""), author = memory_extract_json_string(line, "author", ""), source_task_id = memory_extract_json_string(line, "source_task_id", ""), version = memory_extract_json_int(line, "version", 1), created_unix_ms = i64(memory_extract_json_int(line, "created_unix_ms", 0))}
	return ev, ev.event_id != ""
}

memory_event_kind_string :: proc(kind: contracts.Memory_Event_Kind) -> string { switch kind { case .Memory_Proposed: return "Memory_Proposed"; case .Memory_Approved: return "Memory_Approved"; case .Memory_Rejected: return "Memory_Rejected"; case .Memory_Archived: return "Memory_Archived" } return "Memory_Proposed" }
memory_event_kind_from_string :: proc(value: string) -> contracts.Memory_Event_Kind { switch value { case "Memory_Approved": return .Memory_Approved; case "Memory_Rejected": return .Memory_Rejected; case "Memory_Archived": return .Memory_Archived; case: return .Memory_Proposed } }
memory_type_string :: proc(kind: contracts.Memory_Type) -> string { switch kind { case .Fact: return "fact"; case .Habit: return "habit"; case .Episode: return "episode"; case .Expertise: return "expertise"; case .Skill: return "skill"; case .Template: return "template" } return "fact" }
memory_type_from_string :: proc(value: string) -> contracts.Memory_Type { switch value { case "habit": return .Habit; case "episode": return .Episode; case "expertise": return .Expertise; case "skill": return .Skill; case "template": return .Template; case: return .Fact } }
memory_status_string :: proc(status: contracts.Memory_Status) -> string { switch status { case .Pending: return "pending"; case .Active: return "active"; case .Archived: return "archived"; case .Rejected: return "rejected" } return "pending" }
memory_status_from_string :: proc(value: string) -> contracts.Memory_Status { switch value { case "active": return .Active; case "archived": return .Archived; case "rejected": return .Rejected; case: return .Pending } }

memory_extract_json_string :: proc(body, key, default_value: string) -> string {
	needle := fmt.tprintf("\"%s\":\"", key)
	idx := strings.index(body, needle)
	if idx < 0 do return default_value
	start := idx + len(needle)
	out := strings.builder_make()
	escaped := false
	for i := start; i < len(body); i += 1 {
		ch := body[i]
		if escaped { strings.write_byte(&out, ch); escaped = false; continue }
		if ch == '\\' { escaped = true; continue }
		if ch == '"' do return strings.to_string(out)
		strings.write_byte(&out, ch)
	}
	return default_value
}

memory_extract_json_int :: proc(body, key: string, default_value: int) -> int {
	needle := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, needle)
	if idx < 0 do return default_value
	start := idx + len(needle)
	value := 0
	found := false
	for i := start; i < len(body); i += 1 {
		ch := body[i]
		if ch < '0' || ch > '9' do break
		found = true
		value = value * 10 + int(ch - '0')
	}
	if !found do return default_value
	return value
}

memory_json_write_string :: proc(builder: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '"': strings.write_string(builder, `\"`)
		case '\\': strings.write_string(builder, `\\`)
		case '\n': strings.write_string(builder, `\n`)
		case '\r': strings.write_string(builder, `\r`)
		case '\t': strings.write_string(builder, `\t`)
		case: strings.write_rune(builder, ch)
		}
	}
}

memory_now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}
