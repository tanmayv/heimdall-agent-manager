package contracts

import "core:bytes"
import "core:crypto/ecdh"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/json"
import "core:mem"
import "core:net"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import vault "odin_test:lib/vault"

SECURE_FORM_SCHEMA_MAX :: 32768
SECURE_FORM_PLAINTEXT_MAX :: 32768
SECURE_FORM_ENVELOPE_MAX :: 65536
SECURE_FORM_PROOF_MAX :: 262144
SECURE_FORM_SCRIPT_MAX :: 32768
SECURE_FORM_MANIFEST_MAX :: 262144
SECURE_FORM_FIELDS_MAX :: 12
SECURE_FORM_CHOICES_MAX :: 12
SECURE_FORM_VALUE_MAX :: 8192
SECURE_FORM_LABEL_MAX :: 200
SECURE_FORM_PURPOSE_MAX :: 200
SECURE_FORM_RETENTION_MS :: 300_000
SECURE_FORM_TOMBSTONE_GRACE_MS :: 60_000
SECURE_FORM_LOGO :: "heimdall"
SECURE_FORM_MANIFEST :: "heimdall.secure-form.manifest.v1"
SECURE_FORM_REQUEST :: "heimdall.secure-form.request.v1"
SECURE_FORM_ANSWER :: "heimdall.secure-form.answer.v1"

Secure_Form_Exit :: enum int {
	Success = 0,
	Unauthorized = 20,
	Declined = 21,
	Response_Expired = 22,
	Cancelled = 23,
	Not_Delivered = 24,
	Stdin_Failed = 25,
	Child_Failed = 26,
	Execution_Expired = 27,
	Unknown = 28,
	Retention_Expired = 29,
}

// Wire records use exact UTF-8 JSON members and version 1. Byte strings
// use lowercase hex, except ciphertext (padded standard base64). Request ID
// and digests are 32 bytes, points 65, nonce 12, raw signatures 64. Ciphertext
// includes its 16-byte GCM tag. JSON is transport only: signatures always
// cover the binary, u32-BE length-framed transcripts below.
// Transcript counters and frame counters are canonical unsigned decimal strings.
Secure_Form_Registration :: struct {
	version: int,
	request: Secure_Form_Request,
	entry: Secure_Form_Entry,
	schema, signature: string,
}
Secure_Form_Submission :: struct {
	version: int,
	request_id, generation: string,
	envelope: string, // Exact bounded JSON answer bytes.
	directory_proof: string,
}
// Status/decline/cancel use the same reference payload on distinct actions.
// Live ACKs contain only metadata. They never carry answer or invocation bytes.
Secure_Form_Reference :: struct {
	version: int,
	request_id, generation: string,
}
Secure_Form_Ack :: struct {
	version: int,
	request_id, generation: string,
	state: string,
	code: Maybe(Secure_Form_Exit),
}
Secure_Form_Retry_Command :: struct {
	version: int,
	request_id, after_attempt: string,
}
Secure_Form_Request :: struct {
	owner, bridge, generation, instance, task, conversation, request_id, deadline: string,
	manifest_digest, destination, script_name, schema_digest, recipient_key: string,
}
Secure_Form_Answer :: struct {
	request_digest, device, directory_sequence, directory_head, sender_key, nonce, ciphertext, signature: string,
}
Secure_Form_Choice :: struct { id, label: string }
Secure_Form_Field :: struct {
	id, label, type: string,
	choices: []Secure_Form_Choice `json:"choices,omitempty"`,
}
Secure_Form_Schema :: struct {
	version: int,
	purpose: string,
	logo: string `json:"logo,omitempty"`,
	fields: []Secure_Form_Field,
}
Secure_Form_File :: struct { path, sha256: string }
Secure_Form_Entry :: struct {
	id, purpose, destination, script, interpreter, controller: string,
	files: []Secure_Form_File,
}

// Core accepts some JSON5-like escapes even in its JSON specification.
// Enforce valid Unicode scalar sequences before it unquotes any string.
@(private = "file")
secure_form_json_string :: proc(token: string) -> bool {
	for i := 1; i < len(token) - 1; i += 1 {
		if token[i] != '\\' do continue
		i += 1
		if i >= len(token) - 1 do return false
		switch token[i] {
		case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
		case 'u':
			if i + 4 >= len(token) - 1 do return false
			unit: [2]byte
			if !vault.hex_decode_into(unit[:], token[i + 1:i + 5]) do return false
			i += 4
			if unit[0] >= 0xdc && unit[0] <= 0xdf do return false
			if unit[0] >= 0xd8 && unit[0] <= 0xdb {
				if i + 6 >= len(token) - 1 || token[i + 1:i + 3] != "\\u" do return false
				if !vault.hex_decode_into(unit[:], token[i + 3:i + 7]) || unit[0] < 0xdc || unit[0] > 0xdf do return false
				i += 6
			}
		case:
			return false
		}
	}
	return true
}

@(private)
secure_form_object :: proc(raw: string, limit: int, allocator: mem.Allocator) -> (json.Object, bool) {
	if len(raw) > limit || !utf8.valid_string(raw) do return nil, false
	// Bound recursion and reject empty keys, which the core parser drops.
	t := json.make_tokenizer(raw, .JSON, true)
	depth := 0
	previous: json.Token
	seen_root := false
	for {
		token, err := json.get_token(&t)
		if err == .EOF do break
		if err != nil do return nil, false
		if depth == 0 {
			if seen_root || token.kind != .Open_Brace do return nil, false
			seen_root = true
		}
		#partial switch token.kind {
		case .Open_Brace, .Open_Bracket:
			depth += 1
			if depth > 8 do return nil, false
		case .Close_Brace, .Close_Bracket:
			if previous.kind == .Comma do return nil, false
			depth -= 1
			if depth < 0 do return nil, false
		case .String:
			if !secure_form_json_string(token.text) do return nil, false
		case .Colon:
			if previous.text == "\"\"" do return nil, false
		}
		previous = token
	}
	if !seen_root || depth != 0 || !json.is_valid(transmute([]byte)raw, .JSON, true) do return nil, false
	root, err := json.parse_string(raw, .JSON, true, allocator)
	if err != nil do return nil, false
	o, ok := root.(json.Object)
	return o, ok
}

@(private = "file")
secure_form_text :: proc(s: string, limit: int) -> bool {
	if !utf8.valid_string(s) || strings.trim_space(s) == "" do return false
	n := 0
	for r in s {
		n += 1
		if n > limit || r < 32 || (r >= 127 && r <= 159) || r == 0x2028 || r == 0x2029 || r == '<' || r == '>' do return false
	}
	return true
}

secure_form_parse_schema :: proc(raw: string, allocator := context.temp_allocator) -> (Secure_Form_Schema, bool) {
	o, ok := secure_form_object(raw, SECURE_FORM_SCHEMA_MAX, allocator)
	if !ok || !mq_known_fields(o, {"version", "purpose", "logo", "fields"}) do return {}, false
	version, _ := o["version"].(json.Integer)
	purpose, logo := mq_string(o, "purpose"), mq_string(o, "logo")
	if version != 1 || !secure_form_text(purpose, SECURE_FORM_PURPOSE_MAX) || ("logo" in o && logo != SECURE_FORM_LOGO) do return {}, false
	rows, rows_ok := o["fields"].(json.Array)
	if !rows_ok || len(rows) < 1 || len(rows) > SECURE_FORM_FIELDS_MAX do return {}, false
	fields := make([]Secure_Form_Field, len(rows), allocator)
	for row, i in rows {
		f, field_ok := row.(json.Object)
		if !field_ok || !mq_known_fields(f, {"id", "label", "type", "choices"}) do return {}, false
		id, label, kind := mq_string(f, "id"), mq_string(f, "label"), mq_string(f, "type")
		if !multi_question_valid_id(id) || !secure_form_text(label, SECURE_FORM_LABEL_MAX) do return {}, false
		for prev in fields[:i] do if prev.id == id do return {}, false
		fields[i] = {id = id, label = label, type = kind}
		switch kind {
		case "text", "password":
			if "choices" in f do return {}, false
		case "single", "multiple":
			options, options_ok := f["choices"].(json.Array)
			if !options_ok || len(options) < 1 || len(options) > SECURE_FORM_CHOICES_MAX do return {}, false
			choices := make([]Secure_Form_Choice, len(options), allocator)
			for option, j in options {
				c, choice_ok := option.(json.Object)
				if !choice_ok || !mq_known_fields(c, {"id", "label"}) do return {}, false
				cid, clabel := mq_string(c, "id"), mq_string(c, "label")
				if !multi_question_valid_id(cid) || !secure_form_text(clabel, SECURE_FORM_LABEL_MAX) do return {}, false
				for prev in choices[:j] do if prev.id == cid do return {}, false
				choices[j] = {cid, clabel}
			}
			fields[i].choices = choices
		case:
			return {}, false
		}
	}
	return {1, purpose, logo, fields}, true
}

@(private = "file")
secure_form_choice :: proc(f: Secure_Form_Field, id: string) -> bool {
	for choice in f.choices do if choice.id == id do return true
	return false
}

// Callers provide a protected and scrubbed allocator for secret material.
// The local stdin document wraps the resulting map as {"version":1,"values":{...}}.
secure_form_parse_values :: proc(raw: string, schema: Secure_Form_Schema, allocator: mem.Allocator) -> (json.Object, bool) {
	o, ok := secure_form_object(raw, SECURE_FORM_PLAINTEXT_MAX, allocator)
	if !ok || len(o) != len(schema.fields) do return nil, false
	for f in schema.fields {
		if f.type == "multiple" {
			rows, rows_ok := o[f.id].(json.Array)
			if !rows_ok || len(rows) == 0 || len(rows) > len(f.choices) do return nil, false
			for row, i in rows {
				id, id_ok := row.(json.String)
				if !id_ok || !secure_form_choice(f, string(id)) do return nil, false
				for prev in rows[:i] {
					other, _ := prev.(json.String)
					if other == id do return nil, false
				}
			}
		} else {
			s, s_ok := o[f.id].(json.String)
			if !s_ok || len(s) < 1 || len(s) > SECURE_FORM_VALUE_MAX || !utf8.valid_string(string(s)) do return nil, false
			if f.type == "single" && !secure_form_choice(f, string(s)) do return nil, false
		}
	}
	return o, true
}

@(private = "file")
secure_form_path :: proc(path: string) -> bool {
	if len(path) < 2 || len(path) > 4096 || path[0] != '/' || !utf8.valid_string(path) do return false
	for c in path do if c < 32 || c == 127 do return false
	rest := path[1:]
	for {
		i := strings.index_byte(rest, '/')
		head := rest if i < 0 else rest[:i]
		if head == "" || head == "." || head == ".." do return false
		if i < 0 do return true
		rest = rest[i + 1:]
	}
}

// Compare the original string, never repair or normalize input. The UI
// still compares with the browser URL serializer before displaying the form.
secure_form_origin_valid :: proc(origin: string) -> bool {
	if !strings.has_prefix(origin, "https://") || len(origin) > 255 || len(origin) <= 8 do return false
	authority := origin[8:]
	host, suffix: string
	if authority[0] == '[' {
		end := strings.index_byte(authority, ']')
		if end < 0 do return false
		host, suffix = authority[1:end], authority[end + 1:]
		ip, ok := net.parse_ip6_address(host)
		if !ok || net.address_to_string(ip) != host do return false
	} else {
		end := strings.index_byte(authority, ':')
		host = authority if end < 0 else authority[:end]
		if end >= 0 do suffix = authority[end:]
		if len(host) == 0 do return false
		domain := host
		if domain[len(domain) - 1] == '.' do domain = domain[:len(domain) - 1]
		for {
			dot := strings.index_byte(domain, '.')
			label := domain if dot < 0 else domain[:dot]
			if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label) - 1] == '-' do return false
			numeric := true
			for c in label {
				if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') do return false
				if c < '0' || c > '9' do numeric = false
			}
			if dot < 0 {
				// Browsers reinterpret numeric-ending names as IPv4.
				if numeric || strings.has_prefix(label, "0x") {
					ip, ok := net.parse_ip4_address(host)
					if !ok || net.address_to_string(ip) != host do return false
				}
				break
			}
			domain = domain[dot + 1:]
		}
	}
	if suffix != "" {
		if suffix[0] != ':' do return false
		port, ok := secure_form_uint(suffix[1:])
		if !ok || port == 443 || port > 65535 do return false
	}
	return true
}

@(private = "file")
secure_form_entry_valid :: proc(e: Secure_Form_Entry) -> bool {
	if !secure_form_origin_valid(e.destination) do return false
	if !multi_question_valid_id(e.id) || !secure_form_text(e.purpose, SECURE_FORM_PURPOSE_MAX) || !secure_form_path(e.script) ||
	   !secure_form_path(e.interpreter) || (e.controller != "" && !secure_form_path(e.controller)) {
		return false
	}
	if len(e.files) < 1 || len(e.files) > 64 do return false
	has_interpreter, has_controller := false, e.controller == ""
	for f, i in e.files {
		if !secure_form_path(f.path) || f.path == e.script || len(f.sha256) != 64 || !vault.is_lower_hex(f.sha256) do return false
		for prev in e.files[:i] do if prev.path == f.path do return false
		if f.path == e.interpreter do has_interpreter = true
		if f.path == e.controller do has_controller = true
	}
	return has_interpreter && has_controller
}

@(private = "file")
secure_form_parse_entry :: proc(value: json.Value, allocator: mem.Allocator) -> (Secure_Form_Entry, bool) {
	e, e_ok := value.(json.Object)
	if !e_ok || !mq_known_fields(e, {"id", "purpose", "destination", "script", "interpreter", "controller", "files"}) do return {}, false
	controller, c_ok := e["controller"].(json.String)
	rows_files, f_ok := e["files"].(json.Array)
	if !c_ok || !f_ok || len(rows_files) > 64 do return {}, false
	entry := Secure_Form_Entry{
		mq_string(e, "id"), mq_string(e, "purpose"), mq_string(e, "destination"), mq_string(e, "script"),
		mq_string(e, "interpreter"), string(controller), make([]Secure_Form_File, len(rows_files), allocator),
	}
	for file, j in rows_files {
		f, file_ok := file.(json.Object)
		if !file_ok || !mq_known_fields(f, {"path", "sha256"}) do return {}, false
		entry.files[j] = {mq_string(f, "path"), mq_string(f, "sha256")}
	}
	if !secure_form_entry_valid(entry) do return {}, false
	return entry, true
}

secure_form_parse_manifest :: proc(raw: string, allocator := context.temp_allocator) -> ([]Secure_Form_Entry, bool) {
	o, ok := secure_form_object(raw, SECURE_FORM_MANIFEST_MAX, allocator)
	if !ok || !mq_known_fields(o, {"version", "entries"}) do return nil, false
	version, _ := o["version"].(json.Integer)
	rows, rows_ok := o["entries"].(json.Array)
	if version != 1 || !rows_ok || len(rows) > 64 do return nil, false
	entries := make([]Secure_Form_Entry, len(rows), allocator)
	for row, i in rows {
		entry, entry_ok := secure_form_parse_entry(row, allocator)
		if !entry_ok do return nil, false
		for prev in entries[:i] do if prev.id == entry.id || prev.script == entry.script do return nil, false
		entries[i] = entry
	}
	return entries, true
}

@(private = "file")
secure_form_frame :: proc(parts: [][]byte, allocator: mem.Allocator) -> []byte {
	total := 0
	for part in parts do total += 4 + len(part)
	out := make([]byte, total, allocator)
	i := 0
	for part in parts {
		n := u32(len(part))
		out[i] = byte(n >> 24)
		out[i + 1] = byte(n >> 16)
		out[i + 2] = byte(n >> 8)
		out[i + 3] = byte(n)
		copy(out[i + 4:], part)
		i += 4 + len(part)
	}
	return out
}

secure_form_manifest_transcript :: proc(e: Secure_Form_Entry, allocator := context.temp_allocator) -> ([]byte, bool) {
	if !secure_form_entry_valid(e) do return nil, false
	ordered: [64]Secure_Form_File
	copy(ordered[:], e.files)
	slice.sort_by(ordered[:len(e.files)], proc(a, b: Secure_Form_File) -> bool {
		return bytes.compare(transmute([]byte)a.path, transmute([]byte)b.path) < 0
	})
	count: [24]byte
	parts: [136][]byte
	for s, i in ([]string{SECURE_FORM_MANIFEST, e.id, e.purpose, e.destination, e.script,
		e.interpreter, e.controller, strconv.write_uint(count[:], u64(len(e.files)), 10)}) {
		parts[i] = transmute([]byte)s
	}
	for f, i in ordered[:len(e.files)] {
		parts[8 + i * 2] = transmute([]byte)f.path
		parts[9 + i * 2] = transmute([]byte)f.sha256
	}
	return secure_form_frame(parts[:8 + len(e.files) * 2], allocator), true
}

@(private = "file")
secure_form_hex :: proc(dst: []byte, s: string) -> bool {
	return len(s) == len(dst) * 2 && vault.is_lower_hex(s) && vault.hex_decode_into(dst, s)
}

secure_form_uint :: proc(s: string) -> (u64, bool) {
	if len(s) == 0 || len(s) > 20 || (len(s) > 1 && s[0] == '0') do return 0, false
	for c in s do if c < '0' || c > '9' do return 0, false
	return strconv.parse_u64(s)
}

@(private = "file")
secure_form_point :: proc(dst: ^[65]byte, s: string) -> bool {
	if !secure_form_hex(dst[:], s) || dst[0] != 4 do return false
	key: ecdh.Public_Key
	defer ecdh.public_key_clear(&key)
	return ecdh.public_key_set_bytes(&key, .SECP256R1, dst[:])
}

secure_form_raw_signature :: proc(s: string) -> (sig: [64]byte, ok: bool) {
	order, zero: [32]byte
	_ = vault.hex_decode_into(order[:], "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
	if !secure_form_hex(sig[:], s) do return {}, false
	for scalar in ([][]byte{sig[:32], sig[32:]}) {
		if bytes.compare(scalar, zero[:]) == 0 || bytes.compare(scalar, order[:]) >= 0 do return {}, false
	}
	return sig, true
}

secure_form_request_transcript :: proc(r: Secure_Form_Request, allocator := context.temp_allocator) -> ([]byte, bool) {
	for id in ([]string{r.owner, r.bridge, r.instance, r.task, r.conversation}) {
		if !multi_question_valid_id(id) do return nil, false
	}
	gen, g_ok := secure_form_uint(r.generation)
	deadline, d_ok := secure_form_uint(r.deadline)
	if !g_ok || gen == 0 || !d_ok || deadline == 0 do return nil, false
	id, manifest, schema: [32]byte
	pub: [65]byte
	if !secure_form_hex(id[:], r.request_id) || !secure_form_hex(manifest[:], r.manifest_digest) ||
	   !secure_form_hex(schema[:], r.schema_digest) || !secure_form_point(&pub, r.recipient_key) {
		return nil, false
	}
	if !secure_form_text(r.destination, 255) || !secure_form_text(r.script_name, 4096) do return nil, false
	return secure_form_frame({
		transmute([]byte)string(SECURE_FORM_REQUEST), transmute([]byte)r.owner, transmute([]byte)r.bridge,
		transmute([]byte)r.generation, transmute([]byte)r.instance, transmute([]byte)r.task, transmute([]byte)r.conversation,
		id[:], transmute([]byte)r.deadline, manifest[:], transmute([]byte)r.destination, transmute([]byte)r.script_name,
		schema[:], pub[:],
	}, allocator), true
}

secure_form_answer_transcript :: proc(e: Secure_Form_Answer, allocator := context.temp_allocator) -> ([]byte, bool) {
	if !multi_question_valid_id(e.device) do return nil, false
	_, seq_ok := secure_form_uint(e.directory_sequence)
	request, head: [32]byte
	pub: [65]byte
	nonce: [12]byte
	if !seq_ok || !secure_form_hex(request[:], e.request_digest) || !secure_form_hex(head[:], e.directory_head) ||
	   !secure_form_point(&pub, e.sender_key) || !secure_form_hex(nonce[:], e.nonce) {
		return nil, false
	}
	if len(e.ciphertext) < 24 || len(e.ciphertext) > 4 * ((SECURE_FORM_PLAINTEXT_MAX + 18) / 3) do return nil, false
	ct, err := base64.decode(e.ciphertext, allocator = allocator)
	if err != nil do return nil, false
	defer delete(ct, allocator)
	if len(ct) <= 16 || len(ct) > SECURE_FORM_PLAINTEXT_MAX + 16 do return nil, false
	encoded := base64.encode(ct, allocator = allocator)
	defer delete(encoded, allocator)
	if encoded != e.ciphertext do return nil, false
	return secure_form_frame({
		transmute([]byte)string(SECURE_FORM_ANSWER), request[:], transmute([]byte)e.device,
		transmute([]byte)e.directory_sequence, head[:], pub[:], nonce[:], ct[:],
	}, allocator), true
}

secure_form_parse_registration :: proc(raw: string, allocator := context.temp_allocator) -> (Secure_Form_Registration, bool) {
	o, ok := secure_form_object(raw, 6 * SECURE_FORM_SCHEMA_MAX + 512 * 1024, allocator)
	if !ok || !mq_known_fields(o, {"version", "request", "entry", "schema", "signature"}) do return {}, false
	version, _ := o["version"].(json.Integer)
	req, req_ok := o["request"].(json.Object)
	if version != 1 || !req_ok || !mq_known_fields(req, {"owner", "bridge", "generation", "instance",
		"task", "conversation", "request_id", "deadline", "manifest_digest", "destination",
		"script_name", "schema_digest", "recipient_key"}) {
		return {}, false
	}
	r := Secure_Form_Request{
		mq_string(req, "owner"), mq_string(req, "bridge"), mq_string(req, "generation"),
		mq_string(req, "instance"), mq_string(req, "task"), mq_string(req, "conversation"),
		mq_string(req, "request_id"), mq_string(req, "deadline"), mq_string(req, "manifest_digest"),
		mq_string(req, "destination"), mq_string(req, "script_name"), mq_string(req, "schema_digest"),
		mq_string(req, "recipient_key"),
	}
	entry, entry_ok := secure_form_parse_entry(o["entry"], allocator)
	schema, signature := mq_string(o, "schema"), mq_string(o, "signature")
	_, sig_ok := secure_form_raw_signature(signature)
	if !entry_ok || !sig_ok || !secure_form_display_matches(r, entry, schema, allocator) do return {}, false
	t, t_ok := secure_form_request_transcript(r, allocator)
	if !t_ok do return {}, false
	delete(t, allocator)
	return {1, r, entry, schema, signature}, true
}

// Parse the inner envelope independently of its directory proof attachment.
// Format acceptance does not verify the bridge/device signature or the proof,
// which require the authenticated endpoint's current trust state.
secure_form_parse_answer :: proc(raw: string, allocator := context.temp_allocator) -> (Secure_Form_Answer, bool) {
	o, ok := secure_form_object(raw, SECURE_FORM_ENVELOPE_MAX, allocator)
	if !ok || !mq_known_fields(o, {"request_digest", "device", "directory_sequence", "directory_head",
		"sender_key", "nonce", "ciphertext", "signature"}) {
		return {}, false
	}
	e := Secure_Form_Answer{
		mq_string(o, "request_digest"), mq_string(o, "device"), mq_string(o, "directory_sequence"),
		mq_string(o, "directory_head"), mq_string(o, "sender_key"), mq_string(o, "nonce"),
		mq_string(o, "ciphertext"), mq_string(o, "signature"),
	}
	_, sig_ok := secure_form_raw_signature(e.signature)
	if !sig_ok do return {}, false
	t, t_ok := secure_form_answer_transcript(e, allocator)
	if !t_ok do return {}, false
	delete(t, allocator)
	return e, true
}

secure_form_parse_submission :: proc(raw: string, allocator := context.temp_allocator) -> (Secure_Form_Submission, bool) {
	// Each inner byte can occupy at most six bytes in the outer JSON string.
	o, ok := secure_form_object(raw, 6 * (SECURE_FORM_ENVELOPE_MAX + SECURE_FORM_PROOF_MAX) + 1024, allocator)
	if !ok || !mq_known_fields(o, {"version", "request_id", "generation", "envelope", "directory_proof"}) do return {}, false
	version, _ := o["version"].(json.Integer)
	id, generation := mq_string(o, "request_id"), mq_string(o, "generation")
	envelope, proof := mq_string(o, "envelope"), mq_string(o, "directory_proof")
	decoded: [32]byte
	gen, gen_ok := secure_form_uint(generation)
	if version != 1 || !secure_form_hex(decoded[:], id) || !gen_ok || gen == 0 do return {}, false
	if len(proof) == 0 || len(proof) > SECURE_FORM_PROOF_MAX || !utf8.valid_string(proof) do return {}, false
	_, envelope_ok := secure_form_parse_answer(envelope, allocator)
	if !envelope_ok do return {}, false
	return {1, id, generation, envelope, proof}, true
}

@(private = "file")
secure_form_reference :: proc(o: json.Object) -> (Secure_Form_Reference, bool) {
	version, _ := o["version"].(json.Integer)
	id, generation := mq_string(o, "request_id"), mq_string(o, "generation")
	decoded: [32]byte
	gen, gen_ok := secure_form_uint(generation)
	if version != 1 || !secure_form_hex(decoded[:], id) || !gen_ok || gen == 0 do return {}, false
	return {1, id, generation}, true
}

secure_form_parse_reference :: proc(raw: string, allocator := context.temp_allocator) -> (Secure_Form_Reference, bool) {
	o, ok := secure_form_object(raw, 1024, allocator)
	if !ok || !mq_known_fields(o, {"version", "request_id", "generation"}) do return {}, false
	return secure_form_reference(o)
}

// An ACK may report a nonterminal routing state, or one fixed final outcome.
secure_form_parse_ack :: proc(raw: string, allocator := context.temp_allocator) -> (Secure_Form_Ack, bool) {
	o, ok := secure_form_object(raw, 1024, allocator)
	if !ok || !mq_known_fields(o, {"version", "request_id", "generation", "state", "code"}) do return {}, false
	ref, ref_ok := secure_form_reference(o)
	if !ref_ok || !("code" in o) do return {}, false
	state := mq_string(o, "state")
	ack := Secure_Form_Ack{1, ref.request_id, ref.generation, state, nil}
	switch state {
	case "pending", "forwarding", "accepted":
		if _, nonterminal := o["code"].(json.Null); !nonterminal do return {}, false
	case "final":
		code, terminal := o["code"].(json.Integer)
		if !terminal || (code != 0 && (code < 20 || code > 29)) do return {}, false
		ack.code = Secure_Form_Exit(code)
	case:
		return {}, false
	}
	return ack, true
}

secure_form_parse_retry :: proc(raw: string, allocator := context.temp_allocator) -> (Secure_Form_Retry_Command, bool) {
	o, ok := secure_form_object(raw, 1024, allocator)
	if !ok || !mq_known_fields(o, {"version", "request_id", "after_attempt"}) do return {}, false
	version, _ := o["version"].(json.Integer)
	id, after := mq_string(o, "request_id"), mq_string(o, "after_attempt")
	decoded: [32]byte
	n, n_ok := secure_form_uint(after)
	if version != 1 || !secure_form_hex(decoded[:], id) || !n_ok || n == 0 do return {}, false
	return {1, id, after}, true
}

secure_form_digest :: proc(data: []byte) -> (digest: [32]byte) {
	c: sha2.Context_256
	sha2.init_256(&c)
	sha2.update(&c, data)
	sha2.final(&c, digest[:])
	return
}

secure_form_display_matches :: proc(r: Secure_Form_Request, e: Secure_Form_Entry, raw: string, allocator := context.temp_allocator) -> bool {
	schema, ok := secure_form_parse_schema(raw, allocator)
	if !ok || r.destination != e.destination || schema.purpose != e.purpose do return false
	name := e.script
	for c, i in e.script do if c == '/' do name = e.script[i + 1:]
	if name != r.script_name do return false
	manifest, m_ok := secure_form_manifest_transcript(e, allocator)
	s, m: [32]byte
	return m_ok && secure_form_hex(s[:], r.schema_digest) && secure_form_hex(m[:], r.manifest_digest) &&
		secure_form_digest(transmute([]byte)raw) == s && secure_form_digest(manifest) == m
}

Secure_Form_Hub_State :: enum { Pending, Forwarding, Accepted, Final }
Secure_Form_Bridge_State :: enum { Pending, Consumed, Running, Final }

// Guards for lock-owned transitions. A final status is a tombstone and
// cannot be reopened. The endpoint must separately prove the outcome and
// arbitrate pending decline/cancel/accept and uncertain post-dispatch effects.
secure_form_hub_transition :: proc(from, to: Secure_Form_Hub_State) -> bool {
	switch from {
	case .Pending: return to == .Forwarding || to == .Final
	case .Forwarding: return to == .Accepted || to == .Final
	case .Accepted: return to == .Final
	case .Final: return false
	}
	return false
}

secure_form_bridge_transition :: proc(from, to: Secure_Form_Bridge_State) -> bool {
	switch from {
	case .Pending: return to == .Consumed || to == .Final
	case .Consumed: return to == .Running || to == .Final
	case .Running: return to == .Final
	case .Final: return false
	}
	return false
}

// Compare with authenticated placement and reserve under the routing lock.
secure_form_admit_initial :: proc(request, live: Secure_Form_Request, now: u64, state: Secure_Form_Hub_State) -> bool {
	deadline, ok := secure_form_uint(request.deadline)
	return state == .Pending && request == live && ok && now < deadline
}

secure_form_directory_matches :: proc(e: Secure_Form_Answer, digest: [32]byte, sequence: u64, trusted_head: [32]byte) -> bool {
	seq, ok := secure_form_uint(e.directory_sequence)
	d, head: [32]byte
	return ok && seq == sequence && secure_form_hex(d[:], e.request_digest) && secure_form_hex(head[:], e.directory_head) &&
		d == digest && head == trusted_head
}

Secure_Form_Retry_Binding :: struct {
	request_id, manifest_digest, script, purpose, owner, bridge, instance, task: string,
}
Secure_Form_Attempt :: struct { number: u64, terminal: bool, code: Secure_Form_Exit }
Secure_Form_Retry_Action :: enum { Reject, Join, Start }
Secure_Form_Retry_Decision :: struct { action: Secure_Form_Retry_Action, attempt: u64, code: Secure_Form_Exit }

// Compare and reserve atomically against original receipt time and the latest
// attempt. Script body and connection generation are deliberately not bound.
secure_form_retry :: proc(original, caller: Secure_Form_Retry_Binding, receipt, now, after: u64,
	retained: bool, latest: Secure_Form_Attempt) -> Secure_Form_Retry_Decision {
	if original != caller || after == 0 do return {.Reject, 0, .Unauthorized}
	// Joining reads metadata only, so it remains valid while the successor
	// status is available, even if the retained input has expired.
	if latest.number > 1 && after == latest.number - 1 do return {.Join, latest.number, latest.code}
	if !retained || now < receipt || now - receipt >= SECURE_FORM_RETENTION_MS do return {.Reject, 0, .Retention_Expired}
	if after != latest.number || latest.number == max(u64) do return {.Reject, 0, .Unauthorized}
	// A confirmed terminal 28 means the attempt is over but its external
	// effects are uncertain. The explicit caller checks those effects.
	if !latest.terminal do return {.Reject, 0, .Unknown}
	#partial switch latest.code {
	case .Stdin_Failed, .Child_Failed, .Execution_Expired, .Unknown:
		return {.Start, latest.number + 1, .Unknown}
	case:
		return {.Reject, 0, .Unauthorized}
	}
}
