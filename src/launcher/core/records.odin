// Records the launcher reads (docs/specs/bridge-supervisor-engine.md §3, §4, §7.1):
// instance.json (ownership), the current/previous pointers, known-good.json, and the
// release.json of the tree a pointer names. Everything here is read-only except
// launcher-status.json (diagnostics) and the launcher's own stop-request file.
package launcher_core

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strconv"
import "core:strings"

// ABI is the frozen launcher ABI of Phase 1 (spec §7.4, D8).
ABI :: 1

// VERSION is stamped by the build like every other binary (-define:HAM_APP_VERSION).
VERSION :: #config(HAM_APP_VERSION, "0.0.0-dev")

POINTER_CURRENT :: "current"
POINTER_PREVIOUS :: "previous"

// Largest record the launcher will read. Every record is tiny; anything larger is
// treated as corrupt rather than read into memory.
MAX_RECORD_BYTES :: 1 << 20

// TARGET is the release-manifest target of this build (docs/release-signing.md).
TARGET :: "linux-amd64" when ODIN_OS == .Linux && ODIN_ARCH == .amd64 else
	"linux-arm64" when ODIN_OS == .Linux && ODIN_ARCH == .arm64 else
	"darwin-arm64" when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 else
	"darwin-amd64" when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 else
	"windows-amd64" when ODIN_OS == .Windows && ODIN_ARCH == .amd64 else
	"unsupported"

SUPERVISOR_EXE :: "ham-supervisor.exe" when ODIN_OS == .Windows else "ham-supervisor"

Owner :: struct {
	uid: i64, // POSIX; -1 when absent
	sid: string, // Windows; "" when absent
}

Instance_Record :: struct {
	instance_id: string,
	owner:       Owner,
	data_root:   string,
	state_root:  string,
}

Tree_Name :: struct {
	version: string,
	d12:     string,
	repair:  int, // n of a -r<n> suffix, 0 for none
}

// parse_tree_name splits "<ver>-<d12>" or "<ver>-<d12>-r<n>" (spec §4). It works from
// the right so a SemVer prerelease containing '-' stays in <ver>.
parse_tree_name :: proc(name: string) -> (t: Tree_Name, ok: bool) {
	if len(name) == 0 || len(name) > 128 do return
	for c in transmute([]byte)name {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-', '+', '_':
		case:
			return
		}
	}
	rest := name
	i := strings.last_index_byte(rest, '-')
	if i < 0 do return
	last := rest[i + 1:]
	if len(last) >= 2 && last[0] == 'r' && last[1] != '0' && is_decimal(last[1:]) {
		n, parsed := strconv.parse_int(last[1:], 10)
		if !parsed || n < 1 do return
		t.repair = n
		rest = rest[:i]
		i = strings.last_index_byte(rest, '-')
		if i < 0 do return
		last = rest[i + 1:]
	}
	if len(last) != 12 || !is_lower_hex(last) do return
	t.d12 = last
	t.version = rest[:i]
	if len(t.version) == 0 || t.version[0] < '0' || t.version[0] > '9' do return
	return t, true
}

@(private)
is_decimal :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	for c in transmute([]byte)s do if c < '0' || c > '9' do return false
	return true
}

@(private)
is_lower_hex :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	for c in transmute([]byte)s {
		switch c {
		case '0' ..= '9', 'a' ..= 'f':
		case:
			return false
		}
	}
	return true
}

// valid_instance_id accepts "ins_" + 32 lowercase hex (spec §3). The id is used in
// Windows object names, so nothing else may get through.
valid_instance_id :: proc(id: string) -> bool {
	return len(id) == 36 && strings.has_prefix(id, "ins_") && is_lower_hex(id[4:])
}

read_small_file :: proc(path: string, allocator := context.allocator) -> (data: []byte, ok: bool) {
	info, serr := os.stat(path, context.temp_allocator)
	if serr != nil || info.type != .Regular || info.size > MAX_RECORD_BYTES do return
	bytes, rerr := read_file_shared(path, allocator)
	if rerr != nil do return
	if len(bytes) > MAX_RECORD_BYTES {
		delete(bytes, allocator)
		return
	}
	return bytes, true
}

@(private)
json_object :: proc(v: json.Value) -> (json.Object, bool) {
	o, ok := v.(json.Object)
	return o, ok
}

@(private)
json_string :: proc(o: json.Object, key: string) -> (string, bool) {
	v, present := o[key]
	if !present do return "", false
	s, ok := v.(json.String)
	return string(s), ok
}

@(private)
json_int :: proc(o: json.Object, key: string) -> (i64, bool) {
	v, present := o[key]
	if !present do return 0, false
	#partial switch n in v {
	case json.Integer:
		return n, true
	case json.Float:
		if n == f64(i64(n)) do return i64(n), true
	}
	return 0, false
}

// read_instance_record parses <data>/instance.json (spec §3). All strings are cloned
// into the caller's allocator.
read_instance_record :: proc(instance_root: string, allocator := context.allocator) -> (rec: Instance_Record, reason: string) {
	path := join(instance_root, "instance.json")
	data, ok := read_small_file(path, context.temp_allocator)
	if !ok do return rec, "instance_record_missing"
	value, err := json.parse(data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil do return rec, "instance_record_invalid"
	obj, is_obj := json_object(value)
	if !is_obj do return rec, "instance_record_invalid"
	schema, has_schema := json_int(obj, "schema")
	if !has_schema || schema != 1 do return rec, "instance_record_schema"
	id, has_id := json_string(obj, "instance_id")
	if !has_id || !valid_instance_id(id) do return rec, "instance_record_invalid"
	rec.instance_id = strings.clone(id, allocator)
	rec.owner.uid = -1
	if owner_value, present := obj["owner"]; present {
		owner, owner_ok := json_object(owner_value)
		if !owner_ok do return rec, "instance_record_invalid"
		if uid, has_uid := json_int(owner, "uid"); has_uid do rec.owner.uid = uid
		if sid, has_sid := json_string(owner, "sid"); has_sid do rec.owner.sid = strings.clone(sid, allocator)
	}
	if dr, has := json_string(obj, "data_root"); has do rec.data_root = strings.clone(dr, allocator)
	if sr, has := json_string(obj, "state_root"); has do rec.state_root = strings.clone(sr, allocator)
	return rec, ""
}

// check_instance_record enforces the ownership rule of spec §3 [T0 Q8]: the effective
// user and the roots must be the ones recorded at install.
check_instance_record :: proc(rec: Instance_Record, instance_root, state_root: string) -> (reason: string) {
	if !owner_matches(rec.owner) do return "ownership_mismatch"
	if rec.data_root == "" || !same_path(rec.data_root, instance_root) do return "ownership_mismatch"
	if rec.state_root != "" && !same_path(rec.state_root, state_root) do return "ownership_mismatch"
	return ""
}

same_path :: proc(a, b: string) -> bool {
	ca := normalize_path(a)
	cb := normalize_path(b)
	when ODIN_OS == .Windows {
		return strings.equal_fold(ca, cb)
	} else {
		return ca == cb
	}
}

@(private)
normalize_path :: proc(p: string) -> string {
	abs, err := os.get_absolute_path(p, context.temp_allocator)
	if err != nil do abs = p
	cleaned, cerr := os.clean_path(abs, context.temp_allocator)
	if cerr != nil do cleaned = abs
	when ODIN_OS == .Windows {
		cleaned, _ = strings.replace_all(cleaned, "/", "\\", context.temp_allocator)
	}
	for len(cleaned) > 1 && (cleaned[len(cleaned) - 1] == '/' || cleaned[len(cleaned) - 1] == '\\') {
		cleaned = cleaned[:len(cleaned) - 1]
	}
	return cleaned
}

join :: proc(parts: ..string) -> string {
	out, _ := os.join_path(parts, context.temp_allocator)
	return out
}

// tree_valid is the validity rule of spec §4: the tree exists under releases/, holds
// .complete, and its release.json names the same version, with this target's bundle
// digest starting with <d12>. The -r<n> suffix is ignored for the check.
tree_valid :: proc(instance_root, name: string) -> (ok: bool, reason: string) {
	tn, parsed := parse_tree_name(name)
	if !parsed do return false, "bad_tree_name"
	dir := join(instance_root, "releases", name)
	if !os.is_directory(dir) do return false, "tree_missing"
	if !os.exists(join(dir, ".complete")) do return false, "tree_incomplete"
	data, read_ok := read_small_file(join(dir, "release.json"), context.temp_allocator)
	if !read_ok do return false, "release_json_missing"
	value, err := json.parse(data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil do return false, "release_json_invalid"
	obj, is_obj := json_object(value)
	if !is_obj do return false, "release_json_invalid"
	version, has_version := json_string(obj, "version")
	if !has_version || version != tn.version do return false, "release_version_mismatch"
	targets_value, has_targets := obj["targets"]
	if !has_targets do return false, "release_json_invalid"
	targets, targets_ok := json_object(targets_value)
	if !targets_ok do return false, "release_json_invalid"
	target_value, has_target := targets[TARGET]
	if !has_target do return false, "release_target_missing"
	target, target_ok := json_object(target_value)
	if !target_ok do return false, "release_json_invalid"
	digest, has_digest := json_string(target, "sha256")
	if !has_digest || len(digest) != 64 || !is_lower_hex(digest) do return false, "release_json_invalid"
	if digest[:12] != tn.d12 do return false, "release_digest_mismatch"
	return true, ""
}

// Pointer records (Windows, spec §4.2). The canonical form the crc32 covers is the
// record without the crc32 member, members in this order, no whitespace:
//   {"tree":"<tree>","op_id":"<op_id>","seq":<n>}
// crc32 is IEEE CRC-32 of those bytes as 8 lowercase hex digits. Tree names and op
// ids never need JSON escaping; a record whose strings would is invalid.
Pointer_Record :: struct {
	tree:  string,
	op_id: string,
	seq:   i64,
}

pointer_record_canonical :: proc(r: Pointer_Record, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("{{\"tree\":\"%s\",\"op_id\":\"%s\",\"seq\":%d}}", r.tree, r.op_id, r.seq, allocator = allocator)
}

// pointer_record_encode renders a full record (canonical members + crc32) plus LF.
// The supervisor (T13) writes records with this, so both sides agree on the bytes.
pointer_record_encode :: proc(r: Pointer_Record, allocator := context.allocator) -> string {
	canonical := pointer_record_canonical(r)
	crc := hash.crc32(transmute([]byte)canonical)
	return fmt.aprintf("{{\"tree\":\"%s\",\"op_id\":\"%s\",\"seq\":%d,\"crc32\":\"%08x\"}}\n", r.tree, r.op_id, r.seq, crc, allocator = allocator)
}

@(private)
plain_token :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 128 do return false
	for c in transmute([]byte)s {
		if c < 0x21 || c > 0x7e || c == '"' || c == '\\' do return false
	}
	return true
}

// pointer_record_decode validates a record file's bytes and returns the tree it names.
pointer_record_decode :: proc(data: []byte) -> (tree: string, ok: bool) {
	value, err := json.parse(data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil do return
	obj, is_obj := json_object(value)
	if !is_obj do return
	r: Pointer_Record
	has_tree, has_op, has_seq, has_crc: bool
	crc_text: string
	r.tree, has_tree = json_string(obj, "tree")
	r.op_id, has_op = json_string(obj, "op_id")
	r.seq, has_seq = json_int(obj, "seq")
	crc_text, has_crc = json_string(obj, "crc32")
	if !has_tree || !has_op || !has_seq || !has_crc || r.seq < 0 do return
	if !plain_token(r.tree) || !plain_token(r.op_id) do return
	if len(crc_text) != 8 || !is_lower_hex(crc_text) do return
	want, parsed := strconv.parse_u64(crc_text, 16)
	if !parsed do return
	canonical := pointer_record_canonical(r)
	if u64(hash.crc32(transmute([]byte)canonical)) != want do return
	return r.tree, true
}

// symlink_target_tree accepts only "releases/<name>" (spec §4.1): relative, one
// component, nothing that could escape releases/.
symlink_target_tree :: proc(target: string) -> (tree: string, ok: bool) {
	PREFIX :: "releases/"
	if !strings.has_prefix(target, PREFIX) do return
	name := target[len(PREFIX):]
	if len(name) == 0 || strings.contains_any(name, "/\\") || name == "." || name == ".." do return
	return name, true
}

// read_known_good returns the tree named by known-good.json.
read_known_good :: proc(instance_root: string) -> (tree: string, ok: bool) {
	data, read_ok := read_small_file(join(instance_root, "known-good.json"), context.temp_allocator)
	if !read_ok do return
	value, err := json.parse(data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil do return
	obj, is_obj := json_object(value)
	if !is_obj do return
	t, has := json_string(obj, "tree")
	if !has || !plain_token(t) do return
	return t, true
}

Records :: struct {
	current:    string, // "" = none (missing or invalid)
	previous:   string,
	known_good: string,
	why_current_invalid: string,
}

// read_records re-reads the three records and applies valid() (spec §7.2). Strings
// live in the temp allocator.
read_records :: proc(instance_root: string) -> (r: Records) {
	if t, ok := read_pointer(instance_root, POINTER_CURRENT); ok {
		valid, why := tree_valid(instance_root, t)
		if valid do r.current = strings.clone(t, context.temp_allocator)
		else do r.why_current_invalid = why
	} else {
		r.why_current_invalid = "pointer_invalid"
	}
	if t, ok := read_pointer(instance_root, POINTER_PREVIOUS); ok {
		if valid, _ := tree_valid(instance_root, t); valid do r.previous = strings.clone(t, context.temp_allocator)
	}
	if t, ok := read_known_good(instance_root); ok {
		if valid, _ := tree_valid(instance_root, t); valid do r.known_good = strings.clone(t, context.temp_allocator)
	}
	return
}
