package http

import "core:encoding/json"
import "core:testing"
import fleet "odin_test:hub/service/fleet_application"
import mcp "odin_test:hub/service/mcp"

@(test)
test_fleet_http_mcp_draft_contract_and_scope :: proc(t: ^testing.T) {
	valid := `{"request_id":"same","expected_revision":0,"default_runtime":{"provider":"codex","model":"model"},"overrides":[]}`
	v, e := json.parse_string(valid, .JSON, parse_integers=true, allocator=context.temp_allocator)
	input, ok := fleet.parse_apply(v)
	testing.expect(t, e == nil && ok && input.request_id == "same")
	o := v.(json.Object)
	o["bridge_id"] = json.String("brg_example")
	a, accepted := mcp_fleet_arguments("fleet.apply", o)
	testing.expect(t, accepted && a.fleet.draft.request_id == input.request_id && a.fleet.draft.default_runtime.model == input.default_runtime.model)
	for raw in ([]string{
		`{"request_id":"same","expected_revision":0,"default_runtime":{"provider":"p","model":"m","permission_mode":"yolo"},"overrides":[]}`,
		`{"request_id":"same","expected_revision":0,"default_runtime":{"provider":"p","model":"m"},"overrides":[{"agent_id":"agt_a","runtime":{"provider":"p","model":"m"},"capacity":5}]}`,
		`{"request_id":"same","expected_revision":0,"default_runtime":{"provider":"p","model":"m"},"overrides":null}`,
		`{"request_id":"same","expected_revision":-1,"default_runtime":{"provider":"p","model":"m"},"overrides":[]}`,
		`{"request_id":"same","expected_revision":0,"default_runtime":{"provider":"p","model":"m"}}`,
	}) {
		value, _ := json.parse_string(raw, .JSON, parse_integers=true, allocator=context.temp_allocator)
		_, parsed := fleet.parse_apply(value)
		testing.expect(t, !parsed, raw)
		obj := value.(json.Object); obj["bridge_id"] = json.String("brg_example")
		_, parsed = mcp_fleet_arguments("fleet.apply", obj)
		testing.expect(t, !parsed, "MCP must reject the same invalid draft")
	}
	read := "mcp:chains mcp:instances:read"
	control := "mcp:chains mcp:instances:control"
	for tool in ([]string{"fleet.read", "fleet.status"}) {
		testing.expect(t, mcp.scope_allows_tool(read,tool) && !mcp.scope_allows_tool(control,tool))
	}
	for tool in ([]string{"fleet.apply", "fleet.retry"}) {
		testing.expect(t, mcp.scope_allows_tool(control,tool) && !mcp.scope_allows_tool(read,tool))
	}
}

@(test)
test_fleet_preview_strict_complete_draft_contract :: proc(t: ^testing.T) {
	for raw, index in ([]string{
		`{"expected_revision":0,"default_runtime":{"provider":"codex","model":"m"},"overrides":[]}`,
		`{"expected_revision":0,"default_runtime":{"provider":"codex","model":"m"},"overrides":[],"restart":true}`,
		`{"expected_revision":-1,"default_runtime":{"provider":"codex","model":"m"},"overrides":[]}`,
		`{"expected_revision":0,"default_runtime":{"provider":"codex","model":"m"},"overrides":null}`,
		`{"expected_revision":0,"default_runtime":{"provider":"codex","model":"m","extra":1},"overrides":[]}`,
		`{"expected_revision":0,"default_runtime":{"provider":"codex","model":"m"}}`,
	}) {
		value, e := json.parse_string(raw,.JSON,parse_integers=true,allocator=context.temp_allocator)
		_, ok := fleet.parse_preview(value)
		testing.expect(t,e==nil && ok==(index==0),raw)
	}
}
