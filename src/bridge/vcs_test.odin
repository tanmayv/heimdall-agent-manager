package main

import "core:os"
import "core:strings"
import "core:testing"

// Pure-function tests for the VCS provider: unified-diff parsing, porcelain status
// mapping, pagination, and the JSON envelope shapes. These exercise no processes
// and no WS, so they are hermetic.

@(test)
vcs_parse_unified_diff_basic :: proc(t: ^testing.T) {
	diff := "diff --git a/f b/f\nindex 111..222 100644\n--- a/f\n+++ b/f\n@@ -1,3 +1,4 @@\n context\n-removed\n+added1\n+added2\n"
	hunks := vcs_parse_unified_diff(diff)
	testing.expect_value(t, len(hunks), 1)
	h := hunks[0]
	testing.expect_value(t, h.old_start, 1)
	testing.expect_value(t, h.old_len, 3)
	testing.expect_value(t, h.new_start, 1)
	testing.expect_value(t, h.new_len, 4)
	testing.expect_value(t, len(h.lines), 4)
	testing.expect(t, h.lines[0].op == " " && h.lines[0].text == "context", "first line is context")
	testing.expect(t, h.lines[1].op == "-" && h.lines[1].text == "removed", "second line removed")
	testing.expect(t, h.lines[2].op == "+" && h.lines[2].text == "added1", "third line added")
}

@(test)
vcs_parse_unified_diff_multi_hunk_and_no_newline :: proc(t: ^testing.T) {
	diff := "@@ -1 +1 @@\n-a\n+b\n@@ -10,2 +10,2 @@\n c\n-d\n+e\n\\ No newline at end of file\n"
	hunks := vcs_parse_unified_diff(diff)
	testing.expect_value(t, len(hunks), 2)
	// "@@ -1 +1 @@" — missing lengths default to 1.
	testing.expect_value(t, hunks[0].old_start, 1)
	testing.expect_value(t, hunks[0].old_len, 1)
	testing.expect_value(t, hunks[1].new_start, 10)
	testing.expect_value(t, hunks[1].new_len, 2)
	// The "\ No newline" marker must not become a content line.
	testing.expect_value(t, len(hunks[1].lines), 3)
}

@(test)
vcs_parse_unified_diff_empty :: proc(t: ^testing.T) {
	hunks := vcs_parse_unified_diff("")
	testing.expect_value(t, len(hunks), 0)
}

@(test)
vcs_git_status_word_mapping :: proc(t: ^testing.T) {
	testing.expect(t, vcs_git_status_word('?', '?') == "untracked", "?? -> untracked")
	testing.expect(t, vcs_git_status_word(' ', 'M') == "modified", "worktree M -> modified")
	testing.expect(t, vcs_git_status_word('A', ' ') == "added", "index A -> added")
	testing.expect(t, vcs_git_status_word('D', ' ') == "deleted", "index D -> deleted")
	testing.expect(t, vcs_git_status_word('R', ' ') == "renamed", "index R -> renamed")
	testing.expect(t, vcs_git_status_word('M', 'M') == "modified", "MM -> modified (index preferred)")
}

@(test)
vcs_jj_status_word_mapping :: proc(t: ^testing.T) {
	testing.expect(t, vcs_jj_status_word('A') == "added", "A -> added")
	testing.expect(t, vcs_jj_status_word('M') == "modified", "M -> modified")
	testing.expect(t, vcs_jj_status_word('D') == "deleted", "D -> deleted")
	testing.expect(t, vcs_jj_status_word('R') == "renamed", "R -> renamed")
}

@(test)
vcs_split_range_defaults :: proc(t: ^testing.T) {
	s, l := vcs_split_range("12,5")
	testing.expect_value(t, s, 12)
	testing.expect_value(t, l, 5)
	s2, l2 := vcs_split_range("7")
	testing.expect_value(t, s2, 7)
	testing.expect_value(t, l2, 1) // missing length defaults to 1
}

@(test)
vcs_paginate_files_pages :: proc(t: ^testing.T) {
	all := make([]VCS_Changed_File, 5)
	for i in 0 ..< 5 do all[i] = VCS_Changed_File{path = "f", status = "modified", staged = false}
	// First page of 2.
	page, next_cursor, has_more := vcs_paginate_files(all, "", 2, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	testing.expect_value(t, len(page), 2)
	testing.expect(t, has_more, "5 items, page 2 -> has_more")
	testing.expect(t, next_cursor != "", "next_cursor present when has_more")
	// Follow the cursor to the final page.
	page2, next2, more2 := vcs_paginate_files(all, next_cursor, 2, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	testing.expect_value(t, len(page2), 2)
	testing.expect(t, more2, "still more after item 4")
	page3, next3, more3 := vcs_paginate_files(all, next2, 2, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	testing.expect_value(t, len(page3), 1)
	testing.expect(t, !more3, "last item -> no more")
	testing.expect(t, next3 == "", "no next_cursor on last page")
}

@(test)
vcs_clamp_limit_bounds :: proc(t: ^testing.T) {
	testing.expect_value(t, vcs_clamp_limit(0, 100, 500), 100)   // <=0 -> default
	testing.expect_value(t, vcs_clamp_limit(9999, 100, 500), 500) // over max -> max
	testing.expect_value(t, vcs_clamp_limit(50, 100, 500), 50)    // in range -> as-is
}

@(test)
vcs_no_vcs_json_envelope :: proc(t: ^testing.T) {
	// A path with no VCS must yield ok:false + error code no_vcs on every command.
	req := "{\"command_id\":\"c1\",\"path\":\"/nonexistent/definitely/not/a/repo\"}"
	caps := bridge_vcs_capabilities_json("c1", req)
	testing.expect(t, strings.contains(caps, "\"ok\":false"), "caps ok:false for no vcs")
	testing.expect(t, strings.contains(caps, "\"code\":\"no_vcs\""), "caps no_vcs code")
	testing.expect(t, strings.contains(caps, "\"type\":\"vcs_capabilities_result\""), "caps result type")

	files := bridge_vcs_files_json("c1", req)
	testing.expect(t, strings.contains(files, "\"no_vcs\""), "files no_vcs")
	// Pagination fields must be present even in the error envelope.
	testing.expect(t, strings.contains(files, "\"has_more\":"), "files has_more present")
	testing.expect(t, strings.contains(files, "\"next_cursor\":"), "files next_cursor present")
	testing.expect(t, strings.contains(files, "\"limit\":"), "files limit present")
	testing.expect(t, strings.contains(files, "\"cursor\":"), "files cursor present")

	diff := bridge_vcs_diff_json("c1", req)
	testing.expect(t, strings.contains(diff, "\"no_vcs\""), "diff no_vcs")
	testing.expect(t, strings.contains(diff, "\"has_more\":"), "diff has_more present")
	testing.expect(t, strings.contains(diff, "\"next_cursor\":"), "diff next_cursor present")
}

@(test)
vcs_detect_provider_on_repo :: proc(t: ^testing.T) {
	// This checkout is a git repo and (per the task) has no .jj.
	home := strings.trim_space(os.get_env("HOME", context.temp_allocator))
	if home == "" do return
	repo := strings.concatenate({home, "/heimdall-agent-manager"}, context.temp_allocator)
	if !vcs_git_detect(repo) do return // skip if the checkout is elsewhere
	provider, ok := vcs_detect_provider(repo)
	testing.expect(t, ok, "git repo must be detected")
	testing.expect(t, provider.name() == "git", "git wins detection ordering")
	testing.expect(t, !vcs_jj_detect(repo), "no .jj in this checkout")
}
