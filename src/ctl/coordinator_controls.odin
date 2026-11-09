package main

// Coordinator controls (P-CS CC-C, T1) for Bridge-owned (owner) chains. Every
// verb goes to the Bridge as one agent.* method; on a chain this Bridge owns
// the owner store serves it (src/bridge/owner_agent_controls.odin). On a legacy
// Hub chain the Bridge answers the typed `owner_chain_only` bad_request and
// ham-ctl prints a typed owner_chain_only error: these controls are not
// implemented for Hub chains. The one exception is hold/release/unblock/
// recheck, which ham-ctl already sent to their existing Hub routes before the
// owner controls existed; they keep doing so (ctl_coord_hub_action).
//
// Verb                         Owner method
// task hold|release|unblock|recheck  agent.task.hold|release|unblock|recheck
// task cancel|reopen|delete|escalate agent.task.cancel|reopen|delete|escalate
// task submit-for-review       agent.task.submit_review
// task done --force            agent.task.complete
// task split                   agent.task.split
// lease revoke                 agent.lease.revoke
// merge retry                  agent.task.merge_retry
// review roles                 agent.task.review_roles
//
// A Hub route for a verb is one entry in ctl_coord_hub_action plus its body in
// ctl_coord_hub_body; nothing else changes. Refusals are printed verbatim; a
// refused reopen also names its cause (the owner Bridge supplies it).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import httpc "odin_test:lib/httpc"

CTL_OWNER_CHAIN_ONLY :: "owner_chain_only"

// Ctl_Coord_Plan is one coordinator control call: the owner agent method and
// its params, the legacy Hub fallback (action "" = owner chains only) and a
// usage error when the flags are incomplete.
Ctl_Coord_Plan :: struct {
	method:     string,
	params:     string,
	hub_action: string,
	reason:     string,
	error:      string,
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

// ctl_coord_hub_action: the pre-existing Hub task action route of a verb, ""
// when the verb is served only on Bridge-owned chains (every new control).
ctl_coord_hub_action :: proc(verb: string) -> string {
	switch verb {
	case "hold":    return "hold"
	case "release": return "release"
	case "unblock": return "answer"
	case "recheck": return "recheck"
	}
	return ""
}

// Verbs whose owner control requires a reason (R2-6), checked here so the
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
		plan = {method = "agent.task.hold"}
	case "release":
		plan = {method = "agent.task.release"}
	case "unblock":
		plan = {method = "agent.task.unblock"}
	case "recheck":
		plan = {method = "agent.task.recheck"}
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
	plan.hub_action = ctl_coord_hub_action(verb)
	plan.reason = reason
	return plan
}

// ctl_coord_hub_body: the body of a verb's legacy Hub route.
ctl_coord_hub_body :: proc(verb, reason: string) -> httpc.Body {
	switch verb {
	case "hold":    return httpc.json_body(Ctl_Task_Reason_Body{reason = reason})
	case "unblock": return httpc.json_body(Ctl_Task_Note_Body{note = reason})
	}
	return ctl_empty_object_body()
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
	case "complete": return "task done"
	case "submit-review": return "task submit-for-review"
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
// owner_chain_only error (the target chain is not owned by this Bridge): a
// failed envelope whose error code is, or whose message starts with,
// owner_chain_only. A successful reply that merely mentions the word (e.g. in
// a task title) never counts, so it is neither re-executed nor misreported.
ctl_coord_owner_only :: proc(response: string) -> bool {
	v, ok := ctl_parse_json_document(response)
	if !ok do return false
	o, is_obj := v.(json.Object)
	if !is_obj do return false
	if success, has := o["ok"].(json.Boolean); !has || bool(success) do return false
	e, has_err := o["error"].(json.Object)
	if !has_err do return false
	code, _ := e["code"].(json.String)
	message, _ := e["message"].(json.String)
	return string(code) == CTL_OWNER_CHAIN_ONLY || strings.has_prefix(strings.trim_space(string(message)), CTL_OWNER_CHAIN_ONLY)
}

// ctl_coord_owner_only_json: the typed error printed for an owner-chain verb
// on a legacy Hub chain.
ctl_coord_owner_only_json :: proc(verb: string) -> string {
	text := fmt.tprintf("`%s` is a coordinator control of Bridge-owned chains only; this task's chain is a legacy Hub chain, where it is not supported", ctl_coord_verb_name(verb))
	err := json_object(json_kv("code", CTL_OWNER_CHAIN_ONLY), json_kv("message", text))
	return json_object(json_kv_raw("ok", "false"), json_kv_raw("error", err))
}

// Ctl_Coord_Route is what ctl_coord_control does with the Bridge's answer.
Ctl_Coord_Route :: enum {
	Print,        // the owner store served (or refused) the control: print verbatim
	Hub,          // a Hub chain and the verb has a Hub route
	Owner_Only,   // a Hub chain and the verb is owner-only: typed error
}

// ctl_coord_route decides from the Bridge's first answer. Only the typed
// owner_chain_only reply is turned into the typed error (or a pre-existing
// Hub route); a refusal (worker or reviewer token, foreign chain) is printed
// as-is and never retried on the Hub.
ctl_coord_route :: proc(plan: Ctl_Coord_Plan, response: string) -> Ctl_Coord_Route {
	if !ctl_coord_owner_only(response) do return .Print
	if plan.hub_action == "" do return .Owner_Only
	return .Hub
}

// ctl_coord_refusal_cause names why an owner control was refused, for causes
// an agent can act on. "" when nothing is recognised.
ctl_coord_refusal_cause :: proc(response: string) -> string {
	if !strings.contains(response, `"ok":false`) do return ""
	message := ""
	if v, ok := ctl_parse_json_document(response); ok {
		if o, is_obj := v.(json.Object); is_obj {
			if e, has := o["error"].(json.Object); has {
				if m, is_str := e["message"].(json.String); is_str do message = string(m)
			}
		}
	}
	// The owner Bridge names a reopen's cause itself (owner_local
	// reopen_refusal_cause): chain not active, consumed by a started dependent, ...
	if i := strings.index(message, "cannot be reopened: "); i >= 0 do return strings.trim_space(message[i + len("cannot be reopened: "):])
	if strings.contains(message, "only the verified chain coordinator") || strings.contains(message, "only the chain coordinator") {
		return "the caller is not this chain's coordinator (worker and reviewer tokens cannot use coordinator controls)"
	}
	return ""
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
	switch ctl_coord_route(plan, response) {
	case .Hub:
		// A Hub chain: the Hub serves this verb on its own task action route.
		hub, hub_ok := ctl_v2_task_action_call(endpoint, token, tid, args, plan.hub_action, ctl_coord_hub_body(verb, plan.reason))
		if !hub_ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
		ctl_coord_print_and_exit(verb, hub, args)
	case .Owner_Only:
		fmt.println(ctl_coord_owner_only_json(verb))
		os.exit(1)
	case .Print:
		ctl_coord_print_and_exit(verb, response, args)
	}
}

// ctl_coord_print_and_exit prints a control's answer (decrypted for owner
// replies); a refused control also prints its cause on stderr.
@(private = "file")
ctl_coord_print_and_exit :: proc(verb, response: string, args: []string) {
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	out := ctl_decrypt_json_string(response, keyring, key_ok)
	fmt.println(out)
	if !strings.contains(response, `"ok":false`) do return
	if cause := ctl_coord_refusal_cause(response); cause != "" {
		fmt.eprintfln("ham-ctl: %s refused: %s", ctl_coord_verb_name(verb), cause)
	}
	os.exit(1)
}

// ---- --assignee self (T1 REQ 4) ---------------------------------------------

// Ctl_Self_Assignee: the resolved durable agent id, or a refusal code and
// message (code "" = allowed).
Ctl_Self_Assignee :: struct {
	agent_id: string,
	code:     string,
	message:  string,
}

CTL_SELF_SOLO_HINT :: "use solo mode (the coordinator holds a worker fleet row in this chain) or `task done --force`"

// ctl_assignee_self_resolve decides `--assignee self` from the target chain's
// agent.task_chain.show reply. The owner Bridge adds `caller` {agent_id,
// instance_id, coordinator, worker_fleet_row}. Allowed only for the chain
// coordinator in solo mode (it holds an enabled worker fleet row); a legacy
// Hub chain answers owner_chain_only. Pure: no I/O.
ctl_assignee_self_resolve :: proc(chain_json: string) -> Ctl_Self_Assignee {
	chain := ctl_json_data_object(chain_json)
	auth, has := chain["authority"].(json.Object)
	if !has || ctl_json_str(auth, "kind") != "owner" {
		return {code = CTL_OWNER_CHAIN_ONLY, message = "--assignee self is supported only on Bridge-owned chains; this chain is a legacy Hub chain: pass --assignee agt_..."}
	}
	caller, has_caller := chain["caller"].(json.Object)
	agent := ctl_json_str(caller, "agent_id")
	if !has_caller || !strings.has_prefix(agent, "agt_") do return {code = "self_unresolved", message = "--assignee self: the Bridge did not report your durable agent id (agt_...); pass --assignee agt_..."}
	if b, _ := caller["coordinator"].(json.Boolean); !bool(b) {
		return {code = "coordinator_only", message = "--assignee self is only for the chain coordinator in solo mode; you are not the coordinator of this chain (worker and reviewer agents cannot assign tasks)"}
	}
	if b, _ := caller["worker_fleet_row"].(json.Boolean); !bool(b) {
		return {code = "solo_required", message = fmt.tprintf("--assignee self is allowed only in solo mode; %s", CTL_SELF_SOLO_HINT)}
	}
	return {agent_id = agent}
}

// ctl_assignee_is_self: `--assignee self` (also `me`).
ctl_assignee_is_self :: proc(args: []string) -> bool {
	a := strings.trim_space(option_value(args, "--assignee", ""))
	return a == "self" || a == "me"
}

// ctl_assignee_self_args resolves `--assignee self` against the live chain and
// returns args with the durable agent id substituted; prints the typed refusal
// and exits 1 when it is not allowed. The chain is --chain, the task's chain
// (update, via tid), else the caller's own chain (the Bridge's default).
ctl_assignee_self_args :: proc(endpoint, token: string, args: []string, tid := "") -> []string {
	if !ctl_assignee_is_self(args) do return args
	chain_id := strings.trim_space(option_value(args, "--chain", option_value(args, "--chain-id", "")))
	if chain_id == "" && tid != "" {
		if res, ok := ctl_agent_local_call(endpoint, token, "agent.task.show", json_object(json_kv("task_id", tid))); ok {
			chain_id = extract_json_string_unescaped(res, "chain_id", "", context.temp_allocator)
		}
	}
	params := "{}"
	if chain_id != "" do params = json_object(json_kv("chain_id", chain_id))
	chain_json, ok := ctl_agent_local_call(endpoint, token, "agent.task_chain.show", params)
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	r := ctl_assignee_self_resolve(chain_json)
	if r.code != "" {
		fmt.println(json_object(json_kv_raw("ok", "false"), json_kv_raw("error", json_object(json_kv("code", r.code), json_kv("message", r.message)))))
		os.exit(1)
	}
	return ctl_args_replace_value(args, "--assignee", r.agent_id)
}

// ctl_args_replace_value: a copy of args with the value of every `flag <v>` /
// `flag=<v>` occurrence replaced.
ctl_args_replace_value :: proc(args: []string, flag, value: string) -> []string {
	out := make([dynamic]string, 0, len(args), context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if a == flag && i + 1 < len(args) {
			append(&out, a, value)
			i += 1
			continue
		}
		if strings.has_prefix(a, strings.concatenate({flag, "="}, context.temp_allocator)) {
			append(&out, strings.concatenate({flag, "=", value}, context.temp_allocator))
			continue
		}
		append(&out, a)
	}
	return out[:]
}

// ctl_json_data_object: the innermost "data" object of a (relayed) envelope,
// or the document itself when it has none.
ctl_json_data_object :: proc(text: string) -> json.Object {
	v, ok := ctl_parse_json_document(text)
	if !ok do return nil
	for _ in 0 ..< 4 {
		o, is_obj := v.(json.Object)
		if !is_obj do return nil
		inner, has := o["data"]
		if !has do return o
		if _, inner_obj := inner.(json.Object); !inner_obj do return o
		v = inner
	}
	o, _ := v.(json.Object)
	return o
}

ctl_json_str :: proc(o: json.Object, key: string) -> string {
	if o == nil do return ""
	s, _ := o[key].(json.String)
	return strings.trim_space(string(s))
}
