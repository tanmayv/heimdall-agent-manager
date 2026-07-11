package main

import "core:fmt"
import "core:os"
import vcs "odin_test:lib/vcs"

main :: proc() {
	root := "/tmp/ham-vcs-backend-test"
	origin := "/tmp/ham-vcs-backend-origin.git"
	worktrees := "/tmp/ham-vcs-backend-worktrees"
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"rm", "-rf", root, origin, worktrees}}, context.allocator)
	_ = os.make_directory_all(root)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "init", "-b", "main", root}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "config", "user.email", "test@example.com"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "config", "user.name", "Test User"}}, context.allocator)
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", root), "hello\n")
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "add", "README.md"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "commit", "-m", "init"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "clone", "--bare", root, origin}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "remote", "add", "origin", origin}}, context.allocator)

	backend := vcs.vcs_backend_for(.Git)
	detected := backend.detect(root)
	if !detected.ok {
		fmt.println("git detect failed", detected.message)
		os.exit(1)
	}
	handle: vcs.Vcs_Workspace_Handle
	ok: bool
	msg: string
	handle, ok, msg = backend.workspace_add(root, "team/test-chain", detected.base_ref, worktrees)
	if !ok {
		fmt.println("git workspace_add failed", msg)
		os.exit(1)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", handle.path), "branch change\n")
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", handle.path, "add", "README.md"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", handle.path, "commit", "-m", "branch change"}}, context.allocator)
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", root), "main change\n")
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "add", "README.md"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "commit", "-m", "main change"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "push", "origin", "main"}}, context.allocator)
	status: vcs.Vcs_Status
	status, ok, msg = backend.workspace_status(handle)
	if !ok {
		fmt.println("git workspace_status failed", msg)
		os.exit(1)
	}
	if status.ahead_commits < 1 || len(status.files) == 0 || status.files[0].adds == 0 {
		fmt.println("git status missing ahead/adds", status.ahead_commits, len(status.files))
		os.exit(1)
	}
	_, ok, msg = backend.workspace_diff(handle, "README.md")
	if !ok {
		fmt.println("git workspace_diff failed", msg)
		os.exit(1)
	}
	preview: vcs.Vcs_Merge_Preview
	preview, ok, msg = backend.merge_preview(handle, "main")
	if !ok || len(preview.commands) == 0 || len(preview.conflicts) == 0 {
		fmt.println("git merge_preview failed", msg, len(preview.conflicts))
		os.exit(1)
	}
	fmt.println("git ok", detected.repo_root, handle.path, handle.branch_or_change, status.summary_line, "conflicts", len(preview.conflicts))

	jj_root := "/tmp/ham-vcs-jj-backend-test"
	jj_workspaces := "/tmp/ham-vcs-jj-workspaces"
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"rm", "-rf", jj_root, jj_workspaces}}, context.allocator)
	_ = os.make_directory_all(jj_root)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "init", "-b", "main", jj_root}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", jj_root, "config", "user.email", "test@example.com"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", jj_root, "config", "user.name", "Test User"}}, context.allocator)
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", jj_root), "hello\n")
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", jj_root, "add", "README.md"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", jj_root, "commit", "-m", "init"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"jj", "git", "init", "--colocate", jj_root}}, context.allocator)
	jj := vcs.vcs_backend_for(.Jj)
	jj_detected := jj.detect(jj_root)
	if !jj_detected.ok {
		fmt.println("jj detect failed", jj_detected.message)
		os.exit(1)
	}
	jj_handle: vcs.Vcs_Workspace_Handle
	jj_ok: bool
	jj_msg: string
	jj_handle, jj_ok, jj_msg = jj.workspace_add(jj_root, "team/test-chain", jj_detected.base_ref, jj_workspaces)
	if !jj_ok {
		fmt.println("jj workspace_add failed", jj_msg)
		os.exit(1)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/jj-change.txt", jj_handle.path), "change\n")
	jj_status: vcs.Vcs_Status
	jj_status, jj_ok, jj_msg = jj.workspace_status(jj_handle)
	if !jj_ok {
		fmt.println("jj workspace_status failed", jj_msg)
		os.exit(1)
	}
	jj_has_adds := false
	for f in jj_status.files {
		if f.adds > 0 do jj_has_adds = true
	}
	if len(jj_status.files) == 0 || !jj_has_adds {
		fmt.println("jj status missing adds", len(jj_status.files))
		os.exit(1)
	}
	_, jj_ok, jj_msg = jj.workspace_diff(jj_handle, "jj-change.txt")
	if !jj_ok {
		fmt.println("jj workspace_diff failed", jj_msg)
		os.exit(1)
	}
	jj_preview: vcs.Vcs_Merge_Preview
	jj_preview, jj_ok, jj_msg = jj.merge_preview(jj_handle, jj_detected.base_ref)
	if !jj_ok || len(jj_preview.commands) == 0 {
		fmt.println("jj merge_preview failed", jj_msg)
		os.exit(1)
	}
	fmt.println("jj ok", jj_detected.repo_root, jj_handle.path, jj_handle.branch_or_change, jj_status.summary_line)
}
