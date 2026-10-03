package taskchain

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import project_service "odin_test:hub/service/project"
import agent_service "odin_test:hub/service/agent"

@(test)
test_subscription_crud_lifecycle :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_sub_crud_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)

	owner := domain.User_ID("user_sub_test")
	cid := domain.Task_Chain_ID("chain_sub_test")
	tid := domain.Task_ID("task_sub_test")

	// Save chain
	_, _, _ = iface.taskchain_save_chain(&tc_repo, domain.Task_Chain{
		chain_id      = cid,
		owner_user_id = owner,
		title         = "Subscription Test Chain",
		publish_state = .Published,
		status        = .Active,
		kind          = "team_work",
		created_at    = "2026-09-28T10:00:00Z",
		updated_at    = "2026-09-28T10:00:00Z",
	})

	// Save task
	_, _, _ = iface.taskchain_save_task(&tc_repo, domain.Task{
		task_id       = tid,
		chain_id      = cid,
		owner_user_id = owner,
		title         = "Subscription Test Task",
		publish_state = .Published,
		status        = .Assigned,
		created_at    = "2026-09-28T10:00:00Z",
		updated_at    = "2026-09-28T10:00:00Z",
	})

	auth_sub1 := contracts.Auth_Context{
		kind              = .Instance_Token,
		user_id           = string(owner),
		agent_instance_id = "inst_subscriber_1",
	}

	auth_no_instance := contracts.Auth_Context{
		kind    = .User_Token,
		user_id = string(owner),
	}

	// 1. Validation failure: missing subscriber agent instance
	_, sub_bad_ok, sub_bad_err := subscribe_taskchain(&svc, auth_no_instance, cid, "chain_status")
	testing.expect(t, !sub_bad_ok, "subscribe without agent instance should fail")
	testing.expect_value(t, sub_bad_err.code, domain.Error_Code.Validation_Failed)

	// 2. Validation failure: invalid event_type
	_, sub_bad_evt_ok, sub_bad_evt_err := subscribe_taskchain(&svc, auth_sub1, cid, "invalid_event")
	testing.expect(t, !sub_bad_evt_ok, "subscribe with invalid event should fail")
	testing.expect_value(t, sub_bad_evt_err.code, domain.Error_Code.Validation_Failed)

	// 3. Create chain subscription
	sub_chain, c_ok, c_err := subscribe_taskchain(&svc, auth_sub1, cid, "chain_status")
	testing.expect(t, c_ok, "subscribe_taskchain should succeed")
	testing.expect_value(t, c_err.code, domain.Error_Code.None)
	testing.expect(t, strings.has_prefix(sub_chain.subscription_id, "sub_"), "subscription_id prefix")
	testing.expect_value(t, sub_chain.subscriber_agent_instance_id, "inst_subscriber_1")
	testing.expect_value(t, sub_chain.chain_id, cid)
	testing.expect_value(t, sub_chain.task_id, domain.Task_ID(""))
	testing.expect_value(t, sub_chain.event_type, "chain_status")

	// 4. Create task subscription
	sub_task, t_ok, t_err := subscribe_task(&svc, auth_sub1, tid, "task_status")
	testing.expect(t, t_ok, "subscribe_task should succeed")
	testing.expect_value(t, t_err.code, domain.Error_Code.None)
	testing.expect(t, strings.has_prefix(sub_task.subscription_id, "sub_"), "subscription_id prefix")
	testing.expect_value(t, sub_task.subscriber_agent_instance_id, "inst_subscriber_1")
	testing.expect_value(t, sub_task.chain_id, cid)
	testing.expect_value(t, sub_task.task_id, tid)
	testing.expect_value(t, sub_task.event_type, "task_status")

	// 5. List subscriptions for the chain
	subs, l_err := list_subscriptions(&svc, auth_sub1, cid)
	testing.expect_value(t, l_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(subs), 2)
	destroy_subscriptions(subs)

	// 6. Idempotent re-subscribe (updates record)
	sub_chain_dupe, cd_ok, cd_err := subscribe_taskchain(&svc, auth_sub1, cid, "chain_status")
	testing.expect(t, cd_ok, "re-subscribe should succeed")
	testing.expect_value(t, cd_err.code, domain.Error_Code.None)
	testing.expect(t, len(sub_chain_dupe.subscription_id) > 0, "has subscription id")

	subs_after_dupe, _ := list_subscriptions(&svc, auth_sub1, cid)
	testing.expect_value(t, len(subs_after_dupe), 2)
	destroy_subscriptions(subs_after_dupe)

	// 7. Unsubscribe task
	rem_task_ok, rem_task_err := unsubscribe_task(&svc, auth_sub1, tid, "task_status")
	testing.expect(t, rem_task_ok, "unsubscribe_task should succeed")
	testing.expect_value(t, rem_task_err.code, domain.Error_Code.None)

	subs_after_rem_t, _ := list_subscriptions(&svc, auth_sub1, cid)
	testing.expect_value(t, len(subs_after_rem_t), 1)
	destroy_subscriptions(subs_after_rem_t)

	// 8. Unsubscribe chain
	rem_chain_ok, rem_chain_err := unsubscribe_taskchain(&svc, auth_sub1, cid, "chain_status")
	testing.expect(t, rem_chain_ok, "unsubscribe_taskchain should succeed")
	testing.expect_value(t, rem_chain_err.code, domain.Error_Code.None)

	subs_after_rem_c, _ := list_subscriptions(&svc, auth_sub1, cid)
	testing.expect_value(t, len(subs_after_rem_c), 0)
	destroy_subscriptions(subs_after_rem_c)
}

@(test)
test_fanout_chain_status_change :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fanout_chain_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)

	owner := domain.User_ID("user_fanout_chain")
	cid := domain.Task_Chain_ID("chain_fanout_1")

	// Register bridge
	_, _, _ = iface.bridge_save_bridge(&br_repo, domain.Bridge{
		bridge_id        = "brg_fanout",
		owner_user_id    = owner,
		machine_hostname = "localhost",
		status           = .Online,
		created_at       = "2026-09-28T10:00:00Z",
		updated_at       = "2026-09-28T10:00:00Z",
	})

	// Register instances
	inst_coord := "inst_coordinator"
	inst_sub_chain := "inst_sub_chain"
	inst_sub_all := "inst_sub_all"
	inst_sub_task_only := "inst_sub_task_only"

	for id in ([]string{inst_coord, inst_sub_chain, inst_sub_all, inst_sub_task_only}) {
		_, _, _ = iface.agent_save_instance(&ag_repo, domain.Agent_Instance{
			agent_instance_id = id,
			owner_user_id     = owner,
			bridge_id         = "brg_fanout",
			runtime_status    = "running",
			created_at        = "2026-09-28T10:00:00Z",
			updated_at        = "2026-09-28T10:00:00Z",
		})
	}

	// Save chain
	_, _, _ = iface.taskchain_save_chain(&tc_repo, domain.Task_Chain{
		chain_id                      = cid,
		owner_user_id                 = owner,
		title                         = "Fanout Test Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "team_work",
		coordinator_agent_instance_id = inst_coord,
		created_at                    = "2026-09-28T10:00:00Z",
		updated_at                    = "2026-09-28T10:00:00Z",
	})

	// Add coordinator member
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = cid,
		agent_instance_id = inst_coord,
		owner_user_id     = owner,
		role              = "coordinator",
		created_at        = "2026-09-28T10:00:00Z",
	})

	// Create subscriptions
	auth_sub_chain := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = inst_sub_chain}
	auth_sub_all := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = inst_sub_all}
	auth_sub_task := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = inst_sub_task_only}

	_, _, _ = subscribe_taskchain(&svc, auth_sub_chain, cid, "chain_status")
	_, _, _ = subscribe_taskchain(&svc, auth_sub_all, cid, "all")
	_, _, _ = subscribe_taskchain(&svc, auth_sub_task, cid, "task_status")

	// Trigger chain status change via coordinator
	auth_coord := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = inst_coord}
	saved_chain, ch_ok, ch_err := change_chain_status(&svc, auth_coord, cid, .Completed)
	testing.expect(t, ch_ok, "change_chain_status should succeed")
	testing.expect_value(t, ch_err.code, domain.Error_Code.None)
	testing.expect_value(t, saved_chain.status, domain.Task_Chain_Status.Completed)

	// Verify command deliveries
	found_sub_chain := false
	found_sub_all := false
	found_task_only := false
	found_coord_sub := false

	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"origin":"subscription"`) && strings.contains(cmd.body_json, `"action":"chain_status_changed"`) {
			if strings.contains(cmd.body_json, inst_sub_chain) {
				found_sub_chain = true
			}
			if strings.contains(cmd.body_json, inst_sub_all) {
				found_sub_all = true
			}
			if strings.contains(cmd.body_json, inst_sub_task_only) {
				found_task_only = true
			}
			if strings.contains(cmd.body_json, inst_coord) {
				found_coord_sub = true
			}
		}
	}

	testing.expect(t, found_sub_chain, "inst_sub_chain should receive chain_status_changed subscription nudge")
	testing.expect(t, found_sub_all, "inst_sub_all should receive chain_status_changed subscription nudge")
	testing.expect(t, !found_task_only, "inst_sub_task_only should NOT receive chain_status_changed")
	testing.expect(t, !found_coord_sub, "actor coordinator should NOT receive self-notification via subscription")
}

@(test)
test_fanout_task_status_change :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_fanout_task_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)

	owner := domain.User_ID("user_fanout_task")
	cid := domain.Task_Chain_ID("chain_fanout_task_1")
	tid := domain.Task_ID("task_fanout_1")
	other_tid := domain.Task_ID("task_fanout_other")

	// Register bridge
	_, _, _ = iface.bridge_save_bridge(&br_repo, domain.Bridge{
		bridge_id        = "brg_fanout_task",
		owner_user_id    = owner,
		machine_hostname = "localhost",
		status           = .Online,
		created_at       = "2026-09-28T10:00:00Z",
		updated_at       = "2026-09-28T10:00:00Z",
	})

	inst_assignee := "inst_worker_assignee"
	inst_sub_task := "inst_subscriber_task"
	inst_sub_chain := "inst_subscriber_chain"
	inst_sub_other_task := "inst_subscriber_other"

	for id in ([]string{inst_assignee, inst_sub_task, inst_sub_chain, inst_sub_other_task}) {
		_, _, _ = iface.agent_save_instance(&ag_repo, domain.Agent_Instance{
			agent_instance_id = id,
			owner_user_id     = owner,
			bridge_id         = "brg_fanout_task",
			runtime_status    = "running",
			created_at        = "2026-09-28T10:00:00Z",
			updated_at        = "2026-09-28T10:00:00Z",
		})
	}

	// Save chain
	_, _, _ = iface.taskchain_save_chain(&tc_repo, domain.Task_Chain{
		chain_id      = cid,
		owner_user_id = owner,
		title         = "Task Fanout Chain",
		publish_state = .Published,
		status        = .Active,
		kind          = "team_work",
		created_at    = "2026-09-28T10:00:00Z",
		updated_at    = "2026-09-28T10:00:00Z",
	})

	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = cid,
		agent_instance_id = inst_assignee,
		owner_user_id     = owner,
		role              = "member",
		created_at        = "2026-09-28T10:00:00Z",
	})

	// Save main task
	_, _, _ = iface.taskchain_save_task(&tc_repo, domain.Task{
		task_id           = tid,
		chain_id          = cid,
		owner_user_id     = owner,
		title             = "Main Task",
		publish_state     = .Published,
		status            = .Assigned,
		assignee_ref_json = fmt.tprintf(`[{{"type":"agent_instance","agent_instance_id":"%s"}}]`, inst_assignee),
		created_at        = "2026-09-28T10:00:00Z",
		updated_at        = "2026-09-28T10:00:00Z",
	})

	// Save other task
	_, _, _ = iface.taskchain_save_task(&tc_repo, domain.Task{
		task_id           = other_tid,
		chain_id          = cid,
		owner_user_id     = owner,
		title             = "Other Task",
		publish_state     = .Published,
		status            = .Assigned,
		created_at        = "2026-09-28T10:00:00Z",
		updated_at        = "2026-09-28T10:00:00Z",
	})

	// Subscriptions
	auth_sub_t := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = inst_sub_task}
	auth_sub_c := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = inst_sub_chain}
	auth_sub_other := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = inst_sub_other_task}

	_, _, _ = subscribe_task(&svc, auth_sub_t, tid, "task_status")
	_, _, _ = subscribe_taskchain(&svc, auth_sub_c, cid, "all")
	_, _, _ = subscribe_task(&svc, auth_sub_other, other_tid, "task_status")

	// Transition main task to In_Progress by assignee
	auth_assignee := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = inst_assignee}
	saved_task, st_ok, st_err := change_task_status(&svc, auth_assignee, tid, .In_Progress)
	testing.expect(t, st_ok, "change_task_status should succeed")
	testing.expect_value(t, st_err.code, domain.Error_Code.None)
	testing.expect_value(t, saved_task.status, domain.Task_Status.In_Progress)

	found_sub_task := false
	found_sub_chain := false
	found_sub_other := false

	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"origin":"subscription"`) && strings.contains(cmd.body_json, `"action":"task_status_changed"`) {
			if strings.contains(cmd.body_json, inst_sub_task) {
				found_sub_task = true
			}
			if strings.contains(cmd.body_json, inst_sub_chain) {
				found_sub_chain = true
			}
			if strings.contains(cmd.body_json, inst_sub_other_task) {
				found_sub_other = true
			}
		}
	}

	testing.expect(t, found_sub_task, "inst_sub_task should receive task_status_changed nudge")
	testing.expect(t, found_sub_chain, "inst_sub_chain (all) should receive task_status_changed nudge")
	testing.expect(t, !found_sub_other, "inst_sub_other_task should NOT receive main task nudge")
}

@(test)
test_deduplication_actor_and_primary_wake_targets :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_dedup_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)

	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)

	br_impl := sqlite.Bridge_Repo_SQLite{conn = &conn}
	br_repo := sqlite.new_bridge_repository(&br_impl, &conn)

	captured_cmds := make([dynamic]project_service.Runtime_Command)
	defer {
		for cmd in captured_cmds do delete(cmd.body_json)
		delete(captured_cmds)
	}
	sink := project_service.Bridge_Command_Sink{
		ctx = rawptr(&captured_cmds),
		send_runtime_command = proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			commands := (^[dynamic]project_service.Runtime_Command)(ctx)
			captured := cmd
			captured.body_json = strings.clone(cmd.body_json)
			append(commands, captured)
			return true, domain.Domain_Error{}
		},
	}

	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service_with_runtime(&tc_repo, &ag_repo, sink, &clock, &ids)

	owner := domain.User_ID("user_dedup")
	cid := domain.Task_Chain_ID("chain_dedup")
	tid := domain.Task_ID("task_dedup")

	// Register bridge
	_, _, _ = iface.bridge_save_bridge(&br_repo, domain.Bridge{
		bridge_id        = "brg_dedup",
		owner_user_id    = owner,
		machine_hostname = "localhost",
		status           = .Online,
		created_at       = "2026-09-28T10:00:00Z",
		updated_at       = "2026-09-28T10:00:00Z",
	})

	inst_assignee := "inst_dedup_assignee"
	inst_reviewer := "inst_dedup_reviewer"
	inst_coord := "inst_dedup_coord"
	inst_external_sub := "inst_dedup_external"

	for id in ([]string{inst_assignee, inst_reviewer, inst_coord, inst_external_sub}) {
		_, _, _ = iface.agent_save_instance(&ag_repo, domain.Agent_Instance{
			agent_instance_id = id,
			owner_user_id     = owner,
			bridge_id         = "brg_dedup",
			runtime_status    = "running",
			created_at        = "2026-09-28T10:00:00Z",
			updated_at        = "2026-09-28T10:00:00Z",
		})
	}

	// Save chain with coordinator
	_, _, _ = iface.taskchain_save_chain(&tc_repo, domain.Task_Chain{
		chain_id                      = cid,
		owner_user_id                 = owner,
		title                         = "Dedup Chain",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "team_work",
		coordinator_agent_instance_id = inst_coord,
		created_at                    = "2026-09-28T10:00:00Z",
		updated_at                    = "2026-09-28T10:00:00Z",
	})

	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = cid,
		agent_instance_id = inst_coord,
		owner_user_id     = owner,
		role              = "coordinator",
		created_at        = "2026-09-28T10:00:00Z",
	})
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = cid,
		agent_instance_id = inst_assignee,
		owner_user_id     = owner,
		role              = "member",
		created_at        = "2026-09-28T10:00:00Z",
	})
	_, _, _ = iface.taskchain_save_member(&tc_repo, domain.Task_Chain_Member{
		chain_id          = cid,
		agent_instance_id = inst_reviewer,
		owner_user_id     = owner,
		role              = "member",
		created_at        = "2026-09-28T10:00:00Z",
	})

	// Save task with explicit assignee and reviewer
	_, _, _ = iface.taskchain_save_task(&tc_repo, domain.Task{
		task_id            = tid,
		chain_id           = cid,
		owner_user_id      = owner,
		title              = "Dedup Task",
		publish_state      = .Published,
		status             = .In_Progress,
		assignee_ref_json  = fmt.tprintf(`[{{"type":"agent_instance","agent_instance_id":"%s"}}]`, inst_assignee),
		reviewer_refs_json = fmt.tprintf(`[{{"type":"agent_instance","agent_instance_id":"%s"}}]`, inst_reviewer),
		created_at         = "2026-09-28T10:00:00Z",
		updated_at         = "2026-09-28T10:00:00Z",
	})

	// Subscribe ALL 4 instances to the task
	for id in ([]string{inst_assignee, inst_reviewer, inst_coord, inst_external_sub}) {
		auth_i := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = id}
		_, _, _ = subscribe_task(&svc, auth_i, tid, "task_status")
	}

	// Clear captured commands from setup
	clear(&captured_cmds)

	// Move task to In_Validation by assignee
	auth_assignee := contracts.Auth_Context{kind = .Instance_Token, user_id = string(owner), agent_instance_id = inst_assignee}
	saved_t, ok_t, err_t := change_task_status(&svc, auth_assignee, tid, .In_Validation)
	testing.expect(t, ok_t, "change_task_status to In_Validation ok")
	testing.expect_value(t, err_t.code, domain.Error_Code.None)
	testing.expect_value(t, saved_t.status, domain.Task_Status.In_Validation)

	// Count subscription-origin notifications
	sub_nudges_assignee := 0
	sub_nudges_reviewer := 0
	sub_nudges_coord := 0
	sub_nudges_external := 0

	for cmd in captured_cmds {
		if strings.contains(cmd.body_json, `"origin":"subscription"`) {
			if strings.contains(cmd.body_json, fmt.tprintf(`"agent_instance_id":"%s"`, inst_assignee)) {
				sub_nudges_assignee += 1
			}
			if strings.contains(cmd.body_json, fmt.tprintf(`"agent_instance_id":"%s"`, inst_reviewer)) {
				sub_nudges_reviewer += 1
			}
			if strings.contains(cmd.body_json, fmt.tprintf(`"agent_instance_id":"%s"`, inst_coord)) {
				sub_nudges_coord += 1
			}
			if strings.contains(cmd.body_json, fmt.tprintf(`"agent_instance_id":"%s"`, inst_external_sub)) {
				sub_nudges_external += 1
			}
		}
	}

	testing.expect_value(t, sub_nudges_assignee, 0)
	testing.expect_value(t, sub_nudges_reviewer, 0)
	testing.expect_value(t, sub_nudges_coord, 0)
	testing.expect_value(t, sub_nudges_external, 1)
}
