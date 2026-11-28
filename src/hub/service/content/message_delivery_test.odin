package content

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import project_service "odin_test:hub/service/project"

MD_OWNER :: domain.User_ID("u_message_delivery")

@(private = "file")
md_send_ok :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) { return true, {} }

// D5: send_message propagates the delivery result. A message to a stopped or
// dead agent is stored and pending with a reason, never accepted; only a
// running, ready agent whose bridge took the notice is accepted.
@(test)
test_send_message_to_stopped_agent_is_pending :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened, "open db") do return
	defer sqlite.close(&conn)
	migrated, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations") do return
	content_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	agent_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	chain_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	content_repo := sqlite.new_content_repository(&content_impl, &conn)
	agent_repo := sqlite.new_agent_repository(&agent_impl, &conn)
	chain_repo := sqlite.new_taskchain_repository(&chain_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_content_service(&content_repo, &agent_repo, nil, nil, &chain_repo, &clock, &ids)
	svc.bridge_command_sink = {send_runtime_command = md_send_ok}
	now := platform.clock_now(&clock)
	Case :: struct { id, runtime, startup: string, state: Message_Delivery_State, reason: string }
	cases := []Case{
		{"inst_md_ready", "running", "ready", .Accepted, ""},
		{"inst_md_stopped", "stopped", "stopped", .Pending, "agent_not_running"},
		{"inst_md_failed", "failed", "failed", .Pending, "agent_not_running"},
		{"inst_md_stopping", "stopping", "ready", .Pending, "agent_not_running"},
		{"inst_md_launching", "launching", "starting", .Pending, "agent_starting"},
		{"inst_md_idle", "idle", "ready", .Accepted, ""},
	}
	user := contracts.Auth_Context{kind = .Session, user_id = string(MD_OWNER)}
	for c in cases {
		chat := c.id
		_, inst_ok, inst_err := iface.agent_save_instance(&agent_repo, domain.Agent_Instance{agent_instance_id = c.id, owner_user_id = MD_OWNER, agent_id = "agt_md", bridge_id = "brg_md", runtime_status = c.runtime, startup_status = c.startup, conversation_id = chat, created_at = now, updated_at = now})
		if !testing.expectf(t, inst_ok, "save instance: %s", inst_err.message) do return
		_, conv_ok, conv_err := iface.content_save_conversation(&content_repo, domain.Chat_Conversation{conversation_id = chat, owner_user_id = MD_OWNER, agent_id = "agt_md", agent_instance_id = c.id, title = "t", title_source = "default", created_at = now, updated_at = now})
		if !testing.expectf(t, conv_ok, "save conversation: %s", conv_err.message) do return
		m, delivery, sent, err := send_message_delivered(&svc, user, chat, Message_Input{body = "hello"})
		if !testing.expectf(t, sent, "%s: send: %s", c.id, err.message) do continue
		testing.expectf(t, m.message_id != "", "%s: the message is stored", c.id)
		testing.expectf(t, delivery.state == c.state && delivery.reason == c.reason, "%s: delivery %v/%q, want %v/%q", c.id, delivery.state, delivery.reason, c.state, c.reason)
	}
	// A running agent whose bridge cannot be reached is pending too.
	svc.bridge_command_sink = {}
	_, delivery, sent, _ := send_message_delivered(&svc, user, "inst_md_ready", Message_Input{body = "again"})
	testing.expect(t, sent && delivery.state == .Pending && delivery.reason == "bridge_offline", "an unreachable bridge leaves the message pending")
}
