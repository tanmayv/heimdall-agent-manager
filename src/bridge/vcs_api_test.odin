package main

import "core:fmt"
import "core:strings"
import "core:testing"

// Crash-regression + payload-correctness tests for the VCS bridge command
// handlers. These feed the exact JSON payloads the hub sends (see
// src/hub/service/bridge_handlers.odin) straight into the bridge_vcs_*_json procs
// and assert (a) the handler returns without crashing and (b) the output JSON
// carries the expected ok/provider/error fields.
//
// Two production crashes motivated these:
//   - 4486bc3: empty "root" path fed to the handlers (GPF).
//   - dabdef75: vcs_detect_provider returned a slice over a function-local array
//     (global slice), crashing on the next command.
// Tests #1/#2/#4/#5/#6 reproduce the empty/missing-path conditions to prove no
// GPF; #7 guards the old wrong-JSON-key regression (handler reads "path", not the
// legacy "file"); #3 confirms a real git repo still resolves to provider "git".

// 1. Empty root must fail safe to no_vcs (crash regression: empty path).
@(test)
vcs_api_capabilities_empty_root_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_capabilities_json("t1", `{"command_id":"t1","root":""}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root must return ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root must return no_vcs error")
}

// 2. Nonexistent path must fail safe to no_vcs (crash regression: bad path).
@(test)
vcs_api_capabilities_nonexistent_path_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_capabilities_json("t2", `{"command_id":"t2","root":"/tmp/definitely-not-a-vcs-path-heimdall-test"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "nonexistent path must return ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "nonexistent path must return no_vcs error")
}

// 3. A real git repo resolves and reports provider "git".
@(test)
vcs_api_capabilities_git_repo_returns_provider :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_capabilities_json("t3", `{"command_id":"t3","root":"."}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "git repo must return ok:true")
	testing.expect(t, strings.contains(out, `"provider":"git"`), "git repo must report provider git")
}

// 4. Missing "root" key entirely (old hub bug) must fail safe to no_vcs.
@(test)
vcs_api_capabilities_missing_root_key_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_capabilities_json("t4", `{"command_id":"t4"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "missing root key must return ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "missing root key must return no_vcs error")
}

// 5. Empty root on vcs_files must fail safe (crash regression: empty path).
@(test)
vcs_api_files_empty_root_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_files_json("t5", `{"command_id":"t5","root":"","cursor":"","limit":0}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root files must return ok:false")
}

// 6. Empty root on vcs_diff must fail safe (crash regression: empty path).
@(test)
vcs_api_diff_empty_root_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_diff_json("t6", `{"command_id":"t6","root":"","path":"README.md","cursor":"","limit":0}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root diff must return ok:false")
}

// 7. Real repo but no "path" key must fail safe, not crash (regression for the
// old wrong-key bug: the handler reads "path", and an absent path is rejected).
@(test)
vcs_api_diff_missing_path_key_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_diff_json("t7", `{"command_id":"t7","root":"/home/tanmay/heimdall-agent-manager"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "missing path key must return ok:false")
}

// --- new VCS command handlers (TASK-1-TEST Part A) ------------------------
// Coverage for the vcs_stage/unstage/revert/log/commit_diff/workspaces handlers added
// in TASK-1. Empty-root cases prove the shared no_vcs fail-safe. Detection-only cases
// (missing-file, jj not_supported, same-ref) run against a hermetic marker repo — a
// temp dir carrying just a .git/.jj entry, which vcs_detect_provider recognizes without
// the real tool, and whose handler path returns before any subprocess runs. The
// real-repo cases run against this checkout and skip (like
// vcs_api_capabilities_git_repo_returns_provider) when it is not a git repo. The
// vcs_test_* helpers live in vcs_integration_test.odin (same package).
//
// vcs_stage_not_cached (task item): the write handlers must NOT be command_id-cached,
// because a mutation is not idempotent. This is enforced in vcs_api.odin —
// bridge_vcs_handle_command's vcs_stage/vcs_unstage/vcs_revert cases call
// bridge_vcs_*_json DIRECTLY, with no bridge_runtime_cached_command lookup or
// bridge_runtime_cache_command store (unlike every read handler). Verified by
// inspection of the dispatch; it needs a live ws.Connection to exercise at runtime, so
// there is no hermetic assertion for it here.

@(test)
vcs_api_capabilities_new_fields :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_capabilities_json("c", `{"command_id":"c","root":"."}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "git repo returns ok:true")
	testing.expect(t, strings.contains(out, `"staging_model":"index"`), "git staging_model is index")
	testing.expect(t, strings.contains(out, `"stage"`), "supported_actions include stage")
	testing.expect(t, strings.contains(out, `"unstage"`), "supported_actions include unstage")
	testing.expect(t, strings.contains(out, `"workspaces"`), "supported_actions include workspaces")
}

@(test)
vcs_api_stage_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_stage_json("s", `{"command_id":"s","root":"","path":"f.txt"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root stage ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root stage -> no_vcs")
}

@(test)
vcs_api_stage_empty_file :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("stage-empty-file", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_stage_json("s", fmt.tprintf(`{"command_id":"s","root":"%s","path":""}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty file stage ok:false")
	testing.expect(t, strings.contains(out, `"code":"missing_file"`), "empty file -> missing_file")
}

@(test)
vcs_api_unstage_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_unstage_json("u", `{"command_id":"u","root":"","path":"f.txt"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root unstage ok:false")
}

@(test)
vcs_api_unstage_not_supported_jj :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("unstage-jj", ".jj")
	defer vcs_test_rm(repo)
	out := bridge_vcs_unstage_json("u", fmt.tprintf(`{"command_id":"u","root":"%s","path":"f.txt"}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "jj unstage ok:false")
	testing.expect(t, strings.contains(out, `"provider":"jj"`), "provider resolves to jj")
	testing.expect(t, strings.contains(out, `"code":"not_supported"`), "jj unstage -> not_supported")
}

@(test)
vcs_api_revert_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_revert_json("r", `{"command_id":"r","root":"","path":"f.txt"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root revert ok:false")
}

@(test)
vcs_api_revert_missing_file :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("revert-missing", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_revert_json("r", fmt.tprintf(`{"command_id":"r","root":"%s","path":""}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "missing file revert ok:false")
	testing.expect(t, strings.contains(out, `"code":"missing_file"`), "missing file -> missing_file")
}

@(test)
vcs_api_log_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_log_json("l", `{"command_id":"l","root":""}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root log ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root log -> no_vcs")
}

@(test)
vcs_api_log_real_repo :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_log_json("l", `{"command_id":"l","root":".","limit":5}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "log ok:true on real repo")
	testing.expect(t, strings.contains(out, `"entries":[`), "entries is an array")
}

@(test)
vcs_api_commit_diff_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_commit_diff_json("cd", `{"command_id":"cd","root":"","base_ref":"HEAD"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root commit_diff ok:false")
}

@(test)
vcs_api_commit_diff_same_ref :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("commit-diff-same", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_commit_diff_json("cd", fmt.tprintf(`{"command_id":"cd","root":"%s","base_ref":"HEAD","head_ref":"HEAD"}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "base_ref == head_ref -> ok:true")
	testing.expect(t, strings.contains(out, `"hunks":[]`), "base_ref == head_ref -> empty hunks")
}

// list_files mode: a real repo with list_files:true returns "list_files":true and a
// "files":[ array (never "hunks"). Skips when this checkout is not a git repo.
@(test)
vcs_api_commit_diff_list_files_real :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_commit_diff_json("cd", `{"command_id":"cd","root":".","base_ref":"HEAD~1","head_ref":"HEAD","list_files":true}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "list_files real repo -> ok:true")
	testing.expect(t, strings.contains(out, `"list_files":true`), "response echoes list_files:true")
	testing.expect(t, strings.contains(out, `"files":[`), "response carries a files array")
	testing.expect(t, !strings.contains(out, `"hunks":`), "list_files response has no hunks field")
	// Well-formedness: list_files is a bare bool token, so it must be immediately
	// followed by a proper key separator (,"base_ref"), never a stray quote (`true"`).
	testing.expect(t, strings.contains(out, `"list_files":true,"base_ref":`), "list_files:true is followed by a clean key separator")
	testing.expect(t, !strings.contains(out, `true",`), "no stray quote after the list_files bool (malformed-JSON guard)")
	testing.expect(t, strings.contains(out, `"head_ref":"HEAD"`), "head_ref echoed back verbatim")
}

// no-regression: list_files absent (default false) still returns the hunk shape.
@(test)
vcs_api_commit_diff_hunks_default :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_commit_diff_json("cd", `{"command_id":"cd","root":".","base_ref":"HEAD~1","head_ref":"HEAD"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "default mode real repo -> ok:true")
	testing.expect(t, strings.contains(out, `"hunks":[`), "default mode carries a hunks array")
	testing.expect(t, !strings.contains(out, `"list_files":true`), "default mode does not set list_files")
}

// jj provider has commit_diff_files=nil, so list_files mode on a .jj marker repo
// must fail safe to not_supported (detection-only path, no jj binary needed).
@(test)
vcs_api_commit_diff_list_files_jj_not_supported :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("commit-diff-files-jj", ".jj")
	defer vcs_test_rm(repo)
	out := bridge_vcs_commit_diff_json("cd", fmt.tprintf(`{"command_id":"cd","root":"%s","base_ref":"HEAD","head_ref":"HEAD~1","list_files":true}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "jj list_files -> ok:false")
	testing.expect(t, strings.contains(out, `"provider":"jj"`), "provider resolves to jj")
	testing.expect(t, strings.contains(out, `"list_files":true`), "error still echoes list_files:true")
	testing.expect(t, strings.contains(out, `"code":"not_supported"`), "jj list_files -> not_supported")
}

// vcs_commit handler: empty root -> no_vcs (fail-safe, no crash).
@(test)
vcs_api_commit_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_commit_json("cm", `{"command_id":"cm","root":"","message":"x"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root commit ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root commit -> no_vcs")
}

// vcs_commit handler: a real (marker) git repo but an empty message -> missing_message,
// before any git runs.
@(test)
vcs_api_commit_missing_message :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("commit-missing-msg", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_commit_json("cm", fmt.tprintf(`{"command_id":"cm","root":"%s","message":""}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty message commit ok:false")
	testing.expect(t, strings.contains(out, `"provider":"git"`), "provider resolves to git")
	testing.expect(t, strings.contains(out, `"code":"missing_message"`), "empty message -> missing_message")
}

// vcs_commit handler: jj provider has commit=nil -> not_supported (detection-only path).
@(test)
vcs_api_commit_jj_not_supported :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("commit-jj", ".jj")
	defer vcs_test_rm(repo)
	out := bridge_vcs_commit_json("cm", fmt.tprintf(`{"command_id":"cm","root":"%s","message":"hi"}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "jj commit ok:false")
	testing.expect(t, strings.contains(out, `"provider":"jj"`), "provider resolves to jj")
	testing.expect(t, strings.contains(out, `"code":"not_supported"`), "jj commit -> not_supported")
}

@(test)
vcs_api_workspaces_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_workspaces_json("w", `{"command_id":"w","root":""}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root workspaces ok:false")
}

@(test)
vcs_api_workspaces_real_repo :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_workspaces_json("w", `{"command_id":"w","root":"."}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "workspaces ok:true on real repo")
	testing.expect(t, strings.contains(out, `"is_current":true`), "the queried worktree is current")
}
