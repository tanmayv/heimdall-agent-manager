package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"

CHANNEL_HELP :: `ham-ctl channel read [--limit N]        Read your owner's unanswered Telegram messages (marks them read).
ham-ctl channel send --text <text>      Send plaintext to your owner's paired Telegram chat.
ham-ctl channel send --text-file <path> Same, text read from a UTF-8 file.
ham-ctl channel history [--limit N]     Recent Telegram messages in both directions, newest first.
Only a bot instance may use these verbs. Telegram messages are not end-to-end encrypted.`

print_help_channel :: proc() {
	fmt.println(CHANNEL_HELP)
}

// Params use the temporary allocator, including file bytes and JSON. No vault
// sealing occurs here: the channel transport explicitly accepts plaintext.
ctl_channel_params :: proc(verb: string, args: []string) -> (params, message: string) {
	switch verb {
	case "read", "history":
		limit, valid := strconv.parse_int(option_value(args, "--limit", "20"))
		maximum := 50
		if verb == "history" do maximum = 100
		if !valid || limit < 1 || limit > maximum do return "", fmt.tprintf("--limit must be between 1 and %d", maximum)
		data, marshal_err := json.marshal(struct {limit: int}{limit}, allocator = context.temp_allocator)
		if marshal_err != nil do return "", "cannot encode channel limit"
		return string(data), ""
	case "send":
		text := option_value(args, "--text", "")
		path := option_value(args, "--text-file", "")
		if has_flag(args, "--text") && has_flag(args, "--text-file") do return "", "use either --text or --text-file"
		if path != "" {
			data, err := os.read_entire_file(path, context.temp_allocator)
			if err != nil do return "", "cannot read --text-file"
			text = string(data)
		}
		if text == "" do return "", "channel send requires --text or --text-file"
		data, err := json.marshal(struct {text: string}{text}, allocator = context.temp_allocator)
		if err != nil do return "", "cannot encode channel text"
		return string(data), ""
	}
	return "", "unknown channel verb"
}

ctl_v2_channel :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	if verb == "" || has_flag(args, "--help") {
		print_help_channel()
		return
	}
	params, message := ctl_channel_params(verb, args)
	if message != "" {
		data, _ := json.marshal(struct {ok: bool, message: string}{false, message}, allocator = context.temp_allocator)
		fmt.println(string(data))
		os.exit(1)
	}
	ctl_agent_call_task(endpoint, token, fmt.tprintf("agent.channel.%s", verb), params, args)
}
