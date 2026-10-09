package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import ws "odin_test:lib/ws"

Bridge_Provider_Path :: struct {
	provider:      string `json:"provider"`,
	resolved_path: string `json:"resolved_path"`,
	version_text:  string `json:"version_text"`,
	probed_at:     string `json:"probed_at"`,
	state:         string `json:"state"`,
}

Bridge_Provider_Path_Store_Wire :: struct {
	providers: []Bridge_Provider_Path `json:"providers"`,
}

Bridge_Provider_Probe_Target :: struct { provider, binary: string }

bridge_provider_paths_mutex: sync.RW_Mutex
bridge_provider_paths_loaded: bool
bridge_provider_paths: [dynamic]Bridge_Provider_Path

bridge_provider_paths_path :: proc() -> string {
	data_dir := strings.trim_space(bridge_config.data_dir)
	if data_dir == "" do data_dir = "~/.local/share/heimdall"
	expanded := bridge_expand_home(data_dir)
	defer if raw_data(expanded) != raw_data(data_dir) do delete(expanded)
	return strings.concatenate({strings.trim_right(expanded, "/"), "/bridge/provider_paths.json"})
}

bridge_provider_probe_time :: proc() -> string {
	year, month, day := time.date(time.now())
	hour, minute, second := time.clock(time.now())
	// Provider probe records are persisted and explicitly destroyed. Use an owned
	// allocation; tprintf uses the temporary allocator and becomes an invalid free
	// when a stale/missing provider record is cleaned up after re-probing.
	return fmt.aprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", year, int(month), day, hour, minute, second)
}

bridge_provider_path_clone :: proc(value: Bridge_Provider_Path, allocator := context.allocator) -> Bridge_Provider_Path {
	return Bridge_Provider_Path{
		provider = strings.clone(value.provider, allocator),
		resolved_path = strings.clone(value.resolved_path, allocator),
		version_text = strings.clone(value.version_text, allocator),
		probed_at = strings.clone(value.probed_at, allocator),
		state = strings.clone(value.state, allocator),
	}
}

bridge_provider_path_destroy :: proc(value: ^Bridge_Provider_Path, allocator := context.allocator) {
	if value == nil do return
	delete(value.provider, allocator)
	delete(value.resolved_path, allocator)
	delete(value.version_text, allocator)
	delete(value.probed_at, allocator)
	delete(value.state, allocator)
	value^ = {}
}

bridge_provider_path_executable :: proc(path: string) -> bool {
	if strings.trim_space(path) == "" do return false
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	return posix.access(c_path, {.X_OK}) == .OK
}

bridge_provider_probe_version :: proc(path: string) -> string {
	if path == "" do return ""
	argv := []string{path, "--version"}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = argv}, context.allocator)
	defer if len(stdout) > 0 do delete(stdout)
	defer if len(stderr) > 0 do delete(stderr)
	if err != nil || !state.success do return ""
	text := strings.trim_space(string(stdout))
	if newline := strings.index_byte(text, '\n'); newline >= 0 do text = text[:newline]
	if len(text) > 256 do text = text[:256]
	return strings.clone(text)
}

bridge_provider_probe_one :: proc(provider, binary: string) -> Bridge_Provider_Path {
	path := bridge_runtime_find_on_path(binary)
	if path != "" && !bridge_provider_path_executable(path) {
		delete(path)
		path = ""
	}
	version := bridge_provider_probe_version(path)
	return Bridge_Provider_Path{
		provider = strings.clone(provider),
		resolved_path = path,
		version_text = version,
		probed_at = bridge_provider_probe_time(),
		state = strings.clone("present" if path != "" else "absent"),
	}
}

bridge_provider_probe_targets :: proc(filter: []string) -> [dynamic]Bridge_Provider_Probe_Target {
	bridge_provider_catalog_init()
	targets := make([dynamic]Bridge_Provider_Probe_Target)
	sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_snapshot == nil do return targets
	for provider in bridge_provider_catalog_snapshot.providers {
		selected := len(filter) == 0
		for wanted in filter {
			if wanted == provider.provider { selected = true; break }
		}
		if selected {
			append(&targets, Bridge_Provider_Probe_Target{
				provider = strings.clone(provider.provider),
				binary = strings.clone(provider.binary),
			})
		}
	}
	return targets
}

bridge_provider_paths_save_unlocked :: proc() -> bool {
	path := bridge_provider_paths_path()
	defer delete(path)
	if slash := strings.last_index_byte(path, '/'); slash > 0 do _ = os.make_directory_all(path[:slash])
	wire := Bridge_Provider_Path_Store_Wire{providers = bridge_provider_paths[:]}
	bytes, err := json.marshal(wire, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil do return false
	tmp := strings.concatenate({path, ".tmp"})
	defer delete(tmp)
	if os.write_entire_file(tmp, bytes) != nil do return false
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

bridge_provider_paths_init :: proc() {
	sync.rw_mutex_lock(&bridge_provider_paths_mutex)
	defer sync.rw_mutex_unlock(&bridge_provider_paths_mutex)
	if bridge_provider_paths_loaded do return
	bridge_provider_paths_loaded = true
	bridge_provider_paths = make([dynamic]Bridge_Provider_Path, runtime.default_allocator())
	path := bridge_provider_paths_path()
	defer delete(path)
	raw, err := os.read_entire_file(path, runtime.default_allocator())
	if err != nil do return
	defer delete(raw, runtime.default_allocator())
	wire: Bridge_Provider_Path_Store_Wire
	if decode_err := json.unmarshal(raw, &wire, json.DEFAULT_SPECIFICATION, runtime.default_allocator()); decode_err != nil do return
	for item in wire.providers {
		if bridge_provider_catalog_name_supported(item.provider) && (item.state == "present" || item.state == "absent") {
			append(&bridge_provider_paths, item)
		}
	}
}

bridge_provider_paths_upsert_unlocked :: proc(value: Bridge_Provider_Path) {
	for i in 0..<len(bridge_provider_paths) {
		if bridge_provider_paths[i].provider == value.provider {
			bridge_provider_path_destroy(&bridge_provider_paths[i], runtime.default_allocator())
			bridge_provider_paths[i] = value
			return
		}
	}
	append(&bridge_provider_paths, value)
}

bridge_provider_discover :: proc(filter: []string) -> [dynamic]Bridge_Provider_Path {
	bridge_provider_paths_init()
	targets := bridge_provider_probe_targets(filter)
	defer {
		for target in targets { delete(target.provider); delete(target.binary) }
		delete(targets)
	}
	results := make([dynamic]Bridge_Provider_Path)
	for target in targets do append(&results, bridge_provider_probe_one(target.provider, target.binary))

	sync.rw_mutex_lock(&bridge_provider_paths_mutex)
	for result in results do bridge_provider_paths_upsert_unlocked(bridge_provider_path_clone(result, runtime.default_allocator()))
	_ = bridge_provider_paths_save_unlocked()
	sync.rw_mutex_unlock(&bridge_provider_paths_mutex)
	return results
}

bridge_provider_discovery_report_json :: proc(request_id: string, results: [dynamic]Bridge_Provider_Path) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"provider_discovery_report\",\"request_id\":\"")
	bridge_runtime_write_json_string(&b, request_id)
	strings.write_string(&b, "\",\"command_id\":\"")
	bridge_runtime_write_json_string(&b, request_id)
	strings.write_string(&b, "\",\"providers\":[")
	for result, i in results {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"provider\":\""); bridge_runtime_write_json_string(&b, result.provider)
		strings.write_string(&b, "\",\"binary_path\":\""); bridge_runtime_write_json_string(&b, result.resolved_path)
		strings.write_string(&b, "\",\"version_text\":\""); bridge_runtime_write_json_string(&b, result.version_text)
		strings.write_string(&b, "\",\"state\":\""); bridge_runtime_write_json_string(&b, result.state)
		strings.write_string(&b, "\",\"checked_at\":\""); bridge_runtime_write_json_string(&b, result.probed_at)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

bridge_provider_handle_discover_frame :: proc(conn: ^ws.Connection, frame_type, text: string) -> bool {
	if frame_type != "provider_discover" do return false
	request_id := extract_json_string(text, "request_id", "")
	defer delete(request_id)
	filter, _ := bridge_provider_json_extract_string_array(text, "providers")
	defer {
		for item in filter do delete(item)
		delete(filter)
	}
	results := bridge_provider_discover(filter)
	defer {
		for &result in results do bridge_provider_path_destroy(&result)
		delete(results)
	}
	report := bridge_provider_discovery_report_json(request_id, results)
	defer delete(report)
	_ = bridge_hub_send(conn, report)
	return true
}

bridge_provider_resolve_path :: proc(provider: string) -> (string, bool) {
	bridge_provider_paths_init()
	sync.rw_mutex_shared_lock(&bridge_provider_paths_mutex)
	for item in bridge_provider_paths {
		if item.provider == provider && item.state == "present" && bridge_provider_path_executable(item.resolved_path) {
			path := strings.clone(item.resolved_path)
			sync.rw_mutex_shared_unlock(&bridge_provider_paths_mutex)
			return path, true
		}
	}
	sync.rw_mutex_shared_unlock(&bridge_provider_paths_mutex)

	filter := []string{provider}
	results := bridge_provider_discover(filter)
	defer {
		for &result in results do bridge_provider_path_destroy(&result)
		delete(results)
	}
	if len(results) == 1 && results[0].state == "present" do return strings.clone(results[0].resolved_path), true
	return "", false
}
