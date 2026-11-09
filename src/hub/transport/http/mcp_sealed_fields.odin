package http

import "core:encoding/json"
import mcp "odin_test:hub/service/mcp"
import vault "odin_test:lib/vault"

// Every sealed field of a device-transformed write is an envelope under the
// connection's current vault epoch (catalog and resource writes).
mcp_task_sealed_fields :: proc(view:mcp.Access_View,expected,actual:json.Object)->bool {
	if len(expected)!=len(actual) do return false
	for key,value in expected {
		if key=="acceptance" {
			items,typed:=actual[key].(json.Array);original,original_typed:=value.(json.Array)
			if !typed || !original_typed || len(items)!=len(original) do return false
			for item in items {s,ok:=item.(json.String);if !ok || !mcp_task_envelope_ok(view,string(s)) do return false}
		} else {
			s,typed:=actual[key].(json.String);if !typed || !mcp_task_envelope_ok(view,string(s)) do return false
		}
	}
	return true
}

mcp_task_envelope_ok :: proc(view:mcp.Access_View,token:string)->bool {
	vid,epoch,_,status:=vault.envelope_parse(token,context.temp_allocator)
	buf:[16]byte
	return status==.Ok && epoch==view.epoch && vault.vault_id_hex(vid,buf[:])==view.vault_id
}
