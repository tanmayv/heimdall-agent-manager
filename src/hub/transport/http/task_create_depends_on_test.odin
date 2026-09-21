package http

// REQ-CLI-10 regression guard: agent-mode task CREATE dropped `depends_on`.
//
// The ctl sent the field (agent_mode.odin:330) and agent_action_task_create_handler
// never read it, so an agent-created task silently got an EMPTY dependency list and
// returned success — the dependency gate a coordinator asked for simply did not
// exist. The USER-mode create (taskchain_handlers.odin:637) DID read it, so this
// was a one-site fix, unlike REQ-CLI-2 which was broken in both.
//
// These tests pin the parse contract the two create handlers now share:
// json_array_of_strings is the single parser, absent means "no dependencies" (NOT
// an error), and ids are carried through verbatim in order.

import "core:strings"
import "core:testing"
import "odin_test:hub/domain"

@(test)
test_create_depends_on_absent_is_empty_not_error :: proc(t: ^testing.T) {
	deps := json_array_of_strings(`{"title":"probe"}`, "depends_on")
	testing.expect(t, len(deps) == 0, "absent depends_on must yield no dependencies")
	empty := json_array_of_strings(`{"title":"probe","depends_on":[]}`, "depends_on")
	testing.expect(t, len(empty) == 0, "explicit empty list must yield no dependencies")
}

@(test)
test_create_depends_on_single_round_trips :: proc(t: ^testing.T) {
	deps := json_array_of_strings(`{"title":"probe","depends_on":["task_abc123"]}`, "depends_on")
	testing.expect(t, len(deps) == 1, "one dependency must survive the parse")
	if len(deps) == 1 do testing.expect_value(t, deps[0], domain.Task_ID("task_abc123"))
}

// The CLI turns a comma-separated --depends-on into a JSON array, so multiple
// dependencies must round-trip in order.
@(test)
test_create_depends_on_multiple_round_trip_in_order :: proc(t: ^testing.T) {
	body := `{"title":"probe","depends_on":["task_one","task_two","task_three"]}`
	deps := json_array_of_strings(body, "depends_on")
	testing.expect(t, len(deps) == 3, "all three dependencies must survive the parse")
	if len(deps) != 3 do return
	want := []string{"task_one", "task_two", "task_three"}
	for w, i in want do testing.expect_value(t, deps[i], domain.Task_ID(w))
}

// depends_on must not be confused with a neighbouring field, and an unrelated body
// must not conjure dependencies out of nothing.
@(test)
test_create_depends_on_does_not_bleed_from_other_fields :: proc(t: ^testing.T) {
	body := `{"title":"probe","reviewer_refs":["inst_xyz"],"depends_on":["task_real"]}`
	deps := json_array_of_strings(body, "depends_on")
	testing.expect(t, len(deps) == 1, "depends_on must not pick up reviewer_refs")
	if len(deps) == 1 do testing.expect_value(t, deps[0], domain.Task_ID("task_real"))
	none := json_array_of_strings(`{"title":"probe","reviewer_refs":["inst_xyz"]}`, "depends_on")
	testing.expect(t, len(none) == 0, "a body without depends_on must yield none")
}

// The agent-mode create body is built by the ctl; pin that the shape it actually
// sends is the shape the handler parses.
@(test)
test_create_depends_on_parses_ctl_shaped_body :: proc(t: ^testing.T) {
	body := strings.concatenate({`{"chain_id":"chain_1","title":"t","depends_on":["`, "task_dep1", `","`, "task_dep2", `"]}`})
	defer delete(body)
	deps := json_array_of_strings(body, "depends_on")
	testing.expect(t, len(deps) == 2, "ctl-shaped create body must parse both dependencies")
}
