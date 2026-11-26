package http

import "core:encoding/json"
import domain "odin_test:hub/domain"
import auth "odin_test:hub/service/auth"
import fleet "odin_test:hub/service/fleet_application"

Fleet_Handlers :: struct {auth: ^auth.Auth_Service, service: ^fleet.Service}

fleet_preview_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Fleet_Handlers)(ctx)
	a, ok, response := require_auth_any(h.auth, req)
	if !ok do return response
	value, parse_err := json.parse_string(req.body,.JSON,parse_integers=true,allocator=context.temp_allocator)
	draft, valid := fleet.parse_preview(value)
	if parse_err != nil || !valid do return respond_error(domain.domain_error(.Validation_Failed,"invalid complete Fleet draft"),req.request_id)
	result, err := fleet.preview(h.service,a,path_part(req.path,4),draft)
	if err.code != .None do return respond_error(err,req.request_id)
	data, _ := json.marshal(result,allocator=context.temp_allocator)
	return respond_success(string(data),req.request_id,auth_ctx_server_time(req))
}

fleet_settings_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Fleet_Handlers)(ctx)
	a, ok, response := require_auth_any(h.auth, req)
	if !ok do return response
	snapshot, err := fleet.read_settings(h.service, a, path_part(req.path,4))
	if err.code != .None do return respond_error(err,req.request_id)
	defer domain.fleet_settings_destroy(snapshot)
	data, _ := json.marshal(snapshot,allocator=context.temp_allocator)
	return respond_success(string(data),req.request_id,auth_ctx_server_time(req))
}
fleet_apply_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Fleet_Handlers)(ctx)
	a, ok, response := require_auth_any(h.auth,req)
	if !ok do return response
	value, parse_err := json.parse_string(req.body,.JSON,parse_integers=true,allocator=context.temp_allocator)
	input, valid := fleet.parse_apply(value)
	if parse_err != nil || !valid do return respond_error(domain.domain_error(.Validation_Failed,"invalid complete Fleet draft"),req.request_id)
	r, accepted, err := fleet.apply(h.service,a,path_part(req.path,4),input)
	if !accepted do return respond_error(err,req.request_id)
	defer domain.fleet_application_record_destroy(&r)
	data, _ := json.marshal(r.application,allocator=context.temp_allocator)
	return respond_success(string(data),req.request_id,auth_ctx_server_time(req),202)
}
fleet_application_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Fleet_Handlers)(ctx)
	a, ok, response := require_auth_any(h.auth,req)
	if !ok do return response
	r, found, err := fleet.read_application(h.service,a,path_part(req.path,4),path_part(req.path,7))
	if !found do return respond_error(err,req.request_id)
	defer domain.fleet_application_record_destroy(&r)
	data, _ := json.marshal(r.application,allocator=context.temp_allocator)
	return respond_success(string(data),req.request_id,auth_ctx_server_time(req))
}
fleet_retry_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Fleet_Handlers)(ctx)
	a, ok, response := require_auth_any(h.auth,req)
	if !ok do return response
	r, found, err := fleet.retry_application(h.service,a,path_part(req.path,4),path_part(req.path,7))
	if !found do return respond_error(err,req.request_id)
	defer domain.fleet_application_record_destroy(&r)
	data, _ := json.marshal(r.application,allocator=context.temp_allocator)
	return respond_success(string(data),req.request_id,auth_ctx_server_time(req),202)
}
