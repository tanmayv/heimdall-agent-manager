package http

import "base:runtime"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import channel "odin_test:hub/service/channel"
import httpc "odin_test:lib/httpc"

Ninjy_Spike_Provider :: enum {
	Telegram,
	WhatsApp,
}
NINJY_SPIKE_TG_TOKEN :: "TEST-phase-zero"
NINJY_SPIKE_WA_NUMBER :: "100000000000001"
NINJY_SPIKE_WA_ACCOUNT :: "200000000000002"
NINJY_SPIKE_WA_SECRET :: "synthetic-phase-zero-secret"
NINJY_SPIKE_WA_TOKEN :: "synthetic-phase-zero-token"

Ninjy_Spike_Channel :: struct {
	provider:               Ninjy_Spike_Provider,
	telegram:               channel.Telegram_Adapter,
	whatsapp:               channel.WhatsApp_Adapter,
	adapter:                channel.Channel_Adapter,
	base, input:            string, // fixture owns only base; input is borrowed for its lifetime
	listener:               net.TCP_Socket,
	port:                   int,
	worker:                 ^thread.Thread,
	stopping:               bool,
	mu:                     sync.Mutex,
	sends:                  int,
	address, body, receipt: string, // heap-owned, protected by mu
}

ninjy_spike_channel_start :: proc(
	t: ^testing.T,
	f: ^Ninjy_Spike_Channel,
	provider: Ninjy_Spike_Provider,
	input: string,
) -> bool {
	ok, message := httpc.init()
	if !testing.expect(t, ok, message) do return false
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, err == nil, "bind fake channel") do return false
	bound, bound_err := net.bound_endpoint(listener)
	if !testing.expect(t, bound_err == nil, "resolve fake channel port") {
		net.close(listener)
		return false
	}
	f.listener = listener
	f.port = bound.port
	f.provider = provider
	f.input = input
	f.base = fmt.aprintf("http://127.0.0.1:%d", f.port)
	switch provider {
	case .Telegram:
		f.telegram = {
			token    = NINJY_SPIKE_TG_TOKEN,
			api_base = f.base,
		}
		f.adapter = channel.telegram_adapter(&f.telegram)
	case .WhatsApp:
		f.whatsapp = {
			access_token        = NINJY_SPIKE_WA_TOKEN,
			app_secret          = NINJY_SPIKE_WA_SECRET,
			phone_number_id     = NINJY_SPIKE_WA_NUMBER,
			business_account_id = NINJY_SPIKE_WA_ACCOUNT,
			api_base            = f.base,
		}
		f.adapter = channel.whatsapp_adapter(&f.whatsapp)
	}
	f.worker = thread.create_and_start_with_data(f, ninjy_spike_channel_serve)
	if !testing.expect(t, f.worker != nil, "start fake channel worker") {
		net.close(listener)
		delete(f.base)
		return false
	}
	return true
}

ninjy_spike_channel_stop :: proc(f: ^Ninjy_Spike_Channel) {
	if f.worker == nil do return
	sync.atomic_store(&f.stopping, true)
	// Wake accept without a sleep, a process, or a host-global port.
	if wake, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = f.port}); err == nil {
		net.close(wake)
	}
	thread.join(f.worker)
	thread.destroy(f.worker)
	net.close(f.listener)
	channel.telegram_destroy(&f.telegram)
	channel.whatsapp_destroy(&f.whatsapp)
	delete(f.base)
	delete(f.address, runtime.heap_allocator())
	delete(f.body, runtime.heap_allocator())
	delete(f.receipt, runtime.heap_allocator())
}

// The returned row's fields belong to allocator.
ninjy_spike_channel_receive :: proc(
	t: ^testing.T,
	f: ^Ninjy_Spike_Channel,
	allocator := context.allocator,
) -> (
	row: channel.Inbound,
	ok: bool,
) {
	batch: []channel.Inbound
	switch f.provider {
	case .Telegram:
		cursor: string
		err: channel.Channel_Error
		batch, cursor, err = f.adapter.poll(f.adapter.ctx, "", nil, allocator)
		defer delete(cursor, allocator)
		if !testing.expect(t, err.kind == .None, err.message) {
			channel.inbound_destroy_batch(batch, allocator)
			return {}, false
		}
	case .WhatsApp:
		escaped := ninjy_spike_channel_json_text(f.input)
		body := fmt.tprintf(
			`{{"object":"whatsapp_business_account","entry":[{{"id":"%s","changes":[{{"field":"messages","value":{{"metadata":{{"phone_number_id":"%s"}},"messages":[{{"from":"15550100123","id":"wamid.phase-zero-in","timestamp":"1763452800","type":"text","text":{{"body":%s}}}}]}}}}]}}]}}`,
			NINJY_SPIKE_WA_ACCOUNT,
			NINJY_SPIKE_WA_NUMBER,
			escaped,
		)
		tag: [32]byte
		hmac.sum(.SHA256, tag[:], transmute([]byte)body, transmute([]byte)f.whatsapp.app_secret)
		signature := fmt.tprintf("sha256=%s", string(hex.encode(tag[:], context.temp_allocator)))
		verdict: channel.Push_Verdict
		batch, verdict = f.adapter.push_parse(f.adapter.ctx, signature, body, allocator)
		if !testing.expect_value(t, verdict, channel.Push_Verdict.Accepted) {
			channel.inbound_destroy_batch(batch, allocator)
			return {}, false
		}
	}
	if !testing.expect_value(t, len(batch), 1) {
		channel.inbound_destroy_batch(batch, allocator)
		return {}, false
	}
	row = batch[0]
	delete(batch, allocator)
	return row, true
}

ninjy_spike_channel_send :: proc(
	f: ^Ninjy_Spike_Channel,
	address, plaintext: string,
) -> (
	string,
	channel.Channel_Error,
) {
	return f.adapter.send_text(f.adapter.ctx, address, plaintext)
}

ninjy_spike_channel_capture :: proc(
	f: ^Ninjy_Spike_Channel,
	allocator := context.allocator,
) -> (
	count: int,
	address, body, receipt: string,
) {
	sync.mutex_lock(&f.mu)
	defer sync.mutex_unlock(&f.mu)
	return f.sends, strings.clone(f.address, allocator), strings.clone(f.body, allocator), strings.clone(f.receipt, allocator)
}

ninjy_spike_channel_json_text :: proc(value: string) -> string {
	encoded, _ := json.marshal(value, allocator = context.temp_allocator)
	return string(encoded)
}

ninjy_spike_channel_serve :: proc(data: rawptr) {
	f := (^Ninjy_Spike_Channel)(data)
	for !sync.atomic_load(&f.stopping) {
		client, _, err := net.accept_tcp(f.listener)
		if err != nil do return
		defer net.close(client)
		if sync.atomic_load(&f.stopping) do return
		_ = net.set_option(client, .Receive_Timeout, 2 * time.Second)
		_ = net.set_option(client, .Send_Timeout, 2 * time.Second)
		ninjy_spike_channel_request(f, client)
	}
}

ninjy_spike_channel_request :: proc(f: ^Ninjy_Spike_Channel, client: net.TCP_Socket) {
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	allocator := virtual.arena_allocator(&scratch)
	context.allocator = allocator
	context.temp_allocator = allocator
	request, ok := read_http_request(client)
	if !ok do return
	method, target := request_method_target(request)
	path, _ := split_target_query(target)
	body := request_body(request)
	reply := `{}`
	status := 404
	switch {
	case f.provider == .Telegram && method == "GET" && path == "/bot" + NINJY_SPIKE_TG_TOKEN + "/getMe":
		status = 200
		reply = `{"ok":true,"result":{"id":7001,"username":"phase_zero_test_bot"}}`
	case f.provider == .Telegram && method == "GET" && path == "/bot" + NINJY_SPIKE_TG_TOKEN + "/getUpdates":
		status = 200
		reply = fmt.tprintf(
			`{{"ok":true,"result":[{{"update_id":8701,"message":{{"message_id":8702,"chat":{{"id":8111,"type":"private"}},"from":{{"id":8111,"first_name":"Test"}},"text":%s}}}}]}}`,
			ninjy_spike_channel_json_text(f.input),
		)
	case f.provider == .Telegram && method == "POST" && path == "/bot" + NINJY_SPIKE_TG_TOKEN + "/sendMessage":
		data: struct {
			chat_id: i64,
			text:    string,
		}
		if json.unmarshal(transmute([]byte)body, &data, allocator = context.temp_allocator) == nil {
			id := ninjy_spike_channel_record(f, fmt.tprintf("%d", data.chat_id), data.text)
			status = 200
			reply = fmt.tprintf(`{{"ok":true,"result":{{"message_id":%s}}}}`, id)
		}
	case f.provider == .WhatsApp &&
	     method == "POST" &&
	     path == "/" + channel.WHATSAPP_GRAPH_VERSION + "/" + NINJY_SPIKE_WA_NUMBER + "/messages":
		data: struct {
			to, type: string,
			text:     struct {
				body: string,
			},
		}
		if json.unmarshal(transmute([]byte)body, &data, allocator = context.temp_allocator) == nil &&
		   data.type == "text" {
			id := ninjy_spike_channel_record(f, data.to, data.text.body)
			status = 200
			reply = fmt.tprintf(`{{"messages":[{{"id":"%s"}}]}}`, id)
		}
	}
	write_http_response(client, Response{status = status, body = reply})
}

ninjy_spike_channel_record :: proc(f: ^Ninjy_Spike_Channel, address, body: string) -> string {
	sync.mutex_lock(&f.mu)
	defer sync.mutex_unlock(&f.mu)
	f.sends += 1
	id :=
		fmt.tprintf("%d", 9000 + f.sends) if f.provider == .Telegram else fmt.tprintf("wamid.phase-zero-out-%d", f.sends)
	heap := runtime.heap_allocator()
	delete(f.address, heap)
	delete(f.body, heap)
	delete(f.receipt, heap)
	f.address = strings.clone(address, heap)
	f.body = strings.clone(body, heap)
	f.receipt = strings.clone(id, heap)
	return id
}
