package main

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import httpc "odin_test:lib/httpc"

// Hub requests are described structurally (Ctl_Request) and encoded by httpc:
// ids are single path segments, query values are encoded, optional body fields
// are omitted exactly where the hand-built JSON used to omit them.

@(test)
test_hub_request_tricky_ids_are_single_segments :: proc(t: ^testing.T) {
	tricky := "a b/c?d"
	testing.expect_value(t, ctl_test_target(t, {method = .GET, path = ctl_api("memories", tricky)}), "/api/v1/memories/a%20b%2Fc%3Fd")
	testing.expect_value(t, ctl_test_target(t, {method = .DELETE, path = ctl_api("task-chains", "ch/1", "members", "inst 2")}), "/api/v1/task-chains/ch%2F1/members/inst%202")
	// The query is still separate from an id that holds '?' or '#'.
	fetch := ctl_test_target(t, ctl_task_fetch_request("c?x=1", "t#2", "facet:t:1:output"))
	testing.expectf(t, strings.has_prefix(fetch, "/api/v1/task-chains/c%3Fx%3D1/tasks/t%232/fetch?ref="), "fetch: %s", fetch)
	// A dot segment or an empty id can never address another route.
	for bad in ([]string{"", ".", ".."}) {
		_, ok := ctl_agent_rest_params({method = .GET, path = ctl_api("issues", bad)})
		testing.expectf(t, !ok, "id %q must be rejected", bad)
	}
}

@(test)
test_agent_rest_params_carry_target_and_body :: proc(t: ^testing.T) {
	query := []httpc.Query_Param{{"limit", "5"}}
	params, ok := ctl_agent_rest_params({method = .POST, path = ctl_api("issues", "iss 1", "comments"), query = query, body = httpc.json_body(Ctl_Issue_Comment_Body{body = `say "hi"`})})
	defer delete(params)
	testing.expect(t, ok, "params built")
	v, parsed := ctl_parse_json_document(params)
	obj, _ := v.(json.Object)
	testing.expect(t, parsed, params)
	method, _ := obj["http_method"].(json.String)
	path, _ := obj["path"].(json.String)
	body, _ := obj["body"].(json.String)
	testing.expect_value(t, string(method), "POST")
	testing.expect_value(t, string(path), "/api/v1/issues/iss%201/comments?limit=5")
	testing.expect_value(t, string(body), `{"body":"say \"hi\""}`)

	none, nok := ctl_agent_rest_params({method = .GET, path = ctl_api("shells")})
	defer delete(none)
	testing.expect(t, nok && strings.contains(none, `"body":""`), none)
}

FAKE_HUB_BUF :: 16 * 1024

Fake_Hub :: struct {
	listener: net.TCP_Socket,
	port:     int,
	request:  [FAKE_HUB_BUF]byte,
	req_len:  int,
	response: string,
	handle:   ^thread.Thread,
}

fake_hub_thread :: proc(data: rawptr) {
	fh := cast(^Fake_Hub)data
	client, _, aerr := net.accept_tcp(fh.listener)
	if aerr != nil do return
	defer net.close(client)
	_ = net.set_option(client, .Receive_Timeout, 3 * time.Second)
	total := 0
	for total < len(fh.request) {
		n, rerr := net.recv_tcp(client, fh.request[total:])
		if rerr != nil || n <= 0 do break
		total += n
		text := string(fh.request[:total])
		head_end := strings.index(text, "\r\n\r\n")
		if head_end < 0 do continue
		want := 0
		if i := strings.index(text, "Content-Length: "); i >= 0 && i < head_end {
			rest := text[i + len("Content-Length: "):]
			if eol := strings.index(rest, "\r\n"); eol >= 0 do want, _ = strconv.parse_int(rest[:eol])
		}
		if total >= head_end + 4 + want do break
	}
	fh.req_len = total
	_, _ = net.send_tcp(client, transmute([]byte)fh.response)
}

fake_hub_start :: proc(t: ^testing.T, response: string) -> ^Fake_Hub {
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, err == nil, "fake hub binds") do return nil
	bound, _ := net.bound_endpoint(listener)
	fh := new(Fake_Hub)
	fh.listener = listener
	fh.port = bound.port
	fh.response = response
	fh.handle = thread.create_and_start_with_data(fh, fake_hub_thread)
	return fh
}

fake_hub_stop :: proc(fh: ^Fake_Hub) {
	if fh == nil do return
	thread.join(fh.handle)
	thread.destroy(fh.handle)
	net.close(fh.listener)
	free(fh)
}

@(test)
test_user_transport_resolves_under_base_path_prefix :: proc(t: ^testing.T) {
	reply := `{"ok":true}`
	fh := fake_hub_start(t, fmt.tprintf("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(reply), reply))
	if fh == nil do return
	defer fake_hub_stop(fh)

	hub := ctl_hub_make(fmt.tprintf("http://127.0.0.1:%d/heimdall/", fh.port), "tok_1")
	testing.expect(t, hub.valid, "base URL parses")
	req := Ctl_Request{method = .POST, path = ctl_api("issues", "a b/c?d", "comments"), body = httpc.json_body(Ctl_Issue_Comment_Body{body = "hello"})}
	body, status, ok := ctl_hub_fetch(hub, req, context.temp_allocator)
	testing.expect(t, ok, "hub reached")
	testing.expect_value(t, status, 201)
	testing.expect_value(t, body, reply)

	sent := string(fh.request[:fh.req_len])
	// The prefix is applied exactly once (the old client prefixed twice).
	testing.expectf(t, strings.has_prefix(sent, "POST /heimdall/api/v1/issues/a%20b%2Fc%3Fd/comments HTTP/1.1\r\n"), "request: %s", sent)
	testing.expectf(t, strings.contains(sent, "\r\nAuthorization: Bearer tok_1\r\n"), "bearer header: %s", sent)
	testing.expectf(t, strings.contains(sent, "\r\nContent-Type: application/json\r\n"), "content type: %s", sent)
	testing.expectf(t, strings.has_suffix(sent, "\r\n\r\n{\"body\":\"hello\"}"), "body: %s", sent)
}

@(test)
test_user_transport_unreachable_or_invalid_base_fails :: proc(t: ^testing.T) {
	_, _, ok := ctl_hub_fetch(ctl_hub_make("not a url", "tok"), {method = .GET, path = ctl_api("me")})
	testing.expect(t, !ok, "an invalid base URL is a failed request")
	transport := ctl_user_transport("", "")
	resp, tok := ctl_transport_fetch(transport, {method = .GET, path = ctl_api("me")})
	testing.expect(t, !tok && strings.contains(resp, "user transport requires"), resp)
}
