package content

import "core:fmt"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"

// Regression: these lookups read a capped owner-wide page (500 instances,
// 200 conversations) and filtered it in memory, so rows past the cap were
// invisible. The target rows here are the oldest, behind 650 newer rows.
@(test)
test_instance_and_conversation_lookups_find_rows_past_legacy_caps :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := sqlite.open(":memory:"); if !testing.expect(t, opened) do return
	defer sqlite.close(&conn)
	migrated, _ := sqlite.run_migrations(&conn); if !testing.expect(t, migrated) do return
	testing.expect(t, sqlite.exec(&conn, "PRAGMA foreign_keys=OFF;"))
	ai: sqlite.Agent_Repo_SQLite; agents := sqlite.new_agent_repository(&ai, &conn)
	ci: sqlite.Content_Repo_SQLite; contents := sqlite.new_content_repository(&ci, &conn)

	target := domain.Agent_Instance{agent_instance_id = "target", owner_user_id = "owner", agent_id = "agent", bridge_id = "bridge", project_id = "proj", conversation_id = "target_conversation", runtime_status = "idle", kind = "agent", runtime_transport = "pty", created_at = "2000-01-01T00:00:00Z", updated_at = "2000-01-01T00:00:00Z"}
	_, saved, err := iface.agent_save_instance(&agents, target)
	if !testing.expect(t, saved, err.message) do return
	_, saved, err = iface.content_save_conversation(&contents, {conversation_id = "target_conversation", owner_user_id = "owner", agent_instance_id = "target", agent_id = "agent", created_at = "2000-01-01T00:00:00Z", updated_at = "2000-01-01T00:00:00Z"})
	if !testing.expect(t, saved, err.message) do return
	for i in 0 ..< 650 {
		id := fmt.tprintf("noise%04d", i)
		at := fmt.tprintf("2026-01-01T00:%02d:%02dZ", i / 60, i % 60)
		_, ok, e := iface.agent_save_instance(&agents, {agent_instance_id = id, owner_user_id = "owner", agent_id = "other", bridge_id = "bridge2", project_id = "proj2", runtime_status = "stopped", kind = "agent", runtime_transport = "pty", created_at = at, updated_at = at})
		if !testing.expect(t, ok, e.message) do return
		_, ok, e = iface.content_save_conversation(&contents, {conversation_id = id, owner_user_id = "owner", agent_instance_id = id, agent_id = "other", created_at = at, updated_at = at})
		if !testing.expect(t, ok, e.message) do return
	}
	auth := contracts.Auth_Context{kind = .Internal_User, user_id = "owner"}

	agent_svc := agent_service.Agent_Service{agents = &agents, content = &contents}
	for filter in ([?]agent_service.List_Instances_Filter{
		{agent_id = "agent"},
		{bridge_id = "bridge"},
		{project_id = "proj"},
		{runtime_status = "idle"},
		{runtime_status = "live"},
		{agent_id = "agent", bridge_id = "bridge", runtime_status = "active"},
	}) {
		rows, lerr := agent_service.list_instances_filtered(&agent_svc, auth, filter, 50, "")
		if testing.expectf(t, lerr.code == .None && len(rows) == 1, "filter %v: err=%v rows=%d", filter, lerr.code, len(rows)) {
			testing.expect_value(t, rows[0].agent_instance_id, "target")
		}
	}
	all, aerr := agent_service.list_instances_filtered(&agent_svc, auth, {bridge_id = "bridge2"}, 1000, "")
	testing.expect(t, aerr.code == .None && len(all) == 650)

	// ensure_instance_conversation must reuse the existing conversation, not create a duplicate.
	ensured, ensured_ok, eerr := agent_service.ensure_instance_conversation(&agent_svc, target)
	if testing.expect(t, ensured_ok, eerr.message) do testing.expect_value(t, ensured.conversation_id, "target_conversation")

	content_svc := Content_Service{content = &contents, agents = &agents}
	c, found, cerr := get_conversation_by_instance(&content_svc, auth, "target")
	if testing.expect(t, found, cerr.message) do testing.expect_value(t, c.conversation_id, "target_conversation")
	_, found, cerr = get_conversation_by_instance(&content_svc, contracts.Auth_Context{kind = .Internal_User, user_id = "other_owner"}, "target")
	testing.expect(t, !found && cerr.code == .Not_Found)

	bound, berr := conversation_instance_binding_valid(&content_svc, "owner", Chat_Input{agent_instance_id = "target", agent_id = "agent"})
	testing.expect(t, !bound && berr.code == .Conflict, "a second conversation for the instance must be refused")
}
