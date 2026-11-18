package bots

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"

Send_Test_State :: struct {
	messages: [dynamic]domain.Channel_Message,
	sequence: []channel.Channel_Error,
	calls, next_id, expected_rows: int,
	recorded_before_send: bool,
}
send_test_id :: proc(ctx: rawptr, prefix: string) -> string {
	s := (^Send_Test_State)(ctx)
	s.next_id += 1
	return fmt.tprintf("%s%d",prefix,s.next_id)
}
send_test_insert :: proc(ctx: rawptr, msg: domain.Channel_Message) -> domain.Domain_Error {
	s := (^Send_Test_State)(ctx)
	append(&s.messages, domain.Channel_Message{message_id = strings.clone(msg.message_id), body = strings.clone(msg.body), send_state = msg.send_state})
	return {}
}
send_test_result :: proc(ctx: rawptr, id: string, state: domain.Channel_Send_State, external, err: string) -> domain.Domain_Error {
	s := (^Send_Test_State)(ctx)
	for &msg in s.messages {
		if msg.message_id == id {
			msg.send_state = state
			msg.external_message_id = strings.clone(external)
			msg.send_error = strings.clone(err)
			return {}
		}
	}
	return domain.domain_error(.Not_Found,"test missing message")
}
send_test_text :: proc(ctx: rawptr, external_chat_id, text: string) -> (string, channel.Channel_Error) {
	s := (^Send_Test_State)(ctx)
	if s.calls == 0 {
		s.recorded_before_send = len(s.messages) == s.expected_rows
		for m in s.messages do s.recorded_before_send = s.recorded_before_send && m.send_state == .Pending
	}
	index := s.calls
	s.calls += 1
	if index < len(s.sequence) && s.sequence[index].kind != .None do return "", s.sequence[index]
	return strings.clone(fmt.tprintf("%d",s.calls)), {}
}
send_test_free :: proc(s: ^Send_Test_State, ids: []string) {
	for id in ids do delete(id)
	delete(ids)
	for &msg in s.messages do domain.channel_message_destroy(&msg)
	delete(s.messages)
}

@(test)
test_channel_send_chunk_boundaries :: proc(t: ^testing.T) {
	ascii := strings.repeat("x",3998,context.temp_allocator)
	huge := strings.repeat("z",5000,context.temp_allocator)
	for text in ([]string{fmt.tprintf("%s🌏end",ascii), fmt.tprintf("ab\n%s",huge),fmt.tprintf("ab %s",huge),""}) {
		chunks := channel_text_chunks(text)
		defer delete(chunks)
		pos := 0
		for chunk in chunks {
			testing.expect(t, len(chunk)>0 && len(chunk)<=4000 && utf8.valid_string(chunk))
			testing.expect(t, chunk == text[pos:pos+len(chunk)])
			pos += len(chunk)
		}
		testing.expect(t, pos == len(text), "no whitespace or characters lost")
		if strings.has_prefix(text,"ab\n") do testing.expect(t, len(chunks[0]) == 3)
		if strings.has_prefix(text,"ab ") do testing.expect(t, len(chunks[0]) == 3)
	}
}

@(test)
test_channel_send_records_all_chunks_before_failure :: proc(t: ^testing.T) {
	state := Send_Test_State{expected_rows = 2, sequence = {{kind = .Unauthorized}}}
	repo := iface.Bot_Repository{ctx = &state, message_insert_outbound = send_test_insert, message_set_send_result = send_test_result}
	ids := platform.ID_Generator{ctx = &state, generate = send_test_id}
	a := channel.Channel_Adapter{ctx = &state, send_text = send_test_text}
	s := Bots_Service{repo = &repo, ids = &ids, adapter = &a}
	result, err := channel_send(&s,{provider="telegram",binding_id="chb_test",bot_id="bot_test",owner_user_id="alice",external_chat_id="111"},strings.repeat("x",4500,context.temp_allocator),true)
	defer send_test_free(&state,result)
	testing.expect(t, len(result)==2 && state.calls==1 && state.recorded_before_send)
	testing.expect(t, err.code == .Provider_Unavailable && err.message == "channel send failed")
	testing.expectf(t, err.details_json == `{"code":"channel_send_failed","kind":"Unauthorized"}`, "details: %q", err.details_json)
	if testing.expect(t,len(state.messages)==2) {
		testing.expect(t,state.messages[0].send_state == .Failed && state.messages[0].send_error == "Unauthorized")
		testing.expect(t,state.messages[1].send_state == .Failed && state.messages[1].send_error == "not_sent")
	}
}

@(test)
test_channel_send_retry_limits_and_success :: proc(t: ^testing.T) {
	state := Send_Test_State{expected_rows=1,sequence = {{kind = .Transient},{kind = .Rate_Limited,retry_after_ms=0},{}}}
	repo := iface.Bot_Repository{ctx=&state,message_insert_outbound=send_test_insert,message_set_send_result=send_test_result}
	ids := platform.ID_Generator{ctx=&state,generate=send_test_id}
	a := channel.Channel_Adapter{ctx=&state,send_text=send_test_text}
	s := Bots_Service{repo=&repo,ids=&ids,adapter=&a}
	result, err := channel_send(&s,{provider="telegram"},"hi",true)
	defer send_test_free(&state,result)
	testing.expect(t, err.code == .None && state.calls==3 && state.recorded_before_send)
	testing.expect(t, len(state.messages)==1 && state.messages[0].send_state==.Sent && state.messages[0].external_message_id=="3")
	// Rate limit beyond the total budget is refused without sleeping or retrying.
	limited := Send_Test_State{sequence={{kind=.Rate_Limited,retry_after_ms=20_001}}}
	a.ctx = &limited
	notice, rate_err := channel_send(&s,{provider="telegram"},"notice",false)
	defer send_test_free(&limited,notice)
	testing.expect(t,rate_err.code==.Provider_Unavailable && limited.calls==1 && len(limited.messages)==0)
	exhausted := Send_Test_State{sequence={{kind=.Transient},{kind=.Transient},{kind=.Transient}}}
	a.ctx = &exhausted
	failed, transient_err := channel_send(&s,{provider="telegram"},"notice",false)
	defer send_test_free(&exhausted,failed)
	testing.expect(t,transient_err.code==.Provider_Unavailable && exhausted.calls==3)
	unavailable := Bots_Service{}
	no_ids, config_err := channel_send(&unavailable,{},"hi",true)
	defer delete(no_ids)
	testing.expect(t,config_err.code==.Provider_Unavailable && config_err.details_json==`{"code":"channel_not_configured"}`)
}
