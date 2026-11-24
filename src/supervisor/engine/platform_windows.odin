#+build windows
package engine

import "core:encoding/json"
import "core:fmt"
import "core:os"
import win "core:sys/windows"
import lc "../../launcher/core"

@(private = "file") REPLACEFILE_IGNORE_MERGE_ERRORS :: 0x2
@(private = "file") MOVEFILE_REPLACE_EXISTING :: 0x1
@(private = "file") MOVEFILE_WRITE_THROUGH :: 0x8
@(private = "file") LOCKFILE_FAIL_IMMEDIATELY :: 0x1
@(private = "file") LOCKFILE_EXCLUSIVE_LOCK :: 0x2

// platform_replace: ReplaceFileW, else MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH)
// (spec §4.2: first write of a record, or ERROR_UNABLE_TO_MOVE_REPLACEMENT*).
@(private)
platform_replace :: proc(src, dst: string) -> os.Error {
	wsrc := win.utf8_to_wstring(src, context.temp_allocator)
	wdst := win.utf8_to_wstring(dst, context.temp_allocator)
	if os.exists(dst) && lc.ReplaceFileW(wdst, wsrc, nil, REPLACEFILE_IGNORE_MERGE_ERRORS, nil, nil) do return nil
	if win.MoveFileExW(wsrc, wdst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) do return nil
	return os.Platform_Error(win.GetLastError())
}

// Instance lock (spec §9): LockFileEx(EXCLUSIVE|FAIL_IMMEDIATELY) on byte 0 of
// supervisor/engine.lock. core:os handles are not inheritable, so no child can hold it.
Lock :: struct {
	f: ^os.File,
}

lock_acquire :: proc(path: string) -> (l: Lock, err: Error) {
	f, e := os.open(path, {.Read, .Write, .Create}, PRIVATE_FILE_PERMS)
	if e != nil do return l, fail("lock_open", "open %s: %v", path, e)
	ov: win.OVERLAPPED
	if !win.LockFileEx(win.HANDLE(os.fd(f)), LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov) {
		os.close(f)
		return l, fail("lock_held", "%s is held by another supervisor", path)
	}
	return Lock{f = f}, nil
}

lock_release :: proc(l: ^Lock) {
	if l.f != nil {
		os.close(l.f) // closing the handle releases the byte-range lock
		l.f = nil
	}
}

// record_seq returns the seq of an existing valid pointer record (-1 if none).
@(private = "file")
record_seq :: proc(path: string) -> i64 {
	data, err := lc.read_file_shared(path, context.temp_allocator)
	if err != nil do return -1
	if _, ok := lc.pointer_record_decode(data); !ok do return -1
	v, perr := json.parse(data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if perr != nil do return -1
	obj, is_obj := v.(json.Object)
	if !is_obj do return -1
	#partial switch n in obj["seq"] {
	case json.Integer:
		return n
	case json.Float:
		return i64(n)
	}
	return -1
}

// write_pointer_platform: Windows pointers are record files `<name>.json` (spec §4.2),
// encoded by the launcher's own pointer_record_encode; `seq` is one more than the larger
// seq of the two records. One durable step (replace_durable).
@(private)
write_pointer_platform :: proc(e: ^Engine, name, tree, op_id: string) -> Error {
	root := e.cfg.instance_root
	seq := max(record_seq(join(root, "current.json")), record_seq(join(root, "previous.json"))) + 1
	data := lc.pointer_record_encode(lc.Pointer_Record{tree = tree, op_id = op_id, seq = seq}, context.temp_allocator)
	path := join(root, fmt.tprintf("%s.json", name))
	if err := replace_durable(e.inj, e.cfg.retry, path, transmute([]byte)data, op_id); err != nil {
		if is_crash(err) do return err
		return Failure{code = "pointer_write", detail = error_detail(err)}
	}
	return nil
}

pointer_file_name :: proc(name: string) -> string {
	return fmt.tprintf("%s.json", name)
}
