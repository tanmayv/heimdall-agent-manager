package engine

// Mutable state: snapshot, restore, refuse (spec §11, D5; J12, J22).
//
// The registry (Config.state_stores) lists the schema-bearing stores. Activation from F to
// T always snapshots them into supervisor/snapshots/<op_id>/ (files/<n> + snapshot.json
// written last); the snapshot is *required* (and restored on rollback) only when the move
// is one-way: T.state_schema > F.state_schema and F.state_schema < T.state_compat_min.
// A downgrade below what the newer release can still be read by is refused before the gate.
// Credentials, runtime-status.json, the journal, logs, shell_sessions/, run/ are never in
// the registry.

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

State_Root :: enum {
	Data, // <data>
	State, // <state>
}

State_Store :: struct {
	root:      State_Root,
	path:      string, // relative, '/'-separated; a file or a directory (copied recursively)
	max_bytes: i64,
}

// DEFAULT_STATE_STORES: the registry of today's schema-bearing stores (spec §11.1:
// config.toml, ports.json under <state>; JSON stores under <data>/bridge/). A package
// variable, not a constant: a constant slice literal is materialised on the stack of
// each user and would dangle once stored in a Config.
@(rodata)
DEFAULT_STATE_STORES := []State_Store {
	{.State, "config.toml", 1 << 20},
	{.State, "ports.json", 1 << 20},
	{.Data, "bridge", 128 << 20},
}

SNAPSHOT_TOTAL_CAP :: 256 << 20
SNAPSHOT_JSON :: "snapshot.json"
RESTORED_MARKER :: "restored"

Schema_Rule :: enum {
	Safe, // snapshot as insurance, never restored
	One_Way, // snapshot required, restored on rollback
	Refuse, // state_schema_incompatible
}

schema_rule :: proc(f, t: Tree_Schemas) -> Schema_Rule {
	if t.state_schema < f.state_schema {
		return .Safe if t.state_schema >= f.state_compat_min else .Refuse
	}
	if t.state_schema > f.state_schema && f.state_schema < t.state_compat_min do return .One_Way
	return .Safe
}

@(private)
root_path :: proc(e: ^Engine, r: State_Root) -> string {
	return e.cfg.instance_root if r == .Data else e.cfg.state_root
}

@(private)
snapshot_dir :: proc(e: ^Engine, op_id: string) -> string {
	return join(e.cfg.instance_root, "supervisor", "snapshots", op_id)
}

@(private)
Snap_File :: struct {
	root:    State_Root,
	rel:     string,
	present: bool,
	size:    i64,
	sha256:  string,
}

// collect: every regular file of a store (a missing store is recorded as absent).
@(private)
collect :: proc(e: ^Engine, s: State_Store, out: ^[dynamic]Snap_File) -> (total: i64, ok: bool) {
	base := root_path(e, s.root)
	full := join(base, s.path)
	if !os.exists(full) {
		append(out, Snap_File{root = s.root, rel = s.path, present = false})
		return 0, true
	}
	if !os.is_directory(full) {
		info, err := os.stat(full, context.temp_allocator)
		if err != nil do return 0, false
		append(out, Snap_File{root = s.root, rel = s.path, present = true, size = info.size})
		return info.size, true
	}
	entries, rerr := os.read_directory_by_path(full, -1, context.temp_allocator)
	if rerr != nil do return 0, false
	for ent in entries {
		sub := State_Store{s.root, fmt.tprintf("%s/%s", s.path, ent.name), s.max_bytes}
		if ent.type == .Directory || ent.type == .Regular {
			n, sub_ok := collect(e, sub, out)
			if !sub_ok do return 0, false
			total += n
		}
	}
	return total, true
}

// take_snapshot (J12). `required` decides only whether a failure is fatal for the caller.
take_snapshot :: proc(e: ^Engine, op_id, from_tree: string, required: bool) -> Error {
	dir := snapshot_dir(e, op_id)
	if os.exists(dir) {
		if err := remove_durable(e.inj, dir); err != nil do return err // incomplete earlier try (J12)
	}
	files := make([dynamic]Snap_File, context.temp_allocator)
	total: i64
	for s in e.cfg.state_stores {
		before := len(files)
		n, ok := collect(e, s, &files)
		if !ok do return fail("snapshot_failed", "cannot read store %s", s.path)
		if n > s.max_bytes do return fail("snapshot_failed", "store %s is %d bytes, over its limit %d", s.path, n, s.max_bytes)
		_ = before
		total += n
	}
	if total > SNAPSHOT_TOTAL_CAP do return fail("snapshot_failed", "state is %d bytes, over %d", total, SNAPSHOT_TOTAL_CAP)
	if err := make_dir_durable(e.inj, join(dir, "files")); err != nil do return err
	for &f, i in files {
		if !f.present do continue
		data, rerr := os.read_entire_file(join(root_path(e, f.root), f.rel), context.temp_allocator)
		if rerr != nil do return fail("snapshot_failed", "read %s: %v", f.rel, rerr)
		f.size = i64(len(data))
		f.sha256 = sha256_hex(data)
		if err := write_file_durable(e.inj, join(dir, "files", fmt.tprintf("%d", i)), data); err != nil do return err
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"op_id":`)
	write_json_string(&b, op_id)
	strings.write_string(&b, `,"from_tree":`)
	write_json_string(&b, from_tree)
	fmt.sbprintf(&b, `,"required":%v,"files":[`, required)
	for f, i in files {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"n":%d,"root":"%s","path":`, i, "data" if f.root == .Data else "state")
		write_json_string(&b, f.rel)
		fmt.sbprintf(&b, `,"present":%v,"size":%d,"sha256":"%s"}}`, f.present, f.size, f.sha256)
	}
	strings.write_string(&b, "]}\n")
	return write_file_durable(e.inj, join(dir, SNAPSHOT_JSON), transmute([]byte)strings.to_string(b))
}

// snapshot_required: the op has a complete snapshot that must be restored on rollback.
snapshot_required :: proc(e: ^Engine, op_id: string) -> bool {
	data, rerr := os.read_entire_file(join(snapshot_dir(e, op_id), SNAPSHOT_JSON), context.temp_allocator)
	if rerr != nil do return false
	v, perr := json.parse(data, json.Specification.JSON, true, context.temp_allocator)
	if perr != nil do return false
	obj, is_obj := v.(json.Object)
	if !is_obj do return false
	req, is_bool := obj["required"].(json.Boolean)
	return is_bool && bool(req)
}

// restore_snapshot (J22): per file, temp copy + atomic replace; stores absent at snapshot
// time are removed; the `restored` marker is written last. Idempotent: snapshot files are
// never modified, and a present marker means done.
restore_snapshot :: proc(e: ^Engine, op_id: string) -> Error {
	dir := snapshot_dir(e, op_id)
	if os.exists(join(dir, RESTORED_MARKER)) do return nil
	data, rerr := os.read_entire_file(join(dir, SNAPSHOT_JSON), context.temp_allocator)
	if rerr != nil do return fail("restore_failed", "snapshot %s has no snapshot.json", op_id)
	v, perr := json.parse(data, json.Specification.JSON, true, context.temp_allocator)
	if perr != nil do return fail("restore_failed", "snapshot.json invalid")
	obj, _ := v.(json.Object)
	arr, is_arr := obj["files"].(json.Array)
	if !is_arr do return fail("restore_failed", "snapshot.json has no files")
	for item in arr {
		f, is_f := item.(json.Object)
		if !is_f do continue
		n, _ := obj_int(f, "n")
		root_name, _ := obj_string(f, "root")
		rel, _ := obj_string(f, "path")
		present := false
		if pv, has := f["present"].(json.Boolean); has do present = bool(pv)
		if rel == "" || strings.contains(rel, "..") do return fail("restore_failed", "bad path in snapshot.json")
		target := join(e.cfg.instance_root if root_name == "data" else e.cfg.state_root, rel)
		if !present {
			if os.exists(target) {
				if err := remove_durable(e.inj, target); err != nil do return err
			}
			continue
		}
		content, cerr := os.read_entire_file(join(dir, "files", fmt.tprintf("%d", n)), context.temp_allocator)
		if cerr != nil do return fail("restore_failed", "snapshot file %d missing", n)
		want, _ := obj_string(f, "sha256")
		if sha256_hex(content) != want do return fail("restore_failed", "snapshot file %d damaged", n)
		parent := dir_of(target)
		if !os.is_directory(parent) {
			if err := make_dir_durable(e.inj, parent); err != nil do return err
		}
		if err := replace_durable(e.inj, e.cfg.retry, target, content, fmt.tprintf("restore-%s", op_id), PRIVATE_FILE_PERMS); err != nil do return err
	}
	return write_file_durable(e.inj, join(dir, RESTORED_MARKER), nil)
}

@(private)
sha256_hex :: proc(data: []byte) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sum: [32]byte
	sha2.final(&ctx, sum[:])
	return string(hex.encode(sum[:], context.temp_allocator))
}
