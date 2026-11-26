package main

import "core:encoding/json"
import "core:strings"
import "core:testing"

// T3 (ham-ctl parity): reconfigure / reconfigurations / cancel-reconfiguration,
// stop --force and the argument tokenizer for the new value flags.

@(private = "file")
IRC_INSTANCE_RESPONSE :: `{"v":1,"id":"r1","ok":true,"data":{"data":{"agent_instance_id":"inst_a","bridge_id":"brg_a","provider":"claude","provider_profile":"claude_work","model":"opus","project_id":"proj_a","runtime_transport":"pty","configuration_revision":4,"permission_mode":"ask"},"meta":{"request_id":"x"}}}`

@(private = "file")
irc_reconfiguration :: proc(t: ^testing.T, params: string) -> json.Object {
	value, err := json.parse_string(params, .JSON, true, context.temp_allocator)
	if !testing.expectf(t, err == nil, "params are JSON: %s", params) do return nil
	root, _ := value.(json.Object)
	testing.expect_value(t, ctl_json_object_string(root, "instance_id"), "inst_a")
	body, ok := root["reconfiguration"].(json.Object)
	testing.expect(t, ok, params)
	return body
}

@(private = "file")
irc_current :: proc(t: ^testing.T) -> Ctl_Instance_Config {
	current, ok, message := ctl_instance_config_from_response(IRC_INSTANCE_RESPONSE)
	testing.expect(t, ok, message)
	return current
}

@(test)
ctl_reconfigure_reads_the_current_instance :: proc(t: ^testing.T) {
	current := irc_current(t)
	testing.expect_value(t, current, Ctl_Instance_Config{bridge_id = "brg_a", project_id = "proj_a", provider = "claude", provider_profile = "claude_work", model = "opus", configuration_revision = 4})

	_, ok, message := ctl_instance_config_from_response(`{"v":1,"id":"r1","ok":false,"error":{"code":"hub_error","message":"instance not found"}}`)
	testing.expect(t, !ok)
	testing.expect_value(t, message, "instance not found")
	_, ok, _ = ctl_instance_config_from_response(`{"ok":true,"data":{"data":{"bridge_id":"brg_a"}}}`)
	testing.expect(t, !ok, "a response without provider/configuration_revision is refused")
}

@(test)
ctl_reconfigure_fills_every_unset_field_from_the_instance :: proc(t: ^testing.T) {
	params, ok, message := ctl_reconfigure_params("inst_a", irc_current(t), []string{"--model", "sonnet"}, "key_1")
	if !testing.expect(t, ok, message) do return
	// Exact wire body: project_id is always resent (an empty one clears the
	// project), optional keys are omitted, the revision defaults to current.
	testing.expect_value(t, params, `{"instance_id":"inst_a","reconfiguration":{"bridge_id":"brg_a","project_id":"proj_a","provider":"claude","provider_profile":"claude_work","model":"sonnet","expected_revision":4,"idempotency_key":"key_1"}}`)
}

@(test)
ctl_reconfigure_keeps_an_empty_project_id_on_the_wire :: proc(t: ^testing.T) {
	current := irc_current(t)
	current.project_id = ""
	params, ok, message := ctl_reconfigure_params("inst_a", current, nil, "key_1")
	if !testing.expect(t, ok, message) do return
	testing.expect(t, strings.contains(params, `"project_id":""`), params)
}

@(test)
ctl_reconfigure_sends_every_named_flag :: proc(t: ^testing.T) {
	args := []string{"--bridge", "brg_b", "--provider", "codex", "--profile", "codex_alt", "--model", "gpt", "--transport", "acp", "--permission-mode", "yolo", "--apply", "after_turn", "--expected-revision", "9"}
	params, ok, message := ctl_reconfigure_params("inst_a", irc_current(t), args, "key_2")
	if !testing.expect(t, ok, message) do return
	body := irc_reconfiguration(t, params)
	testing.expect_value(t, ctl_json_object_string(body, "bridge_id"), "brg_b")
	testing.expect_value(t, ctl_json_object_string(body, "project_id"), "proj_a")
	testing.expect_value(t, ctl_json_object_string(body, "provider"), "codex")
	testing.expect_value(t, ctl_json_object_string(body, "provider_profile"), "codex_alt")
	testing.expect_value(t, ctl_json_object_string(body, "model"), "gpt")
	testing.expect_value(t, ctl_json_object_string(body, "runtime_transport"), "acp")
	testing.expect_value(t, ctl_json_object_string(body, "permission_mode"), "yolo")
	testing.expect_value(t, ctl_json_object_string(body, "apply"), "after_turn")
	testing.expect_value(t, ctl_json_object_string(body, "idempotency_key"), "key_2")
	revision, _ := ctl_json_object_int(body, "expected_revision")
	testing.expect_value(t, revision, 9)
	// Only keys the hub's create handler accepts.
	for key in body {
		switch key {
		case "bridge_id", "project_id", "provider", "provider_profile", "model", "permission_mode", "runtime_transport", "apply", "expected_revision", "idempotency_key":
		case: testing.expectf(t, false, "unexpected reconfiguration key %s", key)
		}
	}
}

@(test)
ctl_reconfigure_drops_the_profile_when_the_provider_changes :: proc(t: ^testing.T) {
	params, ok, message := ctl_reconfigure_params("inst_a", irc_current(t), []string{"--provider", "codex", "--model", "gpt"}, "key_3")
	if !testing.expect(t, ok, message) do return
	testing.expect(t, !strings.contains(params, "provider_profile"), "the hub picks the new provider's default profile")
	// Same provider named explicitly keeps the current profile.
	params, ok, message = ctl_reconfigure_params("inst_a", irc_current(t), []string{"--provider", "claude"}, "key_3")
	if !testing.expect(t, ok, message) do return
	testing.expect(t, strings.contains(params, `"provider_profile":"claude_work"`), params)
}

@(test)
ctl_reconfigure_rejects_invalid_flags :: proc(t: ^testing.T) {
	current := irc_current(t)
	cases := [][]string{
		{"--transport", "ssh"},
		{"--permission-mode", "admin"},
		{"--apply", "later"},
		{"--expected-revision", "x"},
		{"--expected-revision", "-1"},
		{"--model", " "},
	}
	for args in cases {
		_, ok, message := ctl_reconfigure_params("inst_a", current, args, "key")
		testing.expectf(t, !ok && message != "", "%v must be refused", args)
	}
	_, ok, _ := ctl_reconfigure_params("", current, nil, "key")
	testing.expect(t, !ok, "an instance id is required")
	_, ok, _ = ctl_reconfigure_params("inst_a", current, nil, "")
	testing.expect(t, !ok, "an idempotency key is required")
}

@(test)
ctl_reconfigure_value_flags_are_not_positional :: proc(t: ^testing.T) {
	tokens := command_tokens([]string{"ham-ctl", "agents", "instance", "reconfigure", "--apply", "now", "--transport", "acp", "--profile", "p", "--idempotency-key", "k", "--expected-revision", "3", "inst_a"})
	defer delete(tokens)
	testing.expect_value(t, len(tokens), 4)
	testing.expect_value(t, pos(tokens[1:], 2), "inst_a")
}

@(test)
ctl_reconfigure_idempotency_key_prefers_the_flag :: proc(t: ^testing.T) {
	testing.expect_value(t, ctl_reconfigure_idempotency_key([]string{"--idempotency-key", "mine"}), "mine")
	generated := ctl_reconfigure_idempotency_key(nil)
	testing.expect(t, strings.has_prefix(generated, "ctl_") && len(generated) == len("ctl_") + 32, generated)
	testing.expect(t, generated != ctl_reconfigure_idempotency_key(nil), "each run gets a fresh key")
}

@(test)
ctl_cancel_reconfiguration_targets_the_queued_operation :: proc(t: ^testing.T) {
	// Phases are enum ordinals on the wire: 4 ready, 7 waiting_for_idle.
	list := `{"ok":true,"data":{"data":{"operations":[{"idempotency_key":"old","revision":3,"phase":4},{"idempotency_key":"queued","revision":2,"phase":7}]}}}`
	params, ok, message := ctl_cancel_reconfiguration_params("inst_a", list)
	if !testing.expect(t, ok, message) do return
	testing.expect_value(t, params, `{"instance_id":"inst_a","idempotency_key":"queued","expected_operation_revision":2}`)

	// A string phase is accepted too.
	params, ok, message = ctl_cancel_reconfiguration_params("inst_a", `{"ok":true,"data":{"data":{"operations":[{"idempotency_key":"q","revision":1,"phase":"waiting_for_idle"}]}}}`)
	testing.expect(t, ok && strings.contains(params, `"idempotency_key":"q"`), message)

	_, ok, message = ctl_cancel_reconfiguration_params("inst_a", `{"ok":true,"data":{"data":{"operations":[{"idempotency_key":"old","revision":3,"phase":4}]}}}`)
	testing.expect(t, !ok)
	testing.expect_value(t, message, "no configuration change is queued after the current turn for this instance")
	_, ok, message = ctl_cancel_reconfiguration_params("inst_a", `{"ok":false,"message":"instance not found"}`)
	testing.expect(t, !ok)
	testing.expect_value(t, message, "instance not found")
}

@(test)
ctl_stop_force_sends_force :: proc(t: ^testing.T) {
	testing.expect_value(t, ctl_instance_lifecycle_params("stop", "inst_a", []string{"--force", "--reason", "stuck"}), `{"instance_id":"inst_a","reason":"stuck","force":true}`)
	testing.expect_value(t, ctl_instance_lifecycle_params("stop", "inst_a", nil), `{"instance_id":"inst_a"}`)
	testing.expect_value(t, ctl_instance_lifecycle_params("restart", "inst_a", []string{"--force"}), `{"instance_id":"inst_a"}`)
}
