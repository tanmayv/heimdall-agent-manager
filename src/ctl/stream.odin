package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import contracts "odin_test:contracts"

ctl_stream_usage :: proc() {
	fmt.println("ham-ctl stream share --tab <cdp-target-id> | stop <id> | list --sources tabs")
}

ctl_stream_parse :: proc(tokens, argv: []string) -> (method, key, value: string) {
	tab := option_value(argv, "--tab", "")
	sources := option_value(argv, "--sources", "")
	switch {
	case len(tokens) == 2 && tokens[0] == "share" && tab != "" && tokens[1] == tab && sources == "":
		return "agent.stream.share", "tab", tab
	case len(tokens) == 2 && tokens[0] == "stop" && contracts.stream_id_valid(tokens[1]) && tab == "" && sources == "":
		return "agent.stream.stop", "stream_id", tokens[1]
	case len(tokens) == 2 && tokens[0] == "list" && sources == "tabs" && tokens[1] == sources && tab == "":
		return "agent.stream.list", "sources", sources
	}
	return "", "", ""
}

ctl_stream :: proc(endpoint, token: string, tokens, argv: []string) {
	method, key, value := ctl_stream_parse(tokens, argv)
	if method == "" {
		ctl_stream_usage()
		os.exit(2)
	}
	params := make(map[string]string, context.temp_allocator)
	params[key] = value
	encoded, err := json.marshal(params, allocator = context.temp_allocator)
	if err != nil do os.exit(1)
	raw, ok := ctl_agent_local_call(endpoint, token, method, string(encoded))
	if !ok {
		fmt.eprintln("ham-ctl stream: local Bridge is not reachable")
		os.exit(1)
	}
	reply: struct { ok: bool, data: struct { link: string } }
	if json.unmarshal_string(raw, &reply, allocator = context.temp_allocator) != nil || !reply.ok {
		fmt.eprintln(raw)
		os.exit(1)
	}
	if method == "agent.stream.share" {
		if reply.data.link == "" do os.exit(1)
		fmt.println(reply.data.link)
	} else {
		fmt.println(raw)
	}
}
