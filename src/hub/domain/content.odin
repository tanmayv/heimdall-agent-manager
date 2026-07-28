package domain

Memory :: struct {
	memory_id: string,
	owner_user_id: User_ID,
	agent_id: string,
	type: string,
	status: string,
	title: string,
	body: string,
	evidence: string,
	created_at: string,
	updated_at: string,
}

Chat_Conversation :: struct {
	conversation_id: string,
	owner_user_id: User_ID,
	agent_id: string,
	agent_instance_id: string,
	project_id: Project_ID,
	chain_id: string,
	title: string,
	unread_count: int,
	last_message_preview: string,
	last_message_at: string,
	created_at: string,
	updated_at: string,
}

Chat_Message :: struct {
	message_id: string,
	conversation_id: string,
	owner_user_id: User_ID,
	direction: string,
	sender_agent_id: string,
	sender_agent_instance_id: string,
	body: string,
	artifact_ids_json: string,
	created_at: string,
	delivered_at: string,
	read_at: string,
}

Artifact :: struct {
	artifact_id: string,
	owner_user_id: User_ID,
	kind: string,
	name: string,
	description: string,
	content_type: string,
	size_bytes: int,
	blob_ref: string,
	content: string,
	mime: string,
	ext: string,
	sha256: string,
	origin_kind: string,
	origin_ref: string,
	deleted_at: string,
	agent_id: string,
	agent_instance_id: string,
	chain_id: string,
	task_id: string,
	project_id: Project_ID,
	created_at: string,
	updated_at: string,
}

Template :: struct {
	template_id: string,
	owner_user_id: User_ID,
	is_system: bool,
	name: string,
	description: string,
	persona: string,
	instructions: string,
	created_at: string,
	updated_at: string,
}
