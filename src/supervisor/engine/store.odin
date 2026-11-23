package engine

// Durable writes of the engine (docs/specs/bridge-supervisor-engine.md §4, §6, §11) and the
// failure-injection layer the tests use to crash the engine at every durable write (§18).
//
// Every write the engine makes to the instance root goes through one of the procedures
// below. Each is one *durable step*: when it returns nil, the bytes are on disk
// (file fsync + directory fsync on POSIX, FlushFileBuffers + MOVEFILE_WRITE_THROUGH on
// Windows). An `Injector` attached to the engine counts the steps and, at the chosen step,
// simulates a crash in one of three ways:
//
//   .Drop  the step never reached the disk (power lost before it, or before its fsync);
//   .Land  the step is durable, the process dies right after it;
//   .Torn  power lost in the middle: a journal append leaves a prefix of its line with no
//          LF; an atomic replace leaves its *.tmp-* file but not the rename.
//
// After the crash every further engine I/O fails with code `crashed`, so the engine
// unwinds without touching anything else, exactly like a process that is gone. Tests then
// open a fresh engine on the same root (the "next supervisor start") and check recovery.
//
// The injector can also make one step fail *without* a crash (`fail_at`), the way a real
// disk does: `.Busy` keeps the step refused for the whole W3 retry budget (-> `fs_busy`,
// e.g. an AV scanner holding current.json on Windows); `.Io` fails it with `fs_error`
// (ENOSPC, EIO); a journal append then writes a prefix of its line first (short write).
// The engine keeps running and must handle the error (engine.odin "Error contract").
//
// Model limit (documented in §18): it assumes fsync is honest. A filesystem that reorders
// fsynced writes is out of scope, as it is for every journaling design.

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"

Failure :: struct {
	code:   string, // spec code (journal `error`), e.g. "pointer_write", "fs_busy"
	detail: string, // human text, temp allocator
}

Error :: Maybe(Failure)

CRASHED :: "crashed"

fail :: proc(code: string, format: string, args: ..any) -> Error {
	return Failure{code = code, detail = fmt.tprintf(format, ..args)}
}

error_code :: proc(e: Error) -> string {
	f, ok := e.?
	return f.code if ok else ""
}

is_crash :: proc(e: Error) -> bool {
	return error_code(e) == CRASHED
}

Crash_Mode :: enum {
	Drop,
	Land,
	Torn,
}

// Injector: crash at durable step number `crash_at` (1-based; 0 = never).
Injector :: struct {
	crash_at: int,
	mode:     Crash_Mode,
	steps:    int, // durable steps attempted so far
	crashed:  bool,
	at_what:  string, // description of the step that crashed (diagnostics)
	// Busy injection (W3): the next `busy_count` rename/replace calls fail as a sharing
	// violation would. Used to prove the 60 s retry budget and `fs_busy`.
	busy_count: int,
	// Non-crash failure at durable step number `fail_at` (1-based; 0 = never), one shot.
	fail_at:    int,
	fail_kind:  Fail_Kind,
	failed:     bool, // the non-crash failure was delivered
	failed_what: string,
}

Fail_Kind :: enum {
	Busy, // refused for the whole W3 budget -> fs_busy
	Io, // fs_error (a journal append writes part of its line first)
}

@(private)
Step_Action :: enum {
	Run,
	Dead, // already crashed earlier
	Drop,
	Land,
	Torn,
	Fail_Busy,
	Fail_Io,
}

@(private)
inject_step :: proc(inj: ^Injector, what: string) -> Step_Action {
	if inj == nil do return .Run
	if inj.crashed do return .Dead
	inj.steps += 1
	if inj.fail_at != 0 && inj.steps == inj.fail_at && !inj.failed {
		inj.failed = true
		inj.failed_what = strings.clone(what, context.temp_allocator)
		return .Fail_Busy if inj.fail_kind == .Busy else .Fail_Io
	}
	if inj.crash_at == 0 || inj.steps != inj.crash_at do return .Run
	inj.crashed = true
	inj.at_what = strings.clone(what, context.temp_allocator)
	switch inj.mode {
	case .Drop:
		return .Drop
	case .Land:
		return .Land
	case .Torn:
		return .Torn
	}
	return .Run
}

crashed :: proc(inj: ^Injector) -> bool {
	return inj != nil && inj.crashed
}

@(private)
crash_error :: proc(what: string) -> Error {
	return fail(CRASHED, "injected crash at %s", what)
}

// injected_failure: the result of a .Fail_* step that has no effect on disk.
@(private)
injected_failure :: proc(action: Step_Action, what: string) -> Error {
	if action == .Fail_Busy do return fail("fs_busy", "%s refused (injected)", what)
	return fail("fs_error", "%s: injected I/O error", what)
}

// BUSY_FOREVER: busy_count that makes the W3 loop see sharing violations for its whole
// budget (an injected .Fail_Busy step).
@(private)
BUSY_FOREVER :: 1 << 30

FILE_PERMS :: os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}
PRIVATE_FILE_PERMS :: os.Permissions{.Read_User, .Write_User}
PRIVATE_DIR_PERMS :: os.Permissions{.Read_User, .Write_User, .Execute_User}

// Retry_Policy implements W3 for renames and replaces: retry sharing violations with
// backoff 100 ms -> 2 s for up to 60 s. `sleep` is injectable so tests do not wait.
Retry_Policy :: struct {
	budget_ms: int,
	first_ms:  int,
	max_ms:    int,
	sleep:     proc(ms: int),
}

DEFAULT_RETRY :: Retry_Policy {
	budget_ms = 60_000,
	first_ms  = 100,
	max_ms    = 2_000,
}

// is_busy_error: Windows sharing/lock violation or access denied (core:os maps the first
// and last to io.Error.Permission_Denied); EBUSY/ETXTBSY elsewhere. Same rule as
// src/supervisor/fetch/tree.odin is_busy_error.
@(private)
is_busy_error :: proc(e: os.Error) -> bool {
	#partial switch v in e {
	case io.Error:
		return ODIN_OS == .Windows && v == .Permission_Denied
	case os.Platform_Error:
		when ODIN_OS == .Windows {
			code := u32(v)
			return code == 32 || code == 33 || code == 5 // SHARING, LOCK, ACCESS_DENIED
		} else {
			code := i32(v)
			return code == 16 || code == 26 // EBUSY, ETXTBSY
		}
	}
	return false
}

// with_retry runs op until it succeeds, fails with a non-busy error, or the W3 budget is
// spent (-> fs_busy).
@(private)
with_retry :: proc(inj: ^Injector, policy: Retry_Policy, what: string, op: proc(a, b: string) -> os.Error, a, b: string) -> Error {
	waited := 0
	backoff := max(policy.first_ms, 1)
	for {
		e: os.Error
		if inj != nil && inj.busy_count > 0 {
			inj.busy_count -= 1
			e = os.Platform_Error(32 when ODIN_OS == .Windows else 16)
		} else {
			e = op(a, b)
		}
		if e == nil do return nil
		if !is_busy_error(e) do return fail("fs_error", "%s: %v", what, e)
		if waited >= policy.budget_ms do return fail("fs_busy", "%s still refused after %d ms: %v", what, waited, e)
		step := min(backoff, policy.budget_ms - waited)
		if policy.sleep != nil do policy.sleep(step)
		else do time.sleep(time.Duration(step) * time.Millisecond)
		waited += step
		backoff = min(backoff * 2, max(policy.max_ms, 1))
	}
}

// write_new_synced creates (truncates) path, writes data and fsyncs it. Not a durable step
// on its own: callers wrap it.
@(private)
write_new_synced :: proc(path: string, data: []byte, perms := FILE_PERMS) -> Error {
	f, e := os.open(path, {.Write, .Create, .Trunc}, perms)
	if e != nil do return fail("fs_error", "create %s: %v", path, e)
	n, we := os.write(f, data)
	if we != nil || n != len(data) {
		os.close(f)
		return fail("fs_error", "write %s: %v", path, we)
	}
	if se := os.sync(f); se != nil {
		os.close(f)
		return fail("fs_error", "fsync %s: %v", path, se)
	}
	if ce := os.close(f); ce != nil do return fail("fs_error", "close %s: %v", path, ce)
	return nil
}

// sync_dir fsyncs a directory (POSIX) so a new entry or a rename in it is durable. NTFS
// journals metadata; Windows writers use MOVEFILE_WRITE_THROUGH instead.
sync_dir :: proc(path: string) -> Error {
	when ODIN_OS == .Windows {
		return nil
	} else {
		f, e := os.open(path)
		if e != nil do return fail("fs_error", "open dir %s: %v", path, e)
		defer os.close(f)
		if se := os.sync(f); se != nil do return fail("fs_error", "fsync dir %s: %v", path, se)
		return nil
	}
}

@(private)
dir_of :: proc(path: string) -> string {
	dir, _ := os.split_path(path)
	return dir
}

// replace_durable: the atomic replace of spec §4.2 used for every small record
// (known-good.json, pins.json, op-index.json, Windows pointer records, restored state
// files): write `<path>.tmp-<tag>`, fsync, then replace `path` (rename(2) + dir fsync on
// POSIX; ReplaceFileW, else MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH) on Windows), W3
// retries. One durable step.
replace_durable :: proc(inj: ^Injector, policy: Retry_Policy, path: string, data: []byte, tag: string, perms := FILE_PERMS) -> Error {
	what := fmt.tprintf("replace %s", path)
	tmp := fmt.tprintf("%s.tmp-%s", path, tag)
	switch inject_step(inj, what) {
	case .Dead, .Drop:
		return crash_error(what)
	case .Torn:
		write_new_synced(tmp, data, perms)
		return crash_error(what)
	case .Fail_Io:
		return injected_failure(.Fail_Io, what)
	case .Fail_Busy:
		inj.busy_count = BUSY_FOREVER // the real W3 loop runs out of budget
	case .Land, .Run:
	}
	if e := write_new_synced(tmp, data, perms); e != nil {
		os.remove(tmp)
		return e
	}
	rerr := with_retry(inj, policy, what, platform_replace, tmp, path)
	if inj != nil && inj.busy_count >= BUSY_FOREVER / 2 do inj.busy_count = 0
	if rerr != nil {
		os.remove(tmp)
		return rerr
	}
	if e := sync_dir(dir_of(path)); e != nil do return e
	if crashed(inj) do return crash_error(what) // .Land: durable, then gone
	return nil
}

// append_durable appends one whole line with a single write and fsyncs (spec §6.1).
//
// A short write or fsync error cuts the file back to its size before the write, so the next
// append does not concatenate onto a fragment (which would make a later line torn or the
// whole journal corrupt). If even that cut fails the result is `journal_torn`: the file may
// end in a fragment without LF, which the next supervisor start truncates as a torn tail
// (§6.1) — so the caller must not append again in this process (engine "Error contract").
append_durable :: proc(inj: ^Injector, path: string, line: string) -> Error {
	what := fmt.tprintf("append %s", path)
	action := inject_step(inj, what)
	if action == .Dead || action == .Drop do return crash_error(what)
	if action == .Fail_Busy do return injected_failure(action, what)
	existed := os.exists(path)
	f, e := os.open(path, {.Write, .Create, .Append}, PRIVATE_FILE_PERMS)
	if e != nil do return fail("fs_error", "open %s: %v", path, e)
	before, serr := os.file_size(f)
	if serr != nil {
		os.close(f)
		return fail("fs_error", "size %s: %v", path, serr)
	}
	data := transmute([]byte)line
	if action == .Torn {
		// Power lost mid-write: a prefix of the line, never its LF.
		cut := max(1, len(data) / 2)
		if cut >= len(data) do cut = len(data) - 1
		os.write(f, data[:cut])
		os.sync(f)
		os.close(f)
		return crash_error(what)
	}
	cut_back :: proc(f: ^os.File, path: string, before: i64, why: Error) -> Error {
		if te := os.truncate(f, before); te != nil {
			os.close(f)
			return fail("journal_torn", "%s; cutting %s back to %d bytes failed: %v", error_detail(why), path, before, te)
		}
		if se := os.sync(f); se != nil {
			os.close(f)
			return fail("journal_torn", "%s; fsync after cutting %s back failed: %v", error_detail(why), path, se)
		}
		os.close(f)
		return why
	}
	if action == .Fail_Io {
		// Short write (ENOSPC mid-line): a prefix reaches the file, then the error.
		os.write(f, data[:max(1, len(data) / 2)])
		return cut_back(f, path, before, injected_failure(action, what))
	}
	n, we := os.write(f, data)
	if we != nil || n != len(data) {
		return cut_back(f, path, before, fail("fs_error", "append %s: wrote %d of %d bytes: %v", path, n, len(data), we))
	}
	if se := os.sync(f); se != nil {
		return cut_back(f, path, before, fail("fs_error", "fsync %s: %v", path, se))
	}
	os.close(f)
	if !existed {
		if e2 := sync_dir(dir_of(path)); e2 != nil do return e2
	}
	if action == .Land do return crash_error(what)
	return nil
}

// truncate_durable cuts a file to `size` bytes (torn journal tail, §6.1). One step.
truncate_durable :: proc(inj: ^Injector, path: string, size: i64) -> Error {
	what := fmt.tprintf("truncate %s", path)
	action := inject_step(inj, what)
	if action == .Dead || action == .Drop || action == .Torn do return crash_error(what)
	if action == .Fail_Busy || action == .Fail_Io do return injected_failure(action, what)
	f, e := os.open(path, {.Write})
	if e != nil do return fail("fs_error", "open %s: %v", path, e)
	if te := os.truncate(f, size); te != nil {
		os.close(f)
		return fail("fs_error", "truncate %s: %v", path, te)
	}
	os.sync(f)
	os.close(f)
	if action == .Land do return crash_error(what)
	return nil
}

// remove_durable deletes a file or a whole directory tree (missing is fine). One step.
remove_durable :: proc(inj: ^Injector, path: string) -> Error {
	what := fmt.tprintf("remove %s", path)
	action := inject_step(inj, what)
	if action == .Dead || action == .Drop || action == .Torn do return crash_error(what)
	if action == .Fail_Busy || action == .Fail_Io do return injected_failure(action, what)
	if os.exists(path) || is_symlink(path) {
		e: os.Error
		if os.is_directory(path) && !is_symlink(path) do e = os.remove_all(path)
		else do e = os.remove(path)
		if e != nil do return fail("fs_error", "remove %s: %v", path, e)
		sync_dir(dir_of(path))
	}
	if action == .Land do return crash_error(what)
	return nil
}

// rename_durable renames a file or directory with W3 retries, then fsyncs the directory.
rename_durable :: proc(inj: ^Injector, policy: Retry_Policy, old_path, new_path: string) -> Error {
	what := fmt.tprintf("rename %s -> %s", old_path, new_path)
	action := inject_step(inj, what)
	if action == .Dead || action == .Drop || action == .Torn do return crash_error(what)
	if action == .Fail_Io do return injected_failure(action, what)
	if action == .Fail_Busy do inj.busy_count = BUSY_FOREVER
	rerr := with_retry(inj, policy, what, os_rename, old_path, new_path)
	if inj != nil && inj.busy_count >= BUSY_FOREVER / 2 do inj.busy_count = 0
	if rerr != nil do return rerr
	if e := sync_dir(dir_of(new_path)); e != nil do return e
	if action == .Land do return crash_error(what)
	return nil
}

@(private)
os_rename :: proc(a, b: string) -> os.Error {
	return os.rename(a, b)
}

// make_dir_durable creates a directory (and parents). One step.
make_dir_durable :: proc(inj: ^Injector, path: string, perms := PRIVATE_DIR_PERMS) -> Error {
	what := fmt.tprintf("mkdir %s", path)
	action := inject_step(inj, what)
	if action == .Dead || action == .Drop || action == .Torn do return crash_error(what)
	if action == .Fail_Busy || action == .Fail_Io do return injected_failure(action, what)
	if !os.is_directory(path) {
		if e := os.make_directory_all(path, perms); e != nil && !os.is_directory(path) {
			return fail("fs_error", "mkdir %s: %v", path, e)
		}
		sync_dir(dir_of(path))
	}
	if action == .Land do return crash_error(what)
	return nil
}

is_symlink :: proc(path: string) -> bool {
	info, err := os.lstat(path, context.temp_allocator)
	return err == nil && info.type == .Symlink
}

join :: proc(parts: ..string) -> string {
	out, _ := os.join_path(parts, context.temp_allocator)
	return out
}

error_detail :: proc(e: Error) -> string {
	f, ok := e.?
	return f.detail if ok else ""
}

// write_file_durable creates a new file (snapshot copies, markers), fsyncs it and its
// directory. One step; .Torn leaves a truncated file, which a reader detects (the
// snapshot.json written last is absent, or a sha256 mismatches).
write_file_durable :: proc(inj: ^Injector, path: string, data: []byte) -> Error {
	what := fmt.tprintf("write %s", path)
	action := inject_step(inj, what)
	if action == .Dead || action == .Drop do return crash_error(what)
	if action == .Fail_Busy || action == .Fail_Io do return injected_failure(action, what)
	if action == .Torn {
		write_new_synced(path, data[:len(data) / 2], PRIVATE_FILE_PERMS)
		return crash_error(what)
	}
	if e := write_new_synced(path, data, PRIVATE_FILE_PERMS); e != nil do return e
	if e := sync_dir(dir_of(path)); e != nil do return e
	if action == .Land do return crash_error(what)
	return nil
}
