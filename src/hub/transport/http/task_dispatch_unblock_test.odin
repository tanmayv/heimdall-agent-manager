package http

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"

@(test)
test_dispatch_unblock_http_coordinator_and_owner_auth :: proc(t: ^testing.T) {
	f := wire_setup(t, "dispatch_unblock")
	defer wire_teardown(f)
	engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.th.task_engine = &engine
	chain, _, _ := iface.taskchain_get_chain(&f.tc_repo, f.chain_id)
	chain.publish_state = .Published
	_, _, _ = iface.taskchain_save_chain(&f.tc_repo, chain)
	task := domain.Task{task_id = "task_dispatch_auth", chain_id = f.chain_id, owner_user_id = f.owner, title = "Dispatch auth", publish_state = .Published, kind = .Task, state = .Backlog, brief_json = `{"goal":"g"}`, blocked_on_json = `{"kind":"dispatch","reason":"codex/model on bridge failed to start: exit 1"}`}
	_, _, _ = iface.taskchain_save_task(&f.tc_repo, task)
	_, _, _ = taskv2.append_event(&f.tc_repo, &f.clock, task, taskv2.hub_actor(), taskv2.EV_PUBLISHED, `{}`)
	_, _, _ = taskv2.append_event(&f.tc_repo, &f.clock, task, taskv2.hub_actor(), taskv2.EV_BLOCKED, `{"dispatch_failed":true,"waiting_on":{"kind":"dispatch","reason":"exit 1"}}`)
	path := fmt.aprintf("/api/v1/task-chains/%s/tasks/%s/answer", f.chain_id, task.task_id)
	defer delete(path)
	req := wire_cookie_request(f, "POST", path, `{"note":"repaired provider"}`)
	req.headers = f.agent_headers[:]
	// REQ-AUTHZ-2: another owner cannot see the task, let alone unblock it.
	other_req := wire_cookie_request(f, "POST", path, `{"note":"not yours"}`)
	other_req.headers = http_test_login(t, &f.auth_svc, "unblock_foreign_owner")
	denied := answer_task_handler(&f.th, other_req)
	testing.expect_value(t, denied.status, 404)
	still, _, _ := iface.taskchain_get_task(&f.tc_repo, task.task_id)
	testing.expect(t, still.blocked_on_json != "", "cross-owner cannot unblock")
	// Any same-owner agent instance may clear it, even with no chain membership.
	_, _ = iface.taskchain_remove_member(&f.tc_repo, f.chain_id, f.instance_id, f.owner)
	allowed := answer_task_handler(&f.th, req)
	testing.expect_value(t, allowed.status, 200)
	testing.expect(t, strings.contains(allowed.body, `"state":"ready"`) && strings.contains(allowed.body, `"blocked_on":null`), "same-owner non-member clears dispatch block")
	// The same existing route remains available to the authenticated owner.
	task.blocked_on_json = `{"kind":"agent_not_running","reason":"exit 2"}`
	_, _, _ = iface.taskchain_save_task(&f.tc_repo, task)
	_, _, _ = taskv2.append_event(&f.tc_repo, &f.clock, task, taskv2.hub_actor(), taskv2.EV_BLOCKED, `{"dispatch_failed":true,"waiting_on":{"kind":"agent_not_running","reason":"exit 2"}}`)
	owner_resp := answer_task_handler(&f.th, wire_cookie_request(f, "POST", path, `{}`))
	testing.expect_value(t, owner_resp.status, 200)
}
