package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

// _shell_session_list_json gained a `has_more` key so GET /api/v1/shells matches
// the envelope every other list route emits. The value is exactly
// `next_cursor != ""`: the repository sets next_cursor ONLY when a full page came
// back, so an empty cursor is precisely "no more rows".
@(test)
test_shell_session_list_json_has_more :: proc(t: ^testing.T) {
	sessions := []domain.Shell_Session{
		{session_id = "sh_a", bridge_id = "brg_1", status = "running"},
		{session_id = "sh_b", bridge_id = "brg_2", status = "exited"},
	}

	// A full page: cursor present, has_more true.
	more := _shell_session_list_json(sessions, "sh_b")
	defer delete(more)
	testing.expect(t, strings.contains(more, "\"next_cursor\":\"sh_b\""), "cursor echoed")
	testing.expect(t, strings.contains(more, "\"has_more\":true"), "has_more true when a cursor was returned")
	testing.expect(t, !strings.contains(more, "\"has_more\":false"), "not both spellings")

	// The last page: no cursor, has_more false.
	last := _shell_session_list_json(sessions, "")
	defer delete(last)
	testing.expect(t, strings.contains(last, "\"next_cursor\":\"\""), "empty cursor still emitted")
	testing.expect(t, strings.contains(last, "\"has_more\":false"), "has_more false with no cursor")

	// The keys existing consumers already read are untouched and still in order.
	testing.expect(t, strings.contains(last, "\"ok\":true,\"sessions\":["), "envelope prefix unchanged")
	testing.expect(t, strings.contains(last, "\"session_id\":\"sh_a\""), "first session present")
	testing.expect(t, strings.contains(last, "\"session_id\":\"sh_b\""), "second session present")
	testing.expect(t, strings.contains(last, "\"bridge_id\":\"brg_2\""), "sessions from more than one bridge serialize")

	// An empty page is still a well-formed envelope, not a bare array.
	none := _shell_session_list_json([]domain.Shell_Session{}, "")
	defer delete(none)
	testing.expect_value(t, none, "{\"ok\":true,\"sessions\":[],\"next_cursor\":\"\",\"has_more\":false}")
}
