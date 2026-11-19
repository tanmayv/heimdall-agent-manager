package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
test_channel_rewrite_without_attachments_unchanged :: proc(t: ^testing.T) {
	response := `{ "ok":true, "data":{"messages":[{"body":"hi"}]} }`
	out, ok := ctl_channel_rewrite_attachments(response, nil, nil)
	testing.expect(t, ok)
	testing.expect_value(t, out, response)
	_, ok = ctl_channel_rewrite_attachments(`{"attachments":`, nil, nil)
	testing.expect(t, !ok)
}

Ctl_Channel_Rewrite_Test_Context :: struct {
	calls: int,
	t:     ^testing.T,
}
ctl_channel_test_resolve :: proc(raw: rawptr, a: Ctl_Channel_Attachment_In) -> Ctl_Channel_Attachment_Out {
	c := cast(^Ctl_Channel_Rewrite_Test_Context)raw
	testing.expect_value(c.t, a.attachment_id, "cha")
	testing.expect_value(c.t, a.name, "invoice.pdf")
	testing.expect_value(c.t, a.size, i64(48213))
	c.calls += 1
	if a.state == "pending" && a.artifact_id == "fetch" {
		return {artifact_id = "created", kind = a.kind, name = a.name, mime = "application/pdf", size = 48213}
	}
	media_ctx := Ctl_Channel_Media_Context{}
	return ctl_channel_resolve_attachment(&media_ctx, a)
}

@(test)
test_channel_rewrite_attachments_outputs :: proc(t: ^testing.T) {
	cases := []struct {
		direction, state, id, expected_id, error, sent_as: string,
	} {
		{"outbound", "native", "art", "art", "", "native"},
		{"outbound", "held", "art", "art", "", "held"},
		{"inbound", "stored", "art", "art", "", ""},
		{"inbound", "too_large", "art", "", "too_large", ""},
		{"inbound", "unavailable", "", "", "unavailable", ""},
		{"inbound", "pending", "", "", "vault_unavailable", ""},
		{"inbound", "pending", "fetch", "created", "", ""},
	}
	c := Ctl_Channel_Rewrite_Test_Context {
		t = t,
	}
	for tc in cases {
		input := struct {
			ok:   bool,
			data: struct {
				messages: []struct {
					direction:   string,
					body:        string,
					attachments: []Ctl_Channel_Attachment_In,
				},
			},
		}{}
		input.ok = true
		attachments := []Ctl_Channel_Attachment_In {
			{
				attachment_id = "cha",
				kind = "document",
				name = "invoice.pdf",
				mime = "application/pdf",
				artifact_id = tc.id,
				state = tc.state,
				size = 48213,
			},
		}
		rows := []struct {
			direction:   string,
			body:        string,
			attachments: []Ctl_Channel_Attachment_In,
		}{{tc.direction, "unchanged", attachments}}
		input.data.messages = rows
		// The local Bridge wraps the Hub envelope in its own data field.
		envelope := struct {v: int, id: string, ok: bool, data: type_of(input)}{1, "ham-ctl-agent", true, input}
		encoded, _ := json.marshal(envelope, allocator = context.temp_allocator)
		rewritten, ok := ctl_channel_rewrite_attachments(string(encoded), ctl_channel_test_resolve, &c)
		testing.expect(t, ok)
		output: struct {
			ok:   bool,
			data: struct {
				messages: []struct {
					body:        string,
					attachments: []Ctl_Channel_Attachment_Out,
				},
			},
		}
		wrapped: struct {data: type_of(output)}
		testing.expect_value(
			t,
			json.unmarshal(transmute([]byte)rewritten, &wrapped, allocator = context.temp_allocator),
			nil,
		)
		output = wrapped.data
		testing.expect_value(t, len(output.data.messages), 1)
		if len(output.data.messages) != 1 do continue
		testing.expect_value(t, output.data.messages[0].body, "unchanged")
		actual := output.data.messages[0].attachments[0]
		testing.expect_value(t, actual.artifact_id, tc.expected_id)
		testing.expect_value(t, actual.error, tc.error)
		testing.expect_value(t, actual.sent_as, tc.sent_as)
		testing.expect(t, !strings.contains(rewritten, "attachment_id"))
		testing.expect(t, !strings.contains(rewritten, `"state"`))
	}
	testing.expect_value(t, c.calls, len(cases))
}

@(test)
test_ctl_media_mime_from_name :: proc(t: ^testing.T) {
	names := []string {
		"x.jpg",
		"x.png",
		"x.webp",
		"x.gif",
		"x.ogg",
		"x.mp3",
		"x.m4a",
		"x.aac",
		"x.amr",
		"x.mp4",
		"x.3gp",
		"x.mov",
		"x.pdf",
		"x.txt",
	}
	mimes := []string {
		"image/jpeg",
		"image/png",
		"image/webp",
		"image/gif",
		"audio/ogg",
		"audio/mpeg",
		"audio/mp4",
		"audio/aac",
		"audio/amr",
		"video/mp4",
		"video/3gpp",
		"video/quicktime",
		"application/pdf",
		"text/plain",
	}
	for name, i in names do testing.expect_value(t, ctl_media_mime_from_name(name), mimes[i])
	testing.expect_value(t, ctl_media_mime_from_name("PHOTO.JPG"), "image/jpeg")
	for name in ([]string{"", "file", "x.unknown", "a.pdf.exe"}) do testing.expect_value(t, ctl_media_mime_from_name(name), "application/octet-stream")
}

@(test)
test_channel_media_fetch_seals_and_records :: proc(t: ^testing.T) {
	kr := tkr("1111111111111111111111111111111111111111111111111111111111111111")
	replies := []string {
		"{\"v\":1,\"ok\":true,\"data\":{\"data\":{\"outcome\":\"fetched\",\"mime\":\"image/png\",\"size\":3,\"content_base64\":\"AP+A\"}}}\n",
		"{\"ok\":true,\"data\":{\"artifact_id\":\"created\"}}\n",
		"{\"ok\":true,\"data\":{\"artifact_id\":\"winner\"}}\n",
	}
	fb := fake_bridge_start(t, replies)
	if fb == nil do return
	defer fake_bridge_stop(fb)
	c := Ctl_Channel_Media_Context {
		endpoint = fb.endpoint,
		token    = "test",
		keyring  = kr,
	}
	out := ctl_channel_resolve_attachment(
		&c,
		{attachment_id = "cha", kind = "image", name = "photo.png", mime = "wrong", state = "pending"},
	)
	testing.expect_value(t, out.error, "")
	testing.expect_value(t, out.artifact_id, "winner")
	testing.expect_value(t, out.mime, "image/png")
	testing.expect_value(t, out.size, i64(3))
	testing.expect_value(t, fb.served, 3)
	request := fake_bridge_request(fb, 1)
	testing.expect_value(t, ctl_channel_string(request, "method", ""), "agent.artifact.create")
	testing.expect_value(t, ctl_channel_string(request, "kind", ""), "image")
	name, nr := ctl_vault_open(ctl_channel_string(request, "name", ""), kr, context.temp_allocator)
	testing.expect(t, nr == .Ok)
	testing.expect_value(t, name, "photo.png")
	sealed, err := base64.decode(ctl_channel_string(request, "content_base64", ""), allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	bytes, res := ctl_vault_open(string(sealed), kr, context.temp_allocator)
	testing.expect(t, res == .Ok)
	testing.expect_value(t, bytes, "\x00\xff\x80")
	testing.expect(t, strings.contains(fake_bridge_request(fb, 2), "/media/stored"))
}

@(test)
test_channel_media_fetch_outcomes :: proc(t: ^testing.T) {
	kr := tkr("1111111111111111111111111111111111111111111111111111111111111111")
	for outcome in ([]string{"stored", "too_large", "unavailable", "failed"}) {
		response, _ := json.marshal(struct {
				ok:   bool,
				data: struct {
					outcome, artifact_id: string,
				},
			}{true, {outcome, "already"}}, allocator = context.temp_allocator)
		replies := []string{strings.concatenate({string(response), "\n"}, context.temp_allocator)}
		fb := fake_bridge_start(t, replies)
		if fb == nil do continue
		c := Ctl_Channel_Media_Context {
			endpoint = fb.endpoint,
			token    = "test",
			keyring  = kr,
		}
		out := ctl_channel_resolve_attachment(&c, {state = "pending", attachment_id = "cha"})
		if outcome == "stored" {
			testing.expect_value(t, out.artifact_id, "already")
			testing.expect_value(t, out.error, "")
		} else if outcome == "failed" {
			testing.expect_value(t, out.error, "fetch_failed")
		} else {
			testing.expect_value(t, out.error, outcome)
		}
		fake_bridge_stop(fb)
	}
}

@(test)
test_channel_media_send_plan_controls_upload :: proc(t: ^testing.T) {
	key_hex := "1111111111111111111111111111111111111111111111111111111111111111"
	kr := tkr(key_hex)
	sealed, _ := ctl_vault_seal("binary content", kr, context.temp_allocator)
	encrypted_name, _ := ctl_vault_seal("invoice.pdf", kr, context.temp_allocator)
	meta, _ := json.marshal(struct {
			ok:   bool,
			data: struct {
				name: string,
			},
		}{true, {encrypted_name}}, allocator = context.temp_allocator)
	content, _ := json.marshal(struct {
			ok:   bool,
			data: struct {
				content: string,
			},
		}{true, {sealed}}, allocator = context.temp_allocator)
	for mode in ([]string{"link", "native"}) {
		plan, _ := json.marshal(struct {
				ok:   bool,
				data: struct {
					mode: string,
				},
			}{true, {mode}}, allocator = context.temp_allocator)
		replies := []string {
			strings.concatenate({string(meta), "\n"}, context.temp_allocator),
			strings.concatenate({string(content), "\n"}, context.temp_allocator),
			strings.concatenate({string(plan), "\n"}, context.temp_allocator),
			"{\"ok\":true}\n",
		}
		fb := fake_bridge_start(t, replies)
		if fb == nil do continue
		ctl_channel_send_artifact(fb.endpoint, "test", "art", "caption", []string{"--vault-keyring", tkr_b64(key_hex)})
		testing.expect_value(t, fb.served, 4)
		testing.expect(t, strings.contains(fake_bridge_request(fb, 2), "/media/plan"))
		request := fake_bridge_request(fb, 3)
		testing.expect_value(t, ctl_channel_string(request, "text", ""), "caption")
		testing.expect_value(t, ctl_channel_string(request, "mime", ""), "application/pdf")
		testing.expect_value(t, ctl_channel_string(request, "name", ""), "invoice.pdf")
		testing.expect_value(t, strings.contains(request, "content_base64"), mode == "native")
		if mode == "native" {
			raw, err := base64.decode(
				ctl_channel_string(request, "content_base64", ""),
				allocator = context.temp_allocator,
			)
			testing.expect_value(t, err, nil)
			testing.expect_value(t, string(raw), "binary content")
		}
		fake_bridge_stop(fb)
	}
}

@(test)
test_channel_media_fetch_failures :: proc(t: ^testing.T) {
	kr := tkr("1111111111111111111111111111111111111111111111111111111111111111")
	cases := [][]string {
		{"{\"ok\":false}\n"},
		{"{\"ok\":true,\"data\":{\"outcome\":\"fetched\",\"content_base64\":\"!\"}}\n"},
		{
			"{\"ok\":true,\"data\":{\"outcome\":\"fetched\",\"content_base64\":\"YQ==\",\"size\":1}}\n",
			"{\"ok\":false}\n",
		},
		{
			"{\"ok\":true,\"data\":{\"outcome\":\"fetched\",\"content_base64\":\"YQ==\",\"size\":1}}\n",
			"{\"ok\":true,\"data\":{\"artifact_id\":\"art\"}}\n",
			"{\"ok\":false}\n",
		},
	}
	for replies in cases {
		fb := fake_bridge_start(t, replies)
		if fb == nil do continue
		c := Ctl_Channel_Media_Context {
			endpoint = fb.endpoint,
			token    = "test",
			keyring  = kr,
		}
		out := ctl_channel_resolve_attachment(
			&c,
			{attachment_id = "cha", kind = "document", name = "file", state = "pending"},
		)
		testing.expect_value(t, out.error, "fetch_failed")
		testing.expect_value(t, out.artifact_id, "")
		testing.expect_value(t, fb.served, len(replies))
		fake_bridge_stop(fb)
	}
}

Ctl_Media_Large_Bridge :: struct {
	listener: net.TCP_Socket,
	fetched:  string,
	served:   int,
}
ctl_media_large_bridge_thread :: proc(raw: rawptr) {
	fb := cast(^Ctl_Media_Large_Bridge)raw
	for i in 0 ..< 12 {
		client, _, err := net.accept_tcp(fb.listener)
		if err != nil do return
		_ = net.set_option(client, .Receive_Timeout, 5 * time.Second)
		buffer: [65536]byte
		for {
			n, recv_err := net.recv_tcp(client, buffer[:])
			if recv_err != nil || n <= 0 do break
			if strings.index_byte(string(buffer[:n]), '\n') >= 0 do break
		}
		response := "{\"ok\":true,\"data\":{\"artifact_id\":\"art_large\"}}\n"
		if i % 3 == 0 do response = fb.fetched
		sent := 0
		for sent < len(response) {
			n, send_err := net.send_tcp(client, transmute([]byte)response[sent:])
			if send_err != nil || n <= 0 do break
			sent += n
		}
		net.close(client)
		fb.served += 1
	}
}

@(test)
test_channel_media_large_attachments_release_scratch :: proc(t: ^testing.T) {
	// Four sequential 2 MiB files through the actual fetch/seal/create/stored
	// path. Track the arena's heap blocks separately from escaped metadata.
	size :: 2 * 1024 * 1024
	bytes := make([]byte, size, context.temp_allocator)
	for &b, i in bytes do b = byte(i % 251)
	encoded := base64.encode(bytes, allocator = context.temp_allocator)
	fetched, _ := json.marshal(struct {
			ok:   bool,
			data: struct {
				outcome, mime:  string,
				size:           int,
				content_base64: string,
			},
		}{true, {"fetched", "application/pdf", size, encoded}}, allocator = context.temp_allocator)
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, listen_err == nil) do return
	defer net.close(listener)
	bound, bound_err := net.bound_endpoint(listener)
	if !testing.expect(t, bound_err == nil) do return
	fb := Ctl_Media_Large_Bridge {
		listener = listener,
		fetched  = strings.concatenate({string(fetched), "\n"}, context.temp_allocator),
	}
	handle := thread.create_and_start_with_data(&fb, ctl_media_large_bridge_thread)
	defer thread.destroy(handle)
	defer thread.join(handle)
	endpoint := fmt.tprintf("tcp:127.0.0.1:%d", bound.port)
	scratch_track, output_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&scratch_track, context.allocator)
	defer mem.tracking_allocator_destroy(&scratch_track)
	mem.tracking_allocator_init(&output_track, context.allocator)
	defer mem.tracking_allocator_destroy(&output_track)
	output_allocator := mem.tracking_allocator(&output_track)
	c := Ctl_Channel_Media_Context {
		endpoint        = endpoint,
		token           = "test",
		keyring         = tkr("1111111111111111111111111111111111111111111111111111111111111111"),
		scratch_backing = mem.tracking_allocator(&scratch_track),
	}
	first_peak: i64
	for i in 0 ..< 4 {
		out: Ctl_Channel_Attachment_Out
		{
			context.temp_allocator = output_allocator
			out = ctl_channel_resolve_attachment(
				&c,
				{attachment_id = "cha_large", kind = "document", name = "large.pdf", state = "pending"},
			)
		}
		testing.expect_value(t, out.error, "")
		testing.expect_value(t, out.artifact_id, "art_large")
		testing.expect_value(t, out.mime, "application/pdf")
		testing.expect_value(t, out.size, i64(size))
		testing.expect_value(t, scratch_track.current_memory_allocated, i64(0))
		testing.expect_value(t, len(scratch_track.allocation_map), 0)
		testing.expect(t, output_track.current_memory_allocated < 256)
		if i == 0 do first_peak = scratch_track.peak_memory_allocated
		testing.expect_value(t, scratch_track.peak_memory_allocated, first_peak)
		fmt.printf(
			"D5 large file %d: scratch retained=%d, peak=%d, output=%d bytes\n",
			i + 1,
			scratch_track.current_memory_allocated,
			scratch_track.peak_memory_allocated,
			output_track.current_memory_allocated,
		)
		delete(out.artifact_id, output_allocator)
		delete(out.kind, output_allocator)
		delete(out.name, output_allocator)
		delete(out.mime, output_allocator)
		delete(out.error, output_allocator)
		delete(out.sent_as, output_allocator)
		testing.expect_value(t, output_track.current_memory_allocated, i64(0))
	}
	testing.expect(t, first_peak > size)
	testing.expect(t, first_peak < 96 * 1024 * 1024)
}
