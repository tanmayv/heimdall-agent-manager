package sqlite

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

actions_repo_test :: proc(t: ^testing.T, scenario: proc(^testing.T, iface.Action_Repository, ^Conn)) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	actions_repo_test_scenario(t, scenario)
	testing.expect_value(t, len(track.allocation_map), 0)
}
actions_repo_test_scenario :: proc(t: ^testing.T, scenario: proc(^testing.T, iface.Action_Repository, ^Conn)) {
	conn, opened, err := open(":memory:")
	if !testing.expect(t, opened, err.message) do return
	defer close(&conn)
	ok, migration_err := run_migrations(&conn)
	if !testing.expect(t, ok, migration_err.message) do return
	impl: Action_Repo_SQLite
	repo := new_action_repository(&impl, &conn)
	a := domain.Action{id="act_a",owner_user_id="owner",name="A",prompt_text="prompt",target_kind="agent",instance_strategy="reuse",placement_selector="first",enabled=true,min_interval_s=30,created_at="2026-01-01T00:00:00Z",updated_at="2026-01-01T00:00:00Z"}
	if !testing.expect_value(t, repo.save(repo.ctx,a).code, domain.Error_Code.None) do return
	scenario(t,repo,&conn)
}
actions_test_run :: proc(id, state: string) -> domain.Action_Run {
	return {run_id=id, action_id="act_a",trigger_id="trg_a",owner_user_id="owner",occurrence_key=id,event_type="chain.state",event_params_json="{}",state=state,rule_position=-1,created_at="2026-01-01T00:00:00Z"}
}
@(test)
test_action_repo_round_trip :: proc(t: ^testing.T) {actions_repo_test(t, actions_round_trip)}
actions_round_trip :: proc(t: ^testing.T, repo: iface.Action_Repository, conn: ^Conn) {
	a, found, err := repo.get(repo.ctx,"act_a")
	defer domain.action_destroy(&a)
	testing.expect(t, found && err.code == .None)
	testing.expect_value(t,a.name,"A")
	testing.expect_value(t,repo.save(repo.ctx,a).code,domain.Error_Code.None)
	all, list_err := repo.list(repo.ctx,"owner")
	defer {for &v in all do domain.action_destroy(&v); delete(all)}
	testing.expect(t,list_err.code == .None && len(all)==1)
	testing.expect_value(t,repo.rules_replace(repo.ctx,"act_a",{{0,"*","*","*"}}).code,domain.Error_Code.None)
	rules, rules_err := repo.rules_list(repo.ctx,"act_a")
	defer domain.action_rules_destroy(rules)
	testing.expect(t,rules_err.code == .None && len(rules)==1 && rules[0].model=="*")
	trg := domain.Action_Trigger{trigger_id="trg_a",action_id="act_a",owner_user_id="owner",kind="event",config_json="{}",event_type="chain.state",subject_filter="ev.owner.chain.*.state",match_key="",data_filter_json="{}",enabled=true,rev=1,created_at=a.created_at,updated_at=a.updated_at}
	testing.expect_value(t,repo.trigger_save(repo.ctx,trg).code,domain.Error_Code.None)
	got, trigger_found, trigger_err := repo.trigger_get(repo.ctx,"trg_a")
	defer domain.action_trigger_destroy(&got)
	testing.expect(t,trigger_found && trigger_err.code == .None && got.rev==1)
	inserted, insert_err := repo.run_insert(repo.ctx,actions_test_run("arun_a","routed"))
	testing.expect(t,inserted && insert_err.code == .None)
	open, open_found, open_err := repo.run_open(repo.ctx,"act_a")
	defer domain.action_run_destroy(&open)
	testing.expect(t,open_found && open_err.code == .None && open.state=="routed")
	due, due_err := repo.runs_due(repo.ctx,"2099-01-01T00:00:00Z",100)
	defer domain.action_runs_destroy(due)
	testing.expect(t,due_err.code == .None && len(due)==0)
	testing.expect_value(t,repo.trigger_delete(repo.ctx,"trg_a").code,domain.Error_Code.None)
	gone, still_found, _ := repo.trigger_get(repo.ctx,"trg_a")
	defer domain.action_trigger_destroy(&gone)
	testing.expect(t,!still_found)
	testing.expect_value(t,repo.trigger_save(repo.ctx,trg).code,domain.Error_Code.None)
	testing.expect(t,exec(conn,"PRAGMA foreign_keys=OFF;"))
	testing.expect_value(t,repo.delete_action(repo.ctx,"act_a").code,domain.Error_Code.None)
	testing.expect_value(t,actions_reset_text(conn,"SELECT count(*) FROM action_target_rules;"),"0")
	testing.expect_value(t,actions_reset_text(conn,"SELECT count(*) FROM action_triggers;"),"0")
	testing.expect_value(t,actions_reset_text(conn,"SELECT count(*) FROM action_runs;"),"0")
}
@(test)
test_action_runs_one_open :: proc(t: ^testing.T) {actions_repo_test(t, actions_one_open)}
actions_one_open :: proc(t: ^testing.T, repo: iface.Action_Repository, conn: ^Conn) {
	first := actions_test_run("one","queued")
	inserted, err := repo.run_insert(repo.ctx,first)
	testing.expect(t,inserted && err.code == .None)
	inserted, err = repo.run_insert(repo.ctx,first)
	testing.expect(t,!inserted && err.code == .None)
	inserted, err = repo.run_insert(repo.ctx,actions_test_run("two","queued"))
	testing.expect(t,!inserted && err.code != .None)
	first.state="routed"
	changed, trans_err := repo.run_transition(repo.ctx,first,"queued")
	testing.expect(t,changed && trans_err.code == .None)
	inserted, err = repo.run_insert(repo.ctx,actions_test_run("three","deferred"))
	testing.expect(t,!inserted && err.code != .None)
}
@(test)
test_run_transition_cas :: proc(t: ^testing.T) {actions_repo_test(t, actions_cas)}
actions_cas :: proc(t: ^testing.T, repo: iface.Action_Repository, conn: ^Conn) {
	run := actions_test_run("one","queued")
	_, _ = repo.run_insert(repo.ctx,run)
	run.state="failed"; run.reason="changed"
	changed, err := repo.run_transition(repo.ctx,run,"deferred")
	testing.expect(t,!changed && err.code == .None)
	stored, found, get_err := repo.run_get(repo.ctx,"one")
	defer domain.action_run_destroy(&stored)
	testing.expect(t,found && get_err.code == .None && stored.state=="queued" && stored.reason=="")
}
@(test)
test_runs_prune :: proc(t: ^testing.T) {actions_repo_test(t, actions_prune)}
actions_prune :: proc(t: ^testing.T, repo: iface.Action_Repository, conn: ^Conn) {
	for i in 0..<205 {
		run := actions_test_run(fmt.tprintf("run_%03d",i),"delivered")
		run.created_at=fmt.tprintf("2026-01-01T00:%02d:%02dZ",i/60,i%60)
		inserted, err := repo.run_insert(repo.ctx,run)
		testing.expect(t,inserted && err.code == .None)
	}
	old_open := actions_test_run("open","routed")
	old_open.created_at="2020-01-01T00:00:00Z"
	_, _ = repo.run_insert(repo.ctx,old_open)
	testing.expect_value(t,repo.runs_prune(repo.ctx,"act_a",200,"2025-01-01T00:00:00Z").code,domain.Error_Code.None)
	testing.expect_value(t,actions_reset_text(conn,"SELECT count(*) FROM action_runs;"),"201")
	testing.expect_value(t,actions_reset_text(conn,"SELECT min(created_at) FROM action_runs WHERE state='delivered';"),"2026-01-01T00:00:05Z")
	testing.expect_value(t,repo.runs_prune(repo.ctx,"act_a",200,"2027-01-01T00:00:00Z").code,domain.Error_Code.None)
	testing.expect_value(t,actions_reset_text(conn,"SELECT count(*) FROM action_runs;"),"1")
}
@(test)
test_triggers_match_reads_only_matching_keys :: proc(t: ^testing.T) {actions_repo_test(t, actions_matching_keys)}
actions_matching_keys :: proc(t: ^testing.T, repo: iface.Action_Repository, conn: ^Conn) {
	for i in 0..<1000 {
		id := fmt.tprintf("trg_%d",i)
		key := fmt.tprintf("ev.owner.sched.%s",id)
		trg := domain.Action_Trigger{trigger_id=id,action_id="act_a",owner_user_id="owner",kind="schedule",config_json="{}",event_type="schedule.fired",subject_filter=key,match_key=key,data_filter_json="{}",enabled=true,rev=1,created_at="now",updated_at="now"}
		testing.expect_value(t,repo.trigger_save(repo.ctx,trg).code,domain.Error_Code.None)
	}
	testing.expect_value(t,repo.trigger_save(repo.ctx,{trigger_id="wild",action_id="act_a",owner_user_id="owner",kind="event",config_json="{}",event_type="chain.state",subject_filter="ev.owner.chain.*.state",data_filter_json="{}",enabled=true,rev=1,created_at="now",updated_at="now"}).code,domain.Error_Code.None)
	rows, err := repo.triggers_match(repo.ctx,"owner","schedule.fired","ev.owner.sched.trg_500")
	defer domain.action_triggers_destroy(rows)
	testing.expect(t,err.code == .None && len(rows)==1)
	if len(rows)==1 do testing.expect_value(t,rows[0].trigger_id,"trg_500")
}
actions_query_plans_scenario :: proc(t: ^testing.T) {actions_repo_test(t, actions_index_plans)}
actions_index_plans :: proc(t: ^testing.T, repo: iface.Action_Repository, conn: ^Conn) {
	queries := [?]string{ACTIONS_SQL_TRIGGERS_MATCH,ACTIONS_SQL_GET,ACTIONS_SQL_RUN_OPEN,ACTIONS_SQL_RUN_INSERT,ACTIONS_SQL_RUNS_PRUNE,ACTIONS_SQL_RUNS_DUE,ACTIONS_SQL_RUNS_DEFERRED,ACTIONS_SQL_RUN_LAST_STARTED_AT,ACTIONS_SQL_RULES_LIST}
	for query in queries {
		stmt: sqlite3_stmt
		sql := strings.concatenate({"EXPLAIN QUERY PLAN ",query},context.temp_allocator)
		if !testing.expect_value(t,sqlite3_prepare_v2(conn.db,strings.clone_to_cstring(sql,context.temp_allocator),-1,&stmt,nil),SQLITE_OK) do continue
		for sqlite3_step(stmt)==SQLITE_ROW {
			detail := column_text_unowned(stmt,3)
			if strings.contains(detail,"SCAN") {
				testing.expect(t,strings.contains(detail,"USING INDEX") || strings.contains(detail,"USING COVERING INDEX"),detail)
			}
		}
		sqlite3_finalize(stmt)
	}
}

