package http

// REQ-CLI-2 regression guard: task CREATE dropped `priority`.
//
// Create_Task_Input had no priority field and create_task hardcoded .P2, so both
// CLIs sent the field and the Hub discarded it — `--priority p0` silently produced
// a p2 task. These tests pin the parse contract the two create handlers share:
// absent means "use the P2 default", a valid value is carried through, and an
// explicitly present but invalid value is REJECTED rather than coerced to p2 (the
// coercion in domain.task_priority_from_string is what hid the original bug).

import "core:strings"
import "core:testing"
import "odin_test:hub/domain"

@(test)
test_create_priority_absent_leaves_default :: proc(t: ^testing.T) {
	priority, has, ok, _ := create_priority_from_body(`{"title":"probe"}`)
	testing.expect(t, ok, "absent priority must not be an error")
	testing.expect(t, !has, "absent priority must not claim an explicit value")
	testing.expect_value(t, priority, domain.Task_Priority.P2)
}

@(test)
test_create_priority_round_trips_each_level :: proc(t: ^testing.T) {
	cases := [][2]string{{"p0", "P0"}, {"p1", "P1"}, {"p2", "P2"}}
	want := []domain.Task_Priority{.P0, .P1, .P2}
	for c, i in cases {
		for raw in c {
			body := concat_priority_body(raw)
			defer delete(body)
			priority, has, ok, _ := create_priority_from_body(body)
			testing.expect(t, ok, "valid priority must parse")
			testing.expect(t, has, "valid priority must be marked explicit")
			testing.expect_value(t, priority, want[i])
		}
	}
}

@(test)
test_create_priority_invalid_is_rejected_not_coerced :: proc(t: ^testing.T) {
	invalid := []string{"urgent", "P3", "high", ""}
	for raw in invalid {
		body := concat_priority_body(raw)
		defer delete(body)
		_, has, ok, err := create_priority_from_body(body)
		testing.expect(t, !ok, "invalid priority must be rejected")
		testing.expect(t, !has, "rejected priority must not be forwarded as explicit")
		testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	}
}

@(private = "file")
concat_priority_body :: proc(value: string) -> string {
	return strings.concatenate({`{"title":"probe","priority":"`, value, `"}`})
}
