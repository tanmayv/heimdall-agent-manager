package main

// Setup discovery returns metadata only, never prompts or session bodies.
import "core:os"
import "core:strings"
import "core:path/filepath"
import json "core:encoding/json"
import cfg_lib "odin_test:lib/config"
import ws "odin_test:lib/ws"

Session_Project :: struct {
	source: string,
	path: string, // Codex cwd, or Claude's encoded project folder name
	sessions: int,
	last_session_at: string,
}
Session_Projects_Result :: struct {
	type: string,
	command_id: string,
	ok: bool,
	projects: [dynamic]Session_Project,
	truncated: bool,
}

// A bounded prefix avoids reading multi-GB conversations. session_meta is normally
// the first line. Malformed lines do not prevent later metadata from being found.
session_project_codex_cwd :: proc(path: string, truncated: ^bool = nil) -> string {
	f, err := os.open(path, {.Read})
	if err != nil do return ""
	defer os.close(f)
	buf := make([]u8, 256 * 1024)
	defer delete(buf)
	used := 0
	for used < len(buf) {
		n, read_err := os.read(f, buf[used:])
		if n > 0 do used += n
		if read_err != nil || n <= 0 do break
	}
	lines := strings.split(string(buf[:used]), "\n")
	defer delete(lines)
	for line in lines {
		meta: struct {type: string, payload: struct {cwd: string}}
		if json.unmarshal_string(line, &meta, json.DEFAULT_SPECIFICATION, context.allocator) != nil {
			delete(meta.type); delete(meta.payload.cwd); continue
		}
		defer { delete(meta.type); delete(meta.payload.cwd) }
		if meta.type == "session_meta" && filepath.is_abs(meta.payload.cwd) do return strings.clone(meta.payload.cwd)
	}
	if used == len(buf) && truncated != nil do truncated^ = true
	return ""
}

// Filesystem canonicalization uses scratch allocations internally. Keep them
// within the worker's temporary arena, returning only the owned resolved path.
session_project_resolve :: proc(path, root: string) -> (string, bool) {
	owned := context.allocator
	context.allocator = context.temp_allocator
	resolved, within := bridge_fs_resolve_within(path, root)
	return strings.clone(resolved, owned), within
}

session_projects_discover :: proc(home, sandbox_root: string, deadline_ns: i64 = 0) -> Session_Projects_Result {
	result := Session_Projects_Result{type = "session_projects_result", ok = true}
	result.projects = make([dynamic]Session_Project)
	// Only fixed provider history roots are accepted. No caller supplied paths.
	remaining := 20_000
	for source in ([]string{"Codex", "Claude Code"}) {
		suffix := "/.codex/sessions" if source == "Codex" else "/.claude/projects"
		requested := strings.concatenate({home, suffix}, context.temp_allocator)
		root, within := session_project_resolve(requested, sandbox_root)
		defer delete(root)
		if !within || !os.is_dir(root) do continue
		queue := make([dynamic]string)
		append(&queue, strings.clone(root))
		defer { for dir in queue do delete(dir); delete(queue) }
		for index := 0; index < len(queue); index += 1 {
			if remaining <= 0 || bridge_command_deadline_expired(deadline_ns) { result.truncated = true; break }
			infos, err := os.read_directory_by_path(queue[index], remaining + 1, context.allocator)
			if err != nil do continue
			for info in infos {
				if remaining <= 0 || bridge_command_deadline_expired(deadline_ns) { result.truncated = true; break }
				remaining -= 1
				// Do not follow symlinks out of history or into cycles.
				if info.type == .Directory {
					if source == "Codex" || index == 0 {
						canonical, allowed := session_project_resolve(info.fullpath, root)
						if allowed && canonical == info.fullpath { append(&queue, canonical) } else { delete(canonical) }
					}
					continue
				}
				if info.type != .Regular || !strings.has_suffix(info.name, ".jsonl") do continue
				path := ""
				if source == "Codex" {
					if !strings.has_prefix(info.name, "rollout-") do continue
					path = session_project_codex_cwd(info.fullpath, &result.truncated)
					if path == "" do continue
					canonical, allowed := session_project_resolve(path, sandbox_root)
					delete(path)
					if !allowed || !os.is_dir(canonical) { delete(canonical); continue }
					path = canonical
				} else {
					if index == 0 do continue
					path = strings.clone(filepath.base(queue[index]))
				}
				found := -1
				for project, i in result.projects {
					if project.source == source && project.path == path { found = i; break }
				}
				if found < 0 {
					append(&result.projects, Session_Project{source = source, path = path})
					found = len(result.projects) - 1
				} else { delete(path) }
				project := &result.projects[found]
				project.sessions += 1
				stamp := strings.clone(bridge_fs_format_mtime(info.modification_time))
				if stamp > project.last_session_at {
					delete(project.last_session_at)
					project.last_session_at = stamp
				} else { delete(stamp) }
			}
			os.file_info_slice_delete(infos, context.allocator)
		}
	}
	return result
}

session_projects_destroy :: proc(result: ^Session_Projects_Result) {
	for project in result.projects { delete(project.path); delete(project.last_session_at) }
	delete(result.projects)
}

bridge_session_projects_handle_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	if type != "session_projects" do return false
	cmd: struct {command_id: string}
	if json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil do return false
	if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
	home := cfg_lib.home_dir(context.temp_allocator)
	result := session_projects_discover(home, bridge_fs_root, bridge_command_worker_deadline_ns(conn))
	defer session_projects_destroy(&result)
	result.command_id = cmd.command_id
	out, err := json.marshal(result)
	if err != nil do return false
	defer delete(out)
	bridge_runtime_cache_command(cmd.command_id, string(out))
	_ = bridge_hub_send(conn, string(out))
	return true
}
