package vcs

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Vcs_Kind :: enum { None, Git, Jj }

Vcs_Detect_Result :: struct {
	kind:      Vcs_Kind,
	repo_root: string,
	base_ref:  string,
	ok:        bool,
	message:   string,
}

Vcs_Workspace_Handle :: struct {
	path:             string,
	branch_or_change: string,
	base_ref:         string,
	kind:             Vcs_Kind,
}

Vcs_File_Change :: struct {
	path:   string,
	status: string,
	adds:   int,
	dels:   int,
}

Vcs_Status :: struct {
	ahead_commits:  int,
	behind_commits: int,
	files:          []Vcs_File_Change,
	is_conflicted:  bool,
	summary_line:   string,
}

Vcs_Merge_Preview :: struct {
	can_fast_forward: bool,
	conflicts:        []string,
	commands:         []string,
	summary:          string,
}

Vcs_Repo_Diff :: struct {
	diff:     string,
	mode:     string,
	label:    string,
	base_sha: string,
}

Vcs_Backend :: struct {
	kind:                Vcs_Kind,
	detect:              proc(repo_path: string) -> Vcs_Detect_Result,
	workspace_add:       proc(repo: string, name: string, base_ref: string, worktree_root: string) -> (Vcs_Workspace_Handle, bool, string),
	workspace_remove:    proc(handle: Vcs_Workspace_Handle, force: bool) -> (bool, string),
	workspace_status:    proc(handle: Vcs_Workspace_Handle) -> (Vcs_Status, bool, string),
	workspace_diff:      proc(handle: Vcs_Workspace_Handle, path: string) -> (string, bool, string),
	workspace_pull_base: proc(handle: Vcs_Workspace_Handle) -> (bool, string),
	repo_head_sha:        proc(repo: string) -> (string, bool, string),
	repo_status:          proc(repo, diff_base_sha: string) -> (Vcs_Status, bool, string),
	repo_diff:            proc(repo, path, diff_base_sha: string) -> (Vcs_Repo_Diff, bool, string),
	merge_preview:       proc(handle: Vcs_Workspace_Handle, target: string) -> (Vcs_Merge_Preview, bool, string),
	merge_execute:       proc(handle: Vcs_Workspace_Handle, target: string) -> (bool, string),
}

none_backend := Vcs_Backend{kind = .None}
git_backend := Vcs_Backend{kind = .Git, detect = git_detect, workspace_add = git_workspace_add, workspace_remove = git_workspace_remove, workspace_status = git_workspace_status, workspace_diff = git_workspace_diff, workspace_pull_base = git_workspace_pull_base, repo_head_sha = git_repo_head_sha, repo_status = git_repo_status, repo_diff = git_repo_diff, merge_preview = git_merge_preview, merge_execute = git_merge_execute}
jj_backend := Vcs_Backend{kind = .Jj, detect = jj_detect, workspace_add = jj_workspace_add, workspace_remove = jj_workspace_remove, workspace_status = jj_workspace_status, workspace_diff = jj_workspace_diff, workspace_pull_base = jj_workspace_pull_base, merge_preview = jj_merge_preview, merge_execute = jj_merge_execute}

vcs_backend_for :: proc(kind: Vcs_Kind) -> ^Vcs_Backend {
	switch kind {
	case .Git: return &git_backend
	case .Jj: return &jj_backend
	case .None: return &none_backend
	}
	return &none_backend
}

vcs_run :: proc(cmd: []string) -> (string, bool, string) {
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil do return "", false, "command failed to start"
	out := strings.trim_space(string(stdout))
	if state.success do return strings.clone(out), true, "ok"
	msg := strings.trim_space(string(stderr))
	if msg == "" do msg = "command failed"
	return strings.clone(out), false, vcs_safe_message(msg)
}

vcs_run_ok :: proc(cmd: []string) -> (bool, string) {
	_, ok, msg := vcs_run(cmd)
	return ok, msg
}

vcs_safe_message :: proc(msg: string) -> string {
	trimmed := strings.trim_space(msg)
	if len(trimmed) > 512 do return fmt.tprintf("%s… [truncated]", trimmed[:512])
	return strings.clone(trimmed)
}

vcs_truncate_diff :: proc(text: string) -> string {
	if len(text) <= 512 * 1024 do return strings.clone(text)
	return fmt.tprintf("%s\n… [truncated]", text[:512 * 1024])
}

vcs_workspace_path :: proc(root, name: string) -> string {
	return strings.clone(fmt.tprintf("%s/%s", strings.trim_right(root, "/"), strings.trim_left(name, "/")))
}

vcs_workspace_parent :: proc(path: string) -> string {
	idx := strings.last_index(path, "/")
	if idx < 0 do return "."
	return strings.clone(path[:idx])
}

vcs_write_kept_marker :: proc(handle: Vcs_Workspace_Handle, chain_id, workspace_id, reason: string) -> (bool, string) {
	if handle.path == "" do return false, "workspace path missing"
	_ = os.make_directory_all(handle.path)
	marker := fmt.tprintf("%s/.heimdall-kept", strings.trim_right(handle.path, "/"))
	kind := "none"
	switch handle.kind {
	case .Git: kind = "git"
	case .Jj: kind = "jj"
	case .None: kind = "none"
	}
	body := strings.builder_make()
	strings.write_string(&body, "# Heimdall kept workspace marker\n")
	strings.write_string(&body, fmt.tprintf("chain_id=%s\n", chain_id))
	strings.write_string(&body, fmt.tprintf("workspace_id=%s\n", workspace_id))
	strings.write_string(&body, fmt.tprintf("vcs_kind=%s\n", kind))
	strings.write_string(&body, fmt.tprintf("path=%s\n", handle.path))
	strings.write_string(&body, fmt.tprintf("branch_or_change=%s\n", handle.branch_or_change))
	strings.write_string(&body, fmt.tprintf("timestamp_unix_ms=%d\n", time.to_unix_nanoseconds(time.now()) / 1_000_000))
	strings.write_string(&body, fmt.tprintf("reason=%s\n", reason))
	if os.write_entire_file(marker, strings.to_string(body)) != nil {
		return false, "failed to write kept marker"
	}
	return true, "kept marker written"
}

vcs_summary_line :: proc(modified, added, deleted, untracked, conflicted: int) -> string {
	return strings.clone(fmt.tprintf("%d modified, %d added, %d deleted, %d untracked, %d conflicted", modified, added, deleted, untracked, conflicted))
}

vcs_summary_from_files :: proc(files: []Vcs_File_Change, conflicted: int) -> string {
	modified, added, deleted, untracked := 0, 0, 0, 0
	conflict_count := conflicted
	for f in files {
		if strings.contains(f.status, "U") || f.status == "C" { conflict_count += 1 }
		else if strings.contains(f.status, "?") { untracked += 1 }
		else if strings.contains(f.status, "A") || (f.status == "" && f.adds > 0 && f.dels == 0) { added += 1 }
		else if strings.contains(f.status, "D") || (f.status == "" && f.dels > 0 && f.adds == 0) { deleted += 1 }
		else { modified += 1 }
	}
	return vcs_summary_line(modified, added, deleted, untracked, conflict_count)
}
