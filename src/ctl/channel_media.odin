package main

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import httpc "odin_test:lib/httpc"
import vault "odin_test:lib/vault"

Ctl_Channel_Attachment_In :: struct {
	attachment_id, kind, name, mime, artifact_id, state, direction: string,
	size:                                                           i64,
}
Ctl_Channel_Attachment_Out :: struct {
	artifact_id, kind, name, mime: string,
	size:                          i64,
	error:                         string `json:"error,omitempty"`,
	sent_as:                       string `json:"sent_as,omitempty"`,
}

// The tree and returned text belong to the caller's temporary allocator.
ctl_channel_rewrite_attachments :: proc(
	response: string,
	resolve: proc(ctx: rawptr, a: Ctl_Channel_Attachment_In) -> Ctl_Channel_Attachment_Out,
	ctx: rawptr,
) -> (
	string,
	bool,
) {
	if !strings.contains(response, `"attachments"`) do return response, true
	value, err := json.parse(response, allocator = context.temp_allocator, parse_integers = true)
	if err != nil do return response, false
	root, root_ok := value.(json.Object)
	if !root_ok do return response, false
	data, _ := root["data"].(json.Object)
	if nested, wrapped := data["data"].(json.Object); wrapped do data = nested
	messages, _ := data["messages"].(json.Array)
	for message in messages {
		row, ok := message.(json.Object)
		if !ok do continue
		attachments, present := row["attachments"].(json.Array)
		if !present do continue
		for item, i in attachments {
			raw, encode_err := json.marshal(item, allocator = context.temp_allocator)
			if encode_err != nil do return response, false
			a: Ctl_Channel_Attachment_In
			if json.unmarshal(raw, &a, allocator = context.temp_allocator) != nil do return response, false
			a.direction = "inbound"
			if direction, typed := row["direction"].(json.String); typed && direction == "outbound" do a.direction = "outbound"
			out := resolve(ctx, a)
			encoded, out_err := json.marshal(out, allocator = context.temp_allocator)
			if out_err != nil do return response, false
			replacement, parse_err := json.parse(encoded, allocator = context.temp_allocator, parse_integers = true)
			if parse_err != nil do return response, false
			attachments[i] = replacement
		}
	}
	encoded, marshal_err := json.marshal(
		value,
		json.Marshal_Options{sort_maps_by_key = true},
		allocator = context.temp_allocator,
	)
	return string(encoded), marshal_err == nil
}

Ctl_Channel_Media_Context :: struct {
	endpoint, token: string,
	keyring:         ^vault.Vault_Keyring,
	scratch_backing: mem.Allocator,
}

// Resolve one file in a separately owned arena. Only the small output fields
// escape into the caller's allocator; all encoded/plaintext buffers die here.
ctl_channel_resolve_attachment :: proc(ctx: rawptr, a: Ctl_Channel_Attachment_In) -> Ctl_Channel_Attachment_Out {
	c := cast(^Ctl_Channel_Media_Context)ctx
	output_allocator := context.temp_allocator
	backing := c.scratch_backing
	if backing.procedure == nil do backing = runtime.heap_allocator()
	scratch: runtime.Arena
	if runtime.arena_init(&scratch, 1024 * 1024, backing) != nil {
		return {kind = a.kind, name = a.name, mime = a.mime, size = a.size, error = "fetch_failed"}
	}
	defer runtime.arena_destroy(&scratch)
	context.temp_allocator = runtime.arena_allocator(&scratch)
	context.allocator = context.temp_allocator
	out := ctl_channel_resolve_attachment_scratch(ctx, a)
	out.artifact_id = strings.clone(out.artifact_id, output_allocator)
	out.kind = strings.clone(out.kind, output_allocator)
	out.name = strings.clone(out.name, output_allocator)
	out.mime = strings.clone(out.mime, output_allocator)
	out.error = strings.clone(out.error, output_allocator)
	out.sent_as = strings.clone(out.sent_as, output_allocator)
	return out
}

ctl_channel_resolve_attachment_scratch :: proc(
	ctx: rawptr,
	a: Ctl_Channel_Attachment_In,
) -> Ctl_Channel_Attachment_Out {
	context.allocator = context.temp_allocator
	c := cast(^Ctl_Channel_Media_Context)ctx
	out := Ctl_Channel_Attachment_Out {
		artifact_id = a.artifact_id,
		kind        = a.kind,
		name        = a.name,
		mime        = a.mime,
		size        = a.size,
	}
	if a.direction == "outbound" {
		out.sent_as = a.state
		return out
	}
	if a.state == "stored" do return out
	out.artifact_id = ""
	if a.state == "too_large" || a.state == "unavailable" {
		out.error = a.state
		return out
	}
	out.error = "fetch_failed"
	if a.state != "pending" do return out
	if c.keyring == nil {
		out.error = "vault_unavailable"
		return out
	}
	response, reachable := ctl_agent_rest_local(
		c.endpoint,
		c.token,
		{method = .POST, path = ctl_api("agent-actions", "channel", "media", "fetch"), body = httpc.json_body(struct {
					attachment_id: string,
				}{a.attachment_id})},
	)
	if !reachable || !strings.contains(response, `"ok":true`) do return out
	fetch_value, fetch_err := json.parse(response, allocator = context.temp_allocator, parse_integers = true)
	if fetch_err != nil do return out
	fetch_root, _ := fetch_value.(json.Object)
	fetched, _ := fetch_root["data"].(json.Object)
	if nested, wrapped := fetched["data"].(json.Object); wrapped do fetched = nested
	state_value, _ := fetched["outcome"].(json.String)
	state := string(state_value)
	switch state {
	case "stored":
		id, _ := fetched["artifact_id"].(json.String)
		out.artifact_id = string(id)
		if out.artifact_id != "" do out.error = ""
		return out
	case "too_large", "unavailable":
		out.error = state
		return out
	case "fetched":
	case:
		return out
	}
	content_base64, _ := fetched["content_base64"].(json.String)
	bytes, decode_err := base64.decode(string(content_base64), allocator = context.temp_allocator)
	if decode_err != nil || len(bytes) == 0 do return out
	sealed, seal_ok := ctl_vault_seal(string(bytes), c.keyring, context.temp_allocator)
	name, name_ok := ctl_vault_seal(a.name, c.keyring, context.temp_allocator)
	if !seal_ok || !name_ok {
		out.error = "vault_unavailable"
		return out
	}
	mime_value, _ := fetched["mime"].(json.String)
	mime := string(mime_value)
	if mime == "" do mime = a.mime
	size, size_ok := fetched["size"].(json.Integer)
	if !size_ok do return out
	kind := ctl_channel_artifact_kind(a.kind)
	encoded := base64.encode(transmute([]byte)sealed, allocator = context.temp_allocator)
	params, _ := json.marshal(struct {
			name, kind, content_base64, content_type: string,
		}{name, kind, encoded, mime}, allocator = context.temp_allocator)
	created, create_ok := ctl_agent_local_call(c.endpoint, c.token, "agent.artifact.create", string(params))
	if !create_ok || !strings.contains(created, `"ok":true`) do return out
	artifact_id := ctl_channel_string(created, "artifact_id", "")
	if artifact_id == "" do return out
	stored, stored_ok := ctl_agent_rest_local(
		c.endpoint,
		c.token,
		{method = .POST, path = ctl_api("agent-actions", "channel", "media", "stored"), body = httpc.json_body(struct {
					attachment_id, artifact_id: string,
				}{a.attachment_id, artifact_id})},
	)
	if !stored_ok || !strings.contains(stored, `"ok":true`) do return out
	out.artifact_id = ctl_channel_string(stored, "artifact_id", "")
	if out.artifact_id == "" do return out
	out.mime = mime
	out.size = i64(size)
	out.error = ""
	return out
}

// ctl_channel_artifact_kind maps an inbound channel attachment kind to the
// artifact kind it is stored as. Voice notes and audio keep their own kinds so
// agents can tell them apart from documents (REQ-VOICE-5); video, documents and
// unknown kinds stay generic files.
ctl_channel_artifact_kind :: proc(attachment_kind: string) -> string {
	switch attachment_kind {
	case "image", "voice", "audio":
		return attachment_kind
	}
	return "file"
}

ctl_channel_read_media :: proc(endpoint, token, verb, params: string, args: []string) {
	context.allocator = context.temp_allocator
	response, ok := ctl_agent_local_call(endpoint, token, fmt.tprintf("agent.channel.%s", verb), params)
	if !ok {
		ctl_channel_media_error("local Bridge endpoint is not reachable")
		return
	}
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	c := Ctl_Channel_Media_Context {
		endpoint = endpoint,
		token    = token,
	}
	if key_ok do c.keyring = keyring
	rewritten, rewrite_ok := ctl_channel_rewrite_attachments(response, ctl_channel_resolve_attachment, &c)
	if !rewrite_ok do rewritten = response
	decrypted := ctl_decrypt_json_string(rewritten, keyring, key_ok, context.temp_allocator)
	fmt.println(decrypted)
	if strings.contains(response, `"ok":false`) do os.exit(1)
}

ctl_channel_media_error :: proc(message: string) {
	encoded, _ := json.marshal(struct {
			ok:      bool,
			message: string,
		}{false, message}, allocator = context.temp_allocator)
	fmt.println(string(encoded))
	os.exit(1)
}

ctl_channel_send_artifact :: proc(endpoint, token, artifact_id, caption: string, args: []string) {
	context.allocator = context.temp_allocator
	keyring, ok := ctl_read_vault_keyring(args, context.temp_allocator)
	if !ok do ctl_channel_media_error("vault keyring unavailable; cannot read the artifact on this machine")
	id_bytes, _ := json.marshal(struct {
			artifact_id: string,
		}{artifact_id}, allocator = context.temp_allocator)
	id_params := string(id_bytes)
	meta, meta_ok := ctl_agent_local_call(endpoint, token, "agent.artifact.show", id_params)
	if !meta_ok do ctl_channel_media_error("local Bridge endpoint is not reachable")
	artifact_require_ok(meta)
	opened_meta := ctl_decrypt_json_string(meta, keyring, true, context.temp_allocator)
	name := ctl_channel_string(opened_meta, "name", "")
	response, content_ok := ctl_agent_local_call(endpoint, token, "agent.artifact.content", id_params)
	if !content_ok do ctl_channel_media_error("local Bridge endpoint is not reachable")
	artifact_require_ok(response)
	content, result := ctl_vault_open(ctl_channel_string(response, "content", ""), keyring, context.temp_allocator)
	if result != .Ok do ctl_channel_media_error("artifact could not be decrypted on this machine")
	if len(content) == 0 do ctl_channel_media_error("artifact is empty")
	if size_error := ctl_artifact_content_size_error(len(content)); size_error != "" do ctl_channel_media_error(size_error)
	mime := ctl_channel_string(meta, "mime", "")
	if mime == "" do mime = ctl_channel_string(meta, "content_type", "")
	if mime == "" do mime = ctl_media_mime_from_name(name)
	plan, plan_ok := ctl_agent_rest_local(
		endpoint,
		token,
		{method = .POST, path = ctl_api("agent-actions", "channel", "media", "plan"), body = httpc.json_body(struct {
					mime: string,
					size: int,
				}{mime, len(content)})},
	)
	if !plan_ok do ctl_channel_media_error("local Bridge endpoint is not reachable")
	artifact_require_ok(plan)

	media := Ctl_Channel_Send_Media {
		name = name,
		mime = mime,
		size = len(content),
	}
	if ctl_channel_string(plan, "mode", "") == "native" {
		media.content_base64 = base64.encode(transmute([]byte)content, allocator = context.temp_allocator)
	}
	params, err := json.marshal(struct {
			text, artifact_id: string,
			media:             Ctl_Channel_Send_Media,
		}{caption, artifact_id, media}, allocator = context.temp_allocator)
	if err != nil do ctl_channel_media_error("cannot encode channel media")
	ctl_agent_call_task(endpoint, token, "agent.channel.send", string(params), args)
}

ctl_media_mime_from_name :: proc(name: string) -> string {
	lower := strings.to_lower(name, context.temp_allocator)
	extensions := []string {
		".jpg",
		".png",
		".webp",
		".gif",
		".ogg",
		".mp3",
		".m4a",
		".aac",
		".amr",
		".mp4",
		".3gp",
		".mov",
		".pdf",
		".txt",
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
	for ext, i in extensions {
		if strings.has_suffix(lower, ext) do return mimes[i]
	}
	return "application/octet-stream"
}

ctl_channel_string :: proc(response, key, fallback: string) -> string {
	return extract_json_string_unescaped(response, key, fallback, context.temp_allocator)
}

Ctl_Channel_Send_Media :: struct {
	name, mime:     string,
	size:           int,
	content_base64: string `json:"content_base64,omitempty"`,
}
