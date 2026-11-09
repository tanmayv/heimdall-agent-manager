package http

// REQ-EXP-GATE-3/5/6: every project fs/vcs/search route (the
// Project Explorer) is refused for an owner without project_vcs BEFORE any project or
// directory lookup, bridge lookup or relay. These drive the production handlers with
// real session-cookie auth and counting fake project repositories: a refusal
// leaves both counters at zero, and an opt-in reaches the existing ownership lookup
// (the fakes answer not_found, so nothing is relayed and no bridge is needed).

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import project_service "odin_test:hub/service/project"
import user_service "odin_test:hub/service/user"

@(private = "file")
Explorer_Route :: struct {
	name:    string,
	handler: Handler_Proc,
	method:  string,
	path:    string,
	query:   string,
	body:    string,
	project: bool, // true = /projects/*, false = /task-chains/*/directories/*
}

@(private = "file")
PROJECT_PATH :: "/api/v1/projects/prj_gate"
// Every route wiring.odin registers through project_fs_relay, project_vcs_relay,
// directory_fs_relay and directory_vcs_relay (vcs/commit-diff on a chain directory is
// the task-review exemption, covered separately below).
@(private = "file")
EXPLORER_ROUTES := [?]Explorer_Route{
	{"project fs list", list_project_dir_handler, "GET", PROJECT_PATH + "/fs", "path=", "", true},
	{"project fs quick-open", quick_open_project_fs_handler, "GET", PROJECT_PATH + "/fs/quick-open", "query=main", "", true},
	{"project fs search", search_project_fs_handler, "GET", PROJECT_PATH + "/fs/search", "query=main", "", true},
	{"project fs read", read_project_file_handler, "GET", PROJECT_PATH + "/fs/file", "path=a.txt", "", true},
	{"project fs create", create_project_file_handler, "POST", PROJECT_PATH + "/fs/file", "", `{"path":"a.txt"}`, true},
	{"project fs write", write_project_file_handler, "PUT", PROJECT_PATH + "/fs/file", "", `{"path":"a.txt","content":"x"}`, true},
	{"project fs batch write", batch_write_project_files_handler, "PUT", PROJECT_PATH + "/fs/files", "", `{"files":[{"path":"a.txt","content":"x"}]}`, true},
	{"project fs mkdir", create_project_dir_handler, "POST", PROJECT_PATH + "/fs/dir", "", `{"path":"d"}`, true},
	{"project fs move", move_project_path_handler, "POST", PROJECT_PATH + "/fs/move", "", `{"from":"a","to":"b"}`, true},
	{"project fs delete", delete_project_path_handler, "DELETE", PROJECT_PATH + "/fs", "path=a.txt", "", true},
	{"project vcs capabilities", project_handle_vcs_capabilities, "GET", PROJECT_PATH + "/vcs/capabilities", "", "", true},
	{"project vcs status", project_handle_vcs_status, "GET", PROJECT_PATH + "/vcs/status", "", "", true},
	{"project vcs files", project_handle_vcs_files, "GET", PROJECT_PATH + "/vcs/files", "", "", true},
	{"project vcs diff", project_handle_vcs_diff, "GET", PROJECT_PATH + "/vcs/diff", "file=a.txt", "", true},
	{"project vcs log", project_handle_vcs_log, "GET", PROJECT_PATH + "/vcs/log", "", "", true},
	{"project vcs commit-diff", project_handle_vcs_commit_diff, "GET", PROJECT_PATH + "/vcs/commit-diff", "base=HEAD~1&head=HEAD", "", true},
	{"project vcs workspaces", project_handle_vcs_workspaces, "GET", PROJECT_PATH + "/vcs/workspaces", "", "", true},
	{"project vcs stage", project_handle_vcs_stage, "POST", PROJECT_PATH + "/vcs/stage", "", `{"file":"a.txt"}`, true},
	{"project vcs unstage", project_handle_vcs_unstage, "POST", PROJECT_PATH + "/vcs/unstage", "", `{"file":"a.txt"}`, true},
	{"project vcs revert", project_handle_vcs_revert, "POST", PROJECT_PATH + "/vcs/revert", "", `{"file":"a.txt"}`, true},
	{"project vcs save-file", project_handle_vcs_save_file, "POST", PROJECT_PATH + "/vcs/save-file", "", `{"file":"a.txt","content":"x"}`, true},
	{"project vcs commit", project_handle_vcs_commit, "POST", PROJECT_PATH + "/vcs/commit", "", `{"message":"m"}`, true},
	{"project vcs upload", project_handle_vcs_upload, "POST", PROJECT_PATH + "/vcs/upload", "", `{}`, true},
	{"project vcs sync", project_handle_vcs_sync, "POST", PROJECT_PATH + "/vcs/sync", "", `{}`, true},
}

@(private = "file")
Explorer_Exp_Repo :: struct {
	enabled_owner: string, // the only owner with a stored project_vcs row
	disabled_row:  bool,   // that row is enabled=false (F1: absent = default on)
	fail:          bool,
}

@(private = "file")
explorer_exp_list :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	r := (^Explorer_Exp_Repo)(ctx)
	if r.fail do return nil, domain.domain_error(.Internal_Error, "database is locked")
	out := make([dynamic]domain.Experiment)
	if r.enabled_owner != "" && owner_user_id == r.enabled_owner {
		append(&out, domain.Experiment{owner_user_id = strings.clone(owner_user_id), key = strings.clone(domain.PROJECT_VCS_EXPERIMENT_KEY), enabled = !r.disabled_row, updated_at = strings.clone("2026-10-25T00:00:00Z")})
	}
	return out, domain.Domain_Error{}
}

// Counts lookups; ctx is the test's own counter, so tests stay parallel-safe.
@(private = "file")
explorer_project_get :: proc(ctx: rawptr, project_id: domain.Project_ID) -> (domain.Project, bool, domain.Domain_Error) {
	(^int)(ctx)^ += 1
	return domain.Project{}, false, domain.domain_error(.Not_Found, "project not found")
}

@(private = "file")
Explorer_Fixture :: struct {
	conn:           sqlite.Conn,
	us_repo_sqlite: sqlite.User_Repo_SQLite,
	us_repo:        iface.User_Repository,
	clock:          platform.Clock,
	ids:            platform.ID_Generator,
	us_svc:         user_service.User_Service,
	auth_svc:       auth_service.Auth_Service,
	exp:            Explorer_Exp_Repo,
	exp_repo:       iface.Experiment_Repository,
	project_gets:   int,
	project_repo:   iface.Project_Repository,
	projects:       project_service.Project_Service,
	bh:             Bridge_Handlers,
}

@(private = "file")
setup_explorer_fixture :: proc(t: ^testing.T) -> ^Explorer_Fixture {
	f := new(Explorer_Fixture)
	conn, open_ok, _ := sqlite.open(":memory:")
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	f.us_repo = sqlite.new_user_repository(&f.us_repo_sqlite, &f.conn)
	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)
	f.auth_svc = auth_service.new_auth_service(auth_service.Auth_Config{auto_provision_users = true}, &f.us_svc)
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids

	f.exp_repo = iface.Experiment_Repository{ctx = rawptr(&f.exp), list_by_owner = explorer_exp_list}
	f.project_repo = iface.Project_Repository{ctx = rawptr(&f.project_gets), get = explorer_project_get}
	f.projects = project_service.Project_Service{projects = &f.project_repo}
	f.bh = Bridge_Handlers{
		auth = &f.auth_svc,
		projects = &f.projects,
		experiments = &f.exp_repo,
	}
	return f
}

@(private = "file")
teardown_explorer_fixture :: proc(f: ^Explorer_Fixture) {
	sqlite.close(&f.conn)
	free(f)
}

// Resolves (auto-provisioning) the user a browser session for `username` maps to.
@(private = "file")
explorer_user_id :: proc(t: ^testing.T, f: ^Explorer_Fixture, username: string) -> string {
	headers := http_test_login(t, &f.auth_svc, username)
	ctx, ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{remote_addr = "127.0.0.1:4444", headers = headers})
	testing.expect(t, ok, "session user resolved")
	return strings.clone(ctx.user_id)
}

@(private = "file")
explorer_call :: proc(f: ^Explorer_Fixture, route: Explorer_Route, username: string) -> Response {
	headers := http_test_session_headers(&f.auth_svc, username)
	return route.handler(rawptr(&f.bh), Request{
		method = route.method, path = route.path, query = route.query, body = route.body,
		request_id = "req_explorer_gate", remote_addr = "127.0.0.1:4444", headers = headers,
	})
}

@(private = "file")
expect_explorer_disabled :: proc(t: ^testing.T, route: Explorer_Route, resp: Response) {
	testing.expectf(t, resp.status == 403, "%s: disabled explorer must be 403, got %d (%s)", route.name, resp.status, resp.body)
	testing.expectf(t, strings.contains(resp.body, `"code":"forbidden"`), "%s: existing forbidden code", route.name)
	testing.expectf(t, strings.contains(resp.body, "Project Explorer is experimental. Enable it in Settings > Experimental to use it."), "%s: spec message", route.name)
	testing.expectf(t, strings.contains(resp.body, `"experimental_feature_disabled"`), "%s: details code", route.name)
	testing.expectf(t, strings.contains(resp.body, `"feature":"project_vcs"`), "%s: details feature", route.name)
}

@(test)
test_explorer_routes_refuse_disabled_owner_before_lookup :: proc(t: ^testing.T) {
	f := setup_explorer_fixture(t)
	defer teardown_explorer_fixture(f)

	// An explicit off row disables (F1: absent = default on); no project/chain
	// lookup, so no relay.
	off_owner := explorer_user_id(t, f, "gate_disabled")
	defer delete(off_owner)
	f.exp.enabled_owner = off_owner
	f.exp.disabled_row = true
	for route in EXPLORER_ROUTES {
		resp := explorer_call(f, route, "gate_disabled")
		expect_explorer_disabled(t, route, resp)
	}
	testing.expect_value(t, f.project_gets, 0)
}

@(test)
test_explorer_routes_pass_enabled_owner_to_ownership_checks :: proc(t: ^testing.T) {
	f := setup_explorer_fixture(t)
	defer teardown_explorer_fixture(f)
	owner := explorer_user_id(t, f, "gate_enabled")
	defer delete(owner)
	f.exp.enabled_owner = owner

	project_routes := 0
	for route in EXPLORER_ROUTES {
		resp := explorer_call(f, route, "gate_enabled")
		// The guard passes; the existing project/chain ownership lookup still runs and
		// answers not_found for the fake (no bridge relay is reachable).
		testing.expectf(t, resp.status == 404, "%s: enabled owner reaches ownership lookup, got %d (%s)", route.name, resp.status, resp.body)
		testing.expectf(t, !strings.contains(resp.body, "experimental_feature_disabled"), "%s: not refused as experimental", route.name)
		if route.project do project_routes += 1
	}
	testing.expect_value(t, f.project_gets, project_routes)
}

// Per-owner isolation: one user's opt-in never enables another user.
@(test)
test_explorer_routes_are_owner_isolated :: proc(t: ^testing.T) {
	f := setup_explorer_fixture(t)
	defer teardown_explorer_fixture(f)
	owner := explorer_user_id(t, f, "gate_owner_a")
	defer delete(owner)
	// owner_a turned the explorer off; owner_b (no row, default on) is unaffected.
	f.exp.enabled_owner = owner
	f.exp.disabled_row = true

	for route in EXPLORER_ROUTES {
		expect_explorer_disabled(t, route, explorer_call(f, route, "gate_owner_a"))
		resp := explorer_call(f, route, "gate_owner_b")
		testing.expectf(t, !strings.contains(resp.body, "experimental_feature_disabled"), "%s: another owner's off does not gate owner_b", route.name)
	}
}

// Repository failures fail closed with the existing internal-error response.
@(test)
test_explorer_routes_fail_closed_on_experiment_repo_error :: proc(t: ^testing.T) {
	f := setup_explorer_fixture(t)
	defer teardown_explorer_fixture(f)
	f.exp.fail = true

	for route in EXPLORER_ROUTES {
		resp := explorer_call(f, route, "gate_repo_down")
		testing.expectf(t, resp.status == 500, "%s: repo failure must be 500, got %d (%s)", route.name, resp.status, resp.body)
		testing.expectf(t, strings.contains(resp.body, `"code":"internal_error"`), "%s: internal_error code", route.name)
	}
	testing.expect_value(t, f.project_gets, 0)
}
