package main

// ── Task System v2 (M2): brief flags, lease verbs, review, fetch ──────────────
//
// Everything here talks to the local Bridge endpoint over the same JSONL client
// the rest of agent mode uses (ctl_agent_local_call). The hub contract is the
// M2 wire contract:
//
//   agent.lease.submit   {lease_id?, summary, handoff?, output?, artifacts?}       (bridge adds vcs)
//   agent.lease.handoff  {lease_id?, summary, handoff?}                            (bridge adds vcs)
//   agent.lease.block    {lease_id?, waiting_on:{kind, ref?, reason}, summary?}
//   agent.review.post    {task_id?, verdict: approve|request_changes, findings?}
//   agent.task.fetch     {task_id, ref}   ref = "#<event_id>" | "facet:<task>:<attempt>:<kind>"
//
// Configured verification commands were removed (REQ-TV2-1): workers choose and
// report their own checks, and an independent reviewer judges them. For one
// release `ham-ctl verify` is an inert stub, and the old brief flags
// (--verify/--auto-submit/--require-independent-verify) and submit flags
// (--verify/--skip-verify/--skip-verify-reason/--auto) are accepted, dropped and
// reported on stderr; nothing is sent or executed.
//
// The lease verbs also send `cwd` (ham-ctl's own working directory, which is the
// agent's) so the bridge can find the repository for its vcs enrichment; the hub
// ignores the key.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import httpc "odin_test:lib/httpc"
import contracts "odin_test:contracts"
import "core:time"
import jsonx "odin_test:lib/jsonx"

ctl_requirements_revision_flag :: proc(args: []string, flag: string) -> int {
    if !has_flag(args,flag) do return 0
    value,ok:=strconv.parse_int(option_value(args,flag,""))
    if !ok || value<1 do ctl_print_error_exit(strings.concatenate({flag," requires a positive revision"},context.temp_allocator))
    return value
}

ctl_requirement_brief_sealed :: proc(value: json.Value, args: []string) -> json.Value {
    object,ok:=value.(json.Object)
    if !ok do return value
    kr:=ctl_vault_keyring_for_write(args)
    if goal,typed:=object["goal"].(json.String);typed && !is_vault_armored(string(goal)) {
        if len(string(goal))>2000 || strings.trim_space(string(goal))=="" do ctl_print_error_exit("goal must contain 1..2000 bytes")
        object["goal"]=json.String(ctl_seal_or_exit(string(goal),kr))
    }
    if acceptance,typed:=object["acceptance"].(json.Array);typed {
        if len(acceptance)<1 || len(acceptance)>20 do ctl_print_error_exit("acceptance requires 1..20 items")
        for item,i in acceptance {
            if text,typed:=item.(json.String);typed && !is_vault_armored(string(text)) {
                if len(string(text))>200 || strings.trim_space(string(text))=="" do ctl_print_error_exit("acceptance items must contain 1..200 bytes")
                acceptance[i]=json.String(ctl_seal_or_exit(string(text),kr))
            }
        }
    }
    return object
}

ctl_v2_heartbeat_params :: proc(args: []string) -> string {
    fields:=make([dynamic]string,context.temp_allocator)
    if value:=option_value(args,"--lease","");value!="" do append(&fields,json_kv("lease_id",value))
    if value:=option_value(args,"--note","");value!="" do append(&fields,json_kv("note",value))
    if revision:=ctl_requirements_revision_flag(args,"--acknowledge-requirements-revision");revision>0 {
        if option_value(args,"--lease","")=="" do ctl_print_error_exit("acknowledgement requires --lease from the context you read")
        append(&fields,json_kv_raw("acknowledge_requirements_revision",fmt.tprintf("%d",revision)))
    }
    return json_object_from_slice(fields[:])
}

// ---- brief ------------------------------------------------------------------

// ctl_collect_repeated gathers every value of the named flags WITHOUT splitting
// on commas (acceptance criteria are prose and legitimately contain commas).
// Blank values are skipped. Caller owns the result.
ctl_collect_repeated :: proc(args: []string, names: ..string) -> [dynamic]string {
	out := make([dynamic]string)
	for i := 0; i + 1 < len(args); i += 1 {
		matched := false
		for name in names { if args[i] == name { matched = true; break } }
		if !matched do continue
		v := strings.trim_space(args[i + 1])
		if v != "" do append(&out, v)
	}
	return out
}

// CTL_BRIEF_KEYS is the one brief schema create, update and propose share
// (REQ-TV2-4), in the order ham-ctl writes them. The hub owns validation: keys
// outside it are forwarded and the hub rejects them with unknown_brief_fields
// instead of ham-ctl dropping them silently.
CTL_BRIEF_KEYS :: [?]string{"goal", "acceptance", "inputs", "assignee", "reviewers", "budget", "output", "on_output", "requires_user_approval", "approver", "gate"}

// ctl_brief_clear_flag: `--clear-<field>` sends `"<field>":null`, which the
// hub's top-level merge reads as "remove this key".
ctl_brief_clear_flag :: proc(key: string) -> string {
	flag, _ := strings.replace_all(key, "_", "-", context.temp_allocator)
	return strings.concatenate({"--clear-", flag}, context.temp_allocator)
}

// ctl_task_brief_flags_present reports whether any brief flag was given, so
// `task update` without them does not send an (empty) brief.
ctl_task_brief_flags_present :: proc(args: []string) -> bool {
	for f in ([?]string{"--goal", "--acceptance", "--input", "--inputs", "--on-output-workflow", "--output-schema", "--brief-file"}) {
		if has_flag(args, f) do return true
	}
	for k in CTL_BRIEF_KEYS do if has_flag(args, ctl_brief_clear_flag(k)) do return true
	return false
}

// ctl_task_brief_json builds the `brief` object from an optional --brief-file
// body (the base) and the brief flags (which override the file's fields).
// Pure: the file's text is passed in. Returns ("", false) when there is nothing
// to send; an explicitly empty `{}` file returns ("{}", true). Every key of the file is carried (explicit nulls included, so they
// clear the key on update); flags win field by field and `--clear-<field>`
// sends null. The removed verify keys are never carried.
ctl_task_brief_json :: proc(args: []string, brief_file_text: string) -> (string, bool) {
	entries, ok := ctl_task_brief_entries(args, brief_file_text)
	if !ok do return "", false
	if len(entries) == 0 do return strings.clone("{}"), true
	fields := make([dynamic]string)
	defer delete(fields)
	for e in entries {
		raw, merr := json.marshal(e.value, allocator = context.temp_allocator)
		if merr != nil do continue
		append(&fields, json_kv_raw(e.key, string(raw)))
	}
	return json_object_from_slice(fields[:]), true
}

// Ctl_Brief_Entry is one top-level brief key in the order ham-ctl writes it.
Ctl_Brief_Entry :: struct {
	key:   string,
	value: json.Value,
}

// ctl_task_brief_entries is the brief as ordered (key, value) pairs: the
// CTL_BRIEF_KEYS in schema order, then any other key sorted. ok=false when
// there is nothing to send; an explicitly empty `{}` file is ok with no entries.
// Values are temp-allocated.
ctl_task_brief_entries :: proc(args: []string, brief_file_text: string) -> ([]Ctl_Brief_Entry, bool) {
	file := strings.trim_space(brief_file_text)
	values := make(map[string]json.Value, allocator = context.temp_allocator)
	// An explicitly empty `{}` file is a brief of its own (with --replace-brief it
	// clears every field); a file of only removed verify keys stays no brief.
	explicit_empty := false
	if file != "" {
		parsed, perr := json.parse_string(file, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		if obj, is_obj := parsed.(json.Object); perr == nil && is_obj {
			explicit_empty = len(obj) == 0
			for key, value in obj {
				removed := false
				for k in CTL_REMOVED_BRIEF_KEYS do if k == key { removed = true; break }
				if removed do continue
				values[key] = value
			}
		}
	}

	if goal := option_value(args, "--goal", ""); goal != "" do values["goal"] = json.String(goal)
	acceptance := ctl_collect_repeated(args, "--acceptance")
	defer delete(acceptance)
	if len(acceptance) > 0 do values["acceptance"] = ctl_json_string_array_value(acceptance[:])
	inputs := ctl_multi_values(args, "--input", "--inputs")
	if len(inputs) > 0 do values["inputs"] = ctl_json_string_array_value(inputs)
	if out_schema := strings.trim_space(option_value(args, "--output-schema", "")); out_schema != "" do values["output"] = json.String(out_schema)
	if on_wf := strings.trim_space(option_value(args, "--on-output-workflow", "")); on_wf != "" {
		on_output := make(json.Object, allocator = context.temp_allocator)
		on_output["start_workflow"] = json.String(on_wf)
		values["on_output"] = on_output
	}
	for k in CTL_BRIEF_KEYS do if has_flag(args, ctl_brief_clear_flag(k)) do values[k] = json.Null{}

	if len(values) == 0 do return nil, explicit_empty
	entries := make([dynamic]Ctl_Brief_Entry, 0, len(values), context.temp_allocator)
	for k in CTL_BRIEF_KEYS {
		if v, ok := values[k]; ok do append(&entries, Ctl_Brief_Entry{key = k, value = v})
	}
	extra := make([dynamic]string, context.temp_allocator)
	for k in values {
		known := false
		for b in CTL_BRIEF_KEYS do if b == k { known = true; break }
		if !known do append(&extra, k)
	}
	slice.sort(extra[:])
	for k in extra do append(&entries, Ctl_Brief_Entry{key = k, value = values[k]})
	return entries[:], true
}

// ctl_json_string_array_value is a json.Array of strings (temp-allocated).
ctl_json_string_array_value :: proc(items: []string) -> json.Value {
	arr := make(json.Array, 0, len(items), context.temp_allocator)
	for item in items do append(&arr, json.String(item))
	return arr
}

// CTL_REMOVED_BRIEF_KEYS / CTL_REMOVED_BRIEF_FLAGS: the verification brief
// fields that were removed. They are accepted for one release and dropped.
CTL_REMOVED_BRIEF_KEYS :: [?]string{"verify", "auto_submit", "require_independent_verify"}
CTL_REMOVED_BRIEF_FLAGS :: [?]string{"--verify", "--auto-submit", "--require-independent-verify"}

// ctl_task_brief_removed_fields names the removed verification fields the
// caller passed, as flags or as --brief-file keys. Pure.
ctl_task_brief_removed_fields :: proc(args: []string, brief_file_text: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	keys := CTL_REMOVED_BRIEF_KEYS
	for f, i in CTL_REMOVED_BRIEF_FLAGS {
		if has_flag(args, f) do append(&out, keys[i])
	}
	if file := strings.trim_space(brief_file_text); file != "" {
		for k in keys {
			if !jsonx.has_key(file, k, top_level_only = true) do continue
			dup := false
			for o in out { if o == k { dup = true; break } }
			if !dup do append(&out, k)
		}
	}
	return out[:]
}

// ctl_warn_removed prints the one-release compatibility warning for dropped
// verification flags on stderr, so stdout stays the command's JSON.
ctl_warn_removed :: proc(what: string, fields: []string) {
	if len(fields) == 0 do return
	fmt.eprintfln("ham-ctl: warning: %s %s ignored: verification commands were removed; choose and report your own checks", what, strings.join(fields, ", ", context.temp_allocator))
}

// ctl_task_brief_field returns the `"brief":{...}` field for create/update from
// the flags and --brief-file, or ("", false) when no brief was given. Exits 1
// when --brief-file cannot be read or is not a JSON object. Removed verification
// fields are dropped with a stderr warning.
ctl_task_brief_field :: proc(args: []string) -> (string, bool) {
	file_text, present := ctl_task_brief_file(args)
	if !present do return "", false
	brief, ok := ctl_task_brief_json(args, file_text)
	if !ok do return "", false
	// --replace-brief: the hub swaps the whole brief instead of merging keys.
	if has_flag(args, "--replace-brief") do return strings.concatenate({json_kv_raw("brief", brief), `,"replace_brief":true`}), true
	return json_kv_raw("brief", brief), true
}

// ctl_task_brief_value is the brief for a hub request body: the same keys and
// values as ctl_task_brief_field, as a json.Object (temp-allocated). replace is
// --replace-brief.
ctl_task_brief_value :: proc(args: []string) -> (brief: json.Value, replace: Maybe(bool), ok: bool) {
	file_text, present := ctl_task_brief_file(args)
	if !present do return nil, nil, false
	entries, eok := ctl_task_brief_entries(args, file_text)
	if !eok do return nil, nil, false
	obj := make(json.Object, len(entries), context.temp_allocator)
	for e in entries do obj[e.key] = e.value
	if has_flag(args, "--replace-brief") do replace = true
	return obj, replace, true
}

// ctl_task_brief_file reads --brief-file (exits 1 when it cannot be read or is
// not a JSON object), warns about removed verification fields, and reports
// whether any brief input was given at all.
ctl_task_brief_file :: proc(args: []string) -> (file_text: string, present: bool) {
	if path := option_value(args, "--brief-file", ""); path != "" {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			ctl_print_error_exit(fmt.tprintf("--brief-file %s: cannot read", path))
		}
		file_text = string(data)
		if t := strings.trim_space(file_text); t == "" || t[0] != '{' {
			ctl_print_error_exit(fmt.tprintf("--brief-file %s: must contain a JSON object", path))
		}
	}
	ctl_warn_removed("brief", ctl_task_brief_removed_fields(args, file_text))
	if file_text == "" && !ctl_task_brief_flags_present(args) do return "", false
	return file_text, true
}

// ---- publish: brief_incomplete rendering -------------------------------------

// ctl_brief_incomplete_render turns a publish refusal into a per-task list of
// missing brief fields. Accepts BOTH envelopes: the agent-mode one, where the
// bridge wraps the hub's error body as a JSON string in `error.message`, and the
// user-mode one, where the hub body is the response itself. Pure. Returns
// ("", false) when the response is not a brief_incomplete 422.
ctl_brief_incomplete_render :: proc(response: string) -> (string, bool) {
	if !strings.contains(response, "brief_incomplete") do return "", false
	parsed, perr := json.parse(transmute([]byte)response, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil do return "", false
	root, is_obj := parsed.(json.Object)
	if !is_obj do return "", false

	hub := root
	if e, has := root["error"].(json.Object); has {
		if msg, is_str := e["message"].(json.String); is_str && strings.contains(string(msg), "brief_incomplete") {
			inner, ierr := json.parse(transmute([]byte)string(msg), json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
			if ierr == nil {
				if io, ok := inner.(json.Object); ok do hub = io
			}
		}
	}
	err_obj, has_err := hub["error"].(json.Object)
	if !has_err do return "", false
	details, has_details := err_obj["details"].(json.Object)
	if !has_details do return "", false
	if code, ok := details["code"].(json.String); !ok || string(code) != "brief_incomplete" do return "", false

	b := strings.builder_make()
	strings.write_string(&b, "publish refused: brief incomplete\n")
	if tasks, ok := details["tasks"].(json.Array); ok {
		for t in tasks {
			to, tok := t.(json.Object)
			if !tok do continue
			tid := ""
			if v, sok := to["task_id"].(json.String); sok do tid = string(v)
			strings.write_string(&b, "  ")
			strings.write_string(&b, tid)
			strings.write_string(&b, ": missing ")
			if missing, mok := to["missing"].(json.Array); mok {
				for m, i in missing {
					if i > 0 do strings.write_string(&b, ", ")
					if ms, msok := m.(json.String); msok do strings.write_string(&b, string(ms))
				}
			}
			strings.write_byte(&b, '\n')
		}
	}
	strings.write_string(&b, "rules: goal (≤2000 chars); 1..20 acceptance items (≤200 chars each); every reviewer must be an enabled chain member.\n")
	return strings.to_string(b), true
}

// ctl_publish_print_and_exit prints the response; a brief_incomplete refusal is
// rendered readably (then the raw envelope) and exits 1.
ctl_publish_print_and_exit :: proc(response: string) {
	if text, found := ctl_brief_incomplete_render(response); found {
		fmt.print(text)
		fmt.println(response)
		os.exit(1)
	}
	fmt.println(response)
	if strings.contains(response, `"ok":false`) do os.exit(1)
}

// ctl_v2_task_publish publishes ONE task (coordinator only). The hub route is
// chain-scoped, so the chain is taken from --chain, else this agent's own chain
// (context), else the task itself (task show).
ctl_v2_task_publish :: proc(endpoint, token, tid: string, args: []string) {
	ctl_v2_task_action(endpoint, token, tid, args, "publish", ctl_empty_object_body())
}

// ctl_v2_task_action POSTs `body` to a chain-scoped task action route.
ctl_v2_task_action :: proc(endpoint, token, tid: string, args: []string, action: string, body: httpc.Body) {
	response, ok := ctl_v2_task_action_call(endpoint, token, tid, args, action, body)
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	ctl_publish_print_and_exit(response)
}

// ctl_v2_task_action_call resolves the task's chain (--chain, the task, else
// this agent's chain) and POSTs `body` to its Hub task action route; returns
// the relayed response. Exits 1 when no chain can be resolved.
ctl_v2_task_action_call :: proc(endpoint, token, tid: string, args: []string, action: string, body: httpc.Body) -> (string, bool) {
	chain_id := option_value(args, "--chain", "")
	if chain_id == "" {
		if res, ok := ctl_agent_local_call(endpoint, token, "agent.task.show", json_object(json_kv("task_id", tid))); ok {
			chain_id = extract_json_string_unescaped(res, "chain_id", "", context.temp_allocator)
		}
	}
	if chain_id == "" {
		if res, ok := ctl_agent_local_call(endpoint, token, "agent.context.get", "{}"); ok {
			chain_id = extract_json_string_unescaped(res, "chain_id", "", context.temp_allocator)
		}
	}
	if chain_id == "" {
		fmt.println(`{"ok":false,"message":"could not resolve the task's chain; pass --chain <id>"}`)
		os.exit(1)
	}
	return ctl_agent_rest_local(endpoint, token, {method = .POST, path = ctl_api("task-chains", chain_id, "tasks", tid, action), body = body})
}

// ---- lease verbs --------------------------------------------------------------

// ctl_read_json_file_flag reads `--<flag> <path>` and returns the file's JSON
// text (validated to parse). Exits 1 on a missing/invalid file. ("", false)
// when the flag is absent.
// ctl_handoff_flags: the handoff object from --handoff-file, or one built from
// the inline flags TASK.md teaches: --next-steps <text>, and repeatable
// --decision <text> / --dead-end <text> (one item per flag). Not both forms.
// Decisions and dead ends reach every task that waits for this one.
ctl_handoff_flags :: proc(args: []string) -> (string, bool) {
	next := strings.trim_space(option_value(args, "--next-steps", ""))
	decisions := option_values_trimmed(args, "--decision")
	dead_ends := option_values_trimmed(args, "--dead-end")
	inline := next != "" || len(decisions) > 0 || len(dead_ends) > 0
	h, has_file := ctl_read_json_file_flag(args, "--handoff-file")
	if has_file && inline { fmt.println(`{"ok":false,"message":"use --next-steps/--decision/--dead-end or --handoff-file (put them in the file), not both"}`); os.exit(1) }
	if has_file do return h, true
	if !inline do return "", false
	fields := make([dynamic]string, context.temp_allocator)
	if next != "" do append(&fields, json_kv("next_steps", next))
	if len(decisions) > 0 do append(&fields, json_string_array_field("decisions", decisions))
	if len(dead_ends) > 0 do append(&fields, json_string_array_field("dead_ends", dead_ends))
	return json_object_from_slice(fields[:]), true
}

// option_values_trimmed: every non-blank value of a repeatable `name <value>` flag.
option_values_trimmed :: proc(args: []string, name: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for i := 0; i + 1 < len(args); i += 1 {
		if args[i] != name do continue
		if v := strings.trim_space(args[i + 1]); v != "" do append(&out, v)
	}
	return out[:]
}

ctl_read_json_file_flag :: proc(args: []string, flag: string) -> (string, bool) {
	path := option_value(args, flag, "")
	if path == "" do return "", false
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		ctl_print_error_exit(fmt.tprintf("%s %s: cannot read", flag, path))
	}
	text := strings.trim_space(string(data))
	parsed, perr := json.parse(transmute([]byte)text, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		ctl_print_error_exit(fmt.tprintf("%s %s: not valid JSON", flag, path))
	}
	_ = parsed
	return text, true
}

// ctl_agent_cwd returns ham-ctl's working directory — the agent's cwd, since
// ham-ctl runs as the agent's child ("" when unavailable).
ctl_agent_cwd :: proc(allocator := context.temp_allocator) -> string {
	cwd, err := os.get_working_directory(allocator)
	if err != nil do return ""
	return cwd
}

// ctl_lease_dir_or: the lease's chain directory when it exists on this machine,
// else `fallback` (ham-ctl's own cwd).
ctl_lease_dir_or :: proc(directory_path, fallback: string) -> string {
	dp := strings.trim_space(directory_path)
	if dp != "" && os.exists(dp) do return dp
	return fallback
}

// ctl_lease_work_dir: where the current lease's work lives, for the lease verbs'
// `cwd` (the bridge reads the repository's VCS state from it). Peeks the lease
// for placement.directory_path; falls back to ham-ctl's own cwd.
ctl_lease_work_dir :: proc(endpoint, token: string) -> string {
	cwd := ctl_agent_cwd()
	resp, ok := ctl_agent_local_call(endpoint, token, "agent.lease.next", json_object(json_kv("cwd", cwd), json_kv_raw("peek", "true")))
	if !ok do return cwd
	lease, parsed := ctl_lease_peek_parse(resp)
	if !parsed do return cwd
	return ctl_lease_dir_or(lease.directory_path, cwd)
}

ctl_agent_cwd_field :: proc() -> string {
	return json_kv("cwd", ctl_agent_cwd())
}

// CTL_REMOVED_SUBMIT_FLAGS: the verification flags `lease submit` no longer
// sends. They are accepted for one release with a stderr warning.
CTL_REMOVED_SUBMIT_FLAGS :: [?]string{"--verify", "--skip-verify", "--skip-verify-reason", "--auto"}

// ctl_lease_submit_removed_flags names the removed submit flags present. Pure.
ctl_lease_submit_removed_flags :: proc(args: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for f in CTL_REMOVED_SUBMIT_FLAGS {
		if has_flag(args, f) do append(&out, f)
	}
	return out[:]
}

ctl_v2_lease_submit_params :: proc(args: []string, handoff_json := "", output_json := "", artifacts_json := "", cwd_override := "") -> (string, bool) {
	summary := strings.trim_space(option_value(args, "--summary", ""))
	if summary == "" do return "", false
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("summary", summary))
    if revision:=ctl_requirements_revision_flag(args,"--requirements-revision");revision>0 do append(&fields,json_kv_raw("requirements_revision",fmt.tprintf("%d",revision)))
	if v := option_value(args, "--lease", ""); v != "" do append(&fields, json_kv("lease_id", v))
	if handoff_json != "" do append(&fields, json_kv_raw("handoff", handoff_json))
	if output_json != "" do append(&fields, json_kv_raw("output", output_json))
	if artifacts_json != "" do append(&fields, json_kv_raw("artifacts", artifacts_json))
	if v := option_value(args, "--vcs-base", ""); v != "" do append(&fields, json_kv("vcs_base", v))
	cwd := cwd_override if cwd_override != "" else ctl_agent_cwd()
	append(&fields, json_kv("cwd", cwd))
	return json_object_from_slice(fields[:]), true
}

ctl_v2_lease_submit :: proc(endpoint, token: string, args: []string) {
	summary := strings.trim_space(option_value(args, "--summary", ""))
	if summary == "" { fmt.println(`{"ok":false,"message":"lease submit requires --summary <text>"}`); os.exit(1) }
	ctl_warn_removed("lease submit", ctl_lease_submit_removed_flags(args))
	h, _ := ctl_handoff_flags(args)
	o, _ := ctl_read_json_file_flag(args, "--output-file")
	a, a_ok := ctl_read_json_file_flag(args, "--artifacts-file")
	if !a_ok {
		if raw_a := strings.trim_space(option_value(args, "--artifacts", "")); raw_a != "" {
			if _, perr := json.parse(transmute([]byte)raw_a, json.DEFAULT_SPECIFICATION, false, context.temp_allocator); perr != nil {
				fmt.println(`{"ok":false,"message":"--artifacts: not valid JSON"}`)
				os.exit(1)
			}
			a = raw_a
		}
	}
	params, ok := ctl_v2_lease_submit_params(args, h, o, a, ctl_lease_work_dir(endpoint, token))
	if !ok { fmt.println(`{"ok":false,"message":"lease submit requires --summary <text>"}`); os.exit(1) }
	ctl_agent_call_task(endpoint, token, "agent.lease.submit", params, args)
}

ctl_v2_lease_handoff :: proc(endpoint, token: string, args: []string) {
	summary := strings.trim_space(option_value(args, "--summary", ""))
	if summary == "" { fmt.println(`{"ok":false,"message":"lease handoff requires --summary <text>"}`); os.exit(1) }
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("summary", summary))
	if v := option_value(args, "--lease", ""); v != "" do append(&fields, json_kv("lease_id", v))
	if h, ok := ctl_handoff_flags(args); ok do append(&fields, json_kv_raw("handoff", h))
	if v := option_value(args, "--vcs-base", ""); v != "" do append(&fields, json_kv("vcs_base", v))
	append(&fields, json_kv("cwd", ctl_lease_work_dir(endpoint, token)))
	ctl_agent_call_task(endpoint, token, "agent.lease.handoff", json_object_from_slice(fields[:]), args)
}

// ctl_v2_lease_switch (solo mode): hand the current task off and take another
// ready task in one step. `ham-ctl lease switch <task_id> --summary <s>`.
ctl_v2_lease_switch :: proc(endpoint, token: string, args: []string, positional_task := "") {
	task_id := strings.trim_space(option_value(args, "--task", ""))
	if task_id == "" do task_id = strings.trim_space(positional_task)
	summary := strings.trim_space(option_value(args, "--summary", ""))
	if task_id == "" || summary == "" { fmt.println(`{"ok":false,"message":"lease switch requires <task_id> and --summary <text> (where you left the current task)"}`); os.exit(1) }
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("task_id", task_id))
	append(&fields, json_kv("summary", summary))
	if v := option_value(args, "--lease", ""); v != "" do append(&fields, json_kv("lease_id", v))
	if h, ok := ctl_handoff_flags(args); ok do append(&fields, json_kv_raw("handoff", h))
	append(&fields, json_kv("cwd", ctl_lease_work_dir(endpoint, token)))
	ctl_agent_call_task(endpoint, token, "agent.lease.switch", json_object_from_slice(fields[:]), args)
}

ctl_v2_lease_block :: proc(endpoint, token: string, args: []string) {
	kind := strings.trim_space(option_value(args, "--waiting-on", ""))
	reason := strings.trim_space(option_value(args, "--reason", ""))
	if kind == "" || reason == "" { fmt.println(`{"ok":false,"message":"lease block requires --waiting-on <kind> and --reason <text> [--ref <id>] [--summary <text>]"}`); os.exit(1) }
	wo := make([dynamic]string)
	defer delete(wo)
	append(&wo, json_kv("kind", kind))
	if v := option_value(args, "--ref", ""); v != "" do append(&wo, json_kv("ref", v))
	append(&wo, json_kv("reason", reason))
	fields := make([dynamic]string)
	defer delete(fields)
	if v := option_value(args, "--lease", ""); v != "" do append(&fields, json_kv("lease_id", v))
	append(&fields, json_kv_raw("waiting_on", json_object_from_slice(wo[:])))
	if v := option_value(args, "--summary", ""); v != "" do append(&fields, json_kv("summary", v))
	ctl_agent_call_task(endpoint, token, "agent.lease.block", json_object_from_slice(fields[:]), args)
}

// ---- review ---------------------------------------------------------------------

ctl_v2_review_post_params :: proc(tokens, args: []string, findings_json := "") -> (string, bool) {
	verdict := strings.trim_space(option_value(args, "--verdict", ""))
	if verdict != "approve" && verdict != "request_changes" do return "", false
	fields := make([dynamic]string)
	defer delete(fields)
	if v := option_value(args, "--task", option_value(args, "--task-id", pos(tokens, 1))); v != "" do append(&fields, json_kv("task_id", v))
	append(&fields, json_kv("verdict", verdict))
    if value:=option_value(args,"--lease","");value!="" do append(&fields,json_kv("lease_id",value))
    if revision:=ctl_requirements_revision_flag(args,"--requirements-revision");revision>0 do append(&fields,json_kv_raw("requirements_revision",fmt.tprintf("%d",revision)))
    if attempt:=ctl_requirements_revision_flag(args,"--expected-attempt");attempt>0 do append(&fields,json_kv_raw("expected_attempt_no",fmt.tprintf("%d",attempt)))
    if has_flag(args,"--expected-head") do append(&fields,json_kv("expected_head",option_value(args,"--expected-head","")))
	if findings_json != "" do append(&fields, json_kv_raw("findings", findings_json))
	// --summary: the reason in words (enough on its own for request_changes;
	// a rejected gate's re-plan reads it).
	if v := strings.trim_space(option_value(args, "--summary", "")); v != "" do append(&fields, json_kv("summary", v))
	if obo := strings.trim_space(option_value(args, "--on-behalf-of", "")); obo != "" {
		append(&fields, json_kv("on_behalf_of", obo))
	}
	return json_object_from_slice(fields[:]), true
}

ctl_v2_review :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "post":
		f, _ := ctl_read_json_file_flag(args, "--findings-file")
		params, ok := ctl_v2_review_post_params(tokens, args, f)
		if !ok {
			fmt.println(`{"ok":false,"message":"review post requires --verdict approve|request_changes [--summary <reason>] [--findings-file <json>] [--task <id>] [--on-behalf-of user]"}`)
			os.exit(1)
		}
		ctl_agent_call_task(endpoint, token, "agent.review.post", params, args)
	case:
		print_help_review()
	}
}

// ---- task-chain summary / propose / fleet --------------------------------------

// Ctl_Chain_Summary_Body: PUT /api/v1/task-chains/<id>/summary and the
// agent.task_chain.set_summary params.
Ctl_Chain_Summary_Body :: struct {
	chain_id: string `json:"chain_id,omitempty"`,
	summary:  string `json:"summary"`,
}

// Ctl_Summary_Mode: what `task-chain summary ...` does. Only an explicit write
// (`set`, or --summary/--body/--file/--stdin) ever writes; `get`/`show` and a
// bare `summary` read. Any other word is refused instead of being stored as
// the summary (it used to overwrite the summary with the literal word).
Ctl_Summary_Mode :: enum {
	Invalid,
	Read,
	Write,
}

ctl_v2_task_chain_summary_write_flags :: proc(args: []string) -> bool {
	return has_flag(args, "--summary") || has_flag(args, "--body") || has_flag(args, "--file") || has_flag(args, "--stdin")
}

ctl_v2_task_chain_summary_mode :: proc(tokens, args: []string) -> (Ctl_Summary_Mode, string) {
	switch pos(tokens, 0) {
	case "get", "show", "read", "view":
		if ctl_v2_task_chain_summary_write_flags(args) do return .Invalid, "task-chain summary get is read-only; use `task-chain summary set <text>|--file <path>|--stdin` to write"
		return .Read, ""
	case "set":
		return .Write, ""
	case "":
		if ctl_v2_task_chain_summary_write_flags(args) do return .Write, ""
		return .Read, ""
	}
	return .Invalid, fmt.tprintf("unknown task-chain summary subcommand %q: use `summary get|show [--chain <id>]` to read or `summary set <text>|--file <path>|--stdin` to write", pos(tokens, 0))
}

// ctl_v2_task_chain_summary_body builds a WRITE (mode .Write only): the text
// comes from --summary/--body, --file, --stdin, or the positional after `set`.
ctl_v2_task_chain_summary_body :: proc(tokens, args: []string, stdin_text := "", file_text := "") -> (Ctl_Chain_Summary_Body, bool) {
	if mode, _ := ctl_v2_task_chain_summary_mode(tokens, args); mode != .Write do return {}, false
	summary := strings.trim_space(option_value(args, "--summary", option_value(args, "--body", "")))
	if file_text != "" && summary == "" {
		summary = strings.trim_right_space(file_text)
	} else if has_flag(args, "--stdin") {
		summary = stdin_text
	} else if summary == "" && pos(tokens, 0) == "set" {
		summary = pos(tokens, 1)
	}
	if summary == "" && !ctl_v2_task_chain_summary_write_flags(args) do return {}, false
	return Ctl_Chain_Summary_Body{chain_id = option_value(args, "--chain", option_value(args, "--chain-id", "")), summary = summary}, true
}

// ctl_v2_task_chain_summary_params is the summary body as agent RPC params.
ctl_v2_task_chain_summary_params :: proc(tokens, args: []string, stdin_text := "", file_text := "") -> (string, bool) {
	body, ok := ctl_v2_task_chain_summary_body(tokens, args, stdin_text, file_text)
	if !ok do return "", false
	return ctl_json_text(body), true
}

// ctl_v2_task_chain_summary_read_chain: the chain a read targets: --chain, the
// positional after get/show, else "" (the caller's own chain).
ctl_v2_task_chain_summary_read_chain :: proc(tokens, args: []string) -> string {
	if v := strings.trim_space(option_value(args, "--chain", option_value(args, "--chain-id", ""))); v != "" do return v
	if pos(tokens, 0) != "" do return strings.trim_space(pos(tokens, 1))
	return ""
}

// ctl_owner_summary_view: the summary read of a Bridge-owned chain, built
// from its owner agent.task_chain.show reply; false for any other chain.
ctl_owner_summary_view :: proc(show_json: string) -> (string, bool) {
	if !strings.contains(show_json, `"ok":true`) do return "", false
	chain := ctl_json_data_object(show_json)
	auth, has := chain["authority"].(json.Object)
	if !has || ctl_json_str(auth, "kind") != "owner" do return "", false
	summary, _ := chain["summary"].(json.String)
	// The owner Bridge returns ciphertext when it cannot decrypt (vault locked):
	// refuse rather than print an envelope as if it were the summary.
	if strings.has_prefix(string(summary), "vault:") {
		return json_object(json_kv_raw("ok", "false"), json_kv("code", "vault_locked"), json_kv("message", "the owner Bridge could not decrypt the chain summary (vault locked); unlock the Bridge vault and retry")), true
	}
	version := ctl_json_str(chain, "summary_version")
	if version == "" do version = "0"
	data := json_object(json_kv("chain_id", ctl_json_str(chain, "chain_id")), json_kv("summary", string(summary)), json_kv("version", version), json_kv("authority", "owner"))
	return json_object(json_kv_raw("ok", "true"), json_kv_raw("data", data)), true
}

ctl_v2_task_chain_summary :: proc(endpoint, token: string, tokens, args: []string) {
	mode, why := ctl_v2_task_chain_summary_mode(tokens, args)
	switch mode {
	case .Invalid:
		ctl_print_error_exit(why)
	case .Read:
		chain_id := ctl_v2_task_chain_summary_read_chain(tokens, args)
		// A Bridge-owned chain keeps its summary in the owner store: the owner
		// agent.task_chain.show carries it (agent.rest.request would reach the Hub).
		show_params := "{}"
		if chain_id != "" do show_params = json_object(json_kv("chain_id", chain_id))
		show, shown := ctl_agent_local_call(endpoint, token, "agent.task_chain.show", show_params)
		if !shown { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
		if view, is_owner := ctl_owner_summary_view(show); is_owner {
			fmt.println(view)
			if strings.contains(view, `"ok":false`) do os.exit(1)
			return
		}
		// Hub task chains are removed: every chain is Bridge-owned, so a reply
		// that is not an owner chain is an error, never a Hub fallback.
		if strings.contains(show, `"ok":false`) { fmt.println(show); os.exit(1) }
		ctl_print_error_exit("task-chain summary get: not a Bridge-owned chain (Hub task chains are removed); pass --chain <owner chain id>")
	case .Write:
	}
	stdin_text := ""
	file_text := ""
	if path := option_value(args, "--file", ""); path != "" {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			ctl_print_error_exit(fmt.tprintf("--file %s: cannot read", path))
		}
		file_text = string(data)
	} else if has_flag(args, "--stdin") {
		if data, err := os.read_entire_file("/dev/stdin", context.allocator); err == nil {
			stdin_text = string(data)
		}
	}
	params, ok := ctl_v2_task_chain_summary_params(tokens, args, stdin_text, file_text)
	if !ok {
		fmt.println(`{"ok":false,"message":"task-chain summary set requires <text>, --body <text>, --file <path>, or --stdin [--chain <id>]"}`)
		os.exit(1)
	}
	ctl_agent_call_task(endpoint, token, "agent.task_chain.set_summary", params, args)
}

// Ctl_Chain_Propose_Body: POST /api/v1/agent-actions/chain/propose and the
// agent.task_chain.propose params. tasks/inputs are carried from the proposal file.
Ctl_Chain_Propose_Body :: struct {
	chain_id:     string      `json:"chain_id,omitempty"`,
	kind:         string      `json:"kind,omitempty"`,
	rationale:    string      `json:"rationale,omitempty"`,
	alternative:  string      `json:"alternative,omitempty"`,
	auto_approve: Maybe(bool) `json:"auto_approve,omitempty"`,
	// require_decision: the proposal waits for an explicit decide (opt-in,
	// F1); without it proposals auto-approve.
	require_decision: Maybe(bool) `json:"require_decision,omitempty"`,
	tasks:        json.Value  `json:"tasks,omitempty"`,
	workflow:     string      `json:"workflow,omitempty"`,
	inputs:       json.Value  `json:"inputs,omitempty"`,
}

ctl_v2_task_chain_propose_body :: proc(args: []string, file_text: string) -> (body: Ctl_Chain_Propose_Body, ok: bool) {
	trimmed := strings.trim_space(file_text)
	if trimmed == "" || trimmed[0] != '{' do return {}, false
	parsed, perr := json.parse(transmute([]byte)trimmed, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if perr != nil do return {}, false
	obj, is_obj := parsed.(json.Object)
	if !is_obj do return {}, false

	body.chain_id = option_value(args, "--chain", option_value(args, "--chain-id", ""))
	if body.chain_id == "" {
		if s, sok := obj["chain_id"].(json.String); sok do body.chain_id = string(s)
	}
	if s, sok := obj["kind"].(json.String); sok && string(s) != "" {
		body.kind = string(s)
	} else {
		body.kind = option_value(args, "--kind", "")
	}
	if s, sok := obj["rationale"].(json.String); sok && string(s) != "" {
		body.rationale = string(s)
	} else {
		body.rationale = option_value(args, "--rationale", "")
	}
	if s, sok := obj["alternative"].(json.String); sok && string(s) != "" {
		body.alternative = string(s)
	} else {
		body.alternative = option_value(args, "--alternative", "")
	}
	// Proposals auto-approve by default (F1). `--require-decision` (or
	// "require_decision": true / "auto_approve": false in the file) keeps the
	// proposal pending until an explicit decide. `--auto-approve` is accepted
	// for compatibility and wins over a file-level opt-in.
	require_decision := has_flag(args, "--require-decision")
	if !require_decision && !has_flag(args, "--auto-approve") {
		if b, bok := obj["require_decision"].(json.Boolean); bok && bool(b) do require_decision = true
		if b, bok := obj["auto_approve"].(json.Boolean); bok && !bool(b) do require_decision = true
	}
	if require_decision {
		body.require_decision = true
	} else {
		body.auto_approve = true
	}

	if tasks, has_tasks := obj["tasks"].(json.Array); has_tasks {
		body.tasks = tasks
	} else {
		wf_ref := option_value(args, "--workflow", option_value(args, "--template", ""))
		if wf_ref == "" {
			if s, sok := obj["workflow"].(json.String); sok do wf_ref = string(s)
		}
		if wf_ref == "" {
			if s, sok := obj["template"].(json.String); sok do wf_ref = string(s)
		}
		if wf_ref == "" do return {}, false
		body.workflow = wf_ref
		if inputs, has_inputs := obj["inputs"].(json.Object); has_inputs do body.inputs = inputs
	}
	return body, true
}

// ctl_v2_task_chain_propose_params is the proposal as agent RPC params.
ctl_v2_task_chain_propose_params :: proc(args: []string, file_text: string) -> (string, bool) {
	body, ok := ctl_v2_task_chain_propose_body(args, file_text)
	if !ok do return "", false
	return ctl_json_text(body), true
}

ctl_v2_task_chain_propose :: proc(endpoint, token: string, tokens, args: []string) {
	_ = tokens
	file_text := ""
	path := option_value(args, "--file", option_value(args, "--proposal-file", ""))
	if path != "" {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			ctl_print_error_exit(fmt.tprintf("--file %s: cannot read", path))
		}
		file_text = string(data)
	} else if has_flag(args, "--stdin") {
		if data, err := os.read_entire_file("/dev/stdin", context.allocator); err == nil {
			file_text = string(data)
		}
	}
	params, ok := ctl_v2_task_chain_propose_params(args, file_text)
	if !ok {
		fmt.println(`{"ok":false,"message":"task-chain propose requires --file <proposal.json> (with tasks array) [--require-decision] [--chain <id>]"}`)
		os.exit(1)
	}
	ctl_agent_call_task(endpoint, token, "agent.task_chain.propose", params, args)
}

// Ctl_Fleet_Pause_Body: `{"roles":[…]}` from --role/--roles (empty = every
// role of the row).
Ctl_Fleet_Pause_Body :: struct {
	roles: []string `json:"roles"`,
}

// Ctl_Fleet_Set_Body: PUT /api/v1/task-chains/<id>/fleets/<agent>. Placement
// fields are presence-checked (an explicit empty value is sent).
Ctl_Fleet_Set_Body :: struct {
	capacity:         int           `json:"capacity"`,
	min_warm:         Maybe(int)    `json:"min_warm,omitempty"`,
	idle_ttl_seconds: Maybe(int)    `json:"idle_ttl_seconds,omitempty"`,
	roles:            []string      `json:"roles,omitempty"`,
	bridge_id:        Maybe(string) `json:"bridge_id,omitempty"`,
	provider:         Maybe(string) `json:"provider,omitempty"`,
	model:            Maybe(string) `json:"model,omitempty"`,
	bridge_models:    json.Value    `json:"bridge_models,omitempty"`,
}

// Ctl_Lease_Peek is what the lease verbs need from a `lease next` peek: where
// the leased task's work lives, for the bridge's vcs enrichment.
Ctl_Lease_Peek :: struct {
	status:     string,
	lease_id:   string,
	task_id:    string,
	attempt_no: int,
	// placement.workdir (the task's own git worktree) when the hub names one,
	// else placement.directory_path.
	directory_path: string,
}

// ctl_lease_peek_parse reads a lease.next (or task.show) response. The
// placement may sit on the lease, at the top level, or in the context pack.
ctl_lease_peek_parse :: proc(response: string) -> (Ctl_Lease_Peek, bool) {
	parsed, perr := json.parse(transmute([]byte)response, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil do return {}, false
	obj, is_obj := parsed.(json.Object)
	if !is_obj do return {}, false
	node := obj
	for _ in 0 ..< 5 {
		if _, has := node["lease"]; has do break
		if _, has := node["task"]; has do break
		if _, has := node["brief"]; has do break
		inner, got := node["data"].(json.Object)
		if !got do break
		node = inner
	}
	placement_dir :: proc(out: ^Ctl_Lease_Peek, holder: json.Object) {
		if out.directory_path != "" do return
		pl, ok := holder["placement"].(json.Object)
		if !ok do return
		if dp, dok := pl["directory_path"].(json.String); dok do out.directory_path = strings.clone(string(dp))
		if wd, wok := pl["workdir"].(json.String); wok && string(wd) != "" do out.directory_path = strings.clone(string(wd))
	}
	out: Ctl_Lease_Peek
	if v, ok := node["status"].(json.String); ok do out.status = strings.clone(string(v))
	if lease, ok := node["lease"].(json.Object); ok {
		if l, lok := lease["lease_id"].(json.String); lok do out.lease_id = strings.clone(string(l))
		if n, nok := lease["attempt_no"].(json.Float); nok do out.attempt_no = int(n)
		if n, nok := lease["attempt_no"].(json.Integer); nok do out.attempt_no = int(n)
		if t, tok := lease["task_id"].(json.String); tok do out.task_id = strings.clone(string(t))
		placement_dir(&out, lease)
	}
	task_obj, has_task := node["task"].(json.Object)
	if !has_task {
		if _, has_brief := node["brief"]; has_brief {
			task_obj = node
			has_task = true
		}
	}
	if has_task {
		if t, tok := task_obj["task_id"].(json.String); tok && out.task_id == "" do out.task_id = strings.clone(string(t))
		if out.attempt_no == 0 {
			if n, nok := task_obj["attempt_no"].(json.Float); nok do out.attempt_no = int(n)
			if n, nok := task_obj["attempt_no"].(json.Integer); nok do out.attempt_no = int(n)
		}
	}
	placement_dir(&out, node)
	if pack, pok := node["pack"].(json.Object); pok {
		// lease.next returns {status, lease, task, pack}; the placement (with the
		// chain directory's path) lives in the pack, at its top level and under
		// pack.lease.
		placement_dir(&out, pack)
		if pl_lease, lok := pack["lease"].(json.Object); lok do placement_dir(&out, pl_lease)
	}
	return out, out.task_id != ""
}

// ---- verify (removed; one-release stub) -------------------------------------------

// ctl_verify_removed_json is the M3 stub's whole output. Pure.
ctl_verify_removed_json :: proc() -> string {
	return json_object(
		json_kv_raw("ok", "true"),
		json_kv("verify", "removed"),
		json_kv("message", "Verification commands were removed; choose and report your own checks"),
	)
}

// ctl_v2_verify is the inert `ham-ctl verify` kept for one release so old
// instructions do not fail: it runs nothing, records nothing, never submits,
// and exits 0.
ctl_v2_verify :: proc(endpoint, token: string, tokens, args: []string) {
	_, _ = endpoint, token
	if pos(tokens, 0) == "help" || has_flag(args, "--help") || has_flag(args, "-h") { print_help_verify(); return }
	fmt.println(ctl_verify_removed_json())
}

// ---- help ------------------------------------------------------------------------

print_help_review :: proc() {
	fmt.println("ham-ctl review — post a review verdict on the task you were woken to review")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  post --verdict approve|request_changes [--summary <reason>] [--findings-file <json>] [--task <id>] [--on-behalf-of user]")
	fmt.println("      Changed requirements: --lease <id> --requirements-revision <n> --expected-attempt <n> --expected-head <sha>.")
	fmt.println("      Use the context you reviewed; user-proxy reviews omit --lease. Refresh after conflicts.")
	fmt.println("      Record your verdict. --task defaults to the task your lease names. request_changes")
	fmt.println("      needs --summary or findings. The")
	fmt.println("      findings file is a JSON array of {path?, line?, severity?, text}.")
	fmt.println("      Coordinator instances can pass `--on-behalf-of user` when the user said so in chat.")
	fmt.println("      Response: {gate: waiting|approved|changes_requested, task}.")
	fmt.println("      On a Bridge-owned chain an --on-behalf-of review never counts as the user: only the")
	fmt.println("      user's device-signed Approve / Request changes in the Heimdall app clears a user gate.")
	fmt.println("  A task's reviewers are agent ids: `task create|update --reviewer agt_a --reviewer agt_b")
	fmt.println("      [--require-user-approval]`. Every listed reviewer must approve.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl review post --verdict approve")
	fmt.println("  ham-ctl review post --verdict request_changes --findings-file findings.json")
	fmt.println("  ham-ctl review post --verdict request_changes --summary \"the zero case still crashes\"")
	fmt.println("  ham-ctl review post --task task_1 --verdict approve --on-behalf-of user")
}

print_help_merge :: proc() {
	fmt.println("ham-ctl merge — merge-back controls (coordinator, Bridge-owned chains)")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  retry <task-id> --reason <text>   Retry the unchanged pending merge of a merge-blocked task")
	fmt.println("                                    (after the conflict or base problem was fixed). On a Hub")
	fmt.println("                                    chain this answers owner_chain_only.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl merge retry task_1 --reason \"rebased main; conflict resolved\"")
}

print_help_verify :: proc() {
	fmt.println("ham-ctl verify — removed")
	fmt.println("")
	fmt.println("Configured verification commands were removed. Choose the checks that fit your")
	fmt.println("task, run them yourself (for example with `ham-ctl shell run`), and report the")
	fmt.println("exact commands and outcomes in your `lease submit` summary; an independent")
	fmt.println("reviewer judges correctness.")
	fmt.println("")
	fmt.println("For one release `ham-ctl verify` still exists as a stub: it prints")
	fmt.println("{\"ok\":true,\"verify\":\"removed\",…}, runs nothing, never submits, and exits 0.")
}

// ---- workflow (M3b) --------------------------------------------------------------

// Ctl_Workflow_Define_Body: POST /api/v1/workflows/definitions and the
// agent.workflow.define params; definition is the --file document.
Ctl_Workflow_Define_Body :: struct {
	name:       string     `json:"name,omitempty"`,
	definition: json.Value `json:"definition"`,
}

// ctl_v2_workflow_inputs_value merges the --inputs-file (or a JSON --inputs)
// object with repeated --input k=v (a flag wins over the file's key). nil when
// there are no inputs; ok=false on a malformed value. Temp-allocated.
ctl_v2_workflow_inputs_value :: proc(args: []string, inputs_file_text := "") -> (json.Value, bool) {
	inputs := make(json.Object, allocator = context.temp_allocator)

	base_json := strings.trim_space(inputs_file_text)
	if base_json == "" {
		raw_flag := strings.trim_space(option_value(args, "--inputs", ""))
		if strings.has_prefix(raw_flag, "{") {
			base_json = raw_flag
		}
	}
	if base_json != "" {
		if !strings.has_prefix(base_json, "{") do return nil, false
		parsed, perr := json.parse(transmute([]byte)base_json, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		if perr != nil do return nil, false
		obj, is_obj := parsed.(json.Object)
		if !is_obj do return nil, false
		for k, v in obj do inputs[k] = v
	}

	kv_flags := ctl_collect_repeated(args, "--input", "--inputs")
	defer delete(kv_flags)
	for item in kv_flags {
		trimmed := strings.trim_space(item)
		if trimmed == "" || strings.has_prefix(trimmed, "{") do continue
		eq := strings.index_byte(trimmed, '=')
		if eq <= 0 do return nil, false
		k := strings.trim_space(trimmed[:eq])
		v := trimmed[eq + 1:]
		if k == "" do return nil, false
		inputs[k] = json.String(v)
	}

	if len(inputs) == 0 do return nil, true
	return inputs, true
}

// Ctl_Workflow_Run_Body: POST /api/v1/task-chains/<id>/workflow-runs and the
// agent.workflow.run params.
Ctl_Workflow_Run_Body :: struct {
	ref:           string         `json:"ref"`,
	request_id:    string         `json:"request_id"`,
	inputs:        json.Value     `json:"inputs"`,
	chain_id:      string         `json:"chain_id,omitempty"`,
	title:         string         `json:"title,omitempty"`,
	prerequisites: []Ctl_Work_Ref `json:"prerequisites"`,
}

// Ctl_Workflow_Status_Params: agent.workflow.status/history/output params.
Ctl_Workflow_Status_Params :: struct {
	run_id:       string     `json:"run_id"`,
	execution_no: Maybe(i64) `json:"execution_no,omitempty"`,
	stage_key:    string     `json:"stage_key,omitempty"`,
}

// Ctl_Workflow_Retry_Body: POST /api/v1/workflow-runs/<id>/retry and the
// agent.workflow.retry params.
Ctl_Workflow_Retry_Body :: struct {
	run_id:            string `json:"run_id"`,
	reason:            string `json:"reason"`,
	expected_revision: i64    `json:"expected_revision"`,
}

ctl_v2_workflow_retry_body :: proc(tokens, args: []string) -> (Ctl_Workflow_Retry_Body, bool) {
	id := strings.trim_space(option_value(args, "--run", pos(tokens, 1)))
	reason := strings.trim_space(option_value(args, "--reason", ""))
	revision := option_value(args, "--expected-revision", "")
	n, parsed := strconv.parse_i64(revision)
	for flag in ([?]string{"--stage", "--task", "--task-id", "--cascade", "--chain", "--execution"}) { if has_flag(args, flag) do return {}, false }
	if id == "" || reason == "" || !parsed || n <= 0 || pos(tokens, 2) != "" do return {}, false
	return Ctl_Workflow_Retry_Body{run_id = id, reason = reason, expected_revision = n}, true
}

ctl_v2_workflow_retry_params :: proc(tokens, args: []string) -> (run_id, target, params: string, ok: bool) {
	body, bok := ctl_v2_workflow_retry_body(tokens, args)
	if !bok do return "", "", "", false
	return body.run_id, "", ctl_json_text(body), true
}

// Ctl_Workflow_Cancel_Body: POST /api/v1/workflow-runs/<id>/cancel and the
// agent.workflow.cancel params.
Ctl_Workflow_Cancel_Body :: struct {
	run_id:       string `json:"run_id"`,
	reason:       string `json:"reason"`,
	execution_no: i64    `json:"execution_no"`,
}

ctl_v2_workflow_cancel_body :: proc(tokens, args: []string) -> (Ctl_Workflow_Cancel_Body, bool) {
	id := strings.trim_space(option_value(args, "--run", pos(tokens, 1)))
	n, valid := strconv.parse_i64(option_value(args, "--execution", "0"))
	if !valid || n <= 0 do return {}, false
	return Ctl_Workflow_Cancel_Body{run_id = id, reason = option_value(args, "--reason", ""), execution_no = n}, true
}

ctl_v2_workflow_cancel_params :: proc(tokens, args: []string) -> (run_id, params: string) {
	body, ok := ctl_v2_workflow_cancel_body(tokens, args)
	if !ok do return "", "{}"
	return body.run_id, ctl_json_text(body)
}

ctl_v2_workflow :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "templates", "list", "history", "define", "run", "status", "output":
		// Hub workflows are removed with the Hub task-chain engine; retry and
		// cancel remain for runs of Bridge-owned chains.
		ctl_hub_chains_removed_exit(fmt.tprintf("workflow %s", verb if verb != "" else "templates"))
	case "retry":
		_, _, params, ok := ctl_v2_workflow_retry_params(tokens, args)
		if !ok {
			fmt.println(`{"ok":false,"message":"workflow retry requires <run_id> --expected-revision <n> --reason <text>"}`)
			os.exit(1)
		}
		defer delete(params)
		ctl_agent_call_task(endpoint, token, "agent.workflow.retry", params, args)
	case "cancel":
		id, params := ctl_v2_workflow_cancel_params(tokens, args)
        if id == "" { fmt.println(`{"ok":false,"message":"workflow cancel requires <run_id> --execution <number>"}`); os.exit(1) }
		defer delete(params)
		ctl_agent_call_task(endpoint, token, "agent.workflow.cancel", params, args)
	case:
		print_help_workflow()
	}
}

ctl_workflow_user_mode :: proc(cmd, args: []string) {
	tokens := cmd[1:] if len(cmd) > 1 else []string{}
	if pos(tokens, 0) == "help" || has_flag(args, "--help") || has_flag(args, "-h") {
		print_help_workflow()
		return
	}
	ctl_hub_chains_removed_exit("workflow")
}

print_help_workflow :: proc() {
 fmt.println("ham-ctl workflow: Hub workflows are removed with the Hub task-chain engine.")
 fmt.println("  retry <run_id> --expected-revision <n> --reason <text>   (a run of a Bridge-owned chain)")
 fmt.println("  cancel <run_id> --execution <number> [--reason <text>]")
}


// Relays an opaque human-device-signed request. The instance token authenticates
// transport only; it cannot sign, create grants, or authorize owner mutations.
ctl_v2_owner_local :: proc(endpoint,token:string,tokens,args:[]string) {
    if pos(tokens,1)=="lease" {
        path:=option_value(args,"--request-file","")
        if path=="" do ctl_print_error_exit("--request-file is required")
        bytes,err:=os.read_entire_file(path,context.temp_allocator)
        if err!=nil do ctl_print_error_exit("cannot read owner-local lease input")
        if _,valid:=contracts.owner_parse(string(bytes),"lease_input");!valid {
            if _,valid:=contracts.owner_parse(string(bytes),"lifecycle_input");!valid do ctl_print_error_exit("invalid owner-local lease/lifecycle input")
        }
        response,sent:=ctl_agent_local_call(endpoint,token,"agent.owner_local.lease",string(bytes))
        if !sent do ctl_print_error_exit("local Bridge endpoint is not reachable")
        fmt.println(response)
        if strings.contains(response,`"ok":false`) do os.exit(1)
        return
    }
    if pos(tokens,1)!="relay" { ctl_print_error_exit("usage: task-chain owner-local relay --request-file <browser-export.json>") }
    path:=option_value(args,"--request-file","")
    if path=="" do ctl_print_error_exit("--request-file is required")
    bytes,read:=os.read_entire_file(path,context.temp_allocator)
    if read!=nil do ctl_print_error_exit("cannot read signed request file")
    relay,valid:=contracts.owner_parse(string(bytes),"relay")
    if !valid do ctl_print_error_exit("invalid signed request relay")
    now:=time.to_unix_nanoseconds(time.now())/1000000
    relay["expires_ms"]=json.String(fmt.tprintf("%d",now+60000))
    relay["request_id"]=json.String(fmt.tprintf("req_cli_%d",time.to_unix_nanoseconds(time.now())))
    ctl_agent_rest(endpoint,token,{method=.POST,path=ctl_api("owner-local","relay"),body=httpc.json_body(relay)})
}

// One-shot legacy import (R3). Consent is a browser-device signature over the
// selection and destination genesis; the instance token only transports it.
// Without --request-file this prints the Hub preflight for the chain.
ctl_v2_task_chain_migrate :: proc(endpoint,token:string,args:[]string) {
    chain:=option_value(args,"--chain","")
    owner:=option_value(args,"--owner","")
    if has_flag(args,"--abort") {
        // Aborting returns a frozen chain to the Hub writer and abandons any
        // owner-side import: a human decision the Hub accepts only from the
        // account owner's browser session, never from an agent token.
        ctl_print_error_exit("migration abort needs the account owner: open the task chain's owner-local panel and use \"Abort unfinished migration\" (agent tokens are refused)")
    }
    if chain=="" || owner=="" do ctl_print_error_exit("usage: task-chain migrate --chain <id> --owner <bridge-id> [--request-file <signed.json>] | --abort")
    path:=option_value(args,"--request-file","")
    if path=="" {
        q:=ctl_query_make()
        ctl_query_add(&q,"chain_id",chain)
        ctl_agent_rest(endpoint,token,{method=.GET,path=ctl_api("owner-local","migrations","preflight"),query=q[:]})
        return
    }
    bytes,read:=os.read_entire_file(path,context.temp_allocator)
    if read!=nil do ctl_print_error_exit("cannot read signed migration request")
    request,valid:=ctl_migration_request_parse(string(bytes),chain,owner)
    if !valid do ctl_print_error_exit("signed migration request must hold a selection and genesis for --chain and --owner")
    ctl_agent_rest(endpoint,token,{method=.POST,path=ctl_api("owner-local","migrations"),body=httpc.json_body(request)})
}
Ctl_Migration_Request :: struct { selection,genesis:string }
ctl_migration_request_parse :: proc(raw,chain,owner:string)->(Ctl_Migration_Request,bool) {
    request:Ctl_Migration_Request
    if json.unmarshal_string(raw,&request,.JSON,context.temp_allocator)!=nil do return {},false
    selection,sel_ok:=contracts.owner_parse(request.selection,"migration_selection")
    genesis,gen_ok:=contracts.owner_parse(request.genesis,"genesis")
    if !sel_ok || !gen_ok do return {},false
    get:=contracts.owner_string
    if get(selection,"chain_id")!=chain || get(selection,"owner_bridge_id")!=owner || get(genesis,"chain_id")!=chain || get(genesis,"creation_op")!=get(selection,"migration_id") do return {},false
    return request,true
}

// ctl_hub_chains_removed_exit: the typed refusal for a verb that only ever
// reached the removed Hub task-chain engine.
ctl_hub_chains_removed_exit :: proc(what: string) -> ! {
	fmt.println(json_object(json_kv_raw("ok", "false"), json_kv("code", "hub_chains_removed"),
		json_kv("message", fmt.tprintf("%s: Hub task chains are removed; chains are Bridge-owned (import legacy chains from Settings → Bridge)", what))))
	os.exit(1)
}
