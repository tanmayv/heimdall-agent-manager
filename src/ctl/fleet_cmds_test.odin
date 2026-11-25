package main

import "core:testing"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import httpc "odin_test:lib/httpc"

@(test)
test_ctl_bridge_fleet_read_status_retry_routes :: proc(t: ^testing.T) {
	for example in ([]struct{verb,path:string,method:httpc.Method}{
		{"show","/api/v1/bridges/brg_one/launch-defaults",.GET},
		{"defaults","/api/v1/bridges/brg_one/launch-defaults",.GET},
		{"overrides","/api/v1/bridges/brg_one/agent-overrides",.GET},
		{"status","/api/v1/bridges/brg_one/fleet/applications/fleet_apply_one",.GET},
		{"retry","/api/v1/bridges/brg_one/fleet/applications/fleet_apply_one/retry",.POST},
	}) {
		req, ok, message := ctl_bridge_fleet_request(example.verb,"brg_one","fleet_apply_one",nil)
		testing.expect(t,ok && message=="")
		testing.expect_value(t,req.method,example.method)
		testing.expect_value(t,ctl_test_target(t,req),example.path)
	}
	_, ok, _ := ctl_bridge_fleet_request("apply","brg_one","",nil)
	testing.expect(t,!ok,"complete draft file is required")
	_, ok, _ = ctl_bridge_fleet_request("status","brg_one","",nil)
	testing.expect(t,!ok)
}

@(test)
test_ctl_bridge_fleet_apply_draft_is_json_object :: proc(t:^testing.T) {
	sync.mutex_lock(&vault_test_mutex);defer sync.mutex_unlock(&vault_test_mutex)
	sb:=ctl_vault_test_sandbox_open("fleet-draft");defer ctl_vault_test_sandbox_close(&sb)
	path:=strings.concatenate({sb.dir,"/draft.json"},context.temp_allocator)
	draft:=`{"request_id":"stable","expected_revision":7,"default_runtime":{"provider":"codex","model":"m"},"overrides":[]}`
	if !testing.expect(t,os.write_entire_file(path,transmute([]byte)draft)==nil) do return
	req,ok,message:=ctl_bridge_fleet_request("apply","brg_one","",[]string{"--draft-file",path})
	if !testing.expect(t,ok,message) do return
	testing.expect_value(t,req.method,httpc.Method.POST)
	testing.expect_value(t,ctl_test_target(t,req),"/api/v1/bridges/brg_one/fleet/apply")
	body:=capability_body(t,req)
	testing.expect_value(t,body["request_id"].(json.String),json.String("stable"))
	testing.expect_value(t,body["expected_revision"].(json.Integer),json.Integer(7))
}
