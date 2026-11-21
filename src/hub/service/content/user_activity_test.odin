package content

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

// Coordinator idle-stop resets (REQ-CIS-1): only user chat (and the action
// cards and MCP chains.message that reuse deliver_user_message) reports user
// activity; the agent's own messages and agent-to-agent messages never do.

User_Activity_Capture :: struct {
	ids: [dynamic]string,
}

user_activity_capture :: proc(ctx: rawptr, instance_id: string) {
	cap := (^User_Activity_Capture)(ctx)
	append(&cap.ids, strings.clone(instance_id))
}

UA_OWNER :: domain.User_ID("u_user_activity")

@(test)
test_user_activity_hook_fires_for_user_chat_only :: proc(t: ^testing.T) {
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
	now := platform.clock_now(&clock)
	for pair in ([][2]string{{"chat_ua_coord", "inst_ua_coord"}, {"chat_ua_worker", "inst_ua_worker"}}) {
		_, inst_ok, inst_err := iface.agent_save_instance(&agent_repo, domain.Agent_Instance{agent_instance_id = pair[1], owner_user_id = UA_OWNER, agent_id = "agt_ua", bridge_id = "brg_ua", runtime_status = "running", conversation_id = pair[0], created_at = now, updated_at = now})
		if !testing.expectf(t, inst_ok, "save instance: %s", inst_err.message) do return
		_, conv_ok, conv_err := iface.content_save_conversation(&content_repo, domain.Chat_Conversation{conversation_id = pair[0], owner_user_id = UA_OWNER, agent_id = "agt_ua", agent_instance_id = pair[1], title = "t", title_source = "default", created_at = now, updated_at = now})
		if !testing.expectf(t, conv_ok, "save conversation: %s", conv_err.message) do return
	}
	cap: User_Activity_Capture
	svc.user_activity = User_Activity_Hook{ctx = &cap, run = user_activity_capture}
	user := contracts.Auth_Context{kind = .Session, user_id = string(UA_OWNER)}

	_, sent, err := send_message(&svc, user, "chat_ua_coord", Message_Input{body = "status?"})
	if !testing.expectf(t, sent, "user send: %s", err.message) do return
	if !testing.expect_value(t, len(cap.ids), 1) do return
	testing.expect_value(t, cap.ids[0], "inst_ua_coord")

	// The coordinator answering the user, and a worker messaging it, are not user events.
	_, replied, rerr := send_agent_message(&svc, contracts.Auth_Context{kind = .Instance_Token, user_id = string(UA_OWNER), agent_instance_id = "inst_ua_coord"}, "inst_ua_coord", Message_Input{body = "working"})
	testing.expectf(t, replied, "agent reply: %s", rerr.message)
	_, relayed, aerr := send_agent_to_agent(&svc, contracts.Auth_Context{kind = .Instance_Token, user_id = string(UA_OWNER), agent_instance_id = "inst_ua_worker"}, "inst_ua_coord", Message_Input{body = "done"})
	testing.expectf(t, relayed, "agent to agent: %s", aerr.message)
	testing.expect_value(t, len(cap.ids), 1)
}
