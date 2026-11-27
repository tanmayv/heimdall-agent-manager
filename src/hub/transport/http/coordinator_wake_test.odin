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
import agent_service "odin_test:hub/service/agent"
import taskv2 "odin_test:hub/service/taskv2"
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
	// Existing delivery tests describe process states via their fixture rows.
	// The production decision consumes only this independent observation.
	f.ag_svc.fixture_start_fact = proc(inst: domain.Agent_Instance) -> agent_service.Agent_Liveness {
		switch inst.runtime_status {
		case "running", "idle", "busy", "blocked": return {state=.Alive, reason=.pty_child_alive, pid=42, ready=true}
		case "starting", "launching", "stopping": return {state=.Alive, reason=.pty_child_alive, pid=42}
		case "terminated": return {reason=.retired}
		case: return {state=.Exited, reason=.missing_from_pty_roster}
		}
	}
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

@(test)
test_coordinator_wake_guard_evicts_expired_entries :: proc(t: ^testing.T) {
	// Keep context.allocator as the runner's tracking allocator: every map,
	// cloned key and eviction buffer must be freed before this test returns.
	g: Coordinator_Wake_Guard
	defer coordinator_wake_guard_destroy(&g)
	for i in 0..<40 {
		sender := fmt.tprintf("sender_%d", i)
		target := fmt.tprintf("target_%d", i)
		testing.expect(t, coordinator_wake_guard_try_locked(&g, sender, target, 0))
	}
	testing.expect_value(t, len(g.last_target_ms), 40)
	testing.expect_value(t, len(g.sender_windows), 40)
	testing.expect(t, !coordinator_wake_guard_try_locked(&g, "sender_0", "target_0", 119_999))
	testing.expect(t, coordinator_wake_guard_try_locked(&g, "fresh_sender", "fresh_target", 120_000))
	// A periodic sweep may lag by a minute; force the next scheduled sweep.
	testing.expect(t, coordinator_wake_guard_try_locked(&g, "fresh_sender", "next_target", 180_000))
	testing.expect_value(t, len(g.last_target_ms), 2)
	testing.expect_value(t, len(g.sender_windows), 41)
	testing.expect(t, coordinator_wake_guard_try_locked(&g, "after_expiry", "after_expiry", 3_780_000))
	testing.expect_value(t, len(g.last_target_ms), 1)
	testing.expect_value(t, len(g.sender_windows), 1)
}

@(test)
test_coordinator_wake_guard_capacity_preserves_live_limits :: proc(t: ^testing.T) {
	g: Coordinator_Wake_Guard
	defer coordinator_wake_guard_destroy(&g)
	for i in 0..<COORDINATOR_WAKE_GUARD_MAX_ENTRIES {
		sender := fmt.tprintf("sender_%d", i)
		target := fmt.tprintf("target_%d", i)
		testing.expect(t, coordinator_wake_guard_try_locked(&g, sender, target, 0))
	}
	testing.expect(t, !coordinator_wake_guard_try_locked(&g, "new_sender", "new_target", 1))
	testing.expect_value(t, len(g.last_target_ms), COORDINATOR_WAKE_GUARD_MAX_ENTRIES)
	testing.expect_value(t, len(g.sender_windows), COORDINATOR_WAKE_GUARD_MAX_ENTRIES)
	testing.expect(t, !coordinator_wake_guard_try_locked(&g, "sender_0", "target_0", 1))
	// Target slots expire first. A new sender is still refused while every
	// sender window is live, but an existing sender can use a new target.
	testing.expect(t, !coordinator_wake_guard_try_locked(&g, "new_sender", "new_target", 120_000))
	testing.expect_value(t, len(g.last_target_ms), 0)
	testing.expect(t, coordinator_wake_guard_try_locked(&g, "sender_0", "new_target", 120_000))
	testing.expect_value(t, g.sender_windows["sender_0"].count, 2)
	testing.expect(t, coordinator_wake_guard_try_locked(&g, "new_sender", "new_target", 3_600_000))
	testing.expect_value(t, len(g.last_target_ms), 1)
	testing.expect_value(t, len(g.sender_windows), 1)
}

// ---- REQ-CIS-2: [taskv2] notices wake a stopped coordinator ---------------------

coordinator_wake_launches :: proc(c: ^Coordinator_Wake_Fixture) -> int {
	count := 0
	for command in c.commands do if strings.contains(command, `"type":"launch_agent"`) do count += 1
	return count
}

coordinator_wake_set_stopped :: proc(t: ^testing.T, c: ^Coordinator_Wake_Fixture, stopped_by := "") {
	testing.expect(t, sqlite.exec(&c.f.conn, fmt.tprintf("UPDATE agent_instances SET runtime_status='stopped', stopped_by='%s' WHERE agent_instance_id='inst_wake';", stopped_by)))
}

// coordinator_wake_idle_stop stops the running coordinator the way the idle
// timer does (agent.stop_instance with a non-"user" reason), then records the
// bridge's stopped report.
coordinator_wake_idle_stop :: proc(t: ^testing.T, c: ^Coordinator_Wake_Fixture, reason: string) {
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE agent_instances SET runtime_status='running' WHERE agent_instance_id='inst_wake';"))
	auth := contracts.Auth_Context{kind = .Internal_User, user_id = string(c.f.owner)}
	_, stopped, stop_err := agent_service.stop_instance(c.f.ah.agents, auth, "inst_wake", {reason = reason})
	testing.expectf(t, stopped, "stop %s: %s", reason, stop_err.message)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE agent_instances SET runtime_status='stopped' WHERE agent_instance_id='inst_wake';"))
	inst, _, _ := iface.agent_get_instance(&c.f.ag_repo, "inst_wake")
	testing.expect_value(t, inst.stopped_by, "")
}

coordinator_wake_notice_at :: proc(c: ^Coordinator_Wake_Fixture, now: i64) -> Coordinator_Wake_Outcome {
	outcome, _ := coordinator_wake_after_task_notice(&c.f.ah, string(c.f.owner), "inst_wake", now)
	return outcome
}

coordinator_wake_notice_reply :: proc(c: ^Coordinator_Wake_Fixture, now: i64) -> (Coordinator_Wake_Outcome, taskv2.Coordinator_Wake_Reply) {
	return coordinator_wake_after_task_notice(&c.f.ah, string(c.f.owner), "inst_wake", now)
}

coordinator_wake_set_status :: proc(t: ^testing.T, c: ^Coordinator_Wake_Fixture, status: string) {
	testing.expect(t, sqlite.exec(&c.f.conn, fmt.tprintf("UPDATE agent_instances SET runtime_status='%s' WHERE agent_instance_id='inst_wake';", status)))
}

@(test)
test_task_notice_wakes_idle_stopped_coordinator :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	coordinator_wake_idle_stop(t, c, "coordinator_idle")
	testing.expect_value(t, coordinator_wake_notice_at(c, 0), Coordinator_Wake_Outcome.Started)
	testing.expect_value(t, coordinator_wake_launches(c), 1)
	inst, _, _ := iface.agent_get_instance(&c.f.ag_repo, "inst_wake")
	testing.expect_value(t, inst.runtime_status, "launching")
}

@(test)
test_task_notice_does_not_wake_user_stopped_coordinator :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	coordinator_wake_set_stopped(t, c, "user")
	testing.expect_value(t, coordinator_wake_notice_at(c, 0), Coordinator_Wake_Outcome.User_Stopped)
	testing.expect_value(t, coordinator_wake_launches(c), 0)
	inst, _, _ := iface.agent_get_instance(&c.f.ag_repo, "inst_wake")
	testing.expect_value(t, inst.stopped_by, "user")
}

@(test)
test_task_notice_burst_starts_coordinator_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect_value(t, coordinator_wake_notice_at(c, 0), Coordinator_Wake_Outcome.Started)
	// A notice that lands before the launch is reported is not needed at all.
	testing.expect_value(t, coordinator_wake_notice_at(c, 100), Coordinator_Wake_Outcome.Not_Needed)
	// Even if the instance reads as stopped again, the burst is throttled.
	coordinator_wake_set_stopped(t, c)
	for now in ([]i64{200, 60_000, 119_999}) {
		testing.expect_value(t, coordinator_wake_notice_at(c, now), Coordinator_Wake_Outcome.Rate_Limited)
	}
	testing.expect_value(t, coordinator_wake_launches(c), 1)
	testing.expect_value(t, coordinator_wake_notice_at(c, 120_000), Coordinator_Wake_Outcome.Started)
	testing.expect_value(t, coordinator_wake_launches(c), 2)
}

@(test)
test_task_notice_wakes_coordinator_of_completed_chain :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE task_chains SET status='completed', completion_summary='finished', completed_at='now';"))
	coordinator_wake_idle_stop(t, c, "coordinator_idle_completed")
	testing.expect_value(t, coordinator_wake_notice_at(c, 0), Coordinator_Wake_Outcome.Started)
	testing.expect_value(t, coordinator_wake_launches(c), 1)
}

@(test)
test_task_notice_skips_cancelled_chain_bot_and_non_coordinator :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE task_chains SET status='cancelled';"))
	testing.expect_value(t, coordinator_wake_notice_at(c, 0), Coordinator_Wake_Outcome.Not_Coordinator)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE task_chains SET status='active';"))
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE agents SET template_id='tmpl_bot' WHERE agent_id='agt_wake';"))
	testing.expect_value(t, coordinator_wake_notice_at(c, 0), Coordinator_Wake_Outcome.Not_Coordinator)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE agents SET template_id='tmpl_worker' WHERE agent_id='agt_wake';"))
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE task_chain_members SET role='worker' WHERE agent_instance_id='inst_wake';"))
	testing.expect_value(t, coordinator_wake_notice_at(c, 0), Coordinator_Wake_Outcome.Not_Coordinator)
	testing.expect_value(t, coordinator_wake_launches(c), 0)
}

@(test)
test_task_notice_wake_resolves_conversation_by_instance :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect(t, sqlite.exec(&c.f.conn, "UPDATE agent_instances SET conversation_id='' WHERE agent_instance_id='inst_wake';"))
	testing.expect_value(t, coordinator_wake_notice_at(c, 0), Coordinator_Wake_Outcome.Started)
	testing.expect_value(t, coordinator_wake_launches(c), 1)
}

@(test)
test_task_notice_wake_ignores_other_owner :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t, other_owner = true); defer coordinator_wake_fixture_destroy(c)
	testing.expect_value(t, coordinator_wake_notice_at(c, 0), Coordinator_Wake_Outcome.Failed)
	testing.expect_value(t, coordinator_wake_launches(c), 0)
}

// The idle stop reasons must not read as a user stop: a user chat message to
// the coordinator still restarts it (restart_stopped_conversation_instance is
// the chat send path, content_handlers.odin).
@(test)
test_user_chat_wakes_idle_stopped_coordinator :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for reason, i in ([]string{"coordinator_idle", "coordinator_idle_completed"}) {
		c := coordinator_wake_fixture(t)
		coordinator_wake_idle_stop(t, c, reason)
		ch := Content_Handlers{auth = c.f.ah.auth, agents = c.f.ah.agents, content = c.f.ah.content, event_bus = c.f.ah.event_bus}
		restarted, err := restart_stopped_conversation_instance(&ch, {kind = .Internal_User, user_id = string(c.f.owner)}, "chat_wake")
		testing.expectf(t, restarted, "%s: %s", reason, err.message)
		testing.expectf(t, coordinator_wake_launches(c) == 1, "%s: launches=%d (case %d)", reason, coordinator_wake_launches(c), i)
		coordinator_wake_fixture_destroy(c)
	}
}

// ---- review round 1: unsettled wakes report when to retry ------------------------

// Finding 1: a rate-limited wake is not settled; it names the time at which the
// guard admits it, and an attempt at that time starts the coordinator.
@(test)
test_task_notice_rate_limited_reply_names_retry_time :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	testing.expect_value(t, coordinator_wake_notice_at(c, 0), Coordinator_Wake_Outcome.Started)
	coordinator_wake_set_stopped(t, c) // idle-stopped again soon after the wake
	outcome, reply := coordinator_wake_notice_reply(c, 90_000)
	testing.expect_value(t, outcome, Coordinator_Wake_Outcome.Rate_Limited)
	testing.expect(t, !reply.settled && !reply.live)
	testing.expect_value(t, reply.retry_at_ms, COORDINATOR_WAKE_TARGET_MIN_INTERVAL_MS)
	outcome, reply = coordinator_wake_notice_reply(c, reply.retry_at_ms)
	testing.expect_value(t, outcome, Coordinator_Wake_Outcome.Started)
	testing.expect(t, reply.settled)
	testing.expect_value(t, coordinator_wake_launches(c), 2)
}

// Finding 2: a stopping (or launching) coordinator is not settled; once the
// stop completes the next attempt starts it. A live one asks only for a watch.
@(test)
test_task_notice_while_stopping_is_retried_after_stop :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	coordinator_wake_set_status(t, c, "running")
	outcome, reply := coordinator_wake_notice_reply(c, 0)
	testing.expect_value(t, outcome, Coordinator_Wake_Outcome.Not_Needed)
	testing.expect(t, !reply.settled && reply.live)
	for status in ([]string{"stopping", "launching", "starting"}) {
		coordinator_wake_set_status(t, c, status)
		outcome, reply = coordinator_wake_notice_reply(c, 1_000)
		testing.expect_value(t, outcome, Coordinator_Wake_Outcome.Not_Needed)
		testing.expectf(t, !reply.settled && !reply.live, "%s must be retried", status)
	}
	coordinator_wake_set_status(t, c, "stopped")
	outcome, reply = coordinator_wake_notice_reply(c, 2_000)
	testing.expect_value(t, outcome, Coordinator_Wake_Outcome.Started)
	testing.expect(t, reply.settled)
	testing.expect_value(t, coordinator_wake_launches(c), 1)
	// A terminated instance will never run again: settled.
	coordinator_wake_set_status(t, c, "terminated")
	outcome, reply = coordinator_wake_notice_reply(c, 3_000)
	testing.expect_value(t, outcome, Coordinator_Wake_Outcome.Not_Needed)
	testing.expect(t, reply.settled)
}

// Finding 3: a transient restart failure releases the guard slot and is
// retried; the retry starts the coordinator instead of being rate limited.
@(test)
test_task_notice_transient_failure_retried_without_guard_penalty :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t); defer coordinator_wake_fixture_destroy(c)
	generation := project_service.bridge_runtime_registry_generation(&c.registry, c.f.bridge_pin)
	project_service.bridge_runtime_registry_mark_offline(&c.registry, c.f.bridge_pin, generation)
	outcome, reply := coordinator_wake_notice_reply(c, 0)
	testing.expect_value(t, outcome, Coordinator_Wake_Outcome.Failed)
	testing.expect(t, !reply.settled)
	testing.expect_value(t, reply.retry_at_ms, COORDINATOR_WAKE_TRANSIENT_RETRY_MS)
	testing.expect_value(t, coordinator_wake_guard_next_allowed("taskv2:inst_wake", "inst_wake", 1), i64(1))
	testing.expect(t, project_service.bridge_runtime_registry_mark_live(&c.registry, c.f.bridge_pin, false, ""))
	outcome, reply = coordinator_wake_notice_reply(c, reply.retry_at_ms)
	testing.expect_value(t, outcome, Coordinator_Wake_Outcome.Started)
	testing.expect(t, reply.settled)
	testing.expect_value(t, coordinator_wake_launches(c), 1)
}

@(test)
test_task_notice_permanent_failure_settles :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := coordinator_wake_fixture(t, other_owner = true); defer coordinator_wake_fixture_destroy(c)
	outcome, reply := coordinator_wake_notice_reply(c, 0)
	testing.expect_value(t, outcome, Coordinator_Wake_Outcome.Failed)
	testing.expect(t, reply.settled)
}

@(test)
test_coordinator_wake_guard_next_allowed_and_release :: proc(t: ^testing.T) {
	g: Coordinator_Wake_Guard
	defer coordinator_wake_guard_destroy(&g)
	testing.expect_value(t, coordinator_wake_guard_next_allowed_locked(&g, "s", "a", 5), i64(5))
	testing.expect(t, coordinator_wake_guard_try_locked(&g, "s", "a", 10))
	testing.expect_value(t, coordinator_wake_guard_next_allowed_locked(&g, "s", "a", 20), 10 + COORDINATOR_WAKE_TARGET_MIN_INTERVAL_MS)
	// A stale stamp is not released; the matching one is, with its sender count.
	coordinator_wake_guard_release_locked(&g, "s", "a", 11)
	testing.expect_value(t, len(g.last_target_ms), 1)
	coordinator_wake_guard_release_locked(&g, "s", "a", 10)
	testing.expect_value(t, len(g.last_target_ms), 0)
	testing.expect_value(t, g.sender_windows["s"].count, 0)
	testing.expect_value(t, coordinator_wake_guard_next_allowed_locked(&g, "s", "a", 20), i64(20))
	// The hourly cap defers to the next window instead of failing for good.
	// The window opened at 10; a release does not restart it.
	for i in 0..<COORDINATOR_WAKE_SENDER_MAX_PER_HOUR {
		testing.expect(t, coordinator_wake_guard_try_locked(&g, "s", fmt.tprintf("t_%d", i), 100))
	}
	testing.expect_value(t, coordinator_wake_guard_next_allowed_locked(&g, "s", "b", 200), 10 + COORDINATOR_WAKE_SENDER_WINDOW_MS)
}
