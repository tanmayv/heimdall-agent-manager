package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_write_directory_json_lean :: proc(t: ^testing.T) {
	dir := domain.Task_Chain_Directory{
		directory_id  = "dir_test123",
		chain_id      = domain.Task_Chain_ID("chain_abc"),
		owner_user_id = domain.User_ID("user_tanmay"),
		path          = "/home/tanmay/repo",
		bridge_id     = "brg_local",
		vcs_kind      = "git",
		vcs_info_json = `{"branch":"main","root":"/home/tanmay/repo"}`,
		created_at    = "2026-09-22T10:00:00Z",
		updated_at    = "2026-09-22T10:05:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_directory_json(&b, dir)
	out := strings.to_string(b)

	// Required lean fields must be present
	testing.expect(t, strings.contains(out, `"directory_id":"dir_test123"`), "must contain directory_id")
	testing.expect(t, strings.contains(out, `"path":"/home/tanmay/repo"`), "must contain path")
	testing.expect(t, strings.contains(out, `"bridge_id":"brg_local"`), "must contain bridge_id")
	testing.expect(t, strings.contains(out, `"vcs_kind":"git"`), "must contain vcs_kind")
	testing.expect(t, strings.contains(out, `"vcs":{"branch":"main","root":"/home/tanmay/repo"}`), "must contain vcs object")

	// Lean payload: created_at, updated_at, owner_user_id must NOT be leaked
	testing.expect(t, !strings.contains(out, `"created_at"`), "lean payload must not contain created_at")
	testing.expect(t, !strings.contains(out, `"updated_at"`), "lean payload must not contain updated_at")
	testing.expect(t, !strings.contains(out, `"owner_user_id"`), "lean payload must not contain owner_user_id")
	testing.expect(t, !strings.contains(out, `"chain_id"`), "lean payload must not contain redundant chain_id")
}

@(test)
test_write_directory_json_empty_vcs :: proc(t: ^testing.T) {
	dir := domain.Task_Chain_Directory{
		directory_id  = "dir_empty_vcs",
		chain_id      = domain.Task_Chain_ID("chain_xyz"),
		owner_user_id = domain.User_ID("user_tanmay"),
		path          = "/home/tanmay/docs",
		bridge_id     = "",
		vcs_kind      = "",
		vcs_info_json = "",
		created_at    = "2026-09-22T10:00:00Z",
		updated_at    = "2026-09-22T10:00:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_directory_json(&b, dir)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"directory_id":"dir_empty_vcs"`), "must contain directory_id")
	testing.expect(t, strings.contains(out, `"path":"/home/tanmay/docs"`), "must contain path")
	testing.expect(t, strings.contains(out, `"bridge_id":""`), "must contain empty bridge_id")
	testing.expect(t, strings.contains(out, `"vcs_kind":""`), "must contain empty vcs_kind")
	testing.expect(t, strings.contains(out, `"vcs":{}`), "empty vcs_info_json must serialize as empty object")
}
