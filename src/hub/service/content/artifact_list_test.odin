package content

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Artifact_Test_Capture :: struct {
	owner:  domain.User_ID,
	filter: domain.Artifact_List_Filter,
	called: bool,
}

fake_content_list_artifacts_capture :: proc(ctx: rawptr, owner: domain.User_ID, filter: domain.Artifact_List_Filter) -> ([]domain.Artifact, domain.Domain_Error) {
	capture := (^Artifact_Test_Capture)(ctx)
	if capture != nil {
		capture.owner = owner
		capture.filter = filter
		capture.called = true
	}
	return {}, {}
}

@(test)
test_list_artifacts_limit_clamping :: proc(t: ^testing.T) {
	capture: Artifact_Test_Capture
	repo := iface.Content_Repository{ctx = rawptr(&capture), list_artifacts = fake_content_list_artifacts_capture}
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)
	auth := contracts.Auth_Context{user_id = "user_1"}

	// Test default limit when 0 or negative
	capture = {}
	_, err0 := list_artifacts(&service, auth, domain.Artifact_List_Filter{limit = 0})
	testing.expect_value(t, err0.code, domain.Error_Code.None)
	testing.expect_value(t, capture.called, true)
	testing.expect_value(t, capture.filter.limit, 50)

	// Test max clamping when > 200
	capture = {}
	_, err250 := list_artifacts(&service, auth, domain.Artifact_List_Filter{limit = 250})
	testing.expect_value(t, err250.code, domain.Error_Code.None)
	testing.expect_value(t, capture.called, true)
	testing.expect_value(t, capture.filter.limit, 200)

	// Test valid limit in range preserved
	capture = {}
	_, err75 := list_artifacts(&service, auth, domain.Artifact_List_Filter{limit = 75})
	testing.expect_value(t, err75.code, domain.Error_Code.None)
	testing.expect_value(t, capture.called, true)
	testing.expect_value(t, capture.filter.limit, 75)
}

@(test)
test_list_artifacts_sort_validation :: proc(t: ^testing.T) {
	capture: Artifact_Test_Capture
	repo := iface.Content_Repository{ctx = rawptr(&capture), list_artifacts = fake_content_list_artifacts_capture}
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)
	auth := contracts.Auth_Context{user_id = "user_1"}

	// Default sort_field and sort_order
	capture = {}
	_, err_def := list_artifacts(&service, auth, domain.Artifact_List_Filter{})
	testing.expect_value(t, err_def.code, domain.Error_Code.None)
	testing.expect_value(t, capture.filter.sort_field, "updated_at")
	testing.expect_value(t, capture.filter.sort_order, "desc")

	// Valid sort fields
	valid_fields := []string{"created_at", "updated_at", "name", "size_bytes"}
	for field in valid_fields {
		capture = {}
		_, err := list_artifacts(&service, auth, domain.Artifact_List_Filter{sort_field = field})
		testing.expect_value(t, err.code, domain.Error_Code.None)
		testing.expect_value(t, capture.filter.sort_field, field)
	}

	// Invalid sort field
	_, err_bad_field := list_artifacts(&service, auth, domain.Artifact_List_Filter{sort_field = "invalid_col"})
	testing.expect_value(t, err_bad_field.code, domain.Error_Code.Validation_Failed)

	// Valid sort orders
	capture = {}
	_, err_asc := list_artifacts(&service, auth, domain.Artifact_List_Filter{sort_order = "asc"})
	testing.expect_value(t, err_asc.code, domain.Error_Code.None)
	testing.expect_value(t, capture.filter.sort_order, "asc")

	capture = {}
	_, err_desc := list_artifacts(&service, auth, domain.Artifact_List_Filter{sort_order = "desc"})
	testing.expect_value(t, err_desc.code, domain.Error_Code.None)
	testing.expect_value(t, capture.filter.sort_order, "desc")

	// Invalid sort order
	_, err_bad_order := list_artifacts(&service, auth, domain.Artifact_List_Filter{sort_order = "sideways"})
	testing.expect_value(t, err_bad_order.code, domain.Error_Code.Validation_Failed)
}

@(test)
test_list_artifacts_filter_passed_to_repo :: proc(t: ^testing.T) {
	capture: Artifact_Test_Capture
	repo := iface.Content_Repository{ctx = rawptr(&capture), list_artifacts = fake_content_list_artifacts_capture}
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)
	auth := contracts.Auth_Context{user_id = "user_42"}

	input_filter := domain.Artifact_List_Filter{
		project_id        = "proj_123",
		agent_instance_id = "inst_abc",
		agent_id          = "agt_xyz",
		chain_id          = "chain_1",
		task_id           = "task_99",
		kind              = "patch",
		since             = "2026-01-01T00:00:00Z",
		until             = "2026-01-02T00:00:00Z",
		include_deleted   = true,
		sort_field        = "name",
		sort_order        = "asc",
		limit             = 100,
		cursor            = "foo|bar",
	}

	_, err := list_artifacts(&service, auth, input_filter)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, capture.called, true)
	testing.expect_value(t, string(capture.owner), "user_42")
	testing.expect_value(t, string(capture.filter.project_id), "proj_123")
	testing.expect_value(t, capture.filter.agent_instance_id, "inst_abc")
	testing.expect_value(t, capture.filter.agent_id, "agt_xyz")
	testing.expect_value(t, capture.filter.chain_id, "chain_1")
	testing.expect_value(t, capture.filter.task_id, "task_99")
	testing.expect_value(t, capture.filter.kind, "patch")
	testing.expect_value(t, capture.filter.since, "2026-01-01T00:00:00Z")
	testing.expect_value(t, capture.filter.until, "2026-01-02T00:00:00Z")
	testing.expect_value(t, capture.filter.include_deleted, true)
	testing.expect_value(t, capture.filter.sort_field, "name")
	testing.expect_value(t, capture.filter.sort_order, "asc")
	testing.expect_value(t, capture.filter.limit, 100)
	testing.expect_value(t, capture.filter.cursor, "foo|bar")
}
