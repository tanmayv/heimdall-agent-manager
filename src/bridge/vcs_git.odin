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
// file shape, joins per-file addition/deletion counts from `git diff --numstat`,
// then paginates (default 100, max 500).
vcs_git_changed_files :: proc(path, cursor: string, limit: int) -> ([]VCS_Changed_File, string, bool, bool) {
	out, ok := vcs_run([]string{"git", "-C", path, "status", "--porcelain"})
	if !ok do return nil, "", false, false

	// Per-file +/- counts. Unstaged edits show up in `diff HEAD` numstat; staged-
	// only changes need the `--cached HEAD` pass. A later entry wins on overlap,
	// but a path is normally only in one of the two sets.
	stats := make(map[string][2]int, 0, context.temp_allocator)
	vcs_git_numstat_into(&stats, path, []string{"git", "-C", path, "diff", "--numstat", "HEAD"})
	vcs_git_numstat_into(&stats, path, []string{"git", "-C", path, "diff", "--numstat", "--cached", "HEAD"})

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
		clean_path := strings.clone(strings.trim_space(raw_path))
		// Untracked files never appear in numstat; they stay 0/0.
		counts := stats[clean_path] // zero value {0, 0} when absent
		append(&all, VCS_Changed_File{
			path      = clean_path,
			status    = status,
			staged    = staged,
			additions = counts[0],
			deletions = counts[1],
		})
	}
	page, next_cursor, has_more := vcs_paginate_files(all[:], cursor, limit, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// vcs_git_numstat_into runs a `git diff --numstat` argv and folds its per-file
// "<additions>\t<deletions>\t<path>" rows into `stats` (keyed by path). A binary
// file reports "-\t-\t<path>", which vcs_atoi maps to 0/0. Fails soft: a git
// error leaves `stats` untouched. Keys are temp-allocated (only read within the
// changed-files build, which allocates its cloned paths from the same lookup).
vcs_git_numstat_into :: proc(stats: ^map[string][2]int, repo: string, args: []string) {
	out, ok := vcs_run(args)
	if !ok do return
	lines := strings.split_lines(out, context.temp_allocator)
	for line in lines {
		if len(line) == 0 do continue
		// Tab-separated: additions, deletions, path.
		first := strings.index_byte(line, '\t')
		if first < 0 do continue
		rest := line[first + 1:]
		second := strings.index_byte(rest, '\t')
		if second < 0 do continue
		add_s := line[:first]
		del_s := rest[:second]
		file := strings.trim_space(rest[second + 1:])
		if file == "" do continue
		stats[file] = [2]int{vcs_atoi(add_s), vcs_atoi(del_s)}
	}
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
