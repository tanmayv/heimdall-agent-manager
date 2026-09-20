package main

// Hermetic tests for the vcs_save_file write command (TASK-4 amendment). Saving is
// a contained filesystem write (routed through bridge_fs_write_file), so a marker
// repo (a dir carrying just a .git entry, which vcs_detect_provider recognizes) is
// enough — no real git/jj needed. Shares vcs_test_make_marker_repo / vcs_test_rm
// from vcs_integration_test.odin.
//
// The success paths go through bridge_fs_write_file, which resolves the target
// within the GLOBAL bridge_fs_root; the marker repos live under /tmp, so each such
// test points the global root at /tmp (restored via defer) so the repo root is
// accepted and the within-repo containment is what's actually exercised.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// vcs_save_test_use_tmp_root sets the global fs sandbox root to a canonical /tmp for
// the duration of a test and returns the previous value so the caller can restore it.
vcs_save_test_use_tmp_root :: proc() -> string {
	old := bridge_fs_root
	bridge_fs_root = bridge_fs_canonicalize_existing("/tmp")
	return old
}

@(test)
vcs_api_save_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_save_json("s", `{"command_id":"s","root":"","path":"f.txt","content":"x"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"type":"vcs_save_file_result"`), "result type is vcs_save_file_result")
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root save ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root save -> no_vcs")
}

@(test)
vcs_api_save_missing_file :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("save-missing", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_save_json("s", fmt.tprintf(`{"command_id":"s","root":"%s","path":"","content":"x"}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "missing file save ok:false")
	testing.expect(t, strings.contains(out, `"code":"missing_file"`), "empty path -> missing_file")
}

@(test)
vcs_api_save_writes_file :: proc(t: ^testing.T) {
	old := vcs_save_test_use_tmp_root()
	defer bridge_fs_root = old
	repo := vcs_test_make_marker_repo("save-write", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_save_json("s", fmt.tprintf(`{"command_id":"s","root":"%s","path":"hello.txt","content":"hello world"}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "save writes -> ok:true")
	testing.expect(t, strings.contains(out, `"provider":"git"`), "provider resolves to git")
	data, rerr := os.read_entire_file_from_path(fmt.tprintf("%s/hello.txt", repo), context.allocator)
	testing.expect(t, rerr == nil, "saved file exists on disk")
	testing.expect(t, string(data) == "hello world", "file content matches the saved buffer")
}

@(test)
vcs_api_save_unescapes_content :: proc(t: ^testing.T) {
	// The JSON content carries an escaped newline; extract_json_string must decode it
	// so the file lands with a real two-line body.
	old := vcs_save_test_use_tmp_root()
	defer bridge_fs_root = old
	repo := vcs_test_make_marker_repo("save-nl", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_save_json("s", fmt.tprintf("{\"command_id\":\"s\",\"root\":\"%s\",\"path\":\"nl.txt\",\"content\":\"a\\nb\"}", repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "save (escaped content) -> ok:true")
	data, rerr := os.read_entire_file_from_path(fmt.tprintf("%s/nl.txt", repo), context.allocator)
	testing.expect(t, rerr == nil, "saved file exists on disk")
	testing.expect(t, string(data) == "a\nb", "escaped newline decoded to a real newline")
}

@(test)
vcs_api_save_rejects_path_traversal :: proc(t: ^testing.T) {
	// SECURITY: a "../escape.txt" path must be refused (containment via
	// bridge_fs_write_file / bridge_fs_resolve_within) and must NOT touch disk.
	old := vcs_save_test_use_tmp_root()
	defer bridge_fs_root = old
	repo := vcs_test_make_marker_repo("save-escape", ".git")
	defer vcs_test_rm(repo)
	// "../ham-vcs-save-escape-PWNED.txt" from the repo resolves to a sibling under
	// /tmp — outside the repo root, so the containment check must refuse it.
	escaped := "/tmp/ham-vcs-save-escape-PWNED.txt"
	_ = os.remove(escaped)
	out := bridge_vcs_save_json("s", fmt.tprintf(`{"command_id":"s","root":"%s","path":"../ham-vcs-save-escape-PWNED.txt","content":"pwn"}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "traversal save must be rejected")
	testing.expect(t, strings.contains(out, `"code":"path_outside_root"`), "traversal -> path_outside_root")
	testing.expect(t, !os.exists(escaped), "escaped file must not exist on disk")
}
