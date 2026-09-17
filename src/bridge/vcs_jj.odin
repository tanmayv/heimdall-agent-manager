package main

// Jujutsu (jj) adapter for the VCS provider interface (see vcs_provider.odin).
//
// Shells out with `jj -R <path> ...` via vcs_run. jj's working copy is always an
// implicit commit, so every change is effectively "staged" — supports_staging is
// false and every changed file reports staged = true. Detection probes for a .jj
// directory. Diffs are requested in `--git` form so they share the exact unified
// parser the git adapter uses.

import "core:strings"

// vcs_jj_provider returns the jj proc-table.
vcs_jj_provider :: proc() -> VCS_Provider {
	return VCS_Provider{
		name          = vcs_jj_name,
		detect        = vcs_jj_detect,
		status        = vcs_jj_status,
		changed_files = vcs_jj_changed_files,
		diff_file     = vcs_jj_diff_file,
		capabilities  = vcs_jj_capabilities,
	}
}

vcs_jj_name :: proc() -> string {
	return "jj"
}

// vcs_jj_detect reports whether `path` is a jj workspace (.jj present).
vcs_jj_detect :: proc(path: string) -> bool {
	return vcs_dir_exists(path, ".jj")
}

vcs_jj_capabilities :: proc(path: string) -> VCS_Capabilities {
	return VCS_Capabilities{provider = "jj", supports_staging = false}
}

// vcs_jj_status collects the current branch(es), origin remote, and clean flag.
// jj has no simple upstream ahead/behind, so those stay 0. ok=false only when the
// summary probe (our liveness check) fails.
vcs_jj_status :: proc(path: string) -> (VCS_Status, bool) {
	st := VCS_Status{provider = "jj"}

	// is_clean + liveness: `jj diff --summary` empty means a clean working copy.
	summary, ok := vcs_run([]string{"jj", "-R", path, "diff", "--summary"})
	if !ok do return st, false
	st.is_clean = strings.trim_space(summary) == ""

	if branch, bok := vcs_run([]string{"jj", "-R", path, "log", "-r", "@", "--no-graph", "--template", "{branches}"}); bok {
		st.branch = strings.trim_space(branch)
	}
	if remotes, rok := vcs_run([]string{"jj", "-R", path, "git", "remote", "list"}); rok {
		st.remote = vcs_jj_pick_remote(remotes)
	}
	return st, true
}

// vcs_jj_pick_remote extracts an origin URL from `jj git remote list` output
// (lines of "<name> <url>"). Prefers a remote literally named "origin", else the
// first remote listed; "" when none.
vcs_jj_pick_remote :: proc(out: string) -> string {
	first := ""
	lines := strings.split_lines(out, context.temp_allocator)
	for line in lines {
		fields := strings.fields(strings.trim_space(line), context.temp_allocator)
		if len(fields) < 2 do continue
		if fields[0] == "origin" do return strings.clone(fields[1])
		if first == "" do first = strings.clone(fields[1])
	}
	return first
}

// vcs_jj_changed_files parses `jj diff --summary` (each line "<code> <path>") into
// the neutral shape, then paginates (default 100, max 500). Every entry is staged
// (jj's working copy is always committed-in-place).
vcs_jj_changed_files :: proc(path, cursor: string, limit: int) -> ([]VCS_Changed_File, string, bool, bool) {
	out, ok := vcs_run([]string{"jj", "-R", path, "diff", "--summary"})
	if !ok do return nil, "", false, false

	all := make([dynamic]VCS_Changed_File, context.allocator)
	lines := strings.split_lines(out, context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_right(line, "\r")
		if len(trimmed) < 2 do continue // "<code> <path>"
		code := trimmed[0]
		raw_path := strings.trim_space(trimmed[1:])
		if raw_path == "" do continue
		append(&all, VCS_Changed_File{
			path   = strings.clone(raw_path),
			status = vcs_jj_status_word(code),
			staged = true,
		})
	}
	page, next_cursor, has_more := vcs_paginate_files(all[:], cursor, limit, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// vcs_jj_status_word maps a `jj diff --summary` prefix to the neutral status word.
vcs_jj_status_word :: proc(code: u8) -> string {
	switch code {
	case 'A': return "added"
	case 'M': return "modified"
	case 'D': return "deleted"
	case 'R': return "renamed"
	case 'C': return "added" // copied — surfaced as an addition
	case:     return "modified"
	}
}

// vcs_jj_diff_file parses `jj diff --git -- <file>` (unified/git format) into
// hunks, then paginates (default 50, max 200).
vcs_jj_diff_file :: proc(path, file, cursor: string, limit: int) -> ([]VCS_Diff_Hunk, string, bool, bool) {
	out, ok := vcs_run([]string{"jj", "-R", path, "diff", "--git", "--", file})
	if !ok do return nil, "", false, false
	hunks := vcs_parse_unified_diff(out)
	page, next_cursor, has_more := vcs_paginate_hunks(hunks, cursor, limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	return page, next_cursor, has_more, true
}
