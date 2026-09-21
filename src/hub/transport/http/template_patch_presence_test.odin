package http

// REQ-CLI-8 regression guard: PATCH /api/v1/templates/* silently BLANKED every
// field the caller omitted, and returned 200.
//
// update_template presence-checked only `name`; description, persona and
// instructions were assigned unconditionally from the parsed body. So the obvious
// partial PATCH — send just the field you want to change — destroyed the other
// three. That is silent DATA LOSS, not a dropped input, and per REQ-CLI-7 an agent
// cannot repair a template afterwards.
//
// These tests pin the parse half of the contract: template_input must report which
// fields were PRESENT in the body, so the service can leave absent ones alone.
// Presence is the whole fix — if has_* is wrong here, the service cannot be right.

import "core:testing"

@(test)
test_template_patch_absent_fields_are_not_present :: proc(t: ^testing.T) {
	input := template_input(`{"name":"only the name"}`)
	testing.expect(t, input.has_name, "name was in the body")
	testing.expect(t, !input.has_description, "description absent -> must not be marked present")
	testing.expect(t, !input.has_persona, "persona absent -> must not be marked present")
	testing.expect(t, !input.has_instructions, "instructions absent -> must not be marked present")
	testing.expect_value(t, input.name, "only the name")
}

// The inverse: patching only instructions must not claim the other three.
@(test)
test_template_patch_only_instructions :: proc(t: ^testing.T) {
	input := template_input(`{"instructions":"do the thing"}`)
	testing.expect(t, input.has_instructions, "instructions was in the body")
	testing.expect(t, !input.has_name, "name absent -> must not be marked present")
	testing.expect(t, !input.has_description, "description absent -> must not be marked present")
	testing.expect(t, !input.has_persona, "persona absent -> must not be marked present")
	testing.expect_value(t, input.instructions, "do the thing")
}

// An explicitly empty field is PRESENT — that is a deliberate clear, and is the
// case a bare `!= ""` check cannot distinguish from absence. This distinction is
// the entire reason for the has_* flags.
@(test)
test_template_patch_explicit_empty_is_present :: proc(t: ^testing.T) {
	input := template_input(`{"description":"","persona":""}`)
	testing.expect(t, input.has_description, "explicit empty description is present, not absent")
	testing.expect(t, input.has_persona, "explicit empty persona is present, not absent")
	testing.expect_value(t, input.description, "")
	testing.expect(t, !input.has_name, "name still absent")
	testing.expect(t, !input.has_instructions, "instructions still absent")
}

// A full body (what the UI and a careful caller send) must still carry all four.
@(test)
test_template_patch_full_body_carries_every_field :: proc(t: ^testing.T) {
	input := template_input(`{"name":"n","description":"d","persona":"p","instructions":"i"}`)
	testing.expect(t, input.has_name && input.has_description && input.has_persona && input.has_instructions, "all four present")
	testing.expect_value(t, input.name, "n")
	testing.expect_value(t, input.description, "d")
	testing.expect_value(t, input.persona, "p")
	testing.expect_value(t, input.instructions, "i")
}

// An empty body changes nothing at all.
@(test)
test_template_patch_empty_body_marks_nothing_present :: proc(t: ^testing.T) {
	input := template_input(`{}`)
	testing.expect(t, !input.has_name && !input.has_description && !input.has_persona && !input.has_instructions, "empty body must mark no field present")
}

// Values containing the other field NAMES must not confuse the presence scan —
// instructions text very plausibly contains the word "persona".
@(test)
test_template_patch_field_names_inside_values_do_not_confuse_presence :: proc(t: ^testing.T) {
	input := template_input(`{"instructions":"your persona and description matter"}`)
	testing.expect(t, input.has_instructions, "instructions present")
	testing.expect(t, !input.has_persona, "the word persona inside a VALUE is not a persona field")
	testing.expect(t, !input.has_description, "the word description inside a VALUE is not a description field")
}
