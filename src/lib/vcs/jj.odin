package vcs

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

jj_detect :: proc(repo_path: string) -> Vcs_Detect_Result {
	root, ok, msg := vcs_run([]string{"jj", "-R", repo_path, "workspace", "root"})
	if !ok do return Vcs_Detect_Result{kind = .Jj, ok = false, message = msg}
	base, base_ok, _ := vcs_run([]string{"jj", "-R", repo_path, "log", "-r", "trunk()", "--no-graph", "-T", "commit_id.short()"})
	if !base_ok || strings.trim_space(base) == "" do base = "trunk()"
	return Vcs_Detect_Result{kind = .Jj, repo_root = root, base_ref = strings.trim_space(base), ok = true, message = "jj repository detected"}
}

jj_workspace_add :: proc(repo, name, base_ref, worktree_root: string) -> (Vcs_Workspace_Handle, bool, string) {
	effective_base := base_ref
	if effective_base == "" do effective_base = "trunk()"
	clean_name, _ := strings.replace_all(name, "/", "_")
	ws_name := fmt.tprintf("ws_%s", clean_name)
	path := vcs_workspace_path(worktree_root, name)
	_ = os.make_directory_all(vcs_workspace_parent(path))
	_, ok, msg := vcs_run([]string{"jj", "-R", repo, "workspace", "add", "--name", ws_name, path})
	if !ok do return Vcs_Workspace_Handle{}, false, msg
	_, ok, msg = vcs_run([]string{"jj", "-R", path, "new", effective_base})
	if !ok do return Vcs_Workspace_Handle{}, false, msg
	_, _, _ = vcs_run([]string{"jj", "-R", path, "describe", "-m", name})
	return Vcs_Workspace_Handle{path = path, branch_or_change = ws_name, base_ref = effective_base, kind = .Jj}, true, "jj workspace created"
}

jj_workspace_remove :: proc(handle: Vcs_Workspace_Handle, force: bool) -> (bool, string) {
	_, _, _ = vcs_run([]string{"jj", "-R", handle.path, "workspace", "forget", handle.branch_or_change})
	if !force {
		ok, msg := vcs_write_kept_marker(handle, "", "", "jj workspace remove keep")
		if !ok do return false, msg
		return true, "jj workspace forgotten; files kept"
	}
	_, _, _ = vcs_run([]string{"rm", "-rf", handle.path})
	return true, "jj workspace removed"
}

jj_workspace_status :: proc(handle: Vcs_Workspace_Handle) -> (Vcs_Status, bool, string) {
	out, ok, msg := vcs_run([]string{"jj", "-R", handle.path, "status"})
	if !ok do return Vcs_Status{}, false, msg
	files := make([dynamic]Vcs_File_Change)
	modified, added, deleted, untracked, conflicted := 0, 0, 0, 0, 0
	for raw in strings.split(out, "\n") {
		line := strings.trim_space(raw)
		if len(line) < 3 do continue
		flag := line[:1]
		path := strings.trim_space(line[2:])
		switch flag {
		case "M": modified += 1
		case "A": added += 1
		case "D": deleted += 1
		case "?": untracked += 1
		case "C": conflicted += 1
		case: continue
		}
		append(&files, Vcs_File_Change{path = strings.clone(path), status = strings.clone(flag)})
	}
	if strings.contains(out, "conflict") do conflicted += 1
	jj_apply_stat(handle, &files)
	ahead := jj_count_log(handle.path, fmt.tprintf("ancestors(@, 100) ~ ancestors(%s, 100)", handle.base_ref))
	behind := jj_count_log(handle.path, fmt.tprintf("ancestors(%s, 100) ~ ancestors(@, 100)", handle.base_ref))
	return Vcs_Status{ahead_commits = ahead, behind_commits = behind, files = files[:], is_conflicted = conflicted > 0, summary_line = vcs_summary_from_files(files[:], 0)}, true, "jj status ok"
}

jj_workspace_diff :: proc(handle: Vcs_Workspace_Handle, path: string) -> (string, bool, string) {
	file_arg := fmt.tprintf("root:%s", path)
	out, ok, msg := vcs_run([]string{"jj", "-R", handle.path, "diff", "-r", "@-", "--context", "3", "--", file_arg})
	if !ok do return "", false, msg
	return vcs_truncate_diff(out), true, "jj diff ok"
}

jj_workspace_pull_base :: proc(handle: Vcs_Workspace_Handle) -> (bool, string) {
	_, _, _ = vcs_run([]string{"jj", "-R", handle.path, "git", "fetch"})
	return vcs_run_ok([]string{"jj", "-R", handle.path, "rebase", "-d", handle.base_ref})
}

jj_merge_preview :: proc(handle: Vcs_Workspace_Handle, target: string) -> (Vcs_Merge_Preview, bool, string) {
	effective_target := target
	if effective_target == "" do effective_target = handle.base_ref
	cmds := make([dynamic]string)
	append(&cmds, strings.clone(fmt.tprintf("jj -R <repo> workspace forget %s", handle.branch_or_change)))
	append(&cmds, strings.clone(fmt.tprintf("jj -R <repo> rebase -r @ -d %s", effective_target)))
	append(&cmds, strings.clone("jj -R <repo> git push --branch main"))
	conflicts := make([dynamic]string)
	out, ok, msg := vcs_run([]string{"jj", "-R", handle.path, "rebase", "-r", "@", "-d", effective_target, "--dry-run"})
	if !ok {
		for line in strings.split(out, "\n") {
			trimmed := strings.trim_space(line)
			if strings.contains(trimmed, "conflict") do append(&conflicts, strings.clone(trimmed))
		}
		if len(conflicts) == 0 do append(&conflicts, strings.clone(msg))
		return Vcs_Merge_Preview{can_fast_forward = false, conflicts = conflicts[:], commands = cmds[:], summary = fmt.tprintf("jj preview found %d conflict marker(s)", len(conflicts))}, true, "jj merge preview ok"
	}
	return Vcs_Merge_Preview{can_fast_forward = len(conflicts) == 0, conflicts = conflicts[:], commands = cmds[:], summary = fmt.tprintf("Preview jj rebase onto %s", effective_target)}, true, "jj merge preview ok"
}

jj_apply_stat :: proc(handle: Vcs_Workspace_Handle, files: ^[dynamic]Vcs_File_Change) {
	out, ok, _ := vcs_run([]string{"jj", "-R", handle.path, "diff", "--stat", "-r", "@-..@"})
	if !ok do return
	for line in strings.split(out, "\n") {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.contains(trimmed, "file") do continue
		bar := strings.index(trimmed, "|")
		if bar < 0 do continue
		path := strings.trim_space(trimmed[:bar])
		rest := strings.trim_space(trimmed[bar + 1:])
		parts := strings.fields(rest)
		adds := 0; dels := 0
		if len(parts) > 0 {
			if n, n_ok := strconv.parse_int(parts[0]); n_ok do adds = int(n)
		}
		if plus := strings.index(rest, "+"); plus >= 0 do adds = max(adds, strings.count(rest, "+"))
		if minus := strings.index(rest, "-"); minus >= 0 do dels = strings.count(rest, "-")
		found := false
		for i in 0..<len(files^) {
			if files^[i].path == path {
				files^[i].adds = adds; files^[i].dels = dels; found = true
			}
		}
		if !found do append(files, Vcs_File_Change{path = strings.clone(path), status = "", adds = adds, dels = dels})
	}
}

jj_count_log :: proc(repo_path, revset: string) -> int {
	out, ok, _ := vcs_run([]string{"jj", "-R", repo_path, "log", "-r", revset, "--no-graph", "-T", "commit_id.short() ++ \"\\n\""})
	if !ok do return 0
	count := 0
	for line in strings.split(out, "\n") {
		if strings.trim_space(line) != "" do count += 1
	}
	return count
}

jj_merge_execute :: proc(handle: Vcs_Workspace_Handle, target: string) -> (bool, string) {
	// Operator-gated local integration only. Rebase the workspace change onto
	// <target>; never push automatically (INV-4). The git push recipe stays a
	// manual command shown in merge_preview.commands[].
	effective_target := target
	if effective_target == "" do effective_target = handle.base_ref
	if effective_target == "" do effective_target = "trunk()"
	if r_ok, r_msg := vcs_run_ok([]string{"jj", "-R", handle.path, "rebase", "-r", "@", "-d", effective_target}); !r_ok {
		return false, r_msg
	}
	return true, "jj change rebased onto target locally; push manually when ready"
}
