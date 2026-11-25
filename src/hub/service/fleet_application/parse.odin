package fleet_application

import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"

parse_preview :: proc(value: json.Value) -> (domain.Fleet_Settings_Draft, bool) {
	o, object := value.(json.Object)
	if !object || len(o) != 3 do return {}, false
	// Reuse the strict full-draft parser; this literal is never persisted or used
	// to allocate an application. Unknown fields still fail closed.
	copy := make(json.Object, context.temp_allocator)
	for key, v in o do copy[key] = v
	copy["request_id"] = json.String("preview")
	input, valid := parse_apply(copy)
	return {input.expected_revision, input.default_runtime, input.overrides}, valid
}

// HTTP, MCP and the CLI's REST transport share one strict draft contract.
parse_apply :: proc(value: json.Value) -> (domain.Fleet_Apply_Input, bool) {
	o, object := value.(json.Object)
	if !object || len(o) != 4 do return {}, false
	for key in ([]string{"request_id", "expected_revision", "default_runtime", "overrides"}) do if _, present := o[key]; !present do return {}, false
	request, typed := o["request_id"].(json.String)
	if !typed || strings.trim_space(string(request)) == "" || len(request) > 128 do return {}, false
	revision, integer := o["expected_revision"].(json.Integer)
	if !integer || revision < 0 do return {}, false
	if !runtime_object(o["default_runtime"]) do return {}, false
	overrides, array := o["overrides"].(json.Array)
	if !array do return {}, false
	for v in overrides {
		entry, obj := v.(json.Object)
		if !obj || len(entry) != 2 || !runtime_object(entry["runtime"]) do return {}, false
		id, valid := entry["agent_id"].(json.String)
		if !valid || strings.trim_space(string(id)) == "" do return {}, false
	}
	data, _ := json.marshal(value, allocator=context.temp_allocator)
	input: domain.Fleet_Apply_Input
	if json.unmarshal(data, &input, .JSON, context.temp_allocator) != nil do return {}, false
	return input, true
}

runtime_object :: proc(value: json.Value) -> bool {
	o, obj := value.(json.Object)
	if !obj || len(o) < 2 || len(o) > 3 do return false
	for key, v in o {
		if key != "provider" && key != "provider_profile" && key != "model" do return false
		if _, typed := v.(json.String); !typed do return false
	}
	for key in ([]string{"provider", "model"}) {
		v, typed := o[key].(json.String)
		if !typed || strings.trim_space(string(v)) == "" do return false
	}
	return true
}
