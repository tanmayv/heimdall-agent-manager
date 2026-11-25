package app

import "core:encoding/json"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import mcp "odin_test:hub/service/mcp"
import fleet "odin_test:hub/service/fleet_application"
import vd "odin_test:hub/service/vault_directory"

MCP_Fleet_Request :: struct {g:^App_Graph,raw:string,view:mcp.Access_View,tool:string,cancel_ctx:rawptr,cancel:proc(ctx:rawptr)->bool}
mcp_fleet_request_check :: proc(ctx:rawptr)->domain.Domain_Error {
	p:=(^MCP_Fleet_Request)(ctx)
	if p.cancel!=nil && p.cancel(p.cancel_ctx) do return domain.domain_error(.Forbidden,"Fleet request cancelled")
	u,ok,err:=iface.unit_of_work_begin(&p.g.uow_factory)
	if !ok do return err
	defer iface.unit_of_work_rollback(&u)
	if code:=mcp_task_write_check(p.g,p.raw,p.view,p.tool);code!="" do return domain.domain_error(.Forbidden,code)
	return {}
}
fleet_authority_check :: proc(ctx:rawptr,owner:domain.User_ID,binding:string)->domain.Domain_Error {
	g:=(^App_Graph)(ctx)
	u,ok,err:=iface.unit_of_work_begin(&g.uow_factory)
	if !ok do return err
	defer iface.unit_of_work_rollback(&u)
	impl:sqlite.Vault_Directory_Repo_SQLite
	repo:=sqlite.new_vault_directory_repository(&impl,&g.db)
	directory:=vd.Service{repo=&repo,clock=&g.clock}
	authority:=MCP_Task_Authority{conn=&g.db,directory=&directory}
	s:=g.mcp_delegation;s.authority_ctx=&authority;s.authority=mcp_task_authority
	if !mcp.fleet_binding_live(sqlite.mcp_transaction_view(&g.db),&s,&directory,string(owner),binding) do return domain.domain_error(.Forbidden,"delegated Fleet grant was revoked or changed")
	return {}
}
mcp_fleet_call :: proc(ctx:rawptr,raw:string,view:mcp.Access_View,tool:string,a:mcp.Fleet_Arguments,cancel_ctx:rawptr,cancel:proc(ctx:rawptr)->bool)->(string,string) {
	g:=(^App_Graph)(ctx)
	guard:=MCP_Fleet_Request{g,raw,view,tool,cancel_ctx,cancel}
	if err:=mcp_fleet_request_check(&guard);err.code!=.None do return "",err.message
	principal:=mcp.control_auth(view.owner)
	if tool=="fleet.read" {
		snapshot,err:=fleet.read_settings(&g.fleet,principal,a.bridge_id)
		if err.code!=.None do return "",mcp_task_error(err)
		defer domain.fleet_settings_destroy(snapshot)
		data,_:=json.marshal(snapshot,allocator=context.temp_allocator)
		return string(data),""
	}
	r:domain.Fleet_Application_Record;found:bool;err:domain.Domain_Error
	authorization:=fleet.Authorization{binding=mcp.fleet_binding(view),ctx=&guard,check=mcp_fleet_request_check}
	switch tool {
	case "fleet.apply":r,found,err=fleet.apply(&g.fleet,principal,a.bridge_id,a.draft,authorization)
	case "fleet.retry":r,found,err=fleet.retry_application(&g.fleet,principal,a.bridge_id,a.application_id,authorization)
	case "fleet.status":r,found,err=fleet.read_application(&g.fleet,principal,a.bridge_id,a.application_id)
	}
	if !found do return "",mcp_task_error(err)
	defer domain.fleet_application_record_destroy(&r)
	data,_:=json.marshal(r.application,allocator=context.temp_allocator)
	return string(data),""
}
