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
// Each test runs on a mem.Tracking_Allocator and asserts BOTH halves of it — an empty
// bad_free_array AND an allocation_map back at its baseline — following
// shell_session_ownership_test.odin:506+527. Asserting only bad frees was review finding
// B2: the resolver hands back an owned string on EVERY verdict including the rejections,
// and its expansion branches are the thing that can leak, so the leak half is the half
// that needed defending. The resolve happens inside its OWN BLOCK in each test so the
// `defer delete` has run by the time the baseline is compared — a defer at test scope
// would still be holding the string when the assertion reads the map.

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

// cwd_test_expect_no_leak asserts BOTH halves of the tracking allocator: nothing the
// resolver allocated is still live, and nothing was freed that should not have been.
// Split out so all seven tests make the same pair of assertions and none can quietly
// make only one of them (review finding B2).
@(private = "file")
cwd_test_expect_no_leak :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator, baseline_allocs: int) {
	testing.expectf(t, len(track.allocation_map) == baseline_allocs,
		"leak: %d live allocations, expected the baseline %d",
		len(track.allocation_map), baseline_allocs)
	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
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

	baseline_allocs := len(track.allocation_map)
	{
		resolved, verdict := bridge_shell_cwd_resolve(missing)
		defer delete(resolved)
		testing.expect(t, verdict == .Missing, "a cwd that does not exist must be refused, not silently replaced by $HOME")

		// AC2: THE PATH IS NAMED. A refusal that does not say which path was rejected
		// leaves the caller exactly as stuck as the silent fallback did.
		msg := bridge_shell_cwd_reject_message(verdict, resolved)
		defer delete(msg)
		testing.expect(t, strings.contains(msg, missing), "the refusal must name the offending path")
		testing.expect(t, strings.contains(msg, "does not exist"), "the refusal must say why")
	}

	cwd_test_expect_no_leak(t, &track, baseline_allocs)
}

@(test)
test_shell_cwd_resolve_non_directory_is_refused :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	file := cwd_test_make_file(t, "file")
	defer { _ = os.remove(file); delete(file) }

	baseline_allocs := len(track.allocation_map)
	{
		resolved, verdict := bridge_shell_cwd_resolve(file)
		defer delete(resolved)
		// Distinct from .Missing on purpose: the path DOES exist, and telling the caller
		// it does not would send them looking for the wrong problem.
		testing.expect(t, verdict == .Not_Directory, "an existing non-directory cwd must be refused as such")

		msg := bridge_shell_cwd_reject_message(verdict, resolved)
		defer delete(msg)
		testing.expect(t, strings.contains(msg, file), "the refusal must name the offending path")
		testing.expect(t, strings.contains(msg, "is not a directory"), "the refusal must say why")
	}

	cwd_test_expect_no_leak(t, &track, baseline_allocs)
}

@(test)
test_shell_cwd_resolve_valid_directory_is_accepted :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	dir := cwd_test_make_dir(t, "ok")
	defer { _ = os.remove_all(dir); delete(dir) }

	baseline_allocs := len(track.allocation_map)
	{
		// AC3, direction 1: this change must not narrow the working cases.
		resolved, verdict := bridge_shell_cwd_resolve(dir)
		defer delete(resolved)
		testing.expect(t, verdict == .Ok, "an existing directory must still be accepted")
		testing.expect_value(t, resolved, dir)
	}

	cwd_test_expect_no_leak(t, &track, baseline_allocs)
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
	baseline_allocs := len(track.allocation_map)
	for input in ([]string{"", "   ", "\t\n"}) {
		resolved, verdict := bridge_shell_cwd_resolve(input)
		defer delete(resolved)
		testing.expect(t, verdict == .Ok, "no cwd requested must not be a refusal")
		testing.expect_value(t, resolved, "")
	}

	cwd_test_expect_no_leak(t, &track, baseline_allocs)
}

@(test)
test_shell_cwd_resolve_expands_home_before_checking :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	home := cwd_test_make_dir(t, "home")
	defer { _ = os.remove_all(home); delete(home) }

	// HOME is PASSED IN, never set on the process: the runner is parallel and other tests
	// in this package read the real HOME (data_dir_expand_test.odin), so mutating it here
	// would make their outcome depend on this test's timing.
	baseline_allocs := len(track.allocation_map)

	// A real `~/…` directory resolves and is accepted. Without expansion IN THIS
	// PROCEDURE this would be refused as missing — the check would have been applied to
	// a path nothing can open.
	{
		resolved, verdict := bridge_shell_cwd_resolve_with_home("~/", home)
		defer delete(resolved)
		testing.expect(t, verdict == .Ok, "an existing ~-relative directory must be accepted")
		testing.expect(t, strings.has_prefix(resolved, home), "the resolved path must be the expanded one")
		testing.expect(t, !strings.contains(resolved, "~"), "the ~ must be gone by the time the path is used")
	}

	// And a missing `~/…` directory is refused NAMING THE EXPANDED PATH, not the
	// literal `~/…` the caller typed: the expanded form is the one that was actually
	// checked, and the one the reader has to go look at.
	{
		resolved, verdict := bridge_shell_cwd_resolve_with_home("~/definitely-not-here", home)
		defer delete(resolved)
		testing.expect(t, verdict == .Missing, "a missing ~-relative directory must be refused")
		msg := bridge_shell_cwd_reject_message(verdict, resolved)
		defer delete(msg)
		testing.expect(t, strings.contains(msg, home), "the refusal must name the expanded path it checked")
	}

	cwd_test_expect_no_leak(t, &track, baseline_allocs)
}

@(test)
test_shell_cwd_resolve_bare_tilde_is_accepted :: proc(t: ^testing.T) {
	// REVIEW FINDING B1, and its own test because `~/` passing told us nothing about `~`.
	// The shared bridge_expand_home (provider_store.odin:166-173) expands only on a `~/`
	// PREFIX, so the first cut of this guard stat()ed a literal `~`, refused it, and told
	// the caller "does not exist: ~" — FALSE about the world, and the ONE input the guard
	// narrowed: pre-fix a bare `~` fell back to $HOME, which is exactly the directory `~`
	// denotes, so the caller had been getting the right answer for the wrong reason.
	//
	// Not reachable through an interactive `--cwd ~` (the caller's shell expands it
	// first), which is how it got past a careful test pass. It IS reachable from anything
	// that does not go through a shell: src/ctl/shell_cmds.odin:81/237/314 forward --cwd
	// verbatim, so a quoted `--cwd '~'`, a scripted call, or a REST caller sending
	// cwd:"~" all arrive as a literal tilde.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	home := cwd_test_make_dir(t, "baretilde")
	defer { _ = os.remove_all(home); delete(home) }

	baseline_allocs := len(track.allocation_map)
	{
		resolved, verdict := bridge_shell_cwd_resolve_with_home("~", home)
		defer delete(resolved)
		testing.expect(t, verdict == .Ok, "a bare ~ names $HOME and must be accepted")
		// The exact directory, not merely something under it: `~` IS $HOME, so a
		// resolution that landed anywhere else would be a different bug wearing this
		// test's pass.
		testing.expect_value(t, resolved, home)
	}

	// `~user` is deliberately NOT expanded — nothing in this product has ever resolved
	// one — so it is checked literally and refused naming what was checked. Pinned so
	// the distinction is a decision on the record rather than an accident of the prefix
	// test above.
	{
		resolved, verdict := bridge_shell_cwd_resolve_with_home("~nobody-by-this-name", home)
		defer delete(resolved)
		testing.expect(t, verdict == .Missing, "a ~user form is not expanded and must be refused")
		testing.expect_value(t, resolved, "~nobody-by-this-name")
	}

	cwd_test_expect_no_leak(t, &track, baseline_allocs)
}

@(test)
test_shell_cwd_resolve_home_unset_is_refused_honestly :: proc(t: ^testing.T) {
	// With no HOME there is nothing to expand against, so `~` and `~/x` cannot be
	// resolved at all. THE POINT OF THIS TEST IS THE WORDING, not just the refusal: the
	// defect this task fixes was a wrong answer delivered confidently, and answering
	// "does not exist: ~" here would be the same mistake in a refusal — the path is not
	// known to be absent, it is unresolvable. Hence a verdict of its own.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	baseline_allocs := len(track.allocation_map)
	// BOTH tilde forms, because the pre-B1 code reached them by different routes and only
	// one of them was ever expanded.
	for input in ([]string{"~", "~/somewhere"}) {
		// "" IS the unset case — no process env touched.
		resolved, verdict := bridge_shell_cwd_resolve_with_home(input, "")
		defer delete(resolved)
		testing.expectf(t, verdict == .Home_Unset, "%s with no HOME must be refused as unresolvable, not as missing", input)
		// The caller's own spelling: there is no expanded form to name.
		testing.expect_value(t, resolved, input)

		msg := bridge_shell_cwd_reject_message(verdict, resolved)
		defer delete(msg)
		testing.expect(t, strings.contains(msg, "HOME is not set"), "the refusal must say what is actually wrong")
		testing.expect(t, !strings.contains(msg, "does not exist"), "the refusal must not claim the path is absent")
	}

	cwd_test_expect_no_leak(t, &track, baseline_allocs)
}

@(test)
test_shell_cwd_resolve_wrapper_reads_the_real_home :: proc(t: ^testing.T) {
	// The seam above is only worth having if the PRODUCTION entry point is wired to it,
	// so this pins the one thing the injected-home tests cannot: that
	// bridge_shell_cwd_resolve reads HOME from the environment. Read-only — it asserts
	// against whatever HOME already holds rather than setting it, so it stays safe under
	// the parallel runner.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	home := os.get_env("HOME", context.temp_allocator)
	if strings.trim_space(home) == "" {
		// A bridge host with no HOME is not a case to fail on: the injected-home test
		// covers that branch, and this one has nothing left to compare against.
		testing.expect(t, true, "no HOME in this environment; the injected-home test covers it")
		return
	}

	baseline_allocs := len(track.allocation_map)
	{
		resolved, verdict := bridge_shell_cwd_resolve("~")
		defer delete(resolved)
		testing.expect(t, verdict == .Ok, "a bare ~ must resolve through the real HOME")
		testing.expect_value(t, resolved, home)
	}

	cwd_test_expect_no_leak(t, &track, baseline_allocs)
}
