package http

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import bots_service "odin_test:hub/service/bots"
import device_auth "odin_test:hub/service/device_auth"

WHATSAPP_WEBHOOK_MAX_BODY_BYTES :: 4 << 20
WHATSAPP_WEBHOOK_POST_PER_MINUTE :: 1200
WHATSAPP_WEBHOOK_GET_PER_MINUTE :: 120
WHATSAPP_WEBHOOK_BAD_SIGNATURE_PER_IP :: 20
WHATSAPP_WEBHOOK_CHALLENGE_MAX_BYTES :: 128

Bot_Webhook_Handlers :: struct {
	bots: ^bots_service.Bots_Service,
	runtime: ^bots_service.Bots_Runtime,
	trusted_cidrs: []string,
	limiter: Webhook_Rate_Limiter,
}
Webhook_Request_Kind :: enum { Get, Post }
Webhook_Log_Once :: enum { Rate_Limited, Foreign_Account }
Webhook_Rate_Limiter :: struct {
	mutex: sync.Mutex,
	window_start_s: i64,
	posts, gets: int,
	bad_by_ip: map[string]int,
	logged: bit_set[Webhook_Log_Once],
}

// Called only under mutex; reset and release all heap-owned keys together.
webhook_rate_window :: proc(l: ^Webhook_Rate_Limiter, now_s: i64) {
	start := now_s / 60 * 60
	if start == l.window_start_s do return
	for k in l.bad_by_ip do delete(k, runtime.heap_allocator())
	clear(&l.bad_by_ip)
	l.window_start_s = start
	l.posts = 0
	l.gets = 0
	l.logged = {}
}
webhook_rate_log_once :: proc(l: ^Webhook_Rate_Limiter, which: Webhook_Log_Once, now_s: i64) -> bool {
	sync.mutex_lock(&l.mutex)
	defer sync.mutex_unlock(&l.mutex)
	webhook_rate_window(l, now_s)
	if which in l.logged do return false
	l.logged += {which}
	return true
}
webhook_rate_admit :: proc(l: ^Webhook_Rate_Limiter, kind: Webhook_Request_Kind, ip: string, now_s: i64) -> bool {
	sync.mutex_lock(&l.mutex)
	defer sync.mutex_unlock(&l.mutex)
	webhook_rate_window(l, now_s)
	key := ip if ip != "" else "unknown"
	switch kind {
	case .Get:
		if l.gets >= WHATSAPP_WEBHOOK_GET_PER_MINUTE do return false
		l.gets += 1
	case .Post:
		if l.posts >= WHATSAPP_WEBHOOK_POST_PER_MINUTE || l.bad_by_ip[key] >= WHATSAPP_WEBHOOK_BAD_SIGNATURE_PER_IP do return false
		l.posts += 1
	}
	return true
}
webhook_rate_note_bad_signature :: proc(l: ^Webhook_Rate_Limiter, ip: string, now_s: i64) {
	sync.mutex_lock(&l.mutex)
	defer sync.mutex_unlock(&l.mutex)
	webhook_rate_window(l, now_s)
	key := ip if ip != "" else "unknown"
	if l.bad_by_ip == nil do l.bad_by_ip = make(map[string]int, runtime.heap_allocator())
	if n, ok := l.bad_by_ip[key]; ok {l.bad_by_ip[key] = n + 1} else {
		l.bad_by_ip[strings.clone(key, runtime.heap_allocator())] = 1
	}
}
webhook_rate_destroy :: proc(l: ^Webhook_Rate_Limiter) {
	sync.mutex_lock(&l.mutex)
	defer sync.mutex_unlock(&l.mutex)
	for k in l.bad_by_ip do delete(k, runtime.heap_allocator())
	delete(l.bad_by_ip)
	l.bad_by_ip = nil
}
whatsapp_webhook_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bot_Webhook_Handlers)(ctx)
	if !bots_service.bots_push_enabled(h.bots, "whatsapp") do return respond_error(bots_service.bots_detail_error(.Not_Found, "not_found"), req.request_id)
	now_s := i64(time.tick_since(time.Tick{})) / i64(time.Second)
	ip := device_auth.resolve_client_ip(req.remote_addr, header_value(req.headers, "X-Forwarded-For"), h.trusted_cidrs)
	kind := Webhook_Request_Kind.Post
	if req.method == "GET" do kind = .Get
	if !webhook_rate_admit(&h.limiter, kind, ip, now_s) {
		if webhook_rate_log_once(&h.limiter, .Rate_Limited, now_s) do fmt.println("bots: whatsapp webhook rejected reason=rate_limited")
		return respond_error(bots_service.bots_detail_error(.Rate_Limited, "rate_limited"), req.request_id)
	}
	if req.method == "GET" {
		challenge := query_value(req.query, "hub.challenge")
		valid := len(challenge) > 0 && len(challenge) <= WHATSAPP_WEBHOOK_CHALLENGE_MAX_BYTES
		for c in transmute([]u8)challenge {
			if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '.' || c == '_' || c == '-') do valid = false
		}
		if !valid do return respond_error(bots_service.bots_detail_error(.Validation_Failed, "challenge_invalid"), req.request_id)
		if !bots_service.bots_push_challenge(h.bots, "whatsapp", query_value(req.query, "hub.mode"), query_value(req.query, "hub.verify_token")) do return respond_error(bots_service.bots_detail_error(.Forbidden, "verify_token_mismatch"), req.request_id)
		return {status = 200, content_type = "text/plain", body = challenge}
	}
	if len(req.body) > WHATSAPP_WEBHOOK_MAX_BODY_BYTES do return respond_error(bots_service.bots_detail_error(.Validation_Failed, "webhook_body_too_large"), req.request_id)
	result, _, _ := bots_service.bots_push_receive(h.bots, "whatsapp", header_value(req.headers, "X-Hub-Signature-256"), req.body)
	switch result {
	case .Bad_Signature:
		webhook_rate_note_bad_signature(&h.limiter, ip, now_s)
		fmt.println("bots: whatsapp webhook rejected reason=bad_signature")
		return respond_error(bots_service.bots_detail_error(.Unauthenticated, "webhook_signature_invalid"), req.request_id)
	case .Bad_Payload: fmt.println("bots: whatsapp webhook ignored reason=bad_payload")
	case .Foreign_Account:
		if webhook_rate_log_once(&h.limiter, .Foreign_Account, now_s) do fmt.println("bots: whatsapp webhook ignored reason=foreign_account")
	case .Store_Failed: return respond_error(bots_service.bots_detail_error(.Provider_Unavailable, "webhook_store_failed"), req.request_id)
	case .Not_Configured: return respond_error(bots_service.bots_detail_error(.Not_Found, "not_found"), req.request_id)
	case .Stored: bots_service.bots_runtime_signal_intake(h.runtime)
	}
	return respond_success("{\"received\":true}", req.request_id, auth_ctx_server_time(req))
}
