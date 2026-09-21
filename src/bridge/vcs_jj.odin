package main

// Jujutsu (jj) adapter for the VCS provider interface (see vcs_provider.odin).
//
// Shells out with `jj -R <path> ...` via vcs_run. jj's working copy is always an
// implicit commit, so every change is effectively "staged" — supports_staging is
// false and every changed file reports staged = true. Detection probes for a .jj
// directory. Diffs are requested in `--git` form so they share the exact unified
// parser the git adapter uses.

import "core:strings"

// Static-storage action whitelist (see vcs_git_actions). jj has no index, so
// "stage"/"unstage" are deliberately absent.
vcs_jj_actions := [5]string{"diff", "log", "commit_diff", "revert", "workspaces"}

// vcs_jj_provider returns the jj proc-table.
vcs_jj_provider :: proc() -> VCS_Provider {
	return VCS_Provider{
		name            = vcs_jj_name,
		detect          = vcs_jj_detect,
		status          = vcs_jj_status,
		changed_files   = vcs_jj_changed_files,
		diff_file       = vcs_jj_diff_file,
		capabilities    = vcs_jj_capabilities,
		stage_file      = vcs_jj_stage_file,
		unstage_file    = vcs_jj_unstage_file,
		revert_file     = vcs_jj_revert_file,
		save_file       = vcs_jj_save_file,
		log             = vcs_jj_log,
		commit_diff     = vcs_jj_commit_diff,
		// commit_diff_files intentionally nil: the Log tab file-list mode is git-only
		// for now (jj is compile-only here, no live test). nil = "not_supported".
		commit_diff_files = nil,
		// commit intentionally nil: staged-commit is git-only for now (jj commits
		// differently and is compile-only here). nil = "not_supported".
		commit = nil,
		list_workspaces = vcs_jj_list_workspaces,
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
	return VCS_Capabilities{
		provider          = "jj",
		supports_staging  = false,
		staging_model     = "none",
		commit_model      = "revision",
		supports_amend    = false,
		supported_actions = vcs_jj_actions[:],
	}
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

// --- write commands ------------------------------------------------------

// jj has no staging index — the working copy is always an implicit commit — so
// stage/unstage are unsupported. Reported via msg "not_supported" (mirrors the
// nil-proc contract) rather than a nil pointer, so callers get a clear code.
vcs_jj_stage_file :: proc(path, file: string) -> (ok: bool, msg: string) {
	return false, "not_supported"
}

vcs_jj_unstage_file :: proc(path, file: string) -> (ok: bool, msg: string) {
	return false, "not_supported"
}

// vcs_jj_revert_file discards a file's changes in the working-copy commit by
// restoring it from the parent (`jj restore --changes-in @ -- <file>`).
vcs_jj_revert_file :: proc(path, file: string) -> (ok: bool, msg: string) {
	if _, rok := vcs_run([]string{"jj", "-R", path, "restore", "--changes-in", "@", "--", file}); !rok {
		return false, "revert_failed"
	}
	return true, ""
}

// vcs_jj_save_file writes the editor buffer back to the working-copy file. jj's
// working copy is an implicit commit, so a plain filesystem write is picked up by
// the next jj snapshot (surfaced on the next vcs_status/vcs_diff) — no jj command
// needed, identical to the git adapter.
vcs_jj_save_file :: proc(path, file, content: string) -> (ok: bool, msg: string) {
	return vcs_write_file_impl(path, file, content)
}

// --- log -----------------------------------------------------------------

// vcs_jj_log lists all revisions via a template that emits the same
// "hash|short|subject|author|date" 5-field row the git adapter's parser expects
// (shared vcs_parse_log_line). --no-graph keeps one commit per line. The template
// uses jj's builtin methods (commit_id.short(), description.first_line(),
// author.name(), committer.timestamp()); a trailing newline separates rows.
vcs_jj_log :: proc(path, cursor: string, limit: int) -> ([]VCS_Log_Entry, string, bool, bool) {
	template := `commit_id ++ "|" ++ commit_id.short() ++ "|" ++ description.first_line() ++ "|" ++ author.name() ++ "|" ++ committer.timestamp() ++ "\n"`
	out, ok := vcs_run([]string{"jj", "-R", path, "log", "-r", "all()", "--no-graph", "--template", template})
	if !ok do return nil, "", false, false
	all := make([dynamic]VCS_Log_Entry, context.allocator)
	lines := strings.split_lines(out, context.temp_allocator)
	for line in lines {
		if strings.trim_space(line) == "" do continue
		if e, eok := vcs_parse_log_line(line); eok do append(&all, e)
	}
	page, next_cursor, has_more := vcs_paginate_log(all[:], cursor, limit, VCS_LOG_DEFAULT_LIMIT, VCS_LOG_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// --- commit_diff ---------------------------------------------------------

// vcs_jj_commit_diff diffs base_ref (optionally --to head_ref) in --git format so
// it shares the unified parser. head_ref == "WORKDIR"/empty omits --to (compares to
// the working copy); base_ref == head_ref is an empty diff.
vcs_jj_commit_diff :: proc(path, base_ref, head_ref, file, cursor: string, limit: int) -> ([]VCS_Diff_Hunk, string, bool, bool) {
	if base_ref == head_ref do return nil, "", false, true
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "jj", "-R", path, "diff", "--git", "-r", base_ref)
	if head_ref != "" && head_ref != "WORKDIR" do append(&args, "--to", head_ref)
	if file != "" do append(&args, "--", file)
	out, ok := vcs_run(args[:])
	if !ok do return nil, "", false, false
	hunks := vcs_parse_unified_diff(out)
	page, next_cursor, has_more := vcs_paginate_hunks(hunks, cursor, limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// --- workspaces ----------------------------------------------------------

// vcs_jj_list_workspaces parses `jj workspace list`, whose rows read
// "<name>: <change_id> <desc>" with the active workspace marked "(current)". jj
// exposes no per-workspace path, so path mirrors the workspace name; label is the
// name and is_locked is always false (jj has no worktree lock concept).
vcs_jj_list_workspaces :: proc(path: string) -> ([]VCS_Workspace, bool) {
	out, ok := vcs_run([]string{"jj", "-R", path, "workspace", "list"})
	if !ok do return nil, false
	all := make([dynamic]VCS_Workspace, context.allocator)
	lines := strings.split_lines(out, context.temp_allocator)
	for raw in lines {
		line := strings.trim_space(raw)
		if line == "" do continue
		colon := strings.index_byte(line, ':')
		if colon < 0 do continue
		name := strings.trim_space(line[:colon])
		if name == "" do continue
		append(&all, VCS_Workspace{
			path       = strings.clone(name),
			label      = strings.clone(name),
			is_current = strings.contains(line, "(current)"),
			is_locked  = false,
		})
	}
	return all[:], true
}
