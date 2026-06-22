package main

import "core:fmt"
import "core:os"
import "core:strings"

TASK_MAX_EVENTS      :: 20000
TASK_MAX_TASKS       :: 2048
TASK_MAX_CHAINS      :: 512
TASK_MAX_PARTICIPANTS :: 4096
TASK_MAX_COMMENTS    :: 8192
TASK_MAX_VOTES       :: 2048

// Task statuses: planning → ready → in_progress → review_ready → approved
// blocked and cancelled are reachable from most states.
// All transitions except planning→ready and review_ready→approved are manual.
// planning→ready is automatic (deps satisfied + chain active).
// review_ready→approved is automatic (all lgtm_required have voted approved).
// ready→in_progress is automatic (assignee has no other active task).

Task_Event_Kind :: enum {
	Task_Created,
	Task_Comment,
	Task_Comment_Resolved,
	Task_Status_Changed,
	Task_Assigned,
	Task_Participant_Added,
	Task_Review_Vote,
	Task_Nudged,
	Task_Nudge_Failed,
	Chain_Created,
	Chain_Metadata_Updated,
	Chain_Status_Changed,
	Chain_Final_Summary_Set,
	Chain_Completed,
	Chain_Archive_Pending,
	Chain_Archived,
}

Task_Event :: struct {
	event_id:                   string,
	kind:                       Task_Event_Kind,
	task_id:                    string,
	chain_id:                   string,
	title:                      string,
	description:                string,
	acceptance_criteria:        string,
	priority:                   string,
	status:                     string,
	body:                       string,
	comment_id:                 string,
	vote_approved:              string, // "true" or "false" for Task_Review_Vote
	project_id:                 string,
	agent_instance_id:          string,
	assignee_agent_instance_id: string,
	coordinator_agent_instance_id: string,
	depends_on:                 string,
	role:                       string,
	created_by:                 string,
	author_agent_instance_id:   string,
	created_unix_ms:            i64,
}

Task_State :: struct {
	task_id:                    string,
	chain_id:                   string,
	title:                      string,
	description:                string,
	acceptance_criteria:        string,
	priority:                   string,
	status:                     string,
	assignee_agent_instance_id: string,
	coordinator_agent_instance_id: string,
	depends_on:                 string,
	created_by:                 string,
	created_at_unix_ms:         i64,
	updated_at_unix_ms:         i64,
}

Task_Participant :: struct {
	task_id:            string,
	chain_id:           string,
	agent_instance_id:  string,
	role:               string,
}

Task_Comment_State :: struct {
	comment_id:               string,
	task_id:                  string,
	chain_id:                 string,
	body:                     string,
	author_agent_instance_id: string,
	resolved:                 bool,
	created_unix_ms:          i64,
}

Task_LGTM_Vote_State :: struct {
	task_id:                    string,
	chain_id:                   string,
	reviewer_agent_instance_id: string,
	approved:                   bool,
	role:                       string, // "lgtm_required" or "lgtm_optional"
	comment:                    string,
	created_unix_ms:            i64,
}

Task_Chain_State :: struct {
	chain_id:                      string,
	project_id:                    string,
	title:                         string,
	description:                   string,
	status:                        string,
	coordinator_agent_instance_id: string,
	final_summary:                 string,
	created_at_unix_ms:            i64,
	completed_at_unix_ms:          i64,
	archive_pending:               bool,
	archived:                      bool,
}

task_events:            [TASK_MAX_EVENTS]Task_Event
task_event_count:       int
task_states:            [TASK_MAX_TASKS]Task_State
task_state_count:       int
task_participants:      [TASK_MAX_PARTICIPANTS]Task_Participant
task_participant_count: int
task_chains:            [TASK_MAX_CHAINS]Task_Chain_State
task_chain_count:       int
task_comments:          [TASK_MAX_COMMENTS]Task_Comment_State
task_comment_count:     int
task_lgtm_votes:        [TASK_MAX_VOTES]Task_LGTM_Vote_State
task_lgtm_vote_count:   int
task_store_dir:         string
task_events_path:       string

task_store_init :: proc(data_dir: string) {
	task_event_count = 0
	task_projection_reset()
	task_store_dir   = strings.clone(fmt.tprintf("%s/tasks", data_dir))
	task_events_path = strings.clone(fmt.tprintf("%s/events.jsonl", task_store_dir))
	_ = os.make_directory_all(task_store_dir)

	// 1. Initialize the SQLite task database
	if !task_db_init(data_dir) {
		fmt.println("WARNING: task_db_init failed, task events will not persist across restarts")
		return
	}

	// 2. Check and migrate legacy events.jsonl
	if os.exists(task_events_path) {
		fmt.println("MIGRATION: Found legacy events.jsonl at", task_events_path)
		
		task_store_replay_jsonl()
		
		if task_event_count > 0 {
			fmt.printf("MIGRATION: Migrating %d task events to SQLite...\n", task_event_count)
			_ = task_db_execute("BEGIN TRANSACTION;")
			migrated_ok := true
			for i in 0..<task_event_count {
				if !task_db_insert_event(task_events[i]) {
					migrated_ok = false
					break
				}
			}
			if migrated_ok {
				_ = task_db_execute("COMMIT;")
				fmt.println("MIGRATION: Successfully migrated all task events to SQLite!")
				
				migrated_path := fmt.tprintf("%s/events.jsonl.migrated", task_store_dir)
				err := os.rename(task_events_path, migrated_path)
				if err != 0 {
					fmt.println("WARNING: Failed to rename legacy events.jsonl to events.jsonl.migrated, error code:", err)
				}
			} else {
				_ = task_db_execute("ROLLBACK;")
				fmt.println("ERROR: Task event migration failed! Legacy events.jsonl kept.")
			}
		} else {
			_ = os.remove(task_events_path)
		}
		
		// Reset memory projection to prepare for clean SQLite replay
		task_event_count = 0
		task_projection_reset()
	}

	// 3. Replay all events from SQLite
	if !task_db_replay_all() {
		fmt.println("ERROR: Failed to replay task events from SQLite")
	}
}

task_store_append_event :: proc(event: Task_Event) -> bool {
	ev := event
	if ev.event_id == "" do ev.event_id = strings.clone(fmt.tprintf("taskevt_%d", router_now_unix_ms()))
	if ev.created_unix_ms == 0 do ev.created_unix_ms = router_now_unix_ms()
	if !task_store_apply_event(ev) do return false
	// Write to SQLite task database
	return task_db_insert_event(ev)
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
		event_id                    = strings.clone(event.event_id),
		kind                        = event.kind,
		task_id                     = strings.clone(event.task_id),
		chain_id                    = strings.clone(event.chain_id),
		title                       = strings.clone(event.title),
		description                 = strings.clone(event.description),
		acceptance_criteria         = strings.clone(event.acceptance_criteria),
		priority                    = strings.clone(event.priority),
		status                      = strings.clone(event.status),
		body                        = strings.clone(event.body),
		comment_id                  = strings.clone(event.comment_id),
		vote_approved               = strings.clone(event.vote_approved),
		project_id                  = strings.clone(event.project_id),
		agent_instance_id           = strings.clone(event.agent_instance_id),
		assignee_agent_instance_id  = strings.clone(event.assignee_agent_instance_id),
		coordinator_agent_instance_id = strings.clone(event.coordinator_agent_instance_id),
		depends_on                  = strings.clone(event.depends_on),
		role                        = strings.clone(event.role),
		created_by                  = strings.clone(event.created_by),
		author_agent_instance_id    = strings.clone(event.author_agent_instance_id),
		created_unix_ms             = event.created_unix_ms,
	}
}

task_store_replay :: proc() {
	_ = task_db_replay_all()
}

task_store_replay_jsonl :: proc() {
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
	b := strings.builder_make()
	strings.write_string(&b, `{"event_id":"`);         json_write_string(&b, event.event_id)
	strings.write_string(&b, `","kind":"`);             json_write_string(&b, fmt.tprintf("%v", event.kind))
	strings.write_string(&b, `","task_id":"`);          json_write_string(&b, event.task_id)
	strings.write_string(&b, `","chain_id":"`);         json_write_string(&b, event.chain_id)
	strings.write_string(&b, `","title":"`);            json_write_string(&b, event.title)
	strings.write_string(&b, `","description":"`);      json_write_string(&b, event.description)
	strings.write_string(&b, `","acceptance_criteria":"`); json_write_string(&b, event.acceptance_criteria)
	strings.write_string(&b, `","priority":"`);         json_write_string(&b, event.priority)
	strings.write_string(&b, `","status":"`);           json_write_string(&b, event.status)
	strings.write_string(&b, `","body":"`);             json_write_string(&b, event.body)
	strings.write_string(&b, `","comment_id":"`);       json_write_string(&b, event.comment_id)
	strings.write_string(&b, `","vote_approved":"`);    json_write_string(&b, event.vote_approved)
	strings.write_string(&b, `","project_id":"`);       json_write_string(&b, event.project_id)
	strings.write_string(&b, `","agent_instance_id":"`); json_write_string(&b, event.agent_instance_id)
	strings.write_string(&b, `","assignee_agent_instance_id":"`); json_write_string(&b, event.assignee_agent_instance_id)
	strings.write_string(&b, `","coordinator_agent_instance_id":"`); json_write_string(&b, event.coordinator_agent_instance_id)
	strings.write_string(&b, `","depends_on":"`);       json_write_string(&b, event.depends_on)
	strings.write_string(&b, `","role":"`);             json_write_string(&b, event.role)
	strings.write_string(&b, `","created_by":"`);       json_write_string(&b, event.created_by)
	strings.write_string(&b, `","author_agent_instance_id":"`); json_write_string(&b, event.author_agent_instance_id)
	strings.write_string(&b, `","created_unix_ms":`);   strings.write_string(&b, fmt.tprintf("%d", event.created_unix_ms))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

task_event_from_json :: proc(line: string) -> (Task_Event, bool) {
	kind_text := extract_json_string(line, "kind", "")
	event := Task_Event{
		event_id                    = extract_json_string(line, "event_id", ""),
		kind                        = task_event_kind_from_string(kind_text),
		task_id                     = extract_json_string(line, "task_id", ""),
		chain_id                    = extract_json_string(line, "chain_id", ""),
		title                       = extract_json_string(line, "title", ""),
		description                 = extract_json_string(line, "description", ""),
		acceptance_criteria         = extract_json_string(line, "acceptance_criteria", ""),
		priority                    = extract_json_string(line, "priority", ""),
		status                      = extract_json_string(line, "status", ""),
		body                        = extract_json_string(line, "body", ""),
		comment_id                  = extract_json_string(line, "comment_id", ""),
		vote_approved               = extract_json_string(line, "vote_approved", ""),
		project_id                  = extract_json_string(line, "project_id", ""),
		agent_instance_id           = extract_json_string(line, "agent_instance_id", ""),
		assignee_agent_instance_id  = extract_json_string(line, "assignee_agent_instance_id", ""),
		coordinator_agent_instance_id = extract_json_string(line, "coordinator_agent_instance_id", ""),
		depends_on                  = extract_json_string(line, "depends_on", ""),
		role                        = extract_json_string(line, "role", ""),
		created_by                  = extract_json_string(line, "created_by", ""),
		author_agent_instance_id    = extract_json_string(line, "author_agent_instance_id", ""),
		created_unix_ms             = i64(extract_json_int(line, "created_unix_ms", 0)),
	}
	return event, kind_text != ""
}

task_event_kind_from_string :: proc(value: string) -> Task_Event_Kind {
	switch value {
	case "Task_Created":          return .Task_Created
	case "Task_Comment":          return .Task_Comment
	case "Task_Comment_Resolved": return .Task_Comment_Resolved
	case "Task_Status_Changed":   return .Task_Status_Changed
	case "Task_Assigned":         return .Task_Assigned
	case "Task_Participant_Added": return .Task_Participant_Added
	case "Task_Review_Vote":      return .Task_Review_Vote
	case "Task_Nudged":           return .Task_Nudged
	case "Task_Nudge_Failed":     return .Task_Nudge_Failed
	case "Chain_Created":         return .Chain_Created
	case "Chain_Metadata_Updated": return .Chain_Metadata_Updated
	case "Chain_Status_Changed":  return .Chain_Status_Changed
	case "Chain_Final_Summary_Set": return .Chain_Final_Summary_Set
	case "Chain_Completed":       return .Chain_Completed
	case "Chain_Archive_Pending": return .Chain_Archive_Pending
	case "Chain_Archived":        return .Chain_Archived
	case:                         return .Task_Comment
	}
}
