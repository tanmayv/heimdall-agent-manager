package main

// P-CS CC-C: agent-mode verbs for the coordinator controls on Bridge-owned
// chains (src/bridge/owner_agent_controls.odin). Each verb maps to exactly one
// agent.* method; the Bridge serves it from its owner store, or answers a typed
// `owner_chain_only` bad_request for a Hub chain. The verbs the Hub also serves
// (hold, release, unblock, recheck) then fall back to the existing Hub route;
// every other verb prints the typed error. Refusals are printed verbatim.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import httpc "odin_test:lib/httpc"

// Ctl_Coord_Plan is one coordinator control call: the agent method, its params,
// the Hub fallback action (empty when the verb exists only on owner chains) and
// a usage error when the flags are incomplete.
Ctl_Coord_Plan :: struct {
	method:       string,
	params:       string,
	hub_fallback: string,
	error:        string,
}

// The verbs `task <verb>` routes here.
ctl_coord_task_verb :: proc(verb: string) -> bool {
	switch verb {
	case "cancel", "reopen", "delete", "escalate", "merge-retry", "review-roles",
	     "submit-for-review", "submit-review", "done", "complete", "split":
		return true
	}
	return false
}

// Verbs whose owner method requires a reason (R2-6), checked here so the
// caller sees the flag name before anything is sent.
@(private = "file")
ctl_coord_reason_required :: proc(verb: string) -> bool {
	switch verb {
	case "hold", "cancel", "reopen", "delete", "escalate", "merge-retry", "revoke",
	     "submit-for-review", "submit-review", "done", "complete", "split":
		return true
	}
	return false
}

// ctl_coord_plan builds the call for `task <verb> <task-id>`, `lease revoke
// <task-id>`, `merge retry <task-id>` and `review roles <task-id>`. children_json
// is the --child-file document and map_json the --map document (split only);
// both are pre-validated JSON text. Pure: no I/O.
ctl_coord_plan :: proc(verb, tid: string, args: []string, children_json := "", map_json := "") -> Ctl_Coord_Plan {
	// Every string of the plan lives in the temp allocator (one CLI call).
	context.allocator = context.temp_allocator
	usage := ctl_coord_usage(verb)
	if strings.trim_space(tid) == "" do return {error = usage}
	fields := make([dynamic]string, context.temp_allocator)
	append(&fields, json_kv("task_id", tid))
	if v := strings.trim_space(option_value(args, "--chain", option_value(args, "--chain-id", ""))); v != "" do append(&fields, json_kv("chain_id", v))
	reason := strings.trim_space(option_value(args, "--reason", ""))
	if verb == "unblock" && reason == "" do reason = strings.trim_space(option_value(args, "--note", ""))
	if reason == "" && ctl_coord_reason_required(verb) do return {error = fmt.tprintf("%s requires --reason <text> (recorded in the audit trail)", ctl_coord_verb_name(verb))}
	if reason != "" do append(&fields, json_kv("reason", reason))
	plan: Ctl_Coord_Plan
	switch verb {
	case "hold":
		plan = {method = "agent.task.hold", hub_fallback = "hold"}
	case "release":
		plan = {method = "agent.task.release", hub_fallback = "release"}
	case "unblock":
		plan = {method = "agent.task.unblock", hub_fallback = "answer"}
	case "recheck":
		plan = {method = "agent.task.recheck", hub_fallback = "recheck"}
	case "reopen":
		plan = {method = "agent.task.reopen"}
	case "delete":
		plan = {method = "agent.task.delete"}
	case "escalate":
		plan = {method = "agent.task.escalate"}
	case "merge-retry":
		plan = {method = "agent.task.merge_retry"}
	case "cancel":
		plan = {method = "agent.task.cancel"}
		dependents := strings.trim_space(option_value(args, "--dependents", ""))
		to := strings.trim_space(option_value(args, "--to", option_value(args, "--repoint", "")))
		switch {
		case dependents == "" && to != "":
			dependents = fmt.tprintf("repoint:%s", to)
		case dependents == "repoint":
			if to == "" do return {error = "task cancel --dependents repoint needs --to <task-id> (the task that dependents should wait on instead)"}
			dependents = fmt.tprintf("repoint:%s", to)
		case strings.has_prefix(dependents, "repoint:"):
			if to != "" && dependents != fmt.tprintf("repoint:%s", to) do return {error = "use either --dependents repoint:<task-id> or --dependents repoint --to <task-id>, not both"}
		case dependents == "drop", dependents == "keep", dependents == "":
			if to != "" do return {error = "--to is only valid with --dependents repoint"}
		case:
			return {error = "--dependents must be drop, keep or repoint (with --to <task-id>)"}
		}
		if dependents != "" do append(&fields, json_kv("dependents", dependents))
	case "revoke":
		plan = {method = "agent.lease.revoke"}
		mode := strings.trim_space(option_value(args, "--mode", ""))
		if has_flag(args, "--stop") {
			if mode != "" && mode != "stop" do return {error = "use either --stop or --mode checkpoint, not both"}
			mode = "stop"
		}
		if mode != "" && mode != "checkpoint" && mode != "stop" do return {error = "--mode must be checkpoint or stop"}
		if mode != "" do append(&fields, json_kv("mode", mode))
		if has_flag(args, "--disable-fleet") do append(&fields, json_kv_raw("disable_fleet", "true"))
	case "review-roles":
		plan = {method = "agent.task.review_roles"}
		pairs, perr := ctl_coord_role_pairs(args)
		if perr != "" do return {error = perr}
		append(&fields, json_kv_raw("pairs", pairs))
		if has_flag(args, "--require-user-approval") && has_flag(args, "--no-require-user-approval") do return {error = "use either --require-user-approval or --no-require-user-approval"}
		if has_flag(args, "--require-user-approval") do append(&fields, json_kv_raw("requires_user_approval", "true"))
		if has_flag(args, "--no-require-user-approval") do append(&fields, json_kv_raw("requires_user_approval", "false"))
	case "submit-for-review", "submit-review":
		plan = {method = "agent.task.submit_review"}
		if has_flag(args, "--head") do return {error = "task submit-for-review takes no --head: the Bridge observes the task worktree head itself"}
		summary := strings.trim_space(option_value(args, "--summary", ""))
		if summary == "" do return {error = "task submit-for-review requires --summary <text> (what the worker delivered) and --reason <text>"}
		append(&fields, json_kv("summary", summary))
		if has_flag(args, "--override-ack") do append(&fields, json_kv_raw("override_ack", "true"))
		if v := strings.trim_space(option_value(args, "--expected-requirements-revision", "")); v != "" do append(&fields, json_kv("expected_requirements_revision", v))
	case "done", "complete":
		plan = {method = "agent.task.complete"}
		if !has_flag(args, "--force") do return {error = "task done requires --force --reason <text>: it skips only the independent agent review, never a user approval; use `task recheck` to settle verdicts already posted"}
		append(&fields, json_kv_raw("force", "true"))
	case "split":
		plan = {method = "agent.task.split"}
		if children_json == "" do return {error = "task split requires --child-file <json> (an array of {title, body?, brief?, assignee?} or {children:[...]})"}
		children, dependents, mapping, serr := ctl_coord_split_children(children_json)
		if serr != "" do return {error = serr}
		if v := strings.trim_space(option_value(args, "--dependents", "")); v != "" do dependents = v
		if dependents == "" do dependents = "all"
		if dependents != "all" && dependents != "last" && dependents != "map" do return {error = "--dependents must be all, last or map"}
		if map_json != "" do mapping = map_json
		if dependents == "map" && mapping == "" do return {error = "--dependents map needs --map <json|file> ({dependent_task_id: [child task ids]})"}
		if dependents != "map" && map_json != "" do return {error = "--map is only valid with --dependents map"}
		append(&fields, json_kv_raw("children", children), json_kv("dependents", dependents))
		if dependents == "map" do append(&fields, json_kv_raw("map", mapping))
	case:
		return {error = usage}
	}
	plan.params = json_object_from_slice(fields[:])
	return plan
}

// ctl_coord_role_pairs: --role <role>=<agent_id>[@<instance_id>] (repeatable or
// comma-separated) or --roles-file <json array of {role, agent_id[, instance_id]}>.
@(private = "file")
ctl_coord_role_pairs :: proc(args: []string) -> (string, string) {
	if path := option_value(args, "--roles-file", ""); path != "" {
		text, ok := ctl_coord_read_json_arg(path)
		if !ok do return "", fmt.tprintf("--roles-file %s: cannot read or not valid JSON", path)
		v, _ := ctl_parse_json_document(text)
		if _, is_list := v.(json.Array); !is_list do return "", "--roles-file must be a JSON array of {role, agent_id}"
		return text, ""
	}
	items := make([dynamic]string, context.temp_allocator)
	for raw in option_values_trimmed(args, "--role") {
		for part in strings.split(raw, ",", context.temp_allocator) {
			entry := strings.trim_space(part)
			if entry == "" do continue
			eq := strings.index_byte(entry, '=')
			if eq <= 0 || eq == len(entry) - 1 do return "", fmt.tprintf("--role %q must be <role>=<agent_id>", entry)
			role, agent := entry[:eq], entry[eq + 1:]
			instance := ""
			if at := strings.index_byte(agent, '@'); at > 0 { instance = agent[at + 1:]; agent = agent[:at] }
			pair := make([dynamic]string, context.temp_allocator)
			append(&pair, json_kv("role", role), json_kv("agent_id", agent))
			if instance != "" do append(&pair, json_kv("instance_id", instance))
			append(&items, json_object_from_slice(pair[:]))
		}
	}
	if len(items) == 0 do return "", "task review-roles needs --role <role>=<agent_id> (repeatable) or --roles-file <json>"
	return strings.concatenate({"[", strings.join(items[:], ",", context.temp_allocator), "]"}, context.temp_allocator), ""
}

// ctl_coord_split_children accepts an array of children or an object
// {children, dependents?, map?} and returns the children array plus the file's
// dependents/map (flags override them).
ctl_coord_split_children :: proc(text: string) -> (children, dependents, mapping, err: string) {
	v, ok := ctl_parse_json_document(text)
	if !ok do return "", "", "", "--child-file is not valid JSON"
	#partial switch doc in v {
	case json.Array:
		if len(doc) < 1 || len(doc) > 32 do return "", "", "", "task split needs 1-32 children"
		return strings.trim_space(text), "", "", ""
	case json.Object:
		list, is_list := doc["children"].(json.Array)
		if !is_list || len(list) < 1 || len(list) > 32 do return "", "", "", "--child-file needs children: an array of 1-32 {title, ...}"
		children = ctl_json_text(list, context.temp_allocator)
		if d, is_str := doc["dependents"].(json.String); is_str do dependents = string(d)
		if m, has := doc["map"]; has && m != nil {
			if _, is_obj := m.(json.Object); !is_obj do return "", "", "", "--child-file map must be an object {dependent_task_id: [child task ids]}"
			mapping = ctl_json_text(m, context.temp_allocator)
		}
		return children, dependents, mapping, ""
	}
	return "", "", "", "--child-file must be a JSON array of children or an object {children:[...]}"
}

// ctl_coord_read_json_arg: inline JSON (starts with { or [) or a file path.
@(private = "file")
ctl_coord_read_json_arg :: proc(value: string) -> (string, bool) {
	trimmed := strings.trim_space(value)
	text := trimmed
	if !strings.has_prefix(trimmed, "{") && !strings.has_prefix(trimmed, "[") {
		data, err := os.read_entire_file(trimmed, context.temp_allocator)
		if err != nil do return "", false
		text = strings.trim_space(string(data))
	}
	if _, ok := ctl_parse_json_document(text); !ok do return "", false
	return text, true
}

ctl_coord_verb_name :: proc(verb: string) -> string {
	switch verb {
	case "revoke": return "lease revoke"
	case "merge-retry": return "merge retry"
	case "review-roles": return "review roles"
	}
	return fmt.tprintf("task %s", verb)
}

ctl_coord_usage :: proc(verb: string) -> string {
	switch verb {
	case "hold": return "usage: task hold <task-id> --reason <text>"
	case "release": return "usage: task release <task-id> [--reason <text>] (required on Bridge-owned chains)"
	case "unblock": return "usage: task unblock <task-id> [--note|--reason <text>] (required on Bridge-owned chains)"
	case "recheck": return "usage: task recheck <task-id> [--reason <text>]"
	case "cancel": return "usage: task cancel <task-id> --reason <text> [--dependents drop|keep|repoint --to <task-id>]"
	case "reopen": return "usage: task reopen <task-id> --reason <text>"
	case "delete": return "usage: task delete <task-id> --reason <text>"
	case "escalate": return "usage: task escalate <task-id> --reason <text>"
	case "merge-retry": return "usage: merge retry <task-id> --reason <text>"
	case "review-roles": return "usage: review roles <task-id> --role <role>=<agent_id> [--role ...] | --roles-file <json> [--require-user-approval]"
	case "revoke": return "usage: lease revoke <task-id> --reason <text> [--disable-fleet] [--stop | --mode checkpoint|stop]"
	case "submit-for-review", "submit-review": return "usage: task submit-for-review <task-id> --summary <text> --reason <text> [--override-ack]"
	case "done", "complete": return "usage: task done <task-id> --force --reason <text>"
	case "split": return "usage: task split <task-id> --child-file <json> --reason <text> [--dependents all|last|map --map <json|file>]"
	}
	return "usage: ham-ctl task --help"
}

// ctl_coord_owner_only reports whether the Bridge answered the typed
// owner_chain_only error (the target chain is not owned by this Bridge).
ctl_coord_owner_only :: proc(response: string) -> bool {
	return strings.contains(response, "owner_chain_only")
}

// ctl_coord_control runs one coordinator control end to end and exits 1 on
// any refusal (printed verbatim).
ctl_coord_control :: proc(endpoint, token, verb, tid: string, args: []string) {
	children, map_json := "", ""
	if verb == "split" {
		if path := option_value(args, "--child-file", ""); path != "" {
			text, ok := ctl_coord_read_json_arg(path)
			if !ok do ctl_print_error_exit(fmt.tprintf("--child-file %s: cannot read or not valid JSON", path))
			children = text
		}
		if v := option_value(args, "--map", ""); v != "" {
			text, ok := ctl_coord_read_json_arg(v)
			if !ok do ctl_print_error_exit(fmt.tprintf("--map %s: not valid JSON (inline object or file path)", v))
			map_json = text
		}
	}
	plan := ctl_coord_plan(verb, tid, args, children, map_json)
	if plan.error != "" do ctl_print_error_exit(plan.error)
	response, ok := ctl_agent_local_call(endpoint, token, plan.method, plan.params)
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	if ctl_coord_owner_only(response) {
		if plan.hub_fallback != "" {
			// A Hub chain: the Hub serves this verb on its own route.
			ctl_coord_hub_fallback(endpoint, token, tid, args, plan.hub_fallback)
			return
		}
		fmt.println(response)
		fmt.eprintfln("ham-ctl: `%s` is a coordinator control of Bridge-owned chains only (owner_chain_only); this task's chain is a Hub chain.", ctl_coord_verb_name(verb))
		os.exit(1)
	}
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	out := ctl_decrypt_json_string(response, keyring, key_ok)
	fmt.println(out)
	if strings.contains(response, `"ok":false`) do os.exit(1)
}

@(private = "file")
ctl_coord_hub_fallback :: proc(endpoint, token, tid: string, args: []string, action: string) {
	switch action {
	case "hold":
		ctl_v2_task_hold(endpoint, token, tid, args)
	case "release":
		ctl_v2_task_hold(endpoint, token, tid, args, release = true)
	case "answer":
		note := option_value(args, "--note", option_value(args, "--reason", ""))
		ctl_v2_task_action(endpoint, token, tid, args, "answer", httpc.json_body(Ctl_Task_Note_Body{note = note}))
	case "recheck":
		ctl_v2_task_action(endpoint, token, tid, args, "recheck", ctl_empty_object_body())
	}
}
