package project

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Cross-Bridge git work: the owner Bridge names its chain repository, the Hub
// maps it to the same project's path on the executor Bridge.

@(private = "file")
Peer_Test_Repo :: struct {
	projects: []domain.Project,
	paths:    []domain.Project_Bridge_Path,
}

@(private = "file")
peer_test_list :: proc(ctx: rawptr, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Project, domain.Domain_Error) {
	repo := cast(^Peer_Test_Repo)ctx
	out := make([dynamic]domain.Project, context.temp_allocator)
	for p in repo.projects do if p.owner_user_id == owner do append(&out, p)
	return out[:], domain.Domain_Error{}
}

@(private = "file")
peer_test_path :: proc(ctx: rawptr, project_id: domain.Project_ID, bridge_id: string) -> (domain.Project_Bridge_Path, bool, domain.Domain_Error) {
	repo := cast(^Peer_Test_Repo)ctx
	for p in repo.paths do if p.project_id == project_id && p.bridge_id == bridge_id do return p, true, domain.Domain_Error{}
	return {}, false, domain.domain_error(.Not_Found, "no path")
}

@(test)
test_resolve_peer_path_maps_the_owner_repository_to_the_executor_checkout :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	projects := []domain.Project{
		{project_id = "prj_archived", owner_user_id = "usr_a", default_path = "/srv/repo", state = .Archived},
		{project_id = "prj_repo", owner_user_id = "usr_a", default_path = "/home/a/default", state = .Active},
		{project_id = "prj_default", owner_user_id = "usr_a", default_path = "/srv/shared", state = .Active},
		{project_id = "prj_foreign", owner_user_id = "usr_b", default_path = "/srv/other", state = .Active},
	}
	paths := []domain.Project_Bridge_Path{
		{project_id = "prj_repo", bridge_id = "brg_owner", owner_user_id = "usr_a", path = "/srv/repo"},
		{project_id = "prj_repo", bridge_id = "brg_exec", owner_user_id = "usr_a", path = "/home/b/repo"},
		{project_id = "prj_foreign", bridge_id = "brg_owner", owner_user_id = "usr_b", path = "/srv/foreign"},
		{project_id = "prj_foreign", bridge_id = "brg_exec", owner_user_id = "usr_b", path = "/home/b/foreign"},
	}
	fake := Peer_Test_Repo{projects, paths}
	repo := iface.Project_Repository{ctx = &fake, list_by_owner = peer_test_list, get_bridge_path = peer_test_path}
	service := Project_Service{projects = &repo}
	// The per-Bridge override on both sides (trailing slash ignored); the
	// archived project with the same default path is skipped.
	testing.expect_value(t, resolve_peer_path(&service, "usr_a", "brg_owner", "/srv/repo/", "brg_exec"), "/home/b/repo")
	// No override: both sides fall back to the project's default path.
	testing.expect_value(t, resolve_peer_path(&service, "usr_a", "brg_owner", "/srv/shared", "brg_exec"), "/srv/shared")
	// Unknown repository, another account's project, missing inputs: no hint.
	testing.expect_value(t, resolve_peer_path(&service, "usr_a", "brg_owner", "/srv/unknown", "brg_exec"), "")
	testing.expect_value(t, resolve_peer_path(&service, "usr_a", "brg_owner", "/srv/foreign", "brg_exec"), "")
	testing.expect_value(t, resolve_peer_path(&service, "usr_a", "", "/srv/repo", "brg_exec"), "")
	testing.expect_value(t, resolve_peer_path(&service, "usr_a", "brg_owner", "", "brg_exec"), "")
	testing.expect_value(t, resolve_peer_path(nil, "usr_a", "brg_owner", "/srv/repo", "brg_exec"), "")
}
