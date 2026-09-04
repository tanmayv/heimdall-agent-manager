package main

// Agent API v2 (see docs/agent-api-redesign.md).
//
// One flat `agent.<domain>.<verb>` method namespace, routed by a SINGLE pure
// table (`bridge_agent_route`) instead of the old three near-identical relay
// procs (agent-actions envelope / admin raw-REST / instance-lifecycle raw-REST).
//
// Each method resolves to a Bridge_Agent_Route describing HOW the bridge fulfils
// it:
//   .Envelope  POST /api/v1/agent-actions/... with {method, agent_instance_id,
//              params} (the hub reads the caller from the instance token).
//   .Raw       direct REST call (method+path) with the instance token header;
//              params become the body for writes, query already baked into path.
//   .Local     served by the bridge itself with NO hub round-trip (e.g. listing
//              locally-configured peer bridges).
//
// Auth invariant (unchanged): agent token in -> bridge authenticates + strips ->
// forwards to hub with the bridge token + X-Heimdall-Instance-Token. Agents
// never see a hub URL or hub token.

import "core:strings"

Bridge_Agent_Route_Kind :: enum {
	Unknown,   // method not allowed / not found
	Envelope,  // agent-actions envelope POST
	Raw,       // raw REST relay with instance token
	Local,     // bridge-served, no hub call
}

Bridge_Agent_Route :: struct {
	kind:        Bridge_Agent_Route_Kind,
	http_method: string, // for .Raw
	path:        string, // for .Raw / .Envelope (envelope path is fixed per method)
	// local_op names the bridge-local handler for .Local routes.
	local_op:    string,
	// send_body: for .Raw, whether params should be forwarded as the request body.
	send_body:   bool,
}

// bridge_agent_route is the ONE place that maps a v2 method + params to its
// fulfilment. Pure (no I/O) so it is unit-testable. Returns .Unknown for any
// method not in the allowlist. Caller owns any concatenated path string.
bridge_agent_route :: proc(method, params: string) -> Bridge_Agent_Route {
	switch method {
	// ---- bridge discovery -------------------------------------------------
	case "agent.bridge.list":
		// scope hub|configured|all (default all) decided bridge-side; the local
		// merge is done in the handler, so this is a Local op.
		return Bridge_Agent_Route{kind = .Local, local_op = "bridge.list"}
	case "agent.bridge.providers":
		bridge_id := bridge_local_extract_json_string(params, "bridge_id", "")
		if strings.trim_space(bridge_id) != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = strings.concatenate({"/api/v1/bridges/", bridge_id, "/providers"})}
		}
		// no bridge_id => list bridges (each carries its provider matrix)
		return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/bridges"}

	// ---- agents: durable identities --------------------------------------
	case "agent.agents.list":
		return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/agents"}
	case "agent.agents.create":
		return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = "/api/v1/agents", send_body = true}

	// ---- agents: templates ------------------------------------------------
	case "agent.agents.template_list":
		return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/templates"}
	case "agent.agents.template_create":
		return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = "/api/v1/templates", send_body = true}

	// ---- agents: instances ------------------------------------------------
	case "agent.agents.instance_list":
		// live filter -> live envelope; else durable instance list (raw GET).
		if bridge_agent_params_bool(params, "live") {
			return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/agents/live"}
		}
		agent_id := bridge_local_extract_json_string(params, "agent_id", "")
		if strings.trim_space(agent_id) != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = strings.concatenate({"/api/v1/agent-instances?agent_id=", agent_id})}
		}
		return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/agent-instances"}
	case "agent.agents.new_instance":
		return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = "/api/v1/agent-instances", send_body = true}
	case "agent.agents.instance_start":
		if id := bridge_agent_instance_id(params); id != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = strings.concatenate({"/api/v1/agent-instances/", id, "/start"})}
		}
	case "agent.agents.instance_restart":
		if id := bridge_agent_instance_id(params); id != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = strings.concatenate({"/api/v1/agent-instances/", id, "/restart"})}
		}
	case "agent.agents.instance_stop":
		if id := bridge_agent_instance_id(params); id != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = strings.concatenate({"/api/v1/agent-instances/", id, "/stop"}), send_body = true}
		}

	// ---- task-chain -------------------------------------------------------
	case "agent.task_chain.list":
		// coordinated_by_me -> chains this agent coordinates (hub defaults the
		// coordinator to the caller's own instance from the instance token).
		if bridge_agent_params_bool(params, "coordinated_by_me") {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/task-chains?coordinated_by="}
		}
		if pid := bridge_local_extract_json_string(params, "project_id", ""); strings.trim_space(pid) != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = strings.concatenate({"/api/v1/task-chains?project_id=", pid})}
		}
		return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/task-chains"}
	case "agent.task_chain.show":
		if cid := bridge_local_extract_json_string(params, "chain_id", ""); strings.trim_space(cid) != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = strings.concatenate({"/api/v1/task-chains/", cid})}
		}
		// no chain_id => fall back to the caller's context snapshot (envelope).
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/context"}
	case "agent.task_chain.set_title":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chain/set-title"}
	case "agent.task_chain.reconcile":
		// explicit self-heal kickoff / re-plan (coordinator or owner only, enforced
		// hub-side). Needs chain_id; without it there's nothing to reconcile.
		if cid := bridge_local_extract_json_string(params, "chain_id", ""); strings.trim_space(cid) != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = strings.concatenate({"/api/v1/task-chains/", cid, "/reconcile"})}
		}

	// ---- task -------------------------------------------------------------
	case "agent.task.list":
		if cid := bridge_local_extract_json_string(params, "chain_id", ""); strings.trim_space(cid) != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = strings.concatenate({"/api/v1/task-chains/", cid, "/tasks"})}
		}
		// no chain_id => caller's context snapshot lists the caller's tasks.
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/context"}
	case "agent.task.show":
		// slim task detail (task + comment_summary + votes; no comment bodies).
		// Needs chain_id + task_id; if chain_id is absent, fall back to context.
		cid := bridge_local_extract_json_string(params, "chain_id", "")
		tid := bridge_agent_task_id(params)
		if strings.trim_space(cid) != "" && tid != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = strings.concatenate({"/api/v1/task-chains/", cid, "/tasks/", tid})}
		}
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/context"}
	case "agent.task.comments":
		// the newest N comments (bodies) for a task: GET .../comments?last=N.
		cid := bridge_local_extract_json_string(params, "chain_id", "")
		tid := bridge_agent_task_id(params)
		if strings.trim_space(cid) != "" && tid != "" {
			base := strings.concatenate({"/api/v1/task-chains/", cid, "/tasks/", tid, "/comments"})
			if last := bridge_local_extract_json_string(params, "last", ""); strings.trim_space(last) != "" {
				return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = strings.concatenate({base, "?last=", last})}
			}
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = base}
		}
		// task_id without chain_id can't address the comments endpoint.
	case "agent.task.create":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/create"}
	case "agent.task.depend":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/depend"}
	case "agent.task.comment":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/comment"}
	case "agent.task.status":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/status"}
	case "agent.task.set_current":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/set-current"}
	case "agent.task.vote":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/vote"}
	case "agent.task.nudge":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/nudge"}

	// ---- chat -------------------------------------------------------------
	case "agent.chat.send":
		// to == "user" -> send-to-user; else to is an agent-instance-id.
		to := strings.trim_space(bridge_local_extract_json_string(params, "to", ""))
		if to == "user" {
			return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chat/send-to-user"}
		}
		if to != "" {
			return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chat/send-to-agent"}
		}
		// missing to -> Unknown so the handler returns a bad_request.
	case "agent.chat.read":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chat/read"}

	// ---- instance-self / misc --------------------------------------------
	case "agent.context.get":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/context"}
	case "agent.conversation.set_title":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/conversation/set-title"}
	case "agent.memory.propose":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/memory/propose"}
	case "agent.artifact.create":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/artifacts/create"}
	case "agent.artifact.list":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/artifacts/list"}
	case "agent.artifact.show":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/artifacts/show"}
	case "agent.artifact.content":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/artifacts/content"}
	}
	return Bridge_Agent_Route{kind = .Unknown}
}

// bridge_agent_method_allowed reports whether a v2 method is dispatchable. This
// is a membership check on the METHOD name only (independent of params): a method
// like agent.chat.send is allowed even though its route needs a valid `to` in
// params (a missing/invalid `to` becomes a bad_request at dispatch, not a
// forbidden). The self/bridge-handled methods that never leave the bridge
// (start_success, activity, permission, rest.request) are also allowed.
bridge_agent_method_allowed :: proc(method: string) -> bool {
	switch method {
	case "agent.start_success", "agent.activity.report",
	     "agent.permission.request", "agent.permission.reply",
	     "agent.rest.request",
	     // discovery + agents
	     "agent.bridge.list", "agent.bridge.providers",
	     "agent.agents.list", "agent.agents.create",
	     "agent.agents.template_list", "agent.agents.template_create",
	     "agent.agents.instance_list", "agent.agents.new_instance",
	     "agent.agents.instance_start", "agent.agents.instance_restart",
	     "agent.agents.instance_stop",
	     // task-chain + task
	     "agent.task_chain.list", "agent.task_chain.show", "agent.task_chain.set_title",
	     "agent.task_chain.reconcile",
	     "agent.task.list", "agent.task.show", "agent.task.comments", "agent.task.create",
	     "agent.task.depend", "agent.task.comment", "agent.task.status",
	     "agent.task.set_current", "agent.task.vote", "agent.task.nudge",
	     // chat + self/misc
	     "agent.chat.send", "agent.chat.read",
	     "agent.context.get", "agent.conversation.set_title", "agent.memory.propose",
	     "agent.artifact.create", "agent.artifact.list", "agent.artifact.show",
	     "agent.artifact.content":
		return true
	}
	return false
}

// ---- small param helpers (pure) -----------------------------------------

bridge_agent_params_bool :: proc(params, key: string) -> bool {
	// accepts "key":true or "key":"true"
	if strings.contains(params, strings.concatenate({"\"", key, "\":true"})) do return true
	if bridge_local_extract_json_string(params, key, "") == "true" do return true
	return false
}

bridge_agent_instance_id :: proc(params: string) -> string {
	id := bridge_local_extract_json_string(params, "instance_id", "")
	if strings.trim_space(id) == "" do id = bridge_local_extract_json_string(params, "agent_instance_id", "")
	return strings.trim_space(id)
}

bridge_agent_task_id :: proc(params: string) -> string {
	id := bridge_local_extract_json_string(params, "task_id", "")
	return strings.trim_space(id)
}

// bridge_agent_rewrite_params adapts v2 params to what a specific hub endpoint
// expects, keeping the CLI/wire surface clean. Currently: agent.chat.send with a
// non-"user" `to` maps `to` -> `to_instance` for /chat/send-to-agent. Returns the
// (possibly rewritten) params; caller uses the result verbatim.
bridge_agent_rewrite_params :: proc(method, params: string) -> string {
	if method == "agent.chat.send" {
		to := strings.trim_space(bridge_local_extract_json_string(params, "to", ""))
		if to != "" && to != "user" {
			// inject to_instance = to (the hub's send-to-agent expects to_instance).
			body := strings.trim_space(params)
			if body == "" || body == "{}" {
				return strings.concatenate({"{\"to_instance\":\"", to, "\"}"})
			}
			// insert to_instance right after the opening brace.
			return strings.concatenate({"{\"to_instance\":\"", to, "\",", body[1:]})
		}
	}
	return params
}

// ---- local op handlers (bridge-served, no hub) --------------------------

// bridge_local_handle_agent_local_op fulfils .Local routes. Currently only
// bridge.list, which merges Hub-registered bridges + locally-configured peers +
// self, per docs/agent-api-redesign.md §2.1.
bridge_local_handle_agent_local_op :: proc(request_id, op, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	if op == "bridge.list" {
		scope := strings.trim_space(bridge_local_extract_json_string(params, "scope", "all"))
		if scope == "" do scope = "all"

		b := strings.builder_make()
		strings.write_string(&b, "{\"scope\":\"")
		bridge_local_write_json_string(&b, scope)
		strings.write_string(&b, "\",\"bridges\":[")
		first := true

		// Hub-registered bridges (scope hub|all): relay GET /api/v1/bridges and
		// splice each row through, tagged origin=hub.
		if (scope == "hub" || scope == "all") && strings.trim_space(rec.instance_token) != "" {
			relay := bridge_local_relay_raw("GET", "/api/v1/bridges", "", rec)
			if relay.ok && relay.status >= 200 && relay.status < 300 {
				for obj in bridge_agent_json_array_objects(bridge_agent_json_data_array(relay.body)) {
					if !first do strings.write_byte(&b, ',')
					first = false
					strings.write_string(&b, "{\"origin\":\"hub\",\"bridge\":")
					strings.write_string(&b, obj)
					strings.write_byte(&b, '}')
				}
			}
		}

		// Self + configured peers (scope configured|all): served locally.
		if scope == "configured" || scope == "all" {
			// self row
			if !first do strings.write_byte(&b, ',')
			first = false
			strings.write_string(&b, "{\"origin\":\"self\",\"daemon_id\":\"")
			bridge_local_write_json_string(&b, string(bridge_config.daemon_id))
			strings.write_string(&b, "\",\"local_endpoint_port\":")
			strings.write_string(&b, bridge_agent_itoa(int(bridge_config.local_endpoint_port)))
			strings.write_string(&b, "}")
			// configured peers
			for i in 0..<len(bridge_peer_states) {
				p := &bridge_peer_states[i]
				if !first do strings.write_byte(&b, ',')
				first = false
				strings.write_string(&b, "{\"origin\":\"configured\",\"name\":\"")
				bridge_local_write_json_string(&b, p.name)
				strings.write_string(&b, "\",\"daemon_id\":\"")
				bridge_local_write_json_string(&b, string(p.daemon_id))
				strings.write_string(&b, "\",\"endpoint\":\"")
				bridge_local_write_json_string(&b, p.endpoint)
				strings.write_string(&b, "\",\"reachability\":\"")
				strings.write_string(&b, "linked" if p.status == .Linked else "unreachable")
				strings.write_string(&b, "\",\"active_sessions\":")
				strings.write_string(&b, bridge_agent_itoa(p.active_sessions))
				strings.write_string(&b, ",\"last_error\":\"")
				bridge_local_write_json_string(&b, p.last_error)
				strings.write_string(&b, "\"}")
			}
		}

		strings.write_string(&b, "]}")
		return bridge_local_response_data(request_id, strings.to_string(b))
	}
	return bridge_local_response_error(request_id, "bad_request", strings.concatenate({"unknown local op: ", op}))
}

// bridge_agent_itoa: tiny positive-int to string without importing fmt here.
bridge_agent_itoa :: proc(n: int) -> string {
	if n == 0 do return "0"
	v := n
	neg := v < 0
	if neg do v = -v
	buf: [24]byte
	i := len(buf)
	for v > 0 {
		i -= 1
		buf[i] = byte('0' + (v % 10))
		v /= 10
	}
	if neg { i -= 1; buf[i] = '-' }
	return strings.clone(string(buf[i:]))
}

// bridge_agent_json_data_array returns the raw text of the top-level "data"
// array from a hub list response ({"data":[...],...}); "" if absent.
bridge_agent_json_data_array :: proc(body: string) -> string {
	key := "\"data\""
	idx := strings.index(body, key)
	if idx < 0 do return ""
	rest := body[idx + len(key):]
	lb := strings.index_byte(rest, '[')
	if lb < 0 do return ""
	depth := 0
	in_str := false
	esc := false
	for i := lb; i < len(rest); i += 1 {
		ch := rest[i]
		if in_str {
			if esc { esc = false; continue }
			if ch == '\\' { esc = true; continue }
			if ch == '"' do in_str = false
			continue
		}
		if ch == '"' { in_str = true; continue }
		if ch == '[' do depth += 1
		if ch == ']' { depth -= 1; if depth == 0 do return rest[lb:i + 1] }
	}
	return ""
}

// bridge_agent_json_array_objects splits a JSON array's top-level object elements
// into a slice of their raw {..} texts.
bridge_agent_json_array_objects :: proc(array: string) -> []string {
	out := make([dynamic]string)
	depth := 0
	in_str := false
	esc := false
	start := -1
	for i := 0; i < len(array); i += 1 {
		ch := array[i]
		if in_str {
			if esc { esc = false; continue }
			if ch == '\\' { esc = true; continue }
			if ch == '"' do in_str = false
			continue
		}
		if ch == '"' { in_str = true; continue }
		if ch == '{' { if depth == 0 do start = i; depth += 1; continue }
		if ch == '}' { depth -= 1; if depth == 0 && start >= 0 { append(&out, array[start:i + 1]); start = -1 } }
	}
	return out[:]
}
