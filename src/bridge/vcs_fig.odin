package main

// Google Hg/Fig adapter for the VCS provider interface (see vcs_provider.odin).
//
// Supports Mercurial/Fig repositories and CitC workspaces. Scopes status, changed
// files, and diffs to the selected directory via `hg --cwd <path> ...` commands.
// Detection traverses upward to locate repository or CitC workspace markers (.hg, .citc)
// or recognizes /google/src/cloud/ paths.

import "core:os"
import "core:strings"
import "core:path/filepath"

// vcs_fig_provider returns the fig proc-table.
vcs_fig_provider :: proc() -> VCS_Provider {
	return VCS_Provider{
		name          = vcs_fig_name,
		detect        = vcs_fig_detect,
		status        = vcs_fig_status,
		changed_files = vcs_fig_changed_files,
		diff_file     = vcs_fig_diff_file,
		capabilities  = vcs_fig_capabilities,
	}
}

vcs_fig_name :: proc() -> string {
	return "fig"
}

// vcs_fig_capabilities indicates Fig/Hg features: no index/staging area.
vcs_fig_capabilities :: proc(path: string) -> VCS_Capabilities {
	_ = path
	return VCS_Capabilities{provider = "fig", supports_staging = false}
}

// vcs_fig_detect checks if path is within a Mercurial/Fig or CitC workspace.
// It checks /google/src/cloud/ prefixes, traverses upward for .hg or .citc,
// and probes with `hg --cwd <path> root`.
vcs_fig_detect :: proc(path: string) -> bool {
	if path == "" do return false
	if !os.exists(path) do return false

	// Fast path for Google Cloudtop CitC workspace paths
	if strings.has_prefix(path, "/google/src/cloud/") {
		return true
	}

	// Traverse upward looking for repository / workspace markers (.hg or .citc)
	cur, _ := filepath.clean(path, context.temp_allocator)
	for {
		if vcs_dir_exists(cur, ".hg") || vcs_dir_exists(cur, ".citc") {
			return true
		}
		parent := filepath.dir(cur)
		if parent == cur || parent == "/" || parent == "." {
			if vcs_dir_exists(parent, ".hg") || vcs_dir_exists(parent, ".citc") {
				return true
			}
			break
		}
		cur = parent
	}

	// Fallback probe via hg root
	if _, ok := vcs_run([]string{"hg", "--cwd", path, "root"}); ok {
		return true
	}

	return false
}

// vcs_fig_status collects bookmark/branch, remote default path, and clean flag
// scoped to the selected directory w.r.t. `hg --cwd <path> status .`.
vcs_fig_status :: proc(path: string) -> (VCS_Status, bool) {
	st := VCS_Status{provider = "fig"}

	// is_clean probe w.r.t. selected directory
	out, ok := vcs_run([]string{"hg", "--cwd", path, "status", "."})
	if !ok do return st, false
	st.is_clean = strings.trim_space(out) == ""

	// Query bookmark via log or identify
	if bm, bok := vcs_run([]string{"hg", "--cwd", path, "log", "-r", ".", "-T", "{bookmark}"}); bok {
		trimmed_bm := strings.trim_space(bm)
		if trimmed_bm != "" {
			st.branch = strings.clone(trimmed_bm)
		}
	}
	if st.branch == "" {
		if id_b, iok := vcs_run([]string{"hg", "--cwd", path, "identify", "-B"}); iok {
			trimmed_id := strings.trim_space(id_b)
			if trimmed_id != "" {
				st.branch = strings.clone(trimmed_id)
			}
		}
	}
	if st.branch == "" {
		if br, brok := vcs_run([]string{"hg", "--cwd", path, "branch"}); brok {
			trimmed_br := strings.trim_space(br)
			if trimmed_br != "" {
				st.branch = strings.clone(trimmed_br)
			}
		}
	}

	// Query remote default path if available
	if rem, rok := vcs_run([]string{"hg", "--cwd", path, "paths", "default"}); rok {
		trimmed_rem := strings.trim_space(rem)
		if trimmed_rem != "" {
			st.remote = strings.clone(trimmed_rem)
		}
	}

	return st, true
}

// vcs_fig_status_word maps hg status codes ('M', 'A', 'R', '!', '?') to neutral status words.
vcs_fig_status_word :: proc(code: u8) -> string {
	switch code {
	case 'M': return "modified"
	case 'A': return "added"
	case 'R': return "deleted"
	case '!': return "deleted"
	case '?': return "untracked"
	case:     return "modified"
	}
}

// vcs_fig_parse_diffstat_into folds diffstat summary lines ("<path> | <total> <graph>")
// into stats (keyed by path). Summary totals lines without a pipe are skipped.
vcs_fig_parse_diffstat_into :: proc(stats: ^map[string][2]int, out: string) {
	lines := strings.split_lines(out, context.temp_allocator)
	for line in lines {
		pipe := strings.index_byte(line, '|')
		if pipe < 0 do continue // Skip non-file summary line ("1 files changed...")
		raw_file := strings.trim_space(line[:pipe])
		if raw_file == "" do continue

		clean_file := raw_file
		if strings.has_prefix(clean_file, "./") {
			clean_file = clean_file[2:]
		}

		rest := strings.trim_space(line[pipe + 1:])
		fields := strings.fields(rest, context.temp_allocator)
		if len(fields) == 0 do continue
		total := vcs_atoi(fields[0])

		plus_count := 0
		minus_count := 0
		for ch in rest {
			if ch == '+' do plus_count += 1
			if ch == '-' do minus_count += 1
		}

		additions := 0
		deletions := 0
		if plus_count + minus_count > 0 {
			additions = (total * plus_count) / (plus_count + minus_count)
			deletions = total - additions
		} else {
			additions = total
			deletions = 0
		}

		stats[clean_file] = [2]int{additions, deletions}
	}
}

// vcs_fig_diffstat_into queries additions and deletions per file via `hg --cwd <path> diff --stat .`.
vcs_fig_diffstat_into :: proc(stats: ^map[string][2]int, path: string) {
	out, ok := vcs_run([]string{"hg", "--cwd", path, "diff", "--stat", "."})
	if !ok do return
	vcs_fig_parse_diffstat_into(stats, out)
}

// vcs_fig_parse_changed_files parses raw `hg status .` output lines into VCS_Changed_File structs.
vcs_fig_parse_changed_files :: proc(out: string, stats: map[string][2]int, base_path: string = "") -> []VCS_Changed_File {
	all := make([dynamic]VCS_Changed_File, context.allocator)
	lines := strings.split_lines(out, context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_right(line, "\r")
		if len(trimmed) < 2 do continue
		code := trimmed[0]
		raw_path := strings.trim_space(trimmed[1:])
		if raw_path == "" do continue

		clean_path := raw_path
		if strings.has_prefix(clean_path, "./") {
			clean_path = clean_path[2:]
		}
		if base_path != "" && strings.has_prefix(clean_path, base_path) {
			rel := clean_path[len(base_path):]
			if strings.has_prefix(rel, "/") {
				rel = rel[1:]
			}
			clean_path = rel
		}

		counts := stats[clean_path]
		append(&all, VCS_Changed_File{
			path      = strings.clone(clean_path),
			status    = vcs_fig_status_word(code),
			staged    = false,
			additions = counts[0],
			deletions = counts[1],
		})
	}
	return all[:]
}

// vcs_fig_changed_files parses `hg --cwd <path> status .` scoped strictly to the selected directory,
// joins per-file addition/deletion counts from diffstat, and paginates.
vcs_fig_changed_files :: proc(path, cursor: string, limit: int) -> ([]VCS_Changed_File, string, bool, bool) {
	out, ok := vcs_run([]string{"hg", "--cwd", path, "status", "."})
	if !ok do return nil, "", false, false

	stats := make(map[string][2]int, 0, context.temp_allocator)
	vcs_fig_diffstat_into(&stats, path)

	all := vcs_fig_parse_changed_files(out, stats, path)
	page, next_cursor, has_more := vcs_paginate_files(all, cursor, limit, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// vcs_fig_diff_file parses `hg --cwd <path> diff <file>` into hunks, then paginates.
vcs_fig_diff_file :: proc(path, file, cursor: string, limit: int) -> ([]VCS_Diff_Hunk, string, bool, bool) {
	out, ok := vcs_run([]string{"hg", "--cwd", path, "diff", file})
	if !ok do return nil, "", false, false
	hunks := vcs_parse_unified_diff(out)
	page, next_cursor, has_more := vcs_paginate_hunks(hunks, cursor, limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	return page, next_cursor, has_more, true
}
