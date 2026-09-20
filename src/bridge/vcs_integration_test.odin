package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Real-git-repo integration tests for the bridge VCS provider (TASK-1-TEST Part C):
// stage/unstage roundtrip, revert (modified + untracked guard), the no-HEAD unstage
// fallback, log pagination, and worktree listing — each driven against a live git repo.
//
// PLACEMENT NOTE: the task sketched these under tests/vcs_backend_test/main.odin, but
// that is a standalone `package main` binary built against the src/lib/vcs backend
// library (Vcs_Backend / workspace_add), which has no stage/unstage/log/list_workspaces
// and cannot import the bridge provider (also `package main`). These tests exercise the
// bridge provider procs (vcs_git_*), so they live here and run under
// `odin test src/bridge`; the lib/vcs integration binary is left untouched and still
// builds + passes on its own.
//
// Each test builds its own throwaway git repo under /tmp with a unique per-test dir, so
// the default multi-threaded test runner never races on a shared path, and shells out
// to real git. A test is skipped (returns early) only if repo setup itself fails, which
// keeps the suite green on a host without git rather than reporting a spurious failure.

// vcs_test_rm best-effort recursively removes a path, discarding output and errors.
vcs_test_rm :: proc(path: string) {
	_, stdout, stderr, _ := os.process_exec(os.Process_Desc{command = []string{"rm", "-rf", path}}, context.allocator)
	if len(stdout) > 0 do delete(stdout, context.allocator)
	if len(stderr) > 0 do delete(stderr, context.allocator)
}

// vcs_test_git runs a git argv, discards its stdout/stderr, and reports exit-0 success.
vcs_test_git :: proc(args: ..string) -> bool {
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = args}, context.allocator)
	if len(stdout) > 0 do delete(stdout, context.allocator)
	if len(stderr) > 0 do delete(stderr, context.allocator)
	return err == nil && state.success
}

// vcs_test_make_marker_repo creates a throwaway dir carrying just an empty <marker>
// entry (".git" or ".jj") so vcs_detect_provider recognizes that provider WITHOUT the
// real tool — enough for the detection-only handler paths (missing-file, jj
// not_supported, same-ref) that return before any subprocess runs. Returns the dir
// (temp-allocated); the caller must vcs_test_rm it.
vcs_test_make_marker_repo :: proc(name, marker: string) -> string {
	dir := fmt.tprintf("/tmp/ham-vcs-marker-%s", name)
	vcs_test_rm(dir)
	_ = os.make_directory_all(fmt.tprintf("%s/%s", dir, marker))
	return dir
}

// vcs_test_git_repo initializes a fresh git repo (branch main, test identity) at a
// unique temp dir and returns (dir, ok). No commits are made. The dir is returned even
// on failure so the caller can still defer vcs_test_rm on it.
vcs_test_git_repo :: proc(name: string) -> (string, bool) {
	dir := fmt.tprintf("/tmp/ham-vcs-git-%s", name)
	vcs_test_rm(dir)
	if os.make_directory_all(dir) != nil do return dir, false
	if !vcs_test_git("git", "init", "-b", "main", dir) do return dir, false
	if !vcs_test_git("git", "-C", dir, "config", "user.email", "test@example.com") do return dir, false
	if !vcs_test_git("git", "-C", dir, "config", "user.name", "Test User") do return dir, false
	return dir, true
}

// vcs_test_write writes content to <dir>/<rel>, creating any parent dirs named in rel.
vcs_test_write :: proc(dir, rel, content: string) {
	if slash := strings.last_index_byte(rel, '/'); slash >= 0 {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", dir, rel[:slash]))
	}
	_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, rel), content)
}

// vcs_test_find_file returns the changed-file entry whose path equals rel (and found).
vcs_test_find_file :: proc(files: []VCS_Changed_File, rel: string) -> (VCS_Changed_File, bool) {
	for f in files {
		if f.path == rel do return f, true
	}
	return {}, false
}

// vcs_test_free_files frees the cloned paths from vcs_git_changed_files. Like
// vcs_test_free_workspaces it does not free the slice itself (a paginated backing may
// be an interior subslice); the small residual leak is harmless in tests.
vcs_test_free_files :: proc(files: []VCS_Changed_File) {
	for f in files do delete(f.path)
}

// vcs_test_free_log_entries frees the per-entry string clones from vcs_git_log. It does
// NOT delete the slice, since a paginated page can be an interior subslice of a larger
// backing (freeing that pointer would be invalid); the backing leak is harmless.
vcs_test_free_log_entries :: proc(entries: []VCS_Log_Entry) {
	for e in entries do vcs_test_free_log_entry(e)
}

// stage_unstage_roundtrip: stage a new file, confirm changed_files reports staged:true,
// unstage it, confirm staged:false.
@(test)
vcs_git_stage_unstage_roundtrip :: proc(t: ^testing.T) {
	dir, ok := vcs_test_git_repo("stage-roundtrip")
	defer vcs_test_rm(dir)
	if !ok do return
	// An initial commit so HEAD resolves (unstage takes the restore --staged path).
	vcs_test_write(dir, "README.md", "hello\n")
	if !vcs_test_git("git", "-C", dir, "add", "README.md") do return
	if !vcs_test_git("git", "-C", dir, "commit", "-m", "init") do return

	vcs_test_write(dir, "f.txt", "content\n")
	sok, smsg := vcs_git_stage_file(dir, "f.txt")
	testing.expect(t, sok, "stage_file succeeds")
	testing.expect(t, smsg == "", "stage_file returns no error code")
	{
		files, _, _, fok := vcs_git_changed_files(dir, "", 100)
		defer vcs_test_free_files(files)
		testing.expect(t, fok, "changed_files ok after stage")
		f, found := vcs_test_find_file(files, "f.txt")
		testing.expect(t, found, "f.txt listed after stage")
		testing.expect(t, f.staged, "f.txt staged:true after stage")
	}

	uok, umsg := vcs_git_unstage_file(dir, "f.txt")
	testing.expect(t, uok, "unstage_file succeeds")
	testing.expect(t, umsg == "", "unstage_file returns no error code")
	{
		files, _, _, fok := vcs_git_changed_files(dir, "", 100)
		defer vcs_test_free_files(files)
		testing.expect(t, fok, "changed_files ok after unstage")
		f, found := vcs_test_find_file(files, "f.txt")
		testing.expect(t, found, "f.txt still listed after unstage")
		testing.expect(t, !f.staged, "f.txt staged:false after unstage")
	}
}

// revert_modified_file: modify a tracked file, revert it, confirm the committed content
// is restored.
@(test)
vcs_git_revert_modified_file :: proc(t: ^testing.T) {
	dir, ok := vcs_test_git_repo("revert-modified")
	defer vcs_test_rm(dir)
	if !ok do return
	vcs_test_write(dir, "file.txt", "before\n")
	if !vcs_test_git("git", "-C", dir, "add", "file.txt") do return
	if !vcs_test_git("git", "-C", dir, "commit", "-m", "init") do return

	vcs_test_write(dir, "file.txt", "after\n")
	rok, rmsg := vcs_git_revert_file(dir, "file.txt")
	testing.expect(t, rok, "revert_file succeeds on a tracked file")
	testing.expect(t, rmsg == "", "revert_file returns no error code")
	data, derr := os.read_entire_file(fmt.tprintf("%s/file.txt", dir), context.temp_allocator)
	testing.expect(t, derr == nil, "reverted file is readable")
	testing.expect(t, string(data) == "before\n", "content restored to the committed version")
}

// revert_untracked_guard: an untracked file has no committed/indexed version, so revert
// must refuse with the distinct untracked_file code rather than a generic failure.
@(test)
vcs_git_revert_untracked_guard :: proc(t: ^testing.T) {
	dir, ok := vcs_test_git_repo("revert-untracked")
	defer vcs_test_rm(dir)
	if !ok do return
	vcs_test_write(dir, "README.md", "hello\n")
	if !vcs_test_git("git", "-C", dir, "add", "README.md") do return
	if !vcs_test_git("git", "-C", dir, "commit", "-m", "init") do return

	vcs_test_write(dir, "new.txt", "untracked\n")
	rok, rmsg := vcs_git_revert_file(dir, "new.txt")
	testing.expect(t, !rok, "revert refuses an untracked file")
	testing.expect(t, rmsg == "untracked_file", "revert reports untracked_file")
}

// unstage_no_head_fallback: on a repo with no commits HEAD does not resolve, so unstage
// must fall back to `git rm --cached` and still succeed.
@(test)
vcs_git_unstage_no_head_fallback :: proc(t: ^testing.T) {
	dir, ok := vcs_test_git_repo("unstage-no-head")
	defer vcs_test_rm(dir)
	if !ok do return
	// No commit: stage a file into the index, then unstage via the fallback.
	vcs_test_write(dir, "f.txt", "content\n")
	if !vcs_test_git("git", "-C", dir, "add", "f.txt") do return

	uok, umsg := vcs_git_unstage_file(dir, "f.txt")
	testing.expect(t, uok, "unstage succeeds with no HEAD (git rm --cached fallback)")
	testing.expect(t, umsg == "", "fallback unstage returns no error code")

	files, _, _, fok := vcs_git_changed_files(dir, "", 100)
	defer vcs_test_free_files(files)
	testing.expect(t, fok, "changed_files ok after fallback unstage")
	f, found := vcs_test_find_file(files, "f.txt")
	testing.expect(t, found, "f.txt still present (now untracked) after fallback unstage")
	testing.expect(t, !f.staged, "f.txt no longer staged after fallback unstage")
}

// log_pagination: 60 commits, limit 50 -> page of 50 with has_more; the next page holds
// the remaining 10 with has_more:false.
@(test)
vcs_git_log_pagination :: proc(t: ^testing.T) {
	dir, ok := vcs_test_git_repo("log-pagination")
	defer vcs_test_rm(dir)
	if !ok do return
	for i in 0 ..< 60 {
		if !vcs_test_git("git", "-C", dir, "commit", "--allow-empty", "-m", fmt.tprintf("c%d", i)) do return
	}

	page1, cur1, more1, lok1 := vcs_git_log(dir, "", 50)
	defer vcs_test_free_log_entries(page1)
	testing.expect(t, lok1, "log page 1 ok")
	testing.expect_value(t, len(page1), 50)
	testing.expect(t, more1, "60 commits, limit 50 -> has_more on page 1")
	testing.expect(t, cur1 != "", "page 1 returns a next_cursor")

	page2, cur2, more2, lok2 := vcs_git_log(dir, cur1, 50)
	defer vcs_test_free_log_entries(page2)
	defer delete(cur1)
	testing.expect(t, lok2, "log page 2 ok")
	testing.expect_value(t, len(page2), 10)
	testing.expect(t, !more2, "page 2 exhausts the log -> no has_more")
	testing.expect(t, cur2 == "", "final page returns no next_cursor")
}

// worktrees_list: add a linked worktree, then list from each side and confirm exactly
// the queried worktree is reported is_current.
@(test)
vcs_git_worktrees_list :: proc(t: ^testing.T) {
	dir, ok := vcs_test_git_repo("worktrees")
	defer vcs_test_rm(dir)
	if !ok do return
	vcs_test_write(dir, "README.md", "hello\n")
	if !vcs_test_git("git", "-C", dir, "add", "README.md") do return
	if !vcs_test_git("git", "-C", dir, "commit", "-m", "init") do return

	wt := "/tmp/ham-vcs-wt-worktrees"
	vcs_test_rm(wt)
	defer vcs_test_rm(wt)
	if !vcs_test_git("git", "-C", dir, "worktree", "add", wt, "-b", "feat") do return

	// Queried from the main repo: two worktrees, and only the main one is current.
	{
		ws, wok := vcs_git_list_workspaces(dir)
		defer vcs_test_free_workspaces(ws)
		testing.expect(t, wok, "list_workspaces ok from main")
		testing.expect_value(t, len(ws), 2)
		cur_count := 0
		main_current, other_current := false, false
		for w in ws {
			if w.is_current do cur_count += 1
			if vcs_clean_path(w.path) == vcs_clean_path(dir) do main_current = w.is_current
			if vcs_clean_path(w.path) == vcs_clean_path(wt) do other_current = w.is_current
		}
		testing.expect_value(t, cur_count, 1)
		testing.expect(t, main_current, "main worktree is_current when queried from main")
		testing.expect(t, !other_current, "added worktree not current when queried from main")
	}

	// Queried from the added worktree: now it is the current one.
	{
		ws, wok := vcs_git_list_workspaces(wt)
		defer vcs_test_free_workspaces(ws)
		testing.expect(t, wok, "list_workspaces ok from the added worktree")
		wt_current := false
		for w in ws {
			if vcs_clean_path(w.path) == vcs_clean_path(wt) do wt_current = w.is_current
		}
		testing.expect(t, wt_current, "added worktree is_current when queried from itself")
	}
}
