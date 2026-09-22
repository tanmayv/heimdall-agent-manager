package http

// REQ-CLI-8 follow-up (reviewer finding B1): json_property returned the RAW slice
// between the quotes and never unescaped it, while the json_string it replaced
// decodes via json_string_unescaped. Because template_input is shared by
// create_template_handler AND update_template_handler, that turned every escape in
// a template value into literal text on BOTH verbs — and write_handler_json_string
// re-escapes on the way out, so it compounds on each edit round trip rather than
// cancelling. persona and instructions are routinely multi-line, and agents can
// POST templates (bridge/agent_api.odin:72) but cannot repair them (REQ-CLI-7).
//
// These tests pin decoding at the parser, which is where both verbs and the memory
// PATCH path (memory_update_input) share it.

import "core:testing"

@(test)
test_json_property_decodes_escapes :: proc(t: ^testing.T) {
	// A real newline, not a backslash and an 'n'.
	nl, nl_present := json_property(`{"instructions":"line one\nline two"}`, "instructions")
	testing.expect(t, nl_present, "instructions is present")
	testing.expect_value(t, nl, "line one\nline two")
	testing.expect_value(t, len(nl), 17)

	quoted, _ := json_property(`{"persona":"say \"hi\" twice"}`, "persona")
	testing.expect_value(t, quoted, `say "hi" twice`)

	backslash, _ := json_property(`{"persona":"C:\\path\\to"}`, "persona")
	testing.expect_value(t, backslash, `C:\path\to`)

	tabbed, _ := json_property(`{"persona":"a\tb\r\nc"}`, "persona")
	testing.expect_value(t, tabbed, "a\tb\r\nc")

	unicode, _ := json_property(`{"persona":"caf\u00e9"}`, "persona")
	testing.expect_value(t, unicode, "café")
}

// json_property must agree with the json_string it replaced on every value that
// json_string could already parse; presence reporting is the ONLY difference.
@(test)
test_json_property_matches_json_string_decoding :: proc(t: ^testing.T) {
	bodies := []string {
		`{"instructions":"line one\nline two"}`,
		`{"instructions":"say \"hi\""}`,
		`{"instructions":"C:\\path"}`,
		`{"instructions":"caf\u00e9 \t tabbed"}`,
		`{"instructions":"no escapes at all"}`,
		`{"instructions":""}`,
	}
	for body in bodies {
		via_property, _ := json_property(body, "instructions")
		via_string := json_string(body, "instructions")
		testing.expect_value(t, via_property, via_string)
	}
}

// The escape must survive the full create path, not just the parser: this is the
// verb the task's Do-NOT-change list protects, and it shares template_input.
@(test)
test_template_input_create_preserves_escapes :: proc(t: ^testing.T) {
	body := `{"name":"rag","description":"d","persona":"you are\ta helper","instructions":"step one\nstep two\n\nsay \"done\""}`
	input := template_input(body)

	testing.expect_value(t, input.name, "rag")
	testing.expect_value(t, input.persona, "you are\ta helper")
	testing.expect_value(t, input.instructions, "step one\nstep two\n\nsay \"done\"")
	// All four present, so create reads exactly what the caller sent.
	testing.expect(t, input.has_name && input.has_description && input.has_persona && input.has_instructions, "all four present")
}

// The same body through the PATCH path must decode identically — one parser, one
// answer, so create and patch cannot drift apart again.
@(test)
test_template_input_patch_preserves_escapes :: proc(t: ^testing.T) {
	input := template_input(`{"instructions":"line one\nline two"}`)

	testing.expect(t, input.has_instructions, "instructions present")
	testing.expect_value(t, input.instructions, "line one\nline two")
	testing.expect(t, !input.has_name && !input.has_description && !input.has_persona, "nothing else present")
}

// memory_update_input shares json_property, so the memory PATCH path decodes too.
@(test)
test_memory_update_input_decodes_escapes :: proc(t: ^testing.T) {
	input, ok := memory_update_input(`{"body":"first line\nsecond line","title":"a \"quoted\" title"}`)

	testing.expect(t, ok, "body had updatable fields")
	testing.expect_value(t, input.body, "first line\nsecond line")
	testing.expect_value(t, input.title, `a "quoted" title`)
}
