package http
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import channel "odin_test:hub/service/channel"
import bots_service "odin_test:hub/service/bots"

webhook_test_parse :: proc(ctx: rawptr, signature_header, raw_body: string, allocator := context.allocator) -> ([]channel.Inbound, channel.Push_Verdict) {
	if signature_header != "valid" do return nil, .Bad_Signature
	switch raw_body {
	case "bad": return nil, .Bad_Payload
	case "foreign": return nil, .Foreign_Account
	case "empty": return nil, .Accepted
	}
	batch := make([]channel.Inbound, 1, allocator)
	batch[0] = {update_key = "wa:http", kind = .Text, text = "test", external_chat_id = "111"}
	return batch, .Accepted
}
webhook_test_challenge :: proc(ctx: rawptr, mode, verify_token: string) -> bool {return mode == "subscribe" && verify_token == "correct"}
webhook_test_adapter :: proc() -> channel.Channel_Adapter {
	return {provider = "whatsapp", push_parse = webhook_test_parse, push_challenge = webhook_test_challenge}
}
webhook_test_request :: proc(body := "event", signature := "valid") -> Request {
	headers := make([]contracts.HTTP_Header,1,context.temp_allocator)
	headers[0] = {"x-hub-signature-256",signature}
	return {method = "POST", remote_addr = "127.0.0.1:1234", body = body, headers = headers}
}
@(test)
test_webhook_404_when_not_configured_or_experiment_off :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t, false); defer bot_http_destroy(f)
	a := webhook_test_adapter()
	h := Bot_Webhook_Handlers{bots = &f.service}
	defer webhook_rate_destroy(&h.limiter)
	for method in ([]string{"GET", "POST"}) {
		testing.expect_value(t, whatsapp_webhook_handler(&h, {method = method}).status, 404)
		f.service.whatsapp = &a
		testing.expect_value(t, whatsapp_webhook_handler(&h, {method = method}).status, 404)
		f.service.whatsapp = nil
	}
}
@(test)
test_webhook_get_rules :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	a := webhook_test_adapter(); f.service.whatsapp = &a
	h := Bot_Webhook_Handlers{bots = &f.service}; defer webhook_rate_destroy(&h.limiter)
	for tc in ([]struct {query: string, status: int, code: string}{
		{"hub.mode=subscribe&hub.verify_token=correct",400,"challenge_invalid"},
		{"hub.challenge=%3Cscript%3E&hub.mode=subscribe&hub.verify_token=correct",400,"challenge_invalid"},
		{"hub.challenge=abc+def&hub.mode=subscribe&hub.verify_token=correct",400,"challenge_invalid"},
		{"hub.challenge=1&hub.mode=bad&hub.verify_token=correct",403,"verify_token_mismatch"},
		{"hub.challenge=1&hub.mode=subscribe&hub.verify_token=wrong",403,"verify_token_mismatch"},
		{"hub.challenge=abc._-123&hub.mode=subscribe&hub.verify_token=correct",200,""},
		{"hub.challenge=%31&hub.mode=subscribe&hub.verify_token=correct",200,""},
	}) {
		resp := whatsapp_webhook_handler(&h, {method = "GET", query = tc.query})
		testing.expect_value(t, resp.status, tc.status)
		if tc.code != "" do testing.expect(t, strings.contains(resp.body, tc.code))
		if tc.status == 200 do testing.expect_value(t, resp.content_type, "text/plain")
	}
	exact := whatsapp_webhook_handler(&h, {method = "GET", query = "hub.challenge=%31._-&hub.mode=subscribe&hub.verify_token=correct"})
	testing.expect_value(t, exact.body, "1._-")
	boundary := strings.concatenate({"hub.challenge=",strings.repeat("a",128,context.temp_allocator),"&hub.mode=subscribe&hub.verify_token=correct"},context.temp_allocator)
	testing.expect_value(t, whatsapp_webhook_handler(&h, {method = "GET", query = boundary}).status, 200)
	long := strings.concatenate({"hub.challenge=",strings.repeat("a",129,context.temp_allocator)},context.temp_allocator)
	testing.expect_value(t, whatsapp_webhook_handler(&h, {method = "GET", query = long}).status, 400)
	h.limiter.gets = WHATSAPP_WEBHOOK_GET_PER_MINUTE
	testing.expect_value(t, whatsapp_webhook_handler(&h, {method = "GET"}).status, 429)
}
@(test)
test_webhook_post_rules :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	a := webhook_test_adapter(); f.service.whatsapp = &a
	rt: bots_service.Bots_Runtime
	h := Bot_Webhook_Handlers{bots = &f.service, runtime = &rt}; defer webhook_rate_destroy(&h.limiter)
	oversized := strings.repeat("x",WHATSAPP_WEBHOOK_MAX_BODY_BYTES+1,context.temp_allocator)
	resp := whatsapp_webhook_handler(&h, webhook_test_request(oversized, "invalid"))
	testing.expect(t, resp.status == 400 && strings.contains(resp.body, "webhook_body_too_large"))
	resp = whatsapp_webhook_handler(&h, webhook_test_request("bad","invalid"))
	testing.expect(t, resp.status == 401 && strings.contains(resp.body, "webhook_signature_invalid"))
	for body in ([]string{"bad","foreign","empty","event"}) {
		resp = whatsapp_webhook_handler(&h, webhook_test_request(body))
		testing.expect(t, resp.status == 200 && strings.contains(resp.body, "\"received\":true"))
	}
	testing.expect(t, rt.intake_signal)
	h.limiter.posts = WHATSAPP_WEBHOOK_POST_PER_MINUTE
	testing.expect_value(t, whatsapp_webhook_handler(&h, webhook_test_request()).status, 429)
}
@(test)
test_webhook_bad_signature_ip_limit :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	a := webhook_test_adapter(); f.service.whatsapp = &a
	h := Bot_Webhook_Handlers{bots = &f.service}; defer webhook_rate_destroy(&h.limiter)
	for _ in 0..<20 do testing.expect_value(t, whatsapp_webhook_handler(&h, webhook_test_request("","invalid")).status, 401)
	testing.expect_value(t, whatsapp_webhook_handler(&h, webhook_test_request()).status, 429)
	req := webhook_test_request(); req.remote_addr = "127.0.0.2:1234"
	testing.expect_value(t, whatsapp_webhook_handler(&h, req).status, 200)
	testing.expect(t, webhook_rate_admit(&h.limiter,.Post,"127.0.0.1",h.limiter.window_start_s+60))
}
@(test)
test_webhook_global_rate_limit :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	l: Webhook_Rate_Limiter; defer webhook_rate_destroy(&l)
	for _ in 0..<WHATSAPP_WEBHOOK_POST_PER_MINUTE do testing.expect(t, webhook_rate_admit(&l,.Post,"",120))
	testing.expect(t, !webhook_rate_admit(&l,.Post,"other",120))
	for _ in 0..<WHATSAPP_WEBHOOK_GET_PER_MINUTE do testing.expect(t, webhook_rate_admit(&l,.Get,"",120))
	testing.expect(t, !webhook_rate_admit(&l,.Get,"other",120))
	testing.expect(t, webhook_rate_log_once(&l,.Rate_Limited,120))
	testing.expect(t, !webhook_rate_log_once(&l,.Rate_Limited,120))
	testing.expect(t, webhook_rate_admit(&l,.Post,"",180))
	testing.expect(t, webhook_rate_log_once(&l,.Rate_Limited,180))
	webhook_rate_note_bad_signature(&l,"",180)
	testing.expect_value(t, l.bad_by_ip["unknown"], 1)
}
@(test)
test_webhook_store_failure_returns_503 :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	a := webhook_test_adapter(); f.service.whatsapp = &a
	f.bot_repo.push_events_insert = nil
	rt: bots_service.Bots_Runtime
	h := Bot_Webhook_Handlers{bots = &f.service, runtime = &rt}; defer webhook_rate_destroy(&h.limiter)
	resp := whatsapp_webhook_handler(&h, webhook_test_request())
	testing.expect(t, resp.status == 503 && strings.contains(resp.body, "webhook_store_failed") && !rt.intake_signal)
}
@(test)
test_webhook_foreign_account_logged_once_per_window :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	a := webhook_test_adapter(); f.service.whatsapp = &a
	h := Bot_Webhook_Handlers{bots = &f.service}; defer webhook_rate_destroy(&h.limiter)
	for _ in 0..<2 do testing.expect_value(t, whatsapp_webhook_handler(&h, webhook_test_request("foreign")).status, 200)
	now := i64(time.tick_since(time.Tick{}))/i64(time.Second)
	testing.expect(t, !webhook_rate_log_once(&h.limiter,.Foreign_Account,now))
	// Simulate the next fixed window without sleeping.
	h.limiter.window_start_s -= 60
	testing.expect_value(t, whatsapp_webhook_handler(&h, webhook_test_request("foreign")).status, 200)
	testing.expect(t, !webhook_rate_log_once(&h.limiter,.Foreign_Account,now))
}
@(test)
test_webhook_stores_before_200 :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := bot_http_fixture(t); defer bot_http_destroy(f)
	a := webhook_test_adapter(); f.service.whatsapp = &a
	rt: bots_service.Bots_Runtime
	h := Bot_Webhook_Handlers{bots = &f.service,runtime = &rt}; defer webhook_rate_destroy(&h.limiter)
	testing.expect_value(t, whatsapp_webhook_handler(&h, webhook_test_request()).status, 200)
	rows, err := iface.push_events_pending(&f.bot_repo,"whatsapp",50)
	defer {for &r in rows do domain.channel_push_event_destroy(&r); delete(rows)}
	testing.expect(t, err.code == .None && len(rows) == 1 && rows[0].body == "test" && rt.intake_signal)
}
