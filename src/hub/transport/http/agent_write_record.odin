package http

import "core:encoding/json"
import "core:log"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content_service "odin_test:hub/service/content"

// Records key names only. Failure must never turn a successful content write into an error.
record_agent_write :: proc(
	repo: ^iface.Agent_Write_Repository,
	auth: contracts.Auth_Context,
	resource_kind, resource_id, action: string,
	fields: []string,
) {
	if repo == nil || auth.kind != .Instance_Token do return
	err := iface.agent_write_insert(
		repo,
		{
			owner_user_id = auth.user_id,
			actor_agent_instance_id = auth.agent_instance_id,
			resource_kind = resource_kind,
			resource_id = resource_id,
			action = action,
			fields = fields,
		},
	)
	if err.code != .None do log.errorf("agent_write: record failed kind=%s id=%s actor=%s code=%v", resource_kind, resource_id, auth.agent_instance_id, err.code)
}

// Presence matters for memory/agent PATCH, while project services ignore empty values.
agent_write_body_fields :: proc(body: string, keys: []string, nonempty := false) -> []string {
	value, err := json.parse(body)
	if err != nil do return nil
	defer json.destroy_value(value)
	object, ok := value.(json.Object)
	if !ok do return nil
	result := make([dynamic]string, 0, len(keys), context.temp_allocator)
	for key in keys {
		if _, present := object[key]; present && (!nonempty || strings.trim_space(json_string(body, key, context.temp_allocator)) != "") do append(&result, key)
	}
	return result[:]
}
AGENT_WRITE_PROJECT_FIELDS :: []string{"name", "slug", "description", "repo_url", "vcs_kind", "default_path"}
AGENT_WRITE_MEMORY_FIELDS :: []string {
	"type",
	"title",
	"description",
	"body",
	"evidence",
	"status",
	"expires_at",
	"agent_ids",
	"project_ids",
	"bridge_ids",
	"template_ids",
}
AGENT_WRITE_AGENT_FIELDS :: []string{"name", "slug", "template_id", "instructions", "permission_mode"}

agent_write_memory_update_fields :: proc(input: content_service.Memory_Update_Input) -> []string {
	fields := make([dynamic]string, 0, 10, context.temp_allocator)
	if input.has_type do append(&fields, "type")
	if input.has_title do append(&fields, "title")
	if input.has_description do append(&fields, "description")
	if input.has_body do append(&fields, "body")
	if input.has_evidence do append(&fields, "evidence")
	if input.has_expires_at do append(&fields, "expires_at")
	if input.has_agent_ids do append(&fields, "agent_ids")
	if input.has_project_ids do append(&fields, "project_ids")
	if input.has_bridge_ids do append(&fields, "bridge_ids")
	if input.has_template_ids do append(&fields, "template_ids")
	return fields[:]
}
