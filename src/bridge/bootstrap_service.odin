package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import http "odin_test:lib/http_client"

bridge_bootstrap_fetch_and_materialize :: proc(hub_url, bridge_token, instance_id, run_dir, bridge_endpoint, agent_token, provider: string) -> bool {
	if strings.trim_space(hub_url) == "" || strings.trim_space(bridge_token) == "" || strings.trim_space(instance_id) == "" || strings.trim_space(run_dir) == "" do return false
	path := strings.concatenate({"/api/v1/bridge/agent-instances/", instance_id, "/bootstrap"})
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}
	resp, ok := http.request_with_headers_timeout("GET", hub_url, path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok || resp.status != 200 do return false
	_ = os.make_directory_all(run_dir)
	content := extract_json_string(resp.body, "content", strings.concatenate({"# Agent bootstrap\n\nInstance: ", instance_id, "\n"}))
	content = strings.concatenate({content, bridge_bootstrap_ctl_guidance()})
	if os.write_entire_file(strings.concatenate({run_dir, "/AGENTS.md"}), content) != nil do return false
	skill_paths := bridge_bootstrap_write_skills(run_dir, provider, resp.body)
	if !bridge_bootstrap_write_ham_ctl_wrapper(run_dir, bridge_endpoint, agent_token, instance_id) do return false
	manifest := strings.builder_make()
	strings.write_string(&manifest, "{\"agent_instance_id\":\""); strings.write_string(&manifest, instance_id)
	strings.write_string(&manifest, "\",\"managed_files\":[{\"relative_path\":\"AGENTS.md\",\"kind\":\"AGENTS_MD\"},{\"relative_path\":\".heimdall/bin/ham-ctl\",\"kind\":\"CTL_WRAPPER\"}")
	for skill_path in skill_paths {
		strings.write_string(&manifest, ",{\"relative_path\":\""); bridge_bootstrap_json_string(&manifest, skill_path); strings.write_string(&manifest, "\",\"kind\":\"SKILL\"}")
	}
	strings.write_string(&manifest, "]}")
	if os.write_entire_file(strings.concatenate({run_dir, "/heimdall-bootstrap-manifest.json"}), strings.to_string(manifest)) != nil do return false
	return true
}

bridge_bootstrap_write_skills :: proc(run_dir, provider, body: string) -> []string {
	written := make([dynamic]string)
	if skills_array, ok := bridge_provider_json_extract_array(body, "skills"); ok {
		for obj in bridge_provider_json_top_level_objects(skills_array) {
			name := bridge_provider_json_extract_string(obj, "name", "")
			content := bridge_provider_json_extract_string(obj, "content", "")
			path := bridge_bootstrap_skill_relative_path(provider, name)
			if bridge_bootstrap_write_skill_file(run_dir, path, content) do append(&written, path)
		}
	}
	if len(written) == 0 {
		skill_name := extract_json_string(body, "default_skill_name", "heimdall-ctl-communication")
		skill_content := extract_json_string(body, "default_skill_content", "")
		skill_path := bridge_bootstrap_skill_relative_path(provider, skill_name)
		if bridge_bootstrap_write_skill_file(run_dir, skill_path, skill_content) do append(&written, skill_path)
	}
	return written[:]
}

bridge_bootstrap_materialize_local_provider_test :: proc(run_dir, bridge_endpoint, agent_token, instance_id, provider: string) -> bool {
	if strings.trim_space(run_dir) == "" || strings.trim_space(bridge_endpoint) == "" || strings.trim_space(agent_token) == "" || strings.trim_space(instance_id) == "" do return false
	_ = os.make_directory_all(run_dir)
	content := strings.concatenate({"# Provider test bootstrap\n\nInstance: ", instance_id, "\nProvider: ", provider, "\n\nThis is a temporary Heimdall provider smoke-test run. Report readiness with `./.heimdall/bin/ham-ctl agent start-success` after the provider is usable.\n", bridge_bootstrap_ctl_guidance()})
	if os.write_entire_file(strings.concatenate({strings.trim_right(run_dir, "/"), "/AGENTS.md"}), content) != nil do return false
	if !bridge_bootstrap_write_ham_ctl_wrapper(run_dir, bridge_endpoint, agent_token, instance_id) do return false
	manifest := strings.builder_make()
	strings.write_string(&manifest, "{\"agent_instance_id\":\""); strings.write_string(&manifest, instance_id)
	strings.write_string(&manifest, "\",\"provider_test\":true,\"managed_files\":[{\"relative_path\":\"AGENTS.md\",\"kind\":\"AGENTS_MD\"},{\"relative_path\":\".heimdall/bin/ham-ctl\",\"kind\":\"CTL_WRAPPER\"}]}")
	if os.write_entire_file(strings.concatenate({strings.trim_right(run_dir, "/"), "/heimdall-bootstrap-manifest.json"}), strings.to_string(manifest)) != nil do return false
	return true
}

// bridge_bootstrap_free_object_slice frees a []string of cloned JSON objects
// (as returned by bridge_provider_json_top_level_objects): both each element and
// the backing slice.
bridge_bootstrap_free_object_slice :: proc(objs: []string) {
	for o in objs do delete(o)
	delete(objs)
}

bridge_bootstrap_skill_relative_path :: proc(provider, skill_name: string) -> string {
	profile, ok := bridge_provider_by_name_or_default(provider)
	skill_dir := ""
	if ok do skill_dir = strings.trim_space(profile.skill_dir)
	if skill_dir == "" do skill_dir = bridge_provider_default_skill_dir(provider)
	if skill_dir == "" do return ""
	name := bridge_bootstrap_safe_path_part(skill_name)
	if name == "" do name = "heimdall-ctl-communication"
	return strings.concatenate({strings.trim_right(skill_dir, "/"), "/", name, "/SKILL.md"})
}

bridge_bootstrap_safe_path_part :: proc(value: string) -> string {
	b := strings.builder_make()
	for ch in strings.trim_space(value) {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-': strings.write_rune(&b, ch)
		case '_', ' ', '.': strings.write_byte(&b, '-')
		case:
		}
	}
	return strings.to_string(b)
}

bridge_bootstrap_write_skill_file :: proc(run_dir, relative_path, content: string) -> bool {
	if strings.trim_space(relative_path) == "" || strings.trim_space(content) == "" do return false
	if strings.has_prefix(relative_path, "/") || strings.contains(relative_path, "..") do return false
	full_path := strings.concatenate({strings.trim_right(run_dir, "/"), "/", relative_path})
	if slash := strings.last_index_byte(full_path, '/'); slash > 0 {
		_ = os.make_directory_all(full_path[:slash])
	}
	return os.write_entire_file(full_path, content) == nil
}

bridge_bootstrap_json_string :: proc(b: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(b, "\\\\")
		case '"': strings.write_string(b, "\\\"")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case: strings.write_rune(b, ch)
		}
	}
}

bridge_bootstrap_ctl_guidance :: proc() -> string {
	return "\n\n## Heimdall CLI\n\nUse the managed CLI at `./.heimdall/bin/ham-ctl` for Heimdall actions from this run directory. Examples:\n\n```bash\n./.heimdall/bin/ham-ctl agent start-success\n./.heimdall/bin/ham-ctl agent chat read\n./.heimdall/bin/ham-ctl agent chat send --body \"...\"\n```\n\nThe bridge also exports `HEIMDALL_AGENT_TOKEN` and `HEIMDALL_AGENT_INSTANCE_ID` in your process environment.\n"
}

bridge_bootstrap_write_ham_ctl_wrapper :: proc(run_dir, bridge_endpoint, agent_token, instance_id: string) -> bool {
	ctl := bridge_bootstrap_ham_ctl_path()
	if strings.trim_space(ctl) == "" {
		fmt.eprintln("bridge bootstrap failed: ham-ctl not found; set [wrapper].ham_ctl_bin or HEIMDALL_HAM_CTL_BIN")
		return false
	}
	bin_dir := strings.concatenate({strings.trim_right(run_dir, "/"), "/.heimdall/bin"})
	_ = os.make_directory_all(bin_dir)
	wrapper_path := strings.concatenate({bin_dir, "/ham-ctl"})
	_ = posix.unlink(cstring(raw_data(wrapper_path)))
	b := strings.builder_make()
	strings.write_string(&b, "#!/bin/sh\n")
	strings.write_string(&b, "export HEIMDALL_BRIDGE_ENDPOINT="); bridge_bootstrap_shell_quote(&b, bridge_endpoint); strings.write_byte(&b, '\n')
	strings.write_string(&b, "export HEIMDALL_AGENT_TOKEN="); bridge_bootstrap_shell_quote(&b, agent_token); strings.write_byte(&b, '\n')
	strings.write_string(&b, "export HEIMDALL_AGENT_INSTANCE_ID="); bridge_bootstrap_shell_quote(&b, instance_id); strings.write_byte(&b, '\n')
	strings.write_string(&b, "exec "); bridge_bootstrap_shell_quote(&b, ctl); strings.write_string(&b, " \"$@\"\n")
	if os.write_entire_file(wrapper_path, strings.to_string(b)) != nil do return false
	_ = posix.chmod(cstring(raw_data(wrapper_path)), posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	return true
}

bridge_bootstrap_shell_quote :: proc(b: ^strings.Builder, value: string) {
	strings.write_byte(b, '\'')
	for ch in value {
		if ch == '\'' {
			strings.write_string(b, "'\\''")
		} else {
			strings.write_rune(b, ch)
		}
	}
	strings.write_byte(b, '\'')
}

bridge_bootstrap_ham_ctl_path :: proc() -> string {
	if configured := bridge_bootstrap_normalize_executable_path(bridge_config.ham_ctl_bin); configured != "" do return configured
	if v := os.get_env_alloc("HEIMDALL_HAM_CTL_BIN", context.allocator); strings.trim_space(v) != "" {
		if normalized := bridge_bootstrap_normalize_executable_path(v); normalized != "" do return normalized
	}
	if found := bridge_bootstrap_find_on_path("ham-ctl"); found != "" do return found
	return ""
}

bridge_bootstrap_normalize_executable_path :: proc(value: string) -> string {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return ""
	if strings.contains(trimmed, "/") {
		expanded := bridge_expand_home(trimmed)
		if absolute, err := os.get_absolute_path(expanded, context.allocator); err == nil && strings.trim_space(absolute) != "" do return absolute
		return expanded
	}
	return bridge_bootstrap_find_on_path(trimmed)
}

bridge_bootstrap_find_on_path :: proc(name: string) -> string {
	path := os.get_env_alloc("PATH", context.allocator)
	start := 0
	for start <= len(path) {
		end_rel := strings.index_byte(path[start:], ':')
		end := len(path)
		if end_rel >= 0 do end = start + end_rel
		dir := path[start:end]
		if strings.trim_space(dir) != "" {
			candidate := strings.concatenate({strings.trim_right(dir, "/"), "/", name})
			if _, err := os.stat(candidate, context.allocator); err == nil {
				if absolute, abs_err := os.get_absolute_path(candidate, context.allocator); abs_err == nil && strings.trim_space(absolute) != "" do return absolute
				return candidate
			}
		}
		if end_rel < 0 do break
		start = end + 1
	}
	return ""
}

bootstrap_global_cache: Bootstrap_Cache

bridge_bootstrap_fetch_manifest_and_materialize :: proc(hub_url, bridge_token, instance_id, run_dir, bridge_endpoint, agent_token, provider: string, cache: ^Bootstrap_Cache) -> bool {
	if strings.trim_space(hub_url) == "" || strings.trim_space(bridge_token) == "" || strings.trim_space(instance_id) == "" || strings.trim_space(run_dir) == "" do return false
	path := strings.concatenate({"/api/v1/bridge/agent-instances/", instance_id, "/bootstrap?format=manifest"})
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}
	resp, ok := http.request_with_headers_timeout("GET", hub_url, path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok || resp.status != 200 do return false

	data_obj, data_ok := bridge_provider_json_extract_object(resp.body, "data")
	if !data_ok do return false
	protocol, _ := bridge_provider_json_extract_int(data_obj, "protocol")
	if protocol != 2 do return false

	files_array, files_ok := bridge_provider_json_extract_array(data_obj, "files")
	if !files_ok do return false

	skills_array, _ := bridge_provider_json_extract_array(data_obj, "skills")

	// top_level_objects returns freshly-cloned object substrings; free each slice
	// (and its elements) at function end. Scalars extracted below (hashes, names)
	// are freed where they are transient; hashes retained in needed_hashes are
	// freed via that array's element cleanup.
	file_objs := bridge_provider_json_top_level_objects(files_array)
	defer bridge_bootstrap_free_object_slice(file_objs)
	agents_md_assembly := ""
	for f_obj in file_objs {
		kind := bridge_provider_json_extract_string(f_obj, "kind", "")
		if kind == "AGENTS_MD" {
			if ass_arr, got_ass := bridge_provider_json_extract_array(f_obj, "assembly"); got_ass {
				agents_md_assembly = ass_arr
			}
		}
		delete(kind)
	}
	if agents_md_assembly == "" do return false

	// needed_hashes owns its hash strings (delete(dynamic) frees only the backing
	// array). missing_hashes holds ALIASES of needed_hashes entries, so we free
	// only its array, never its elements, to avoid a double free.
	needed_hashes := make([dynamic]string)
	defer { for h in needed_hashes do delete(h); delete(needed_hashes) }
	missing_hashes := make([dynamic]string)
	defer delete(missing_hashes)

	assembly_objs := bridge_provider_json_top_level_objects(agents_md_assembly)
	defer bridge_bootstrap_free_object_slice(assembly_objs)
	for item_obj in assembly_objs {
		h := bridge_provider_json_extract_string(item_obj, "hash", "")
		if h != "" {
			append(&needed_hashes, h)
			if cache != nil && !bootstrap_cache_has(cache, h) {
				append(&missing_hashes, h)
			}
		} else {
			delete(h)
		}
	}

	skill_objs := bridge_provider_json_top_level_objects(skills_array)
	defer bridge_bootstrap_free_object_slice(skill_objs)
	for s_obj in skill_objs {
		h := bridge_provider_json_extract_string(s_obj, "hash", "")
		if h != "" {
			append(&needed_hashes, h)
			if cache != nil && !bootstrap_cache_has(cache, h) {
				append(&missing_hashes, h)
			}
		} else {
			delete(h)
		}
	}

	if len(missing_hashes) > 0 {
		req_b := strings.builder_make()
		strings.write_string(&req_b, "{\"hashes\":[")
		for m_hash, i in missing_hashes {
			if i > 0 do strings.write_byte(&req_b, ',')
			strings.write_byte(&req_b, '"')
			bridge_bootstrap_json_string(&req_b, m_hash)
			strings.write_byte(&req_b, '"')
		}
		strings.write_string(&req_b, "]}")
		blob_body := strings.to_string(req_b)

		post_resp, post_ok := http.request_with_headers_timeout("POST", hub_url, "/api/v1/bridge/blobs", blob_body, headers[:], http.DEFAULT_TIMEOUT_MS)
		if !post_ok || post_resp.status != 200 do return false
		defer delete(post_resp.body)

		post_data_obj, post_data_ok := bridge_provider_json_extract_object(post_resp.body, "data")
		if !post_data_ok {
			post_data_obj, post_data_ok = bridge_provider_json_extract_object(post_resp.body, "")
			if !post_data_ok do return false
		}

		blobs_array, blobs_ok := bridge_provider_json_extract_array(post_data_obj, "blobs")
		if !blobs_ok do return false

		missing_resp_array, _ := bridge_provider_json_extract_array(post_data_obj, "missing")
		if missing_resp_array != "" {
			missing_parsed := bridge_provider_json_parse_string_array(missing_resp_array)
			defer {
				for item in missing_parsed do delete(item)
				delete(missing_parsed)
			}
			if len(missing_parsed) > 0 do return false
		}

		blob_objs := bridge_provider_json_top_level_objects(blobs_array)
		defer bridge_bootstrap_free_object_slice(blob_objs)
		for b_obj in blob_objs {
			b_hash := bridge_provider_json_extract_string(b_obj, "hash", "")
			b_content := bridge_provider_json_extract_string(b_obj, "body", "")
			if cache != nil {
				if !bootstrap_cache_put(cache, b_hash, b_content) { delete(b_hash); delete(b_content); return false }
			}
			delete(b_hash); delete(b_content)
		}
	}

	agents_md_b := strings.builder_make()
	defer strings.builder_destroy(&agents_md_b)
	for item_obj in assembly_objs {
		inline_str := bridge_provider_json_extract_string(item_obj, "inline", "")
		if inline_str != "" {
			strings.write_string(&agents_md_b, inline_str)
			delete(inline_str)
		} else {
			delete(inline_str)
			h := bridge_provider_json_extract_string(item_obj, "hash", "")
			if h != "" {
				if cache != nil {
					body, found := bootstrap_cache_get(cache, h)
					if !found { delete(h); return false }
					strings.write_string(&agents_md_b, body)
					delete(body)
				}
			}
			delete(h)
		}
	}
	strings.write_string(&agents_md_b, bridge_bootstrap_ctl_guidance())

	_ = os.make_directory_all(run_dir)
	agents_md_path := strings.concatenate({run_dir, "/AGENTS.md"})
	defer delete(agents_md_path)
	if os.write_entire_file(agents_md_path, strings.to_string(agents_md_b)) != nil do return false

	written_skills := make([dynamic]string)
	defer { for p in written_skills do delete(p); delete(written_skills) }
	for s_obj in skill_objs {
		name := bridge_provider_json_extract_string(s_obj, "name", "")
		h := bridge_provider_json_extract_string(s_obj, "hash", "")
		content := ""
		if cache != nil {
			got, found := bootstrap_cache_get(cache, h)
			if !found { delete(name); delete(h); return false }
			content = got
		}
		path := bridge_bootstrap_skill_relative_path(provider, name)
		if bridge_bootstrap_write_skill_file(run_dir, path, content) { append(&written_skills, path) } else { delete(path) }
		if content != "" do delete(content)
		delete(name); delete(h)
	}

	if !bridge_bootstrap_write_ham_ctl_wrapper(run_dir, bridge_endpoint, agent_token, instance_id) do return false

	manifest := strings.builder_make()
	defer strings.builder_destroy(&manifest)
	strings.write_string(&manifest, "{\"agent_instance_id\":\""); strings.write_string(&manifest, instance_id)
	strings.write_string(&manifest, "\",\"managed_files\":[{\"relative_path\":\"AGENTS.md\",\"kind\":\"AGENTS_MD\"},{\"relative_path\":\".heimdall/bin/ham-ctl\",\"kind\":\"CTL_WRAPPER\"}")
	for skill_path in written_skills {
		strings.write_string(&manifest, ",{\"relative_path\":\""); bridge_bootstrap_json_string(&manifest, skill_path); strings.write_string(&manifest, "\",\"kind\":\"SKILL\"}")
	}
	strings.write_string(&manifest, "]}")
	manifest_path := strings.concatenate({run_dir, "/heimdall-bootstrap-manifest.json"})
	defer delete(manifest_path)
	if os.write_entire_file(manifest_path, strings.to_string(manifest)) != nil do return false

	return true
}
