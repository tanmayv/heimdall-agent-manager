package team_kinds_test

import "core:fmt"
import "core:os"
import "core:strings"
import daemon "odin_test:daemon"
import vcs "odin_test:lib/vcs"

mock_fig_detect :: proc(repo_path: string) -> vcs.Vcs_Detect_Result {
	return vcs.Vcs_Detect_Result{
		kind = .Fig,
		repo_root = repo_path,
		base_ref = "p4head",
		ok = true,
		message = "mock fig detected",
	}
}

mock_fig_workspace_add :: proc(repo: string, name: string, base_ref: string, worktree_root: string) -> (vcs.Vcs_Workspace_Handle, bool, string) {
	return vcs.Vcs_Workspace_Handle{
		path = "/tmp/mock_workspace",
		branch_or_change = "mock_change",
		base_ref = base_ref,
		kind = .Fig,
	}, true, "mock workspace created"
}

// We also need to mock workspace_remove because task_service_maybe_provision_workspace might call it if clean up is needed,
// but more importantly, we should clean up after ourselves.
mock_fig_workspace_remove :: proc(handle: vcs.Vcs_Workspace_Handle, force: bool) -> (bool, string) {
	return true, "mock workspace removed"
}

test_fig_google3_detection :: proc() {
	fmt.println("=== Running test_fig_google3_detection ===")

	// Initialize DB for the test
	db_dir := "/tmp/ham-test-vcs-db"
	_ = os.remove_all(db_dir)
	db_init_ok := daemon.vcs_db_init(db_dir)
	check(db_init_ok, "failed to initialize vcs db")

	// Save original backend procedures to restore them later
	orig_detect := vcs.fig_backend.detect
	orig_add := vcs.fig_backend.workspace_add
	orig_remove := vcs.fig_backend.workspace_remove

	// Apply mocks
	vcs.fig_backend.detect = mock_fig_detect
	vcs.fig_backend.workspace_add = mock_fig_workspace_add
	vcs.fig_backend.workspace_remove = mock_fig_workspace_remove

	defer {
		// Restore original procedures
		vcs.fig_backend.detect = orig_detect
		vcs.fig_backend.workspace_add = orig_add
		vcs.fig_backend.workspace_remove = orig_remove
		_ = os.remove_all(db_dir)
	}

	// Test cases mapping config directory examples to Fig
	test_paths := []string{
		"google3/configs/production/canary_analysis/teloneum-processor/",
		"google3/configs/slo/alert/teloneum-processor/",
		"google3/configs/slo/definitions/teloneum-processor/",
		"google3/production/security/bcid/urfin/teloneum-processor/",
		"google3/configs/security/ganpati/onpiper/prod/server-platform/teloneum-processor/",
		"/some/absolute/path/google3/configs/production/canary_analysis/teloneum-processor/",
	}

	for path in test_paths {
		fmt.printf("Testing path: %s\n", path)
		
		// Setup dummy project
		proj_id := "test-google3-project"
		pidx := daemon.project_index(proj_id)
		if pidx >= 0 {
			// Clean up if exists (shouldn't exist but just in case)
			daemon.project_record_count -= 1
		}
		
		idx := daemon.project_record_count
		daemon.project_record_count += 1
		
		proj := &daemon.project_records[idx]
		proj.project_id = proj_id
		proj.name = "Test Google3 Project"
		proj.anchor_count = 2
		proj.anchors[0] = daemon.Project_Anchor{type = "directory", value = path}
		proj.anchors[1] = daemon.Project_Anchor{type = "vcs_kind", value = "auto"}

		// Call maybe_provision_workspace
		rec, ok, msg := daemon.task_service_maybe_provision_workspace(proj_id, "test-chain", "test-team", "Test Title")
		
		check(ok, fmt.tprintf("maybe_provision_workspace failed: %s", msg))
		check(rec.vcs_kind == "fig", fmt.tprintf("expected vcs_kind 'fig', got '%s'", rec.vcs_kind))
		check(rec.path == "/tmp/mock_workspace", fmt.tprintf("expected path '/tmp/mock_workspace', got '%s'", rec.path))
		
		// Clean up project record for next iteration
		daemon.project_record_count -= 1
		
		// Clean up workspace from DB
		daemon.vcs_db_delete_workspace("test-chain")
	}

	// Test a non-google3 path to ensure it doesn't default to Fig if it's not fig
	// We need to mock Git detect to return true to allow it to succeed as Git, or false to fail.
	// Actually, if it's not google3, it falls back to Jj detect, then Fig detect, then Git.
	// If we want to ensure it doesn't choose Fig, we can make Fig detect return false for non-google3 path.
	// Our mock_fig_detect currently always returns ok=true.
	// Let's modify the mock to only return ok=true if it contains google3, OR we can just use a different mock.
	
	fmt.println("Testing non-google3 path...")
	
	// Temporary mock that returns false for fig detect
	vcs.fig_backend.detect = proc(repo_path: string) -> vcs.Vcs_Detect_Result {
		return vcs.Vcs_Detect_Result{kind = .Fig, ok = false, message = "not fig"}
	}
	// Mock Jj detect to also return false
	orig_jj_detect := vcs.jj_backend.detect
	vcs.jj_backend.detect = proc(repo_path: string) -> vcs.Vcs_Detect_Result {
		return vcs.Vcs_Detect_Result{kind = .Jj, ok = false, message = "not jj"}
	}
	defer {
		vcs.jj_backend.detect = orig_jj_detect
	}
	
	// Mock Git detect to return true
	orig_git_detect := vcs.git_backend.detect
	vcs.git_backend.detect = proc(repo_path: string) -> vcs.Vcs_Detect_Result {
		return vcs.Vcs_Detect_Result{kind = .Git, repo_root = repo_path, base_ref = "main", ok = true, message = "mock git detected"}
	}
	orig_git_add := vcs.git_backend.workspace_add
	vcs.git_backend.workspace_add = proc(repo, name, base_ref, worktree_root: string) -> (vcs.Vcs_Workspace_Handle, bool, string) {
		return vcs.Vcs_Workspace_Handle{path = "/tmp/mock_git_workspace", branch_or_change = "mock_branch", base_ref = base_ref, kind = .Git}, true, "ok"
	}
	defer {
		vcs.git_backend.detect = orig_git_detect
		vcs.git_backend.workspace_add = orig_git_add
	}

	proj_id := "test-git-project"
	idx := daemon.project_record_count
	daemon.project_record_count += 1
	
	proj := &daemon.project_records[idx]
	proj.project_id = proj_id
	proj.name = "Test Git Project"
	proj.anchor_count = 2
	proj.anchors[0] = daemon.Project_Anchor{type = "directory", value = "/some/git/repo"}
	proj.anchors[1] = daemon.Project_Anchor{type = "vcs_kind", value = "auto"}

	rec, ok, msg := daemon.task_service_maybe_provision_workspace(proj_id, "test-chain-git", "test-team", "Test Title")
	check(ok, fmt.tprintf("maybe_provision_workspace failed for git: %s", msg))
	check(rec.vcs_kind == "git", fmt.tprintf("expected vcs_kind 'git', got '%s'", rec.vcs_kind))
	
	daemon.project_record_count -= 1
	daemon.vcs_db_delete_workspace("test-chain-git")

	fmt.println("[-] test_fig_google3_detection passed")
}
