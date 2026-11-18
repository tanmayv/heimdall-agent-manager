package httpc

import "core:c"
import "core:crypto"
import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"

CONTENT_TYPE_JSON :: "application/json"
CONTENT_TYPE_FORM :: "application/x-www-form-urlencoded"
CONTENT_TYPE_OCTET_STREAM :: "application/octet-stream"

// ---- header helpers -----------------------------------------------------------

// bearer is "Authorization: Bearer <token>". The value is temp-allocated.
bearer :: proc(token: string) -> Header {
	parts := [2]string{"Bearer ", token}
	return Header{name = "Authorization", value = strings.concatenate(parts[:], context.temp_allocator)}
}

accept :: proc(media_type: string) -> Header {
	return Header{name = "Accept", value = media_type}
}

accept_json :: proc() -> Header {
	return Header{name = "Accept", value = CONTENT_TYPE_JSON}
}

// if_none_match is "If-None-Match: <entity-tag>". A bare tag is sent as a
// strong entity tag ("tag"); a value that is already an entity tag ("..." or
// W/"...") is sent unchanged. Temp-allocated.
if_none_match :: proc(tag: string) -> Header {
	if strings.has_prefix(tag, "\"") || strings.has_prefix(tag, "W/\"") do return Header{name = "If-None-Match", value = tag}
	parts := [3]string{"\"", tag, "\""}
	return Header{name = "If-None-Match", value = strings.concatenate(parts[:], context.temp_allocator)}
}

user_agent :: proc(value: string) -> Header {
	return Header{name = "User-Agent", value = value}
}

// oauth_client_basic is HTTP Basic client authentication for an OAuth 2.0 token
// endpoint (RFC 6749 §2.3.1): client id and secret are each form-urlencoded,
// joined with ':' and base64-encoded. Temp-allocated.
oauth_client_basic :: proc(client_id, client_secret: string) -> (h: Header, err: Error) {
	if ok, _ := init(); !ok do return {}, .Not_Initialized
	id := escape_temp(client_id) or_return
	secret := escape_temp(client_secret) or_return
	pair := [3]string{id, ":", secret}
	joined := strings.concatenate(pair[:], context.temp_allocator)
	encoded, b64_err := base64.encode(transmute([]byte)joined, allocator = context.temp_allocator)
	if b64_err != nil do return {}, .Internal
	value := [2]string{"Basic ", encoded}
	return Header{name = "Authorization", value = strings.concatenate(value[:], context.temp_allocator)}, .None
}

// Header names the wrapper (or libcurl) owns: setting them by hand would let a
// caller desynchronise framing or bypass the body's content type.
@(private)
RESERVED_HEADERS :: [?]string{
	"host", "content-length", "transfer-encoding", "connection", "expect",
	"content-type", "accept-encoding", "te", "upgrade", "keep-alive",
	"proxy-connection", "proxy-authorization", "trailer",
}

// header_valid reports whether a request header may be sent: the name is a
// non-empty RFC 9110 token and not reserved; the value carries no CR, LF, NUL or
// other control character except horizontal tab.
header_valid :: proc(h: Header) -> bool {
	if len(h.name) == 0 || len(h.name) > 256 do return false
	for i in 0..<len(h.name) {
		if !is_tchar(h.name[i]) do return false
	}
	for r in RESERVED_HEADERS {
		if strings.equal_fold(h.name, r) do return false
	}
	if len(h.value) > 16 * 1024 do return false
	for i in 0..<len(h.value) {
		b := h.value[i]
		if (b < 0x20 && b != '\t') || b == 0x7f do return false
	}
	return true
}

@(private)
is_tchar :: proc(b: byte) -> bool {
	switch {
	case b >= 'a' && b <= 'z', b >= 'A' && b <= 'Z', b >= '0' && b <= '9':
		return true
	}
	switch b {
	case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	}
	return false
}

// ---- bodies -----------------------------------------------------------------

// json_body marshals `value` with core:encoding/json now (so the body never
// aliases a caller temporary). Bytes are allocated with `allocator`.
// sort_keys orders map keys (json.Object / map[string]T) deterministically.
json_body :: proc(value: any, allocator := context.temp_allocator, sort_keys := false) -> Body {
	data, err := json.marshal(value, json.Marshal_Options{sort_maps_by_key = sort_keys}, allocator)
	if err != nil do return Json_Body{failed = true}
	return Json_Body{encoded = data}
}

// form_body sends fields as application/x-www-form-urlencoded, each name and
// value percent-encoded by libcurl. `fields` must outlive send().
form_body :: proc(fields: []Form_Field) -> Body {
	return Form_Body{fields = fields}
}

// raw_body sends bytes verbatim with the given content type (binary payloads
// such as an encrypted Web Push record).
raw_body :: proc(content_type: string, bytes: []byte) -> Body {
	return Raw_Body{content_type = content_type, bytes = bytes}
}

// relay_json_body forwards a JSON document received verbatim from a peer (an
// agent's request body the bridge relays to the hub). Never build the bytes by
// hand: marshal a value with json_body instead.
relay_json_body :: proc(document: string) -> Body {
	return Raw_Body{content_type = CONTENT_TYPE_JSON, bytes = transmute([]byte)document}
}

@(private)
escape_temp :: proc(s: string) -> (string, Error) {
	if len(s) == 0 do return "", .None
	escaped := curl_easy_escape(nil, raw_data(s), c.int(len(s)))
	if escaped == nil do return "", .Internal
	defer curl_free(rawptr(escaped))
	return strings.clone(string(escaped), context.temp_allocator), .None
}

// encode_form renders fields as "a=1&b=2" with libcurl's percent-encoding.
@(private)
encode_form :: proc(fields: []Form_Field) -> (out: string, err: Error) {
	b := strings.builder_make(context.temp_allocator)
	for f, i in fields {
		if f.name == "" do return "", .Invalid_Body
		if i > 0 do strings.write_byte(&b, '&')
		strings.write_string(&b, escape_temp(f.name) or_return)
		strings.write_byte(&b, '=')
		strings.write_string(&b, escape_temp(f.value) or_return)
	}
	return strings.to_string(b), .None
}

// Multipart_Part values are borrowed for the duration of multipart_body. The
// returned Raw_Body owns bytes and content_type in the requested allocator.
Multipart_Part :: struct {
	name: string,
	filename: string,
	content_type: string,
	value: []byte,
}

// A random boundary is retried before encoding if any value contains it.
multipart_body :: proc(parts: []Multipart_Part, allocator := context.temp_allocator) -> Body {
	for _ in 0..<3 {
		random: [16]byte
		crypto.rand_bytes(random[:])
		hex := "0123456789abcdef"
		boundary: [41]byte
		prefix := "----ninjy"
		copy(boundary[:9], transmute([]byte)prefix)
		for b, i in random {
			boundary[9 + 2*i] = hex[b >> 4]
			boundary[10 + 2*i] = hex[b & 15]
		}
		candidate := string(boundary[:])
		if multipart_boundary_absent(parts, candidate) do return multipart_body_with_boundary(parts, candidate, allocator)
	}
	return Raw_Body{}
}

@(private)
multipart_boundary_absent :: proc(parts: []Multipart_Part, boundary: string) -> bool {
	if boundary == "" do return false
	for part in parts {
		if strings.contains(string(part.value), boundary) do return false
	}
	return true
}

@(private)
multipart_parameter_size :: proc(value: string) -> int {
	size := 0
	for b in transmute([]byte)value {
		count := 1
		if b == '"' || b == '\r' || b == '\n' do count = 3
		if size > max(int) - count do return -1
		size += count
	}
	return size
}

@(private)
multipart_add_size :: proc(total: ^int, size: int) -> bool {
	if size < 0 || total^ > max(int) - size do return false
	total^ += size
	return true
}

@(private)
multipart_write :: proc(out: []byte, offset: ^int, value: string) {
	offset^ += copy(out[offset^:], transmute([]byte)value)
}

@(private)
multipart_write_parameter :: proc(out: []byte, offset: ^int, value: string) {
	for b in transmute([]byte)value {
		switch b {
		case '"': multipart_write(out, offset, "%22")
		case '\r': multipart_write(out, offset, "%0D")
		case '\n': multipart_write(out, offset, "%0A")
		case:
			out[offset^] = b
			offset^ += 1
		}
	}
}

// Fixed-boundary seam. Validate and size before allocating so file bytes are
// written exactly once, directly into the requested allocator.
// Invalid bodies use Raw_Body{} so send reports Invalid_Body.
multipart_body_with_boundary :: proc(parts: []Multipart_Part, boundary: string, allocator := context.temp_allocator) -> Body {
	if !multipart_boundary_absent(parts, boundary) do return Raw_Body{}
	for b in transmute([]byte)boundary {
		if !((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '-') do return Raw_Body{}
	}
	disposition :: "\r\nContent-Disposition: form-data; name=\""
	filename :: "; filename=\""
	type_header :: "\"\r\nContent-Type: "
	total := 0
	for size in ([]int{len(boundary), len("----\r\n")}) {
		if !multipart_add_size(&total, size) do return Raw_Body{}
	}
	for part in parts {
		for size in ([]int{len("--"), len(boundary), len(disposition), multipart_parameter_size(part.name), len("\""), len("\r\n\r\n"), len(part.value), len("\r\n")}) {
			if !multipart_add_size(&total, size) do return Raw_Body{}
		}
		if part.filename != "" {
			content_type := part.content_type
			if content_type == "" do content_type = CONTENT_TYPE_OCTET_STREAM
			for b in transmute([]byte)content_type {
				if b < 0x20 || b == 0x7f do return Raw_Body{}
			}
			for size in ([]int{len(filename), multipart_parameter_size(part.filename), len(type_header), len(content_type)}) {
				if !multipart_add_size(&total, size) do return Raw_Body{}
			}
		}
	}
	out := make([]byte, total, allocator)
	offset := 0
	for part in parts {
		multipart_write(out, &offset, "--")
		multipart_write(out, &offset, boundary)
		multipart_write(out, &offset, disposition)
		multipart_write_parameter(out, &offset, part.name)
		multipart_write(out, &offset, "\"")
		if part.filename != "" {
			multipart_write(out, &offset, filename)
			multipart_write_parameter(out, &offset, part.filename)
			multipart_write(out, &offset, type_header)
			content_type := part.content_type
			if content_type == "" do content_type = CONTENT_TYPE_OCTET_STREAM
			multipart_write(out, &offset, content_type)
		}
		multipart_write(out, &offset, "\r\n\r\n")
		offset += copy(out[offset:], part.value)
		multipart_write(out, &offset, "\r\n")
	}
	multipart_write(out, &offset, "--")
	multipart_write(out, &offset, boundary)
	multipart_write(out, &offset, "--\r\n")
	assert(offset == total)
	type_parts := [2]string{"multipart/form-data; boundary=", boundary}
	return Raw_Body{content_type = strings.concatenate(type_parts[:], allocator), bytes = out}
}
