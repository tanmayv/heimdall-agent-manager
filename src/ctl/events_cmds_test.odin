package main
import "core:encoding/json"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
test_events_cli_params_and_tokens :: proc(t: ^testing.T) {
	tokens := command_tokens([]string{"ham-ctl", "events", "next", "--wait", "30s", "--limit", "7"})
	defer delete(tokens)
	testing.expect_value(t, len(tokens), 2)
	for example in ([]struct {
			duration: string,
			expected: int,
		}{{"0s", 0}, {"30s", 30000}, {"100ms", 100}, {"1.5s", 1500}}) {
		duration, expected := example.duration, example.expected
		params, message := ctl_events_params("next", nil, []string{"--wait", duration, "--limit", "7"})
		testing.expect_value(t, message, "")
		input: contracts.Events_Next_Input
		testing.expect(t, json.unmarshal(transmute([]byte)params, &input, allocator = context.temp_allocator) == nil)
		testing.expect_value(t, input.wait_ms, expected)
		testing.expect_value(t, input.limit, 7)
	}
	for args in ([][]string {
			{"--wait", "31s"},
			{"--wait", "-1s"},
			{"--wait", "NaNs"},
			{"--wait", "garbage"},
			{"--limit", "0"},
			{"--limit", "101"},
			{"--limit", "1.2"},
		}) {
		_, message := ctl_events_params("next", nil, args)
		testing.expect(t, message != "")
	}
	params, message := ctl_events_params("ack", []string{"id_1", "id_2"}, nil)
	testing.expect_value(t, message, "")
	ack: contracts.Events_Ack_Input
	testing.expect(t, json.unmarshal(transmute([]byte)params, &ack, allocator = context.temp_allocator) == nil)
	testing.expect_value(t, len(ack.event_ids), 2)
	for verb in ([]string{"watch", "unwatch"}) {
		_, message = ctl_events_params(verb, nil, nil)
		testing.expect(t, message != "")
		params, message = ctl_events_params(verb, nil, []string{"--chain", "chain"})
		testing.expect_value(t, message, "")
		testing.expect_value(t, params, `{"chain_id":"chain"}`)
	}
	_, message = ctl_events_params("ack", nil, nil)
	testing.expect(t, message != "")
}
