package taskchain

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import taskv2 "odin_test:hub/service/taskv2"

// REQ-TV2-2 / REQ-SCHED-3: publishing validates every brief; a missing goal,
// acceptance or assignee each name the task and the missing field. No verify
// command or output contract is ever required.
@(test)
test_publish_requires_goal_acceptance_and_assignee :: proc(t: ^testing.T) {
	conn, open_ok, _ := sqlite.open(":memory:")
	if !testing.expect(t, open_ok, "sqlite open ok") do return
	defer sqlite.close(&conn)
	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)
	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)
	auth := contracts.Auth_Context{kind = .Session, user_id = "user_pub"}
	now := platform.clock_now(&clock)
	_, _, _ = iface.agent_save(&ag_repo, domain.Agent{agent_id = "agt_w", owner_user_id = "user_pub", name = "w", slug = "w", created_at = now, updated_at = now})

	chain, cok, _ := create_chain(&svc, auth, Create_Chain_Input{title = "publish validation"})
	if !testing.expect(t, cok, "chain created") do return

	complete, ok1, e1 := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "ok", brief_json = `{"goal":"do it","acceptance":["tests pass"],"assignee":"agt_w"}`})
	testing.expect(t, ok1, fmt.tprintf("create ok task: %s", e1.message))
	// REQ-SCHED-3: no assignee → refused at create, even on a draft chain.
	_, ok_na, e_na := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "nobody", brief_json = `{"goal":"g","acceptance":["a"]}`})
	testing.expect(t, !ok_na && strings.contains(e_na.details_json, `"code":"assignee_required"`), fmt.tprintf("create without an assignee: %s", e_na.details_json))
	// REQ-SCHED-8: review_roles is refused, naming the replacement.
	_, ok_rr, e_rr := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "roles", brief_json = `{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_roles":["security"]}`})
	testing.expect(t, !ok_rr && strings.contains(e_rr.details_json, `"code":"review_roles_removed"`), fmt.tprintf("review_roles: %s", e_rr.details_json))
	_, ok_rr2, e_rr2 := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "roles2", assignee_agent_id = "agt_w", review_roles = []string{"security"}})
	testing.expect(t, !ok_rr2 && strings.contains(e_rr2.details_json, `"code":"review_roles_removed"`), "review_roles field refused")
	empty, ok3, e3 := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "bare", description = "just a title", assignee_agent_id = "agt_w"})
	testing.expect(t, ok3, fmt.tprintf("create bare task: %s", e3.message))
	fleets, _ := iface.taskchain_list_fleets_by_chain(&tc_repo, chain.chain_id, chain.owner_user_id)
	testing.expect(t, len(fleets) == 1 && fleets[0].agent_id == "agt_w" && !fleets[0].paused, "the assignee gets a plain fleet row")

	// chain publish is atomic: nothing is published, every problem is listed
	_, pok, perr := publish_chain(&svc, auth, chain.chain_id)
	testing.expect(t, !pok, "chain publish refused")
	testing.expect_value(t, perr.code, domain.Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(perr.details_json, `"code":"brief_incomplete"`), "details code")
	testing.expect(t, strings.contains(perr.details_json, fmt.tprintf(`"task_id":"%s"`, empty.task_id)) && strings.contains(perr.details_json, `"acceptance"`) && !strings.contains(perr.details_json, `"verify"`), "bare task missing acceptance (never verify)")
	testing.expect(t, !strings.contains(perr.details_json, string(complete.task_id)), "complete task not listed")
	persisted, _, _ := iface.taskchain_get_chain(&tc_repo, chain.chain_id)
	testing.expect_value(t, persisted.publish_state, domain.Publish_State.Draft)

	// fix: give the bare task a brief → publish succeeds
	_, uok, uerr := update_task(&svc, auth, empty.task_id, Update_Task_Input{brief_json = `{"goal":"g","acceptance":["a"]}`})
	testing.expect(t, uok, fmt.tprintf("update bare task: %s", uerr.message))
	// The assignee is never removed (REQ-SCHED-3).
	_, rok, rerr := update_task(&svc, auth, empty.task_id, Update_Task_Input{brief_json = `{"assignee":null}`})
	testing.expect(t, !rok && strings.contains(rerr.details_json, `"code":"assignee_required"`), fmt.tprintf("clearing the assignee: %s", rerr.details_json))
	_, pok2, perr2 := publish_chain(&svc, auth, chain.chain_id)
	testing.expect(t, pok2, fmt.tprintf("chain publish: %s %s", perr2.message, perr2.details_json))
	// a task created on the LIVE chain is published at once → validated at create
	long_goal := strings.repeat("g", taskv2.BRIEF_GOAL_MAX + 1, context.temp_allocator)
	_, ok4, e4 := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "long", brief_json = strings.concatenate({`{"goal":"`, long_goal, `","acceptance":["a"],"assignee":"agt_w"}`}, context.temp_allocator)})
	testing.expect(t, !ok4 && e4.code == .Validation_Failed && strings.contains(e4.details_json, `"goal"`), fmt.tprintf("goal > 2k refused on a live chain: ok=%v error=%v", ok4, e4))
	_, ok5, e5 := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "bare live", description = "no brief", assignee_agent_id = "agt_w"})
	testing.expect(t, !ok5 && e5.code == .Validation_Failed && strings.contains(e5.details_json, `"acceptance"`), "bare task refused on a live chain")
	// Engine-managed gates are exempt from the brief validator. Gate rows are
	// created by workflow materialization, not the ordinary task create API.
	missing := brief_publish_problems(&svc, chain, domain.Task{kind = .Gate})
	testing.expect_value(t, len(missing), 0)
}

// Fleet rows have no roles (REQ-SCHED-1/2): roles are refused, pause is one
// boolean that edits keep, and reviewers on create are agent ids (plus `user`)
// that get plain fleet rows; the coordinator's agent gets none.
@(test)
test_fleet_rows_have_no_roles_and_reviewers_are_agents :: proc(t: ^testing.T) {
	conn, open_ok, _ := sqlite.open(":memory:")
	if !testing.expect(t, open_ok, "sqlite open ok") do return
	defer sqlite.close(&conn)
	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)
	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)
	auth := contracts.Auth_Context{kind = .Session, user_id = "user_roles"}
	now := platform.clock_now(&clock)
	for id in ([]string{"agt_rev", "agt_sec", "agt_w"}) {
		_, sok, _ := iface.agent_save(&ag_repo, domain.Agent{agent_id = id, owner_user_id = "user_roles", name = id, slug = id, created_at = now, updated_at = now})
		testing.expect(t, sok, "agent saved")
	}
	chain, cok, _ := create_chain(&svc, auth, Create_Chain_Input{title = "roles"})
	if !testing.expect(t, cok, "chain created") do return

	_, rerr := upsert_fleet(&svc, auth, Upsert_Fleet_Input{chain_id = chain.chain_id, agent_id = "agt_sec", capacity = 1, roles = []string{"security"}, has_roles = true})
	testing.expect(t, rerr.code == .Validation_Failed && strings.contains(rerr.details_json, `"code":"fleet_roles_removed"`), fmt.tprintf("fleet roles refused: %s", rerr.details_json))
	row, err := upsert_fleet(&svc, auth, Upsert_Fleet_Input{chain_id = chain.chain_id, agent_id = "agt_sec", capacity = 1})
	testing.expect(t, err.code == .None && !row.paused, fmt.tprintf("plain row: %s", err.message))
	// REQ-TV2-5: capacity < 1 is refused (no silent clamp) and names the pause verb.
	_, cerr := upsert_fleet(&svc, auth, Upsert_Fleet_Input{chain_id = chain.chain_id, agent_id = "agt_sec", capacity = 0})
	testing.expect(t, cerr.code == .Validation_Failed && strings.contains(cerr.message, "fleet pause"), fmt.tprintf("capacity 0 refused: %s", cerr.message))
	// pause / resume the row; edits keep the pause; per-role pause is refused.
	p1, pause_err := set_fleet_pause(&svc, auth, Fleet_Pause_Input{chain_id = chain.chain_id, agent_id = "agt_sec", paused = true})
	testing.expect(t, pause_err.code == .None && p1.paused, fmt.tprintf("pause: %s", pause_err.message))
	kept_pause, _ := upsert_fleet(&svc, auth, Upsert_Fleet_Input{chain_id = chain.chain_id, agent_id = "agt_sec", capacity = 2})
	testing.expect(t, kept_pause.paused, "an edit keeps the pause")
	_, per_role := set_fleet_pause(&svc, auth, Fleet_Pause_Input{chain_id = chain.chain_id, agent_id = "agt_sec", roles = []string{"security"}, paused = false})
	testing.expect(t, per_role.code == .Validation_Failed, "per-role pause refused")
	p2, _ := set_fleet_pause(&svc, auth, Fleet_Pause_Input{chain_id = chain.chain_id, agent_id = "agt_sec", paused = false})
	testing.expect(t, !p2.paused, "resume")

	// reviewers on create: agent ids and `user`; `user` means user approval.
	task, tok, terr := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "rotate",
		brief_json = `{"goal":"g","acceptance":["a"],"assignee":"agt_w","review_focus":{"agt_sec":"check the token store"}}`,
		reviewer_agent_ids = []string{"agt_rev", "agt_sec", "user"}})
	if !testing.expect(t, tok, fmt.tprintf("create: %s", terr.message)) do return
	testing.expect(t, strings.contains(task.brief_json, `"reviewers":["agt_rev","agt_sec","user"]`), fmt.tprintf("brief names the reviewers: %s", task.brief_json))
	testing.expect(t, strings.contains(task.brief_json, `"review_focus":{"agt_sec":"check the token store"}`), "review_focus kept")
	testing.expect(t, task.requires_user_approval, "`user` among the reviewers means user approval")
	fleets, _ := iface.taskchain_list_fleets_by_chain(&tc_repo, chain.chain_id, chain.owner_user_id)
	testing.expect_value(t, len(fleets), 3) // agt_sec, agt_w, agt_rev
	// The assignee cannot review its own task.
	_, aok, aerr := create_task(&svc, auth, Create_Task_Input{chain_id = chain.chain_id, title = "self", brief_json = `{"goal":"g","acceptance":["a"],"assignee":"agt_w","reviewers":["agt_w"]}`})
	testing.expect(t, !aok && strings.contains(aerr.details_json, `"code":"reviewer_is_assignee"`), fmt.tprintf("self review: %s", aerr.details_json))
	_, pok, perr := publish_chain(&svc, auth, chain.chain_id)
	testing.expect(t, pok, fmt.tprintf("publish: %s %s", perr.message, perr.details_json))
}
