package main

// DP-2 / DP-3 / DP-7: loopback-only JSON management API for ham-dev-proxy.
//
// Routes (all under /_dev/api/, handled before forward_request and NEVER
// proxied to the Hub):
//   GET    /_dev/api/users          -> {active, users:[{username,display_name,email}]}
//   POST   /_dev/api/users          {username, display_name, email}
//                                      -> created user (201); 409 on dup/empty username
//   DELETE /_dev/api/users/<name>   -> removes user (204); clears active if it was selected
//   POST   /_dev/api/active         {username}
//                                      -> sets persisted active + Set-Cookie ham_dev_user (200); 404 if unknown
//
// Loopback enforcement (DP-7) is applied by the dispatcher in main.odin
// before any handler runs: a non-loopback bind serves 404 for all /_dev/*
// routes, so these handlers are unreachable remotely.
//
// Mutations persist via the task-1 store (Dev_Proxy_Store) with atomic
// temp+rename writes and update the in-memory config.users snapshot under
// the store mutex, so the next forwarded request sees the change.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import contracts "odin_test:contracts"

// handle_dev_api_request dispatches a /_dev/api/* request. Returns true if the
// path/method matched a management route (the response has already been
// written); false to let the caller continue /_dev/ dispatch.
handle_dev_api_request :: proc(ctx: ^Dev_Proxy_Client_Context, method, path, body: string) -> bool {
	if method == "GET" && path == "/_dev/api/users" {
		write_api_users(ctx)
		return true
	}
	if method == "POST" && path == "/_dev/api/users" {
		create_api_user(ctx, body)
		return true
	}
	if method == "DELETE" && strings.has_prefix(path, "/_dev/api/users/") {
		username := path[len("/_dev/api/users/"):]
		delete_api_user(ctx, username)
		return true
	}
	if method == "POST" && path == "/_dev/api/active" {
		set_api_active(ctx, body)
		return true
	}
	return false
}

// handle_dev_ui_request is the management HTML UI hook (DP-4, task-19f97e26cdf).
// Task-2 ships a 404 stub so the API is self-contained without the UI; task-3
// replaces this with the real self-contained HTML document served at /_dev/.
handle_dev_ui_request :: proc(client: net.TCP_Socket, path: string) -> bool {
	if path != "/_dev/" && path != "/_dev" && path != "/_dev/ui" do return false
	write_response(client, 404, "Not Found", "text/plain", "management UI not yet implemented (task-19f97e26cdf)")
	return true
}

// write_api_users serializes the current roster + active selection. Active is
// null when no persisted active is set (fresh first run).
write_api_users :: proc(ctx: ^Dev_Proxy_Client_Context) {
	active := dev_proxy_store_active(ctx.store)
	b := strings.builder_make()
	strings.write_string(&b, `{"active": `)
	if active == "" {
		strings.write_string(&b, "null")
	} else {
		json_write_string(&b, active)
	}
	strings.write_string(&b, `, "users": [`)
	first := true
	for u in ctx.config.users {
		if !first do strings.write_string(&b, ", ")
		first = false
		strings.write_string(&b, `{"username": `)
		json_write_string(&b, u.username)
		strings.write_string(&b, `, "display_name": `)
		json_write_string(&b, u.display_name)
		strings.write_string(&b, `, "email": `)
		json_write_string(&b, u.email)
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, `]}`)
	write_response(ctx.client, 200, "OK", "application/json", strings.to_string(b))
}

// create_api_user handles POST /_dev/api/users. Username required + unique
// (DP-2). The new user is persisted (atomic write) and immediately selectable.
create_api_user :: proc(ctx: ^Dev_Proxy_Client_Context, body: string) {
	val, obj, ok := parse_json_object(body)
	if !ok {
		write_json_error(ctx.client, 400, "invalid json body")
		return
	}
	defer json.destroy_value(val)
	u := dev_user_from_json(obj)
	if u.username == "" {
		write_json_error(ctx.client, 409, "username required")
		return
	}
	if dev_user_exists(ctx.config, u.username) {
		write_json_error(ctx.client, 409, "duplicate username")
		return
	}

	new_users := make([]Dev_User, len(ctx.config.users) + 1)
	for i in 0..<len(ctx.config.users) {
		new_users[i] = ctx.config.users[i]
	}
	new_users[len(ctx.config.users)] = u

	active := dev_proxy_store_active(ctx.store)
	if !dev_proxy_store_save(ctx.store, new_users, active) {
		write_json_error(ctx.client, 500, "store save failed")
		return
	}
	ctx.config.users = new_users

	b := strings.builder_make()
	strings.write_string(&b, `{"username": `)
	json_write_string(&b, u.username)
	strings.write_string(&b, `, "display_name": `)
	json_write_string(&b, u.display_name)
	strings.write_string(&b, `, "email": `)
	json_write_string(&b, u.email)
	strings.write_string(&b, `}`)
	write_response(ctx.client, 201, "Created", "application/json", strings.to_string(b))
}

// delete_api_user handles DELETE /_dev/api/users/<username>. If the deleted
// user was the persisted active selection, active is cleared (DP-7).
delete_api_user :: proc(ctx: ^Dev_Proxy_Client_Context, username: string) {
	if !dev_user_exists(ctx.config, username) {
		write_json_error(ctx.client, 404, "unknown user")
		return
	}

	remaining := make([dynamic]Dev_User, 0, len(ctx.config.users))
	for u in ctx.config.users {
		if u.username != username do append(&remaining, u)
	}

	active := dev_proxy_store_active(ctx.store)
	if active == username {
		active = "" // DP-7: deleting the active user clears the active selection
	}
	if !dev_proxy_store_save(ctx.store, remaining[:], active) {
		write_json_error(ctx.client, 500, "store save failed")
		return
	}
	ctx.config.users = remaining[:]

	write_response(ctx.client, 204, "No Content", "application/json", "")
}

// set_api_active handles POST /_dev/api/active {username}. Persists the active
// selection (DP-1/DP-3) AND sets the ham_dev_user cookie so a browser session
// immediately uses it without a separate /_dev/login call. 404 if the user is
// not in the roster.
set_api_active :: proc(ctx: ^Dev_Proxy_Client_Context, body: string) {
	val, obj, ok := parse_json_object(body)
	if !ok {
		write_json_error(ctx.client, 400, "invalid json body")
		return
	}
	defer json.destroy_value(val)
	username := ""
	if v, has := obj["username"]; has {
		if s, ok := v.(json.String); ok do username = string(s)
	}
	if !dev_user_exists(ctx.config, username) {
		write_json_error(ctx.client, 404, "unknown user")
		return
	}

	if !dev_proxy_store_save(ctx.store, ctx.config.users, username) {
		write_json_error(ctx.client, 500, "store save failed")
		return
	}
	ctx.config.default_user = strings.clone(username)

	cookie := contracts.HTTP_Header{name = "Set-Cookie", value = login_response_cookie(username)}
	write_response_with_headers(ctx.client, 200, "OK", "application/json", `{"status":"ok"}`, []contracts.HTTP_Header{cookie})
}

// parse_json_object parses a JSON object body, returning the parsed value
// (so the caller can defer json.destroy_value(val)) and its object view.
// Returns ok=false on any parse/type error (caller emits a 400). On success
// the caller MUST defer json.destroy_value(val) after cloning any kept fields
// (dev_user_from_json clones username/display_name/email).
parse_json_object :: proc(body: string) -> (val: json.Value, obj: json.Object, ok: bool) {
	parsed, err := json.parse_string(body)
	if err != .None do return nil, nil, false
	parsed_obj, is_obj := parsed.(json.Object)
	if !is_obj {
		json.destroy_value(parsed)
		return nil, nil, false
	}
	return parsed, parsed_obj, true
}

// write_json_error emits a uniform JSON error response.
write_json_error :: proc(client: net.TCP_Socket, status: int, message: string) {
	b := strings.builder_make()
	strings.write_string(&b, `{"error": `)
	json_write_string(&b, message)
	strings.write_string(&b, `}`)
	text := strings.to_string(b)
	write_response(client, status, status_text(status), "application/json", text)
}

// status_text maps the small set of status codes used here to reason phrases.
status_text :: proc(status: int) -> string {
	switch status {
	case 400: return "Bad Request"
	case 404: return "Not Found"
	case 409: return "Conflict"
	case 500: return "Internal Server Error"
	case: return fmt.tprintf("%d", status)
	}
}
