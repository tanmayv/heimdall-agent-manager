package main

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
	out := bridge_vcs_capabilities_json("t3", `{"command_id":"t3","root":"/home/tanmay/heimdall-agent-manager"}`)
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
