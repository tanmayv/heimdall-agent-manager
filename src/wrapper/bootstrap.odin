package main

// WRP-1 / PROV-1: the wrapper materializes its own run_dir by a pure,
// list-driven FETCH-AND-PLACE loop over the bridge local socket. Zero hub calls,
// zero assembly (the bridge assembles AGENTS.md + renders the ctl shim and serves
// FINISHED content):
//
//   1. wrapper.bootstrap.list  -> {files:[{file_id,kind,relative_path,mode}], layout:{provider,bootstrap_file_name,skill_dir}}
//   2. for each file: wrapper.bootstrap.file{file_id} -> {content, relative_path, mode, kind}
//   3. write content to run_dir/<placement(kind, relative_path, layout)>; chmod +x for CTL_WRAPPER.
//
// The wrapper OWNS kind->path placement, computed from the provider layout
// override values delivered as data (layout.bootstrap_file_name, layout.skill_dir);
// the bridge-resolved relative_path is a pure fallback (never the source of truth
// for the provider-specific bootstrap filename).

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

WRAPPER_BOOTSTRAP_MAX_ATTEMPTS :: 4
WRAPPER_BOOTSTRAP_BASE_BACKOFF_MS :: 150

// wrapper_bridge_materialize_bootstrap drives the full list->file->place loop.
// Before fetching it DELETES the entire run_dir so the directory is always empty
// before materialisation — this is simpler and more correct than diffing a prior
// placement record: no stale files (old CLAUDE.md, removed skills, etc.) can
// ever be left behind regardless of why the previous launch ended.
// Returns false (with a diagnostic on stderr) if the instance has no published
// file set or any file cannot be fetched/written after retries.
wrapper_bridge_materialize_bootstrap :: proc(cfg: Bridge_Runtime_Config) -> bool {
	run_dir := strings.trim_right(cfg.working_dir, "/")
	if run_dir == "" {
		fmt.eprintln("ham-wrapper bootstrap: empty run_dir")
		return false
	}
	// Nuke then recreate — guarantees a clean slate on every (re)launch.
	wrapper_bootstrap_rmdir_all(run_dir)
	_ = os.make_directory_all(run_dir)

	list_resp, list_ok := wrapper_bridge_bootstrap_call_retry(cfg, "wrapper.bootstrap.list", "{}")
	if !list_ok {
		fmt.eprintln("ham-wrapper bootstrap: bootstrap.list failed after retries")
		return false
	}
	defer delete(list_resp)
	data := extract_json_object(list_resp, "data")
	if data == "" {
		fmt.eprintln("ham-wrapper bootstrap: bootstrap.list response missing data")
		return false
	}
	defer delete(data)
	layout := extract_json_object(data, "layout")
	defer if layout != "" do delete(layout)
	provider := extract_json_string(layout, "provider", cfg.provider)
	defer delete(provider)
	bootstrap_file_name := extract_json_string(layout, "bootstrap_file_name", "")
	defer delete(bootstrap_file_name)
	skill_dir := extract_json_string(layout, "skill_dir", "")
	defer delete(skill_dir)

	files_array := extract_json_array(data, "files")
	if files_array == "" {
		fmt.eprintln("ham-wrapper bootstrap: bootstrap.list response missing files array")
		return false
	}
	defer delete(files_array)
	items := wrapper_bootstrap_split_objects(files_array)
	defer { for it in items do delete(it); delete(items) }
	if len(items) == 0 {
		fmt.eprintln("ham-wrapper bootstrap: empty file list")
		return false
	}

	for item in items {
		file_id := extract_json_string(item, "file_id", "")
		kind := extract_json_string(item, "kind", "")
		relative_path := extract_json_string(item, "relative_path", "")
		defer { delete(file_id); delete(kind); delete(relative_path) }
		if strings.trim_space(file_id) == "" do continue

		// Fetch the FINISHED content for this file (individually retriable).
		params := strings.concatenate({"{\"file_id\":\"", wrapper_bootstrap_json_escape(file_id), "\"}"})
		file_resp, file_ok := wrapper_bridge_bootstrap_call_retry(cfg, "wrapper.bootstrap.file", params)
		delete(params)
		if !file_ok {
			fmt.eprintln("ham-wrapper bootstrap: bootstrap.file failed for", file_id)
			return false
		}
		fdata := extract_json_object(file_resp, "data")
		delete(file_resp)
		if fdata == "" {
			fmt.eprintln("ham-wrapper bootstrap: bootstrap.file response missing data for", file_id)
			return false
		}
		content := extract_json_string(fdata, "content", "")
		mode := extract_json_int(fdata, "mode", 0o644)
		delete(fdata)

		// Wrapper OWNS placement: resolve kind->path from the provider layout, using
		// the bridge relative_path only as a fallback.
		target_rel := wrapper_bootstrap_place(kind, relative_path, provider, bootstrap_file_name, skill_dir)
		defer delete(target_rel)
		if !wrapper_bootstrap_write_file(run_dir, target_rel, content, mode) {
			fmt.eprintln("ham-wrapper bootstrap: failed to write", target_rel)
			delete(content)
			return false
		}
		delete(content)
		fmt.eprintln("ham-wrapper bootstrap: placed", kind, "->", target_rel)
	}
	return true
}

// wrapper_bootstrap_rmdir_all removes the entire directory tree rooted at dir
// (best-effort, depth-first). The run_dir is always recreated immediately after
// by the caller so a partial removal is harmless.
wrapper_bootstrap_rmdir_all :: proc(dir: string) {
	fd, err := os.open(dir)
	if err != nil do return
	infos, rerr := os.read_dir(fd, -1, context.allocator)
	os.close(fd)
	if rerr == nil {
		for info in infos {
			full := strings.concatenate({dir, "/", info.name})
			if info.type == .Directory { wrapper_bootstrap_rmdir_all(full) } else { _ = os.remove(full) }
			delete(full)
		}
		delete(infos)
	}
	_ = os.remove(dir)
}

// wrapper_bootstrap_place resolves the run-dir-relative path for a file kind.
// The wrapper is the placement authority (PROV-1): it derives provider-specific
// paths from the layout override values, falling back to the bridge-resolved
// relative_path only when it has nothing better.
wrapper_bootstrap_place :: proc(kind, relative_path, provider, bootstrap_file_name, skill_dir: string) -> string {
	switch kind {
	case "AGENTS_MD":
		name := strings.trim_space(bootstrap_file_name)
		if name != "" && wrapper_bootstrap_is_safe_name(name) do return strings.clone(name)
		if strings.to_lower(strings.trim_space(provider)) == "claude" do return strings.clone("CLAUDE.md")
		if strings.trim_space(relative_path) != "" do return strings.clone(relative_path)
		return strings.clone("AGENTS.md")
	case "CTL_WRAPPER":
		return strings.clone(".heimdall/bin/ham-ctl")
	case "SKILL":
		// Rebuild <skill_dir>/<skill-name>/SKILL.md from the layout override + the
		// skill name recovered from the bridge relative_path basename dir. Fall back
		// to the bridge relative_path when we cannot improve on it.
		dir := strings.trim_space(skill_dir)
		name := wrapper_bootstrap_skill_name_from_path(relative_path)
		if dir != "" && name != "" {
			return strings.concatenate({strings.trim_right(dir, "/"), "/", name, "/SKILL.md"})
		}
		if strings.trim_space(relative_path) != "" do return strings.clone(relative_path)
		return ""
	case:
		// MANIFEST and anything else: trust the bridge relative_path.
		if strings.trim_space(relative_path) != "" do return strings.clone(relative_path)
		return ""
	}
}

// wrapper_bootstrap_skill_name_from_path extracts "<name>" from a
// ".../<name>/SKILL.md" relative path. Returns "" if the shape does not match.
wrapper_bootstrap_skill_name_from_path :: proc(relative_path: string) -> string {
	p := strings.trim_right(relative_path, "/")
	if !strings.has_suffix(p, "/SKILL.md") do return ""
	p = p[:len(p) - len("/SKILL.md")]
	if slash := strings.last_index_byte(p, '/'); slash >= 0 do return strings.clone(p[slash + 1:])
	return strings.clone(p)
}

wrapper_bootstrap_is_safe_name :: proc(name: string) -> bool {
	if strings.contains(name, "/") || strings.contains(name, "\\") do return false
	if strings.contains(name, "..") do return false
	if name == "." do return false
	return true
}

// wrapper_bootstrap_write_file writes content to run_dir/relative_path, creating
// parent dirs, rejecting traversal, and chmod 0755 when mode says executable.
wrapper_bootstrap_write_file :: proc(run_dir, relative_path, content: string, mode: int) -> bool {
	if strings.trim_space(relative_path) == "" do return false
	if strings.has_prefix(relative_path, "/") || strings.contains(relative_path, "..") do return false
	full := strings.concatenate({run_dir, "/", relative_path})
	defer delete(full)
	if slash := strings.last_index_byte(full, '/'); slash > 0 do _ = os.make_directory_all(full[:slash])
	if os.write_entire_file(full, content) != nil do return false
	if mode == 0o755 do _ = posix.chmod(cstring(raw_data(full)), posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH})
	return true
}

// wrapper_bridge_bootstrap_call_retry performs a local RPC round-trip with
// retry/backoff, returning (response, true) only for a non-error envelope
// (ok:true). Transport failures and ok:false responses retry (RETRY-1).
wrapper_bridge_bootstrap_call_retry :: proc(cfg: Bridge_Runtime_Config, method, params: string) -> (string, bool) {
	for attempt in 1..=WRAPPER_BOOTSTRAP_MAX_ATTEMPTS {
		resp, got := wrapper_bridge_local_call_response(cfg, method, params)
		if got && strings.contains(resp, "\"ok\":true") do return resp, true
		if got do delete(resp)
		if attempt < WRAPPER_BOOTSTRAP_MAX_ATTEMPTS {
			ms := WRAPPER_BOOTSTRAP_BASE_BACKOFF_MS
			for i in 1..<attempt do ms *= 2
			time.sleep(time.Duration(ms) * time.Millisecond)
		}
	}
	return "", false
}

wrapper_bootstrap_json_escape :: proc(value: string) -> string {
	b := strings.builder_make()
	json_write_string(&b, value)
	return strings.to_string(b)
}

// extract_json_array returns the raw "[...]" text for key (balanced brackets,
// string-aware). Returns "" when absent. Caller owns the returned string.
extract_json_array :: proc(body, key: string) -> string {
	pattern := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return ""
	start := idx + len(pattern)
	for start < len(body) && (body[start] == ' ' || body[start] == '\t' || body[start] == '\n' || body[start] == '\r') do start += 1
	if start >= len(body) || body[start] != '[' do return ""
	depth := 0
	in_string := false
	escaped := false
	i := start
	for i < len(body) {
		ch := body[i]
		if escaped { escaped = false; i += 1; continue }
		if ch == '\\' && in_string { escaped = true; i += 1; continue }
		if ch == '"' { in_string = !in_string; i += 1; continue }
		if !in_string {
			if ch == '[' do depth += 1
			if ch == ']' {
				depth -= 1
				if depth == 0 do return strings.clone(body[start : i + 1])
			}
		}
		i += 1
	}
	return ""
}

// wrapper_bootstrap_split_objects splits a JSON array's top-level {..} objects
// into a slice of cloned substrings (string-aware, brace-balanced).
wrapper_bootstrap_split_objects :: proc(array_text: string) -> [dynamic]string {
	out := make([dynamic]string)
	depth := 0
	in_string := false
	escaped := false
	obj_start := -1
	for i in 0..<len(array_text) {
		ch := array_text[i]
		if escaped { escaped = false; continue }
		if ch == '\\' && in_string { escaped = true; continue }
		if ch == '"' { in_string = !in_string; continue }
		if in_string do continue
		if ch == '{' {
			if depth == 0 do obj_start = i
			depth += 1
		} else if ch == '}' {
			depth -= 1
			if depth == 0 && obj_start >= 0 {
				append(&out, strings.clone(array_text[obj_start : i + 1]))
				obj_start = -1
			}
		}
	}
	return out
}
