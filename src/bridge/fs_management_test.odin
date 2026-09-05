package main

// Tests for the project-scoped FS browse/CRUD helpers in fs_management.odin.
// Covers: sort ordering, cursor pagination, hidden filtering, and containment
// (path_outside_root) on list/read/move/delete/create.
//
// Odin runs @(test) procs concurrently, so these tests must NOT depend on a
// mutable shared global. We set the GLOBAL bridge_fs_root ONCE to the shared temp
// base (idempotent — every test writes the same value) and give each test its own
// unique subdirectory that is threaded through the `sandbox_root` parameter of
// every operation. This mirrors exactly how the hub's project-scoped relay calls
// these procs (project root passed per-command), and keeps tests independent.

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import base64 "core:encoding/base64"

// fs_test_base resolves (and pins) the shared temp base as the GLOBAL sandbox
// root. Idempotent across concurrent tests: they all compute + write the same
// absolute path. Per-test isolation comes from unique subdirs (see make_root).
@(private = "file")
fs_test_base :: proc() -> string {
	base := os.get_env_alloc("TMPDIR", context.allocator)
	if strings.trim_space(base) == "" do base = "/tmp"
	base = strings.trim_right(base, "/")
	if resolved, rerr := os.get_absolute_path(base, context.allocator); rerr == nil do base = resolved
	bridge_fs_root = base // global root = shared temp base (defense-in-depth ceiling)
	return base
}

// fs_test_make_root creates a unique per-test subdir under the shared base and
// returns its absolute path, to be passed as `sandbox_root` to every op.
@(private = "file")
fs_test_make_root :: proc(t: ^testing.T, tag: string) -> string {
	base := fs_test_base()
	root := strings.concatenate({base, "/ham_fs_test_", tag, "_", fs_test_stamp()})
	if err := os.make_directory_all(root); err != nil do testing.expect(t, false, "could not create temp root")
	if resolved, rerr := os.get_absolute_path(root, context.allocator); rerr == nil do root = resolved
	return root
}

@(private = "file")
fs_test_stamp :: proc() -> string {
	ns := time.to_unix_nanoseconds(time.now())
	b := strings.builder_make()
	strings.write_int(&b, int(ns % 1_000_000_000))
	return strings.to_string(b)
}

@(private = "file")
fs_test_cleanup :: proc(root: string) {
	if root != "" do _ = os.remove_all(root)
}

@(private = "file")
fs_test_seed_file :: proc(t: ^testing.T, root, rel, content: string) {
	full := strings.concatenate({root, "/", rel})
	parent := full[:strings.last_index_byte(full, '/')]
	_ = os.make_directory_all(parent)
	testing.expect(t, os.write_entire_file_from_string(full, content) == nil, "seed file")
}

@(private = "file")
fs_test_seed_dir :: proc(t: ^testing.T, root, rel: string) {
	full := strings.concatenate({root, "/", rel})
	testing.expect(t, os.make_directory_all(full) == nil, "seed dir")
}

// --- sort ----------------------------------------------------------------

@(test)
fs_list_sorts_dirs_first_then_name :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "sort")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "zebra.txt", "z")
	fs_test_seed_file(t, root, "apple.txt", "a")
	fs_test_seed_dir(t, root, "mango")
	fs_test_seed_dir(t, root, "banana")

	res := bridge_fs_list_dir("", true, "", 200, root)
	testing.expect(t, res.ok, "list ok")
	testing.expect_value(t, len(res.entries), 4)
	// dirs first, name asc: banana, mango, then files apple.txt, zebra.txt
	testing.expect_value(t, res.entries[0].name, "banana")
	testing.expect(t, res.entries[0].is_dir, "banana is dir")
	testing.expect_value(t, res.entries[1].name, "mango")
	testing.expect_value(t, res.entries[2].name, "apple.txt")
	testing.expect(t, !res.entries[2].is_dir, "apple is file")
	testing.expect_value(t, res.entries[3].name, "zebra.txt")
}

// --- pagination cursor ---------------------------------------------------

@(test)
fs_list_paginates_with_opaque_cursor :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "page")
	defer fs_test_cleanup(root)
	for name in ([]string{"a", "b", "c", "d", "e"}) {
		fs_test_seed_file(t, root, strings.concatenate({name, ".txt"}), name)
	}
	// Page 1: limit 2 -> a,b + has_more + next_cursor
	p1 := bridge_fs_list_dir("", true, "", 2, root)
	testing.expect(t, p1.ok, "p1 ok")
	testing.expect_value(t, len(p1.entries), 2)
	testing.expect_value(t, p1.entries[0].name, "a.txt")
	testing.expect_value(t, p1.entries[1].name, "b.txt")
	testing.expect(t, p1.has_more, "p1 has_more")
	testing.expect(t, p1.next_cursor != "", "p1 next_cursor set")
	// The cursor is an opaque base64 offset; page 1 consumed 2 entries -> offset 2.
	decoded, _ := base64.decode(p1.next_cursor, allocator = context.temp_allocator)
	testing.expect_value(t, string(decoded), "2")

	// Page 2: same limit, using cursor -> c,d + has_more
	p2 := bridge_fs_list_dir("", true, p1.next_cursor, 2, root)
	testing.expect_value(t, len(p2.entries), 2)
	testing.expect_value(t, p2.entries[0].name, "c.txt")
	testing.expect_value(t, p2.entries[1].name, "d.txt")
	testing.expect(t, p2.has_more, "p2 has_more")

	// Page 3: last entry, no more
	p3 := bridge_fs_list_dir("", true, p2.next_cursor, 2, root)
	testing.expect_value(t, len(p3.entries), 1)
	testing.expect_value(t, p3.entries[0].name, "e.txt")
	testing.expect(t, !p3.has_more, "p3 no more")
	testing.expect_value(t, p3.next_cursor, "")
}

@(test)
fs_list_malformed_cursor_falls_back_to_first_page :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "badcursor")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "a.txt", "a")
	fs_test_seed_file(t, root, "b.txt", "b")
	res := bridge_fs_list_dir("", true, "not-valid-base64!!", 200, root)
	testing.expect(t, res.ok, "ok")
	testing.expect_value(t, len(res.entries), 2)
	testing.expect_value(t, res.entries[0].name, "a.txt")
}

// --- hidden filter -------------------------------------------------------

@(test)
fs_list_hidden_filter_omits_dotfiles :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "hidden")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "visible.txt", "v")
	fs_test_seed_file(t, root, ".secret", "s")
	fs_test_seed_dir(t, root, ".git")

	// include_hidden=false -> only visible.txt
	hidden_off := bridge_fs_list_dir("", false, "", 200, root)
	testing.expect(t, hidden_off.ok, "ok")
	testing.expect_value(t, len(hidden_off.entries), 1)
	testing.expect_value(t, hidden_off.entries[0].name, "visible.txt")
	testing.expect(t, !hidden_off.entries[0].hidden, "visible not hidden")

	// include_hidden=true -> all three, with hidden flag set on dotfiles
	hidden_on := bridge_fs_list_dir("", true, "", 200, root)
	testing.expect_value(t, len(hidden_on.entries), 3)
	saw_hidden := false
	for e in hidden_on.entries {
		if e.name == ".secret" || e.name == ".git" do testing.expect(t, e.hidden, "dotfile hidden flag")
		if e.hidden do saw_hidden = true
	}
	testing.expect(t, saw_hidden, "saw a hidden entry")
}

// --- containment: list/read/create/move/delete ---------------------------

@(test)
fs_list_rejects_path_outside_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "contain_list")
	defer fs_test_cleanup(root)
	res := bridge_fs_list_dir("../../../etc", true, "", 200, root)
	testing.expect(t, !res.ok, "escape rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_read_rejects_path_outside_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "contain_read")
	defer fs_test_cleanup(root)
	res := bridge_fs_read_file("../../../etc/passwd", root)
	testing.expect(t, !res.ok, "escape rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_read_reports_not_a_file_for_dir :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "read_dir")
	defer fs_test_cleanup(root)
	fs_test_seed_dir(t, root, "adir")
	res := bridge_fs_read_file("adir", root)
	testing.expect(t, !res.ok, "dir not a file")
	testing.expect_value(t, res.error_code, "not_a_file")
}

@(test)
fs_read_gates_unsupported_type :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "read_bin")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "blob.bin", "\x00\x01\x02")
	res := bridge_fs_read_file("blob.bin", root)
	testing.expect(t, res.ok, "request ok")
	testing.expect(t, !res.viewable, "not viewable")
	testing.expect_value(t, res.error_code, "unsupported_type")
}

@(test)
fs_read_returns_utf8_text :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "read_txt")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "hello.md", "# hi")
	res := bridge_fs_read_file("hello.md", root)
	testing.expect(t, res.ok && res.viewable, "viewable")
	testing.expect_value(t, res.encoding, "utf8")
	testing.expect_value(t, res.content, "# hi")
}

@(test)
fs_create_rejects_path_outside_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "contain_create")
	defer fs_test_cleanup(root)
	res := bridge_fs_create_file("../evil.txt", root)
	testing.expect(t, !res.ok, "escape rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_create_then_path_exists :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "create_exists")
	defer fs_test_cleanup(root)
	r1 := bridge_fs_create_file("new.txt", root)
	testing.expect(t, r1.ok && r1.created, "created")
	r2 := bridge_fs_create_file("new.txt", root)
	testing.expect(t, !r2.ok, "second create fails")
	testing.expect_value(t, r2.error_code, "path_exists")
}

@(test)
fs_move_rejects_path_outside_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "contain_move")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "src.txt", "x")
	// destination escapes root
	res := bridge_fs_move("src.txt", "../escaped.txt", root)
	testing.expect(t, !res.ok, "escape rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_move_dest_exists :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "move_dest")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "a.txt", "a")
	fs_test_seed_file(t, root, "b.txt", "b")
	res := bridge_fs_move("a.txt", "b.txt", root)
	testing.expect(t, !res.ok, "dest exists rejected")
	testing.expect_value(t, res.error_code, "dest_exists")
}

@(test)
fs_move_renames_file :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "move_ok")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "old.txt", "data")
	res := bridge_fs_move("old.txt", "new.txt", root)
	testing.expect(t, res.ok, "move ok")
	testing.expect(t, !os.exists(strings.concatenate({root, "/old.txt"})), "old gone")
	testing.expect(t, os.exists(strings.concatenate({root, "/new.txt"})), "new present")
}

@(test)
fs_delete_rejects_path_outside_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "contain_delete")
	defer fs_test_cleanup(root)
	res := bridge_fs_delete("../../etc/hosts", false, root)
	testing.expect(t, !res.ok, "escape rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_delete_refuses_root :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "delete_root")
	defer fs_test_cleanup(root)
	res := bridge_fs_delete("", false, root)
	testing.expect(t, !res.ok, "root delete refused")
	testing.expect_value(t, res.error_code, "cannot_delete_root")
}

@(test)
fs_delete_non_empty_dir_requires_recursive :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "delete_nonempty")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "dir/child.txt", "c")
	// Without recursive -> dir_not_empty
	res := bridge_fs_delete("dir", false, root)
	testing.expect(t, !res.ok, "non-empty rejected")
	testing.expect_value(t, res.error_code, "dir_not_empty")
	// With recursive -> deleted
	res2 := bridge_fs_delete("dir", true, root)
	testing.expect(t, res2.ok && res2.deleted, "recursive delete ok")
	testing.expect(t, !os.exists(strings.concatenate({root, "/dir"})), "dir gone")
}

// --- project-root override semantics (hub project-scoped relay) ----------

@(test)
fs_project_root_override_scopes_listing :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "proj_root")
	defer fs_test_cleanup(root)
	// A project subtree with its own file, plus a sibling outside the project.
	fs_test_seed_file(t, root, "proj/inside.txt", "in")
	fs_test_seed_file(t, root, "outside.txt", "out")
	proj_root := strings.concatenate({root, "/proj"})

	res := bridge_fs_list_dir("", true, "", 200, proj_root)
	testing.expect(t, res.ok, "list ok")
	testing.expect_value(t, res.root, proj_root)
	testing.expect_value(t, len(res.entries), 1)
	testing.expect_value(t, res.entries[0].name, "inside.txt")
	// parent of the project root is "" (breadcrumb stops at project root).
	testing.expect_value(t, res.parent, "")
}

@(test)
fs_project_root_override_blocks_escape_above_project :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "proj_escape")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "proj/inside.txt", "in")
	fs_test_seed_file(t, root, "secret.txt", "s")
	proj_root := strings.concatenate({root, "/proj"})

	// "../secret.txt" is still within the GLOBAL bridge root but escapes the
	// project root -> must be rejected.
	res := bridge_fs_read_file("../secret.txt", proj_root)
	testing.expect(t, !res.ok, "escape above project rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_project_root_override_rejects_root_outside_bridge :: proc(t: ^testing.T) {
	_ = fs_test_make_root(t, "proj_bad_root") // pins the global base
	// A project root override that escapes the global bridge root must be refused
	// (defense-in-depth) rather than honored.
	res := bridge_fs_list_dir("", true, "", 200, "/etc")
	testing.expect(t, !res.ok, "bad project root rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}
