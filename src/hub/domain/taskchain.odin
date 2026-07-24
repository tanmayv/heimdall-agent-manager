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
	In_Progress,
	In_Validation,
	Validated_Good,
	Validated_Not_Good,
	Paused,
	Completed,
	Cancelled,
}

Task_Chain :: struct {
	chain_id:      Task_Chain_ID,
	owner_user_id: User_ID,
	title:         string,
	publish_state: Publish_State,
	status:        Task_Chain_Status,
	kind:          string,
	coordinator_agent_instance_id: string,
	default_reviewer_refs_json: string,
	created_at:    string,
	updated_at:    string,
	published_at:  string,
	completed_at:  string,
}

Task :: struct {
	task_id:       Task_ID,
	chain_id:      Task_Chain_ID,
	owner_user_id: User_ID,
	title:         string,
	publish_state: Publish_State,
	status:        Task_Status,
	assignee_ref_json: string,
	reviewer_refs_json: string,
	created_at:    string,
	updated_at:    string,
	published_at:  string,
	started_at:    string,
	completed_at:  string,
}

Task_Comment :: struct {
	comment_id: string,
	task_id: Task_ID,
	chain_id: Task_Chain_ID,
	owner_user_id: User_ID,
	author_agent_instance_id: string,
	body: string,
	created_at: string,
	updated_at: string,
}

task_status_unblocks_dependents :: proc(status: Task_Status) -> bool {
	return status == .Completed || status == .Cancelled
}

task_is_workable :: proc(task: Task) -> bool {
	return task.publish_state == .Published && task.status != .Completed && task.status != .Cancelled
}
