package main

// Git adapter for the VCS provider interface (see vcs_provider.odin).
//
// Every operation shells out with `git -C <path> ...` via vcs_run (no shell), so
// no chdir and no global git state. Detection is a cheap os.exists(path/.git)
// probe. All commands fail soft: a missing upstream, no origin remote, or a
// non-git path degrade to empty/zero values rather than surfacing an error.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// vcs_git_provider returns the git proc-table.
vcs_git_provider :: proc() -> VCS_Provider {
	return VCS_Provider{
		name          = vcs_git_name,
		detect        = vcs_git_detect,
		status        = vcs_git_status,
		changed_files = vcs_git_changed_files,
		diff_file     = vcs_git_diff_file,
		diff_targets  = vcs_git_diff_targets,
		log           = vcs_git_log,
		file_content  = vcs_git_file_content,
		add_file      = vcs_git_add_file,
		revert_file   = vcs_git_revert_file,
		revert_all    = vcs_git_revert_all,
		commit        = vcs_git_commit,
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

// vcs_git_changed_files parses changed files against HEAD, cached, or a specified target revision,
// joins per-file addition/deletion counts from `git diff --numstat`, then paginates (default 100, max 500).
vcs_git_changed_files :: proc(path, target, cursor: string, limit: int) -> ([]VCS_Changed_File, string, bool, bool) {
	all := make([dynamic]VCS_Changed_File, context.allocator)
	stats := make(map[string][2]int, 0, context.temp_allocator)

	eff_target := strings.trim_space(target)
	if eff_target == "" || eff_target == "HEAD" {
		out, ok := vcs_run([]string{"git", "-C", path, "status", "--porcelain"})
		if !ok do return nil, "", false, false

		vcs_git_numstat_into(&stats, path, []string{"git", "-C", path, "diff", "--numstat", "HEAD"})
		vcs_git_numstat_into(&stats, path, []string{"git", "-C", path, "diff", "--numstat", "--cached", "HEAD"})

		lines := strings.split_lines(out, context.temp_allocator)
		for line in lines {
			if len(line) < 4 do continue // "XY p" is the shortest meaningful record
			x := line[0]
			y := line[1]
			raw_path := line[3:]
			if arrow := strings.index(raw_path, " -> "); arrow >= 0 {
				raw_path = raw_path[arrow + 4:]
			}
			status := vcs_git_status_word(x, y)
			staged := x != ' ' && x != '?'
			clean_path := strings.clone(strings.trim_space(raw_path))
			counts := stats[clean_path]
			append(&all, VCS_Changed_File{
				path      = clean_path,
				status    = status,
				staged    = staged,
				additions = counts[0],
				deletions = counts[1],
			})
		}
	} else if eff_target == "cached" {
		out, ok := vcs_run([]string{"git", "-C", path, "diff", "--name-status", "--cached", "HEAD"})
		if !ok do return nil, "", false, false

		vcs_git_numstat_into(&stats, path, []string{"git", "-C", path, "diff", "--numstat", "--cached", "HEAD"})

		lines := strings.split_lines(out, context.temp_allocator)
		for line in lines {
			trimmed := strings.trim_space(line)
			if len(trimmed) < 2 do continue
			parts := strings.split(trimmed, "\t", context.temp_allocator)
			if len(parts) < 2 do continue
			code := parts[0][0]
			raw_path := parts[len(parts) - 1]
			status := vcs_git_status_word(code, ' ')
			clean_path := strings.clone(strings.trim_space(raw_path))
			counts := stats[clean_path]
			append(&all, VCS_Changed_File{
				path      = clean_path,
				status    = status,
				staged    = true,
				additions = counts[0],
				deletions = counts[1],
			})
		}
	} else {
		// Diffs working tree against specified target revision
		out, ok := vcs_run([]string{"git", "-C", path, "diff", "--name-status", eff_target})
		if !ok do return nil, "", false, false

		vcs_git_numstat_into(&stats, path, []string{"git", "-C", path, "diff", "--numstat", eff_target})

		lines := strings.split_lines(out, context.temp_allocator)
		for line in lines {
			trimmed := strings.trim_space(line)
			if len(trimmed) < 2 do continue
			parts := strings.split(trimmed, "\t", context.temp_allocator)
			if len(parts) < 2 do continue
			code := parts[0][0]
			raw_path := parts[len(parts) - 1]
			status := vcs_git_status_word(code, ' ')
			clean_path := strings.clone(strings.trim_space(raw_path))
			counts := stats[clean_path]
			append(&all, VCS_Changed_File{
				path      = clean_path,
				status    = status,
				staged    = false,
				additions = counts[0],
				deletions = counts[1],
			})
		}

		// Also append untracked files
		if untracked_out, uok := vcs_run([]string{"git", "-C", path, "ls-files", "--others", "--exclude-standard"}); uok {
			ulines := strings.split_lines(untracked_out, context.temp_allocator)
			for uline in ulines {
				utrimmed := strings.trim_space(uline)
				if utrimmed == "" do continue
				append(&all, VCS_Changed_File{
					path      = strings.clone(utrimmed),
					status    = "untracked",
					staged    = false,
					additions = 0,
					deletions = 0,
				})
			}
		}
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

// vcs_git_diff_file parses unified diffs against a target revision, staging area, or /dev/null
// for newly added and deleted files.
vcs_git_diff_file :: proc(path, file, target, cursor: string, limit: int) -> ([]VCS_Diff_Hunk, string, bool, bool) {
	eff_target := strings.trim_space(target)
	full_path, jerr := filepath.join([]string{path, file}, context.temp_allocator)
	if jerr != nil do return nil, "", false, false
	file_exists := os.exists(full_path)

	target_ref := eff_target
	if target_ref == "" || target_ref == "cached" do target_ref = "HEAD"
	_, in_target := vcs_run([]string{"git", "-C", path, "cat-file", "-e", fmt.tprintf("%s:%s", target_ref, file)})

	hunks: []VCS_Diff_Hunk

	if !in_target && file_exists {
		// Newly added or untracked file -> diff against /dev/null (+ lines)
		if content_bytes, err := os.read_entire_file(full_path, context.temp_allocator); err == nil {
			hunks = vcs_synthetic_diff_added(string(content_bytes))
		}
	} else if in_target && !file_exists {
		// Deleted file -> diff against /dev/null (- lines)
		if target_content, ok := vcs_git_file_content(path, file, target_ref); ok {
			hunks = vcs_synthetic_diff_deleted(target_content)
		}
	} else {
		diff_args: [dynamic]string
		append(&diff_args, "git", "-C", path, "diff")
		if eff_target == "cached" {
			append(&diff_args, "--cached", "HEAD")
		} else if eff_target != "" && eff_target != "HEAD" {
			append(&diff_args, eff_target)
		} else {
			append(&diff_args, "HEAD")
		}
		append(&diff_args, "--", file)

		out, ok := vcs_run(diff_args[:])
		if !ok do return nil, "", false, false
		if strings.trim_space(out) != "" {
			hunks = vcs_parse_unified_diff(out)
		}
	}

	page, next_cursor, has_more := vcs_paginate_hunks(hunks, cursor, limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// vcs_git_diff_targets collects available diff targets: HEAD, cached, HEAD~1, upstream, and recent commits.
vcs_git_diff_targets :: proc(path: string) -> ([]VCS_Diff_Target, bool) {
	targets := make([dynamic]VCS_Diff_Target, context.allocator)

	// 1. HEAD (default)
	append(&targets, VCS_Diff_Target{
		id          = "HEAD",
		label       = "HEAD",
		description = "Latest commit on current branch",
		is_default  = true,
	})

	// 2. cached (if staged changes exist)
	if cached_out, ok := vcs_run([]string{"git", "-C", path, "diff", "--cached", "--name-only"}); ok {
		if strings.trim_space(cached_out) != "" {
			append(&targets, VCS_Diff_Target{
				id          = "cached",
				label       = "Staged Changes",
				description = "Changes staged in the index",
				is_default  = false,
			})
		}
	}

	// 3. HEAD~1 (if exists)
	if _, ok := vcs_run([]string{"git", "-C", path, "rev-parse", "--verify", "HEAD~1"}); ok {
		append(&targets, VCS_Diff_Target{
			id          = "HEAD~1",
			label       = "HEAD~1",
			description = "Previous commit",
			is_default  = false,
		})
	}

	// 4. Upstream @{u} (if exists)
	if u_name, ok := vcs_run([]string{"git", "-C", path, "rev-parse", "--abbrev-ref", "@{u}"}); ok {
		u_trimmed := strings.trim_space(u_name)
		if u_trimmed != "" {
			append(&targets, VCS_Diff_Target{
				id          = "@{u}",
				label       = strings.clone(u_trimmed),
				description = "Upstream tracking branch",
				is_default  = false,
			})
		}
	}

	// 5. Last 5 commit SHAs
	if log_out, ok := vcs_run([]string{"git", "-C", path, "log", "-n", "5", "--skip=1", "--pretty=format:%h%x09%s"}); ok {
		lines := strings.split_lines(log_out, context.temp_allocator)
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "" do continue
			tab_idx := strings.index_byte(trimmed, '\t')
			if tab_idx < 0 {
				append(&targets, VCS_Diff_Target{
					id          = strings.clone(trimmed),
					label       = strings.clone(trimmed),
					description = "",
					is_default  = false,
				})
			} else {
				sha := strings.trim_space(trimmed[:tab_idx])
				subj := strings.trim_space(trimmed[tab_idx + 1:])
				append(&targets, VCS_Diff_Target{
					id          = strings.clone(sha),
					label       = strings.clone(sha),
					description = strings.clone(subj),
					is_default  = false,
				})
			}
		}
	}

	return targets[:], true
}

// vcs_git_log queries recent commits formatted as neutral VCS_Log_Entry structs.
vcs_git_log :: proc(path: string, limit: int) -> ([]VCS_Log_Entry, bool) {
	eff_limit := limit
	if eff_limit <= 0 do eff_limit = 20
	if eff_limit > 100 do eff_limit = 100

	limit_str := fmt.tprintf("-n%d", eff_limit)
	out, ok := vcs_run([]string{
		"git", "-C", path, "log", limit_str,
		"--pretty=format:%h%x09%s%x09%an%x09%ad%x09%D",
	})
	if !ok do return nil, false

	entries := make([dynamic]VCS_Log_Entry, context.allocator)
	lines := strings.split_lines(out, context.temp_allocator)
	for line, idx in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		parts := strings.split(trimmed, "\t", context.temp_allocator)
		rev := ""
		title := ""
		author := ""
		timestamp := ""
		ref_names := ""
		if len(parts) > 0 do rev = strings.trim_space(parts[0])
		if len(parts) > 1 do title = strings.trim_space(parts[1])
		if len(parts) > 2 do author = strings.trim_space(parts[2])
		if len(parts) > 3 do timestamp = strings.trim_space(parts[3])
		if len(parts) > 4 do ref_names = strings.trim_space(parts[4])

		is_current := idx == 0 || strings.contains(ref_names, "HEAD")
		status := "committed"
		if is_current do status = "HEAD"

		append(&entries, VCS_Log_Entry{
			revision   = strings.clone(rev),
			cl_number  = "",
			title      = strings.clone(title),
			author     = strings.clone(author),
			timestamp  = strings.clone(timestamp),
			is_current = is_current,
			status     = status,
		})
	}

	return entries[:], true
}

// vcs_git_file_content fetches historical file content at requested target revision.
vcs_git_file_content :: proc(path, file, target: string) -> (string, bool) {
	eff_target := target
	if eff_target == "" do eff_target = "HEAD"
	spec := fmt.tprintf("%s:%s", eff_target, file)
	return vcs_run([]string{"git", "-C", path, "show", spec})
}

// vcs_git_add_file stages a file in Git.
vcs_git_add_file :: proc(path, file: string) -> bool {
	_, ok := vcs_run([]string{"git", "-C", path, "add", "--", file})
	return ok
}

// vcs_git_revert_file restores a tracked file or deletes an untracked file.
vcs_git_revert_file :: proc(path, file: string) -> bool {
	_, tracked := vcs_run([]string{"git", "-C", path, "ls-files", "--error-unmatch", "--", file})
	if tracked {
		_, ok := vcs_run([]string{"git", "-C", path, "checkout", "HEAD", "--", file})
		if !ok {
			_, ok = vcs_run([]string{"git", "-C", path, "restore", "--staged", "--worktree", "--", file})
		}
		return ok
	} else {
		full_path, jerr := filepath.join([]string{path, file}, context.temp_allocator)
		if jerr != nil do return false
		if os.exists(full_path) {
			rerr := os.remove(full_path)
			return rerr == nil
		}
		return true
	}
}

// vcs_git_revert_all discards all changes and untracked files in the working copy.
vcs_git_revert_all :: proc(path: string) -> bool {
	_, ok1 := vcs_run([]string{"git", "-C", path, "reset", "--hard", "HEAD"})
	_, ok2 := vcs_run([]string{"git", "-C", path, "clean", "-fd"})
	return ok1 && ok2
}

// vcs_git_commit creates a commit or amends the current commit.
vcs_git_commit :: proc(path, message: string, amend: bool) -> (string, bool) {
	if amend {
		if message != "" {
			return vcs_run([]string{"git", "-C", path, "commit", "--amend", "-m", message})
		} else {
			return vcs_run([]string{"git", "-C", path, "commit", "--amend", "--no-edit"})
		}
	} else {
		return vcs_run([]string{"git", "-C", path, "commit", "-m", message})
	}
}

