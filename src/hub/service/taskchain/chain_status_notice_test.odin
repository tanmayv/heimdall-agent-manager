package taskchain

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"

@(test)
test_chain_close_reopen_notices :: proc(t: ^testing.T) {
	for use_update in ([?]bool{false, true}) {
		conn, opened, _ := sqlite.open(":memory:")
		if !testing.expect(t, opened) do return
		defer sqlite.close(&conn)
		migrated, _ := sqlite.run_migrations(&conn)
		if !testing.expect(t, migrated) do return
		tc_impl: sqlite.Taskchain_Repo_SQLite
		ag_impl: sqlite.Agent_Repo_SQLite
		repo := sqlite.new_taskchain_repository(&tc_impl, &conn)
		agents := sqlite.new_agent_repository(&ag_impl, &conn)
		clock := platform.real_clock()
		ids := platform.real_id_generator()
		svc := new_taskchain_service(&repo, &agents, &clock, &ids)
		messages := make([dynamic]string)
		defer {
			for m in messages do delete(m)
			delete(messages)
		}
		svc.bridge_command_sink = project.Bridge_Command_Sink{ctx = &messages, send_runtime_command = proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
			out := cast(^[dynamic]string)ctx
			append(out, strings.clone(cmd.body_json))
			return true, {}
		}}
		_, _, chain_err := iface.taskchain_save_chain(&repo, domain.Task_Chain{
			chain_id = "chain_notices", owner_user_id = "notice_owner", title = "Notice sequence",
			publish_state = .Published, status = .Active, kind = domain.CHAIN_KIND_MIXED_WORK,
		})
		testing.expect(t, chain_err.code == .None)
		for id in ([?]string{"inst_actor", "inst_member", "inst_no_bridge"}) {
			bridge := "bridge_notice" if id != "inst_no_bridge" else ""
			_, _, err := iface.agent_save_instance(&agents, domain.Agent_Instance{
				agent_instance_id = id, owner_user_id = "notice_owner", agent_id = "agt_notice", bridge_id = bridge,
			})
			testing.expect(t, err.code == .None)
			_, _, merr := iface.taskchain_save_member(&repo, domain.Task_Chain_Member{
				chain_id = "chain_notices", owner_user_id = "notice_owner", agent_instance_id = id, agent_id = "agt_notice", role = "worker",
			})
			testing.expect(t, merr.code == .None)
		}
		auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "notice_owner", agent_instance_id = "inst_actor"}
		for status in ([?]domain.Task_Chain_Status{.Archived, .Active, .Active}) {
			ok: bool
			err: domain.Domain_Error
			if use_update {
				value := "archived" if status == .Archived else "active"
				_, ok, err = update_chain(&svc, auth, "chain_notices", Update_Chain_Input{status = value})
			} else {
				_, ok, err = change_chain_status(&svc, auth, "chain_notices", status)
			}
			testing.expect(t, ok)
			testing.expect(t, err.code == .None)
		}
		if !testing.expect_value(t, len(messages), 2) do continue
		testing.expect(t, strings.contains(messages[0], "[Chain Closed]"))
		testing.expect(t, strings.contains(messages[1], "[Chain Reopened]"))
		testing.expect(t, strings.contains(messages[1], `"action":"chain_reopened"`))
		for m in messages {
			testing.expect(t, strings.contains(m, `"target_instance_id":"inst_member"`))
			testing.expect(t, strings.contains(m, "ham-ctl task-chain show chain_notices"))
			testing.expect(t, strings.contains(m, "ham-ctl lease next"))
			testing.expect(t, strings.contains(m, "authoritative"))
		}
	}
}
