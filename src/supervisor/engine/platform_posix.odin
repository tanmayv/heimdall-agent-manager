#+build linux, darwin, freebsd, openbsd, netbsd
package engine

import "core:c"
import "core:fmt"
import "core:os"

foreign import libc "system:c"
@(default_calling_convention = "c")
foreign libc {
	flock :: proc(fd: c.int, operation: c.int) -> c.int ---
}

@(private = "file") LOCK_EX :: 2
@(private = "file") LOCK_NB :: 4

// platform_replace: rename(2) replaces dst atomically (spec §4.1/§4.2 POSIX).
@(private)
platform_replace :: proc(src, dst: string) -> os.Error {
	return os.rename(src, dst)
}

// Instance lock (spec §9): flock(LOCK_EX|LOCK_NB) on supervisor/engine.lock, held by an
// O_CLOEXEC fd (core:os opens every file close-on-exec) for the life of the process. The
// kernel drops it when the process dies; there is no stale-lock breaking.
Lock :: struct {
	f: ^os.File,
}

lock_acquire :: proc(path: string) -> (l: Lock, err: Error) {
	f, e := os.open(path, {.Read, .Write, .Create}, PRIVATE_FILE_PERMS)
	if e != nil do return l, fail("lock_open", "open %s: %v", path, e)
	if flock(c.int(os.fd(f)), LOCK_EX | LOCK_NB) != 0 {
		os.close(f)
		return l, fail("lock_held", "%s is held by another supervisor", path)
	}
	return Lock{f = f}, nil
}

lock_release :: proc(l: ^Lock) {
	if l.f != nil {
		os.close(l.f) // closing the only fd releases the flock
		l.f = nil
	}
}

// write_pointer_platform: POSIX pointers are relative symlinks `releases/<tree>` replaced
// with symlink(tmp) + rename(2) + directory fsync (spec §4.1). One durable step.
@(private)
write_pointer_platform :: proc(e: ^Engine, name, tree, op_id: string) -> Error {
	path := join(e.cfg.instance_root, name)
	tmp := fmt.tprintf("%s.tmp-%s", path, op_id)
	what := fmt.tprintf("pointer %s := %s", name, tree)
	action := inject_step(e.inj, what)
	if action == .Dead || action == .Drop do return crash_error(what)
	if is_symlink(tmp) || os.exists(tmp) do os.remove(tmp)
	target := fmt.tprintf("releases/%s", tree)
	if se := os.symlink(target, tmp); se != nil do return fail("pointer_write", "symlink %s: %v", tmp, se)
	if action == .Torn do return crash_error(what) // tmp link left behind, rename never ran
	if re := with_retry(e.inj, e.cfg.retry, what, platform_replace, tmp, path); re != nil {
		os.remove(tmp)
		return Failure{code = "pointer_write", detail = error_detail(re)}
	}
	if de := sync_dir(e.cfg.instance_root); de != nil do return de
	if action == .Land do return crash_error(what)
	return nil
}

pointer_file_name :: proc(name: string) -> string {
	return name
}
