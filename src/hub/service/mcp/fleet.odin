package mcp

import "core:encoding/json"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import vd "odin_test:hub/service/vault_directory"

Fleet_Arguments :: struct {bridge_id,application_id:string,draft:contracts.Fleet_Apply_Input}
Fleet_Proc :: proc(ctx:rawptr,raw:string,view:Access_View,tool:string,args:Fleet_Arguments,cancel_ctx:rawptr,cancel:proc(ctx:rawptr)->bool)->(string,string)
fleet_tool :: proc(tool:string)->bool {return tool=="fleet.read" || tool=="fleet.apply" || tool=="fleet.status" || tool=="fleet.retry"}

// Public signed-grant bindings, never an OAuth credential or private capability.
// Token expiry authorizes the request; durable new acceptance checks the grant.
fleet_binding :: proc(view:Access_View)->string {
	v:=view;v.expires_ms=0;v.version=0
	encoded,_:=json.marshal(v,allocator=context.temp_allocator)
	return string(encoded)
}
fleet_binding_live :: proc(tx:iface.MCP_Transaction,s:^Delegation_Service,directory:^vd.Service,owner,binding:string)->bool {
	v:Access_View
	if json.unmarshal_string(binding,&v,.JSON,context.temp_allocator)!=nil || v.owner!=owner || !scope_allows_tool(v.scope,"fleet.apply") do return false
	g,found,err:=tx.get(tx.ctx,"grant",v.grant)
	if !found || err.code!=.None || g.revoked || g.owner!=owner || g.client!=v.client || g.family!=v.family || g.revision!=v.revision || g.mode!=v.mode || g.scope!=v.scope || g.vault_id!=v.vault_id || g.consent!=v.consent || g.signature!=v.signature do return false
	if live,le:=delegation_live(s,tx,grant_claim_bindings(g));!live || le.code!=.None do return false
	dir,valid,de:=verified_grant_directory(directory,g)
	return valid && de.code==.None && dir.head_hash==v.head && dir.current_epoch==v.epoch
}
