package service

// <state>/update.json (spec §3): channel, auto_update, revision. Written only by J27 ops
// (set_channel, set_auto_update), carrying "last_op" so a replay never applies twice.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "../engine"

UPDATE_FILE :: "update.json"

Settings :: struct {
	channel:     string, // "stable" | "fast"
	auto_update: bool,
	revision:    i64,
	actor:       string,
	updated_at:  i64,
	last_op:     string,
}

default_settings :: proc() -> Settings {
	return Settings{channel = "stable", auto_update = true}
}

// read_settings: a missing or unreadable file is the default (stable, auto_update on).
read_settings :: proc(state_root: string, allocator := context.temp_allocator) -> (s: Settings) {
	s = default_settings()
	data, err := os.read_entire_file(engine.join(state_root, UPDATE_FILE), context.temp_allocator)
	if err != nil do return
	v, perr := json.parse(data, .JSON, true, context.temp_allocator)
	if perr != nil do return
	obj, ok := v.(json.Object)
	if !ok do return
	if c, cok := obj["channel"].(json.String); cok && (c == "stable" || c == "fast") do s.channel = strings.clone(string(c), allocator)
	if a, aok := obj["auto_update"].(json.Boolean); aok do s.auto_update = bool(a)
	if r, rok := obj["revision"].(json.Integer); rok do s.revision = i64(r)
	if a, aok := obj["actor"].(json.String); aok do s.actor = strings.clone(string(a), allocator)
	if u, uok := obj["updated_at"].(json.Integer); uok do s.updated_at = i64(u)
	if l, lok := obj["last_op"].(json.String); lok do s.last_op = strings.clone(string(l), allocator)
	return
}

encode_settings :: proc(s: Settings) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"channel":`)
	json_str(&b, s.channel)
	fmt.sbprintf(&b, `,"auto_update":%v,"revision":%d,"actor":`, s.auto_update, s.revision)
	json_str(&b, s.actor)
	fmt.sbprintf(&b, `,"updated_at":%d,"last_op":`, s.updated_at)
	json_str(&b, s.last_op)
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

write_settings :: proc(state_root: string, s: Settings, retry: engine.Retry_Policy) -> engine.Error {
	data := encode_settings(s)
	return engine.replace_durable(nil, retry, engine.join(state_root, UPDATE_FILE), transmute([]byte)data, s.last_op, engine.PRIVATE_FILE_PERMS)
}

// json_str writes a JSON string literal (escapes quotes, backslashes and control bytes).
json_str :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in transmute([]byte)s {
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case 0 ..< 0x20:
			fmt.sbprintf(b, `\u%04x`, c)
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}
