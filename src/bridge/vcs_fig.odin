package main

// Google Hg/Fig adapter for the VCS provider interface (see vcs_provider.odin).
//
// Supports Mercurial/Fig repositories and CitC workspaces. Scopes status, changed
// files, and diffs to the selected directory via `hg --cwd <path> ...` commands.
// Detection traverses upward to locate repository or CitC workspace markers (.hg, .citc)
// or recognizes /google/src/cloud/ paths.

import "core:fmt"
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
		diff_targets  = vcs_fig_diff_targets,
		log           = vcs_fig_log,
		file_content  = vcs_fig_file_content,
		add_file      = vcs_fig_add_file,
		revert_file   = vcs_fig_revert_file,
		revert_all    = vcs_fig_revert_all,
		commit        = vcs_fig_commit,
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

// vcs_fig_diffstat_into queries additions and deletions per file via `hg --cwd <path> diff --stat`.
vcs_fig_diffstat_into :: proc(stats: ^map[string][2]int, path, target: string) {
	eff_target := strings.trim_space(target)
	diff_args: [dynamic]string
	append(&diff_args, "hg", "--cwd", path, "diff", "--stat")
	if eff_target == "pdiff" {
		append(&diff_args, "-r", ".~1")
	} else if eff_target != "" && eff_target != "." {
		append(&diff_args, "-r", eff_target)
	}
	append(&diff_args, ".")
	out, ok := vcs_run(diff_args[:])
	if !ok do return
	vcs_fig_parse_diffstat_into(stats, out)
}

// vcs_fig_parse_changed_files parses raw `hg status` output lines into VCS_Changed_File structs.
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

// vcs_fig_changed_files parses `hg --cwd <path> status` scoped strictly to the selected directory and target revision,
// joins per-file addition/deletion counts from diffstat, and paginates.
vcs_fig_changed_files :: proc(path, target, cursor: string, limit: int) -> ([]VCS_Changed_File, string, bool, bool) {
	eff_target := strings.trim_space(target)
	status_args: [dynamic]string
	append(&status_args, "hg", "--cwd", path, "status")
	if eff_target == "pdiff" {
		append(&status_args, "--rev", ".~1")
	} else if eff_target != "" && eff_target != "." {
		append(&status_args, "--rev", eff_target)
	}
	append(&status_args, ".")

	out, ok := vcs_run(status_args[:])
	if !ok do return nil, "", false, false

	stats := make(map[string][2]int, 0, context.temp_allocator)
	vcs_fig_diffstat_into(&stats, path, eff_target)

	all := vcs_fig_parse_changed_files(out, stats, path)
	page, next_cursor, has_more := vcs_paginate_files(all, cursor, limit, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// vcs_fig_diff_file parses `hg --cwd <path> diff` into hunks, with synthetic unified diffs for added/deleted files.
vcs_fig_diff_file :: proc(path, file, target, cursor: string, limit: int) -> ([]VCS_Diff_Hunk, string, bool, bool) {
	eff_target := strings.trim_space(target)
	if eff_target == "pdiff" do eff_target = ".~1"
	if eff_target == "" do eff_target = "."

	full_path, jerr := filepath.join([]string{path, file}, context.temp_allocator)
	if jerr != nil do return nil, "", false, false
	file_exists := os.exists(full_path)

	target_content, in_target := vcs_fig_file_content(path, file, eff_target)

	hunks: []VCS_Diff_Hunk

	if !in_target && file_exists {
		// Newly added or untracked file -> diff against /dev/null (+ lines)
		if content_bytes, err := os.read_entire_file(full_path, context.temp_allocator); err == nil {
			hunks = vcs_synthetic_diff_added(string(content_bytes))
		}
	} else if in_target && !file_exists {
		// Deleted file -> diff against /dev/null (- lines)
		hunks = vcs_synthetic_diff_deleted(target_content)
	} else {
		diff_args: [dynamic]string
		append(&diff_args, "hg", "--cwd", path, "diff")
		if eff_target != "." {
			append(&diff_args, "-r", eff_target)
		}
		append(&diff_args, file)

		out, ok := vcs_run(diff_args[:])
		if !ok do return nil, "", false, false
		if strings.trim_space(out) != "" {
			hunks = vcs_parse_unified_diff(out)
		}
	}

	page, next_cursor, has_more := vcs_paginate_hunks(hunks, cursor, limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// vcs_fig_diff_targets collects available diff targets: current (.), parent (pdiff), p4base, p4head, and CL stack.
vcs_fig_diff_targets :: proc(path: string) -> ([]VCS_Diff_Target, bool) {
	targets := make([dynamic]VCS_Diff_Target, context.allocator)

	// 1. Current revision (.) - default
	append(&targets, VCS_Diff_Target{
		id          = ".",
		label       = "Current revision (.)",
		description = "Changes in working copy vs current revision",
		is_default  = true,
	})

	// 2. Parent (.~1 / pdiff)
	append(&targets, VCS_Diff_Target{
		id          = "pdiff",
		label       = "Parent (.~1 / pdiff)",
		description = "Changes vs parent revision",
		is_default  = false,
	})

	// 3. p4base
	append(&targets, VCS_Diff_Target{
		id          = "p4base",
		label       = "p4base",
		description = "Perforce base snapshot",
		is_default  = false,
	})

	// 4. p4head
	append(&targets, VCS_Diff_Target{
		id          = "p4head",
		label       = "p4head",
		description = "Perforce head revision",
		is_default  = false,
	})

	// 5. CL stack entries from hg log
	if log_out, ok := vcs_run([]string{
		"hg", "--cwd", path, "log", "-l", "10",
		"-T", "{rev}\\t{node|short}\\t{cl}\\t{desc|firstline}\\n",
	}); ok {
		lines := strings.split_lines(log_out, context.temp_allocator)
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "" do continue
			parts := strings.split(trimmed, "\t", context.temp_allocator)
			if len(parts) < 4 do continue
			rev := strings.trim_space(parts[0])
			node := strings.trim_space(parts[1])
			cl := strings.trim_space(parts[2])
			desc := strings.trim_space(parts[3])

			id := node
			label := node
			if cl != "" {
				id = cl
				label = fmt.tprintf("CL %s (%s)", cl, node)
			} else if rev != "" {
				label = fmt.tprintf("Rev %s (%s)", rev, node)
			}

			append(&targets, VCS_Diff_Target{
				id          = strings.clone(id),
				label       = strings.clone(label),
				description = strings.clone(desc),
				is_default  = false,
			})
		}
	}

	return targets[:], true
}

// vcs_fig_log queries recent commits / Fig CL stack entries formatted as VCS_Log_Entry structs.
vcs_fig_log :: proc(path: string, limit: int) -> ([]VCS_Log_Entry, bool) {
	eff_limit := limit
	if eff_limit <= 0 do eff_limit = 20
	if eff_limit > 100 do eff_limit = 100

	limit_str := fmt.tprintf("%d", eff_limit)
	out, ok := vcs_run([]string{
		"hg", "--cwd", path, "log", "-l", limit_str,
		"-T", "{rev}\\t{node|short}\\t{cl}\\t{desc|firstline}\\t{phase}\\t{author}\\t{date|isodate}\\n",
	})
	if !ok do return nil, false

	cur_node := ""
	if id_out, iok := vcs_run([]string{"hg", "--cwd", path, "identify", "-i"}); iok {
		cur_node = strings.trim_right(strings.trim_space(id_out), "+")
	}

	entries := make([dynamic]VCS_Log_Entry, context.allocator)
	lines := strings.split_lines(out, context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		parts := strings.split(trimmed, "\t", context.temp_allocator)
		if len(parts) < 5 do continue

		rev := strings.trim_space(parts[0])
		node := strings.trim_space(parts[1])
		cl := strings.trim_space(parts[2])
		desc := strings.trim_space(parts[3])
		phase := strings.trim_space(parts[4])
		author := ""
		timestamp := ""
		if len(parts) > 5 do author = strings.trim_space(parts[5])
		if len(parts) > 6 do timestamp = strings.trim_space(parts[6])

		is_current := (cur_node != "" && (node == cur_node || strings.has_prefix(cur_node, node) || strings.has_prefix(node, cur_node)))

		append(&entries, VCS_Log_Entry{
			revision   = strings.clone(node if node != "" else rev),
			cl_number  = strings.clone(cl),
			title      = strings.clone(desc),
			author     = strings.clone(author),
			timestamp  = strings.clone(timestamp),
			is_current = is_current,
			status     = strings.clone(phase),
		})
	}

	return entries[:], true
}

// vcs_fig_file_content fetches historical file content at requested target revision via hg cat.
vcs_fig_file_content :: proc(path, file, target: string) -> (string, bool) {
	eff_target := target
	if eff_target == "" do eff_target = "."
	if eff_target == "pdiff" do eff_target = ".~1"
	return vcs_run([]string{"hg", "--cwd", path, "cat", "-r", eff_target, file})
}

// vcs_fig_add_file adds an untracked file to Mercurial/Fig.
vcs_fig_add_file :: proc(path, file: string) -> bool {
	_, ok := vcs_run([]string{"hg", "--cwd", path, "add", file})
	return ok
}

// vcs_fig_revert_file reverts changes to a tracked file or deletes an untracked file.
vcs_fig_revert_file :: proc(path, file: string) -> bool {
	_, tracked := vcs_run([]string{"hg", "--cwd", path, "files", file})
	if tracked {
		_, ok := vcs_run([]string{"hg", "--cwd", path, "revert", "--no-backup", file})
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

// vcs_fig_revert_all reverts all changes in the working copy.
vcs_fig_revert_all :: proc(path: string) -> bool {
	_, ok := vcs_run([]string{"hg", "--cwd", path, "revert", "--all", "--no-backup"})
	return ok
}

// vcs_fig_commit commits changes or amends the current revision.
vcs_fig_commit :: proc(path, message: string, amend: bool) -> (string, bool) {
	if amend {
		if message != "" {
			return vcs_run([]string{"hg", "--cwd", path, "amend", "-m", message})
		} else {
			return vcs_run([]string{"hg", "--cwd", path, "amend"})
		}
	} else {
		return vcs_run([]string{"hg", "--cwd", path, "commit", "-m", message})
	}
}

