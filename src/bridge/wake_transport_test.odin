package main

import "core:encoding/json"
import "core:testing"

@(test)
test_wake_synthetic_launch_preserves_runtime_transport_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	command := bridge_wake_launch_command_json("cmd", "inst", "task", "worker", "claude", "opus", "agt", "Worker", "chain", "Title", "coord", "proj", "/project", effective_transport="acp", catalog_etag="sha256:catalog", launch_epoch="launch_epoch", provider_profile="work", run_count=4)
	value, err := json.parse(command)
	if !testing.expect(t, err == nil, command) do return
	defer json.destroy_value(value)
	object := value.(json.Object)
	payload := object["payload"].(json.Object)
	testing.expect_value(t, string(payload["effective_transport"].(json.String)), "acp")
	testing.expect_value(t, string(payload["catalog_etag"].(json.String)), "sha256:catalog")
	testing.expect_value(t, string(payload["launch_epoch"].(json.String)), "launch_epoch")
	testing.expect_value(t, string(payload["instance_token"].(json.String)), "hit_inst~launch_epoch")
	// The launch path extracts this field before consulting any cached assertion.
	assertion := extract_json_string(command, "instance_token", "")
	defer delete(assertion)
	testing.expect_value(t, assertion, "hit_inst~launch_epoch")
	testing.expect_value(t, string(payload["provider_profile"].(json.String)), "work")
	legacy := bridge_wake_launch_command_json("cmd", "inst", "task", "worker", "claude", "opus", "agt", "Worker", "chain", "Title", "coord", "proj", "/project")
	old, old_err := json.parse(legacy)
	if !testing.expect(t, old_err == nil) do return
	defer json.destroy_value(old)
	legacy_payload := old.(json.Object)["payload"].(json.Object)
	testing.expect_value(t, string(legacy_payload["effective_transport"].(json.String)), "pty")
	testing.expect_value(t, string(legacy_payload["launch_epoch"].(json.String)), "")
}
