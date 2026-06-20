package main

import "core:fmt"
import "core:os"
import "core:strings"

TASK_MAX_EVENTS :: 20000
TASK_MAX_TASKS :: 2048
TASK_MAX_CHAINS :: 512
TASK_MAX_PARTICIPANTS :: 4096

Task_Status :: enum { Pending, Ready, Claimed, In_Progress, Blocked, Needs_Review, Needs_Improvements, Approved, Rejected, Done, Cancelled, Open, Working, Archived }
Task_Event_Kind :: enum { Task_Created, Task_Comment, Task_Status_Changed, Task_Assigned, Task_Participant_Added, Task_Review_Submitted, Task_Nudged, Task_Nudge_Failed, Chain_Created, Chain_Metadata_Updated, Chain_Status_Changed, Chain_Final_Summary_Set, Chain_Completed, Chain_Archive_Pending, Chain_Archived }

Task_Event :: struct {
	event_id: string,
	kind: Task_Event_Kind,
	task_id: string,
	chain_id: string,
	title: string,
	description: string,
	acceptance_criteria: string,
	priority: string,
	status: string,
	body: string,
	agent_instance_id: string,
	assignee_agent_instance_id: string,
	reviewer_agent_instance_id: string,
	coordinator_agent_instance_id: string,
	default_reviewer_agent_instance_id: string,
	depends_on: string,
	role: string,
	created_by: string,
	author_agent_instance_id: string,
	created_unix_ms: i64,
}

Task_State :: struct {
	task_id: string,
	chain_id: string,
	title: string,
	description: string,
	acceptance_criteria: string,
	priority: string,
	status: string,
	assignee_agent_instance_id: string,
	reviewer_agent_instance_id: string,
	coordinator_agent_instance_id: string,
	depends_on: string,
	created_by: string,
	created_at_unix_ms: i64,
	updated_at_unix_ms: i64,
	last_comment: string,
	assigned_agent_instance_id: string,
}

Task_Participant :: struct {
	task_id: string,
	chain_id: string,
	agent_instance_id: string,
	role: string,
}

Task_Chain_State :: struct {
	chain_id: string,
	title: string,
	description: string,
	status: string,
	coordinator_agent_instance_id: string,
	default_reviewer_agent_instance_id: string,
	final_summary: string,
	created_at_unix_ms: i64,
	completed_at_unix_ms: i64,
	archive_pending: bool,
	archived: bool,
}

task_events: [TASK_MAX_EVENTS]Task_Event
task_event_count: int
task_states: [TASK_MAX_TASKS]Task_State
task_state_count: int
task_participants: [TASK_MAX_PARTICIPANTS]Task_Participant
task_participant_count: int
task_chains: [TASK_MAX_CHAINS]Task_Chain_State
task_chain_count: int
task_store_dir: string
task_events_path: string

task_store_init :: proc(data_dir: string) {
	task_event_count = 0
	task_projection_reset()
	task_store_dir = strings.clone(fmt.tprintf("%s/tasks", data_dir))
	task_events_path = strings.clone(fmt.tprintf("%s/events.jsonl", task_store_dir))
	_ = os.make_directory_all(task_store_dir)
	task_store_replay()
}

task_store_append_event :: proc(event: Task_Event) -> bool {
	ev := event
	if ev.event_id == "" do ev.event_id = strings.clone(fmt.tprintf("taskevt_%d", router_now_unix_ms()))
	if ev.created_unix_ms == 0 do ev.created_unix_ms = router_now_unix_ms()
	if !task_store_apply_event(ev) do return false
	file, err := os.open(task_events_path, os.O_CREATE | os.O_APPEND | os.O_WRONLY)
	if err != nil do return false
	defer os.close(file)
	os.write_string(file, task_event_json(ev))
	os.write_string(file, "\n")
	return true
}

task_store_apply_event :: proc(event: Task_Event) -> bool {
	stable := task_event_clone(event)
	if task_event_count < TASK_MAX_EVENTS {
		task_events[task_event_count] = stable
		task_event_count += 1
	}
	return task_projection_apply_event(stable)
}

task_event_clone :: proc(event: Task_Event) -> Task_Event {
	return Task_Event{
		event_id = strings.clone(event.event_id),
		kind = event.kind,
		task_id = strings.clone(event.task_id),
		chain_id = strings.clone(event.chain_id),
		title = strings.clone(event.title),
		description = strings.clone(event.description),
		acceptance_criteria = strings.clone(event.acceptance_criteria),
		priority = strings.clone(event.priority),
		status = strings.clone(event.status),
		body = strings.clone(event.body),
		agent_instance_id = strings.clone(event.agent_instance_id),
		assignee_agent_instance_id = strings.clone(event.assignee_agent_instance_id),
		reviewer_agent_instance_id = strings.clone(event.reviewer_agent_instance_id),
		coordinator_agent_instance_id = strings.clone(event.coordinator_agent_instance_id),
		default_reviewer_agent_instance_id = strings.clone(event.default_reviewer_agent_instance_id),
		depends_on = strings.clone(event.depends_on),
		role = strings.clone(event.role),
		created_by = strings.clone(event.created_by),
		author_agent_instance_id = strings.clone(event.author_agent_instance_id),
		created_unix_ms = event.created_unix_ms,
	}
}

task_store_replay :: proc() {
	data, err := os.read_entire_file(task_events_path, context.allocator)
	if err != nil do return
	lines := strings.split(string(data), "\n")
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		event, ok := task_event_from_json(trimmed)
		if ok do task_store_apply_event(event)
	}
}

task_event_json :: proc(event: Task_Event) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"event_id":"`); json_write_string(&builder, event.event_id)
	strings.write_string(&builder, `","kind":"`); json_write_string(&builder, fmt.tprintf("%v", event.kind))
	strings.write_string(&builder, `","task_id":"`); json_write_string(&builder, event.task_id)
	strings.write_string(&builder, `","chain_id":"`); json_write_string(&builder, event.chain_id)
	strings.write_string(&builder, `","title":"`); json_write_string(&builder, event.title)
	strings.write_string(&builder, `","description":"`); json_write_string(&builder, event.description)
	strings.write_string(&builder, `","acceptance_criteria":"`); json_write_string(&builder, event.acceptance_criteria)
	strings.write_string(&builder, `","priority":"`); json_write_string(&builder, event.priority)
	strings.write_string(&builder, `","status":"`); json_write_string(&builder, event.status)
	strings.write_string(&builder, `","body":"`); json_write_string(&builder, event.body)
	strings.write_string(&builder, `","agent_instance_id":"`); json_write_string(&builder, event.agent_instance_id)
	strings.write_string(&builder, `","assignee_agent_instance_id":"`); json_write_string(&builder, event.assignee_agent_instance_id)
	strings.write_string(&builder, `","reviewer_agent_instance_id":"`); json_write_string(&builder, event.reviewer_agent_instance_id)
	strings.write_string(&builder, `","coordinator_agent_instance_id":"`); json_write_string(&builder, event.coordinator_agent_instance_id)
	strings.write_string(&builder, `","default_reviewer_agent_instance_id":"`); json_write_string(&builder, event.default_reviewer_agent_instance_id)
	strings.write_string(&builder, `","depends_on":"`); json_write_string(&builder, event.depends_on)
	strings.write_string(&builder, `","role":"`); json_write_string(&builder, event.role)
	strings.write_string(&builder, `","created_by":"`); json_write_string(&builder, event.created_by)
	strings.write_string(&builder, `","author_agent_instance_id":"`); json_write_string(&builder, event.author_agent_instance_id)
	strings.write_string(&builder, `","created_unix_ms":`); strings.write_string(&builder, fmt.tprintf("%d", event.created_unix_ms)); strings.write_string(&builder, `}`)
	return strings.to_string(builder)
}

task_event_from_json :: proc(line: string) -> (Task_Event, bool) {
	kind_text := extract_json_string(line, "kind", "")
	event := Task_Event{event_id = extract_json_string(line, "event_id", ""), kind = task_event_kind_from_string(kind_text), task_id = extract_json_string(line, "task_id", ""), chain_id = extract_json_string(line, "chain_id", ""), title = extract_json_string(line, "title", ""), description = extract_json_string(line, "description", ""), acceptance_criteria = extract_json_string(line, "acceptance_criteria", ""), priority = extract_json_string(line, "priority", ""), status = extract_json_string(line, "status", ""), body = extract_json_string(line, "body", ""), agent_instance_id = extract_json_string(line, "agent_instance_id", ""), assignee_agent_instance_id = extract_json_string(line, "assignee_agent_instance_id", ""), reviewer_agent_instance_id = extract_json_string(line, "reviewer_agent_instance_id", ""), coordinator_agent_instance_id = extract_json_string(line, "coordinator_agent_instance_id", ""), default_reviewer_agent_instance_id = extract_json_string(line, "default_reviewer_agent_instance_id", ""), depends_on = extract_json_string(line, "depends_on", ""), role = extract_json_string(line, "role", ""), created_by = extract_json_string(line, "created_by", ""), author_agent_instance_id = extract_json_string(line, "author_agent_instance_id", ""), created_unix_ms = i64(extract_json_int(line, "created_unix_ms", 0))}
	return event, kind_text != ""
}

task_event_kind_from_string :: proc(value: string) -> Task_Event_Kind {
	switch value {
	case "Task_Created": return .Task_Created
	case "Task_Status_Changed": return .Task_Status_Changed
	case "Task_Assigned": return .Task_Assigned
	case "Task_Participant_Added": return .Task_Participant_Added
	case "Task_Review_Submitted": return .Task_Review_Submitted
	case "Task_Nudged": return .Task_Nudged
	case "Task_Nudge_Failed": return .Task_Nudge_Failed
	case "Chain_Created": return .Chain_Created
	case "Chain_Metadata_Updated": return .Chain_Metadata_Updated
	case "Chain_Status_Changed": return .Chain_Status_Changed
	case "Chain_Final_Summary_Set": return .Chain_Final_Summary_Set
	case "Chain_Completed": return .Chain_Completed
	case "Chain_Archive_Pending": return .Chain_Archive_Pending
	case "Chain_Archived": return .Chain_Archived
	case: return .Task_Comment
	}
}
