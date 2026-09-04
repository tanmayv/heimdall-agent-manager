package domain

Publish_State :: enum {
	Draft,
	Published,
}

Task_Chain_Status :: enum {
	Active,
	Completed,
	Cancelled,
}

Task_Status :: enum {
	Assigned,
	// Queued marks a published, unblocked task that is eligible to run but is
	// being held back because its assignee instance is currently focused on a
	// higher-priority current task. It is distinct from Assigned (which is the
	// default not-yet-started state) and is set by the auto-promotion engine.
	Queued,
	In_Progress,
	In_Validation,
	Validated_Good,
	Validated_Not_Good,
	Paused,
	Completed,
	Cancelled,
}

// Task_Priority orders tasks within an instance's work queue. Lower ordinal =
// higher urgency (P0 is most urgent). New tasks default to P2.
Task_Priority :: enum {
	P0,
	P1,
	P2,
}

task_priority_string :: proc(priority: Task_Priority) -> string {
	switch priority {
	case .P0: return "p0"
	case .P1: return "p1"
	case .P2: return "p2"
	}
	return "p2"
}

task_priority_from_string :: proc(value: string) -> Task_Priority {
	switch value {
	case "p0", "P0": return .P0
	case "p1", "P1": return .P1
	case "p2", "P2": return .P2
	}
	return .P2
}

Task_Chain :: struct {
	chain_id:                      Task_Chain_ID,
	owner_user_id:                 User_ID,
	title:                         string,
	description:                   string,
	publish_state:                 Publish_State,
	status:                        Task_Chain_Status,
	kind:                          string,
	coordinator_agent_instance_id: string,
	default_reviewer_refs_json:    string,
	// Title-nudge tracking fields (persisted). See Chat_Conversation for semantics.
	last_activity_at:              string,
	last_title_nudge_at:           string,
	title_source:                  string,
	created_at:                    string,
	updated_at:                    string,
	published_at:                  string,
	completed_at:                  string,
}

Task :: struct {
	task_id:            Task_ID,
	chain_id:           Task_Chain_ID,
	owner_user_id:      User_ID,
	title:              string,
	description:        string,
	publish_state:      Publish_State,
	status:             Task_Status,
	priority:           Task_Priority,
	assignee_ref_json:  string,
	reviewer_refs_json: string,
	created_at:         string,
	updated_at:         string,
	published_at:       string,
	started_at:         string,
	completed_at:       string,
}

Task_Comment :: struct {
	comment_id:               string,
	task_id:                  Task_ID,
	chain_id:                 Task_Chain_ID,
	owner_user_id:            User_ID,
	author_agent_instance_id: string,
	body:                     string,
	created_at:               string,
	updated_at:               string,
}

// Task_Comment_Summary is the compact comment rollup embedded on task objects so
// list/show/context can convey "there is discussion, and how recent" without
// shipping every comment body. Derived by a cheap COUNT + last-row query.
Task_Comment_Summary :: struct {
	count:                    int,    // total comments on the task
	last_comment_at:          string, // "" when count == 0
	last_comment_author:      string, // last comment's author_agent_instance_id
	last_comment_preview:     string, // first ~80 chars of the last comment body
}

// TASK_COMMENT_PREVIEW_MAX bounds the preview length (runes) in the summary.
TASK_COMMENT_PREVIEW_MAX :: 80

Task_Chain_Member :: struct {
	chain_id:          Task_Chain_ID,
	agent_instance_id: string,
	agent_id:          string,
	owner_user_id:     User_ID,
	role:              string,
	created_at:        string,
}

Task_Dependency :: struct {
	task_id:            Task_ID,
	depends_on_task_id: Task_ID,
	chain_id:           Task_Chain_ID,
	owner_user_id:      User_ID,
	created_at:         string,
}

Task_Vote :: struct {
	task_id:                    Task_ID,
	reviewer_agent_instance_id: string,
	chain_id:                   Task_Chain_ID,
	owner_user_id:              User_ID,
	vote:                       string,
	comment:                    string,
	created_at:                 string,
	updated_at:                 string,
}

task_status_unblocks_dependents :: proc(status: Task_Status) -> bool {
	return status == .Completed || status == .Cancelled
}

task_is_workable :: proc(task: Task) -> bool {
	return task.publish_state == .Published && task.status != .Completed && task.status != .Cancelled
}
