package vcs

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

fig_workspace_name :: proc(name: string) -> string {
	clean, _ := strings.replace_all(name, "/", "_")
	clean, _ = strings.replace_all(clean, "@", "_")
	clean, _ = strings.replace_all(clean, " ", "_")
	clean, _ = strings.replace_all(clean, "-", "_")
	clean = strings.trim(clean, "_.")
	if clean == "" do clean = "workspace"
	return strings.clone(fmt.tprintf("heimdall_%s", clean))
}

fig_parse_workspace_path :: proc(output: string) -> (string, bool) {
	lines := strings.split(output, "\n")
	defer delete(lines)
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.contains(trimmed, "created in ") {
			idx := strings.index(trimmed, "created in ")
			if idx >= 0 {
				path := trimmed[idx + len("created in "):]
				return strings.clone(strings.trim_space(path)), true
			}
		}
	}
	return "", false
}

fig_apply_stat :: proc(handle: Vcs_Workspace_Handle, files: ^[dynamic]Vcs_File_Change) {
	out, ok, _ := vcs_run([]string{"hg", "--cwd", handle.path, "diff", "--stat"})
	if !ok do return
	
	lines := strings.split(out, "\n")
	defer delete(lines)
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.contains(trimmed, "changed,") || strings.contains(trimmed, "insertion") || strings.contains(trimmed, "deletion") do continue
		bar := strings.index(trimmed, "|")
		if bar < 0 do continue
		path := strings.trim_space(trimmed[:bar])
		rest := strings.trim_space(trimmed[bar + 1:])
		
		parts := strings.fields(rest)
		adds := 0; dels := 0
		
		plus_count := strings.count(rest, "+")
		minus_count := strings.count(rest, "-")
		
		if plus_count > 0 || minus_count > 0 {
			adds = plus_count
			dels = minus_count
		} else if len(parts) > 0 {
			if n, n_ok := strconv.parse_int(parts[0]); n_ok {
				adds = int(n)
			}
		}
		
		found := false
		for i in 0..<len(files^) {
			if files^[i].path == path {
				files^[i].adds = adds
				files^[i].dels = dels
				found = true
				break
			}
		}
		if !found {
			append(files, Vcs_File_Change{path = strings.clone(path), status = "", adds = adds, dels = dels})
		}
	}
}

fig_detect :: proc(repo_path: string) -> Vcs_Detect_Result {
	root, ok, msg := vcs_run([]string{"hg", "--cwd", repo_path, "root"})
	if !ok do return Vcs_Detect_Result{kind = .Fig, ok = false, message = msg}
	
	base, base_ok, log_msg := vcs_run([]string{"hg", "--cwd", repo_path, "log", "-r", "p4base", "-T", "{cl}"})
	if !base_ok {
		return Vcs_Detect_Result{kind = .Fig, ok = false, message = fmt.tprintf("not a fig repo (p4base missing): %s", log_msg)}
	}
	
	base_ref := strings.trim_space(base)
	if base_ref == "" {
		base_ref = "p4head"
	}
	
	return Vcs_Detect_Result{
		kind = .Fig,
		repo_root = root,
		base_ref = base_ref,
		ok = true,
		message = "fig repository detected",
	}
}

fig_workspace_add :: proc(repo, name, base_ref, worktree_root: string) -> (Vcs_Workspace_Handle, bool, string) {
	ws_name := fig_workspace_name(name)
	
	cmd := make([dynamic]string)
	defer delete(cmd)
	append(&cmd, "hg", "citc")
	
	is_cl := true
	if base_ref == "" {
		is_cl = false
	} else {
		for r in base_ref {
			if r < '0' || r > '9' {
				is_cl = false
				break
			}
		}
	}
	
	effective_base := base_ref
	allocated_base := false
	if base_ref != "" {
		if is_cl {
			effective_base = fmt.tprintf("cl(%s)", base_ref)
			allocated_base = true
		}
		append(&cmd, "-r", effective_base)
	}
	append(&cmd, ws_name)
	
	out, ok, msg := vcs_run(cmd[:])
	if allocated_base do delete(effective_base)
	
	if !ok do return Vcs_Workspace_Handle{}, false, msg
	
	path, found := fig_parse_workspace_path(out)
	if !found {
		return Vcs_Workspace_Handle{}, false, "failed to parse workspace path from output"
	}
	
	return Vcs_Workspace_Handle{
		path = path,
		branch_or_change = ws_name,
		base_ref = base_ref,
		kind = .Fig,
	}, true, "fig workspace created"
}

fig_workspace_remove :: proc(handle: Vcs_Workspace_Handle, force: bool) -> (bool, string) {
	if !force {
		status, ok, msg := fig_workspace_status(handle)
		if !ok do return false, fmt.tprintf("failed to check status before removal: %s", msg)
		if len(status.files) > 0 {
			return false, "workspace has modified files; use force to remove"
		}
	}
	
	ok, msg := vcs_run_ok([]string{"hg", "citc", "-d", handle.branch_or_change})
	if !ok do return false, msg
	return true, "fig workspace removed"
}

fig_workspace_status :: proc(handle: Vcs_Workspace_Handle) -> (Vcs_Status, bool, string) {
	out, ok, msg := vcs_run([]string{"hg", "--cwd", handle.path, "status"})
	if !ok do return Vcs_Status{}, false, msg
	
	files := make([dynamic]Vcs_File_Change)
	modified, added, deleted, untracked, conflicted := 0, 0, 0, 0, 0
	
	lines := strings.split(out, "\n")
	defer delete(lines)
	for raw in lines {
		line := strings.trim_space(raw)
		if len(line) < 3 do continue
		flag := line[:1]
		path := strings.trim_space(line[2:])
		
		switch flag {
		case "M": modified += 1
		case "A": added += 1
		case "R", "!": deleted += 1
		case "?": untracked += 1
		case: continue
		}
		append(&files, Vcs_File_Change{path = strings.clone(path), status = strings.clone(flag)})
	}
	
	resolve_out, resolve_ok, _ := vcs_run([]string{"hg", "--cwd", handle.path, "resolve", "-l"})
	is_conflicted := false
	if resolve_ok {
		resolve_lines := strings.split(resolve_out, "\n")
		defer delete(resolve_lines)
		for raw in resolve_lines {
			line := strings.trim_space(raw)
			if strings.has_prefix(line, "U ") {
				is_conflicted = true
				conflicted += 1
			}
		}
	}
	
	fig_apply_stat(handle, &files)
	
	ahead_out, ahead_ok, _ := vcs_run([]string{"hg", "--cwd", handle.path, "log", "-r", "(p4base::.) and draft()", "-T", "."})
	ahead := 0
	if ahead_ok {
		ahead = len(ahead_out)
	}
	
	return Vcs_Status{
		ahead_commits = ahead,
		behind_commits = 0,
		files = files[:],
		is_conflicted = is_conflicted,
		summary_line = vcs_summary_from_files(files[:], conflicted),
	}, true, "fig status ok"
}

fig_workspace_diff :: proc(handle: Vcs_Workspace_Handle, path: string) -> (string, bool, string) {
	cmd := make([dynamic]string)
	defer delete(cmd)
	append(&cmd, "hg", "--cwd", handle.path, "diff", "-U", "3")
	if path != "" {
		append(&cmd, "--", path)
	}
	out, ok, msg := vcs_run(cmd[:])
	if !ok do return "", false, msg
	return vcs_truncate_diff(out), true, "fig diff ok"
}

fig_workspace_pull_base :: proc(handle: Vcs_Workspace_Handle) -> (bool, string) {
	return vcs_run_ok([]string{"hg", "--cwd", handle.path, "sync"})
}

fig_merge_preview :: proc(handle: Vcs_Workspace_Handle, target: string) -> (Vcs_Merge_Preview, bool, string) {
	effective_target := target
	if effective_target == "" do effective_target = handle.base_ref
	if effective_target == "" do effective_target = "p4head"
	
	cmds := make([dynamic]string)
	append(&cmds, fmt.tprintf("hg --cwd <repo> sync"))
	
	dest := effective_target
	is_cl := true
	for r in effective_target {
		if r < '0' || r > '9' {
			is_cl = false
			break
		}
	}
	if is_cl {
		dest = fmt.tprintf("cl(%s)", effective_target)
	}
	append(&cmds, fmt.tprintf("hg --cwd <repo> rebase -d %s", dest))
	if is_cl do delete(dest)
	
	return Vcs_Merge_Preview{
		can_fast_forward = true,
		conflicts = nil,
		commands = cmds[:],
		summary = "Fig rebase preview (conflicts not checked)",
	}, true, "fig merge preview ok"
}

fig_merge_execute :: proc(handle: Vcs_Workspace_Handle, target: string) -> (bool, string) {
	effective_target := target
	if effective_target == "" do effective_target = handle.base_ref
	if effective_target == "" do effective_target = "p4head"
	
	is_cl := true
	for r in effective_target {
		if r < '0' || r > '9' {
			is_cl = false
			break
		}
	}
	dest := effective_target
	if is_cl {
		dest = fmt.tprintf("cl(%s)", effective_target)
	}
	
	ok, msg := vcs_run_ok([]string{"hg", "--cwd", handle.path, "rebase", "-d", dest})
	if is_cl do delete(dest)
	
	if !ok do return false, msg
	return true, "fig changes rebased onto target locally"
}
