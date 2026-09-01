package domain

import "core:strings"

Memory_Type :: enum {
	Unknown,
	Fact,
	Habit,
	Episode,
	Expertise,
	Skill,
}

memory_type_from_string :: proc(value: string) -> Memory_Type {
	switch strings.to_lower(strings.trim_space(value)) {
	case "fact", "":
		return .Fact
	case "habit":
		return .Habit
	case "episode":
		return .Episode
	case "expertise":
		return .Expertise
	case "skill":
		return .Skill
	}
	return .Unknown
}

memory_type_string :: proc(t: Memory_Type) -> string {
	switch t {
	case .Unknown:
		return "unknown"
	case .Fact:
		return "fact"
	case .Habit:
		return "habit"
	case .Episode:
		return "episode"
	case .Expertise:
		return "expertise"
	case .Skill:
		return "skill"
	}
	return "unknown"
}

Memory :: struct {
	memory_id: string,
	owner_user_id: User_ID,
	agent_id: string,
	project_id: Project_ID,
	template_id: string,
	bridge_id: string,
	type: Memory_Type,
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
	// Additive summary-only fields populated by conversation list queries. They
	// support standard chat-list APIs without changing the persisted conversation
	// table or forcing the UI to fetch every message thread for inbox rows.
	last_message_id: string,
	last_message_direction: string,
	last_message_sender_agent_id: string,
	last_message_sender_agent_instance_id: string,
	last_message_type: string,
	last_message_status: string,
	last_message_created_at: string,
	// Total user-visible messages in the conversation (direction != agent_to_agent).
	// Summary-only, populated by conversation list queries.
	message_count: int,
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
	message_type: string,
	message_status: string,
	metadata_json: string,
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
