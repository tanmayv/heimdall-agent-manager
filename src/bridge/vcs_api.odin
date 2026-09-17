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
	}
	return false
}

// vcs_request_path extracts and home-expands the "path" param.
vcs_request_path :: proc(text: string) -> string {
	raw := strings.trim_space(extract_json_string(text, "path", ""))
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
		strings.write_string(&b, "\",\"ok\":false,\"provider\":\"\",\"supports_staging\":false")
		vcs_write_error(&b, "no_vcs", "No supported version control system found at path")
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	caps := provider.capabilities(path)
	strings.write_string(&b, "\",\"ok\":true,\"provider\":\""); json_write_string(&b, caps.provider)
	strings.write_string(&b, "\",\"supports_staging\":"); strings.write_string(&b, "true" if caps.supports_staging else "false")
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
	file := strings.trim_space(extract_json_string(text, "file", ""))
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

// vcs_write_error appends the shared trailing ,"error":{"code":..,"message":..}
// object used by every vcs_* result (empty code/message on success).
vcs_write_error :: proc(b: ^strings.Builder, code, message: string) {
	strings.write_string(b, ",\"error\":{\"code\":\""); json_write_string(b, code)
	strings.write_string(b, "\",\"message\":\""); json_write_string(b, message)
	strings.write_string(b, "\"}")
}
