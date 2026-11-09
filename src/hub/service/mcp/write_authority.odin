package mcp

import iface "odin_test:hub/repository/iface"
import vd "odin_test:hub/service/vault_directory"

// Used only INSIDE a native write transaction, with authority and directory
// readers on that same connection. Replays also require a live original grant.
control_write_authorized :: proc(tx:iface.MCP_Transaction,s:^Delegation_Service,directory:^vd.Service,raw:string,expected:Access_View,tool:string)->string {
	c,opened:=credential_open(s.keys,raw,"access")
	defer credential_claims_wipe(&c)
	if !opened do return "invalid_token"
	op:=Access_Check{service=s,directory=directory,raw=raw,claims=c}
	if err:=access_transaction(tx,&op);err.code!=.None do return "request_failed"
	if !op.ok do return "invalid_token"
	if !access_same(expected,op.view) do return "decryption_unavailable"
	if !scope_allows_tool(op.view.scope,tool) do return "scope_missing"
	return ""
}
