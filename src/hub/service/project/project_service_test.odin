package project

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

stub_project_repo :: struct {
	last_saved: domain.Project,
	save_called: bool,
}

@(private = "file")
stub_project_save :: proc(ctx: rawptr, p: domain.Project) -> (domain.Project, bool, domain.Domain_Error) {
	stub := (^stub_project_repo)(ctx)
	stub.last_saved = p
	stub.save_called = true
	return p, true, domain.Domain_Error{}
}

@(private = "file")
stub_project_get :: proc(ctx: rawptr, id: domain.Project_ID) -> (domain.Project, bool, domain.Domain_Error) {
	stub := (^stub_project_repo)(ctx)
	return stub.last_saved, true, domain.Domain_Error{}
}

@(private = "file")
new_test_service :: proc(stub: ^stub_project_repo, repo: ^iface.Project_Repository, bridges: ^iface.Bridge_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Project_Service {
	repo^ = iface.Project_Repository{
		ctx = rawptr(stub),
		save = stub_project_save,
		get = stub_project_get,
	}
	clock^ = platform.real_clock()
	ids^ = platform.real_id_generator()
	return new_project_service(repo, bridges, clock, ids)
}

@(test)
test_create_fig_project_defaults_and_paths :: proc(t: ^testing.T) {
	stub: stub_project_repo
	repo: iface.Project_Repository
	bridges: iface.Bridge_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := new_test_service(&stub, &repo, &bridges, &clock, &ids)

	auth := contracts.Auth_Context{
		user_id = "testuser",
		kind = .User_Token,
	}

	// 1. Fig project with just workspace_name
	p1, ok1, err1 := create(&service, auth, Create_Project_Input{
		name = "My CitC Project",
		project_type = "fig",
		workspace_name = "heimdall",
	})
	testing.expect(t, ok1, "fig project creation ok")
	testing.expect_value(t, err1.code, domain.Error_Code.None)
	testing.expect_value(t, p1.project_type, "fig")
	testing.expect_value(t, p1.workspace_name, "heimdall")
	testing.expect_value(t, p1.vcs_kind, "piper")
	testing.expect_value(t, p1.default_path, "/google/src/cloud/testuser/heimdall/google3")
	testing.expect_value(t, p1.repo_url, "//depot/google3")

	// 2. Fig project with relative_path
	p2, ok2, _ := create(&service, auth, Create_Project_Input{
		name = "Subdir Project",
		project_type = "fig",
		workspace_name = "heimdall",
		relative_path = "cloud/security",
	})
	testing.expect(t, ok2, "fig project with relative_path creation ok")
	testing.expect_value(t, p2.default_path, "/google/src/cloud/testuser/heimdall/google3/cloud/security")
	testing.expect_value(t, p2.repo_url, "//depot/google3/cloud/security")

	// 3. Fig project without workspace_name fails validation
	_, ok3, err3 := create(&service, auth, Create_Project_Input{
		name = "Invalid Fig Project",
		project_type = "fig",
	})
	testing.expect(t, !ok3, "fig project without workspace_name fails")
	testing.expect_value(t, err3.code, domain.Error_Code.Validation_Failed)

	// 4. Local project defaults to local and requires default_path
	p4, ok4, _ := create(&service, auth, Create_Project_Input{
		name = "Local Project",
		default_path = "/home/user/repo",
	})
	testing.expect(t, ok4, "local project creation ok")
	testing.expect_value(t, p4.project_type, "local")
	testing.expect_value(t, p4.default_path, "/home/user/repo")

	// 5. Fig project with invalid workspace_name (starting with hyphen or special chars)
	_, ok5, err5 := create(&service, auth, Create_Project_Input{
		name = "Bad WS Project",
		project_type = "fig",
		workspace_name = "-invalid_ws",
	})
	testing.expect(t, !ok5, "fig project with leading hyphen in workspace_name fails")
	testing.expect_value(t, err5.code, domain.Error_Code.Validation_Failed)

	// 6. Fig project with path traversal in relative_path
	_, ok6, err6 := create(&service, auth, Create_Project_Input{
		name = "Traversal Project",
		project_type = "fig",
		workspace_name = "heimdall",
		relative_path = "cloud/../../etc",
	})
	testing.expect(t, !ok6, "fig project with '..' in relative_path fails")
	testing.expect_value(t, err6.code, domain.Error_Code.Validation_Failed)

	// 7. Relative path with leading/trailing slashes trimmed
	p7, ok7, _ := create(&service, auth, Create_Project_Input{
		name = "Slash Trim Project",
		project_type = "fig",
		workspace_name = "heimdall",
		relative_path = "/cloud/security/",
	})
	testing.expect(t, ok7, "fig project with slashes trimmed ok")
	testing.expect_value(t, p7.relative_path, "cloud/security")
	testing.expect_value(t, p7.default_path, "/google/src/cloud/testuser/heimdall/google3/cloud/security")
	testing.expect_value(t, p7.repo_url, "//depot/google3/cloud/security")
}

