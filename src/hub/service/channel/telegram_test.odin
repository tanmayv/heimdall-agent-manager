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
