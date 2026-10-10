package http
import "core:encoding/json"
import user_service "odin_test:hub/service/user"
import domain "odin_test:hub/domain"

get_conversation_launch_preferences_handler :: proc(ctx: rawptr, req: Request) -> Response {
 h := (^User_Handlers)(ctx)
 auth, ok, resp := require_auth(h.auth, req); if !ok do return resp
 prefs, err := user_service.get_launch_preferences(h.launch_preferences, auth)
 if err.code != .None do return respond_error(err, req.request_id)
 data, _ := json.marshal(prefs, allocator = context.temp_allocator)
 return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
}
patch_conversation_launch_preferences_handler :: proc(ctx: rawptr, req: Request) -> Response {
 h := (^User_Handlers)(ctx)
 auth, ok, resp := require_auth(h.auth, req); if !ok do return resp
 value, parse_err := json.parse_string(req.body, .JSON, allocator = context.temp_allocator)
 object, valid := value.(json.Object)
 if parse_err != nil || !valid || len(object) != 1 do return respond_error(domain.domain_error(.Validation_Failed, "update one launch selection at a time"), req.request_id)
 for field, raw in object {
  selection, is_string := raw.(string)
  if !is_string do return respond_error(domain.domain_error(.Validation_Failed, "launch selection must be a string"), req.request_id)
  prefs, saved, err := user_service.set_launch_selection(h.launch_preferences, auth, field, selection)
  if !saved do return respond_error(err, req.request_id)
  data, _ := json.marshal(prefs, allocator = context.temp_allocator)
  return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
 }
 return respond_error(domain.domain_error(.Validation_Failed, "selection is required"), req.request_id)
}
set_agent_favorite_handler :: proc(ctx: rawptr, req: Request) -> Response {
 h := (^User_Handlers)(ctx)
 auth, ok, resp := require_auth(h.auth, req); if !ok do return resp
 value, parse_err := json.parse_string(req.body, .JSON, allocator = context.temp_allocator)
 object, valid := value.(json.Object)
 favorite, boolean := object["favorite"].(bool)
 if parse_err != nil || !valid || len(object) != 1 || !boolean do return respond_error(domain.domain_error(.Validation_Failed, "favorite boolean is required"), req.request_id)
 prefs, saved, err := user_service.set_agent_favorite(h.launch_preferences, auth, path_part(req.path, 4), favorite)
 if !saved do return respond_error(err, req.request_id)
 data, _ := json.marshal(prefs, allocator = context.temp_allocator)
 return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
}
