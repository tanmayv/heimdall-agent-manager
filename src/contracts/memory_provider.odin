package contracts

Memory_Type :: enum {
	Fact,
	Habit,
	Episode,
	Expertise,
	Skill,
	Template,
}

Memory_Status :: enum {
	Pending,
	Active,
	Archived,
	Rejected,
}

Memory_Event_Kind :: enum {
	Memory_Proposed,
	Memory_Approved,
	Memory_Rejected,
	Memory_Archived,
}

Memory_Provider_Capability :: enum {
	Append_Event,
	Replay,
	List_Records,
	History,
}

Memory_Event :: struct {
	event_id: string,
	kind: Memory_Event_Kind,
	memory_id: string,
	proposal_id: string,
	subject_agent: string,
	scope: string,
	subject_key: string,
	project_ids: string,
	role_keys: string,
	task_chain_types: string,
	type: Memory_Type,
	title: string,
	body: string,
	status: Memory_Status,
	reason: string,
	evidence: string,
	metadata_json: string,
	author: string,
	source_task_id: string,
	version: int,
	created_unix_ms: i64,
}

Memory_Record :: struct {
	memory_id: string,
	proposal_id: string,
	subject_agent: string,
	scope: string,
	subject_key: string,
	project_ids: string,
	role_keys: string,
	task_chain_types: string,
	type: Memory_Type,
	title: string,
	body: string,
	status: Memory_Status,
	reason: string,
	evidence: string,
	metadata_json: string,
	source_task_id: string,
	version: int,
	created_unix_ms: i64,
	updated_unix_ms: i64,
}

Memory_Append_Response :: struct {
	ok: bool,
	message: string,
	event_id: string,
	memory_id: string,
	proposal_id: string,
}

Memory_Replay_Response :: struct {
	ok: bool,
	message: string,
	event_count: int,
	record_count: int,
}

Memory_List_Request :: struct {
	subject_agent: string,
	scope: string,
	subject_key: string,
	status: Memory_Status,
	include_all_statuses: bool,
}

Memory_List_Response :: struct {
	ok: bool,
	message: string,
	records: []Memory_Record,
}

Memory_History_Request :: struct {
	memory_id: string,
}

Memory_History_Response :: struct {
	ok: bool,
	message: string,
	events: []Memory_Event,
}
