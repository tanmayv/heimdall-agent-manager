package service

// supervisor/procs.json (spec §2, §2.1 layer 3): every process this supervisor started,
// written by atomic replace right after the spawn returns, emptied by the J0 reap once every
// entry is confirmed gone.
//
//   {"procs":[{"pid":N,"start_time":N,"group":true,"role":"runtime","tree":"…","job":"…"}]}

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "../engine"
import "../procs"

PROCS_FILE :: "procs.json"

Proc_Record :: struct {
	id:    procs.Id,
	group: bool, // POSIX: the recorded process leads its own process group
	role:  string, // "runtime" | "pty_host" | …
	tree:  string, // release tree it was started from (W1 liveness)
	job:   string, // Windows: the per-instance job object's name, "" elsewhere
}

procs_path :: proc(instance_root: string) -> string {
	return engine.join(instance_root, "supervisor", PROCS_FILE)
}

read_procs :: proc(instance_root: string, allocator := context.temp_allocator) -> (out: [dynamic]Proc_Record) {
	out = make([dynamic]Proc_Record, allocator)
	data, err := os.read_entire_file(procs_path(instance_root), context.temp_allocator)
	if err != nil do return
	v, perr := json.parse(data, .JSON, true, context.temp_allocator)
	if perr != nil do return
	obj, ok := v.(json.Object)
	if !ok do return
	arr, aok := obj["procs"].(json.Array)
	if !aok do return
	for item in arr {
		o, iok := item.(json.Object)
		if !iok do continue
		r: Proc_Record
		if p, pok := o["pid"].(json.Integer); pok do r.id.pid = int(p)
		if st, sok := o["start_time"].(json.Integer); sok do r.id.start_time = u64(st)
		if g, gok := o["group"].(json.Boolean); gok do r.group = bool(g)
		if s, sok := o["role"].(json.String); sok do r.role = strings.clone(string(s), allocator)
		if s, sok := o["tree"].(json.String); sok do r.tree = strings.clone(string(s), allocator)
		if s, sok := o["job"].(json.String); sok do r.job = strings.clone(string(s), allocator)
		if r.id.pid > 0 do append(&out, r)
	}
	return
}

encode_procs :: proc(list: []Proc_Record) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"procs":[`)
	for r, i in list {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"pid":%d,"start_time":%d,"group":%v,"role":`, r.id.pid, r.id.start_time, r.group)
		json_str(&b, r.role)
		strings.write_string(&b, `,"tree":`)
		json_str(&b, r.tree)
		strings.write_string(&b, `,"job":`)
		json_str(&b, r.job)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}\n")
	return strings.to_string(b)
}

write_procs :: proc(instance_root: string, list: []Proc_Record) -> engine.Error {
	data := encode_procs(list)
	return engine.replace_durable(nil, engine.DEFAULT_RETRY, procs_path(instance_root), transmute([]byte)data, "procs", engine.PRIVATE_FILE_PERMS)
}

// procs_trees: trees of recorded processes that still run (W1 "live").
procs_trees :: proc(instance_root: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for r in read_procs(instance_root) {
		if r.tree != "" && procs.alive(r.id) do append(&out, r.tree)
	}
	return out[:]
}

// json_int_field: a top-level integer member of a small JSON document.
json_int_field :: proc(data: []byte, key: string) -> (n: i64, ok: bool) {
	v, err := json.parse(data, .JSON, true, context.temp_allocator)
	if err != nil do return
	obj, is_obj := v.(json.Object)
	if !is_obj do return
	i, iok := obj[key].(json.Integer)
	return i64(i), iok
}

// json_string_field: a top-level string member of a small JSON document (temp-allocated).
json_string_field :: proc(data: []byte, key: string) -> (s: string, ok: bool) {
	v, err := json.parse(data, .JSON, true, context.temp_allocator)
	if err != nil do return
	obj, is_obj := v.(json.Object)
	if !is_obj do return
	str, sok := obj[key].(json.String)
	return string(str), sok
}
