package http

import "core:strings"
import auth_service "odin_test:hub/service/auth"
import domain "odin_test:hub/domain"
import push_service "odin_test:hub/service/push"

// Push_Handlers serve the Web Push subscription endpoints (WP-API). The VAPID
// public key is served verbatim from config so the client can subscribe; the
// private key is NEVER exposed here.
Push_Handlers :: struct {
	auth:             ^auth_service.Auth_Service,
	push:             ^push_service.Push_Service,
	vapid_public_key: string,
}

// vapid_public_key_handler serves GET /api/v1/push/vapid-public-key (no auth).
// Response: {"data":{"vapid_public_key":"<base64url uncompressed P-256 point>"}}.
// When no key is configured it returns an empty string so the client can detect
// that push is unavailable without erroring.
vapid_public_key_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Push_Handlers)(ctx)
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"vapid_public_key\":\"")
	write_handler_json_string(&builder, handlers.vapid_public_key)
	strings.write_string(&builder, "\"}")
	return respond_success(strings.to_string(builder), req.request_id, auth_ctx_server_time(req))
}

// create_push_subscription_handler serves POST /api/v1/me/push-subscriptions
// (auth). Body is a browser PushSubscription.toJSON():
// {"endpoint":...,"keys":{"p256dh":...,"auth":...}}. Upserts by endpoint and
// returns 201 {"data":{"id":"psub_..."}}.
create_push_subscription_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Push_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp

	endpoint := json_string(req.body, "endpoint")
	p256dh := json_object_string(req.body, "keys", "p256dh")
	auth := json_object_string(req.body, "keys", "auth")

	saved, saved_ok, err := push_service.save_subscription(handlers.push, push_service.Save_Subscription_Input{
		owner_user_id = domain.User_ID(auth_ctx.user_id),
		endpoint      = endpoint,
		p256dh        = p256dh,
		auth          = auth,
	})
	if !saved_ok do return respond_error(err, req.request_id)

	builder := strings.builder_make()
	strings.write_string(&builder, "{\"id\":\"")
	write_handler_json_string(&builder, string(saved.id))
	strings.write_string(&builder, "\"}")
	return respond_success(strings.to_string(builder), req.request_id, auth_ctx_server_time(req), 201)
}

// delete_push_subscription_handler serves DELETE /api/v1/me/push-subscriptions
// (auth). Body: {"endpoint":...}. Returns 200 {"data":{"deleted":true|false}}.
// Deleting is idempotent: a missing subscription still returns 200 with
// deleted=false rather than 404.
delete_push_subscription_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Push_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp

	endpoint := json_string(req.body, "endpoint")
	deleted, err := push_service.delete_subscription(handlers.push, domain.User_ID(auth_ctx.user_id), endpoint)
	if err.code != .None do return respond_error(err, req.request_id)

	builder := strings.builder_make()
	strings.write_string(&builder, "{\"deleted\":")
	strings.write_string(&builder, "true" if deleted else "false")
	strings.write_string(&builder, "}")
	return respond_success(strings.to_string(builder), req.request_id, auth_ctx_server_time(req))
}
