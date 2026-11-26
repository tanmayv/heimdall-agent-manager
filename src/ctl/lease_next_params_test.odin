package main

import "core:testing"

// `lease next` params (REQ-SCHED-39): the bridge adds the stored pack_version;
// --refresh sends an empty one so the hub builds the pack and TASK.md is rewritten.
@(test)
test_lease_next_params_refresh :: proc(t: ^testing.T) {
	plain := ctl_v2_lease_next_params([]string{"ham-ctl", "lease", "next"}, "/work")
	testing.expect_value(t, plain, `{"cwd":"/work"}`)
	refresh := ctl_v2_lease_next_params([]string{"ham-ctl", "lease", "next", "--refresh", "--vcs-base", "abc"}, "/work")
	testing.expect_value(t, refresh, `{"vcs_base":"abc","cwd":"/work","pack_version":""}`)
}
