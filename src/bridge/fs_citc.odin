package main

// CitC (Client in the Cloud) / Fig filesystem management for the bridge host.
//
// Powers Fig workspace discovery under /google/src/cloud/<user>/, CitC workspace
// creation via `g4 citc`, and paginated directory browsing under
// /google/src/cloud/<user>/<workspace>/google3/.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import ws "odin_test:lib/ws"

Fig_Workspace_Entry :: struct {
	name:                  string,
	path:                  string,
	modified_at:           string,
	last_sync_head_change: string,
	age_text:              string,
}

Fig_List_Workspaces_Result :: struct {
	ok:         bool,
	user_root:  string,
	workspaces: []Fig_Workspace_Entry,
	error_code: string,
	message:    string,
}

Fig_Create_Workspace_Result :: struct {
	ok:         bool,
	name:       string,
	path:       string,
	created:    bool,
	error_code: string,
	message:    string,
}

Fig_List_Dir_Result :: struct {
	ok:          bool,
	workspace:   string,
	path:        string, // relative path inside workspace google3
	full_path:   string,
	root:        string,
	parent:      string,
	entries:     []Bridge_Fs_Entry,
	next_cursor: string,
	has_more:    bool,
	error_code:  string,
	message:     string,
}

fig_citc_user_root :: proc() -> string {
	custom := os.get_env_alloc("HEIMDALL_CITC_ROOT", context.allocator)
	if custom != "" {
		return strings.trim_right(custom, "/")
	}
	user := os.get_env_alloc("USER", context.allocator)
	if user == "" do user = os.get_env_alloc("LOGNAME", context.allocator)
	if user == "" do user = "nobody"
	return fmt.tprintf("/google/src/cloud/%s", user)
}

fig_is_valid_workspace_name :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 64 do return false
	if name[0] == '-' || name[0] == '_' do return false
	for ch in name {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-', '_':
			continue
		case:
			return false
		}
	}
	return true
}

Fig_Cache_Item :: struct {
	name:                  string,
	path:                  string,
	modified_at:           string,
	last_sync_head_change: string,
	age_text:              string,
	mtime_ns:              i64,
}

Fig_Workspace_Cache :: struct {
	lock:          sync.Mutex,
	initialized:   bool,
	is_refreshing: bool,
	last_refresh:  time.Time,
	user_root:     string,
	items:         [dynamic]Fig_Cache_Item,
}

fig_cache: Fig_Workspace_Cache

fig_format_age :: proc(mtime: time.Time) -> string {
	now := time.now()
	diff_ns := time.diff(mtime, now)
	if diff_ns < 0 do return "just now"
	diff_sec := i64(diff_ns / 1_000_000_000)
	if diff_sec < 60 do return "just now"
	diff_min := diff_sec / 60
	if diff_min < 60 {
		if diff_min == 1 do return "1m ago"
		return fmt.tprintf("%dm ago", diff_min)
	}
	diff_hours := diff_min / 60
	if diff_hours < 24 {
		if diff_hours == 1 do return "1h ago"
		return fmt.tprintf("%dh ago", diff_hours)
	}
	diff_days := diff_hours / 24
	if diff_days < 30 {
		if diff_days == 1 do return "1d ago"
		return fmt.tprintf("%dd ago", diff_days)
	}
	diff_months := diff_days / 30
	if diff_months == 1 do return "1mo ago"
	return fmt.tprintf("%dmo ago", diff_months)
}

fig_extract_last_sync_head :: proc(user_root, ws_name: string) -> string {
	version_map_path := fmt.tprintf("%s/%s/VERSION_MAP", user_root, ws_name)
	data, err := os.read_entire_file(version_map_path, context.allocator)
	if err != nil do return ""
	defer delete(data)
	content := string(data)
	for line in strings.split_lines_iterator(&content) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "map ") {
			rest := strings.trim_space(trimmed[4:])
			end_idx := strings.index_byte(rest, ' ')
			if end_idx > 0 {
				cl := rest[:end_idx]
				is_digits := true
				for ch in cl {
					if ch < '0' || ch > '9' {
						is_digits = false
						break
					}
				}
				if is_digits && len(cl) > 0 {
					return strings.clone(cl)
				}
			}
		}
	}
	return ""
}

fig_cache_start_prefetch :: proc() {
	sync.mutex_lock(&fig_cache.lock)
	if fig_cache.is_refreshing {
		sync.mutex_unlock(&fig_cache.lock)
		return
	}
	fig_cache.is_refreshing = true
	sync.mutex_unlock(&fig_cache.lock)
	thread.run(fig_cache_refresh_worker)
}

fig_cache_refresh_worker :: proc() {
	user_root := fig_citc_user_root()
	items := fig_scan_workspaces_internal(user_root)

	sync.mutex_lock(&fig_cache.lock)
	for item in fig_cache.items {
		delete(item.name)
		delete(item.path)
		delete(item.modified_at)
		delete(item.last_sync_head_change)
		delete(item.age_text)
	}
	clear(&fig_cache.items)
	for item in items {
		append(&fig_cache.items, item)
	}
	delete(items)
	fig_cache.initialized = true
	fig_cache.is_refreshing = false
	fig_cache.last_refresh = time.now()
	delete(fig_cache.user_root)
	fig_cache.user_root = strings.clone(user_root)
	sync.mutex_unlock(&fig_cache.lock)
}

fig_scan_workspaces_internal :: proc(user_root: string) -> [dynamic]Fig_Cache_Item {
	items := make([dynamic]Fig_Cache_Item)
	if !os.exists(user_root) || !os.is_dir(user_root) do return items
	infos, err := os.read_directory_by_path(user_root, -1, context.allocator)
	if err != nil do return items
	defer os.file_info_slice_delete(infos, context.allocator)

	for info in infos {
		name := info.name
		if name == "" || name == "." || name == ".." do continue
		if len(name) > 0 && name[0] == '.' do continue
		if info.type != .Directory do continue
		if !fig_is_valid_workspace_name(name) do continue

		g3_path := fmt.tprintf("%s/%s/google3", user_root, name)
		mtime := bridge_fs_format_mtime(info.modification_time)
		mtime_ns := time.to_unix_nanoseconds(info.modification_time)
		age := fig_format_age(info.modification_time)

		append(&items, Fig_Cache_Item{
			name = strings.clone(name),
			path = strings.clone(g3_path),
			modified_at = strings.clone(mtime),
			last_sync_head_change = "",
			age_text = strings.clone(age),
			mtime_ns = mtime_ns,
		})
	}

	slice.sort_by(items[:], proc(i, j: Fig_Cache_Item) -> bool {
		if i.mtime_ns != j.mtime_ns {
			return i.mtime_ns > j.mtime_ns // descending: newest first
		}
		return i.name < j.name
	})

	max_version_map_checks := min(25, len(items))
	for i in 0..<max_version_map_checks {
		cl := fig_extract_last_sync_head(user_root, items[i].name)
		if cl != "" {
			items[i].last_sync_head_change = cl
		}
	}

	return items
}

fig_filter_items :: proc(items: []Fig_Cache_Item, user_root, query: string) -> Fig_List_Workspaces_Result {
	clean_query := strings.to_lower(strings.trim_space(query))
	defer delete(clean_query)

	matched := make([dynamic]Fig_Workspace_Entry, context.allocator)
	for item in items {
		if clean_query != "" {
			name_lower := strings.to_lower(item.name)
			defer delete(name_lower)
			if !strings.contains(name_lower, clean_query) do continue
		}
		append(&matched, Fig_Workspace_Entry{
			name = strings.clone(item.name),
			path = strings.clone(item.path),
			modified_at = strings.clone(item.modified_at),
			last_sync_head_change = strings.clone(item.last_sync_head_change),
			age_text = strings.clone(item.age_text),
		})
	}

	return Fig_List_Workspaces_Result{
		ok = true,
		user_root = strings.clone(user_root),
		workspaces = matched[:],
	}
}

fig_list_workspaces :: proc(custom_root: string = "", query: string = "") -> Fig_List_Workspaces_Result {
	user_root := custom_root if custom_root != "" else fig_citc_user_root()

	if custom_root != "" {
		items := fig_scan_workspaces_internal(custom_root)
		defer {
			for item in items {
				delete(item.name)
				delete(item.path)
				delete(item.modified_at)
				delete(item.last_sync_head_change)
				delete(item.age_text)
			}
			delete(items)
		}
		return fig_filter_items(items[:], user_root, query)
	}

	sync.mutex_lock(&fig_cache.lock)
	needs_initial_scan := !fig_cache.initialized && len(fig_cache.items) == 0
	sync.mutex_unlock(&fig_cache.lock)

	if needs_initial_scan {
		fig_cache_refresh_worker()
	} else {
		now := time.now()
		sync.mutex_lock(&fig_cache.lock)
		age_sec := i64(time.diff(fig_cache.last_refresh, now) / 1_000_000_000)
		should_refresh := age_sec > 30 && !fig_cache.is_refreshing
		sync.mutex_unlock(&fig_cache.lock)
		if should_refresh {
			fig_cache_start_prefetch()
		}
	}

	sync.mutex_lock(&fig_cache.lock)
	defer sync.mutex_unlock(&fig_cache.lock)
	return fig_filter_items(fig_cache.items[:], user_root, query)
}

fig_create_workspace :: proc(name: string, custom_root: string = "", mock: bool = false) -> Fig_Create_Workspace_Result {
	if !fig_is_valid_workspace_name(name) {
		return Fig_Create_Workspace_Result{
			ok = false,
			name = name,
			error_code = "invalid_name",
			message = "Workspace name must contain only letters, numbers, hyphens, or underscores",
		}
	}
	user_root := custom_root if custom_root != "" else fig_citc_user_root()
	ws_path := fmt.tprintf("%s/%s", user_root, name)
	g3_path := fmt.tprintf("%s/google3", ws_path)

	mock_env := os.get_env_alloc("HEIMDALL_MOCK_CITC", context.allocator)
	is_mock := mock || mock_env == "1" || mock_env == "true"

	if is_mock {
		if !os.exists(user_root) {
			_ = os.make_directory(user_root)
		}
		if !os.exists(ws_path) {
			_ = os.make_directory(ws_path)
		}
		if !os.exists(g3_path) {
			_ = os.make_directory(g3_path)
		}
		return Fig_Create_Workspace_Result{
			ok = true,
			name = name,
			path = g3_path,
			created = true,
		}
	}

	// Real CitC creation via g4 citc -- <name>
	cmd := []string{"g4", "citc", "--", name}
	process, start_err := os.process_start(os.Process_Desc{command = cmd})
	if start_err != nil {
		return Fig_Create_Workspace_Result{
			ok = false,
			name = name,
			error_code = "citc_spawn_failed",
			message = fmt.tprintf("Failed to invoke g4 citc: %v", start_err),
		}
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil || state.exit_code != 0 {
		exit_code := state.exit_code if wait_err == nil else -1
		return Fig_Create_Workspace_Result{
			ok = false,
			name = name,
			error_code = "citc_command_failed",
			message = fmt.tprintf("g4 citc exited with status %d", exit_code),
		}
	}

	return Fig_Create_Workspace_Result{
		ok = true,
		name = name,
		path = g3_path,
		created = true,
	}
}

fig_list_dir :: proc(workspace, path: string, cursor: string = "", limit: int = 50, include_hidden: bool = false, custom_root: string = "") -> Fig_List_Dir_Result {
	if !fig_is_valid_workspace_name(workspace) {
		return Fig_List_Dir_Result{
			ok = false,
			workspace = workspace,
			path = path,
			error_code = "invalid_workspace",
			message = "Invalid workspace name",
		}
	}
	user_root := custom_root if custom_root != "" else fig_citc_user_root()
	ws_root := fmt.tprintf("%s/%s/google3", user_root, workspace)
	if !os.exists(ws_root) || !os.is_dir(ws_root) {
		return Fig_List_Dir_Result{
			ok = false,
			workspace = workspace,
			path = path,
			root = ws_root,
			error_code = "workspace_not_found",
			message = "Workspace google3 root not found",
		}
	}

	rel_clean := strings.trim_space(path)
	rel_clean = strings.trim_left(rel_clean, "/")
	if strings.contains(rel_clean, "..") || strings.contains(rel_clean, "\x00") {
		return Fig_List_Dir_Result{
			ok = false,
			workspace = workspace,
			path = path,
			root = ws_root,
			error_code = "path_outside_root",
			message = "Path traversal is not permitted",
		}
	}

	target_dir: string
	if rel_clean == "" || rel_clean == "." {
		target_dir = ws_root
		rel_clean = ""
	} else {
		target_dir = fmt.tprintf("%s/%s", ws_root, rel_clean)
	}

	target_clean, _ := filepath.clean(target_dir, context.temp_allocator)
	ws_root_clean, _ := filepath.clean(ws_root, context.temp_allocator)
	ws_prefix := ws_root_clean
	if !strings.has_suffix(ws_prefix, "/") do ws_prefix = fmt.tprintf("%s/", ws_root_clean)
	if target_clean != ws_root_clean && !strings.has_prefix(target_clean, ws_prefix) {
		return Fig_List_Dir_Result{
			ok = false,
			workspace = workspace,
			path = path,
			root = ws_root,
			error_code = "path_outside_root",
			message = "Path traversal is not permitted",
		}
	}

	if !os.exists(target_dir) {
		return Fig_List_Dir_Result{
			ok = false,
			workspace = workspace,
			path = rel_clean,
			full_path = target_dir,
			root = ws_root,
			error_code = "path_not_found",
			message = "Path does not exist",
		}
	}
	if !os.is_dir(target_dir) {
		return Fig_List_Dir_Result{
			ok = false,
			workspace = workspace,
			path = rel_clean,
			full_path = target_dir,
			root = ws_root,
			error_code = "path_not_directory",
			message = "Path is not a directory",
		}
	}

	infos, rerr := os.read_directory_by_path(target_dir, -1, context.allocator)
	if rerr != nil {
		return Fig_List_Dir_Result{
			ok = false,
			workspace = workspace,
			path = rel_clean,
			full_path = target_dir,
			root = ws_root,
			error_code = "read_failed",
			message = "Could not read directory",
		}
	}
	defer os.file_info_slice_delete(infos, context.allocator)

	all := make([dynamic]Bridge_Fs_Entry, context.allocator)
	for info in infos {
		name := info.name
		if name == "" || name == "." || name == ".." do continue
		hidden := len(name) > 0 && name[0] == '.'
		if !include_hidden && hidden do continue
		is_dir := info.type == .Directory
		size := i64(0)
		if !is_dir do size = info.size
		append(&all, Bridge_Fs_Entry{
			name        = strings.clone(name),
			is_dir      = is_dir,
			hidden      = hidden,
			has_git     = false,
			size        = size,
			modified_at = bridge_fs_format_mtime(info.modification_time),
		})
	}

	slice.sort_by(all[:], bridge_fs_entry_less)
	total := len(all)

	page_limit := limit
	if page_limit <= 0 do page_limit = 50
	if page_limit > 200 do page_limit = 200

	start := bridge_fs_decode_cursor(cursor)
	if start < 0 do start = 0
	if start > total do start = total
	end := start + page_limit
	if end > total do end = total

	page := make([dynamic]Bridge_Fs_Entry, context.allocator)
	for i in start..<end do append(&page, all[i])
	has_more := end < total
	next_cursor := ""
	if has_more do next_cursor = bridge_fs_encode_cursor(end)

	parent := ""
	if rel_clean != "" {
		parent = filepath.dir(rel_clean)
		if parent == "." do parent = ""
	}

	return Fig_List_Dir_Result{
		ok = true,
		workspace = workspace,
		path = rel_clean,
		full_path = target_dir,
		root = ws_root,
		parent = parent,
		entries = page[:],
		next_cursor = next_cursor,
		has_more = has_more,
	}
}

bridge_fig_workspaces_result_json :: proc(command_id: string, r: Fig_List_Workspaces_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fig_list_workspaces_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"user_root\":\""); json_write_string(&b, r.user_root)
	strings.write_string(&b, "\",\"workspaces\":[")
	for ws_entry, i in r.workspaces {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"name\":\""); json_write_string(&b, ws_entry.name)
		strings.write_string(&b, "\",\"path\":\""); json_write_string(&b, ws_entry.path)
		strings.write_string(&b, "\",\"modified_at\":\""); json_write_string(&b, ws_entry.modified_at)
		strings.write_string(&b, "\",\"last_sync_head_change\":\""); json_write_string(&b, ws_entry.last_sync_head_change)
		strings.write_string(&b, "\",\"age_text\":\""); json_write_string(&b, ws_entry.age_text)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "],\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_fig_create_workspace_result_json :: proc(command_id: string, r: Fig_Create_Workspace_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fig_create_workspace_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"name\":\""); json_write_string(&b, r.name)
	strings.write_string(&b, "\",\"path\":\""); json_write_string(&b, r.path)
	strings.write_string(&b, "\",\"created\":"); strings.write_string(&b, "true" if r.created else "false")
	strings.write_string(&b, ",\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_fig_list_dir_result_json :: proc(command_id: string, r: Fig_List_Dir_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fig_list_dir_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"workspace\":\""); json_write_string(&b, r.workspace)
	strings.write_string(&b, "\",\"path\":\""); json_write_string(&b, r.path)
	strings.write_string(&b, "\",\"full_path\":\""); json_write_string(&b, r.full_path)
	strings.write_string(&b, "\",\"root\":\""); json_write_string(&b, r.root)
	strings.write_string(&b, "\",\"parent\":\""); json_write_string(&b, r.parent)
	strings.write_string(&b, "\",\"has_more\":"); strings.write_string(&b, "true" if r.has_more else "false")
	if r.next_cursor == "" {
		strings.write_string(&b, ",\"next_cursor\":null")
	} else {
		strings.write_string(&b, ",\"next_cursor\":\""); json_write_string(&b, r.next_cursor); strings.write_string(&b, "\"")
	}
	strings.write_string(&b, ",\"entries\":[")
	for e, i in r.entries {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"name\":\""); json_write_string(&b, e.name)
		strings.write_string(&b, "\",\"is_dir\":"); strings.write_string(&b, "true" if e.is_dir else "false")
		strings.write_string(&b, ",\"hidden\":"); strings.write_string(&b, "true" if e.hidden else "false")
		strings.write_string(&b, ",\"has_git\":"); strings.write_string(&b, "true" if e.has_git else "false")
		strings.write_string(&b, ",\"size\":"); strings.write_string(&b, fmt.tprintf("%d", e.size))
		strings.write_string(&b, ",\"modified_at\":\""); json_write_string(&b, e.modified_at)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "],\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

// bridge_fig_handle_command dispatches fig_* commands over the runtime WS.
bridge_fig_handle_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	switch type {
	case "fig_list_workspaces":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		query := extract_json_string(text, "query", "")
		if query == "" do query = extract_json_string(text, "search", "")
		if query == "" do query = extract_json_string(text, "q", "")
		result := fig_list_workspaces("", query)
		out := bridge_fig_workspaces_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	case "fig_create_workspace":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		name := extract_json_string(text, "workspace", "")
		if name == "" do name = extract_json_string(text, "name", "")
		result := fig_create_workspace(name)
		out := bridge_fig_create_workspace_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	case "fig_list_dir":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		workspace := extract_json_string(text, "workspace", "")
		path := extract_json_string(text, "path", "")
		cursor := extract_json_string(text, "cursor", "")
		limit := extract_json_int(text, "limit", 50)
		include_hidden := false
		if strings.contains(text, "\"include_hidden\"") do include_hidden = bridge_fs_extract_json_bool(text, "include_hidden", false)
		result := fig_list_dir(workspace, path, cursor, limit, include_hidden)
		out := bridge_fig_list_dir_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	}
	return false
}
