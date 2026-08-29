package main

// Sandboxed filesystem directory management for the bridge host.
//
// Powers the UI's bridge-aware directory picker (browse + create project paths)
// and the "is this project path present on bridge X?" check. All operations are
// confined to a configured trusted root (default $HOME) — see the security model
// in docs/plans/bridge-directory-management.md.
//
// v1 capabilities: list a directory, stat a path, mkdir -p. No file contents, no
// delete/rename, no browsing outside the root.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import ws "odin_test:lib/ws"

// The resolved (symlink-free, absolute) sandbox root. Set once at startup by
// bridge_fs_init. Empty means FS management is effectively disabled (deny all).
bridge_fs_root: string

// bridge_fs_init resolves the configured fs_root (or $HOME when unset) to a real
// absolute path and stores it. Call once at startup.
bridge_fs_init :: proc(configured_root: string) {
	home := os.get_env_alloc("HOME", context.allocator)
	root := strings.trim_space(configured_root)
	// Default to $HOME when unset. Also expand a bare "~" or "~/..." to $HOME
	// (bridge_expand_home only handles the "~/" form, so handle bare "~" here).
	if root == "" || root == "~" {
		root = home != "" ? home : "/"
	} else {
		root = bridge_expand_home(root)
	}
	// Resolve symlinks + make absolute so containment compares real paths.
	if resolved, err := os.get_absolute_path(root, context.allocator); err == nil {
		bridge_fs_root = resolved
	} else {
		// Root does not exist / cannot be resolved: fall back to the expanded form
		// (containment still works lexically; ops on a missing root just fail).
		bridge_fs_root = strings.clone(root)
	}
	fmt.printfln("bridge fs sandbox root: %s", bridge_fs_root)
}

Bridge_Fs_Entry :: struct {
	name:    string,
	is_dir:  bool,
	hidden:  bool,
	has_git: bool,
}

Bridge_Fs_List_Result :: struct {
	ok:         bool,
	path:       string, // canonical absolute path actually listed
	root:       string, // sandbox root (for UI breadcrumb bounds)
	parent:     string, // parent within root, or "" if path == root
	entries:    []Bridge_Fs_Entry,
	truncated:  bool,
	error_code: string,
	message:    string,
}

Bridge_Fs_Stat_Result :: struct {
	ok:          bool, // request itself succeeded (within root, no fatal error)
	path:        string,
	exists:      bool,
	is_dir:      bool,
	has_git:     bool,
	within_root: bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Mkdir_Result :: struct {
	ok:          bool,
	path:        string,
	created:     bool, // false if it already existed as a dir (idempotent)
	within_root: bool,
	error_code:  string,
	message:     string,
}

BRIDGE_FS_MAX_ENTRIES :: 2000

// --- containment ---------------------------------------------------------

// bridge_fs_resolve_within canonicalizes `requested` (which may not exist yet) and
// checks that it is the root or a descendant of it. Returns the canonical absolute
// path and whether it is contained. Handles ~-expansion, relative paths (against
// root), `..`, and symlink escapes (by resolving the deepest existing ancestor).
bridge_fs_resolve_within :: proc(requested: string) -> (canonical: string, within: bool) {
	if bridge_fs_root == "" do return "", false
	req := strings.trim_space(requested)
	// Empty request means "the root itself".
	if req == "" || req == "~" do return strings.clone(bridge_fs_root), true
	expanded := bridge_expand_home(req)
	// Relative paths resolve against the root, not the process cwd.
	if !filepath.is_abs(expanded) {
		joined, jerr := filepath.join([]string{bridge_fs_root, expanded}, context.allocator)
		if jerr != nil do return "", false
		expanded = joined
	}
	// Resolve the deepest EXISTING ancestor to a real path (defeats symlink escape),
	// then re-append the non-existent tail (needed for mkdir of a new dir).
	real_prefix, tail := bridge_fs_realpath_existing_prefix(expanded)
	if real_prefix == "" do return "", false
	full := real_prefix
	if tail != "" {
		joined, jerr := filepath.join([]string{real_prefix, tail}, context.allocator)
		if jerr != nil do return "", false
		full = joined
	}
	cleaned, cerr := filepath.clean(full, context.allocator)
	if cerr != nil do return "", false
	if !bridge_fs_is_within_root(cleaned) do return "", false
	return cleaned, true
}

// bridge_fs_realpath_existing_prefix walks up `path` until it finds an existing
// ancestor, resolves that ancestor to its real (symlink-free) absolute form, and
// returns (real_ancestor, remaining_tail) where tail is the not-yet-existing
// suffix (may be "").
bridge_fs_realpath_existing_prefix :: proc(path: string) -> (real_prefix: string, tail: string) {
	cleaned, cerr := filepath.clean(path, context.allocator)
	if cerr != nil do return "", ""
	cursor := cleaned
	suffix_parts := make([dynamic]string)
	defer delete(suffix_parts)
	for {
		if os.exists(cursor) {
			resolved, rerr := os.get_absolute_path(cursor, context.allocator)
			if rerr != nil do return "", ""
			// Reassemble the suffix in forward order.
			tail_parts := make([dynamic]string)
			defer delete(tail_parts)
			for i := len(suffix_parts) - 1; i >= 0; i -= 1 do append(&tail_parts, suffix_parts[i])
			joined_tail := strings.join(tail_parts[:], "/", context.allocator)
			return resolved, joined_tail
		}
		dir := filepath.dir(cursor)
		base := filepath.base(cursor)
		if dir == cursor || base == "" || base == "." || base == "/" {
			// Reached the top without finding an existing ancestor.
			return "", ""
		}
		append(&suffix_parts, base)
		cursor = dir
	}
}

bridge_fs_is_within_root :: proc(abs_path: string) -> bool {
	if bridge_fs_root == "" do return false
	if abs_path == bridge_fs_root do return true
	// Must be a strict descendant: root + "/" prefix.
	prefix := strings.concatenate({bridge_fs_root, "/"}, context.allocator)
	return strings.has_prefix(abs_path, prefix)
}

// --- operations ----------------------------------------------------------

bridge_fs_list_dir :: proc(requested: string) -> Bridge_Fs_List_Result {
	canonical, within := bridge_fs_resolve_within(requested)
	if !within {
		return Bridge_Fs_List_Result{ok = false, root = bridge_fs_root, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if !os.exists(canonical) {
		return Bridge_Fs_List_Result{ok = false, path = canonical, root = bridge_fs_root, error_code = "path_not_found", message = "Path does not exist"}
	}
	if !os.is_dir(canonical) {
		return Bridge_Fs_List_Result{ok = false, path = canonical, root = bridge_fs_root, error_code = "path_not_directory", message = "Path is not a directory"}
	}
	infos, rerr := os.read_directory_by_path(canonical, -1, context.allocator)
	if rerr != nil {
		return Bridge_Fs_List_Result{ok = false, path = canonical, root = bridge_fs_root, error_code = "read_failed", message = "Could not read directory"}
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	entries := make([dynamic]Bridge_Fs_Entry)
	truncated := false
	for info in infos {
		if len(entries) >= BRIDGE_FS_MAX_ENTRIES { truncated = true; break }
		name := info.name
		if name == "" || name == "." || name == ".." do continue
		is_dir := info.type == .Directory
		has_git := false
		if is_dir {
			git_dir := strings.concatenate({info.fullpath, "/.git"}, context.allocator)
			has_git = os.exists(git_dir)
			delete(git_dir)
		}
		append(&entries, Bridge_Fs_Entry{
			name    = strings.clone(name),
			is_dir  = is_dir,
			hidden  = len(name) > 0 && name[0] == '.',
			has_git = has_git,
		})
	}
	parent := ""
	if canonical != bridge_fs_root {
		p := filepath.dir(canonical)
		if bridge_fs_is_within_root(p) || p == bridge_fs_root do parent = p
	}
	return Bridge_Fs_List_Result{
		ok = true, path = canonical, root = bridge_fs_root, parent = parent,
		entries = entries[:], truncated = truncated,
	}
}

bridge_fs_stat :: proc(requested: string) -> Bridge_Fs_Stat_Result {
	canonical, within := bridge_fs_resolve_within(requested)
	if !within {
		return Bridge_Fs_Stat_Result{ok = true, path = requested, exists = false, within_root = false, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	exists := os.exists(canonical)
	is_dir := exists && os.is_dir(canonical)
	has_git := is_dir && bridge_path_has_git_root(canonical)
	return Bridge_Fs_Stat_Result{ok = true, path = canonical, exists = exists, is_dir = is_dir, has_git = has_git, within_root = true}
}

bridge_fs_make_dir :: proc(requested: string) -> Bridge_Fs_Mkdir_Result {
	canonical, within := bridge_fs_resolve_within(requested)
	if !within {
		return Bridge_Fs_Mkdir_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if os.exists(canonical) {
		if os.is_dir(canonical) {
			return Bridge_Fs_Mkdir_Result{ok = true, path = canonical, created = false, within_root = true}
		}
		return Bridge_Fs_Mkdir_Result{ok = false, path = canonical, within_root = true, error_code = "path_exists_not_dir", message = "A non-directory already exists at this path"}
	}
	if err := os.make_directory_all(canonical); err != nil {
		return Bridge_Fs_Mkdir_Result{ok = false, path = canonical, within_root = true, error_code = "mkdir_failed", message = "Could not create directory"}
	}
	return Bridge_Fs_Mkdir_Result{ok = true, path = canonical, created = true, within_root = true}
}

// --- WS command handling (Hub -> Bridge) ---------------------------------

// bridge_fs_handle_command dispatches the fs_* command types over the runtime WS.
// Returns true if `type` was an fs command (handled), false otherwise. Results are
// cached by command_id for idempotent replay, matching the other command handlers.
bridge_fs_handle_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	switch type {
	case "fs_list_dir":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		path := extract_json_string(text, "path", "")
		result := bridge_fs_list_dir(path)
		out := bridge_fs_list_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	case "fs_stat":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		path := extract_json_string(text, "path", "")
		result := bridge_fs_stat(path)
		out := bridge_fs_stat_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	case "fs_make_dir":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		path := extract_json_string(text, "path", "")
		result := bridge_fs_make_dir(path)
		out := bridge_fs_mkdir_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	}
	return false
}

bridge_fs_list_result_json :: proc(command_id: string, r: Bridge_Fs_List_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fs_list_dir_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"path\":\""); json_write_string(&b, r.path)
	strings.write_string(&b, "\",\"root\":\""); json_write_string(&b, r.root)
	strings.write_string(&b, "\",\"parent\":\""); json_write_string(&b, r.parent)
	strings.write_string(&b, "\",\"truncated\":"); strings.write_string(&b, "true" if r.truncated else "false")
	strings.write_string(&b, ",\"entries\":[")
	for e, i in r.entries {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"name\":\""); json_write_string(&b, e.name)
		strings.write_string(&b, "\",\"is_dir\":"); strings.write_string(&b, "true" if e.is_dir else "false")
		strings.write_string(&b, ",\"hidden\":"); strings.write_string(&b, "true" if e.hidden else "false")
		strings.write_string(&b, ",\"has_git\":"); strings.write_string(&b, "true" if e.has_git else "false")
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "],\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_fs_stat_result_json :: proc(command_id: string, r: Bridge_Fs_Stat_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fs_stat_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"path\":\""); json_write_string(&b, r.path)
	strings.write_string(&b, "\",\"exists\":"); strings.write_string(&b, "true" if r.exists else "false")
	strings.write_string(&b, ",\"is_dir\":"); strings.write_string(&b, "true" if r.is_dir else "false")
	strings.write_string(&b, ",\"has_git\":"); strings.write_string(&b, "true" if r.has_git else "false")
	strings.write_string(&b, ",\"within_root\":"); strings.write_string(&b, "true" if r.within_root else "false")
	strings.write_string(&b, ",\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_fs_mkdir_result_json :: proc(command_id: string, r: Bridge_Fs_Mkdir_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fs_make_dir_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"path\":\""); json_write_string(&b, r.path)
	strings.write_string(&b, "\",\"created\":"); strings.write_string(&b, "true" if r.created else "false")
	strings.write_string(&b, ",\"within_root\":"); strings.write_string(&b, "true" if r.within_root else "false")
	strings.write_string(&b, ",\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}
