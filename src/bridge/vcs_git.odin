package main

// Git adapter for the VCS provider interface (see vcs_provider.odin).
//
// Every operation shells out with `git -C <path> ...` via vcs_run (no shell), so
// no chdir and no global git state. Detection is a cheap os.exists(path/.git)
// probe. All commands fail soft: a missing upstream, no origin remote, or a
// non-git path degrade to empty/zero values rather than surfacing an error.

import "core:strings"

// vcs_git_provider returns the git proc-table.
vcs_git_provider :: proc() -> VCS_Provider {
	return VCS_Provider{
		name          = vcs_git_name,
		detect        = vcs_git_detect,
		status        = vcs_git_status,
		changed_files = vcs_git_changed_files,
		diff_file     = vcs_git_diff_file,
		capabilities  = vcs_git_capabilities,
	}
}

vcs_git_name :: proc() -> string {
	return "git"
}

// vcs_git_detect reports whether `path` is a git working tree (has a .git entry —
// a directory for a normal repo, a file for a worktree/submodule).
vcs_git_detect :: proc(path: string) -> bool {
	return vcs_dir_exists(path, ".git")
}

vcs_git_capabilities :: proc(path: string) -> VCS_Capabilities {
	return VCS_Capabilities{provider = "git", supports_staging = true}
}

// vcs_git_status collects branch, origin remote, ahead/behind vs upstream, and the
// clean flag. ok=false only when the repo could not be inspected at all (git
// status itself failed); individual sub-queries degrade to empty/zero.
vcs_git_status :: proc(path: string) -> (VCS_Status, bool) {
	st := VCS_Status{provider = "git"}

	// is_clean: `git status --porcelain` empty. This is also our liveness probe —
	// if it fails, the path is not a usable git repo.
	porcelain, ok := vcs_run([]string{"git", "-C", path, "status", "--porcelain"})
	if !ok do return st, false
	st.is_clean = strings.trim_space(porcelain) == ""

	if branch, bok := vcs_run([]string{"git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"}); bok {
		st.branch = strings.trim_space(branch)
	}
	if remote, rok := vcs_run([]string{"git", "-C", path, "remote", "get-url", "origin"}); rok {
		st.remote = strings.trim_space(remote)
	}
	if ahead, aok := vcs_run([]string{"git", "-C", path, "rev-list", "--count", "@{u}..HEAD"}); aok {
		st.ahead = vcs_atoi(strings.trim_space(ahead))
	}
	if behind, bok := vcs_run([]string{"git", "-C", path, "rev-list", "--count", "HEAD..@{u}"}); bok {
		st.behind = vcs_atoi(strings.trim_space(behind))
	}
	return st, true
}

// vcs_git_changed_files parses `git status --porcelain` into the neutral changed-
// file shape, then paginates (default 100, max 500).
vcs_git_changed_files :: proc(path, cursor: string, limit: int) -> ([]VCS_Changed_File, string, bool, bool) {
	out, ok := vcs_run([]string{"git", "-C", path, "status", "--porcelain"})
	if !ok do return nil, "", false, false

	all := make([dynamic]VCS_Changed_File, context.allocator)
	lines := strings.split_lines(out, context.temp_allocator)
	for line in lines {
		if len(line) < 4 do continue // "XY p" is the shortest meaningful record
		x := line[0]
		y := line[1]
		// Porcelain v1: index status, worktree status, a space, then the path at
		// column 3.
		raw_path := line[3:]
		// Renamed/copied records read "old -> new"; keep the destination path.
		if arrow := strings.index(raw_path, " -> "); arrow >= 0 {
			raw_path = raw_path[arrow + 4:]
		}
		status := vcs_git_status_word(x, y)
		// staged when the index column carries a real (non-space, non-untracked)
		// status.
		staged := x != ' ' && x != '?'
		append(&all, VCS_Changed_File{
			path   = strings.clone(strings.trim_space(raw_path)),
			status = status,
			staged = staged,
		})
	}
	page, next_cursor, has_more := vcs_paginate_files(all[:], cursor, limit, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// vcs_git_status_word maps a porcelain (index, worktree) status pair to one of
// added|modified|deleted|renamed|untracked. Untracked ("??") wins; otherwise the
// index column is preferred, falling back to the worktree column.
vcs_git_status_word :: proc(x, y: u8) -> string {
	if x == '?' || y == '?' do return "untracked"
	code := x
	if code == ' ' do code = y
	switch code {
	case 'A': return "added"
	case 'M': return "modified"
	case 'D': return "deleted"
	case 'R': return "renamed"
	case 'C': return "added"    // copied — surfaced as an addition
	case 'T': return "modified" // type-change — closest neutral bucket
	case:     return "modified"
	}
}

// vcs_git_diff_file parses `git diff HEAD -- <file>` into hunks, then paginates
// (default 50, max 200).
vcs_git_diff_file :: proc(path, file, cursor: string, limit: int) -> ([]VCS_Diff_Hunk, string, bool, bool) {
	out, ok := vcs_run([]string{"git", "-C", path, "diff", "HEAD", "--", file})
	if !ok do return nil, "", false, false
	hunks := vcs_parse_unified_diff(out)
	page, next_cursor, has_more := vcs_paginate_hunks(hunks, cursor, limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	return page, next_cursor, has_more, true
}
