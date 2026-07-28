package hub_phase3_owner_scope_test

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"
import taskchain_service "odin_test:hub/service/taskchain"
import platform "odin_test:hub/platform"

Fake_Repo :: struct {
	projects: [8]domain.Project,
	project_count: int,
	chains: [8]domain.Task_Chain,
	chain_count: int,
	tasks: [8]domain.Task,
	task_count: int,
}

fixed_clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
fixed_id_generate :: proc(ctx: rawptr, prefix: string) -> string {
	repo := (^Fake_Repo)(ctx)
	return strings.concatenate({prefix, fmt.tprintf("%d", repo.project_count + repo.chain_count + repo.task_count + 1)})
}

proj_get :: proc(ctx: rawptr, project_id: domain.Project_ID) -> (domain.Project, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.project_count { if repo.projects[i].project_id == project_id do return repo.projects[i], true, domain.Domain_Error{} }
	return domain.Project{}, false, domain.domain_error(.Not_Found, "project not found")
}
proj_save :: proc(ctx: rawptr, project: domain.Project) -> (domain.Project, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx); repo.projects[repo.project_count] = project; repo.project_count += 1; return project, true, domain.Domain_Error{}
}
proj_update :: proc(ctx: rawptr, project: domain.Project) -> (domain.Project, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.project_count { if repo.projects[i].project_id == project.project_id { repo.projects[i] = project; return project, true, domain.Domain_Error{} } }
	return domain.Project{}, false, domain.domain_error(.Not_Found, "project not found")
}
proj_list_by_owner :: proc(ctx: rawptr, owner_user_id: domain.User_ID, limit: int, cursor: string) -> ([]domain.Project, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	out := make([dynamic]domain.Project)
	for i in 0..<repo.project_count { if repo.projects[i].owner_user_id == owner_user_id do append(&out, repo.projects[i]) }
	return out[:], domain.Domain_Error{}
}

chain_get :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.chain_count { if repo.chains[i].chain_id == chain_id do return repo.chains[i], true, domain.Domain_Error{} }
	return domain.Task_Chain{}, false, domain.domain_error(.Not_Found, "chain not found")
}
chain_save :: proc(ctx: rawptr, chain: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx); repo.chains[repo.chain_count] = chain; repo.chain_count += 1; return chain, true, domain.Domain_Error{}
}
task_save :: proc(ctx: rawptr, task: domain.Task) -> (domain.Task, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx); repo.tasks[repo.task_count] = task; repo.task_count += 1; return task, true, domain.Domain_Error{}
}
task_get :: proc(ctx: rawptr, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	repo := (^Fake_Repo)(ctx)
	for i in 0..<repo.task_count { if repo.tasks[i].task_id == task_id do return repo.tasks[i], true, domain.Domain_Error{} }
	return domain.Task{}, false, domain.domain_error(.Not_Found, "task not found")
}

main :: proc() {
	repo_data: Fake_Repo
	clock := platform.Clock{ctx = nil, now = fixed_clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&repo_data), generate = fixed_id_generate}
	project_repo := iface.Project_Repository{ctx = rawptr(&repo_data), get = proj_get, save = proj_save, update = proj_update, list_by_owner = proj_list_by_owner}
	task_repo := iface.Taskchain_Repository{ctx = rawptr(&repo_data), get_chain = chain_get, save_chain = chain_save, save_task = task_save, get_task = task_get}
	projects := project_service.new_project_service(&project_repo, nil, &clock, &ids)
	taskchains := taskchain_service.new_taskchain_service(&task_repo, nil, &clock, &ids)
	auth_a := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}
	auth_b := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "bob"}

	proj_a, ok, err := project_service.create(&projects, auth_a, project_service.Create_Project_Input{name = "A", default_path = "/a", owner_user_id = "bob"})
	check(ok, err.message)
	check(proj_a.owner_user_id == domain.User_ID("alice"), "create must set owner from auth, not input owner_user_id")
	_, b_read_ok, b_read_err := project_service.get(&projects, auth_b, proj_a.project_id)
	check(!b_read_ok && b_read_err.code == .Not_Found, "cross-user project read must be hidden as not_found")
	list_a, list_err := project_service.list(&projects, auth_a)
	check(list_err.code == .None && len(list_a) == 1, "owner list should include own project")
	list_b, list_b_err := project_service.list(&projects, auth_b)
	check(list_b_err.code == .None && len(list_b) == 0, "owner list should exclude other user project")
	_, mut_ok, mut_err := project_service.update(&projects, auth_a, proj_a.project_id, project_service.Update_Project_Input{name = "evil", owner_user_id = "bob"})
	check(!mut_ok && mut_err.code == .Conflict, "owner_user_id update must be rejected")

	chain_a, chain_ok, chain_err := taskchain_service.create_chain(&taskchains, auth_a, taskchain_service.Create_Chain_Input{title = "chain", owner_user_id = "bob"})
	check(chain_ok, chain_err.message)
	check(chain_a.owner_user_id == domain.User_ID("alice"), "chain owner must come from auth")
	_, task_bad_ok, task_bad_err := taskchain_service.create_task(&taskchains, auth_a, taskchain_service.Create_Task_Input{chain_id = chain_a.chain_id, title = "task", owner_user_id = "bob"})
	check(!task_bad_ok && task_bad_err.code == .Forbidden, "child create must enforce parent-owner equality")
	task_a, task_ok, task_err := taskchain_service.create_task(&taskchains, auth_a, taskchain_service.Create_Task_Input{chain_id = chain_a.chain_id, title = "task"})
	check(task_ok, task_err.message)
	_, task_b_ok, task_b_err := taskchain_service.get_task(&taskchains, auth_b, task_a.task_id)
	check(!task_b_ok && task_b_err.code == .Not_Found, "cross-user task read must be hidden")
	fmt.println("PASS: hub phase3 owner scope")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
