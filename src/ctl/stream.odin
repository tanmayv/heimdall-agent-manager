package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import contracts "odin_test:contracts"

ctl_stream_usage :: proc() {
	fmt.println("ham-ctl stream share --tab <cdp-target-id> | stop <id> | list --sources tabs")
}

ctl_stream :: proc(endpoint, token: string, args: []string) {
	method, key, value: string
	switch {
	case len(args) == 3 && args[0] == "share" && args[1] == "--tab":
		method, key, value = "agent.stream.share", "tab", args[2]
	case len(args) == 2 && args[0] == "stop" && contracts.stream_id_valid(args[1]):
		method, key, value = "agent.stream.stop", "stream_id", args[1]
	case len(args) == 3 && args[0] == "list" && args[1] == "--sources" && args[2] == "tabs":
		method, key, value = "agent.stream.list", "sources", "tabs"
	case:
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
