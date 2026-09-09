package hub_mem7_seed

// MEM-7 validation seed: builds the REAL hub app-graph against a throwaway /tmp DB
// and plants one AGENT-authored and one USER-authored comment on a task, then exits
// (the sqlite file persists). A separately-launched real ham-hub binary then serves
// this DB over HTTP so the comment serializer (author_display_name / author_user_id)
// can be validated on the wire with curl. Owner = "tanmay" to match the dev
// trusted-proxy identity. Usage: odin run tests/hub_mem7_seed.odin -file ... -- <db>

import "core:fmt"
import "core:os"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("SEED-FAIL:", message); os.exit(1) }

main :: proc() {
	db_path := "/tmp/heimdall-mem7-seed.db"
	if len(os.args) > 1 && os.args[len(os.args)-1] != "" do db_path = os.args[len(os.args)-1]
	_ = os.remove(db_path)

	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{database_path = db_path, migrations_dir = "src/hub/repository/sqlite/migrations", bind_host = "127.0.0.1", port = 0, username_header = "X-authentik-username", display_name_header = "X-authentik-name", email_header = "X-authentik-email", trusted_proxy_cidrs = cidrs[:], auto_provision_users = true, logout_url = "/_dev/logout"})
	check(ok, message)

	owner := domain.User_ID("tanmay")
	now := "2026-09-09T17:00:00Z"

	_, asaved, aerr := iface.agent_save(&graph.repos.agents, domain.Agent{agent_id = "agent_x", owner_user_id = owner, name = "Fixer Bot", slug = "fixer", default_provider = "claude", default_tier = "normal", state = .Active, created_at = now, updated_at = now})
	check(asaved, aerr.message)
	_, isaved, ierr := iface.agent_save_instance(&graph.repos.agents, domain.Agent_Instance{agent_instance_id = "inst_x", owner_user_id = owner, agent_id = "agent_x", bridge_id = "brg_seed", provider = "claude", tier = "normal", chain_id = "chain_m7", runtime_status = "running", startup_status = "ready", activity_status = "idle", display_name = "coder #7", created_at = now, updated_at = now, started_at = now, last_seen_at = now})
	check(isaved, ierr.message)

	_, csaved, cerr := iface.taskchain_save_chain(&graph.repos.taskchains, domain.Task_Chain{chain_id = "chain_m7", owner_user_id = owner, title = "MEM-7 Chain", publish_state = .Published, status = .Active, kind = "team_work", coordinator_agent_instance_id = "inst_x", created_at = now, updated_at = now, published_at = now})
	check(csaved, cerr.message)
	_, tsaved, terr := iface.taskchain_save_task(&graph.repos.taskchains, domain.Task{task_id = "task_m7", chain_id = "chain_m7", owner_user_id = owner, title = "Validate comment authors", publish_state = .Published, status = .In_Progress, assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_x"}`, reviewer_refs_json = "[]", created_at = now, updated_at = now, published_at = now, started_at = now})
	check(tsaved, terr.message)

	// AGENT-authored comment (author_agent_instance_id set) -> serializer resolves display name.
	_, ac_saved, ac_err := iface.taskchain_save_comment(&graph.repos.taskchains, domain.Task_Comment{comment_id = "cmt_agent", task_id = "task_m7", chain_id = "chain_m7", owner_user_id = owner, author_agent_instance_id = "inst_x", body = "agent-authored comment", created_at = now, updated_at = now})
	check(ac_saved, ac_err.message)
	// USER-authored comment (author_agent_instance_id empty) -> serializer leaves display blank; UI shows user id.
	_, uc_saved, uc_err := iface.taskchain_save_comment(&graph.repos.taskchains, domain.Task_Comment{comment_id = "cmt_user", task_id = "task_m7", chain_id = "chain_m7", owner_user_id = owner, author_agent_instance_id = "", body = "user-authored comment", created_at = "2026-09-09T17:01:00Z", updated_at = "2026-09-09T17:01:00Z"})
	check(uc_saved, uc_err.message)

	app.shutdown_graph(&graph)
	fmt.printf("SEED-OK %s\n", db_path)
}
