package channel

import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import httpc "odin_test:lib/httpc"

WhatsApp_Test_Fixture :: struct {
	child:                os.Process,
	ready, base, webhook: string,
	whatsapp:             WhatsApp_Adapter,
}

whatsapp_test_start :: proc(t: ^testing.T, f: ^WhatsApp_Test_Fixture, stub_response := "") -> bool {
	ok, message := httpc.init()
	if !testing.expect(t, ok, message) do return false
	f.ready = fmt.aprintf(
		"%s/.cache/heimdall-tests/whatsapp-%d-%d.ready",
		os.get_env("HOME", context.temp_allocator),
		os.get_pid(),
		time.tick_now(),
	)
	// A local sink lets the fake inject real signed webhooks while opening its
	// service windows. Both servers are children of this one fixture process.
	script := `import http from 'node:http'; import {writeFileSync} from 'node:fs'; import {createFakeWhatsApp} from './tools/fake_whatsapp/server.mjs'; let seen={}; const sink=http.createServer(async(q,s)=>{const chunks=[];for await(const c of q)chunks.push(c);if(q.method==='POST')seen={body:Buffer.concat(chunks).toString('utf8'),signature:q.headers['x-hub-signature-256']};s.setHeader('Content-Type','application/json');s.end(JSON.stringify(seen))}); sink.listen(0,'127.0.0.1',()=>{const sinkBase='http://127.0.0.1:'+sink.address().port;const f=process.argv[2]?http.createServer(async(q,s)=>{for await(const c of q){}s.writeHead(200,{'Content-Type':'application/json'});s.end(process.argv[2])}):createFakeWhatsApp({webhookUrl:sinkBase});f.listen(0,'127.0.0.1',()=>writeFileSync(process.argv[1],'http://127.0.0.1:'+f.address().port+'\n'+sinkBase))});`
	child, err := os.process_start({command = {"node", "--input-type=module", "-e", script, f.ready, stub_response}})
	if !testing.expect(t, err == nil) do return false
	f.child = child
	for _ in 0 ..< 250 {
		data, read_err := os.read_entire_file(f.ready, context.allocator)
		if read_err == nil {
			addresses := strings.split(string(data), "\n", context.temp_allocator)
			if len(addresses) != 2 {delete(data); continue}
			f.base = strings.clone(addresses[0])
			f.webhook = strings.clone(addresses[1])
			delete(data)
			f.whatsapp = whatsapp_test_config()
			f.whatsapp.api_base = f.base
			return true
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, false, "fake WhatsApp readiness timeout")
	return false
}

whatsapp_test_stop :: proc(f: ^WhatsApp_Test_Fixture) {
	if f.child.pid != 0 {_ = os.process_kill(f.child); _, _ = os.process_wait(f.child)}
	whatsapp_destroy(&f.whatsapp)
	if f.ready != "" {_ = os.remove(f.ready); delete(f.ready)}
	delete(f.base)
	delete(f.webhook)
}

whatsapp_test_config :: proc() -> WhatsApp_Adapter {
	return {
		access_token = "TEST-WA-TOKEN",
		app_secret = "test-app-secret",
		verify_token = "test-verify-token-0001",
		phone_number_id = "100000000000001",
		business_account_id = "200000000000002",
	}
}

whatsapp_test_control :: proc(t: ^testing.T, f: ^WhatsApp_Test_Fixture, method: string, value: $T) {
	base, _ := httpc.parse_url(f.base)
	resp, err := httpc.send(
		{
			method = .POST,
			url = base,
			path = {"_control", method},
			body = httpc.json_body(value, allocator = context.temp_allocator),
		},
	)
	defer httpc.response_destroy(&resp)
	testing.expectf(t, err == .None && resp.status == 200, "control %s: %d %v", method, resp.status, err)
}

whatsapp_test_get :: proc(t: ^testing.T, f: ^WhatsApp_Test_Fixture, method: string) -> json.Object {
	base, _ := httpc.parse_url(f.base)
	resp, err := httpc.send({url = base, path = {"_control", method}})
	defer httpc.response_destroy(&resp)
	testing.expect(t, err == .None && resp.status == 200)
	value, decode := json.parse(string(resp.body), allocator = context.temp_allocator)
	testing.expect(t, decode == .None)
	return whatsapp_object(value)
}

whatsapp_test_signature :: proc(body: string, secret := "test-app-secret") -> string {
	tag: [32]byte
	hmac.sum(.SHA256, tag[:], transmute([]byte)body, transmute([]byte)secret)
	encoded := hex.encode(tag[:], context.temp_allocator)
	return strings.concatenate({"sha256=", string(encoded)}, context.temp_allocator)
}

whatsapp_test_envelope :: proc(messages: string, extra := "") -> string {
	return strings.concatenate(
		{
			`{"object":"whatsapp_business_account","entry":[{"id":"200000000000002","changes":[{"field":"messages","value":{"metadata":{"phone_number_id":"100000000000001"},"messages":`,
			messages,
			extra,
			`}}]}]}`,
		},
		context.temp_allocator,
	)
}

whatsapp_test_message :: proc(kind, text: string) -> string {
	data: struct {
		from, from_user_id, id, timestamp, type: string,
		text:                                    struct {
			body: string,
		},
	}
	data.from = "15551230001"; data.from_user_id = "US.alice"; data.id = "wamid.X"; data.timestamp = "1763452800"; data.type = kind; data.text.body = text
	raw, _ := json.marshal(data, allocator = context.temp_allocator)
	return strings.concatenate({"[", string(raw), "]"}, context.temp_allocator)
}

whatsapp_test_parse :: proc(w: ^WhatsApp_Adapter, body: string) -> ([]Inbound, Push_Verdict) {
	return whatsapp_push_parse(w, whatsapp_test_signature(body), body)
}

@(test)
test_whatsapp_push_parse_text_fixture :: proc(t: ^testing.T) {
	w := whatsapp_test_config()
	batch, verdict := whatsapp_test_parse(&w, WHATSAPP_TEST_TEXT_FIXTURE)
	defer inbound_destroy_batch(batch)
	if !testing.expect(t, verdict == .Accepted && len(batch) == 1) do return
	row := batch[0]
	testing.expect(t, row.kind == .Text && row.text == "hi" && row.sender_display == "Alice")
	testing.expect(
		t,
		row.external_chat_id == "15551230001" &&
		row.external_user_id == "US.13491208655302741918" &&
		row.chat_is_private,
	)
	testing.expect(t, row.external_message_id == "wamid.HBgLMTY1MDM4Nzk0MzkVAgASGBQzQTRBNjU5OUFFRTAzODEwMTQ0RgA=")
	testing.expect(
		t,
		row.update_key ==
		strings.concatenate({"whatsapp:100000000000001:", row.external_message_id}, context.temp_allocator),
	)
	testing.expect(t, row.provider_time == "2025-11-18T08:00:00Z")
}

@(test)
test_whatsapp_signature_rules :: proc(t: ^testing.T) {
	w := whatsapp_test_config()
	body := WHATSAPP_TEST_TEXT_FIXTURE
	sig := whatsapp_test_signature(body)
	for bad in ([]string {
			"",
			fmt.tprintf("SHA256=%s", sig[7:]),
			"sha256=aa",
			sig[:70],
			fmt.tprintf("%s0", sig),
			fmt.tprintf("sha256=%s", strings.repeat("z", 64, context.temp_allocator)),
			whatsapp_test_signature(body, "wrong"),
		}) {
		rows, verdict := whatsapp_push_parse(&w, bad, body)
		inbound_destroy_batch(rows)
		testing.expect(t, verdict == .Bad_Signature && len(rows) == 0)
	}
	rows, verdict := whatsapp_push_parse(
		&w,
		fmt.tprintf("sha256=%s", strings.to_upper(sig[7:], context.temp_allocator)),
		body,
	)
	inbound_destroy_batch(rows)
	testing.expect(t, verdict == .Accepted)
	rows2, verdict2 := whatsapp_push_parse(&w, sig, fmt.tprintf("%s ", body))
	inbound_destroy_batch(rows2)
	testing.expect(t, verdict2 == .Bad_Signature)
	for malformed in ([]string{"{", `{"object":"other"}`, "null", "[]"}) {
		b, v := whatsapp_test_parse(&w, malformed)
		inbound_destroy_batch(b)
		testing.expect(t, v == .Bad_Payload)
	}
}

@(test)
test_whatsapp_signature_over_raw_escaped_unicode :: proc(t: ^testing.T) {
	w := whatsapp_test_config()
	raw := whatsapp_test_envelope(
		`[{"from":"15551230001","id":"wamid.U","type":"text","text":{"body":"\u0041\ud83c\udf0f"}}]`,
	)
	batch, verdict := whatsapp_test_parse(&w, raw)
	defer inbound_destroy_batch(batch)
	testing.expect(t, verdict == .Accepted && len(batch) == 1 && batch[0].text == "A🌏")
	reserialized, _ := strings.replace_all(raw, `\u0041`, "A", context.temp_allocator)
	b, v := whatsapp_push_parse(&w, whatsapp_test_signature(raw), reserialized)
	inbound_destroy_batch(b)
	testing.expect(t, v == .Bad_Signature)
}

@(test)
test_whatsapp_push_parse_kinds :: proc(t: ^testing.T) {
	w := whatsapp_test_config()
	for test in ([]struct {
			text: string,
			kind: Inbound_Kind,
			want: string,
		} {
			{"  cOnNeCt NiNjY  AbC  ", .Start, "abc"},
			{"Connect Ninjy", .Start, ""},
			{"Connect Ninjy\tABC", .Start, "abc"},
			{"Connect Ninjy\nABC", .Start, "abc"},
			{"Connect Ninjyish", .Text, "Connect Ninjyish"},
			{"Connect Ninjy ABC", .Start, "abc"},
			{" disconnect ", .Disconnect, ""},
			{" /DISCONNECT ", .Disconnect, ""},
			{" hi 🌏 ", .Text, " hi 🌏 "},
		}) {
		b, v := whatsapp_test_parse(&w, whatsapp_test_envelope(whatsapp_test_message("text", test.text)))
		if testing.expect(t, v == .Accepted && len(b) == 1) do testing.expect(t, b[0].kind == test.kind && b[0].text == test.want)
		inbound_destroy_batch(b)
	}
	for kind in ([]string {
			"reaction",
			"system",
			"edit",
			"revoke",
			"group",
			"image",
			"audio",
			"video",
			"document",
			"sticker",
			"location",
			"contacts",
			"interactive",
			"button",
			"order",
			"unsupported",
			"unknown",
		}) {
		b, v := whatsapp_test_parse(&w, whatsapp_test_envelope(whatsapp_test_message(kind, "")))
		skip := kind == "reaction" || kind == "system" || kind == "edit" || kind == "revoke" || kind == "group"
		testing.expect(t, v == .Accepted && len(b) == (0 if skip else 1))
		if len(b) > 0 do testing.expect(t, b[0].kind == .Unsupported && b[0].text == "")
		inbound_destroy_batch(b)
	}
	status := `,"statuses":[{"id":"wamid.O","status":"failed","timestamp":"1763452800","recipient_user_id":"US.alice","errors":[{"code":131047}]},{"id":"wamid.D","status":"delivered"}],"errors":[{"code":100}]`
	b, v := whatsapp_test_parse(&w, whatsapp_test_envelope("[]", status))
	defer inbound_destroy_batch(b)
	if testing.expect(t, v == .Accepted && len(b) == 1) {
		testing.expect(
			t,
			b[0].kind == .Delivery_Failed && b[0].provider_code == 131047 && b[0].external_chat_id == "US.alice",
		)
		testing.expect(
			t,
			b[0].update_key == "whatsapp:100000000000001:failed:wamid.O" &&
			b[0].external_user_id == "" &&
			!b[0].chat_is_private &&
			b[0].text == "",
		)
	}
	// Invalid timestamps and incomplete messages cannot fabricate identifiers.
	b2, v2 := whatsapp_test_parse(
		&w,
		whatsapp_test_envelope(
			`[{"id":"missing-sender"},{"from":"1"},{"from":"1","id":"x","type":"text","timestamp":"no"}]`,
		),
	)
	defer inbound_destroy_batch(b2)
	testing.expect(t, v2 == .Accepted && len(b2) == 1 && b2[0].provider_time == "" && b2[0].sender_display == "+1")
}

@(test)
test_whatsapp_foreign_account_and_number_verdicts :: proc(t: ^testing.T) {
	w := whatsapp_test_config()
	local := whatsapp_test_envelope(whatsapp_test_message("text", "hi"))
	for field in ([]string{"200000000000002", "100000000000001"}) {
		body, _ := strings.replace_all(local, field, "foreign", context.temp_allocator)
		b, v := whatsapp_test_parse(&w, body)
		testing.expect(t, v == .Foreign_Account && len(b) == 0)
		inbound_destroy_batch(b)
	}
	mixed, _ := strings.replace_all(local, `"entry":[`, `"entry":[{"id":"foreign"},`, context.temp_allocator)
	b, v := whatsapp_test_parse(&w, mixed)
	testing.expect(t, v == .Accepted && len(b) == 1)
	inbound_destroy_batch(b)
	statusOnly := whatsapp_test_envelope("[]", `,"statuses":[{"status":"delivered"}]`)
	b2, v2 := whatsapp_test_parse(&w, statusOnly)
	inbound_destroy_batch(b2)
	testing.expect(t, v2 == .Accepted && len(b2) == 0)
}

@(test)
test_whatsapp_bsuid_only_message :: proc(t: ^testing.T) {
	f: WhatsApp_Test_Fixture
	defer whatsapp_test_stop(&f)
	if !whatsapp_test_start(t, &f) do return
	whatsapp_test_control(t, &f, "inject", struct {
		from, user_id: string,
		omit_from:     bool,
	}{"15551230001", "US.alice", true})
	base, _ := httpc.parse_url(f.webhook)
	resp, transport := httpc.send({url = base})
	defer httpc.response_destroy(&resp)
	captured: struct {
		body, signature: string,
	}
	if !testing.expect(t, transport == .None && json.unmarshal(resp.body, &captured, allocator = context.temp_allocator) == nil) do return
	b, v := whatsapp_push_parse(&f.whatsapp, captured.signature, captured.body)
	defer inbound_destroy_batch(b)
	if testing.expect(t, v == .Accepted && len(b) == 1) do testing.expect(t, b[0].external_chat_id == "US.alice" && b[0].external_user_id == "US.alice" && b[0].sender_display == "Alice")
	b2, _ := whatsapp_test_parse(
		&f.whatsapp,
		whatsapp_test_envelope(`[{"from_user_id":"US.alice","id":"x","type":"text"}]`),
	)
	defer inbound_destroy_batch(b2)
	testing.expect(t, len(b2) == 1 && b2[0].sender_display == "WhatsApp user")
}

@(test)
test_whatsapp_identity_and_pairing_url :: proc(t: ^testing.T) {
	f: WhatsApp_Test_Fixture
	defer whatsapp_test_stop(&f)
	if !whatsapp_test_start(t, &f) do return
	a := whatsapp_adapter(&f.whatsapp)
	id, err := a.identity(a.ctx)
	testing.expect(t, err.kind == .None && id.bot_user_id == "100000000000001" && id.bot_username == "15550100001")
	f.whatsapp.api_base = "http://127.0.0.1:1"
	cached, cache_err := a.identity(a.ctx)
	testing.expect(t, cached == id && cache_err.kind == .None)
	url := a.pairing_url(a.ctx, id, "abc123"); defer delete(url)
	text := a.pairing_text(a.ctx, "abc123"); defer delete(text)
	testing.expect(
		t,
		url == "https://wa.me/15550100001?text=Connect%20Ninjy%20abc123" && text == "Connect Ninjy abc123",
	)
	testing.expect(t, a.poll == nil && a.reply_window_ms == 86_400_000 && a.provider == "whatsapp")
	testing.expect(t, a.push_challenge(a.ctx, "subscribe", f.whatsapp.verify_token))
	testing.expect(
		t,
		!a.push_challenge(a.ctx, "other", f.whatsapp.verify_token) && !a.push_challenge(a.ctx, "subscribe", "wrong"),
	)
}

@(test)
test_whatsapp_send_text_and_address_forms :: proc(t: ^testing.T) {
	f: WhatsApp_Test_Fixture
	defer whatsapp_test_stop(&f)
	if !whatsapp_test_start(t, &f) do return
	whatsapp_test_control(t, &f, "inject", struct {
		from, user_id: string,
	}{"15551230001", "US.alice"})
	for chat in ([]string{"15551230001", "US.alice"}) {
		id, err := whatsapp_send_text(&f.whatsapp, chat, "echo: hi 🌏")
		testing.expect(t, err.kind == .None && strings.has_prefix(id, "wamid.FAKE"))
		delete(id)
	}
	for invalid in ([]string{"", strings.repeat("a", 4001, context.temp_allocator), "\xff"}) {
		id, err := whatsapp_send_text(&f.whatsapp, "15551230001", invalid)
		delete(id)
		testing.expect(t, err.kind == .Invalid_Request && err.message == "invalid whatsapp message")
	}
	sent := whatsapp_array(whatsapp_test_get(t, &f, "sent")["messages"])
	if testing.expect(t, len(sent) == 2) {
		testing.expect(t, whatsapp_string(whatsapp_object(sent[0])["to"]) == "15551230001")
		testing.expect(t, whatsapp_string(whatsapp_object(sent[1])["to"]) == "US.alice")
		testing.expect(t, whatsapp_string(whatsapp_object(sent[0])["text"]) == "echo: hi 🌏")
	}
	phone := whatsapp_address("15551230001")
	bsuid := whatsapp_address("US.alice")
	testing.expect(t, whatsapp_string(phone["to"]) == "+15551230001" && phone["recipient"] == nil)
	testing.expect(t, whatsapp_string(bsuid["recipient"]) == "US.alice" && bsuid["to"] == nil)
}

@(test)
test_whatsapp_mark_read_and_react_bodies :: proc(t: ^testing.T) {
	f: WhatsApp_Test_Fixture
	defer whatsapp_test_stop(&f)
	if !whatsapp_test_start(t, &f) do return
	a := whatsapp_adapter(&f.whatsapp)
	testing.expect(t, a.mark_read(a.ctx, "15551230001", "wamid.IN").kind == .None)
	testing.expect(t, a.react(a.ctx, "15551230001", "wamid.IN", "👀").kind == .None)
	testing.expect(t, a.react(a.ctx, "US.alice", "wamid.B", "👀").kind == .None)
	testing.expect(
		t,
		a.mark_read(a.ctx, "1", "").kind == .Invalid_Request &&
		a.react(a.ctx, "1", "", "👀").kind == .Invalid_Request,
	)
	reads := whatsapp_array(whatsapp_test_get(t, &f, "reads")["reads"])
	if testing.expect(t, len(reads) == 1) do testing.expect(t, whatsapp_string(whatsapp_object(reads[0])["message_id"]) == "wamid.IN")
	sent := whatsapp_array(whatsapp_test_get(t, &f, "sent")["messages"])
	if testing.expect(t, len(sent) == 2) {
		row := whatsapp_object(sent[0])
		testing.expect(
			t,
			whatsapp_string(row["reaction"]) == "👀" && whatsapp_string(row["reaction_message_id"]) == "wamid.IN",
		)
		testing.expect(t, whatsapp_string(whatsapp_object(sent[1])["to"]) == "US.alice")
	}
}

@(test)
test_whatsapp_reengage_template_body :: proc(t: ^testing.T) {
	f: WhatsApp_Test_Fixture
	defer whatsapp_test_stop(&f)
	if !whatsapp_test_start(t, &f) do return
	whatsapp_test_control(t, &f, "templates", struct {
		approved: []string,
	}{{"ninjy_reply_waiting"}})
	id, err := whatsapp_send_reengage(&f.whatsapp, "15551230001")
	defer delete(id)
	testing.expect(t, err.kind == .None && id != "")
	sent := whatsapp_array(whatsapp_test_get(t, &f, "sent")["messages"])
	if !testing.expect(t, len(sent) == 1) do return
	template := whatsapp_object(whatsapp_object(sent[0])["template"])
	testing.expect(t, whatsapp_string(template["name"]) == WHATSAPP_REENGAGE_TEMPLATE_NAME)
	testing.expect(t, whatsapp_string(whatsapp_object(template["language"])["code"]) == "en")
	testing.expect(t, template["components"] == nil)
}

WhatsApp_Test_Error_Row :: struct {
	status, code: int,
	want:         Channel_Error_Kind,
	retry:        i64,
}
WHATSAPP_TEST_ERRORS := []WhatsApp_Test_Error_Row {
	{500, 131047, .Transient, 0},
	{503, 0, .Transient, 0},
	{400, 131047, .Window_Closed, 0},
	{400, 132001, .Template_Unavailable, 0},
	{400, 132015, .Template_Unavailable, 0},
	{400, 132016, .Template_Unavailable, 0},
	{400, 131056, .Rate_Limited, 6000},
	{400, 130429, .Rate_Limited, 5000},
	{429, 0, .Rate_Limited, 5000},
	{400, 190, .Unauthorized, 0},
	{400, 368, .Unauthorized, 0},
	{401, 0, .Unauthorized, 0},
	{400, 131026, .Chat_Unavailable, 0},
	{400, 131030, .Chat_Unavailable, 0},
	{400, 100, .Invalid_Request, 0},
	{400, 131009, .Invalid_Request, 0},
	{400, 131062, .Invalid_Request, 0},
	{400, 999, .Invalid_Request, 0},
}

@(test)
test_whatsapp_error_mapping :: proc(t: ^testing.T) {
	f: WhatsApp_Test_Fixture
	defer whatsapp_test_stop(&f)
	if !whatsapp_test_start(t, &f) do return
	for row in WHATSAPP_TEST_ERRORS {
		whatsapp_test_control(t, &f, "fail", struct {
			type:                     string,
			http_status, code, count: int,
		}{"text", row.status, row.code, 1})
		id, err := whatsapp_send_text(&f.whatsapp, "1", "hi")
		delete(id)
		testing.expectf(
			t,
			err.kind == row.want && err.provider_code == row.code && err.retry_after_ms == row.retry,
			"%v -> %v",
			row,
			err,
		)
	}
	testing.expect(
		t,
		whatsapp_error(0, .Timeout, 0).kind == .Transient && whatsapp_error(0, .Connect, 0).kind == .Transient,
	)
	testing.expect(t, whatsapp_error(0, .Aborted, 0).kind == .Aborted)
	cancel := true
	r, err := whatsapp_request(&f.whatsapp, .GET, nil, nil, nil, 1000, &cancel)
	httpc.response_destroy(&r)
	testing.expect(t, err.kind == .Aborted)
	// A valid 200 JSON response lacking expected fields must still fail.
	stub: WhatsApp_Test_Fixture
	defer whatsapp_test_stop(&stub)
	if !whatsapp_test_start(t, &stub, `{"success":false,"messages":[],"display_phone_number":""}`) do return
	id2, err2 := whatsapp_send_text(&stub.whatsapp, "1", "hi")
	delete(id2)
	testing.expect(t, err2.kind == .Transient && err2.message == "invalid whatsapp response")
	testing.expect(t, whatsapp_mark_read(&stub.whatsapp, "1", "id").kind == .Transient)
	_, identity_err := whatsapp_identity(&stub.whatsapp)
	testing.expect(t, identity_err.kind == .Transient && identity_err.message == "invalid whatsapp identity")
}

@(test)
test_whatsapp_failure_kind_matches_request_mapping :: proc(t: ^testing.T) {
	for row in WHATSAPP_TEST_ERRORS {
		if row.code == 0 || row.status >= 500 do continue
		testing.expect(t, whatsapp_failure_kind(row.code) == row.want)
		testing.expect(t, whatsapp_error(row.status, .None, row.code).kind == whatsapp_failure_kind(row.code))
	}
	testing.expect(t, whatsapp_failure_kind(0) == .Transient && whatsapp_failure_kind(999) == .Invalid_Request)
}

@(test)
test_whatsapp_secrets_never_in_error_message :: proc(t: ^testing.T) {
	f: WhatsApp_Test_Fixture
	defer whatsapp_test_stop(&f)
	if !whatsapp_test_start(t, &f) do return
	for row in WHATSAPP_TEST_ERRORS {
		whatsapp_test_control(t, &f, "fail", struct {
			type:                     string,
			http_status, code, count: int,
		}{"text", row.status, row.code, 1})
		id, err := whatsapp_send_text(&f.whatsapp, "1", "secret message")
		delete(id)
		testing.expect(
			t,
			!strings.contains(err.message, f.whatsapp.access_token) &&
			!strings.contains(err.message, f.whatsapp.app_secret) &&
			!strings.contains(err.message, "secret message"),
		)
	}
	for base in ([]string{"bad TEST-WA-TOKEN test-app-secret", "http://127.0.0.1:1"}) {
		f.whatsapp.api_base = base
		id, err := whatsapp_send_text(&f.whatsapp, "1", "hi")
		delete(id)
		testing.expect(
			t,
			err.kind != .None &&
			!strings.contains(err.message, f.whatsapp.access_token) &&
			!strings.contains(err.message, f.whatsapp.app_secret),
		)
	}
	stub: WhatsApp_Test_Fixture
	defer whatsapp_test_stop(&stub)
	if !whatsapp_test_start(t, &stub, `{"error":{"code":190,"message":"TEST-WA-TOKEN test-app-secret secret message"}}`) do return
	id, err := whatsapp_send_text(&stub.whatsapp, "1", "hi")
	delete(id)
	testing.expect(t, err.kind == .Unauthorized && err.message == "whatsapp request failed")
}

@(test)
test_whatsapp_uses_pinned_graph_version :: proc(t: ^testing.T) {
	f: WhatsApp_Test_Fixture
	defer whatsapp_test_stop(&f)
	if !whatsapp_test_start(t, &f) do return
	_, _ = whatsapp_identity(&f.whatsapp)
	_ = whatsapp_mark_read(&f.whatsapp, "1", "wamid.X")
	_ = whatsapp_react(&f.whatsapp, "1", "wamid.X", "👀")
	id, _ := whatsapp_send_reengage(&f.whatsapp, "1"); delete(id)
	id2, _ := whatsapp_send_text(&f.whatsapp, "1", "hi"); delete(id2)
	versions := whatsapp_array(whatsapp_test_get(t, &f, "versions")["versions"])
	testing.expect(t, len(versions) == 1 && whatsapp_string(versions[0]) == WHATSAPP_GRAPH_VERSION)
}

WHATSAPP_TEST_TEXT_FIXTURE :: `{
  "object": "whatsapp_business_account",
  "entry": [{
    "id": "200000000000002",
    "changes": [{
      "field": "messages",
      "value": {
        "messaging_product": "whatsapp",
        "metadata": {"display_phone_number": "15550100001", "phone_number_id": "100000000000001"},
        "contacts": [{"profile": {"name": "Alice"}, "wa_id": "15551230001", "user_id": "US.13491208655302741918"}],
        "messages": [{
          "from": "15551230001",
          "from_user_id": "US.13491208655302741918",
          "id": "wamid.HBgLMTY1MDM4Nzk0MzkVAgASGBQzQTRBNjU5OUFFRTAzODEwMTQ0RgA=",
          "timestamp": "1763452800",
          "type": "text",
          "text": {"body": "hi"}
        }]
      }
    }]
  }]
}
`
