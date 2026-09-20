package main

// VCS command handlers (Hub -> Bridge) for the four vcs_* commands, plus their
// JSON serialization. Mirrors bridge_fs_handle_command in fs_management.odin: each
// command is idempotent (results cached by command_id) and replies over the
// runtime WS with the same chunk-safe bridge_hub_send envelope.
//
// Commands:
//   vcs_capabilities  params: {path}                      -> provider + supports_staging
//   vcs_status        params: {path}                      -> branch/remote/ahead/behind/clean
//   vcs_files         params: {path, cursor?, limit?}     -> paginated changed files
//   vcs_diff          params: {path, file, cursor?, limit?}-> paginated diff hunks
//
// On a path with no recognized VCS, every command returns {ok:false,
// error:{code:"no_vcs"}}. The provider is resolved per request via
// vcs_detect_provider; the caller-supplied path is home-expanded (so "~/proj"
// resolves) but NOT otherwise sandboxed — the task scopes these commands to plain
// detection. (Adding bridge_fs_root containment here would be a straightforward
// follow-up if the hub ever forwards untrusted paths.)

import "core:fmt"
import "core:strings"
import ws "odin_test:lib/ws"

VCS_FILES_DEFAULT_LIMIT :: 100
VCS_FILES_MAX_LIMIT :: 500
VCS_DIFF_DEFAULT_LIMIT :: 50
VCS_DIFF_MAX_LIMIT :: 200
VCS_LOG_DEFAULT_LIMIT :: 100
VCS_LOG_MAX_LIMIT :: 500

// bridge_vcs_handle_command dispatches the vcs_* command types over the runtime
// WS. Returns true if `type` was a vcs command (handled), false otherwise. Results
// are cached by command_id for idempotent replay, matching the fs_* handlers.
bridge_vcs_handle_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	switch type {
	case "vcs_capabilities":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_capabilities_json(command_id, text)
		bridge_runtime_cache_command(command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_status":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_status_json(command_id, text)
		bridge_runtime_cache_command(command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_files":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_files_json(command_id, text)
		bridge_runtime_cache_command(command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_diff":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_diff_json(command_id, text)
		bridge_runtime_cache_command(command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	// --- write commands: mutations are NOT idempotent, so they are never cached. ---
	case "vcs_stage":
		command_id := extract_json_string(text, "command_id", "")
		_ = bridge_hub_send(conn, bridge_vcs_stage_json(command_id, text))
		return true
	case "vcs_unstage":
		command_id := extract_json_string(text, "command_id", "")
		_ = bridge_hub_send(conn, bridge_vcs_unstage_json(command_id, text))
		return true
	case "vcs_revert":
		command_id := extract_json_string(text, "command_id", "")
		_ = bridge_hub_send(conn, bridge_vcs_revert_json(command_id, text))
		return true
	case "vcs_save_file":
		command_id := extract_json_string(text, "command_id", "")
		_ = bridge_hub_send(conn, bridge_vcs_save_json(command_id, text))
		return true
	// --- read-only commands: cached by command_id like the other read handlers. ---
	case "vcs_log":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_log_json(command_id, text)
		bridge_runtime_cache_command(command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_commit_diff":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_commit_diff_json(command_id, text)
		bridge_runtime_cache_command(command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_workspaces":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_workspaces_json(command_id, text)
		bridge_runtime_cache_command(command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	}
	return false
}

// vcs_request_path extracts and home-expands the "root" param.
vcs_request_path :: proc(text: string) -> string {
	raw := strings.trim_space(extract_json_string(text, "root", ""))
	if raw == "" do return ""
	return bridge_expand_home(raw)
}

// vcs_clamp_limit mirrors the pagination clamp so the response can echo the
// effective limit that was actually applied.
vcs_clamp_limit :: proc(limit, default_limit, max_limit: int) -> int {
	l := limit
	if l <= 0 do l = default_limit
	if l > max_limit do l = max_limit
	return l
}

// --- vcs_capabilities ----------------------------------------------------

bridge_vcs_capabilities_json :: proc(command_id, text: string) -> string {
	path := vcs_request_path(text)
	provider, ok := vcs_detect_provider(path)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"vcs_capabilities_result\",\"command_id\":\""); json_write_string(&b, command_id)
	if !ok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\"\",\"supports_staging\":false,\"staging_model\":\"\",\"commit_model\":\"\",\"supported_actions\":[]")
		vcs_write_error(&b, "no_vcs", "No supported version control system found at path")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	caps := provider.capabilities(path)
	strings.write_string(&b, "\",\"ok\":true,\"provider\":\""); json_write_string(&b, caps.provider)
	strings.write_string(&b, "\",\"supports_staging\":"); strings.write_string(&b, "true" if caps.supports_staging else "false")
	strings.write_string(&b, ",\"staging_model\":\""); json_write_string(&b, caps.staging_model)
	strings.write_string(&b, "\",\"commit_model\":\""); json_write_string(&b, caps.commit_model)
	strings.write_string(&b, "\",\"supported_actions\":[")
	for a, i in caps.supported_actions {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"'); json_write_string(&b, a); strings.write_byte(&b, '"')
	}
	strings.write_string(&b, "]")
	vcs_write_error(&b, "", "")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// --- vcs_status ----------------------------------------------------------

bridge_vcs_status_json :: proc(command_id, text: string) -> string {
	path := vcs_request_path(text)
	provider, ok := vcs_detect_provider(path)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"vcs_status_result\",\"command_id\":\""); json_write_string(&b, command_id)
	if !ok {
		strings.write_string(&b, "\",\"ok\":false")
		vcs_write_error(&b, "no_vcs", "No supported version control system found at path")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	st, sok := provider.status(path)
	if !sok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\"")
		vcs_write_error(&b, "status_failed", "Could not read VCS status")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	strings.write_string(&b, "\",\"ok\":true,\"provider\":\""); json_write_string(&b, st.provider)
	strings.write_string(&b, "\",\"branch\":\""); json_write_string(&b, st.branch)
	strings.write_string(&b, "\",\"remote\":\""); json_write_string(&b, st.remote)
	strings.write_string(&b, "\",\"ahead\":"); strings.write_string(&b, fmt.tprintf("%d", st.ahead))
	strings.write_string(&b, ",\"behind\":"); strings.write_string(&b, fmt.tprintf("%d", st.behind))
	strings.write_string(&b, ",\"is_clean\":"); strings.write_string(&b, "true" if st.is_clean else "false")
	vcs_write_error(&b, "", "")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// --- vcs_files -----------------------------------------------------------

bridge_vcs_files_json :: proc(command_id, text: string) -> string {
	path := vcs_request_path(text)
	cursor := extract_json_string(text, "cursor", "")
	limit := extract_json_int(text, "limit", VCS_FILES_DEFAULT_LIMIT)
	eff_limit := vcs_clamp_limit(limit, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	provider, ok := vcs_detect_provider(path)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"vcs_files_result\",\"command_id\":\""); json_write_string(&b, command_id)
	if !ok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\"\",\"files\":[],\"cursor\":\""); json_write_string(&b, cursor)
		strings.write_string(&b, "\",\"limit\":"); strings.write_string(&b, fmt.tprintf("%d", eff_limit))
		strings.write_string(&b, ",\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "no_vcs", "No supported version control system found at path")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	files, next_cursor, has_more, fok := provider.changed_files(path, cursor, eff_limit)
	if !fok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\",\"files\":[],\"cursor\":\""); json_write_string(&b, cursor)
		strings.write_string(&b, "\",\"limit\":"); strings.write_string(&b, fmt.tprintf("%d", eff_limit))
		strings.write_string(&b, ",\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "files_failed", "Could not list changed files")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	strings.write_string(&b, "\",\"ok\":true,\"provider\":\""); json_write_string(&b, provider.name())
	strings.write_string(&b, "\",\"cursor\":\""); json_write_string(&b, cursor)
	strings.write_string(&b, "\",\"limit\":"); strings.write_string(&b, fmt.tprintf("%d", eff_limit))
	strings.write_string(&b, ",\"has_more\":"); strings.write_string(&b, "true" if has_more else "false")
	if next_cursor == "" {
		strings.write_string(&b, ",\"next_cursor\":null")
	} else {
		strings.write_string(&b, ",\"next_cursor\":\""); json_write_string(&b, next_cursor); strings.write_string(&b, "\"")
	}
	strings.write_string(&b, ",\"files\":[")
	for f, i in files {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"path\":\""); json_write_string(&b, f.path)
		strings.write_string(&b, "\",\"status\":\""); json_write_string(&b, f.status)
		strings.write_string(&b, "\",\"staged\":"); strings.write_string(&b, "true" if f.staged else "false")
		strings.write_string(&b, ",\"additions\":"); strings.write_string(&b, fmt.tprintf("%d", f.additions))
		strings.write_string(&b, ",\"deletions\":"); strings.write_string(&b, fmt.tprintf("%d", f.deletions))
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	vcs_write_error(&b, "", "")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// --- vcs_diff ------------------------------------------------------------

bridge_vcs_diff_json :: proc(command_id, text: string) -> string {
	path := vcs_request_path(text)
	file := strings.trim_space(extract_json_string(text, "path", ""))
	cursor := extract_json_string(text, "cursor", "")
	limit := extract_json_int(text, "limit", VCS_DIFF_DEFAULT_LIMIT)
	eff_limit := vcs_clamp_limit(limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	provider, ok := vcs_detect_provider(path)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"vcs_diff_result\",\"command_id\":\""); json_write_string(&b, command_id)
	if !ok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\"\",\"file\":\""); json_write_string(&b, file)
		strings.write_string(&b, "\",\"hunks\":[],\"cursor\":\""); json_write_string(&b, cursor)
		strings.write_string(&b, "\",\"limit\":"); strings.write_string(&b, fmt.tprintf("%d", eff_limit))
		strings.write_string(&b, ",\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "no_vcs", "No supported version control system found at path")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	if file == "" {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\",\"file\":\"\",\"hunks\":[],\"cursor\":\""); json_write_string(&b, cursor)
		strings.write_string(&b, "\",\"limit\":"); strings.write_string(&b, fmt.tprintf("%d", eff_limit))
		strings.write_string(&b, ",\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "missing_file", "The 'file' parameter is required for vcs_diff")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	hunks, next_cursor, has_more, dok := provider.diff_file(path, file, cursor, eff_limit)
	if !dok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\",\"file\":\""); json_write_string(&b, file)
		strings.write_string(&b, "\",\"hunks\":[],\"cursor\":\""); json_write_string(&b, cursor)
		strings.write_string(&b, "\",\"limit\":"); strings.write_string(&b, fmt.tprintf("%d", eff_limit))
		strings.write_string(&b, ",\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "diff_failed", "Could not read file diff")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	strings.write_string(&b, "\",\"ok\":true,\"provider\":\""); json_write_string(&b, provider.name())
	strings.write_string(&b, "\",\"file\":\""); json_write_string(&b, file)
	strings.write_string(&b, "\",\"cursor\":\""); json_write_string(&b, cursor)
	strings.write_string(&b, "\",\"limit\":"); strings.write_string(&b, fmt.tprintf("%d", eff_limit))
	strings.write_string(&b, ",\"has_more\":"); strings.write_string(&b, "true" if has_more else "false")
	if next_cursor == "" {
		strings.write_string(&b, ",\"next_cursor\":null")
	} else {
		strings.write_string(&b, ",\"next_cursor\":\""); json_write_string(&b, next_cursor); strings.write_string(&b, "\"")
	}
	strings.write_string(&b, ",\"hunks\":[")
	for h, i in hunks {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"old_start\":"); strings.write_string(&b, fmt.tprintf("%d", h.old_start))
		strings.write_string(&b, ",\"old_len\":"); strings.write_string(&b, fmt.tprintf("%d", h.old_len))
		strings.write_string(&b, ",\"new_start\":"); strings.write_string(&b, fmt.tprintf("%d", h.new_start))
		strings.write_string(&b, ",\"new_len\":"); strings.write_string(&b, fmt.tprintf("%d", h.new_len))
		strings.write_string(&b, ",\"lines\":[")
		for ln, j in h.lines {
			if j > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, "{\"op\":\""); json_write_string(&b, ln.op)
			strings.write_string(&b, "\",\"text\":\""); json_write_string(&b, ln.text)
			strings.write_string(&b, "\"}")
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "]")
	vcs_write_error(&b, "", "")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// --- vcs_stage / vcs_unstage / vcs_revert (write commands) ---------------

bridge_vcs_stage_json :: proc(command_id, text: string) -> string {
	return bridge_vcs_write_action_json(command_id, text, "vcs_stage_result", "stage")
}
bridge_vcs_unstage_json :: proc(command_id, text: string) -> string {
	return bridge_vcs_write_action_json(command_id, text, "vcs_unstage_result", "unstage")
}
bridge_vcs_revert_json :: proc(command_id, text: string) -> string {
	return bridge_vcs_write_action_json(command_id, text, "vcs_revert_result", "revert")
}

// bridge_vcs_write_action_json is the shared body for the three write commands,
// which differ only in result `type` and which provider proc runs. Params: repo in
// "root", file in "path" (matching vcs_diff). A nil proc pointer or a "not_supported"
// msg both surface error code "not_supported"; the provider's own failure msg
// (e.g. "untracked_file") becomes the error code otherwise.
bridge_vcs_write_action_json :: proc(command_id, text, result_type, action: string) -> string {
	path := vcs_request_path(text)
	file := strings.trim_space(extract_json_string(text, "path", ""))
	provider, ok := vcs_detect_provider(path)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\""); json_write_string(&b, result_type)
	strings.write_string(&b, "\",\"command_id\":\""); json_write_string(&b, command_id)
	if !ok {
		strings.write_string(&b, "\",\"ok\":false")
		vcs_write_error(&b, "no_vcs", "No supported version control system found at path")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	if file == "" {
		strings.write_string(&b, "\",\"ok\":false")
		vcs_write_error(&b, "missing_file", "The 'path' parameter is required")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	supported := true
	aok := false
	msg := ""
	switch action {
	case "stage":
		if provider.stage_file == nil { supported = false } else { aok, msg = provider.stage_file(path, file) }
	case "unstage":
		if provider.unstage_file == nil { supported = false } else { aok, msg = provider.unstage_file(path, file) }
	case "revert":
		if provider.revert_file == nil { supported = false } else { aok, msg = provider.revert_file(path, file) }
	}
	if !supported {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\"")
		vcs_write_error(&b, "not_supported", "Action not supported by this provider")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if aok else "false")
	strings.write_string(&b, ",\"provider\":\""); json_write_string(&b, provider.name())
	strings.write_string(&b, "\"")
	if aok {
		vcs_write_error(&b, "", "")
	} else {
		code := msg
		if code == "" do code = "action_failed"
		vcs_write_error(&b, code, vcs_action_error_message(code))
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// --- vcs_save_file (write command) ---------------------------------------
// Editor save: writes the full text of a working-tree file. Params: repo in "root",
// relative file in "path" (uniform with the other write commands), buffer in
// "content". Never cached (mutation). Result type "vcs_save_file_result".
bridge_vcs_save_json :: proc(command_id, text: string) -> string {
	path := vcs_request_path(text)
	file := strings.trim_space(extract_json_string(text, "path", ""))
	content := extract_json_string(text, "content", "")
	provider, ok := vcs_detect_provider(path)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"vcs_save_file_result\",\"command_id\":\""); json_write_string(&b, command_id)
	if !ok {
		strings.write_string(&b, "\",\"ok\":false")
		vcs_write_error(&b, "no_vcs", "No supported version control system found at path")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	if file == "" {
		strings.write_string(&b, "\",\"ok\":false")
		vcs_write_error(&b, "missing_file", "The 'path' parameter is required")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	if provider.save_file == nil {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\"")
		vcs_write_error(&b, "not_supported", "Save is not supported by this provider")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	aok, msg := provider.save_file(path, file, content)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if aok else "false")
	strings.write_string(&b, ",\"provider\":\""); json_write_string(&b, provider.name())
	strings.write_string(&b, "\"")
	if aok {
		vcs_write_error(&b, "", "")
	} else {
		code := msg
		if code == "" do code = "save_failed"
		vcs_write_error(&b, code, vcs_action_error_message(code))
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// vcs_action_error_message maps a write-action error code to a human message.
vcs_action_error_message :: proc(code: string) -> string {
	switch code {
	case "not_supported":  return "Action not supported by this provider"
	case "untracked_file": return "File is untracked and cannot be reverted"
	case "stage_failed":   return "Could not stage file"
	case "unstage_failed": return "Could not unstage file"
	case "revert_failed":  return "Could not revert file"
	case "save_failed":    return "Could not save file"
	case "missing_file":   return "The 'path' parameter is required"
	case "path_outside_root": return "File path is outside the repository root"
	case:                  return "VCS action failed"
	}
}

// --- vcs_log -------------------------------------------------------------

bridge_vcs_log_json :: proc(command_id, text: string) -> string {
	path := vcs_request_path(text)
	cursor := extract_json_string(text, "cursor", "")
	limit := extract_json_int(text, "limit", VCS_LOG_DEFAULT_LIMIT)
	eff_limit := vcs_clamp_limit(limit, VCS_LOG_DEFAULT_LIMIT, VCS_LOG_MAX_LIMIT)
	provider, ok := vcs_detect_provider(path)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"vcs_log_result\",\"command_id\":\""); json_write_string(&b, command_id)
	if !ok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\"\",\"entries\":[],\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "no_vcs", "No supported version control system found at path")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	if provider.log == nil {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\",\"entries\":[],\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "not_supported", "Log is not supported by this provider")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	entries, next_cursor, has_more, lok := provider.log(path, cursor, eff_limit)
	if !lok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\",\"entries\":[],\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "log_failed", "Could not read commit log")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	strings.write_string(&b, "\",\"ok\":true,\"provider\":\""); json_write_string(&b, provider.name())
	strings.write_string(&b, "\",\"has_more\":"); strings.write_string(&b, "true" if has_more else "false")
	if next_cursor == "" {
		strings.write_string(&b, ",\"next_cursor\":null")
	} else {
		strings.write_string(&b, ",\"next_cursor\":\""); json_write_string(&b, next_cursor); strings.write_string(&b, "\"")
	}
	strings.write_string(&b, ",\"entries\":[")
	for e, i in entries {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"hash\":\""); json_write_string(&b, e.hash)
		strings.write_string(&b, "\",\"short_hash\":\""); json_write_string(&b, e.short_hash)
		strings.write_string(&b, "\",\"subject\":\""); json_write_string(&b, e.subject)
		strings.write_string(&b, "\",\"author\":\""); json_write_string(&b, e.author)
		strings.write_string(&b, "\",\"date\":\""); json_write_string(&b, e.date)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "]")
	vcs_write_error(&b, "", "")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// --- vcs_commit_diff -----------------------------------------------------
// Same shape as vcs_diff_result (type "vcs_commit_diff_result"), plus the base/head
// refs echoed back for correlation. Params: repo in "root", optional file in "path",
// refs in "base_ref"/"head_ref" (head_ref "WORKDIR" or absent = compare to worktree).

bridge_vcs_commit_diff_json :: proc(command_id, text: string) -> string {
	path := vcs_request_path(text)
	base_ref := strings.trim_space(extract_json_string(text, "base_ref", ""))
	head_ref := strings.trim_space(extract_json_string(text, "head_ref", ""))
	file := strings.trim_space(extract_json_string(text, "path", ""))
	cursor := extract_json_string(text, "cursor", "")
	limit := extract_json_int(text, "limit", VCS_DIFF_DEFAULT_LIMIT)
	eff_limit := vcs_clamp_limit(limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	provider, ok := vcs_detect_provider(path)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"vcs_commit_diff_result\",\"command_id\":\""); json_write_string(&b, command_id)
	if !ok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\"\",\"file\":\""); json_write_string(&b, file)
		bridge_vcs_commit_diff_meta(&b, base_ref, head_ref, cursor, eff_limit)
		strings.write_string(&b, ",\"hunks\":[],\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "no_vcs", "No supported version control system found at path")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	if base_ref == "" {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\",\"file\":\""); json_write_string(&b, file)
		bridge_vcs_commit_diff_meta(&b, base_ref, head_ref, cursor, eff_limit)
		strings.write_string(&b, ",\"hunks\":[],\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "invalid_ref", "The 'base_ref' parameter is required")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	if provider.commit_diff == nil {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\",\"file\":\""); json_write_string(&b, file)
		bridge_vcs_commit_diff_meta(&b, base_ref, head_ref, cursor, eff_limit)
		strings.write_string(&b, ",\"hunks\":[],\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "not_supported", "Commit diff is not supported by this provider")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	hunks, next_cursor, has_more, dok := provider.commit_diff(path, base_ref, head_ref, file, cursor, eff_limit)
	if !dok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\",\"file\":\""); json_write_string(&b, file)
		bridge_vcs_commit_diff_meta(&b, base_ref, head_ref, cursor, eff_limit)
		strings.write_string(&b, ",\"hunks\":[],\"has_more\":false,\"next_cursor\":null")
		vcs_write_error(&b, "invalid_ref", "Could not diff the requested revisions")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	strings.write_string(&b, "\",\"ok\":true,\"provider\":\""); json_write_string(&b, provider.name())
	strings.write_string(&b, "\",\"file\":\""); json_write_string(&b, file)
	bridge_vcs_commit_diff_meta(&b, base_ref, head_ref, cursor, eff_limit)
	strings.write_string(&b, ",\"has_more\":"); strings.write_string(&b, "true" if has_more else "false")
	if next_cursor == "" {
		strings.write_string(&b, ",\"next_cursor\":null")
	} else {
		strings.write_string(&b, ",\"next_cursor\":\""); json_write_string(&b, next_cursor); strings.write_string(&b, "\"")
	}
	strings.write_string(&b, ",\"hunks\":[")
	for h, i in hunks {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"old_start\":"); strings.write_string(&b, fmt.tprintf("%d", h.old_start))
		strings.write_string(&b, ",\"old_len\":"); strings.write_string(&b, fmt.tprintf("%d", h.old_len))
		strings.write_string(&b, ",\"new_start\":"); strings.write_string(&b, fmt.tprintf("%d", h.new_start))
		strings.write_string(&b, ",\"new_len\":"); strings.write_string(&b, fmt.tprintf("%d", h.new_len))
		strings.write_string(&b, ",\"lines\":[")
		for ln, j in h.lines {
			if j > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, "{\"op\":\""); json_write_string(&b, ln.op)
			strings.write_string(&b, "\",\"text\":\""); json_write_string(&b, ln.text)
			strings.write_string(&b, "\"}")
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "]")
	vcs_write_error(&b, "", "")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// bridge_vcs_commit_diff_meta writes the shared ,"base_ref":..,"head_ref":..,
// "cursor":..,"limit":.. fields for every vcs_commit_diff response branch. Caller
// has just written the "file" field; this appends the rest of the metadata.
bridge_vcs_commit_diff_meta :: proc(b: ^strings.Builder, base_ref, head_ref, cursor: string, eff_limit: int) {
	strings.write_string(b, "\",\"base_ref\":\""); json_write_string(b, base_ref)
	strings.write_string(b, "\",\"head_ref\":\""); json_write_string(b, head_ref)
	strings.write_string(b, "\",\"cursor\":\""); json_write_string(b, cursor)
	strings.write_string(b, "\",\"limit\":"); strings.write_string(b, fmt.tprintf("%d", eff_limit))
}

// --- vcs_workspaces ------------------------------------------------------

bridge_vcs_workspaces_json :: proc(command_id, text: string) -> string {
	path := vcs_request_path(text)
	provider, ok := vcs_detect_provider(path)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"vcs_workspaces_result\",\"command_id\":\""); json_write_string(&b, command_id)
	if !ok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\"\",\"workspaces\":[]")
		vcs_write_error(&b, "no_vcs", "No supported version control system found at path")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	if provider.list_workspaces == nil {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\",\"workspaces\":[]")
		vcs_write_error(&b, "not_supported", "Workspaces are not supported by this provider")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	workspaces, wok := provider.list_workspaces(path)
	if !wok {
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\""); json_write_string(&b, provider.name())
		strings.write_string(&b, "\",\"workspaces\":[]")
		vcs_write_error(&b, "workspaces_failed", "Could not list workspaces")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	strings.write_string(&b, "\",\"ok\":true,\"provider\":\""); json_write_string(&b, provider.name())
	strings.write_string(&b, "\",\"workspaces\":[")
	for w, i in workspaces {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"path\":\""); json_write_string(&b, w.path)
		strings.write_string(&b, "\",\"label\":\""); json_write_string(&b, w.label)
		strings.write_string(&b, "\",\"is_current\":"); strings.write_string(&b, "true" if w.is_current else "false")
		strings.write_string(&b, ",\"is_locked\":"); strings.write_string(&b, "true" if w.is_locked else "false")
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	vcs_write_error(&b, "", "")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// vcs_write_error appends the shared trailing ,"error":{"code":..,"message":..}
// object used by every vcs_* result (empty code/message on success).
vcs_write_error :: proc(b: ^strings.Builder, code, message: string) {
	strings.write_string(b, ",\"error\":{\"code\":\""); json_write_string(b, code)
	strings.write_string(b, "\",\"message\":\""); json_write_string(b, message)
	strings.write_string(b, "\"}")
}

// vcs-panel-test: 2026-09-17T08:26:21Z
