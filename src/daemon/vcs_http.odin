package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import vcs "odin_test:lib/vcs"

WORKSPACE_SOURCE_CHAIN :: "chain_workspace"
WORKSPACE_SOURCE_CHAIN_LABEL :: "Dedicated chain worktree"
WORKSPACE_SOURCE_REPO :: "project_repo"
WORKSPACE_SOURCE_REPO_LABEL :: "Project repo fallback"

workspace_setup_value :: proc(description, label: string) -> string {
	prefix := fmt.tprintf("- %s: ", label)
	lines := strings.split(description, "\n")
	defer delete(lines)
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, prefix) do return strings.clone(strings.trim_space(trimmed[len(prefix):]))
	}
	return ""
}

workspace_setup_path_and_base_ref :: proc(chain_id: string) -> (string, string, bool) {
	tasks := store_tasks_in_chain(chain_id)
	defer delete(tasks)
	for task in tasks {
		if task.title != "Prepare chain workspace" do continue
		path := workspace_setup_value(task.description, "Worktree path")
		base_ref := workspace_setup_value(task.description, "Base ref")
		if path != "" do return path, base_ref, true
	}
	return "", "", false
}

workspace_root_for_project :: proc(project_id: string) -> string {
	root := fmt.tprintf("/tmp/heimdall-worktrees/%s", project_id)
	if idx := project_index(project_id); idx >= 0 {
		root = project_anchor_value(project_records[idx], "worktree_root", root)
	}
	return strings.clone(strings.trim_right(root, "/"))
}

workspace_path_allowed_for_project :: proc(project_id, path: string) -> bool {
	clean_path := strings.trim_right(strings.trim_space(path), "/")
	if clean_path == "" do return false
	root := workspace_root_for_project(project_id)
	if root == "" do return false
	return clean_path == root || strings.has_prefix(clean_path, fmt.tprintf("%s/", root))
}

workspace_detect_kind_at_path :: proc(project_id, path: string) -> (vcs.Vcs_Kind, vcs.Vcs_Detect_Result, bool) {
	kind := "auto"
	if idx := project_index(project_id); idx >= 0 {
		kind = project_anchor_value(project_records[idx], "vcs_kind", kind)
	}
	if kind == "none" do return .None, vcs.Vcs_Detect_Result{}, false
	if kind == "jj" {
		detected := vcs.vcs_backend_for(.Jj).detect(path)
		return .Jj, detected, detected.ok
	}
	if kind == "fig" {
		detected := vcs.vcs_backend_for(.Fig).detect(path)
		return .Fig, detected, detected.ok
	}
	jj_detected := vcs.vcs_backend_for(.Jj).detect(path)
	if jj_detected.ok do return .Jj, jj_detected, true
	fig_detected := vcs.vcs_backend_for(.Fig).detect(path)
	if fig_detected.ok do return .Fig, fig_detected, true
	git_detected := vcs.vcs_backend_for(.Git).detect(path)
	if git_detected.ok do return .Git, git_detected, true
	return .None, vcs.Vcs_Detect_Result{}, false
}

workspace_vcs_kind_string :: proc(kind: vcs.Vcs_Kind) -> string {
	switch kind {
	case .Git: return "git"
	case .Jj: return "jj"
	case .Fig: return "fig"
	case .None: return "none"
	}
	return "none"
}

workspace_record_chain_workspace_id :: proc(chain_id, workspace_id: string) {
	chain, found := store_get_chain(chain_id)
	if !found do return
	if chain.vcs_workspace_id == workspace_id do return
	chain.vcs_workspace_id = strings.clone(workspace_id)
	_ = store_upsert_chain(chain)
	if task_db_ready do _ = task_db_save_chain(chain)
}

workspace_discover_chain_workspace :: proc(chain: Task_Chain_State) -> (Vcs_Workspace_Record, bool) {
	if chain.project_id == "" do return Vcs_Workspace_Record{}, false
	path, setup_base_ref, _ := workspace_setup_path_and_base_ref(chain.chain_id)
	if strings.trim_space(path) == "" {
		path = task_service_vcs_workspace_path(chain.project_id, chain.chain_id, chain.title)
	}
	path = strings.trim_space(path)
	if !workspace_path_allowed_for_project(chain.project_id, path) do return Vcs_Workspace_Record{}, false
	if !os.is_dir(path) do return Vcs_Workspace_Record{}, false
	kind, detected, ok := workspace_detect_kind_at_path(chain.project_id, path)
	if !ok do return Vcs_Workspace_Record{}, false
	base_ref := strings.trim_space(setup_base_ref)
	if base_ref == "" do base_ref = task_service_project_base_ref(chain.project_id, detected.base_ref)
	branch_or_change := strings.trim_space(detected.base_ref)
	if branch_or_change == "" do branch_or_change = base_ref
	workspace_id := chain.vcs_workspace_id
	if workspace_id == "" do workspace_id = fmt.tprintf("ws_%s", chain.chain_id)
	now := router_now_unix_ms()
	rec := Vcs_Workspace_Record{workspace_id=workspace_id, chain_id=chain.chain_id, project_id=chain.project_id, vcs_kind=workspace_vcs_kind_string(kind), path=path, branch_or_change=branch_or_change, base_ref=base_ref, status="discovered", created_unix_ms=now, updated_unix_ms=now}
	if !vcs_db_insert_workspace(rec) do return Vcs_Workspace_Record{}, false
	workspace_record_chain_workspace_id(chain.chain_id, workspace_id)
	return rec, true
}

workspace_resolve_chain_workspace :: proc(chain_id: string) -> (Vcs_Workspace_Record, bool) {
	if rec, found := vcs_db_workspace_for_chain(chain_id); found {
		workspace_record_chain_workspace_id(chain_id, rec.workspace_id)
		return rec, true
	}
	chain, found := store_get_chain(chain_id)
	if !found do return Vcs_Workspace_Record{}, false
	return workspace_discover_chain_workspace(chain)
}

handle_workspace_request :: proc(client: net.TCP_Socket, request: string) -> bool {
	method, target := http_method_target(request)
	path := path_without_query(target)
	if !strings.has_prefix(path, "/chains/") do return false
	suffix := path[len("/chains/"):]
	slash := strings.index_byte(suffix, '/')
	if slash < 0 do return false
	chain_id := suffix[:slash]
	action := suffix[slash:]
	if method == "GET" && action == "/workspace" {
		if !workspace_query_auth(client, target) do return true
		write_response(client, 200, "OK", workspace_response_json(chain_id, true)); return true
	}
	if method == "GET" && action == "/workspace/diff" {
		if !workspace_query_auth(client, target) do return true
		handle_workspace_diff_for_chain(client, chain_id, query_value(target, "file")); return true
	}
	body := request_body(request)
	if method == "POST" && action == "/workspace/refresh" { handle_workspace_refresh_for_chain(client, body, chain_id); return true }
	if method == "POST" && action == "/workspace/pull-base" { handle_workspace_pull_base_for_chain(client, body, chain_id); return true }
	if method == "GET" && action == "/workspace/merge-preview" {
		if !workspace_query_auth(client, target) do return true
		handle_workspace_merge_preview_for_chain(client, "", chain_id, query_value(target, "target")); return true
	}
	if method == "POST" && action == "/workspace/merge" { handle_workspace_merge_for_chain(client, body, chain_id); return true }
	if method == "POST" && action == "/workspace/archive" { handle_workspace_archive_for_chain(client, body, chain_id); return true }
	return false
}

workspace_query_auth :: proc(client: net.TCP_Socket, target: string) -> bool {
	token := query_value(target, "agent_token")
	body := strings.builder_make()
	strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token); strings.write_string(&body, `"}`)
	_, ok := task_author_from_body(client, strings.to_string(body))
	return ok
}

handle_workspace_show :: proc(client: net.TCP_Socket, body: string) {
	_, ok := task_author_from_body(client, body); if !ok do return
	chain_id := extract_json_string(body, "chain_id", extract_json_string(body, "chain", ""))
	write_response(client, 200, "OK", workspace_response_json(chain_id, true))
}

handle_workspace_diff :: proc(client: net.TCP_Socket, body: string) {
	_, ok := task_author_from_body(client, body); if !ok do return
	chain_id := extract_json_string(body, "chain_id", extract_json_string(body, "chain", ""))
	path := extract_json_string(body, "file", extract_json_string(body, "path", ""))
	handle_workspace_diff_for_chain(client, chain_id, path)
}

handle_workspace_diff_for_chain :: proc(client: net.TCP_Socket, chain_id, path: string) {
	if rec, found := workspace_resolve_chain_workspace(chain_id); found {
		backend := vcs.vcs_backend_for(vcs_handle_from_record(rec).kind)
		diff, diff_ok, msg := backend.workspace_diff(vcs_handle_from_record(rec), path)
		if !diff_ok { write_response(client, 500, "Internal Server Error", workspace_error_json(msg)); return }
		b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"diff":"`); json_write_string(&b, diff); strings.write_string(&b, `"}`)
		write_response(client, 200, "OK", strings.to_string(b)); return
	}
	repo, repo_ok, repo_msg := task_chain_project_git_repo(chain_id)
	if !repo_ok { write_response(client, 404, "Not Found", workspace_error_json(repo_msg)); return }
	chain, chain_ok := store_get_chain(chain_id)
	if !chain_ok { write_response(client, 404, "Not Found", workspace_error_json("chain not found")); return }
	result, diff_ok, msg := vcs.vcs_backend_for(.Git).repo_diff(repo, path, chain.diff_base_sha)
	if !diff_ok { write_response(client, 500, "Internal Server Error", workspace_error_json(msg)); return }
	write_response(client, 200, "OK", workspace_diff_json(result.diff, result.mode, result.label, result.base_sha))
}

handle_workspace_refresh :: proc(client: net.TCP_Socket, body: string) { _, ok := task_author_from_body(client, body); if !ok do return; chain_id := extract_json_string(body, "chain_id", extract_json_string(body, "chain", "")); write_response(client, 200, "OK", workspace_response_json(chain_id, true)) }
handle_workspace_refresh_for_chain :: proc(client: net.TCP_Socket, body, chain_id: string) { _, ok := task_author_from_body(client, body); if !ok do return; write_response(client, 200, "OK", workspace_response_json(chain_id, true)) }

handle_workspace_pull_base :: proc(client: net.TCP_Socket, body: string) {
	_, is_user, ok := task_author_and_type_from_body(client, body); if !ok do return
	if !is_user { write_response(client, 403, "Forbidden", `{"ok":false,"message":"workspace pull requires user token"}`); return }
	chain_id := extract_json_string(body, "chain_id", extract_json_string(body, "chain", ""))
	handle_workspace_pull_base_for_chain(client, body, chain_id)
}

handle_workspace_pull_base_for_chain :: proc(client: net.TCP_Socket, body, chain_id: string) {
	_, is_user, ok := task_author_and_type_from_body(client, body); if !ok do return
	if !is_user { write_response(client, 403, "Forbidden", `{"ok":false,"message":"workspace pull requires user token"}`); return }
	rec, found := workspace_resolve_chain_workspace(chain_id)
	if !found { write_response(client, 404, "Not Found", `{"ok":false,"message":"workspace not found"}`); return }
	backend := vcs.vcs_backend_for(vcs_handle_from_record(rec).kind)
	ok2, msg := backend.workspace_pull_base(vcs_handle_from_record(rec))
	if !ok2 { write_response(client, 500, "Internal Server Error", workspace_error_json(msg)); return }
	write_response(client, 200, "OK", `{"ok":true}`)
}

handle_workspace_merge_preview :: proc(client: net.TCP_Socket, body: string) {
	_, ok := task_author_from_body(client, body); if !ok do return
	chain_id := extract_json_string(body, "chain_id", extract_json_string(body, "chain", ""))
	target := extract_json_string(body, "target", "")
	handle_workspace_merge_preview_for_chain(client, body, chain_id, target)
}

handle_workspace_merge_preview_for_chain :: proc(client: net.TCP_Socket, body, chain_id, target: string) {
	if body != "" { _, ok := task_author_from_body(client, body); if !ok do return }
	rec, found := workspace_resolve_chain_workspace(chain_id)
	if !found { write_response(client, 404, "Not Found", `{"ok":false,"message":"workspace not found"}`); return }
	backend := vcs.vcs_backend_for(vcs_handle_from_record(rec).kind)
	preview, ok2, msg := backend.merge_preview(vcs_handle_from_record(rec), target)
	if !ok2 { write_response(client, 500, "Internal Server Error", workspace_error_json(msg)); return }
	write_response(client, 200, "OK", workspace_merge_preview_json(preview))
}

handle_workspace_merge :: proc(client: net.TCP_Socket, body: string) {
	_, is_user, ok := task_author_and_type_from_body(client, body); if !ok do return
	if !is_user { write_response(client, 403, "Forbidden", `{"ok":false,"message":"workspace merge requires user token"}`); return }
	chain_id := extract_json_string(body, "chain_id", extract_json_string(body, "chain", "")); handle_workspace_merge_for_chain(client, body, chain_id)
}

handle_workspace_merge_for_chain :: proc(client: net.TCP_Socket, body, chain_id: string) {
	user_id, is_user, ok := task_author_and_type_from_body(client, body); if !ok do return
	if !is_user { write_response(client, 403, "Forbidden", `{"ok":false,"message":"workspace merge requires user token"}`); return }
	
	rec, found := workspace_resolve_chain_workspace(chain_id); if !found { write_response(client, 404, "Not Found", `{"ok":false,"message":"workspace not found"}`); return }
	
	mode := extract_json_string(body, "mode", "direct")
	instructions := extract_json_string(body, "instructions", "")
	target := extract_json_string(body, "target", "")

	if mode == "chain" {
		original_title := "Untitled Chain"
		if chain, found_chain := store_get_chain(chain_id); found_chain {
			original_title = chain.title
		}
		
		merge_chain_title := fmt.tprintf("Merge: %s", original_title)
		
		create_cmd := Task_Chain_Create_Command{
			project_id = rec.project_id,
			title = merge_chain_title,
			description = instructions,
			wants_vcs = true,
			author_agent_instance_id = user_id,
		}
		
		create_res := task_service_create_chain(create_cmd)
		if !create_res.ok {
			write_response(client, create_res.status_code, "Error", create_res.message)
			return
		}
		
		_ = vcs_db_update_status(chain_id, "merging")
		merge_lifecycle_finalize_decision(chain_id)
		
		write_response(client, 200, "OK", create_res.message)
		return
	}

	// Default/direct mode
	backend := vcs.vcs_backend_for(vcs_handle_from_record(rec).kind); ok2, msg := backend.merge_execute(vcs_handle_from_record(rec), target)
	if !ok2 { write_response(client, 409, "Conflict", workspace_error_json(msg)); return }
	
	if !rec.keep_on_archive {
		_, _ = backend.workspace_remove(vcs_handle_from_record(rec), true)
	}
	_ = vcs_db_update_status(chain_id, "merged")
	merge_lifecycle_finalize_decision(chain_id)
	write_response(client, 200, "OK", `{"ok":true,"message":"merged locally; worktree removed"}`)
}

handle_workspace_archive :: proc(client: net.TCP_Socket, body: string) {
	_, is_user, ok := task_author_and_type_from_body(client, body); if !ok do return
	if !is_user { write_response(client, 403, "Forbidden", `{"ok":false,"message":"workspace archive requires user token"}`); return }
	chain_id := extract_json_string(body, "chain_id", extract_json_string(body, "chain", "")); handle_workspace_archive_for_chain(client, body, chain_id)
}

handle_workspace_archive_for_chain :: proc(client: net.TCP_Socket, body, chain_id: string) {
	_, is_user, ok := task_author_and_type_from_body(client, body); if !ok do return
	if !is_user { write_response(client, 403, "Forbidden", `{"ok":false,"message":"workspace archive requires user token"}`); return }
	force := extract_json_bool(body, "force", false)
	rec, found := workspace_resolve_chain_workspace(chain_id); if !found { write_response(client, 404, "Not Found", `{"ok":false,"message":"workspace not found"}`); return }
	keep := extract_json_bool(body, "keep", false)
	handle := vcs_handle_from_record(rec)
	backend := vcs.vcs_backend_for(handle.kind)
	if keep {
		ok2, msg := vcs.vcs_write_kept_marker(handle, chain_id, rec.workspace_id, "operator keep-worktree archive decision")
		if !ok2 { write_response(client, 500, "Internal Server Error", workspace_error_json(msg)); return }
	} else {
		ok2, msg := backend.workspace_remove(handle, force)
		if !ok2 { write_response(client, 500, "Internal Server Error", workspace_error_json(msg)); return }
	}
	// Task 16: keep/abandon decision recorded → archive team (§3.5).
	_ = vcs_db_update_status(chain_id, "kept" if keep else "archived")
	merge_lifecycle_finalize_decision(chain_id)
	write_response(client, 200, "OK", `{"ok":true}`)
}

workspace_response_json :: proc(chain_id: string, include_status: bool) -> string {
	if rec, found := workspace_resolve_chain_workspace(chain_id); found {
		status := vcs.Vcs_Status{}
		if include_status { backend := vcs.vcs_backend_for(vcs_handle_from_record(rec).kind); s, ok, _ := backend.workspace_status(vcs_handle_from_record(rec)); if ok do status = s }
		b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"workspace":`); vcs_write_workspace_json(&b, rec, status, WORKSPACE_SOURCE_CHAIN, WORKSPACE_SOURCE_CHAIN_LABEL); strings.write_string(&b, `}`); return strings.to_string(b)
	}
	repo, repo_ok, repo_msg := task_chain_project_git_repo(chain_id)
	if !repo_ok {
		b := strings.builder_make(); strings.write_string(&b, `{"ok":false,"message":"`); json_write_string(&b, repo_msg); strings.write_string(&b, `","repo_diff_supported":false}`); return strings.to_string(b)
	}
	chain, chain_ok := store_get_chain(chain_id)
	if !chain_ok do return `{"ok":false,"message":"chain not found","repo_diff_supported":false}`
	status := vcs.Vcs_Status{}
	if include_status { s, ok, _ := vcs.vcs_backend_for(.Git).repo_status(repo, chain.diff_base_sha); if ok do status = s }
	return workspace_repo_response_json(chain_id, repo, chain.project_id, chain.diff_base_sha, status)
}

workspace_diff_json :: proc(diff, mode, label, base_sha: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"diff":"`); json_write_string(&b, diff)
	strings.write_string(&b, `","diff_mode":"`); json_write_string(&b, mode)
	strings.write_string(&b, `","diff_label":"`); json_write_string(&b, label)
	strings.write_string(&b, `","diff_base_sha":"`); json_write_string(&b, base_sha)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

workspace_repo_response_json :: proc(chain_id, repo, project_id, diff_base_sha: string, status: vcs.Vcs_Status) -> string {
	mode := "repo_uncommitted"
	label := "Uncommitted changes"
	if strings.trim_space(diff_base_sha) != "" {
		mode = "repo_baseline"
		label = "Changes since chain started (whole repo)"
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"workspace":{"workspace_id":"","chain_id":"`); json_write_string(&b, chain_id)
	strings.write_string(&b, `","project_id":"`); json_write_string(&b, project_id)
	strings.write_string(&b, `","vcs_kind":"git","path":"`); json_write_string(&b, repo)
	strings.write_string(&b, `","branch_or_change":"repo-level","base_ref":"`); json_write_string(&b, diff_base_sha)
	strings.write_string(&b, `","status":"repo","source_kind":"`); json_write_string(&b, WORKSPACE_SOURCE_REPO)
	strings.write_string(&b, `","source_label":"`); json_write_string(&b, WORKSPACE_SOURCE_REPO_LABEL)
	strings.write_string(&b, `","summary_line":"`); json_write_string(&b, status.summary_line)
	strings.write_string(&b, `","ahead_commits":0,"behind_commits":0,"is_conflicted":`); strings.write_string(&b, "true" if status.is_conflicted else "false")
	strings.write_string(&b, `,"repo_diff_supported":true,"diff_mode":"`); json_write_string(&b, mode)
	strings.write_string(&b, `","diff_label":"`); json_write_string(&b, label)
	strings.write_string(&b, `","diff_base_sha":"`); json_write_string(&b, diff_base_sha)
	strings.write_string(&b, `","files":[`)
	for i in 0..<len(status.files) {
		if i > 0 do strings.write_string(&b, `,`)
		f := status.files[i]
		strings.write_string(&b, `{"path":"`); json_write_string(&b, f.path)
		strings.write_string(&b, `","status":"`); json_write_string(&b, f.status)
		strings.write_string(&b, `","adds":`); strings.write_string(&b, fmt.tprintf("%d", f.adds))
		strings.write_string(&b, `,"dels":`); strings.write_string(&b, fmt.tprintf("%d", f.dels))
		strings.write_string(&b, `}`)
	}
	strings.write_string(&b, `]}}`)
	return strings.to_string(b)
}

workspace_merge_preview_json :: proc(p: vcs.Vcs_Merge_Preview) -> string {
	b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"preview":{"can_fast_forward":`); strings.write_string(&b, "true" if p.can_fast_forward else "false"); strings.write_string(&b, `,"summary":"`); json_write_string(&b, p.summary); strings.write_string(&b, `","conflicts":[`)
	for i in 0..<len(p.conflicts) { if i>0 do strings.write_string(&b, `,`); strings.write_string(&b, `"`); json_write_string(&b, p.conflicts[i]); strings.write_string(&b, `"`) }
	strings.write_string(&b, `],"commands":[`)
	for i in 0..<len(p.commands) { if i>0 do strings.write_string(&b, `,`); strings.write_string(&b, `"`); json_write_string(&b, p.commands[i]); strings.write_string(&b, `"`) }
	strings.write_string(&b, `]}}`); return strings.to_string(b)
}

workspace_error_json :: proc(msg: string) -> string {
	b := strings.builder_make(); strings.write_string(&b, `{"ok":false,"message":"`); json_write_string(&b, msg); strings.write_string(&b, `"}`); return strings.to_string(b)
}
