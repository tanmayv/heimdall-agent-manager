package http

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"

// F1: POST …/tasks/{id}/start-agent — the owner and the chain coordinator reach
// the engine (a task not waiting on its agent answers 409); a worker is refused
// (403); a task in another chain is not reachable through this chain's path.
@(test)
test_start_agent_http_route_auth :: proc(t: ^testing.T) {
	f := wire_setup(t, "task_start_agent")
	defer wire_teardown(f)
	engine := taskv2.new_service(&f.tc_repo, &f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.th.task_engine = &engine
	task := domain.Task{task_id = "task_start_http", chain_id = f.chain_id, owner_user_id = f.owner, title = "Start", publish_state = .Published, kind = .Task, state = .Ready, brief_json = `{"goal":"g","review_roles":[]}`}
	_, _, _ = iface.taskchain_save_task(&f.tc_repo, task)

	path := fmt.aprintf("/api/v1/task-chains/%s/tasks/%s/start-agent", f.chain_id, task.task_id)
	defer delete(path)
	_, _, _ = iface.taskchain_save_member(&f.tc_repo, domain.Task_Chain_Member{chain_id = f.chain_id, owner_user_id = f.owner, agent_instance_id = f.instance_id, role = "worker"})
	req := wire_cookie_request(f, "POST", path, `{}`)
	req.headers = f.agent_headers[:]
	denied := start_task_agent_handler(&f.th, req)
	testing.expect_value(t, denied.status, 403)

	owner := start_task_agent_handler(&f.th, wire_cookie_request(f, "POST", path, `{}`))
	testing.expect_value(t, owner.status, 409)
	testing.expect(t, strings.contains(owner.body, "no longer waiting for its agent"), owner.body)

	_, _, _ = iface.taskchain_save_member(&f.tc_repo, domain.Task_Chain_Member{chain_id = f.chain_id, owner_user_id = f.owner, agent_instance_id = f.instance_id, role = "coordinator"})
	alias := fmt.aprintf("/api/v1/tasks/%s/start-agent", task.task_id)
	defer delete(alias)
	creq := wire_cookie_request(f, "POST", alias, `{}`)
	creq.headers = f.agent_headers[:]
	coord := start_task_agent_handler(&f.th, creq)
	testing.expect_value(t, coord.status, 409)

	wrong := fmt.aprintf("/api/v1/task-chains/%s/tasks/%s/start-agent", "chain_other", task.task_id)
	defer delete(wrong)
	missing := start_task_agent_handler(&f.th, wire_cookie_request(f, "POST", wrong, `{}`))
	testing.expect_value(t, missing.status, 404)
}
