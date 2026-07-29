package http

import "core:fmt"
import "core:strconv"
import "core:strings"
import internal_b64 "core:encoding/base64"

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import content_service "odin_test:hub/service/content"

Content_Handlers :: struct { auth: ^auth_service.Auth_Service, agents: ^agent_service.Agent_Service, content: ^content_service.Content_Service }

list_memories_handler :: proc(ctx:rawptr, req:Request)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp
	limit:=query_int(req.query,"limit",50)
	if limit<=0 do limit=50
	if limit>200 do limit=200
	cursor:=query_value(req.query,"cursor")
	status:=query_value(req.query,"status")
	type_str:=query_value(req.query,"type")
	agent_id:=query_value(req.query,"agent_id")
	project_id:=query_value(req.query,"project_id")
	bridge_id:=query_value(req.query,"bridge_id")
	filter:=content_service.Memory_Filter{status=status,type=type_str,agent_id=agent_id,project_id=domain.Project_ID(project_id),bridge_id=bridge_id}
	rows,err:=content_service.list_memories(h.content,auth,filter,limit,cursor)
	if err.code!=.None do return respond_error(err,req.request_id)
	defer delete(rows)
	b:=strings.builder_make(); strings.write_byte(&b,'[')
	next_cursor:=""
	for r,i in rows{ if i>0 do strings.write_byte(&b,','); write_memory_json(&b,r,true); next_cursor=r.updated_at }
	strings.write_byte(&b,']')
	has_more:=len(rows)>=limit
	return respond_list(strings.to_string(b),contracts.API_Page{limit=limit,next_cursor=next_cursor if has_more else "",has_more=has_more},req.request_id,auth_ctx_server_time(req))
}
create_memory_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; m,saved,err:=content_service.create_memory(h.content,auth,memory_input(req.body)); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_memory_json(&b,m,false); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201) }
memory_detail_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; m,got,err:=content_service.get_memory(h.content,auth,path_part(req.path,4)); if !got do return respond_error(err,req.request_id); b:=strings.builder_make(); write_memory_json(&b,m,false); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req)) }
patch_memory_handler :: proc(ctx:rawptr, req:Request)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp
	id:=path_part(req.path,4)
	input,_:=memory_update_input(req.body)
	m,updated,err:=content_service.update_memory(h.content,auth,id,input)
	if !updated do return respond_error(err,req.request_id)
	b:=strings.builder_make(); write_memory_json(&b,m,false)
	return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req))
}
memory_action_handler :: proc(ctx:rawptr, req:Request)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp
	id:=path_part(req.path,4)
	action:=path_part(req.path,5)
	m:domain.Memory; good:=false; err:domain.Domain_Error
	if action=="approve" {
		input,has_edits:=memory_update_input(req.body)
		m,good,err=content_service.approve_memory(h.content,auth,id,input,has_edits)
	} else if action=="reject" {
		m,good,err=content_service.reject_memory(h.content,auth,id)
	} else if action=="archive" {
		m,good,err=content_service.archive_memory(h.content,auth,id)
	} else {
		return respond_error(domain.domain_error(.Not_Found,"route not found"),req.request_id)
	}
	if !good do return respond_error(err,req.request_id)
	b:=strings.builder_make(); write_memory_json(&b,m,false)
	return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req))
}

list_chats_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; limit:=query_int(req.query,"limit",50); cursor:=query_value(req.query,"cursor"); rows,err:=content_service.list_conversations(h.content,auth,limit,cursor); if err.code!=.None do return respond_error(err,req.request_id); b:=strings.builder_make(); strings.write_byte(&b,'['); next:=""; for r,i in rows{ if i>0 do strings.write_byte(&b,','); write_chat_json_with_runtime(&b,r,h,auth); next=r.updated_at}; strings.write_byte(&b,']'); has_more:=len(rows)>=limit; return respond_list(strings.to_string(b),contracts.API_Page{limit=limit,next_cursor=next if has_more else "",has_more=has_more},req.request_id,auth_ctx_server_time(req)) }
create_chat_handler :: proc(ctx:rawptr, req:Request)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp
	input:=chat_input(req.body)
	if input.agent_instance_id=="" {
		if h.agents==nil do return respond_error(domain.domain_error(.Internal_Error,"agent service is not configured"),req.request_id)
		initial:=content_service.Message_Input{body=input.initial_body,artifact_ids_json=input.artifact_ids_json}
		if strings.trim_space(input.initial_body)!="" { if msg_ok,msg_err:=content_service.validate_initial_message(h.content,auth,initial); !msg_ok do return respond_error(msg_err,req.request_id) }
		inst,created,create_err:=agent_service.create_instance(h.agents,auth,agent_service.Create_Instance_Input{agent_id=input.agent_id,bridge_id=input.bridge_id,provider=input.provider,tier=input.tier,project_id=input.project_id,chain_id=input.chain_id})
		if !created do return respond_error(create_err,req.request_id)
		c,found,find_err:=content_service.get_conversation_by_instance(h.content,auth,inst.agent_instance_id)
		if !found do return respond_error(find_err,req.request_id)
		if strings.trim_space(input.initial_body)!="" { _,title_ok,title_err:=content_service.update_conversation_title(h.content,auth,c.conversation_id,chat_title_from_initial(input.initial_body)); if !title_ok do return respond_error(title_err,req.request_id); _,sent,send_err := content_service.send_message(h.content,auth,c.conversation_id,initial); if !sent do return respond_error(send_err,req.request_id); updated,updated_ok,updated_err:=content_service.get_conversation(h.content,auth,c.conversation_id); if !updated_ok do return respond_error(updated_err,req.request_id); c=updated }
		b:=strings.builder_make(); write_chat_json(&b,c); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201)
	}
	c,saved,err:=content_service.create_conversation(h.content,auth,input); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_chat_json(&b,c); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201)
}
chat_title_from_initial :: proc(body:string)->string{
	trimmed:=strings.trim_space(body); if len(trimmed)<=120 do return trimmed; return strings.trim_space(trimmed[:120])
}
patch_chat_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; c,saved,err:=content_service.update_conversation_title(h.content,auth,path_part(req.path,4),json_string(req.body,"title")); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_chat_json(&b,c); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req)) }
list_chat_messages_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; limit:=query_int(req.query,"limit",50); cursor:=query_value(req.query,"cursor"); rows,err:=content_service.list_user_visible_messages(h.content,auth,path_part(req.path,4),limit,cursor); if err.code!=.None do return respond_error(err,req.request_id); b:=strings.builder_make(); strings.write_byte(&b,'['); next:=""; for r,i in rows{ if i>0 do strings.write_byte(&b,','); write_message_json(&b,r,h.content); next=r.created_at}; strings.write_byte(&b,']'); has_more:=len(rows)>=limit; return respond_list(strings.to_string(b),contracts.API_Page{limit=limit,next_cursor=next if has_more else "",has_more=has_more},req.request_id,auth_ctx_server_time(req)) }
send_chat_message_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; cid:=path_part(req.path,4); if restarted,restart_err:=restart_stopped_conversation_instance(h,auth,cid); !restarted do return respond_error(restart_err,req.request_id); m,saved,err:=content_service.send_message(h.content,auth,cid,message_input(req.body)); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_message_json(&b,m,h.content); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201) }
read_chat_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; c,saved,err:=content_service.mark_read(h.content,auth,path_part(req.path,4)); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_chat_json(&b,c); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req)) }

list_artifacts_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; rows,err:=content_service.list_artifacts(h.content,auth); if err.code!=.None do return respond_error(err,req.request_id); b:=strings.builder_make(); strings.write_byte(&b,'['); for r,i in rows{ if i>0 do strings.write_byte(&b,','); write_artifact_json(&b,r,false)}; strings.write_byte(&b,']'); return respond_list(strings.to_string(b),contracts.API_Page{limit=contracts.API_DEFAULT_PAGE_LIMIT,has_more=false},req.request_id,auth_ctx_server_time(req)) }
create_artifact_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; a,saved,err:=content_service.create_artifact(h.content,auth,artifact_input_from_request(req)); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_artifact_json(&b,a,false); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201) }
artifact_detail_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; a,got,err:=content_service.get_artifact(h.content,auth,path_part(req.path,4)); if !got do return respond_error(err,req.request_id); b:=strings.builder_make(); write_artifact_json(&b,a,false); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req)) }
artifact_content_handler :: proc(ctx:rawptr, req:Request)->Response{
	return artifact_content_response(ctx, req, false)
}
artifact_download_handler :: proc(ctx:rawptr, req:Request)->Response{
	return artifact_content_response(ctx, req, true)
}
artifact_content_response :: proc(ctx:rawptr, req:Request, force_download:bool)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp;
	a,got,err:=content_service.get_artifact(h.content,auth,path_part(req.path,4)); if !got do return respond_error(err,req.request_id);
	ctype := artifact_response_content_type(a)
	disposition := "inline"
	if force_download || artifact_query_download(req.query) do disposition = "attachment"
	headers := make([dynamic]contracts.HTTP_Header, 0, 4)
	append(&headers, contracts.HTTP_Header{name = "Content-Disposition", value = artifact_content_disposition(disposition, a.name)})
	append(&headers, contracts.HTTP_Header{name = "Cache-Control", value = "private, max-age=60"})
	append(&headers, contracts.HTTP_Header{name = "X-Content-Type-Options", value = "nosniff"})
	return Response{
		status = 200,
		content_type = ctype,
		body = a.content,
		headers = headers[:],
	}
}
artifact_response_content_type :: proc(a:domain.Artifact)->string{
	ctype:=strings.trim_space(a.mime); if ctype=="" do ctype=strings.trim_space(a.content_type); if ctype=="" do ctype="application/octet-stream"; return ctype
}
artifact_query_download :: proc(query:string)->bool{
	v:=strings.to_lower(query_value(query,"download")); if v=="" do v=strings.to_lower(query_value(query,"dl"))
	disposition:=strings.to_lower(query_value(query,"disposition"))
	return v=="1" || v=="true" || v=="yes" || disposition=="attachment" || disposition=="download"
}
artifact_content_disposition :: proc(disposition,name:string)->string{
	safe:=artifact_header_filename(name); if safe=="" do safe="artifact"
	return fmt.tprintf("%s; filename=\"%s\"; filename*=UTF-8''%s", disposition, safe, artifact_filename_star(name))
}
artifact_header_filename :: proc(name:string)->string{
	trimmed:=strings.trim_space(name); if trimmed=="" do return "artifact"
	b:=strings.builder_make()
	for i:=0; i<len(trimmed); i+=1{
		ch:=trimmed[i]
		if ch<32 || ch==127 || ch=='"' || ch=='\\' || ch=='/' || ch=='\r' || ch=='\n' {
			strings.write_byte(&b,'_')
		} else {
			strings.write_byte(&b,ch)
		}
	}
	return strings.to_string(b)
}
artifact_filename_star :: proc(name:string)->string{
	trimmed:=strings.trim_space(name); if trimmed=="" do trimmed="artifact"
	b:=strings.builder_make()
	for i:=0; i<len(trimmed); i+=1{
		ch:=trimmed[i]
		unreserved := (ch>='a' && ch<='z') || (ch>='A' && ch<='Z') || (ch>='0' && ch<='9') || ch=='-' || ch=='.' || ch=='_' || ch=='~'
		if unreserved { strings.write_byte(&b,ch) } else { strings.write_string(&b,fmt.tprintf("%%%02X",int(ch))) }
	}
	return strings.to_string(b)
}

patch_artifact_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; a,saved,err:=content_service.update_artifact(h.content,auth,path_part(req.path,4),json_string(req.body,"name"),json_string(req.body,"description")); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_artifact_json(&b,a,false); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req)) }
delete_artifact_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; deleted,err:=content_service.delete_artifact(h.content,auth,path_part(req.path,4)); if !deleted do return respond_error(err,req.request_id); return Response{status=204,content_type="application/json",body=""} }

list_templates_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; rows,err:=content_service.list_templates(h.content,auth); if err.code!=.None do return respond_error(err,req.request_id); b:=strings.builder_make(); strings.write_byte(&b,'['); for r,i in rows{ if i>0 do strings.write_byte(&b,','); write_template_json(&b,r)}; strings.write_byte(&b,']'); return respond_list(strings.to_string(b),contracts.API_Page{limit=contracts.API_DEFAULT_PAGE_LIMIT,has_more=false},req.request_id,auth_ctx_server_time(req)) }
create_template_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; t,saved,err:=content_service.create_template(h.content,auth,template_input(req.body)); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_template_json(&b,t); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201) }

restart_stopped_conversation_instance :: proc(h:^Content_Handlers, auth:contracts.Auth_Context, cid:string)->(bool,domain.Domain_Error){ c,got,err:=content_service.get_conversation(h.content,auth,cid); if !got do return false,err; if c.agent_instance_id=="" || h.agents==nil do return true,{}; inst,inst_ok,inst_err:=agent_service.get_instance(h.agents,auth,c.agent_instance_id); if !inst_ok do return false,inst_err; if inst.runtime_status=="stopped" || inst.runtime_status=="failed" || inst.runtime_status=="unreachable" { _,restarted,restart_err:=agent_service.restart_instance(h.agents,auth,c.agent_instance_id); if !restarted do return false,restart_err }; return true,{} }

default_str :: proc(v,d:string)->string{ if v=="" do return d; return v }
memory_input :: proc(body:string)->content_service.Memory_Input{
	agent_id := json_string(body,"agent_id"); if agent_id == "" do agent_id = json_string(body,"target_agent_id")
	project_id := json_string(body,"project_id"); if project_id == "" do project_id = json_string(body,"target_project_id")
	template_id := json_string(body,"template_id"); if template_id == "" do template_id = json_string(body,"target_template_id")
	bridge_id := json_string(body,"bridge_id"); if bridge_id == "" do bridge_id = json_string(body,"target_bridge_id")
	return content_service.Memory_Input{agent_id=agent_id,project_id=domain.Project_ID(project_id),template_id=template_id,bridge_id=bridge_id,type=domain.memory_type_from_string(json_string(body,"type")),title=json_string(body,"title"),body=json_string(body,"body"),evidence=json_string(body,"evidence"),status=json_string(body,"status")}
}
json_property :: proc(body, key: string) -> (value: string, present: bool) {
	i := 0
	n := len(body)
	for i < n {
		if body[i] == '"' {
			key_start := i + 1
			i += 1
			for i < n {
				if body[i] == '\\' {
					i += 2
					continue
				}
				if body[i] == '"' {
					break
				}
				i += 1
			}
			if i >= n do return "", false
			found_key := body[key_start:i]
			i += 1

			for i < n && (body[i] == ' ' || body[i] == '\t' || body[i] == '\r' || body[i] == '\n') {
				i += 1
			}
			if i < n && body[i] == ':' {
				i += 1
				for i < n && (body[i] == ' ' || body[i] == '\t' || body[i] == '\r' || body[i] == '\n') {
					i += 1
				}
				if found_key == key {
					if i < n && body[i] == '"' {
						val_start := i + 1
						i += 1
						for i < n {
							if body[i] == '\\' {
								i += 2
								continue
							}
							if body[i] == '"' {
								return body[val_start:i], true
							}
							i += 1
						}
					}
					return "", true
				}
			}
		} else {
			i += 1
		}
	}
	return "", false
}

memory_update_input :: proc(body: string) -> (content_service.Memory_Update_Input, bool) {
	trimmed := strings.trim_space(body)
	if trimmed == "" || trimmed == "{}" do return {}, false
	input: content_service.Memory_Update_Input
	has_any := false

	if val, ok := json_property(body, "title"); ok { input.title = val; input.has_title = true; has_any = true }
	if val, ok := json_property(body, "body"); ok { input.body = val; input.has_body = true; has_any = true }
	if val, ok := json_property(body, "evidence"); ok { input.evidence = val; input.has_evidence = true; has_any = true }
	if val, ok := json_property(body, "type"); ok { input.type = domain.memory_type_from_string(val); input.has_type = true; has_any = true }

	if val, ok := json_property(body, "agent_id"); ok {
		input.agent_id = val; input.has_agent_id = true; has_any = true
	} else if val, ok := json_property(body, "target_agent_id"); ok {
		input.agent_id = val; input.has_agent_id = true; has_any = true
	}

	if val, ok := json_property(body, "project_id"); ok {
		input.project_id = domain.Project_ID(val); input.has_project_id = true; has_any = true
	} else if val, ok := json_property(body, "target_project_id"); ok {
		input.project_id = domain.Project_ID(val); input.has_project_id = true; has_any = true
	}

	if val, ok := json_property(body, "bridge_id"); ok {
		input.bridge_id = val; input.has_bridge_id = true; has_any = true
	} else if val, ok := json_property(body, "target_bridge_id"); ok {
		input.bridge_id = val; input.has_bridge_id = true; has_any = true
	}

	if val, ok := json_property(body, "template_id"); ok {
		input.template_id = val; input.has_template_id = true; has_any = true
	} else if val, ok := json_property(body, "target_template_id"); ok {
		input.template_id = val; input.has_template_id = true; has_any = true
	}

	return input, has_any
}
chat_input :: proc(body:string)->content_service.Chat_Input{ return content_service.Chat_Input{agent_id=json_string(body,"agent_id"),agent_instance_id=json_string(body,"agent_instance_id"),chain_id=json_string(body,"chain_id"),project_id=domain.Project_ID(json_string(body,"project_id")),title=json_string(body,"title"),initial_body=json_object_string(body,"initial_message","body"),artifact_ids_json=json_array_raw(body,"artifact_ids"),bridge_id=json_string(body,"bridge_id"),provider=json_string(body,"provider"),tier=json_string(body,"tier")} }
message_input :: proc(body:string)->content_service.Message_Input{ return content_service.Message_Input{body=json_string(body,"body"),artifact_ids_json=json_array_raw(body,"artifact_ids")} }
artifact_input :: proc(body:string)->content_service.Artifact_Input{
	content := json_string(body,"content")
	b64 := json_string(body,"content_base64")
	if b64 != "" {
		dec, _ := internal_b64.decode(b64, allocator = context.temp_allocator)
		if len(dec) > 0 {
			content = string(dec)
		}
	}
	return content_service.Artifact_Input{kind=json_string(body,"kind"),name=json_string(body,"name"),description=json_string(body,"description"),content_type=json_string(body,"content_type"),content=content,filename=json_string(body,"filename"),agent_id=json_string(body,"agent_id"),agent_instance_id=json_string(body,"agent_instance_id"),chain_id=json_string(body,"chain_id"),task_id=json_string(body,"task_id"),project_id=domain.Project_ID(json_string(body,"project_id")),mime=json_string(body,"mime"),ext=json_string(body,"ext"),sha256=json_string(body,"sha256"),origin_kind=json_string(body,"origin_kind"),origin_ref=json_string(body,"origin_ref")}
}
artifact_input_from_request :: proc(req:Request)->content_service.Artifact_Input{
	ctype := header_value(req.headers,"Content-Type")
	if strings.contains(ctype,"multipart/form-data") {
		if input, ok := multipart_artifact_input(req.body,ctype); ok do return input
	}
	return artifact_input(req.body)
}
multipart_artifact_input :: proc(body,ctype:string)->(content_service.Artifact_Input,bool){
	boundary := multipart_boundary(ctype)
	if boundary == "" do return {},false
	marker := strings.concatenate({"--",boundary}); defer delete(marker)
	marker_crlf := strings.concatenate({"\r\n",marker}); defer delete(marker_crlf)
	marker_lf := strings.concatenate({"\n",marker}); defer delete(marker_lf)
	input: content_service.Artifact_Input
	pos := 0
	seen := false
	for {
		rel := strings.index(body[pos:],marker)
		if rel < 0 do break
		start := pos + rel + len(marker)
		if start + 2 <= len(body) && body[start:start+2] == "--" do break
		if start + 2 <= len(body) && body[start:start+2] == "\r\n" { start += 2 } else if start < len(body) && body[start] == '\n' { start += 1 }
		head_rel := strings.index(body[start:],"\r\n\r\n")
		sep_len := 4
		if head_rel < 0 { head_rel = strings.index(body[start:],"\n\n"); sep_len = 2 }
		if head_rel < 0 do break
		head := body[start:start+head_rel]
		content_start := start + head_rel + sep_len
		next_rel := strings.index(body[content_start:],marker_crlf)
		if next_rel < 0 do next_rel = strings.index(body[content_start:],marker_lf)
		if next_rel < 0 do break
		content_end := content_start + next_rel
		part_body := body[content_start:content_end]
		part_name := multipart_disposition_param(head,"name")
		filename := multipart_disposition_param(head,"filename")
		part_ctype := multipart_header_value(head,"Content-Type")
		if filename != "" && (part_name == "file" || input.content == "") {
			input.content = part_body
			input.filename = filename
			if input.name == "" do input.name = filename
			if part_ctype != "" { input.content_type = part_ctype; input.mime = part_ctype }
			seen = true
		} else if part_name != "" {
			multipart_set_artifact_field(&input,part_name,part_body)
			seen = true
		}
		pos = content_end
	}
	return input,seen
}
multipart_boundary :: proc(ctype:string)->string{
	idx := strings.index(ctype,"boundary=")
	if idx < 0 do return ""
	value := strings.trim_space(ctype[idx+len("boundary="):])
	if semi := strings.index_byte(value,';'); semi >= 0 do value = strings.trim_space(value[:semi])
	if len(value) >= 2 && value[0] == '"' {
		if end := strings.index_byte(value[1:],'"'); end >= 0 do return value[1:1+end]
	}
	return value
}
multipart_header_value :: proc(headers,key:string)->string{
	text := headers
	for line in strings.split_lines_iterator(&text) {
		colon := strings.index_byte(line,':')
		if colon <= 0 do continue
		if ascii_equal_fold(strings.trim_space(line[:colon]),key) do return strings.trim_space(line[colon+1:])
	}
	return ""
}
multipart_disposition_param :: proc(headers,param:string)->string{
	disp := multipart_header_value(headers,"Content-Disposition")
	needle := strings.concatenate({param,"="}); defer delete(needle)
	idx := strings.index(disp,needle)
	if idx < 0 do return ""
	value := strings.trim_space(disp[idx+len(needle):])
	if len(value) >= 1 && value[0] == '"' {
		if end := strings.index_byte(value[1:],'"'); end >= 0 do return value[1:1+end]
	}
	if semi := strings.index_byte(value,';'); semi >= 0 do return strings.trim_space(value[:semi])
	return strings.trim_space(value)
}
multipart_set_artifact_field :: proc(input:^content_service.Artifact_Input,name,value:string){
	switch name {
	case "name": input.name = value
	case "kind": input.kind = value
	case "description": input.description = value
	case "content_type": input.content_type = value
	case "mime": input.mime = value
	case "ext": input.ext = value
	case "sha256": input.sha256 = value
	case "origin_kind": input.origin_kind = value
	case "origin_ref": input.origin_ref = value
	case "filename": input.filename = value
	case "agent_id": input.agent_id = value
	case "agent_instance_id": input.agent_instance_id = value
	case "chain_id": input.chain_id = value
	case "task_id": input.task_id = value
	case "project_id": input.project_id = domain.Project_ID(value)
	}
}
template_input :: proc(body:string)->content_service.Template_Input{ return content_service.Template_Input{name=json_string(body,"name"),description=json_string(body,"description"),persona=json_string(body,"persona"),instructions=json_string(body,"instructions")} }

write_memory_json :: proc(b:^strings.Builder,m:domain.Memory,preview:bool){ typ:=domain.memory_type_string(m.type); strings.write_string(b,"{\"memory_id\":\""); write_handler_json_string(b,m.memory_id); strings.write_string(b,"\",\"agent_id\":\""); write_handler_json_string(b,m.agent_id); strings.write_string(b,"\",\"target_agent_id\":\""); write_handler_json_string(b,m.agent_id); strings.write_string(b,"\",\"project_id\":\""); write_handler_json_string(b,string(m.project_id)); strings.write_string(b,"\",\"target_project_id\":\""); write_handler_json_string(b,string(m.project_id)); strings.write_string(b,"\",\"template_id\":\""); write_handler_json_string(b,m.template_id); strings.write_string(b,"\",\"target_template_id\":\""); write_handler_json_string(b,m.template_id); strings.write_string(b,"\",\"bridge_id\":\""); write_handler_json_string(b,m.bridge_id); strings.write_string(b,"\",\"target_bridge_id\":\""); write_handler_json_string(b,m.bridge_id); strings.write_string(b,"\",\"type\":\""); write_handler_json_string(b,typ); strings.write_string(b,"\",\"status\":\""); write_handler_json_string(b,m.status); strings.write_string(b,"\",\"title\":\""); write_handler_json_string(b,m.title); if preview { strings.write_string(b,"\",\"body_preview\":\""); write_handler_json_string(b,m.body) } else { strings.write_string(b,"\",\"body\":\""); write_handler_json_string(b,m.body); strings.write_string(b,"\",\"evidence\":\""); write_handler_json_string(b,m.evidence) }; strings.write_string(b,"\",\"updated_at\":\""); write_handler_json_string(b,m.updated_at); strings.write_string(b,"\"}") }
write_chat_json :: proc(b:^strings.Builder,c:domain.Chat_Conversation){ strings.write_string(b,"{\"conversation_id\":\""); write_handler_json_string(b,c.conversation_id); strings.write_string(b,"\",\"agent_id\":\""); write_handler_json_string(b,c.agent_id); strings.write_string(b,"\",\"agent_instance_id\":\""); write_handler_json_string(b,c.agent_instance_id); strings.write_string(b,"\",\"project_id\":\""); write_handler_json_string(b,string(c.project_id)); strings.write_string(b,"\",\"chain_id\":\""); write_handler_json_string(b,c.chain_id); strings.write_string(b,"\",\"title\":\""); write_handler_json_string(b,c.title); strings.write_string(b,"\",\"unread_count\":"); strings.write_string(b,fmt.tprintf("%d",c.unread_count)); strings.write_string(b,",\"last_message_preview\":\""); write_handler_json_string(b,c.last_message_preview); strings.write_string(b,"\",\"last_message_at\":\""); write_handler_json_string(b,c.last_message_at); strings.write_string(b,"\",\"updated_at\":\""); write_handler_json_string(b,c.updated_at); strings.write_string(b,"\"}") }
write_chat_json_with_runtime :: proc(b:^strings.Builder,c:domain.Chat_Conversation,h:^Content_Handlers,auth:contracts.Auth_Context){ bridge_id:=""; runtime_status:=""; agent_name:=""; agent_slug:=""; if h!=nil && h.agents!=nil { if c.agent_instance_id!="" { if inst,inst_ok,_:=agent_service.get_instance(h.agents,auth,c.agent_instance_id); inst_ok { bridge_id=inst.bridge_id; runtime_status=inst.runtime_status } }; if c.agent_id!="" { if agent,agent_ok,_:=agent_service.get_agent(h.agents,auth,c.agent_id); agent_ok { agent_name=agent.name; agent_slug=agent.slug } } }; strings.write_string(b,"{\"conversation_id\":\""); write_handler_json_string(b,c.conversation_id); strings.write_string(b,"\",\"agent_id\":\""); write_handler_json_string(b,c.agent_id); strings.write_string(b,"\",\"agent_name\":\""); write_handler_json_string(b,agent_name); strings.write_string(b,"\",\"agent_slug\":\""); write_handler_json_string(b,agent_slug); strings.write_string(b,"\",\"agent_instance_id\":\""); write_handler_json_string(b,c.agent_instance_id); strings.write_string(b,"\",\"bridge_id\":\""); write_handler_json_string(b,bridge_id); strings.write_string(b,"\",\"runtime_status\":\""); write_handler_json_string(b,runtime_status); strings.write_string(b,"\",\"project_id\":\""); write_handler_json_string(b,string(c.project_id)); strings.write_string(b,"\",\"chain_id\":\""); write_handler_json_string(b,c.chain_id); strings.write_string(b,"\",\"title\":\""); write_handler_json_string(b,c.title); strings.write_string(b,"\",\"unread_count\":"); strings.write_string(b,fmt.tprintf("%d",c.unread_count)); strings.write_string(b,",\"last_message_preview\":\""); write_handler_json_string(b,c.last_message_preview); strings.write_string(b,"\",\"last_message_at\":\""); write_handler_json_string(b,c.last_message_at); strings.write_string(b,"\",\"updated_at\":\""); write_handler_json_string(b,c.updated_at); strings.write_string(b,"\"}") }
write_message_json :: proc(b:^strings.Builder,m:domain.Chat_Message,svc:^content_service.Content_Service){ body:=content_service.message_body_for_response(svc,m); strings.write_string(b,"{\"message_id\":\""); write_handler_json_string(b,m.message_id); strings.write_string(b,"\",\"conversation_id\":\""); write_handler_json_string(b,m.conversation_id); strings.write_string(b,"\",\"direction\":\""); write_handler_json_string(b,m.direction); strings.write_string(b,"\",\"body\":\""); write_handler_json_string(b,body); strings.write_string(b,"\",\"artifact_ids\":"); strings.write_string(b,artifact_json_or_empty(m.artifact_ids_json)); strings.write_string(b,",\"created_at\":\""); write_handler_json_string(b,m.created_at); strings.write_string(b,"\"}") }
write_artifact_json :: proc(b:^strings.Builder,a:domain.Artifact,with_content:bool){ strings.write_string(b,"{\"artifact_id\":\""); write_handler_json_string(b,a.artifact_id); strings.write_string(b,"\",\"kind\":\""); write_handler_json_string(b,a.kind); strings.write_string(b,"\",\"name\":\""); write_handler_json_string(b,a.name); strings.write_string(b,"\",\"description\":\""); write_handler_json_string(b,a.description); strings.write_string(b,"\",\"content_type\":\""); write_handler_json_string(b,a.content_type); strings.write_string(b,"\",\"mime\":\""); write_handler_json_string(b,a.mime); strings.write_string(b,"\",\"ext\":\""); write_handler_json_string(b,a.ext); strings.write_string(b,"\",\"sha256\":\""); write_handler_json_string(b,a.sha256); strings.write_string(b,"\",\"origin_kind\":\""); write_handler_json_string(b,a.origin_kind); strings.write_string(b,"\",\"origin_ref\":\""); write_handler_json_string(b,a.origin_ref); strings.write_string(b,"\",\"agent_id\":\""); write_handler_json_string(b,a.agent_id); strings.write_string(b,"\",\"agent_instance_id\":\""); write_handler_json_string(b,a.agent_instance_id); strings.write_string(b,"\",\"chain_id\":\""); write_handler_json_string(b,a.chain_id); strings.write_string(b,"\",\"task_id\":\""); write_handler_json_string(b,a.task_id); strings.write_string(b,"\",\"project_id\":\""); write_handler_json_string(b,string(a.project_id)); strings.write_string(b,"\",\"link\":\"artifact://"); write_handler_json_string(b,a.artifact_id); strings.write_string(b,"\",\"size_bytes\":"); strings.write_string(b,fmt.tprintf("%d",a.size_bytes)); if with_content {strings.write_string(b,",\"content\":\""); write_handler_json_string(b,a.content)}; strings.write_string(b,",\"deleted_at\":\""); write_handler_json_string(b,a.deleted_at); strings.write_string(b,"\",\"created_at\":\""); write_handler_json_string(b,a.created_at); strings.write_string(b,"\",\"updated_at\":\""); write_handler_json_string(b,a.updated_at); strings.write_string(b,"\"}") }
write_template_json :: proc(b:^strings.Builder,t:domain.Template){ strings.write_string(b,"{\"template_id\":\""); write_handler_json_string(b,t.template_id); strings.write_string(b,"\",\"is_system\":"); strings.write_string(b,"true" if t.is_system else "false"); strings.write_string(b,",\"name\":\""); write_handler_json_string(b,t.name); strings.write_string(b,"\",\"description\":\""); write_handler_json_string(b,t.description); strings.write_string(b,"\",\"persona\":\""); write_handler_json_string(b,t.persona); strings.write_string(b,"\",\"instructions\":\""); write_handler_json_string(b,t.instructions); strings.write_string(b,"\"}") }

query_value :: proc(q,key:string)->string{ parts:=strings.split(q,"&"); defer delete(parts); for p in parts{ eq:=strings.index_byte(p,'='); if eq>=0 && p[:eq]==key do return p[eq+1:] }; return "" }
query_int :: proc(q,key:string,d:int)->int{ v:=query_value(q,key); if p,ok:=strconv.parse_int(v); ok do return int(p); return d }
json_array_raw :: proc(body,key:string)->string{ needle:=strings.concatenate({"\"",key,"\""}); defer delete(needle); idx:=strings.index(body,needle); if idx<0 do return "[]"; rest:=body[idx+len(needle):]; open:=strings.index_byte(rest,'['); if open<0 do return "[]"; close:=strings.index_byte(rest[open:],']'); if close<0 do return "[]"; return rest[open:open+close+1] }
json_object_string :: proc(body,obj,key:string)->string{ oi:=strings.index(body,strings.concatenate({"\"",obj,"\""})); if oi<0 do return ""; return json_string(body[oi:],key) }
artifact_json_or_empty :: proc(v:string)->string{ if strings.trim_space(v)=="" do return "[]"; return v }
