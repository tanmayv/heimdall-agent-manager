package http

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import virtual "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"

coordinator_wake_test_mutex: sync.Mutex

Coordinator_Wake_Fixture :: struct {
	f: ^wire_fixture,
	content_impl: sqlite.Content_Repo_SQLite,
	content_repo: iface.Content_Repository,
	content: content_service.Content_Service,
	provider_impl: sqlite.Provider_Repo_SQLite,
	providers: iface.Provider_Repository,
	registry: project_service.Bridge_Runtime_Registry,
	commands: [dynamic]string,
	allocator: mem.Allocator,
}

coordinator_wake_test_command :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	c := (^Coordinator_Wake_Fixture)(ctx)
	context.allocator = c.allocator
	append(&c.commands, strings.clone(command.body_json, c.allocator))
	return true, {}
}

coordinator_wake_fixture :: proc(t: ^testing.T, other_owner := false) -> ^Coordinator_Wake_Fixture {
	sync.mutex_lock(&coordinator_wake_test_mutex)
	coordinator_wake_guard_reset()
	c := new(Coordinator_Wake_Fixture)
	c.allocator = context.allocator
	c.f = wire_setup(t, "coordinator_wake")
	f := c.f
	target_owner := domain.User_ID("other_owner") if other_owner else f.owner
	c.content_repo = sqlite.new_content_repository(&c.content_impl, &f.conn)
	c.content = content_service.new_content_service(&c.content_repo, &f.ag_repo, &f.br_repo, nil, &f.tc_repo, &f.clock, &f.ids)
	c.providers = sqlite.new_provider_repository(&c.provider_impl, &f.conn)
	f.ah.content = &c.content
	f.ag_svc.providers = &c.providers
	f.ag_svc.content = &c.content_repo
	f.ag_svc.bridge_runtime_registry = &c.registry
	sink := project_service.Bridge_Command_Sink{ctx = c, send_runtime_command = coordinator_wake_test_command}
	f.ag_svc.bridge_command_sink = sink
	c.content.bridge_command_sink = sink
	testing.expect(t, project_service.bridge_runtime_registry_mark_live(&c.registry, f.bridge_pin, false, ""))
	testing.expect(t, sqlite.exec(&f.conn, fmt.tprintf("UPDATE bridges SET status='online' WHERE bridge_id='%s';", f.bridge_pin)))
	entry, exists, err := iface.provider_catalog_get(&c.providers, "claude")
	testing.expect(t, exists && err.code == .None && len(entry.models) > 0)
	model := ""
	for m in entry.models do if m.state == "active" { model = m.model_id; break }
	testing.expect(t, model != "")
	_, status_err := iface.bridge_provider_status_upsert(&c.providers, {bridge_id = f.bridge_pin, provider = "claude", state = "present", binary_path = "/bin/claude", checked_at = "now"})
	testing.expect_value(t, status_err.code, domain.Error_Code.None)
	_, agent_ok, agent_err := iface.agent_save(&f.ag_repo, {agent_id = "agt_wake", owner_user_id = target_owner, name = "Coordinator", slug = "wake", template_id = "tmpl_worker", created_at = "now", updated_at = "now"})
	testing.expectf(t, agent_ok, "%s", agent_err.message)
	_, target_ok, target_err := iface.agent_save_instance(&f.ag_repo, {
		agent_instance_id = "inst_wake", agent_id = "agt_wake", owner_user_id = target_owner,
		bridge_id = f.bridge_pin, chain_id = string(f.chain_id), conversation_id = "chat_wake",
		provider = "claude", model = model, runtime_status = "stopped", startup_status = "ready",
		kind = "agent", created_at = "now", updated_at = "now",
	})
	testing.expectf(t, target_ok, "%s", target_err.message)
	_, member_ok, member_err := iface.taskchain_save_member(&f.tc_repo, {chain_id = f.chain_id, agent_instance_id = "inst_wake", agent_id = "agt_wake", owner_user_id = target_owner, role = "coordinator", created_at = "now"})
	testing.expectf(t, member_ok, "%s", member_err.message)
	_, conv_ok, conv_err := iface.content_save_conversation(&c.content_repo, {conversation_id = "chat_wake", owner_user_id = target_owner, agent_id = "agt_wake", agent_instance_id = "inst_wake", title = "Wake", created_at = "now", updated_at = "now"})
	testing.expectf(t, conv_ok, "%s", conv_err.message)
	return c
}

coordinator_wake_fixture_destroy :: proc(c: ^Coordinator_Wake_Fixture) {
	coordinator_wake_guard_reset()
	for command in c.commands do delete(command, c.allocator)
	delete(c.commands)
	project_service.bridge_runtime_registry_destroy(&c.registry)
	wire_teardown(c.f)
	free(c)
	sync.mutex_unlock(&coordinator_wake_test_mutex)
}

coordinator_wake_send :: proc(c: ^Coordinator_Wake_Fixture) -> Response {
	body := strings.concatenate({`{"agent_instance_id":"`, c.f.instance_id, `","params":{"to_instance":"inst_wake","body":"please continue"}}`})
	return agent_action_chat_send_to_agent_handler(&c.f.ah, wire_agent_request(c.f, "chat/send-to-agent", body))
}

coordinator_wake_expect :: proc(t: ^testing.T, c: ^Coordinator_Wake_Fixture, expected: string, launches: int) {
	resp := coordinator_wake_send(c)
	testing.expectf(t, resp.status == 201, "%d %s", resp.status, resp.body)
	wire: struct {data: struct {wake, message_id, conversation_id, body: string}}
	err := json.unmarshal_string(resp.body, &wire)
	testing.expect(t, err == nil)
	testing.expect_value(t, wire.data.wake, expected)
	testing.expect_value(t, wire.data.body, "please continue")
	testing.expect_value(t, wire.data.conversation_id, "chat_wake")
	msg, found, _ := iface.content_get_message(&c.content_repo, wire.data.message_id)
	testing.expect(t, found && msg.direction == "agent_to_agent" && msg.sender_agent_instance_id == c.f.instance_id)
	count := 0
	for command in c.commands do if strings.contains(command, `"type":"launch_agent"`) do count += 1
	testing.expect_value(t, count, launches)
}

@(test)
test_agent_message_wakes_stopped_coordinator :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	coordinator_wake_expect(t, c, "started", 1)
	inst, _, _ := iface.agent_get_instance(&c.f.ag_repo, "inst_wake")
	testing.expect(t, inst.runtime_status == "launching" && inst.run_count == 1)
}

@(test)
test_agent_message_running_coordinator_not_needed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE agent_instances SET runtime_status='running' WHERE agent_instance_id='inst_wake';"))
	coordinator_wake_expect(t, c, "not_needed", 0)
}

@(test)
test_agent_message_does_not_wake_non_coordinator :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE task_chain_members SET role='worker' WHERE agent_instance_id='inst_wake';"))
	coordinator_wake_expect(t, c, "not_coordinator", 0)
}

@(test)
test_agent_message_does_not_wake_coordinator_of_inactive_chain :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE task_chains SET status='completed', completion_summary='finished', completed_at='now';"))
	coordinator_wake_expect(t, c, "not_coordinator", 0)
}

@(test)
test_agent_message_does_not_wake_bot_instance :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE agents SET template_id='tmpl_bot' WHERE agent_id='agt_wake';"))
	coordinator_wake_expect(t, c, "not_coordinator", 0)
}

@(test)
test_agent_message_does_not_wake_user_stopped_coordinator :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE agent_instances SET stopped_by='user' WHERE agent_instance_id='inst_wake';"))
	coordinator_wake_expect(t, c, "user_stopped", 0)
}

coordinator_wake_at :: proc(c: ^Coordinator_Wake_Fixture, now: i64, sender_id := "") -> Coordinator_Wake_Outcome {
	id := sender_id if sender_id != "" else c.f.instance_id
	return coordinator_wake_after_agent_message(&c.f.ah,
		{kind = .Instance_Token, user_id = string(c.f.owner), agent_instance_id = id},
		{agent_instance_id = id, owner_user_id = c.f.owner}, "inst_wake", "chat_wake", now)
}

@(test)
test_coordinator_wake_rate_limited_per_target :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect_value(t, coordinator_wake_at(c, 0), Coordinator_Wake_Outcome.Started)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE agent_instances SET runtime_status='stopped' WHERE agent_instance_id='inst_wake';"))
	testing.expect_value(t, coordinator_wake_at(c, 119_999, "other_sender"), Coordinator_Wake_Outcome.Rate_Limited)
	testing.expect_value(t, coordinator_wake_at(c, 120_000), Coordinator_Wake_Outcome.Started)
}

@(test)
test_coordinator_wake_sender_hourly_cap :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	for i in 0..<20 {
		target := fmt.tprintf("inst_other_%d", i)
		testing.expect(t, coordinator_wake_guard_try(c.f.instance_id, target, 100))
	}
	testing.expect_value(t, coordinator_wake_at(c, 100), Coordinator_Wake_Outcome.Rate_Limited)
	testing.expect_value(t, coordinator_wake_at(c, 3_600_100), Coordinator_Wake_Outcome.Started)
}

@(test)
test_coordinator_wake_failure_keeps_message :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	generation := project_service.bridge_runtime_registry_generation(&c.registry, c.f.bridge_pin)
	project_service.bridge_runtime_registry_mark_offline(&c.registry, c.f.bridge_pin, generation)
	coordinator_wake_expect(t, c, "failed", 0)
	// Failed attempts count too; the next message remains saved but is throttled.
	coordinator_wake_expect(t, c, "rate_limited", 0)
}

@(test)
test_agent_message_cross_owner_target_not_found :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t, other_owner = true); defer coordinator_wake_fixture_destroy(c)
	resp := coordinator_wake_send(c)
	testing.expectf(t, resp.status == 404, "%s", resp.body)
	rows, err := iface.content_list_messages(&c.content_repo, "chat_wake", c.f.owner, -1, "")
	testing.expect(t, err.code == .None && len(rows) == 0)
	testing.expect_value(t, len(c.commands), 0)
}

coordinator_wake_startup_case :: proc(t: ^testing.T, read: bool, message_type := "text") {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	// The authenticated sender restarts with an inbound message from the target.
	_, saved, _ := iface.content_save_conversation(&c.content_repo, {conversation_id = "chat_sender", owner_user_id = c.f.owner, agent_id = "agt_wire_tb2", agent_instance_id = c.f.instance_id, title = "Sender", created_at = "now", updated_at = "now"})
	testing.expect(t, saved)
	read_at := "now" if read else ""
	_, msg_ok, _ := iface.content_save_message(&c.content_repo, {message_id = "msg_agent_pending", conversation_id = "chat_sender", owner_user_id = c.f.owner, direction = "agent_to_agent", sender_agent_id = "agt_wake", sender_agent_instance_id = "inst_wake", body = "reply", message_type = message_type, artifact_ids_json = "[]", created_at = "now", read_at = read_at})
	testing.expect(t, msg_ok)
	body := strings.concatenate({`{"agent_instance_id":"`, c.f.instance_id, `","params":{}}`})
	req := wire_agent_request(c.f, "start-success", body)
	resp := agent_action_start_success_handler(&c.f.ah, req)
	testing.expectf(t, resp.status == 200, "%s", resp.body)
	notices := 0
	for command in c.commands {
		if !strings.contains(command, "notify_agent_message") do continue
		notices += 1
		testing.expect(t, strings.contains(command, `"direction":"agent_to_agent"`) && strings.contains(command, "inst_wake") && strings.contains(command, "msg_agent_pending"))
	}
	expected := 0 if read || message_type == content_service.MESSAGE_TYPE_PREVIOUS_CONTEXT else 1
	testing.expect_value(t, notices, expected)
	testing.expect_value(t, agent_action_start_success_handler(&c.f.ah, req).status, 200)
	testing.expect(t, len(c.commands) == notices, "duplicate start-success does not repeat the notice")
}

@(test)
test_start_success_renotifies_unread_agent_message :: proc(t: ^testing.T) {
	coordinator_wake_startup_case(t, false)
}
@(test)
test_start_success_does_not_renotify_read_agent_message :: proc(t: ^testing.T) {
	coordinator_wake_startup_case(t, true)
}
@(test)
test_start_success_does_not_renotify_agent_previous_context :: proc(t: ^testing.T) {
	coordinator_wake_startup_case(t, false, content_service.MESSAGE_TYPE_PREVIOUS_CONTEXT)
}

@(test)
test_coordinator_wake_failed_and_unreachable_targets :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	for status, i in ([]string{"failed", "unreachable"}) {
		testing.expect(t, sqlite.exec(&c.f.conn, fmt.tprintf("UPDATE agent_instances SET runtime_status='%s' WHERE agent_instance_id='inst_wake';", status)))
		testing.expect_value(t, coordinator_wake_at(c, i64(i) * 120_000), Coordinator_Wake_Outcome.Started)
	}
}

@(test)
test_coordinator_wake_non_agent_target :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE agent_instances SET kind='provider_test' WHERE agent_instance_id='inst_wake';"))
	coordinator_wake_expect(t, c, "not_coordinator", 0)
}

coordinator_wake_guard_scratch_insert :: proc() {
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)
	sender := strings.clone("scratch_sender")
	target := strings.clone("scratch_target")
	assert(coordinator_wake_guard_try(sender, target, 0))
}

@(test)
test_coordinator_wake_guard_owns_keys_beyond_request :: proc(t: ^testing.T) {
	sync.mutex_lock(&coordinator_wake_test_mutex)
	defer sync.mutex_unlock(&coordinator_wake_test_mutex)
	coordinator_wake_guard_reset()
	defer coordinator_wake_guard_reset()
	coordinator_wake_guard_scratch_insert()
	testing.expect(t, !coordinator_wake_guard_try("scratch_sender", "scratch_target", 119_999))
	testing.expect(t, coordinator_wake_guard_try("scratch_sender", "scratch_target", 120_000))
	testing.expect(t, coordinator_wake_guard_try("scratch_sender", "another_target", 120_000))
}
