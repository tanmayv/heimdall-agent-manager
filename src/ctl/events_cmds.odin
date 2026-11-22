package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

EVENTS_HELP :: `ham-ctl events next [--wait 30s] [--limit 20]
ham-ctl events ack <event_id...>
ham-ctl events watch --chain <id>
ham-ctl events unwatch --chain <id>
ham-ctl events subscriptions
Events belong to this agent instance, not to your durable agent identity:
another instance of the same agent has its own subscriptions and events.
A user stop or replacement of the instance ends its subscriptions and pending
events; a restarted instance starts fresh. Acknowledge after handling.
Unacknowledged events are redelivered after 5 minutes, up to 10 attempts.`
print_help_events :: proc() {fmt.println(EVENTS_HELP)}
ctl_events_params :: proc(verb: string, tokens, args: []string) -> (params, message: string) {
	switch verb {
	case "next":
		wait := option_value(args, "--wait", "0s")
		scale := f64(1000)
		number := strings.trim_suffix(wait, "s")
		if strings.has_suffix(wait, "ms") {
			scale = 1; number = strings.trim_suffix(wait, "ms")
		} else if !strings.has_suffix(wait, "s") {
			return "", "--wait requires an s or ms suffix"
		}
		amount, wait_valid := strconv.parse_f64(number)
		milliseconds := amount * scale
		limit, valid := strconv.parse_int(option_value(args, "--limit", "20"))
		if !wait_valid || !(milliseconds >= 0 && milliseconds <= 30000) do return "", "--wait must be between 0s and 30s"
		if !valid || limit < 1 || limit > 100 do return "", "--limit must be between 1 and 100"
		data, _ := json.marshal(
			contracts.Events_Next_Input{int(milliseconds), limit},
			allocator = context.temp_allocator,
		)
		return string(data), ""
	case "ack":
		ids := tokens
		if len(ids) < 1 || len(ids) > 100 do return "", "ack requires 1..100 event ids"
		data, _ := json.marshal(contracts.Events_Ack_Input{ids}, allocator = context.temp_allocator)
		return string(data), ""
	case "watch", "unwatch":
		chain := option_value(args, "--chain", "")
		if chain == "" do return "", "--chain is required"
		data, _ := json.marshal(contracts.Events_Watch_Input{chain}, allocator = context.temp_allocator)
		return string(data), ""
	case "subscriptions":
		return "{}", ""
	}
	return "", "unknown events verb"
}
ctl_v2_events :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	if verb == "" || has_flag(args, "--help") {print_help_events(); return}
	params, message := ctl_events_params(verb, tokens[1:], args)
	if message != "" {
		data, _ := json.marshal(struct {
				ok:      bool,
				message: string,
			}{false, message}, allocator = context.temp_allocator)
		fmt.println(string(data)); os.exit(1)
	}
	ctl_agent_call_task(endpoint, token, fmt.tprintf("agent.events.%s", verb), params, args)
}
