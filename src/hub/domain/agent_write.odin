package domain

AGENT_WRITE_KIND_PROJECT :: "project"
AGENT_WRITE_KIND_MEMORY :: "memory"
AGENT_WRITE_KIND_AGENT :: "agent"
AGENT_WRITE_ACTION_CREATE :: "create"
AGENT_WRITE_ACTION_UPDATE :: "update"
AGENT_WRITE_ACTION_ARCHIVE :: "archive"
AGENT_WRITE_ACTION_UNARCHIVE :: "unarchive"

Agent_Write :: struct {
	seq:                                                                                  i64,
	write_id, owner_user_id, actor_agent_instance_id, actor_agent_id, actor_display_name: string,
	resource_kind, resource_id, action:                                                   string,
	fields:                                                                               []string,
	created_at:                                                                           string,
}

agent_write_destroy :: proc(w: ^Agent_Write) {
	delete(w.write_id)
	delete(w.owner_user_id)
	delete(w.actor_agent_instance_id)
	delete(w.actor_agent_id)
	delete(w.actor_display_name)
	delete(w.resource_kind)
	delete(w.resource_id)
	delete(w.action)
	for field in w.fields do delete(field)
	delete(w.fields)
	delete(w.created_at)
	w^ = {}
}
