package main

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
fig_test_stamp :: proc() -> string {
	ns := time.to_unix_nanoseconds(time.now())
	b := strings.builder_make()
	strings.write_int(&b, int(ns % 1_000_000_000))
	return strings.to_string(b)
}

@(private = "file")
fig_test_make_citc_root :: proc(t: ^testing.T, tag: string) -> string {
	base := os.get_env_alloc("TMPDIR", context.allocator)
	if strings.trim_space(base) == "" do base = "/tmp"
	base = strings.trim_right(base, "/")
	root := strings.concatenate({base, "/ham_citc_test_", tag, "_", fig_test_stamp()})
	_ = os.make_directory_all(root)
	if resolved, rerr := os.get_absolute_path(root, context.allocator); rerr == nil do root = resolved
	return root
}

@(test)
test_fig_workspace_name_validation :: proc(t: ^testing.T) {
	testing.expect(t, fig_is_valid_workspace_name("heimdall"), "valid simple name")
	testing.expect(t, fig_is_valid_workspace_name("zv2-billing-fix"), "valid name with hyphen")
	testing.expect(t, fig_is_valid_workspace_name("my_ws_123"), "valid name with underscore and digits")

	testing.expect(t, !fig_is_valid_workspace_name(""), "empty name rejected")
	testing.expect(t, !fig_is_valid_workspace_name("../escape"), "traversal rejected")
	testing.expect(t, !fig_is_valid_workspace_name("foo/bar"), "slash rejected")
	testing.expect(t, !fig_is_valid_workspace_name("foo bar"), "space rejected")
	testing.expect(t, !fig_is_valid_workspace_name("foo$bar"), "special char rejected")
}

@(test)
test_fig_list_and_create_workspaces_mock :: proc(t: ^testing.T) {
	root := fig_test_make_citc_root(t, "mock_ws")
	defer os.remove_all(root)

	// Initially empty
	res0 := fig_list_workspaces(root)
	testing.expect(t, res0.ok, "list on empty root ok")
	testing.expect_value(t, len(res0.workspaces), 0)

	// Create workspace 1 via mock create
	c1 := fig_create_workspace("ws-beta", root, true)
	testing.expect(t, c1.ok, "create ws-beta ok")
	testing.expect_value(t, c1.name, "ws-beta")
	testing.expect(t, c1.created, "created flag true")

	// Create workspace 2 via mock create
	c2 := fig_create_workspace("ws-alpha", root, true)
	testing.expect(t, c2.ok, "create ws-alpha ok")

	// Create a non-CitC dir without google3 to verify it is ignored
	non_citc := strings.concatenate({root, "/not-a-workspace"})
	_ = os.make_directory_all(non_citc)

	// List workspaces: should discover ws-alpha and ws-beta in sorted order
	res1 := fig_list_workspaces(root)
	testing.expect(t, res1.ok, "list workspaces ok")
	testing.expect_value(t, len(res1.workspaces), 2)
	testing.expect_value(t, res1.workspaces[0].name, "ws-alpha")
	testing.expect_value(t, res1.workspaces[1].name, "ws-beta")
}

@(test)
test_fig_list_dir_pagination_and_sorting :: proc(t: ^testing.T) {
	root := fig_test_make_citc_root(t, "browse")
	defer os.remove_all(root)

	_ = fig_create_workspace("myws", root, true)
	g3 := strings.concatenate({root, "/myws/google3"})

	// Create files and dirs inside google3/
	_ = os.make_directory_all(strings.concatenate({g3, "/zebra_dir"}))
	_ = os.make_directory_all(strings.concatenate({g3, "/apple_dir"}))
	_ = os.write_entire_file_from_string(strings.concatenate({g3, "/banana.txt"}), "content")
	_ = os.write_entire_file_from_string(strings.concatenate({g3, "/apple.txt"}), "content")

	// List page 1 with limit=2 (should return 2 dirs: apple_dir, zebra_dir)
	p1 := fig_list_dir("myws", "", "", 2, false, root)
	testing.expect(t, p1.ok, "page 1 ok")
	testing.expect_value(t, len(p1.entries), 2)
	testing.expect_value(t, p1.entries[0].name, "apple_dir")
	testing.expect_value(t, p1.entries[0].is_dir, true)
	testing.expect_value(t, p1.entries[1].name, "zebra_dir")
	testing.expect_value(t, p1.entries[1].is_dir, true)
	testing.expect(t, p1.has_more, "has_more is true")
	testing.expect(t, p1.next_cursor != "", "next_cursor present")

	// List page 2 with cursor from p1
	p2 := fig_list_dir("myws", "", p1.next_cursor, 2, false, root)
	testing.expect(t, p2.ok, "page 2 ok")
	testing.expect_value(t, len(p2.entries), 2)
	testing.expect_value(t, p2.entries[0].name, "apple.txt")
	testing.expect_value(t, p2.entries[0].is_dir, false)
	testing.expect_value(t, p2.entries[1].name, "banana.txt")
	testing.expect_value(t, p2.entries[1].is_dir, false)
	testing.expect(t, !p2.has_more, "has_more is false on last page")

	// Traversal safety check
	p_trav := fig_list_dir("myws", "../escape", "", 50, false, root)
	testing.expect(t, !p_trav.ok, "path traversal blocked")
	testing.expect_value(t, p_trav.error_code, "path_outside_root")
}
