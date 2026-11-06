// Pure workflow.v1 language operations, derived from the original taskv2
// workflow.odin parser, output contracts and placeholder renderer. This package
// deliberately has no Hub, repository, process or network dependency.
package workflow_v1

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import jsonx "odin_test:lib/jsonx"

Task_Kind :: enum { Task, Gate }
task_kind_from_string :: proc(s:string)->Task_Kind { return .Gate if s=="gate" else .Task }
Error_Code :: enum { None, Validation_Failed }
Error :: struct { code:Error_Code, message,details_json:string }
language_error :: proc(code:Error_Code,message:string,details_json:="")->Error { return Error{code,message,details_json} }
Stage_View :: struct { outputs:[]string }

Workflow_Input_Spec :: struct {
	name:        string,
	type_name:   string,
	required:    bool,
	default_val: string,
	has_default: bool,
	// default_raw is the declared default as raw JSON (any type), so array
	// defaults can feed `for_each: "inputs.<name>"`. type_declared records
	// whether the spec stated a type (the parser otherwise assumes "string").
	default_raw:   string,
	type_declared: bool,
	description: string,
}

Workflow_Stage_Spec :: struct {
	key:                    string,
	kind:                   Task_Kind,
	title:                  string,
	description:            string,
	depends_on:             []string,
	for_each:               string,
	parallel:               int,
	max_parallel:           int,
	priority:               string,
	brief_raw:              string,
	gate_raw:               string,
	approver:               string,
	prompt:                 string,
	requires_user_approval: bool,
	// the spec SAID requires_user_approval (true or false); absent → the solo default.
	has_requires_user_approval: bool,
	raw_json:               string,
}

Workflow_Parsed_Spec :: struct {
	name:            string,
	title:           string,
	description:     string,
	version:         int,
	inputs:          []Workflow_Input_Spec,
	defaults_raw:    string,
	stages:          []Workflow_Stage_Spec,
	normalized_json: string,
}

Workflow_Run_Snapshot :: struct {
	spec:        Workflow_Parsed_Spec,
	inputs_json: string,
	// inputs_members: key → raw value text of inputs_json, scanned once when
	// the snapshot is built. Every {{inputs.*}} placeholder and input fan-out
	// reads it; re-extracting each key from the JSON text cost a full parse of
	// the whole input snapshot per lookup (multi-second for MB-sized inputs,
	// inside the UoW).
	inputs_members: map[string]string,
	def_id:      string,
}

// parse_and_validate_workflow_spec parses and validates both dialects of workflow.v1:
//   Dialect A: {"kind":"workflow", "v":1, "name":..., "stages":[...]}
//   Dialect B: {"schema":"workflow.v1", "version":1, "name":..., "stages":[...]}
parse_and_validate_workflow_spec :: proc(raw_spec: string, name_override := "", version_override := 0, allocator := context.temp_allocator) -> (Workflow_Parsed_Spec, bool, Error) {
	trimmed := strings.trim_space(raw_spec)
	if !strings.has_prefix(trimmed, "{") || !strings.has_suffix(trimmed, "}") {
		return {}, false, language_error(.Validation_Failed, "workflow spec must be a JSON object", `{"code":"workflow_invalid"}`)
	}
	// Kept aligned with the original workflow.v1 parser. Boundary adapters
	// reject removed verification fields rather than executing them.
	// The owner boundary rejects removed command fields before parsing.
	schema_str := strings.trim_space(jsonx.extract_string(trimmed, "schema", "", true, allocator))
	kind_str := strings.trim_space(jsonx.extract_string(trimmed, "kind", "", true, allocator))
	if schema_str != "" && schema_str != "workflow.v1" && schema_str != "workflow" {
		return {}, false, language_error(.Validation_Failed, "workflow schema must be workflow.v1", `{"code":"workflow_invalid"}`)
	}
	if kind_str != "" && kind_str != "workflow" && kind_str != "workflow.v1" {
		return {}, false, language_error(.Validation_Failed, "workflow kind must be workflow", `{"code":"workflow_invalid"}`)
	}
	ver := jsonx.extract_int(trimmed, "version", 0, true)
	if ver <= 0 do ver = jsonx.extract_int(trimmed, "v", 1, true)
	if version_override > 0 do ver = version_override
	if ver <= 0 do ver = 1

	name := strings.trim_space(name_override)
	if name == "" do name = strings.trim_space(jsonx.extract_string(trimmed, "name", "", true, allocator))
	if name == "" do name = strings.trim_space(jsonx.extract_string(trimmed, "id", "", true, allocator))
	title := strings.trim_space(jsonx.extract_string(trimmed, "title", name, true, allocator))
	if title == "" do title = name
	desc := strings.trim_space(jsonx.extract_string(trimmed, "description", "", true, allocator))

	defaults_raw, has_def := jsonx.extract_raw_object(trimmed, "defaults", true, allocator)
	if !has_def || strings.trim_space(defaults_raw) == "" do defaults_raw = "{}"

	inputs_specs := parse_workflow_inputs_spec(trimmed, allocator)

	stages_arr, has_stages := jsonx.extract_raw_array(trimmed, "stages", true, allocator)
	if !has_stages || strings.trim_space(stages_arr) == "" {
		return {}, false, language_error(.Validation_Failed, "workflow stages array is required", `{"code":"workflow_invalid"}`)
	}
	stage_objs, ok_arr := split_json_array_objects(stages_arr, allocator)
	if !ok_arr || len(stage_objs) == 0 {
		return {}, false, language_error(.Validation_Failed, "workflow must declare at least one stage", `{"code":"workflow_invalid"}`)
	}

	stages := make([dynamic]Workflow_Stage_Spec, 0, len(stage_objs), allocator)
	stage_by_key := make(map[string]Workflow_Stage_Spec, len(stage_objs), allocator)

	for sobj in stage_objs {
		skey := strings.trim_space(jsonx.extract_string(sobj, "key", "", true, allocator))
		if skey == "" do skey = strings.trim_space(jsonx.extract_string(sobj, "id", "", true, allocator))
		if !is_valid_stage_key(skey) {
			return {}, false, language_error(.Validation_Failed, fmt.tprintf("invalid or empty stage key: %s", skey), `{"code":"workflow_invalid"}`)
		}
		if _, dup := stage_by_key[skey]; dup {
			return {}, false, language_error(.Validation_Failed, fmt.tprintf("duplicate stage key: %s", skey), `{"code":"workflow_invalid"}`)
		}
		skind_str := strings.trim_space(jsonx.extract_string(sobj, "kind", "task", true, allocator))
		if skind_str == "" do skind_str = "task"
		if skind_str != "task" && skind_str != "gate" {
			return {}, false, language_error(.Validation_Failed, fmt.tprintf("stage %s kind must be task or gate", skey), `{"code":"workflow_invalid"}`)
		}
		skind := task_kind_from_string(skind_str)
		stitle := strings.trim_space(jsonx.extract_string(sobj, "title", skey, true, allocator))
		if stitle == "" do stitle = skey
		sdesc := strings.trim_space(jsonx.extract_string(sobj, "description", "", true, allocator))
		deps := jsonx.extract_string_array(sobj, "depends_on", true, allocator)
		if len(deps) == 0 do deps = jsonx.extract_string_array(sobj, "needs", true, allocator)
		for_each := strings.trim_space(jsonx.extract_string(sobj, "for_each", "", true, allocator))
		max_p := jsonx.extract_int(sobj, "max_parallel", 0, true)
		parallel_n, has_parallel := jsonx.extract_int_found(sobj, "parallel", true)
		if has_parallel && (parallel_n < 1 || parallel_n > 50) {
			return {}, false, language_error(.Validation_Failed, fmt.tprintf("stage %s parallel must be between 1 and 50", skey), `{"code":"workflow_invalid"}`)
		}
		prio := strings.trim_space(jsonx.extract_string(sobj, "priority", "", true, allocator))
		brief_raw, has_brief := jsonx.extract_raw_object(sobj, "brief", true, allocator)
		if !has_brief do brief_raw = "{}"
		// If stage-level `output` is declared and `brief` has no `output`, merge it into `brief_raw`
		if !brief_has_output_contract(brief_raw) {
			if stage_out_obj, has_so := jsonx.extract_raw_object(sobj, "output", true, allocator); has_so && strings.trim_space(stage_out_obj) != "" {
				bb := json_begin(allocator)
				for k, v in jsonx_top_level_members(brief_raw) do json_raw(&bb, k, v)
				json_raw(&bb, "output", stage_out_obj)
				brief_raw = json_end(&bb)
			} else if stage_out_str := strings.trim_space(jsonx.extract_string(sobj, "output", "", true, allocator)); stage_out_str != "" && stage_out_str != "none" {
				bb := json_begin(allocator)
				for k, v in jsonx_top_level_members(brief_raw) do json_raw(&bb, k, v)
				json_str(&bb, "output", stage_out_str)
				brief_raw = json_end(&bb)
			}
		}
		gate_raw, has_gate := jsonx.extract_raw_object(sobj, "gate", true, allocator)
		if !has_gate do gate_raw = "{}"
		approver := strings.trim_space(jsonx.extract_string(sobj, "approver", "", true, allocator))
		if approver == "" && has_gate do approver = strings.trim_space(jsonx.extract_string(gate_raw, "approver", "", true, allocator))
		if approver == "" && has_brief do approver = strings.trim_space(jsonx.extract_string(brief_raw, "approver", "", true, allocator))
		if approver == "" do approver = "user_or_coordinator"
		prompt := strings.trim_space(jsonx.extract_string(sobj, "prompt", "", true, allocator))
		if prompt == "" && has_gate do prompt = strings.trim_space(jsonx.extract_string(gate_raw, "prompt", "", true, allocator))
		if prompt == "" && has_brief do prompt = strings.trim_space(jsonx.extract_string(brief_raw, "goal", "", true, allocator))
		req_user, has_req_user := jsonx.extract_bool_literal(sobj, "requires_user_approval", true)
		if !has_req_user && has_brief do req_user, has_req_user = jsonx.extract_bool_literal(brief_raw, "requires_user_approval", true)

		if skind == .Gate && (for_each != "" || parallel_n > 1) {
			return {}, false, language_error(.Validation_Failed, fmt.tprintf("gate stage %s cannot use for_each or parallel > 1", skey), `{"code":"workflow_invalid"}`)
		}
		if skind == .Gate && approver != "user" && approver != "user_or_coordinator" {
			return {}, false, language_error(.Validation_Failed, fmt.tprintf("gate stage %s approver must be user or user_or_coordinator", skey), `{"code":"workflow_invalid"}`)
		}
		if skind == .Task {
			bgoal := strings.trim_space(jsonx.extract_string(brief_raw, "goal", "", true, allocator))
			// A stage needs a goal and something checkable: acceptance items or a
			// structured output contract. No command is ever required.
			bacc := jsonx.extract_string_array(brief_raw, "acceptance", true, allocator)
			if bgoal == "" || (len(bacc) == 0 && !brief_has_output_contract(brief_raw)) {
				return {}, false, language_error(.Validation_Failed, fmt.tprintf("stage %s brief requires a non-empty goal and acceptance items or an output contract", skey), `{"code":"workflow_invalid"}`)
			}
		}

		st := Workflow_Stage_Spec{
			key                    = skey,
			kind                   = skind,
			title                  = stitle,
			description            = sdesc,
			depends_on             = deps[:],
			for_each               = for_each,
			parallel               = parallel_n if parallel_n > 0 else 1,
			max_parallel           = max_p,
			priority               = prio,
			brief_raw              = brief_raw,
			gate_raw               = gate_raw,
			approver               = approver,
			prompt                 = prompt,
			requires_user_approval = req_user,
			has_requires_user_approval = has_req_user,
			raw_json               = sobj,
		}
		append(&stages, st)
		stage_by_key[skey] = st
	}

	// Validate depends_on references exist and no self-dependency
	for st in stages {
		for dep in st.depends_on {
			d := strings.trim_space(dep)
			if d == st.key {
				return {}, false, language_error(.Validation_Failed, fmt.tprintf("stage %s cannot depend on itself", st.key), `{"code":"workflow_cycle"}`)
			}
			if _, ok := stage_by_key[d]; !ok {
				return {}, false, language_error(.Validation_Failed, fmt.tprintf("stage %s depends_on unknown stage %s", st.key, d), `{"code":"workflow_invalid"}`)
			}
		}
	}

	// Cycle detection (DFS 3-color: 0=unvisited, 1=visiting, 2=visited)
	color := make(map[string]int, len(stages), allocator)
	for st in stages {
		if color[st.key] == 0 {
			if workflow_has_cycle_dfs(st.key, stage_by_key, &color) {
				return {}, false, language_error(.Validation_Failed, "workflow stage dependency graph contains a cycle", `{"code":"workflow_cycle"}`)
			}
		}
	}

	// Validate for_each paths and reachability in depends_on transitive closure, plus placeholder references
	for st in stages {
		ancestors := make(map[string]bool, len(stages), allocator)
		collect_stage_ancestors(st.key, stage_by_key, &ancestors)
		if input_field, is_input := parse_for_each_input_expr(st.for_each); is_input {
			if input_field == "" {
				return {}, false, language_error(.Validation_Failed, fmt.tprintf("stage %s has invalid for_each expression: %s (use inputs.<array-input-name>)", st.key, st.for_each), `{"code":"workflow_invalid"}`)
			}
			if verr := validate_for_each_input_declaration(st.key, input_field, inputs_specs); verr.code != .None {
				return {}, false, verr
			}
		} else if st.for_each != "" {
			up_stage, up_field, ok_fe := parse_for_each_expr(st.for_each)
			if !ok_fe || up_stage == "" || up_field == "" {
				return {}, false, language_error(.Validation_Failed, fmt.tprintf("stage %s has invalid for_each expression: %s", st.key, st.for_each), `{"code":"workflow_invalid"}`)
			}
			if !ancestors[up_stage] {
				return {}, false, language_error(.Validation_Failed, fmt.tprintf("stage %s for_each references stage %s which is not in its depends_on closure", st.key, up_stage), `{"code":"workflow_invalid"}`)
			}
			up_spec := stage_by_key[up_stage]
			if !brief_has_output_contract(up_spec.brief_raw) {
				return {}, false, language_error(.Validation_Failed, fmt.tprintf("stage %s for_each references stage %s which has no output contract", st.key, up_stage), `{"code":"workflow_invalid"}`)
			}
		}
		if perr := validate_stage_placeholders(st, ancestors, stage_by_key); perr.code != .None {
			return {}, false, perr
		}
	}

	parsed := Workflow_Parsed_Spec{
		name            = name,
		title           = title,
		description     = desc,
		version         = ver,
		inputs          = inputs_specs,
		defaults_raw    = defaults_raw,
		stages          = stages[:],
		normalized_json = trimmed,
	}
	return parsed, true, Error{}
}

@(private = "file")
is_valid_stage_key :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 64 do return false
	for i in 0..<len(s) {
		ch := s[i]
		is_lower := ch >= 'a' && ch <= 'z'
		is_upper := ch >= 'A' && ch <= 'Z'
		is_digit := ch >= '0' && ch <= '9'
		if i == 0 && !is_lower && !is_upper do return false
		if !is_lower && !is_upper && !is_digit && ch != '_' && ch != '-' do return false
	}
	return true
}

@(private = "file")
workflow_has_cycle_dfs :: proc(key: string, stage_by_key: map[string]Workflow_Stage_Spec, color: ^map[string]int) -> bool {
	color[key] = 1
	st, ok := stage_by_key[key]
	if ok {
		for dep in st.depends_on {
			d := strings.trim_space(dep)
			c := color[d]
			if c == 1 do return true
			if c == 0 && workflow_has_cycle_dfs(d, stage_by_key, color) do return true
		}
	}
	color[key] = 2
	return false
}

@(private = "file")
collect_stage_ancestors :: proc(key: string, stage_by_key: map[string]Workflow_Stage_Spec, out: ^map[string]bool) {
	st, ok := stage_by_key[key]
	if !ok do return
	for dep in st.depends_on {
		d := strings.trim_space(dep)
		if !out[d] {
			out[d] = true
			collect_stage_ancestors(d, stage_by_key, out)
		}
	}
}

// WORKFLOW_FAN_OUT_MAX_ITEMS bounds one for_each stage (input or stage-output
// source). Expansion creates every item's task in a single transaction, so an
// unbounded array would be an unbounded write. Input fan-out over the cap is
// rejected before the run is created; stage-output fan-out over the cap fails
// the run at expansion (nothing from that stage is created).
WORKFLOW_FAN_OUT_MAX_ITEMS :: 256

// parse_for_each_input_expr recognises workflow-input fan-out:
//   "inputs.<name>" (canonical) or "workflow.input.<name>" (placeholder alias).
// is_input is true whenever the expression uses an input prefix; field is ""
// when the remainder is not a single top-level input name (nested paths are
// not supported), which callers report as an invalid expression.
parse_for_each_input_expr :: proc(expr: string) -> (field: string, is_input: bool) {
	s := strings.trim_space(expr)
	rest := ""
	if strings.has_prefix(s, "inputs.") {
		rest = s[len("inputs."):]
	} else if strings.has_prefix(s, "workflow.input.") {
		rest = s[len("workflow.input."):]
	} else {
		return "", false
	}
	// A stage that happens to be keyed "inputs" keeps its stage-output form.
	if strings.has_prefix(rest, "output.") || strings.has_prefix(rest, "outputs[") do return "", false
	if len(rest) == 0 || len(rest) > 128 do return "", true
	for i in 0..<len(rest) {
		ch := rest[i]
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') do return "", true
	}
	return rest, true
}

// workflow_input_type_is_array reports whether a declared input type names a
// JSON array ("array", "list", "array<object>", "string[]", ...).
@(private = "file")
workflow_input_type_is_array :: proc(type_name: string) -> bool {
	t := strings.to_lower(strings.trim_space(type_name), context.temp_allocator)
	return t == "array" || t == "list" || strings.has_prefix(t, "array<") || strings.has_prefix(t, "list<") || strings.has_suffix(t, "[]")
}

// validate_for_each_input_declaration checks an input fan-out against the
// definition's declared inputs. Undeclared inputs are allowed only when the
// definition declares no inputs at all (the run then validates the value).
@(private = "file")
validate_for_each_input_declaration :: proc(stage_key, field: string, inputs: []Workflow_Input_Spec) -> Error {
	if len(inputs) == 0 do return Error{}
	for inp in inputs {
		if inp.name != field do continue
		if inp.type_declared && !workflow_input_type_is_array(inp.type_name) {
			return language_error(.Validation_Failed, fmt.tprintf("stage %s for_each input %s is declared as type %s; declare it as \"type\": \"array\"", stage_key, field, inp.type_name), `{"code":"workflow_invalid"}`)
		}
		if raw := strings.trim_space(inp.default_raw); raw != "" && raw != "null" && !strings.has_prefix(raw, "[") {
			return language_error(.Validation_Failed, fmt.tprintf("stage %s for_each input %s has a non-array default", stage_key, field), `{"code":"workflow_invalid"}`)
		}
		return Error{}
	}
	return language_error(.Validation_Failed, fmt.tprintf("stage %s for_each references undeclared input %s", stage_key, field), `{"code":"workflow_invalid"}`)
}

// workflow_input_raw_member returns the raw JSON text of a top-level member.
@(private = "file")
workflow_input_raw_member :: proc(members: map[string]string, key: string) -> (string, bool) {
	raw, ok := members[key]
	if !ok do return "", false
	return strings.trim_space(raw), true
}

// resolve_for_each_input_items resolves `for_each: "inputs.<field>"` from the
// execution's immutable input snapshot (falling back to the declared default).
// Items keep array order, so stage indexes are deterministic across
// reconciliation passes and retries. An empty array is valid (zero items).
resolve_for_each_input_items :: proc(stage_key, field: string, inputs_members: map[string]string, inputs: []Workflow_Input_Spec, allocator := context.temp_allocator) -> ([]string, Error) {
	raw, supplied := workflow_input_raw_member(inputs_members, field)
	if !supplied || raw == "null" {
		raw, supplied = "", false
		for inp in inputs {
			if inp.name == field && strings.trim_space(inp.default_raw) != "" && strings.trim_space(inp.default_raw) != "null" {
				raw, supplied = strings.trim_space(inp.default_raw), true
			}
		}
	}
	if !supplied {
		return nil, language_error(.Validation_Failed, fmt.tprintf("stage %s for_each needs input %s: supply it as a JSON array (for example --inputs-file with {\"%s\": [...]})", stage_key, field, field), `{"code":"workflow_input_invalid"}`)
	}
	if len(raw) < 2 || raw[0] != '[' || raw[len(raw) - 1] != ']' {
		return nil, language_error(.Validation_Failed, fmt.tprintf("stage %s for_each input %s must be a JSON array", stage_key, field), `{"code":"workflow_input_invalid"}`)
	}
	items: []string
	if objs, ok := split_json_array_objects(raw, allocator); ok {
		items = objs
	} else {
		items = jsonx_top_level_array_items(raw)
	}
	if err := workflow_check_fan_out_size(stage_key, fmt.tprintf("inputs.%s", field), len(items), true); err.code != .None do return nil, err
	return items, Error{}
}

// workflow_check_fan_out_size enforces WORKFLOW_FAN_OUT_MAX_ITEMS for both
// fan-out sources. Input arrays report workflow_input_invalid (the caller fixes
// the run inputs); stage outputs report workflow_fan_out_too_large, which fails
// the run at expansion before any of that stage's tasks are created.
workflow_check_fan_out_size :: proc(stage_key, source: string, count: int, from_inputs: bool) -> Error {
	if count <= WORKFLOW_FAN_OUT_MAX_ITEMS do return Error{}
	if from_inputs {
		return language_error(.Validation_Failed, fmt.tprintf("stage %s for_each %s has %d items; at most %d are allowed per fan-out stage (split the list across runs)", stage_key, source, count, WORKFLOW_FAN_OUT_MAX_ITEMS), `{"code":"workflow_input_invalid"}`)
	}
	return language_error(.Validation_Failed, fmt.tprintf("stage %s for_each %s produced %d items; at most %d are allowed per fan-out stage", stage_key, source, count, WORKFLOW_FAN_OUT_MAX_ITEMS), `{"code":"workflow_fan_out_too_large"}`)
}

// validate_workflow_run_inputs checks every input fan-out before a run is
// created, so a missing or non-array input never dispatches part of a run.
validate_workflow_run_inputs :: proc(parsed: Workflow_Parsed_Spec, inputs_json: string) -> Error {
	members := jsonx_top_level_members(inputs_json)
	for st in parsed.stages {
		field, is_input := parse_for_each_input_expr(st.for_each)
		if !is_input do continue
		if _, err := resolve_for_each_input_items(st.key, field, members, parsed.inputs); err.code != .None do return err
	}
	return Error{}
}

// parse_for_each_expr accepts all four path forms:
// 1. "<stage>.outputs[0].<field>"
// 2. "<stage>.outputs[].<field>"
// 3. "stage.<stage>.output.<field>"
// 4. "<stage>.output.<field>"
parse_for_each_expr :: proc(expr: string) -> (stage_key: string, field_path: string, ok: bool) {
	s := strings.trim_space(expr)
	if s == "" do return "", "", false
	if strings.has_prefix(s, "stage.") {
		rest := s[len("stage."):]
		dot := strings.index_byte(rest, '.')
		if dot <= 0 do return "", "", false
		stage_key = rest[:dot]
		after := rest[dot + 1:]
		if strings.has_prefix(after, "output.") {
			return stage_key, after[len("output."):], true
		}
		if strings.has_prefix(after, "outputs[0].") {
			return stage_key, after[len("outputs[0]."):], true
		}
		if strings.has_prefix(after, "outputs[].") {
			return stage_key, after[len("outputs[]."):], true
		}
		return "", "", false
	}
	dot := strings.index_byte(s, '.')
	if dot <= 0 do return "", "", false
	stage_key = s[:dot]
	after := s[dot + 1:]
	if strings.has_prefix(after, "outputs[0].") {
		return stage_key, after[len("outputs[0]."):], true
	}
	if strings.has_prefix(after, "outputs[].") {
		return stage_key, after[len("outputs[]."):], true
	}
	if strings.has_prefix(after, "output.") {
		return stage_key, after[len("output."):], true
	}
	return "", "", false
}

@(private = "file")
validate_stage_placeholders :: proc(st: Workflow_Stage_Spec, ancestors: map[string]bool, stage_by_key: map[string]Workflow_Stage_Spec) -> Error {
	// Scan raw_json for {{...}} placeholders
	s := st.raw_json
	pos := 0
	for pos < len(s) {
		open_idx := strings.index(s[pos:], "{{")
		if open_idx < 0 do break
		start := pos + open_idx + 2
		close_idx := strings.index(s[start:], "}}")
		if close_idx < 0 do break
		token := strings.trim_space(s[start : start + close_idx])
		pos = start + close_idx + 2

		if token == "item" || strings.has_prefix(token, "item.") {
			if st.for_each == "" {
				return language_error(.Validation_Failed, fmt.tprintf("stage %s uses {{%s}} without for_each", st.key, token), `{"code":"workflow_invalid"}`)
			}
		} else if strings.has_prefix(token, "stage.") && token != "stage.key" && token != "stage.index" && token != "stage.count" {
			rest := token[len("stage."):]
			dot := strings.index_byte(rest, '.')
			if dot > 0 {
				ref_stage := rest[:dot]
				if _, exists := stage_by_key[ref_stage]; !exists {
					return language_error(.Validation_Failed, fmt.tprintf("stage %s references unknown stage %s in {{%s}}", st.key, ref_stage, token), `{"code":"workflow_invalid"}`)
				}
				if !ancestors[ref_stage] {
					return language_error(.Validation_Failed, fmt.tprintf("stage %s references non-ancestor stage %s in {{%s}}", st.key, ref_stage, token), `{"code":"workflow_invalid"}`)
				}
			}
		}
	}
	return Error{}
}

@(private = "file")
parse_workflow_inputs_spec :: proc(raw_spec: string, allocator := context.temp_allocator) -> []Workflow_Input_Spec {
	out := make([dynamic]Workflow_Input_Spec, allocator)
	if arr, has_arr := jsonx.extract_raw_array(raw_spec, "inputs", true, allocator); has_arr {
		if objs, ok := split_json_array_objects(arr, allocator); ok {
			for obj in objs {
				iname := strings.trim_space(jsonx.extract_string(obj, "name", "", true, allocator))
				if iname == "" do iname = strings.trim_space(jsonx.extract_string(obj, "key", "", true, allocator))
				if iname == "" do continue
				itype := strings.trim_space(jsonx.extract_string(obj, "type", "string", true, allocator))
				req := jsonx.extract_bool(obj, "required", true, true)
				def_val, has_def := jsonx.extract_string_found(obj, "default", true, allocator)
				def_raw, has_def_raw := workflow_input_raw_member(jsonx_top_level_members(obj), "default")
				_, type_declared := jsonx_top_level_members(obj)["type"]
				desc := strings.trim_space(jsonx.extract_string(obj, "description", "", true, allocator))
				append(&out, Workflow_Input_Spec{
					name          = iname,
					type_name     = itype,
					required      = req,
					default_val   = def_val,
					has_default   = has_def || has_def_raw,
					default_raw   = def_raw,
					type_declared = type_declared,
					description   = desc,
				})
			}
		}
		return out[:]
	}
	if obj, has_obj := jsonx.extract_raw_object(raw_spec, "inputs", true, allocator); has_obj {
		for k, v in jsonx_top_level_members(obj) {
			trimmed_v := strings.trim_space(v)
			if strings.has_prefix(trimmed_v, "{") {
				itype := strings.trim_space(jsonx.extract_string(trimmed_v, "type", "string", true, allocator))
				req := jsonx.extract_bool(trimmed_v, "required", true, true)
				def_val, has_def := jsonx.extract_string_found(trimmed_v, "default", true, allocator)
				def_raw, has_def_raw := workflow_input_raw_member(jsonx_top_level_members(trimmed_v), "default")
				_, type_declared := jsonx_top_level_members(trimmed_v)["type"]
				desc := strings.trim_space(jsonx.extract_string(trimmed_v, "description", "", true, allocator))
				append(&out, Workflow_Input_Spec{
					name          = k,
					type_name     = itype,
					required      = req,
					default_val   = def_val,
					has_default   = has_def || has_def_raw,
					default_raw   = def_raw,
					type_declared = type_declared,
					description   = desc,
				})
			} else {
				// Shorthand: {"goal": "string"}
				tstr := strings.trim(trimmed_v, "\"")
				req := !strings.has_suffix(tstr, "?")
				append(&out, Workflow_Input_Spec{
					name          = k,
					type_name     = strings.trim_suffix(tstr, "?"),
					required      = req,
					type_declared = true,
				})
			}
		}
	}
	return out[:]
}

// ---- Output Contracts (`task_list.v1`, `findings.v1`, `inline`) ----------------------

brief_output_schema :: proc(brief_json: string, allocator := context.temp_allocator) -> (schema: string, required_fields: []string, has_output: bool) {
	if obj, ok := jsonx.extract_raw_object(brief_json, "output", true, allocator); ok && strings.trim_space(obj) != "" {
		s := strings.trim_space(jsonx.extract_string(obj, "schema", "", true, allocator))
		if s == "" do s = strings.trim_space(jsonx.extract_string(obj, "kind", "inline", true, allocator))
		req := jsonx.extract_string_array(obj, "required_fields", true, allocator)
		if len(req) == 0 do req = jsonx.extract_string_array(obj, "required", true, allocator)
		return s, req[:], true
	}
	if str := strings.trim_space(jsonx.extract_string(brief_json, "output", "", true, allocator)); str != "" {
		return str, nil, true
	}
	return "", nil, false
}

brief_has_output_contract :: proc(brief_json: string) -> bool {
	_, _, has := brief_output_schema(brief_json)
	return has
}

validate_task_output_contract :: proc(brief_json: string, output_json: string) -> Error {
	schema, req_fields, has_output := brief_output_schema(brief_json)
	if !has_output do return Error{}
	trimmed := strings.trim_space(output_json)
	if !strings.has_prefix(trimmed, "{") || !strings.has_suffix(trimmed, "}") {
		return language_error(.Validation_Failed, "this brief declares an output contract; submit must carry `output`", `{"code":"output_contract_invalid"}`)
	}
	switch schema {
	case "task_list.v1":
		return validate_task_list_v1_json(trimmed)
	case "findings.v1":
		return validate_findings_v1_json(trimmed)
	case:
		for rf in req_fields {
			members := jsonx_top_level_members(trimmed)
			val, exists := members[rf]
			if !exists || strings.trim_space(val) == "" || strings.trim_space(val) == "null" || strings.trim_space(val) == `""` {
				return language_error(.Validation_Failed, fmt.tprintf("output is missing required field: %s", rf), `{"code":"output_contract_invalid"}`)
			}
		}
	}
	return Error{}
}

validate_task_list_v1_json :: proc(output_json: string) -> Error {
	arr_raw, has_tasks := jsonx.extract_raw_array(output_json, "tasks", true, context.temp_allocator)
	if !has_tasks {
		arr_raw, has_tasks = jsonx.extract_raw_array(output_json, "items", true, context.temp_allocator)
	}
	if !has_tasks {
		return language_error(.Validation_Failed, "task_list.v1 output requires a `tasks` or `items` array", `{"code":"output_contract_invalid"}`)
	}
	objs, ok := split_json_array_objects(arr_raw, context.temp_allocator)
	if !ok {
		return language_error(.Validation_Failed, "task_list.v1 `tasks` must be a JSON array of objects", `{"code":"output_contract_invalid"}`)
	}
	seen_keys := make(map[string]bool, len(objs), context.temp_allocator)
	for obj, idx in objs {
		key := strings.trim_space(jsonx.extract_string(obj, "key", "", true, context.temp_allocator))
		if key == "" do key = strings.trim_space(jsonx.extract_string(obj, "id", "", true, context.temp_allocator))
		if key != "" {
			if seen_keys[key] {
				return language_error(.Validation_Failed, fmt.tprintf("task_list.v1 has duplicate item key: %s", key), `{"code":"output_contract_invalid"}`)
			}
			seen_keys[key] = true
		}
		goal := strings.trim_space(jsonx.extract_string(obj, "goal", "", true, context.temp_allocator))
		if goal == "" {
			if bobj, bok := jsonx.extract_raw_object(obj, "brief", true, context.temp_allocator); bok {
				goal = strings.trim_space(jsonx.extract_string(bobj, "goal", "", true, context.temp_allocator))
			}
		}
		if goal == "" {
			return language_error(.Validation_Failed, fmt.tprintf("task_list.v1 item[%d] is missing non-empty `goal`", idx), `{"code":"output_contract_invalid"}`)
		}

	}
	return Error{}
}

validate_findings_v1_json :: proc(output_json: string) -> Error {
	arr_raw, has_arr := jsonx.extract_raw_array(output_json, "findings", true, context.temp_allocator)
	if !has_arr {
		arr_raw, has_arr = jsonx.extract_raw_array(output_json, "items", true, context.temp_allocator)
	}
	if !has_arr {
		return language_error(.Validation_Failed, "findings.v1 output requires a `findings` or `items` array", `{"code":"output_contract_invalid"}`)
	}
	objs, ok := split_json_array_objects(arr_raw, context.temp_allocator)
	if !ok {
		return language_error(.Validation_Failed, "findings.v1 `findings` must be a JSON array of objects", `{"code":"output_contract_invalid"}`)
	}
	for obj, idx in objs {
		sev := strings.trim_space(jsonx.extract_string(obj, "severity", "", true, context.temp_allocator))
		valid_sev := false
		switch sev {
		case "critical", "high", "medium", "low", "info", "blocker", "major", "minor", "warn", "nit":
			valid_sev = true
		}
		if !valid_sev {
			return language_error(.Validation_Failed, fmt.tprintf("findings.v1 item[%d] has invalid severity: %s", idx, sev), `{"code":"output_contract_invalid"}`)
		}
		summary := strings.trim_space(jsonx.extract_string(obj, "summary", "", true, context.temp_allocator))
		if summary == "" do summary = strings.trim_space(jsonx.extract_string(obj, "text", "", true, context.temp_allocator))
		if summary == "" do summary = strings.trim_space(jsonx.extract_string(obj, "message", "", true, context.temp_allocator))
		if summary == "" {
			return language_error(.Validation_Failed, fmt.tprintf("findings.v1 item[%d] requires non-empty summary", idx), `{"code":"output_contract_invalid"}`)
		}
	}
	return Error{}
}


extract_for_each_array_items :: proc(output_json: string, field_path: string, allocator := context.temp_allocator) -> []string {
	arr_raw, ok := jsonx.extract_raw_array(output_json, field_path, true, allocator)
	if !ok {
		if field_path == "tasks" {
			arr_raw, ok = jsonx.extract_raw_array(output_json, "items", true, allocator)
		} else if field_path == "items" {
			arr_raw, ok = jsonx.extract_raw_array(output_json, "tasks", true, allocator)
			if !ok {
				arr_raw, ok = jsonx.extract_raw_array(output_json, "findings", true, allocator)
			}
		} else if field_path == "findings" {
			arr_raw, ok = jsonx.extract_raw_array(output_json, "items", true, allocator)
		}
	}
	if !ok || strings.trim_space(arr_raw) == "" do return nil
	if objs, ok_objs := split_json_array_objects(arr_raw, allocator); ok_objs {
		return objs
	}
	return jsonx_top_level_array_items(arr_raw)
}

// substitute_workflow_placeholders replaces:
// - {{inputs.<k>}} and {{workflow.input.<k>}}
// - {{stage.key}}, {{stage.index}}, {{stage.count}}
// - {{stage.<k>.output.<field>}} and {{stage.<k>.output.items.length}}
// - {{item.<field>}} and {{item}}
substitute_workflow_placeholders :: proc(
	template: string,
	snap: Workflow_Run_Snapshot,
	stage_key: string,
	stage_index: int,
	stage_count: int,
	item_json: string,
	stage_views: map[string]Stage_View,
	escape_for_json: bool,
	allocator := context.temp_allocator,
    preserve_output := false,
) -> string {
	if !strings.contains(template, "{{") do return template
	b := strings.builder_make(allocator)
	s := template
	pos := 0
	for pos < len(s) {
		open_idx := strings.index(s[pos:], "{{")
		if open_idx < 0 {
			strings.write_string(&b, s[pos:])
			break
		}
		strings.write_string(&b, s[pos : pos + open_idx])
		start := pos + open_idx + 2
		close_idx := strings.index(s[start:], "}}")
		if close_idx < 0 {
			strings.write_string(&b, s[pos + open_idx:])
			break
		}
		token := strings.trim_space(s[start : start + close_idx])
		pos = start + close_idx + 2

		val := resolve_placeholder_token(token, snap, stage_key, stage_index, stage_count, item_json, stage_views, allocator)
        if preserve_output && (token=="output" || strings.has_prefix(token,"output.")) do val=strings.concatenate({"{{",token,"}}"},allocator)
		if escape_for_json {
			contracts.write_json_string(&b, val)
		} else {
			strings.write_string(&b, val)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
resolve_placeholder_token :: proc(
	token: string,
	snap: Workflow_Run_Snapshot,
	stage_key: string,
	stage_index: int,
	stage_count: int,
	item_json: string,
	stage_views: map[string]Stage_View,
	allocator := context.temp_allocator,
) -> string {
	if token == "stage.key" do return stage_key
	if token == "stage.index" do return fmt.tprintf("%d", stage_index)
	if token == "stage.count" do return fmt.tprintf("%d", stage_count)
	if token == "item" {
		t := strings.trim_space(item_json)
		if strings.has_prefix(t, `"`) {
			// A string item renders as its decoded text, not escaped JSON.
			if value, perr := json.parse(transmute([]u8)t, parse_integers = true, allocator = allocator); perr == nil {
				if s, is_str := value.(json.String); is_str do return string(s)
			}
		}
		return t
	}
	if strings.has_prefix(token, "item.") {
		field := token[len("item."):]
		// Scalar items have no fields; only {{item.key}} keeps its index fallback.
		if !strings.has_prefix(strings.trim_space(item_json), "{") {
			return fmt.tprintf("item_%d", stage_index) if field == "key" else ""
		}
		if v, ok := extract_scalar_or_raw_string(item_json, field, allocator); ok && v != "" do return v
		// Fallbacks between title/goal/summary/key
		if field == "title" {
			if v, ok := extract_scalar_or_raw_string(item_json, "goal", allocator); ok && v != "" do return v
			if v, ok := extract_scalar_or_raw_string(item_json, "summary", allocator); ok && v != "" do return v
			if v, ok := extract_scalar_or_raw_string(item_json, "key", allocator); ok && v != "" do return v
		} else if field == "key" {
			if v, ok := extract_scalar_or_raw_string(item_json, "id", allocator); ok && v != "" do return v
			return fmt.tprintf("item_%d", stage_index)
		}
		return ""
	}
	if strings.has_prefix(token, "inputs.") {
		k := token[len("inputs."):]
		return resolve_workflow_input_value(snap, k, allocator)
	}
	if strings.has_prefix(token, "workflow.input.") {
		k := token[len("workflow.input."):]
		return resolve_workflow_input_value(snap, k, allocator)
	}
	if strings.has_prefix(token, "stage.") {
		rest := token[len("stage."):]
		dot := strings.index_byte(rest, '.')
		if dot > 0 {
			up_key := rest[:dot]
			after := rest[dot + 1:]
			sv, exists := stage_views[up_key]
			if !exists || len(sv.outputs) == 0 do return ""
			out0 := sv.outputs[0]
			field := ""
			if strings.has_prefix(after, "output.") {
				field = after[len("output."):]
			} else if strings.has_prefix(after, "outputs[0].") {
				field = after[len("outputs[0]."):]
			}
			if field == "items.length" || field == "tasks.length" || field == "findings.length" {
				arr := extract_for_each_array_items(out0, strings.split(field, ".", allocator)[0], allocator)
				return fmt.tprintf("%d", len(arr))
			}
			if field != "" {
				if v, ok := extract_scalar_or_raw_string(out0, field, allocator); ok do return v
			}
		}
	}
	return ""
}

@(private = "file")
resolve_workflow_input_value :: proc(snap: Workflow_Run_Snapshot, key: string, allocator := context.temp_allocator) -> string {
	// A supplied null falls back to the declared default, as fan-out does.
	supplied, found := scalar_or_raw_member(snap.inputs_members, key, allocator)
	if found && supplied != "null" do return supplied
	for inp in snap.spec.inputs {
		if inp.name != key || !inp.has_default do continue
		// Non-string defaults (arrays, objects, numbers) render as raw JSON.
		raw := strings.trim_space(inp.default_raw)
		if raw != "" && raw != "null" && !strings.has_prefix(raw, `"`) do return raw
		return inp.default_val
	}
	return supplied
}

@(private = "package")
extract_scalar_or_raw_string :: proc(obj_json: string, key: string, allocator := context.temp_allocator) -> (string, bool) {
	return scalar_or_raw_member(jsonx_top_level_members(obj_json), key, allocator)
}

// scalar_or_raw_member renders one top-level member the way placeholders want
// it: strings decoded, numbers and booleans as their text, objects/arrays (and
// null) as raw trimmed JSON. Only the member's own text is parsed, never the
// whole object, so a lookup costs O(member) instead of O(object).
@(private = "package")
scalar_or_raw_member :: proc(members: map[string]string, key: string, allocator := context.temp_allocator) -> (string, bool) {
	raw, ok := members[key]
	if !ok do return "", false
	raw = strings.trim_space(raw)
	if raw == "" || raw[0] == '{' || raw[0] == '[' do return raw, true
	// Scalars are small: parse just this value with the same decoder the
	// whole-object path used, so formatting (e.g. floats as %f) is unchanged.
	value, err := json.parse(transmute([]u8)raw, parse_integers = true, allocator = allocator)
	if err != nil do return raw, true
	#partial switch v in value {
	case json.String:  return string(v), true
	case json.Integer: return fmt.tprintf("%d", v), true
	case json.Float:   return fmt.tprintf("%f", v), true
	case json.Boolean: return "true" if v else "false", true
	}
	return raw, true
}


jsonx_top_level_members :: proc(obj: string) -> map[string]string {
	out := make(map[string]string, context.temp_allocator)
	s := strings.trim_space(obj)
	if len(s) < 2 do return out
	i := 1
	n := len(s) - 1
	for i < n {
		for i < n && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r' || s[i] == ',') do i += 1
		if i >= n || s[i] != '"' do break
		kstart := i + 1
		kend := kstart
		for kend < n && s[kend] != '"' { if s[kend] == '\\' do kend += 1; kend += 1 }
		key := s[kstart:kend]
		i = kend + 1
		for i < n && s[i] != ':' do i += 1
		i += 1
		for i < n && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r') do i += 1
		vstart := i
		vend := json_value_end(s, vstart, n)
		out[key] = s[vstart:vend]
		i = vend
	}
	return out
}

jsonx_top_level_array_items :: proc(arr: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	s := strings.trim_space(arr)
	if len(s) < 2 do return out[:]
	i := 1
	n := len(s) - 1
	for i < n {
		for i < n && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r' || s[i] == ',') do i += 1
		if i >= n do break
		vend := json_value_end(s, i, n)
		append(&out, s[i:vend])
		i = vend
	}
	return out[:]
}

json_value_end :: proc(s: string, start, limit: int) -> int {
	i := start
	if i >= limit do return limit
	switch s[i] {
	case '"':
		i += 1
		for i < limit && s[i] != '"' { if s[i] == '\\' do i += 1; i += 1 }
		return min(i + 1, limit)
	case '{', '[':
		depth := 0
		in_str := false
		for i < limit {
			c := s[i]
			if in_str {
				if c == '\\' { i += 2; continue }
				if c == '"' do in_str = false
			} else {
				switch c {
				case '"': in_str = true
				case '{', '[': depth += 1
				case '}', ']':
					depth -= 1
					if depth == 0 do return i + 1
				}
			}
			i += 1
		}
		return limit
	case:
		for i < limit && s[i] != ',' && s[i] != '}' && s[i] != ']' do i += 1
		return i
	}
}
split_json_array_objects :: proc(raw_array: string, allocator := context.temp_allocator) -> ([]string, bool) {
	s := strings.trim_space(raw_array)
	if len(s) < 2 || s[0] != '[' || s[len(s) - 1] != ']' do return nil, false
	out := make([dynamic]string, allocator)
	i := 1
	n := len(s) - 1
	for i < n {
		for i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == ',') do i += 1
		if i >= n do break
		if s[i] != '{' do return nil, false
		start := i
		depth := 0
		in_str := false
		esc := false
		for i < n {
			ch := s[i]
			if in_str {
				if esc {
					esc = false
				} else if ch == '\\' {
					esc = true
				} else if ch == '"' {
					in_str = false
				}
			} else {
				switch ch {
				case '"': in_str = true
				case '{': depth += 1
				case '}':
					depth -= 1
					if depth == 0 {
						append(&out, s[start:i + 1])
						i += 1
						break
					}
				}
			}
			if depth == 0 do break
			i += 1
		}
		if depth != 0 do return nil, false
	}
	return out[:], true
}
Json_Object :: struct {
	b:     strings.Builder,
	count: int,
}

// Payloads are consumed within the call that builds them (appended to the
// event row, spliced into a wake), so the builder is temp-allocated by default
// (review S9); pass an allocator to keep one longer.
json_begin :: proc(allocator := context.temp_allocator) -> Json_Object {
	o := Json_Object{b = strings.builder_make(allocator)}
	strings.write_byte(&o.b, '{')
	return o
}

@(private = "file")
json_key :: proc(o: ^Json_Object, key: string) {
	if o.count > 0 do strings.write_byte(&o.b, ',')
	o.count += 1
	strings.write_byte(&o.b, '"')
	contracts.write_json_string(&o.b, key)
	strings.write_string(&o.b, "\":")
}

json_str :: proc(o: ^Json_Object, key, value: string) {
	json_key(o, key)
	strings.write_byte(&o.b, '"')
	contracts.write_json_string(&o.b, value)
	strings.write_byte(&o.b, '"')
}

// json_raw splices an already-valid JSON value verbatim.
json_raw :: proc(o: ^Json_Object, key, raw: string) {
	json_key(o, key)
	strings.write_string(&o.b, raw if strings.trim_space(raw) != "" else "null")
}

json_end :: proc(o: ^Json_Object) -> string {
	strings.write_byte(&o.b, '}')
	return strings.to_string(o.b)
}

substitute_on_output_placeholders :: proc(template: string, output_json: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(template, "{{") do return template
	b := strings.builder_make(allocator)
	s := template
	pos := 0
	for pos < len(s) {
		open_idx := strings.index(s[pos:], "{{")
		if open_idx < 0 {
			strings.write_string(&b, s[pos:])
			break
		}
		strings.write_string(&b, s[pos : pos + open_idx])
		start := pos + open_idx + 2
		close_idx := strings.index(s[start:], "}}")
		if close_idx < 0 {
			strings.write_string(&b, s[pos + open_idx:])
			break
		}
		token := strings.trim_space(s[start : start + close_idx])
		pos = start + close_idx + 2
		val := ""
		if token == "output" {
			val = output_json
		} else if strings.has_prefix(token, "output.") {
			field := token[len("output."):]
			if v, ok := extract_scalar_or_raw_string(output_json, field, allocator); ok do val = v
		}
		strings.write_string(&b, val)
	}
	return strings.to_string(b)
}
