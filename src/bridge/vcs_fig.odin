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

vcs_fig_name :: proc() -> string {
	return "fig"
}

// vcs_fig_actions declares actions supported by Fig.
vcs_fig_actions := [5]string{"diff", "log", "commit_diff", "revert", "workspaces"}

// vcs_fig_capabilities indicates Fig/Hg features: no index/staging area.
vcs_fig_capabilities :: proc(path: string) -> VCS_Capabilities {
	_ = path
	return VCS_Capabilities{
		provider          = "fig",
		supports_staging  = false,
		staging_model     = "none",
		commit_model      = "revision",
		supported_actions = vcs_fig_actions[:],
	}
}

// vcs_fig_revert_file reverts changes to a tracked file or deletes an untracked file.
vcs_fig_revert_file :: proc(path, file: string) -> (ok: bool, msg: string) {
	if strings.trim_space(file) == "" do return false, "missing_file"
	_, tracked := vcs_run([]string{"hg", "--cwd", path, "files", file})
	if tracked {
		_, ok_run := vcs_run([]string{"hg", "--cwd", path, "revert", "--no-backup", file})
		if !ok_run do return false, "revert_failed"
		return true, ""
	} else {
		full_path, jerr := filepath.join([]string{path, file}, context.temp_allocator)
		if jerr != nil do return false, "invalid_path"
		if os.exists(full_path) {
			rerr := os.remove(full_path)
			if rerr != nil do return false, "revert_failed"
		}
		return true, ""
	}
}

// vcs_fig_provider returns the fig proc-table.
vcs_fig_provider :: proc() -> VCS_Provider {
	return VCS_Provider{
		name              = vcs_fig_name,
		detect            = vcs_fig_detect,
		status            = vcs_fig_status,
		changed_files     = vcs_fig_changed_files,
		diff_file         = vcs_fig_diff_file,
		capabilities      = vcs_fig_capabilities,
		stage_file        = nil,
		unstage_file      = nil,
		revert_file       = vcs_fig_revert_file,
		save_file         = vcs_write_file_impl,
		log               = vcs_fig_log,
		commit_diff       = vcs_fig_commit_diff,
		commit_diff_files = vcs_fig_commit_diff_files,
		commit            = vcs_fig_commit,
		list_workspaces   = vcs_fig_list_workspaces,
	}
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

// vcs_fig_extract_citc_info extracts CitC workspace name and relative path inside google3
// from a path (e.g. /google/src/cloud/tanmayvijay/teloneum-processor/google3/monitoring/cloud_latency/billing/teloneum/processor).
vcs_fig_extract_citc_info :: proc(path: string) -> (workspace_name: string, relative_path: string, is_citc: bool) {
	if path == "" do return "", "", false
	clean_p, cerr := filepath.clean(path, context.temp_allocator)
	if cerr != nil do clean_p = path

	if strings.has_prefix(clean_p, "/google/src/cloud/") {
		sub := clean_p[len("/google/src/cloud/"):]
		slash1 := strings.index_byte(sub, '/')
		if slash1 < 0 do return "", "", false
		ws_part := sub[slash1 + 1:]
		slash2 := strings.index_byte(ws_part, '/')
		ws_name := ""
		tail := ""
		if slash2 < 0 {
			ws_name = ws_part
		} else {
			ws_name = ws_part[:slash2]
			tail = ws_part[slash2 + 1:]
		}
		if ws_name == "" do return "", "", false

		rel := ""
		if tail == "google3" {
			rel = ""
		} else if strings.has_prefix(tail, "google3/") {
			rel = tail[len("google3/"):]
		} else {
			rel = tail
		}
		return ws_name, rel, true
	}

	// Traverse upward looking for .citc marker
	cur := clean_p
	for {
		if vcs_dir_exists(cur, ".citc") {
			ws_name := filepath.base(cur)
			g3_prefix := fmt.tprintf("%s/google3", cur)
			rel := ""
			if clean_p == g3_prefix {
				rel = ""
			} else if strings.has_prefix(clean_p, fmt.tprintf("%s/", g3_prefix)) {
				rel = clean_p[len(g3_prefix) + 1:]
			} else if strings.has_prefix(clean_p, fmt.tprintf("%s/", cur)) {
				rel = clean_p[len(cur) + 1:]
			}
			return ws_name, rel, true
		}
		parent := filepath.dir(cur)
		if parent == cur || parent == "/" || parent == "." {
			if vcs_dir_exists(parent, ".citc") {
				ws_name := filepath.base(parent)
				return ws_name, "", true
			}
			break
		}
		cur = parent
	}

	return "", "", false
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

	ws_name, rel_path, is_citc := vcs_fig_extract_citc_info(path)
	if is_citc && ws_name != "" {
		if st.branch == "" || st.branch == "default" {
			if st.branch != "" do delete(st.branch)
			st.branch = strings.clone(ws_name)
		}
	}

	if is_citc {
		if rel_path != "" {
			st.remote = fmt.aprintf("//depot/google3/%s", rel_path)
		} else {
			st.remote = strings.clone("//depot/google3")
		}
	} else {
		// Query remote default path if available
		if rem, rok := vcs_run([]string{"hg", "--cwd", path, "paths", "default"}); rok {
			trimmed_rem := strings.trim_space(rem)
			if trimmed_rem != "" {
				st.remote = strings.clone(trimmed_rem)
			}
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

// vcs_fig_log queries recent commits / CL stack entries formatted as VCS_Log_Entry structs.
vcs_fig_log :: proc(path, cursor: string, limit: int) -> ([]VCS_Log_Entry, string, bool, bool) {
	start := bridge_fs_decode_cursor(cursor)
	if start < 0 do start = 0
	eff_limit := limit
	if eff_limit <= 0 do eff_limit = VCS_LOG_DEFAULT_LIMIT
	fetch_count := max(100, start + eff_limit + 50)

	limit_str := fmt.tprintf("%d", fetch_count)
	out, ok := vcs_run([]string{
		"hg", "--cwd", path, "log", "-l", limit_str,
		"-T", "{node}|{node|short}|{desc|firstline}|{author}|{date|isodate}\n",
	})
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

// vcs_fig_commit commits changes with the supplied message.
vcs_fig_commit :: proc(path, message: string) -> (ok: bool) {
	if strings.trim_space(message) == "" do return false
	_, rok := vcs_run([]string{"hg", "--cwd", path, "commit", "-m", message})
	return rok
}

// vcs_fig_commit_diff diffs base_ref against head_ref (optionally scoped to one file).
vcs_fig_commit_diff :: proc(path, base_ref, head_ref, file, cursor: string, limit: int) -> ([]VCS_Diff_Hunk, string, bool, bool) {
	if base_ref == head_ref {
		return nil, "", false, true
	}
	diff_args: [dynamic]string
	append(&diff_args, "hg", "--cwd", path, "diff")
	if base_ref != "" {
		append(&diff_args, "-r", base_ref)
	}
	if head_ref != "" && head_ref != "WORKDIR" {
		append(&diff_args, "-r", head_ref)
	}
	if file != "" {
		append(&diff_args, file)
	}

	out, ok := vcs_run(diff_args[:])
	if !ok do return nil, "", false, false

	hunks: []VCS_Diff_Hunk
	if strings.trim_space(out) != "" {
		hunks = vcs_parse_unified_diff(out)
	}
	page, next_cursor, has_more := vcs_paginate_hunks(hunks, cursor, limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// vcs_fig_commit_diff_files returns the flat list of files changed between base_ref and head_ref.
vcs_fig_commit_diff_files :: proc(path, base_ref, head_ref: string) -> ([]VCS_Changed_File, bool) {
	if base_ref == head_ref {
		empty := make([]VCS_Changed_File, 0, context.allocator)
		return empty, true
	}
	status_args: [dynamic]string
	append(&status_args, "hg", "--cwd", path, "status")
	if base_ref != "" {
		append(&status_args, "--rev", base_ref)
	}
	if head_ref != "" && head_ref != "WORKDIR" {
		append(&status_args, "--rev", head_ref)
	}
	append(&status_args, ".")
	out, ok := vcs_run(status_args[:])
	if !ok do return nil, false

	stats := make(map[string][2]int, 0, context.temp_allocator)
	diff_args: [dynamic]string
	append(&diff_args, "hg", "--cwd", path, "diff", "--stat")
	if base_ref != "" {
		append(&diff_args, "-r", base_ref)
	}
	if head_ref != "" && head_ref != "WORKDIR" {
		append(&diff_args, "-r", head_ref)
	}
	append(&diff_args, ".")
	if diff_out, dok := vcs_run(diff_args[:]); dok {
		vcs_fig_parse_diffstat_into(&stats, diff_out)
	}

	files := vcs_fig_parse_changed_files(out, stats, path)
	return files, true
}

// vcs_fig_list_workspaces enumerates available CitC workspaces or returns the current repository.
vcs_fig_list_workspaces :: proc(path: string) -> ([]VCS_Workspace, bool) {
	ws_name, _, is_citc := vcs_fig_extract_citc_info(path)
	user_root := fig_citc_user_root()
	all := make([dynamic]VCS_Workspace, context.allocator)

	if is_citc && os.exists(user_root) && os.is_dir(user_root) {
		infos, err := os.read_directory_by_path(user_root, -1, context.allocator)
		if err == nil {
			defer os.file_info_slice_delete(infos, context.allocator)
			for info in infos {
				name := info.name
				if name == "" || name == "." || name == ".." do continue
				if len(name) > 0 && name[0] == '.' do continue
				if info.type != .Directory do continue
				if !fig_is_valid_workspace_name(name) do continue

				g3_path := fmt.tprintf("%s/%s/google3", user_root, name)
				is_cur := (ws_name != "" && name == ws_name)
				append(&all, VCS_Workspace{
					path       = strings.clone(g3_path),
					label      = strings.clone(name),
					is_current = is_cur,
					is_locked  = false,
				})
			}
		}
	}

	if len(all) == 0 {
		label := ws_name if ws_name != "" else filepath.base(path)
		append(&all, VCS_Workspace{
			path       = strings.clone(path),
			label      = strings.clone(label),
			is_current = true,
			is_locked  = false,
		})
	}

	return all[:], true
}
