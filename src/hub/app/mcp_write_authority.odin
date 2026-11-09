package app

import sqlite "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"
import mcp "odin_test:hub/service/mcp"
import vd "odin_test:hub/service/vault_directory"

// Write-time MCP authority shared by the catalog, resource and runtime write
// tools: the grant's owner must be an active user and the grant must still be
// authorized by the current vault directory, read on the Hub connection.
MCP_Task_Authority :: struct {conn:^sqlite.Conn,directory:^vd.Service}
mcp_task_authority :: proc(ctx:rawptr,grant:domain.MCP_Record)->(bool,domain.Domain_Error) {
	op:=(^MCP_Task_Authority)(ctx)
	impl:sqlite.User_Repo_SQLite
	repo:=sqlite.new_user_repository(&impl,op.conn)
	user,found,err:=iface.user_get_by_id(&repo,domain.User_ID(grant.owner))
	if err.code!=.None do return false,err
	if !found || user.status!=.Active do return false,{}
	return mcp.delegation_vault_authority(op.directory,grant)
}

mcp_task_write_check :: proc(g:^App_Graph,raw:string,view:mcp.Access_View,tool:string)->string {
	impl:sqlite.Vault_Directory_Repo_SQLite
	repo:=sqlite.new_vault_directory_repository(&impl,&g.db)
	directory:=vd.Service{repo=&repo,clock=&g.clock}
	authority:=MCP_Task_Authority{conn=&g.db,directory=&directory}
	service:=g.mcp_delegation
	service.authority_ctx=&authority;service.authority=mcp_task_authority
	return mcp.control_write_authorized(sqlite.mcp_transaction_view(&g.db),&service,&directory,raw,view,tool)
}

mcp_task_error :: proc(err:domain.Domain_Error)->string {
	#partial switch err.code {
	case .None:return ""
	case .Not_Found,.Forbidden:return "not_found"
	case .Conflict:return "conflict"
	case .Bridge_Offline:return "bridge_offline"
	case .Provider_Unavailable:return "provider_unavailable"
	case .Validation_Failed,.Unprocessable_Entity:return "invalid_arguments"
	case:return "request_failed"
	}
}

// Chains are Bridge-owned: a chain binding is the owner's when its owner
// registry route (native or imported) or its legacy read-only Hub record is.
mcp_chain_owned :: proc(g:^App_Graph,owner,chain:string)->bool {
	repo:=&g.repos.taskchains
	if repo.owner_registry_routes!=nil {
		saved:=context.allocator;context.allocator=context.temp_allocator;defer context.allocator=saved
		if routes,err:=repo.owner_registry_routes(repo.ctx,owner,chain);err.code==.None && len(routes)==1 do return true
	}
	if repo.get_chain==nil do return false
	row,found,e:=iface.taskchain_get_chain(repo,domain.Task_Chain_ID(chain))
	return found && e.code==.None && string(row.owner_user_id)==owner
}
