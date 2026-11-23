package engine

// Pointers, known-good.json and pins.json (spec §3, §4, §6.3 J17/J20/J21/J28). Reads go
// through the launcher's own code (src/launcher/core) so the supervisor and the launcher
// can never disagree about which tree a record names or whether it is valid.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import lc "../../launcher/core"

POINTER_CURRENT :: lc.POINTER_CURRENT
POINTER_PREVIOUS :: lc.POINTER_PREVIOUS
KNOWN_GOOD_FILE :: "known-good.json"
PINS_FILE :: "pins.json"

// read_pointer_raw: the tree a pointer names, valid or not ("" if unreadable).
read_pointer_raw :: proc(e: ^Engine, name: string) -> string {
	t, ok := lc.read_pointer(e.cfg.instance_root, name)
	return t if ok else ""
}

// tree_is_valid: spec §4 validity (shared with the launcher).
tree_is_valid :: proc(e: ^Engine, tree: string) -> bool {
	if tree == "" do return false
	ok, _ := lc.tree_valid(e.cfg.instance_root, tree)
	return ok
}

// write_pointer replaces `current` or `previous` (spec §4.1/§4.2). One durable step.
write_pointer :: proc(e: ^Engine, name, tree, op_id: string) -> Error {
	return write_pointer_platform(e, name, tree, op_id)
}

// write_known_good: {"tree","committed_op","at"} by atomic replace (§3, §4.3).
write_known_good :: proc(e: ^Engine, tree, op_id: string) -> Error {
	data := fmt.tprintf("{{\"tree\":\"%s\",\"committed_op\":\"%s\",\"at\":%d}}\n", tree, op_id, now(e))
	return replace_durable(e.inj, e.cfg.retry, join(e.cfg.instance_root, KNOWN_GOOD_FILE), transmute([]byte)data, op_id)
}

read_known_good_raw :: proc(e: ^Engine) -> string {
	t, ok := lc.read_known_good(e.cfg.instance_root)
	return t if ok else ""
}

// ref_of_tree reads version and this target's bundle sha256 from a tree's release.json.
ref_of_tree :: proc(e: ^Engine, tree: string, allocator := context.temp_allocator) -> (r: Ref, ok: bool) {
	if tree == "" do return
	data, rerr := os.read_entire_file(join(e.cfg.instance_root, "releases", tree, "release.json"), context.temp_allocator)
	if rerr != nil do return
	v, perr := json.parse(data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if perr != nil do return
	obj, is_obj := v.(json.Object)
	if !is_obj do return
	version, _ := obj_string(obj, "version")
	targets, has_targets := obj["targets"].(json.Object)
	if !has_targets do return
	target, has_target := targets[lc.TARGET].(json.Object)
	if !has_target do return
	sha, _ := obj_string(target, "sha256")
	if version == "" || sha == "" do return
	return Ref{strings.clone(version, allocator), strings.clone(sha, allocator), strings.clone(tree, allocator)}, true
}

// Manifest engine fields a tree declares (§11.2, §13.4); absent = 0.
Tree_Schemas :: struct {
	state_schema:     i64,
	state_compat_min: i64,
	journal_schema:   i64,
}

tree_schemas :: proc(e: ^Engine, tree: string) -> (s: Tree_Schemas) {
	data, rerr := os.read_entire_file(join(e.cfg.instance_root, "releases", tree, "release.json"), context.temp_allocator)
	if rerr != nil do return
	v, perr := json.parse(data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if perr != nil do return
	obj, is_obj := v.(json.Object)
	if !is_obj do return
	s.state_schema, _ = obj_int(obj, "state_schema")
	s.state_compat_min, _ = obj_int(obj, "state_compat_min")
	s.journal_schema, _ = obj_int(obj, "journal_schema")
	return
}

// ---- pins.json ----

Pin :: struct {
	version: string,
	sha256:  string,
	op_id:   string,
	reason:  string,
	at:      i64,
}

read_pins :: proc(e: ^Engine, allocator := context.temp_allocator) -> [dynamic]Pin {
	out := make([dynamic]Pin, allocator)
	data, rerr := os.read_entire_file(join(e.cfg.instance_root, "supervisor", PINS_FILE), context.temp_allocator)
	if rerr != nil do return out
	v, perr := json.parse(data, json.Specification.JSON, true, context.temp_allocator)
	if perr != nil do return out
	obj, is_obj := v.(json.Object)
	if !is_obj do return out
	arr, is_arr := obj["pins"].(json.Array)
	if !is_arr do return out
	for item in arr {
		p, is_p := item.(json.Object)
		if !is_p do continue
		pin: Pin
		pin.version, _ = obj_string(p, "version")
		pin.sha256, _ = obj_string(p, "sha256")
		pin.op_id, _ = obj_string(p, "op_id")
		pin.reason, _ = obj_string(p, "reason")
		pin.at, _ = obj_int(p, "at")
		pin.version = strings.clone(pin.version, allocator)
		pin.sha256 = strings.clone(pin.sha256, allocator)
		pin.op_id = strings.clone(pin.op_id, allocator)
		pin.reason = strings.clone(pin.reason, allocator)
		append(&out, pin)
	}
	return out
}

is_pinned :: proc(e: ^Engine, version, sha256: string) -> bool {
	for p in read_pins(e) do if p.version == version && p.sha256 == sha256 do return true
	return false
}

@(private)
encode_pins :: proc(pins: []Pin) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"schema":1,"pins":[`)
	for p, i in pins {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"version":`)
		write_json_string(&b, p.version)
		strings.write_string(&b, `,"sha256":`)
		write_json_string(&b, p.sha256)
		strings.write_string(&b, `,"op_id":`)
		write_json_string(&b, p.op_id)
		strings.write_string(&b, `,"reason":`)
		write_json_string(&b, p.reason)
		fmt.sbprintf(&b, `,"at":%d}}`, p.at)
	}
	strings.write_string(&b, "]}\n")
	return strings.to_string(b)
}

// add_pin: J20. Re-adding an existing {version, sha256} is a no-op (no write).
add_pin :: proc(e: ^Engine, version, sha256, op_id, reason: string) -> Error {
	pins := read_pins(e)
	for p in pins do if p.version == version && p.sha256 == sha256 do return nil
	append(&pins, Pin{version, sha256, op_id, reason, now(e)})
	data := encode_pins(pins[:])
	return replace_durable(e.inj, e.cfg.retry, join(e.cfg.instance_root, "supervisor", PINS_FILE), transmute([]byte)data, op_id, PRIVATE_FILE_PERMS)
}

// remove_pin: `retry_failed` (J27). Missing pin = no write.
remove_pin :: proc(e: ^Engine, version, op_id: string) -> Error {
	pins := read_pins(e)
	kept := make([dynamic]Pin, context.temp_allocator)
	for p in pins do if p.version != version do append(&kept, p)
	if len(kept) == len(pins) do return nil
	data := encode_pins(kept[:])
	return replace_durable(e.inj, e.cfg.retry, join(e.cfg.instance_root, "supervisor", PINS_FILE), transmute([]byte)data, op_id, PRIVATE_FILE_PERMS)
}
