package content

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// REQ-CLI-8 service-level coverage for update_template's PATCH semantics.
// The handler-side parsing (which JSON keys set which has_<field> flag) is
// covered by transport/http/template_patch_presence_test.odin; this file covers
// what the service DOES with those flags:
//   absent field            -> left unchanged (the data-loss bug being fixed)
//   present, non-empty      -> written
//   present, empty          -> explicit clear (except name, which is required)
// It also pins the built-in guard and the ownership check, which must survive.

Template_Patch_Capture :: struct {
	stored: domain.Template,
	saved:  domain.Template,
	save_called: bool,
}

fake_content_get_template_stored :: proc(ctx: rawptr, id: string) -> (domain.Template, bool, domain.Domain_Error) {
	capture := (^Template_Patch_Capture)(ctx)
	if capture == nil do return {}, false, domain.domain_error(.Not_Found, "template not found")
	return capture.stored, true, {}
}

fake_content_save_template_capture :: proc(ctx: rawptr, t: domain.Template) -> (domain.Template, bool, domain.Domain_Error) {
	capture := (^Template_Patch_Capture)(ctx)
	if capture != nil {
		capture.saved = t
		capture.save_called = true
	}
	return t, true, {}
}

// template_patch_repo resets the capture to hold one owned, fully-populated
// template and returns a repository reading and writing it. Callers keep the
// returned repository in their own frame and hand its address to the service.
template_patch_repo :: proc(capture: ^Template_Patch_Capture) -> iface.Content_Repository {
	capture^ = Template_Patch_Capture {
		stored = domain.Template {
			template_id = "tmpl_throwaway",
			owner_user_id = "user_1",
			name = "original name",
			description = "original description",
			persona = "original persona",
			instructions = "original instructions",
		},
	}
	return iface.Content_Repository {
		ctx = rawptr(capture),
		get_template = fake_content_get_template_stored,
		save_template = fake_content_save_template_capture,
	}
}

@(test)
test_update_template_name_only_preserves_other_fields :: proc(t: ^testing.T) {
	capture: Template_Patch_Capture
	repo := template_patch_repo(&capture)
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)
	auth := contracts.Auth_Context{user_id = "user_1"}

	updated, ok, err := update_template(&service, auth, "tmpl_throwaway", Template_Input{name = "renamed", has_name = true})

	testing.expect_value(t, ok, true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, capture.save_called, true)
	testing.expect_value(t, updated.name, "renamed")
	testing.expect_value(t, updated.description, "original description")
	testing.expect_value(t, updated.persona, "original persona")
	testing.expect_value(t, updated.instructions, "original instructions")
}

@(test)
test_update_template_instructions_only_preserves_other_fields :: proc(t: ^testing.T) {
	capture: Template_Patch_Capture
	repo := template_patch_repo(&capture)
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)
	auth := contracts.Auth_Context{user_id = "user_1"}

	updated, ok, err := update_template(&service, auth, "tmpl_throwaway", Template_Input{instructions = "new instructions", has_instructions = true})

	testing.expect_value(t, ok, true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, updated.instructions, "new instructions")
	testing.expect_value(t, updated.name, "original name")
	testing.expect_value(t, updated.description, "original description")
	testing.expect_value(t, updated.persona, "original persona")
}

@(test)
test_update_template_empty_body_changes_nothing :: proc(t: ^testing.T) {
	capture: Template_Patch_Capture
	repo := template_patch_repo(&capture)
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)
	auth := contracts.Auth_Context{user_id = "user_1"}

	// This is the exact shape that used to blank three fields and return 200.
	updated, ok, err := update_template(&service, auth, "tmpl_throwaway", Template_Input{})

	testing.expect_value(t, ok, true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, updated.name, "original name")
	testing.expect_value(t, updated.description, "original description")
	testing.expect_value(t, updated.persona, "original persona")
	testing.expect_value(t, updated.instructions, "original instructions")
}

@(test)
test_update_template_present_empty_clears_field :: proc(t: ^testing.T) {
	capture: Template_Patch_Capture
	repo := template_patch_repo(&capture)
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)
	auth := contracts.Auth_Context{user_id = "user_1"}

	// Explicit {"description":""} is a deliberate clear, not an absent field.
	updated, ok, err := update_template(&service, auth, "tmpl_throwaway", Template_Input{description = "", has_description = true})

	testing.expect_value(t, ok, true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, updated.description, "")
	testing.expect_value(t, updated.name, "original name")
	testing.expect_value(t, updated.persona, "original persona")
	testing.expect_value(t, updated.instructions, "original instructions")
}

@(test)
test_update_template_explicit_empty_name_rejected :: proc(t: ^testing.T) {
	capture: Template_Patch_Capture
	repo := template_patch_repo(&capture)
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)
	auth := contracts.Auth_Context{user_id = "user_1"}

	// name is required, so clearing it is the one field-clear that is refused.
	_, ok, err := update_template(&service, auth, "tmpl_throwaway", Template_Input{name = "   ", has_name = true})

	testing.expect_value(t, ok, false)
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	testing.expect_value(t, capture.save_called, false)
}

@(test)
test_update_template_all_fields_still_writable :: proc(t: ^testing.T) {
	capture: Template_Patch_Capture
	repo := template_patch_repo(&capture)
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)
	auth := contracts.Auth_Context{user_id = "user_1"}

	updated, ok, err := update_template(&service, auth, "tmpl_throwaway", Template_Input {
		name = "n2", description = "d2", persona = "p2", instructions = "i2",
		has_name = true, has_description = true, has_persona = true, has_instructions = true,
	})

	testing.expect_value(t, ok, true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, updated.name, "n2")
	testing.expect_value(t, updated.description, "d2")
	testing.expect_value(t, updated.persona, "p2")
	testing.expect_value(t, updated.instructions, "i2")
}

@(test)
test_update_template_guards_survive :: proc(t: ^testing.T) {
	capture: Template_Patch_Capture
	repo := template_patch_repo(&capture)
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)

	// Built-in templates stay uneditable (guard by id, before any repo lookup).
	_, ok_builtin, err_builtin := update_template(&service, contracts.Auth_Context{user_id = "user_1"}, domain.TEMPLATE_WORKER_ID, Template_Input{name = "hijack", has_name = true})
	testing.expect_value(t, ok_builtin, false)
	testing.expect_value(t, err_builtin.code, domain.Error_Code.Validation_Failed)
	testing.expect_value(t, capture.save_called, false)

	// is_system templates stored in the repository are equally uneditable.
	capture.stored.is_system = true
	_, ok_system, err_system := update_template(&service, contracts.Auth_Context{user_id = "user_1"}, "tmpl_throwaway", Template_Input{name = "hijack", has_name = true})
	testing.expect_value(t, ok_system, false)
	testing.expect_value(t, err_system.code, domain.Error_Code.Validation_Failed)
	capture.stored.is_system = false

	// A non-owner gets Not_Found, never a write.
	_, ok_other, err_other := update_template(&service, contracts.Auth_Context{user_id = "user_2"}, "tmpl_throwaway", Template_Input{name = "hijack", has_name = true})
	testing.expect_value(t, ok_other, false)
	testing.expect_value(t, err_other.code, domain.Error_Code.Not_Found)
	testing.expect_value(t, capture.save_called, false)
}
