package main

// REQ-SHELL-20: `shell run --cwd` must refuse a missing or non-directory path rather
// than running the command somewhere else and reporting success.
//
// WHAT THESE TESTS ARE PINNING, and why each direction needs its own case. The defect
// was NOT "we forgot to validate": it was a SILENT FALLBACK inside the vendored
// portable-pty crate (0.9.0, src/cmdbuilder.rs:501-507 —
// `.filter(|dir| Path::new(dir).is_dir()).unwrap_or(home)`), which deletes a cwd that
// fails an is_dir() stat and substitutes $HOME. So there are two failure directions and
// both are load-bearing:
//
//   REJECT what the filter would swallow — missing, and present-but-not-a-directory.
//     A regression here is INVISIBLE: the run still exits 0, in the wrong directory,
//     and the session row still records the directory it never entered. Nothing else
//     in the suite would go red.
//   ACCEPT everything that works today — a real directory, and no cwd at all.
//     A regression here breaks every existing caller loudly, but it is the thing an
//     over-eager validator gets wrong, so AC3 asks for it explicitly.
//
// Expansion is checked alongside, because checking the raw value would pass a literal
// `~/foo` that the spawn then fails to resolve — the check and the expansion have to be
// the same step or the guard has a hole exactly the shape of the bug it closes.
//
// Each test runs on a mem.Tracking_Allocator, following shell_inventory_test.odin: the
// resolver hands back an owned string on EVERY verdict including the rejections, so a
// leak or a double free in the guarded ~-expansion free is a visible failure here
// rather than a slow one in a long-lived bridge.

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
cwd_test_stamp :: proc() -> string {
	ns := time.to_unix_nanoseconds(time.now())
	b := strings.builder_make()
	strings.write_int(&b, int(ns % 1_000_000_000))
	return strings.to_string(b)
}

// cwd_test_make_dir creates a unique empty directory and returns its path.
@(private = "file")
cwd_test_make_dir :: proc(t: ^testing.T, tag: string) -> string {
	stamp := cwd_test_stamp()
	defer delete(stamp)
	root := strings.concatenate({"/tmp/ham_cwd_test_", tag, "_", stamp})
	if err := os.make_directory_all(root); err != nil do testing.expect(t, false, "could not create temp dir")
	return root
}

// cwd_test_make_file creates a unique regular FILE — the non-directory case. It has to
// be a real path that exists, or the test would pass for the Missing reason instead of
// the one it is named for.
@(private = "file")
cwd_test_make_file :: proc(t: ^testing.T, tag: string) -> string {
	stamp := cwd_test_stamp()
	defer delete(stamp)
	path := strings.concatenate({"/tmp/ham_cwd_test_", tag, "_", stamp, ".txt"})
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("x")) == nil, "could not create temp file")
	return path
}

@(test)
test_shell_cwd_resolve_missing_is_refused :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	stamp := cwd_test_stamp()
	defer delete(stamp)
	missing := strings.concatenate({"/tmp/ham_cwd_absent_", stamp})
	defer delete(missing)
	testing.expect(t, !os.exists(missing), "fixture: the path must really not exist")

	resolved, verdict := bridge_shell_cwd_resolve(missing)
	defer delete(resolved)
	testing.expect(t, verdict == .Missing, "a cwd that does not exist must be refused, not silently replaced by $HOME")

	// AC2: THE PATH IS NAMED. A refusal that does not say which path was rejected
	// leaves the caller exactly as stuck as the silent fallback did.
	msg := bridge_shell_cwd_reject_message(verdict, resolved)
	defer delete(msg)
	testing.expect(t, strings.contains(msg, missing), "the refusal must name the offending path")
	testing.expect(t, strings.contains(msg, "does not exist"), "the refusal must say why")

	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
test_shell_cwd_resolve_non_directory_is_refused :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	file := cwd_test_make_file(t, "file")
	defer { _ = os.remove(file); delete(file) }

	resolved, verdict := bridge_shell_cwd_resolve(file)
	defer delete(resolved)
	// Distinct from .Missing on purpose: the path DOES exist, and telling the caller it
	// does not would send them looking for the wrong problem.
	testing.expect(t, verdict == .Not_Directory, "an existing non-directory cwd must be refused as such")

	msg := bridge_shell_cwd_reject_message(verdict, resolved)
	defer delete(msg)
	testing.expect(t, strings.contains(msg, file), "the refusal must name the offending path")
	testing.expect(t, strings.contains(msg, "is not a directory"), "the refusal must say why")

	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
test_shell_cwd_resolve_valid_directory_is_accepted :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	dir := cwd_test_make_dir(t, "ok")
	defer { _ = os.remove_all(dir); delete(dir) }

	// AC3, direction 1: this change must not narrow the working cases.
	resolved, verdict := bridge_shell_cwd_resolve(dir)
	defer delete(resolved)
	testing.expect(t, verdict == .Ok, "an existing directory must still be accepted")
	testing.expect_value(t, resolved, dir)

	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
test_shell_cwd_resolve_empty_means_no_cwd :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	// AC3, direction 2: a run with NO --cwd must keep defaulting exactly as it does
	// today. "" is not a bad path, it is the absence of one — the caller turns this
	// into has_cwd=false, so validating it would break every run that passes no --cwd.
	// Whitespace-only is the same intent typed sloppily.
	for input in ([]string{"", "   ", "\t\n"}) {
		resolved, verdict := bridge_shell_cwd_resolve(input)
		defer delete(resolved)
		testing.expect(t, verdict == .Ok, "no cwd requested must not be a refusal")
		testing.expect_value(t, resolved, "")
	}

	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
test_shell_cwd_resolve_expands_home_before_checking :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	home := cwd_test_make_dir(t, "home")
	defer { _ = os.remove_all(home); delete(home) }

	old_home := os.get_env("HOME", context.temp_allocator)
	_ = os.set_env("HOME", home)
	defer if old_home != "" { _ = os.set_env("HOME", old_home) } else { _ = os.unset_env("HOME") }

	// A real `~/…` directory resolves and is accepted. Without expansion IN THIS
	// PROCEDURE this would be refused as missing — the check would have been applied to
	// a path nothing can open.
	{
		resolved, verdict := bridge_shell_cwd_resolve("~/")
		defer delete(resolved)
		testing.expect(t, verdict == .Ok, "an existing ~-relative directory must be accepted")
		testing.expect(t, strings.has_prefix(resolved, home), "the resolved path must be the expanded one")
		testing.expect(t, !strings.contains(resolved, "~"), "the ~ must be gone by the time the path is used")
	}

	// And a missing `~/…` directory is refused NAMING THE EXPANDED PATH, not the
	// literal `~/…` the caller typed: the expanded form is the one that was actually
	// checked, and the one the reader has to go look at.
	{
		resolved, verdict := bridge_shell_cwd_resolve("~/definitely-not-here")
		defer delete(resolved)
		testing.expect(t, verdict == .Missing, "a missing ~-relative directory must be refused")
		msg := bridge_shell_cwd_reject_message(verdict, resolved)
		defer delete(msg)
		testing.expect(t, strings.contains(msg, home), "the refusal must name the expanded path it checked")
	}

	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}
