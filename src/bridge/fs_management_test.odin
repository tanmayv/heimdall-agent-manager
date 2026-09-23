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
import "core:sync"
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
	stamp := fs_test_stamp()
	defer delete(stamp)
	root := strings.concatenate({base, "/ham_fs_test_", tag, "_", stamp})
	if err := os.make_directory_all(root); err != nil do testing.expect(t, false, "could not create temp root")
	if resolved, rerr := os.get_absolute_path(root, context.allocator); rerr == nil {
		delete(root)
		root = resolved
	}
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
	if root != "" {
		_ = os.remove_all(root)
		delete(root)
	}
}

@(private = "file")
fs_test_seed_file :: proc(t: ^testing.T, root, rel, content: string) {
	full := strings.concatenate({root, "/", rel})
	defer delete(full)
	parent := full[:strings.last_index_byte(full, '/')]
	_ = os.make_directory_all(parent)
	testing.expect(t, os.write_entire_file_from_string(full, content) == nil, "seed file")
}

@(private = "file")
fs_test_seed_dir :: proc(t: ^testing.T, root, rel: string) {
	full := strings.concatenate({root, "/", rel})
	defer delete(full)
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
		fname := strings.concatenate({name, ".txt"})
		fs_test_seed_file(t, root, fname, name)
		delete(fname)
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
fs_read_honors_configured_chunk_size :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "read_chunk")
	defer fs_test_cleanup(root)
	// Seed a 30-byte file
	content := "012345678901234567890123456789"
	fs_test_seed_file(t, root, "numbers.txt", content)

	// Temporarily override chunk size to 10
	orig_chunk_size := bridge_fs_read_page_bytes
	bridge_fs_read_page_bytes = 10
	defer { bridge_fs_read_page_bytes = orig_chunk_size }

	res := bridge_fs_read_file("numbers.txt", root)
	testing.expect(t, res.ok && res.viewable, "viewable")
	testing.expect_value(t, res.bytes_returned, i64(10))
	testing.expect_value(t, res.content, "0123456789")
	testing.expect(t, !res.eof, "not eof yet")
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
	defer delete(proj_root)

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
	defer delete(proj_root)

	// "../secret.txt" is still within the GLOBAL bridge root but escapes the
	// project root -> must be rejected.
	res := bridge_fs_read_file("../secret.txt", proj_root)
	testing.expect(t, !res.ok, "escape above project rejected")
	testing.expect_value(t, res.error_code, "path_outside_root")
}

@(test)
fs_project_root_override_rejects_root_outside_bridge :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "proj_ext_root") // pins the global base
	defer fs_test_cleanup(root)

	// Valid external directories on the host (e.g. /etc or a directory outside bridge root)
	// are now accepted as valid project / task-chain roots.
	can_etc, ok_etc := bridge_fs_effective_root("/etc")
	testing.expect(t, ok_etc, "effective root for /etc ok")
	testing.expect_value(t, can_etc, "/etc")

	res_valid := bridge_fs_list_dir("", true, "", 200, "/etc")
	testing.expect(t, res_valid.ok, "valid external directory accepted")

	// Non-existent directory overrides must be rejected.
	_, ok_bad := bridge_fs_effective_root("/nonexistent_ham_fs_test_dir_12345")
	testing.expect(t, !ok_bad, "non-existent directory ok=false")

	res_nonexistent := bridge_fs_list_dir("", true, "", 200, "/nonexistent_ham_fs_test_dir_12345")
	testing.expect(t, !res_nonexistent.ok, "non-existent directory rejected")
	testing.expect_value(t, res_nonexistent.error_code, "path_outside_root")

	// Subpath containment inside the external root remains enforced: attempts to escape
	// with '..' above the root are still rejected with path_outside_root.
	res_escape := bridge_fs_read_file("../passwd", "/etc")
	testing.expect(t, !res_escape.ok, "escape above external root rejected")
	testing.expect_value(t, res_escape.error_code, "path_outside_root")
}

// --- agent instance run-dir (read-only) ----------------------------------
// The run-dir explorer sandboxes to an instance's bridge-managed run directory,
// which lives OUTSIDE the global bridge_fs_root. bridge_fs_run_dir_root resolves +
// contains it to the instances base, and list/read are called with
// root_prevalidated=true so the global-root check is skipped while the requested
// path is still re-sandboxed to the run dir.

@(test)
fs_run_dir_root_resolves_within_instances_base :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved_dir := bridge_config.local_endpoint_run_dir
	defer { bridge_config.local_endpoint_run_dir = saved_dir }

	base := fs_test_make_root(t, "rundir_base")
	defer fs_test_cleanup(base)
	bridge_config.local_endpoint_run_dir = base
	// The instance dir need not exist yet (agent may not have launched).
	root, ok := bridge_fs_run_dir_root("inst_abc123")
	defer if ok do delete(root)
	testing.expect(t, ok, "run-dir root resolves")
	testing.expect(t, strings.has_suffix(root, "/instances/inst_abc123"), "root is <base>/instances/<id>")
}

@(test)
fs_run_dir_root_sanitizes_instance_id :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved_dir := bridge_config.local_endpoint_run_dir
	defer { bridge_config.local_endpoint_run_dir = saved_dir }

	base := fs_test_make_root(t, "rundir_sanitize")
	defer fs_test_cleanup(base)
	bridge_config.local_endpoint_run_dir = base
	// Slashes are stripped by bridge_runtime_safe_part, so a traversal-looking id
	// collapses to a single contained component (cannot escape the instances base).
	dirty := "inst/../../etc"
	root, ok := bridge_fs_run_dir_root(dirty)
	defer if ok do delete(root)
	testing.expect(t, ok, "sanitized run-dir root resolves")
	expected_suffix := strings.concatenate({"/instances/", bridge_runtime_safe_part(dirty)})
	defer delete(expected_suffix)
	testing.expect(t, strings.has_suffix(root, expected_suffix), "id sanitized to one contained component")
	testing.expect(t, !strings.has_suffix(root, "/etc"), "no traversal to /etc")
}

@(test)
fs_run_dir_root_rejects_empty_instance_id :: proc(t: ^testing.T) {
	_, ok := bridge_fs_run_dir_root("")
	testing.expect(t, !ok, "empty instance id rejected")
}

@(test)
fs_run_dir_root_canonicalizes_symlinked_base :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved_dir := bridge_config.local_endpoint_run_dir
	defer { bridge_config.local_endpoint_run_dir = saved_dir }

	// Regression: on hosts where the instances base traverses a symlink (e.g.
	// macOS /tmp -> /private/tmp), the raw (unresolved) base failed to prefix-match
	// the symlink-resolved run dir, so every run-dir op returned path_outside_root.
	// bridge_fs_run_dir_root must canonicalize the base before the containment check.
	real_base := fs_test_make_root(t, "rundir_symlink_real")
	defer fs_test_cleanup(real_base)
	// A sibling symlink pointing at the real base; configure the LINK path as the
	// run dir so resolution has to follow the symlink.
	link_base := strings.concatenate({real_base, "_link"})
	defer fs_test_cleanup(link_base)
	if os.symlink(real_base, link_base) != nil {
		testing.expect(t, false, "could not create symlink base (platform lacks symlink support)")
		return
	}
	bridge_config.local_endpoint_run_dir = link_base

	root, ok := bridge_fs_run_dir_root("inst_symlink1")
	defer if ok do delete(root)
	testing.expect(t, ok, "run-dir root resolves through a symlinked base")
	testing.expect(t, strings.has_suffix(root, "/instances/inst_symlink1"), "root ends at <id>")

	// End-to-end: a listing through the resolved run dir succeeds (no path_outside_root).
	fs_test_seed_file(t, root, "AGENTS.md", "hi")
	res := bridge_fs_list_dir("", true, "", 200, root, true)
	testing.expect(t, res.ok, "list through symlinked run dir ok (no path_outside_root)")
	testing.expect_value(t, len(res.entries), 1)
}

@(test)
fs_run_dir_prevalidated_list_and_blocks_escape :: proc(t: ^testing.T) {
	run_dir := fs_test_make_root(t, "rundir_list")
	defer fs_test_cleanup(run_dir)
	fs_test_seed_file(t, run_dir, "AGENTS.md", "hello")
	fs_test_seed_file(t, run_dir, ".heimdall/bin/ham-ctl", "wrapper")

	// Prevalidated root lists the run dir even though it is passed directly (the
	// call path that a run dir OUTSIDE bridge_fs_root would take). Hidden shown.
	res := bridge_fs_list_dir("", true, "", 200, run_dir, true)
	testing.expect(t, res.ok, "prevalidated list ok")
	testing.expect_value(t, len(res.entries), 2)

	// Traversal above the run dir is still rejected.
	escape := bridge_fs_list_dir("../..", true, "", 200, run_dir, true)
	testing.expect(t, !escape.ok, "escape above run dir rejected")
	testing.expect_value(t, escape.error_code, "path_outside_root")
}

@(test)
fs_run_dir_prevalidated_read_and_blocks_escape :: proc(t: ^testing.T) {
	run_dir := fs_test_make_root(t, "rundir_read")
	defer fs_test_cleanup(run_dir)
	fs_test_seed_file(t, run_dir, "CLAUDE.md", "# context")
	// A sibling outside the run dir (under the shared temp base) to attempt escape.
	fs_test_seed_file(t, run_dir, "../rundir_read_secret.txt", "secret")
	defer fs_test_cleanup(strings.concatenate({run_dir, "/../rundir_read_secret.txt"}))

	ok_read := bridge_fs_read_file("CLAUDE.md", run_dir, 0, 0, true)
	testing.expect(t, ok_read.ok, "prevalidated read ok")
	testing.expect(t, ok_read.viewable, "file viewable")
	testing.expect_value(t, ok_read.content, "# context")

	escape := bridge_fs_read_file("../rundir_read_secret.txt", run_dir, 0, 0, true)
	testing.expect(t, !escape.ok, "read escape above run dir rejected")
	testing.expect_value(t, escape.error_code, "path_outside_root")
}

// --- grep / ripgrep search engine tests ------------------------------------

@(test)
fs_grep_ripgrep_matches_and_offsets :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "rg_matches")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "file1.txt", "hello world\nsecond line with hello again\n")
	fs_test_seed_file(t, root, "subdir/file2.txt", "no match here\nhello in subdir\n")

	res := bridge_fs_grep("hello", true, 100, root, false, "rg")
	defer bridge_fs_grep_result_delete(&res)

	testing.expect(t, res.ok, "ripgrep search succeeded")
	testing.expect_value(t, len(res.matches), 3)

	found_file1_line1 := false
	found_file1_line2 := false
	found_file2_line2 := false

	for m in res.matches {
		if m.path == "file1.txt" && m.line_number == 1 {
			found_file1_line1 = true
			testing.expect_value(t, m.column, 1)
			testing.expect_value(t, m.match_start, 0)
			testing.expect_value(t, m.match_end, 5)
			testing.expect(t, strings.contains(m.line, "hello world"), "line content matches")
		} else if m.path == "file1.txt" && m.line_number == 2 {
			found_file1_line2 = true
			testing.expect_value(t, m.column, 18)
			testing.expect_value(t, m.match_start, 17)
			testing.expect_value(t, m.match_end, 22)
		} else if m.path == "subdir/file2.txt" && m.line_number == 2 {
			found_file2_line2 = true
			testing.expect_value(t, m.column, 1)
			testing.expect_value(t, m.match_start, 0)
			testing.expect_value(t, m.match_end, 5)
		}
	}

	testing.expect(t, found_file1_line1, "found file1 line 1 match")
	testing.expect(t, found_file1_line2, "found file1 line 2 match")
	testing.expect(t, found_file2_line2, "found file2 line 2 match")
}

@(test)
fs_grep_ripgrep_exit_code_1_handled_as_zero_matches :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "rg_exit_1")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "test.txt", "some contents that do not match\n")

	res := bridge_fs_grep("nonexistent_query_xyz_12345", true, 100, root, false, "rg")
	defer bridge_fs_grep_result_delete(&res)

	testing.expect(t, res.ok, "ripgrep exit code 1 handled gracefully as ok=true")
	testing.expect_value(t, len(res.matches), 0)
	testing.expect(t, !res.truncated, "not truncated")
}

@(test)
fs_grep_grep_fallback_engine :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "grep_engine")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "notes.txt", "first line\nneedle in middle of line\nthird line\nneedle at start\n")

	res := bridge_fs_grep("needle", true, 100, root, false, "grep")
	defer bridge_fs_grep_result_delete(&res)

	testing.expect(t, res.ok, "grep search succeeded")
	testing.expect_value(t, len(res.matches), 2)
	testing.expect_value(t, res.matches[0].path, "notes.txt")
	testing.expect_value(t, res.matches[0].line_number, 2)
	testing.expect_value(t, res.matches[0].column, 1)
	testing.expect_value(t, res.matches[0].match_start, 0)
	testing.expect_value(t, res.matches[0].match_end, 6)

	testing.expect_value(t, res.matches[1].path, "notes.txt")
	testing.expect_value(t, res.matches[1].line_number, 4)
	testing.expect_value(t, res.matches[1].column, 1)

	// Zero matches with grep fallback
	no_match := bridge_fs_grep("nonexistent_pattern", true, 100, root, false, "grep")
	defer bridge_fs_grep_result_delete(&no_match)
	testing.expect(t, no_match.ok, "grep 0 matches handled as ok=true")
	testing.expect_value(t, len(no_match.matches), 0)
}

@(test)
fs_grep_bfs_fallback_engine :: proc(t: ^testing.T) {
	root := fs_test_make_root(t, "bfs_engine")
	defer fs_test_cleanup(root)
	fs_test_seed_file(t, root, "sample.txt", "first line\nsecond item target here\n")

	res := bridge_fs_grep("target", true, 100, root, false, "bfs")
	defer bridge_fs_grep_result_delete(&res)

	testing.expect(t, res.ok, "bfs search succeeded")
	testing.expect_value(t, len(res.matches), 1)
	testing.expect_value(t, res.matches[0].path, "sample.txt")
	testing.expect_value(t, res.matches[0].line_number, 2)
	testing.expect_value(t, res.matches[0].column, 13)
	testing.expect_value(t, res.matches[0].match_start, 12)
	testing.expect_value(t, res.matches[0].match_end, 18)
}

@(test)
fs_grep_result_json_serializes_column_and_bounds :: proc(t: ^testing.T) {
	matches := make([]Bridge_Fs_Grep_Match, 1)
	matches[0] = Bridge_Fs_Grep_Match{
		path = "src/main.odin",
		line_number = 42,
		column = 15,
		match_start = 14,
		match_end = 24,
		line = "fmt.println(\"hello world\")",
	}
	res := Bridge_Fs_Grep_Result{
		ok = true,
		root = "/tmp/proj",
		matches = matches,
		truncated = false,
	}
	defer delete(matches)

	json_str := bridge_fs_grep_result_json("cmd_grep_test", res)
	defer delete(json_str)

	testing.expect(t, strings.contains(json_str, "\"column\":15"), "column serialized in JSON")
	testing.expect(t, strings.contains(json_str, "\"match_start\":14"), "match_start serialized in JSON")
	testing.expect(t, strings.contains(json_str, "\"match_end\":24"), "match_end serialized in JSON")
	testing.expect(t, strings.contains(json_str, "\"line_number\":42"), "line_number serialized in JSON")
	testing.expect(t, strings.contains(json_str, "\"path\":\"src/main.odin\""), "path serialized in JSON")
}

@(test)
fs_grep_prevalidated_run_dir :: proc(t: ^testing.T) {
	run_dir := fs_test_make_root(t, "rundir_grep")
	defer fs_test_cleanup(run_dir)
	fs_test_seed_file(t, run_dir, "context.txt", "agent task run dir search test\n")

	res := bridge_fs_grep("run dir", true, 100, run_dir, true)
	defer bridge_fs_grep_result_delete(&res)

	testing.expect(t, res.ok, "prevalidated run dir grep ok")
	testing.expect_value(t, len(res.matches), 1)
	testing.expect_value(t, res.matches[0].path, "context.txt")
}
