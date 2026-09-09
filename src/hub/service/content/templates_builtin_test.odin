package content

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Fake content repository returning no owner templates so the built-in 'empty'
// template is the only entry list_templates appends.
fake_content_list_templates_empty :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Template, domain.Domain_Error) {
	return {}, {}
}

fake_content_get_template_none :: proc(ctx: rawptr, id: string) -> (domain.Template, bool, domain.Domain_Error) {
	return {}, false, domain.domain_error(.Not_Found, "template not found")
}

@(test)
test_list_templates_includes_empty_excludes_system_reviewer :: proc(t: ^testing.T) {
	repo := iface.Content_Repository{list_templates = fake_content_list_templates_empty, get_template = fake_content_get_template_none}
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)

	templates, err := list_templates(&service, contracts.Auth_Context{user_id = "user_1"})
	defer delete(templates)
	testing.expect_value(t, err.code, domain.Error_Code.None)

	has_empty := false
	has_reviewer := false
	for tmpl in templates {
		if tmpl.template_id == domain.TEMPLATE_EMPTY_ID do has_empty = true
		if tmpl.template_id == "tmpl_system_reviewer" do has_reviewer = true
	}
	testing.expect_value(t, has_empty, true)
	testing.expect_value(t, has_reviewer, false)
}

@(test)
test_get_template_empty_is_builtin :: proc(t: ^testing.T) {
	repo := iface.Content_Repository{list_templates = fake_content_list_templates_empty, get_template = fake_content_get_template_none}
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)

	tmpl, ok, err := get_template(&service, contracts.Auth_Context{user_id = "user_1"}, domain.TEMPLATE_EMPTY_ID)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, tmpl.name, "empty")
	testing.expect_value(t, tmpl.is_system, true)

	testing.expect_value(t, template_available(&service, "user_1", domain.TEMPLATE_EMPTY_ID), true)
	testing.expect_value(t, template_available(&service, "user_1", "tmpl_system_reviewer"), false)
}
