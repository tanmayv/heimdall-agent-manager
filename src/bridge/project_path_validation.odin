package main

import "core:os"
import "core:strings"

Bridge_Project_Path_Validation_Result :: struct {
	ok: bool,
	error_code: string,
	message: string,
}

bridge_validation_command_ids: [128]string
bridge_validation_command_results: [128]string
bridge_validation_command_count: int

bridge_validation_command_cached :: proc(command_id: string) -> (string, bool) {
	if command_id == "" do return "", false
	for i in 0..<bridge_validation_command_count { if bridge_validation_command_ids[i] == command_id do return bridge_validation_command_results[i], true }
	return "", false
}

bridge_validation_command_store :: proc(command_id, result_json: string) {
	if command_id == "" do return
	for i in 0..<bridge_validation_command_count { if bridge_validation_command_ids[i] == command_id { bridge_validation_command_results[i] = result_json; return } }
	if bridge_validation_command_count < len(bridge_validation_command_ids) {
		bridge_validation_command_ids[bridge_validation_command_count] = command_id
		bridge_validation_command_results[bridge_validation_command_count] = result_json
		bridge_validation_command_count += 1
	}
}

bridge_validate_project_path_local :: proc(path, vcs_kind, repo_url: string) -> Bridge_Project_Path_Validation_Result {
	_ = repo_url // remote URL matching is best-effort/post-credential; keep room in result details.
	if !os.exists(path) do return Bridge_Project_Path_Validation_Result{ok = false, error_code = "path_not_found", message = "Path does not exist"}
	if !os.is_dir(path) do return Bridge_Project_Path_Validation_Result{ok = false, error_code = "path_not_directory", message = "Path is not a directory"}
	if vcs_kind == "git" && !bridge_path_has_git_root(path) do return Bridge_Project_Path_Validation_Result{ok = false, error_code = "git_root_not_found", message = "Git root was not found"}
	return Bridge_Project_Path_Validation_Result{ok = true}
}

bridge_path_has_git_root :: proc(path: string) -> bool {
	cursor := path
	for {
		git_dir := strings.concatenate({cursor, "/.git"})
		if os.exists(git_dir) { delete(git_dir); return true }
		delete(git_dir)
		idx := strings.last_index_byte(cursor, '/')
		if idx <= 0 do break
		cursor = cursor[:idx]
	}
	return os.exists("/.git")
}
