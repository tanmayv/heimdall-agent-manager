package channel

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import httpc "odin_test:lib/httpc"

Telegram_Test_Fixture :: struct {
	child: os.Process,
	ready, base: string,
	telegram: Telegram_Adapter,
}

telegram_test_start :: proc(t: ^testing.T, f: ^Telegram_Test_Fixture) -> bool {
	ok, message := httpc.init()
	if !testing.expect(t, ok, message) do return false
	f.ready = fmt.aprintf("%s/.cache/heimdall-tests/telegram-%d-%d.ready", os.get_env("HOME", context.temp_allocator), os.get_pid(), time.tick_now())
	child, err := os.process_start({command = {"node", "tools/fake_telegram/server.mjs", "--port", "0", "--ready-file", f.ready}})
	if !testing.expect(t, err == nil, "fake Telegram starts") do return false
	f.child = child
	for _ in 0..<250 {
		data, read_err := os.read_entire_file(f.ready, context.allocator)
		if read_err == nil {
			f.base = string(data)
			f.telegram = {token = "TEST:FAKE", api_base = f.base}
			return true
		}
		time.sleep(20*time.Millisecond)
	}
	testing.expect(t, false, "fake Telegram readiness timeout")
	return false
}

telegram_test_stop :: proc(f: ^Telegram_Test_Fixture) {
	if f.child.pid != 0 { _ = os.process_kill(f.child); _, _ = os.process_wait(f.child) }
	telegram_destroy(&f.telegram)
	if f.ready != "" { _ = os.remove(f.ready); delete(f.ready) }
	delete(f.base)
}

telegram_test_control :: proc(t: ^testing.T, f: ^Telegram_Test_Fixture, method: string, value: $T) {
	base, _ := httpc.parse_url(f.base)
	resp, err := httpc.send({method = .POST, url = base, path = {"_control", method}, body = httpc.json_body(value, allocator = context.temp_allocator)})
	defer httpc.response_destroy(&resp)
	testing.expectf(t, err == .None && resp.status == 200, "control %s status %d error %v", method, resp.status, err)
}

@(test)
test_telegram_maps_updates :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	values := []string{
		`{"chat_id":111,"from_id":222,"username":"alice","text":"/start   code  "}`,
		`{"chat_id":111,"from_id":222,"text":"/start","first_name":"Alice"}`,
		`{"chat_id":111,"from_id":222,"text":"/disconnect"}`,
		`{"chat_id":111,"from_id":222,"text":"hi 🌏"}`,
		`{"chat_id":111,"from_id":222}`,
		`{"chat_id":-111,"from_id":222,"text":"group","chat_type":"group"}`,
		`{"raw_update":{"edited_message":{}}}`,
	}
	base, _ := httpc.parse_url(f.base)
	for value in values {
		resp, err := httpc.send({method = .POST, url = base, path = {"_control","inject"}, body = httpc.raw_body("application/json", transmute([]byte)value)})
		testing.expect(t, err == .None && resp.status == 200)
		httpc.response_destroy(&resp)
	}
	a := telegram_adapter(&f.telegram)
	batch, next, err := a.poll(a.ctx, "", nil)
	defer inbound_destroy_batch(batch)
	defer delete(next)
	if !testing.expectf(t, err.kind == .None && len(batch) == 6, "mapped rows: %d, %v", len(batch), err) do return
	testing.expect(t, next == "8", "skipped update advances cursor")
	kinds := []Inbound_Kind{.Start,.Start,.Disconnect,.Text,.Unsupported,.Unsupported}
	for row, i in batch {
		testing.expect(t, row.kind == kinds[i])
		testing.expect(t, row.update_key == fmt.tprintf("telegram:123456:%d",i+1))
		testing.expect(t, row.external_user_id == "222")
		testing.expect(t, row.external_message_id == fmt.tprintf("%d", i+1))
	}
	testing.expect(t, batch[0].text == "code" && batch[0].sender_display == "@alice")
	testing.expect(t, batch[1].text == "" && batch[1].sender_display == "Alice")
	testing.expect(t, batch[3].text == "hi 🌏")
	testing.expect(t, !batch[5].chat_is_private && batch[5].external_chat_id == "-111")
	again, next2, err2 := a.poll(a.ctx, "", nil)
	defer inbound_destroy_batch(again); defer delete(next2)
	testing.expect(t, err2.kind == .None && len(again) == 6 && next2 == next, "poll does not acknowledge")
	id, id_err := a.identity(a.ctx)
	testing.expect(t, id_err.kind == .None && id.bot_user_id == "123456" && id.bot_username == "ninjy_test_bot")
	url := a.pairing_url(a.ctx,id,"abc")
	defer delete(url)
	testing.expect(t, url == "https://t.me/ninjy_test_bot?start=abc")
	msg_id, send_err := a.send_text(a.ctx,"111","plaintext <b> 🌏")
	defer delete(msg_id)
	testing.expect(t, send_err.kind == .None && msg_id == "1")
	resp, transport := httpc.send({url = base, path = {"_control","sent"}, query = {{"chat_id","111"}}})
	defer httpc.response_destroy(&resp)
	result: struct {messages: []struct {message_id, chat_id: i64, text: string}}
	testing.expect(t, transport == .None && json.unmarshal(resp.body,&result, allocator = context.temp_allocator) == nil)
	testing.expect(t, len(result.messages) == 1 && result.messages[0].text == "plaintext <b> 🌏")
	// Once cached, identity no longer calls getMe.
	telegram_test_control(t,&f,"fail",struct {method: string,status,count: int}{"getMe",500,1})
	cached, cache_err := a.identity(a.ctx)
	testing.expect(t, cache_err.kind == .None && cached == id)
}

@(test)
test_telegram_error_mapping :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t,&f) do return
	a := telegram_adapter(&f.telegram)
	for row in ([]struct {status: int, description: string, want: Channel_Error_Kind}{
		{500,"server",.Transient}, {429,"limit",.Rate_Limited}, {401,"Unauthorized",.Unauthorized},
		{404,"Not Found",.Unauthorized}, {403,"blocked",.Chat_Unavailable},
		{400,"Bad Request: chat not found",.Chat_Unavailable}, {400,"other",.Invalid_Request},
	}) {
		telegram_test_control(t,&f,"fail",struct {method: string,status,retry_after,count: int,description: string}{"sendMessage",row.status,2,1,row.description})
		msg, err := a.send_text(a.ctx,"111","hi")
		delete(msg)
		testing.expectf(t, err.kind == row.want && err.provider_code == row.status, "%d -> %v",row.status,err)
		if row.status == 429 do testing.expect(t, err.retry_after_ms == 2000)
	}
	testing.expect(t, telegram_error(0,.Timeout,0,"",0).kind == .Transient)
	testing.expect(t, telegram_error(0,.Connect,0,"",0).kind == .Transient)
	cancel := true
	batch, next, aborted := a.poll(a.ctx,"", &cancel)
	inbound_destroy_batch(batch); delete(next)
	testing.expect(t, aborted.kind == .Aborted)
	// Cancel an actual empty long poll after it has entered httpc.
	_, _ = a.identity(a.ctx)
	state := struct {adapter: Channel_Adapter, cancel: bool, err: Channel_Error}{adapter = a}
	worker := thread.create_and_start_with_data(&state, proc(data: rawptr) {
		s := (^struct {adapter: Channel_Adapter, cancel: bool, err: Channel_Error})(data)
		b, n, e := s.adapter.poll(s.adapter.ctx,"", &s.cancel)
		inbound_destroy_batch(b); delete(n); s.err = e
	})
	time.sleep(150*time.Millisecond)
	sync.atomic_store(&state.cancel,true)
	thread.join(worker); thread.destroy(worker)
	testing.expect(t, state.err.kind == .Aborted, "in-flight long poll aborted")
}

@(test)
test_telegram_token_never_in_error_message :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t,&f) do return
	a := telegram_adapter(&f.telegram)
	for status in ([]int{400,401,403,404,429,500}) {
		telegram_test_control(t,&f,"fail",struct {method: string,status,count: int,description: string}{"sendMessage",status,1,"secret TEST:FAKE http://bad/botTEST:FAKE"})
		msg, err := a.send_text(a.ctx,"111","hi"); delete(msg)
		testing.expect(t, err.kind != .None && !strings.contains(err.message, f.telegram.token))
	}
	f.telegram.api_base = "bad TEST:FAKE"
	_, invalid := a.identity(a.ctx)
	testing.expect(t, invalid.kind != .None && !strings.contains(invalid.message,f.telegram.token))
	f.telegram.api_base = "http://127.0.0.1:1"
	_, transport := a.identity(a.ctx)
	testing.expect(t, transport.kind == .Transient && !strings.contains(transport.message,f.telegram.token))
}

@(test)
test_telegram_feedback_payloads_and_errors :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	a := telegram_adapter(&f.telegram)
	testing.expect(t, a.react(a.ctx, "111", "42", "👀").kind == .None)
	base, _ := httpc.parse_url(f.base)
	reactions, reactions_err := httpc.send({url = base, path = {"_control", "reactions"}})
	defer httpc.response_destroy(&reactions)
	reaction_data: struct {reactions: []struct {chat_id, message_id: i64, reaction: []struct {type, emoji: string}}}
	testing.expect(t, reactions_err == .None && json.unmarshal(reactions.body, &reaction_data, allocator = context.temp_allocator) == nil)
	if testing.expect(t, len(reaction_data.reactions) == 1) {
		row := reaction_data.reactions[0]
		testing.expect(t, row.chat_id == 111 && row.message_id == 42)
		if testing.expect(t, len(row.reaction) == 1) do testing.expect(t, row.reaction[0].type == "emoji" && row.reaction[0].emoji == "👀")
	}
	testing.expect(t, a.react(a.ctx, "bad", "42", "👀").kind == .Invalid_Request)
	testing.expect(t, a.react(a.ctx, "111", "bad", "👀").kind == .Invalid_Request)
	testing.expect(t, a.react(a.ctx, "111", "0", "👀").kind == .Invalid_Request)
	telegram_test_control(t, &f, "fail", struct {method: string, status, count: int, description: string}{"setMessageReaction", 500, 1, "secret TEST:FAKE"})
	err := a.react(a.ctx, "111", "42", "👀")
	testing.expect(t, err.kind == .Transient && !strings.contains(err.message, f.telegram.token))
}

@(test)
test_telegram_reaction_timeout_is_bounded :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	a := telegram_adapter(&f.telegram)
	telegram_test_control(t, &f, "fail", struct {method: string, status, count, delay_ms: int}{"setMessageReaction", 500, 1, 2500})
	started := time.tick_now()
	err := a.react(a.ctx, "111", "42", "👀")
	elapsed := time.tick_since(started)
	testing.expect(t, err.kind == .Transient, "slow reaction fails best effort")
	testing.expectf(t, elapsed >= 750*time.Millisecond && elapsed < 2*time.Second, "reaction timeout: %v", elapsed)
}

telegram_test_inject_media :: proc(t: ^testing.T, f: ^Telegram_Test_Fixture, media_type: string, declared: i64 = 3) {
	telegram_test_control(t, f, "inject", struct {
		chat_id, from_id: i64,
		media: struct {type, bytes_base64, mime_type, file_name, caption: string, declare_size: i64},
	}{111, 222, {media_type, "AP+A", "Application/PDF; charset=binary", "invoice.pdf", "caption 🌏", declared}})
}

@(test)
test_telegram_poll_media_kinds :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	for kind in ([]string{"photo", "document", "animation", "voice", "audio", "video", "video_note", "sticker", "location", "contact", "poll"}) do telegram_test_inject_media(t, &f, kind)
	// Optional MIME defaults; empty IDs; field presence and text take precedence.
	base, _ := httpc.parse_url(f.base)
	for raw in ([]string{
		`{"chat_id":111,"from_id":222,"media":{"type":"voice","bytes_base64":"AP+A"}}`,
		`{"chat_id":111,"from_id":222,"media":{"type":"video","bytes_base64":"AP+A"}}`,
		`{"chat_id":111,"from_id":222}`,
		`{"raw_update":{"message":{"chat":{"id":111,"type":"private"},"document":{"file_id":""},"voice":{"file_id":"ignored"}}}}`,
		`{"chat_id":111,"from_id":222,"chat_type":"group","media":{"type":"document","bytes_base64":"AP+A"}}`,
		`{"chat_id":111,"from_id":222,"text":"hello","media":{"type":"document","bytes_base64":"AP+A"}}`,
		`{"raw_update":{"message":{"chat":{"id":111,"type":"private"},"photo":[{"file_id":"first","width":2,"height":3},{"file_id":"later","width":3,"height":2}]}}}`,
	}) {
		resp, err := httpc.send({method = .POST, url = base, path = {"_control", "inject"}, body = httpc.raw_body("application/json", transmute([]byte)raw)})
		testing.expect(t, err == .None && resp.status == 200)
		httpc.response_destroy(&resp)
	}
	a := telegram_adapter(&f.telegram)
	batch, next, err := a.poll(a.ctx, "", nil)
	defer inbound_destroy_batch(batch); defer delete(next)
	if !testing.expect(t, err.kind == .None && len(batch) == 18) do return
	kinds := []Media_Kind{.Image, .Document, .Document, .Voice, .Audio, .Document, .Document}
	for kind, i in kinds {
		row := batch[i]
		testing.expect(t, row.kind == .Media && row.media.kind == kind && row.text == "caption 🌏")
		testing.expect(t, row.media.size == 3 && row.media.file_ref != "")
		if i == 0 {
			testing.expect(t, row.media.file_ref == "FAKEFILE1" && row.media.mime == "image/jpeg")
		} else if i == 6 {
			testing.expect(t, row.media.mime == "video/mp4" && row.media.name == "")
		} else {
			testing.expect(t, row.media.mime == "application/pdf")
			if i != 3 do testing.expect(t, row.media.name == "invoice.pdf")
		}
	}
	for i in 7..<11 do testing.expect(t, batch[i].kind == .Unsupported)
	testing.expect(t, batch[11].media.mime == "audio/ogg")
	testing.expect(t, batch[12].media.mime == "video/mp4")
	for i in 13..<16 do testing.expect(t, batch[i].kind == .Unsupported && batch[i].media.file_ref == "")
	testing.expect(t, batch[16].kind == .Text && batch[16].text == "hello" && batch[16].media.file_ref == "")
	testing.expect(t, batch[17].media.file_ref == "later", "equal photo area selects later entry")
}

@(test)
test_telegram_media_fetch_ok :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	telegram_test_inject_media(t, &f, "document")
	a := telegram_adapter(&f.telegram)
	got, err := a.media_fetch(a.ctx, "FAKEFILE1", 3)
	defer delete(got.bytes); defer delete(got.mime)
	testing.expect(t, err.kind == .None && len(got.bytes) == 3 && got.mime == "")
	if len(got.bytes) == 3 do testing.expect(t, got.bytes[0] == 0 && got.bytes[1] == 255 && got.bytes[2] == 128)
}

@(test)
test_telegram_media_fetch_declared_too_large_skips_download :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	// No bytes exceed the limit; only metadata does. A download would succeed.
	telegram_test_inject_media(t, &f, "document", 4_294_967_296)
	batch, next, poll_err := telegram_poll(&f.telegram, "", nil)
	defer inbound_destroy_batch(batch); defer delete(next)
	if testing.expect(t, poll_err.kind == .None && len(batch) == 1) {
		testing.expect(t, batch[0].media.size == 4_294_967_296, "inbound sizes retain 64 bits")
	}
	got, err := telegram_media_fetch(&f.telegram, "FAKEFILE1", 3)
	defer delete(got.bytes); defer delete(got.mime)
	testing.expect(t, err.kind == .Media_Too_Large && len(got.bytes) == 0)
}

@(test)
test_telegram_media_fetch_body_over_limit :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	telegram_test_inject_media(t, &f, "document", 0)
	for limit in ([]i64{0, 1, 2}) {
		got, err := telegram_media_fetch(&f.telegram, "FAKEFILE1", limit)
		delete(got.bytes); delete(got.mime)
		testing.expect(t, err.kind == .Media_Too_Large)
	}
}

@(test)
test_telegram_media_fetch_expired_is_unavailable :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	telegram_test_inject_media(t, &f, "document")
	telegram_test_control(t, &f, "file-expire", struct {file_id: string}{"FAKEFILE1"})
	for ref in ([]string{"FAKEFILE1", "missing"}) {
		got, err := telegram_media_fetch(&f.telegram, ref, 100)
		delete(got.bytes); delete(got.mime)
		testing.expect(t, err.kind == .Media_Unavailable)
	}
}

@(test)
test_telegram_send_media_methods :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	a := telegram_adapter(&f.telegram)
	bytes := []byte{0, 255, 128}
	for kind, i in ([]Media_Kind{.Image, .Document, .Voice, .Audio}) {
		caption := "caption 🌏" if i%2 == 0 else ""
		id, err := a.send_media(a.ctx, "111", {kind, "file.bin", "application/octet-stream", bytes, caption}, 1000)
		testing.expect(t, err.kind == .None && id == fmt.tprintf("%d", i+1))
		delete(id)
	}
	base, _ := httpc.parse_url(f.base)
	resp, err := httpc.send({url = base, path = {"_control", "sent"}})
	defer httpc.response_destroy(&resp)
	data: struct {messages: []struct {method, filename, mime, caption, sha256: string, size: int, chat_id: i64}}
	testing.expect(t, err == .None && json.unmarshal(resp.body, &data, allocator = context.temp_allocator) == nil)
	if !testing.expect(t, len(data.messages) == 4) do return
	methods := []string{"sendPhoto", "sendDocument", "sendVoice", "sendAudio"}
	for row, i in data.messages {
		testing.expect(t, row.method == methods[i] && row.filename == "file.bin" && row.mime == "application/octet-stream" && row.size == 3 && row.chat_id == 111)
		testing.expect(t, row.sha256 == "f742b965f156c10374bc23aea96e3a8aff8facd6fc079defeaa30219ad86f211")
		testing.expect(t, row.caption == ("caption 🌏" if i%2 == 0 else ""))
	}
	value, _ := json.parse(string(resp.body), allocator = context.temp_allocator)
	obj, _ := value.(json.Object)
	messages, _ := obj["messages"].(json.Array)
	for message, i in messages {
		row, _ := message.(json.Object)
		_, has_caption := row["caption"]
		testing.expect(t, has_caption == (i%2 == 0))
	}
	id, invalid := a.send_media(a.ctx, "bad", {.Document, "f", "application/pdf", bytes, ""}, 1000)
	delete(id)
	testing.expect(t, invalid.kind == .Invalid_Request)
}

@(test)
test_telegram_send_media_400_is_invalid_request :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	telegram_test_control(t, &f, "fail", struct {method: string, status: int}{"sendDocument", 400})
	id, err := telegram_send_media(&f.telegram, "111", {.Document, "f.pdf", "application/pdf", []byte{1}, ""}, 1000)
	defer delete(id)
	testing.expect(t, err.kind == .Invalid_Request)
}

telegram_test_media_timeout :: proc(t: ^testing.T, media: bool) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	method := "sendDocument" if media else "sendMessage"
	telegram_test_control(t, &f, "fail", struct {method: string, status, delay_ms: int}{method, 500, 2000})
	started := time.tick_now()
	id: string
	err: Channel_Error
	if media {
		id, err = telegram_send_media(&f.telegram, "111", {.Document, "f.pdf", "application/pdf", []byte{1}, ""}, 500)
	} else {
		id, err = telegram_send_text_within(&f.telegram, "111", "hello", 500)
	}
	defer delete(id)
	elapsed := time.tick_since(started)
	testing.expectf(t, err.kind == .Transient && elapsed >= 350*time.Millisecond && elapsed < 1500*time.Millisecond, "%v %v", err, elapsed)
}

@(test)
test_telegram_send_media_respects_timeout :: proc(t: ^testing.T) { telegram_test_media_timeout(t, true) }

@(test)
test_telegram_send_text_within_respects_timeout :: proc(t: ^testing.T) { telegram_test_media_timeout(t, false) }

@(test)
test_telegram_media_capabilities_values :: proc(t: ^testing.T) {
	a := telegram_adapter(nil)
	testing.expect(t, a.media.fetch_max_bytes == 20_000_000 && a.media.caption_max_runes == 1024 && len(a.media.send_rules) == 4)
	kinds := []Media_Kind{.Image, .Voice, .Audio, .Document}
	for rule, i in a.media.send_rules {
		testing.expect(t, rule.kind == kinds[i] && rule.caption && rule.max_bytes == (10_000_000 if i == 0 else 50_000_000))
	}
	testing.expect(t, a.media.send_rules[0].mimes[0] == "image/jpeg" && a.media.send_rules[0].mimes[1] == "image/png")
	testing.expect(t, a.media.send_rules[1].mimes[0] == "audio/ogg")
	testing.expect(t, a.media.send_rules[2].mimes[0] == "audio/mpeg" && a.media.send_rules[2].mimes[1] == "audio/mp4")
	testing.expect(t, len(a.media.send_rules[3].mimes) == 0)
}

@(test)
test_telegram_media_errors_hide_token :: proc(t: ^testing.T) {
	f: Telegram_Test_Fixture
	defer telegram_test_stop(&f)
	if !telegram_test_start(t, &f) do return
	for status in ([]int{400, 401, 403, 404, 429, 500}) {
		for method in ([]string{"getFile", "sendDocument"}) {
			telegram_test_control(t, &f, "fail", struct {method: string, status: int, description: string}{method, status, "TEST:FAKE secret URL"})
			err: Channel_Error
			if method == "getFile" {
				got: Fetched_Media
				got, err = telegram_media_fetch(&f.telegram, "secret file ref", 100)
				delete(got.bytes); delete(got.mime)
			} else {
				id: string
				id, err = telegram_send_media(&f.telegram, "111", {.Document, "f", "application/pdf", []byte{1}, ""}, 1000)
				delete(id)
			}
			testing.expect(t, err.kind != .None && !strings.contains(err.message, "TEST:FAKE") && !strings.contains(err.message, "secret"))
		}
	}
}
