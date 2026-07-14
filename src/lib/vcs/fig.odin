package vcs

import "core:fmt"
import "core:os"
import "core:strings"

fig_detect :: proc(repo_path: string) -> Vcs_Detect_Result {
	return Vcs_Detect_Result{kind = .Fig, ok = false, message = "fig detect not implemented"}
}

fig_workspace_add :: proc(repo, name, base_ref, worktree_root: string) -> (Vcs_Workspace_Handle, bool, string) {
	return Vcs_Workspace_Handle{}, false, "fig workspace_add not implemented"
}

fig_workspace_remove :: proc(handle: Vcs_Workspace_Handle, force: bool) -> (bool, string) {
	return false, "fig workspace_remove not implemented"
}

fig_workspace_status :: proc(handle: Vcs_Workspace_Handle) -> (Vcs_Status, bool, string) {
	return Vcs_Status{}, false, "fig workspace_status not implemented"
}

fig_workspace_diff :: proc(handle: Vcs_Workspace_Handle, path: string) -> (string, bool, string) {
	return "", false, "fig workspace_diff not implemented"
}

fig_workspace_pull_base :: proc(handle: Vcs_Workspace_Handle) -> (bool, string) {
	return false, "fig workspace_pull_base not implemented"
}

fig_merge_preview :: proc(handle: Vcs_Workspace_Handle, target: string) -> (Vcs_Merge_Preview, bool, string) {
	return Vcs_Merge_Preview{}, false, "fig merge_preview not implemented"
}

fig_merge_execute :: proc(handle: Vcs_Workspace_Handle, target: string) -> (bool, string) {
	return false, "fig merge_execute not implemented"
}
