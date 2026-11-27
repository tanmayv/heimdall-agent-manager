package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import ws "odin_test:lib/ws"

Bridge_Provider_Path :: struct {
	profile_id: string `json:"profile_id"`,
	provider:      string `json:"provider"`,
	resolved_path: string `json:"resolved_path"`,
	version_text:  string `json:"version_text"`,
	probed_at:     string `json:"probed_at"`,
	state:         string `json:"state"`,
	// REQ-EXT-DET-1: present|disabled|outdated|absent|error|unsupported.
	extension_state:   string `json:"extension_state"`,
	extension_version: string `json:"extension_version"`,
}

Bridge_Provider_Path_Store_Wire :: struct {
	providers: []Bridge_Provider_Path `json:"providers"`,
}

// extension borrows the immutable, process-lifetime catalog snapshot; it is never freed.
Bridge_Provider_Probe_Target :: struct { provider: string, extension: Bridge_Catalog_Extension }

bridge_provider_paths_mutex: sync.RW_Mutex
bridge_provider_paths_loaded: bool
bridge_provider_paths: [dynamic]Bridge_Provider_Path

Bridge_Provider_Discovery_Group :: struct {
	key: string,
	done: bool,
	refs: int,
	results: [dynamic]Bridge_Provider_Path,
}

bridge_provider_discovery_mutex: sync.Mutex
bridge_provider_discovery_cond: sync.Cond
bridge_provider_discovery_current: ^Bridge_Provider_Discovery_Group
bridge_provider_discovery_scan_count: u64
// Deterministic test seam; production leaves this at zero.
bridge_provider_discovery_test_delay: time.Duration
// Test seam: scans started for exactly this key are counted separately, so a test
// can assert coalescing without picking up scans that unrelated, concurrently running
// tests start. Production leaves the key empty and never counts.
bridge_provider_discovery_test_key: string
bridge_provider_discovery_test_key_scans: u64

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
		profile_id = strings.clone(profile_effective_id(value.provider,value.profile_id),allocator),
		provider = strings.clone(value.provider, allocator),
		resolved_path = strings.clone(value.resolved_path, allocator),
		version_text = strings.clone(value.version_text, allocator),
		probed_at = strings.clone(value.probed_at, allocator),
		state = strings.clone(value.state, allocator),
		extension_state = strings.clone(value.extension_state, allocator),
		extension_version = strings.clone(value.extension_version, allocator),
	}
}

bridge_provider_path_destroy :: proc(value: ^Bridge_Provider_Path, allocator := context.allocator) {
	if value == nil do return
	delete(value.profile_id, allocator)
	delete(value.provider, allocator)
	delete(value.resolved_path, allocator)
	delete(value.version_text, allocator)
	delete(value.probed_at, allocator)
	delete(value.state, allocator)
	delete(value.extension_state, allocator)
	delete(value.extension_version, allocator)
	value^ = {}
}

bridge_provider_path_executable :: proc(path: string) -> bool {
	if strings.trim_space(path) == "" do return false
	return bridge_os_is_executable(path)
}

// bridge_provider_probe_one probes the default profile with binary (a command
// name or path) in place of the provider's own; tests use it directly.
bridge_provider_probe_one :: proc(provider, binary: string, extension: Bridge_Catalog_Extension = {}) -> Bridge_Provider_Path {
	d := bridge_provider_descriptor(provider)
	d.binary = binary
	path, _ := bridge_provider_resolve_binary(d, nil, nil)
	return bridge_provider_probe_one_with_timeout(provider, path, 2 * time.Second, extension, time.time_add(time.now(), 2 * time.Second + BRIDGE_PROVIDER_EXTENSION_TIMEOUT))
}

// path is the binary bridge_provider_resolve_binary resolved ("" when absent);
// this procedure takes ownership of it. extension_deadline bounds the extension
// detector (itself capped at 5s); a zero deadline skips it, which reports an
// unsupported/absent/error state without running.
bridge_provider_probe_one_with_timeout :: proc(provider, path: string, timeout: time.Duration, extension: Bridge_Catalog_Extension = {}, extension_deadline: time.Time = {}, env: []string = nil, profile_id: string = "") -> Bridge_Provider_Path {
	path := path
	if path != "" && !bridge_provider_path_executable(path) {
		delete(path)
		path = ""
	}
	version := ""
	if path != "" && timeout > 0 {
		breaker_key := strings.concatenate({"provider-probe:", profile_id, ":", path})
		defer delete(breaker_key)
		if bridge_dependency_breaker_allow(breaker_key) {
			// version_text stays the raw first line; parsing is the ACP probe's job.
			probe := bridge_provider_cli_version(bridge_provider_descriptor(provider), path, env, timeout)
			delete(probe.parsed)
			version = probe.raw
			bridge_dependency_breaker_record(breaker_key, probe.ok)
		}
	}
	extension_timeout: time.Duration = 0
	if extension_deadline != {} do extension_timeout = time.diff(time.now(), extension_deadline)
	extension_state, extension_version := bridge_provider_extension_probe(path, extension, extension_timeout, env, profile_id)
	return Bridge_Provider_Path{
		profile_id = strings.clone(profile_effective_id(provider,profile_id)),
		provider = strings.clone(provider),
		resolved_path = path,
		version_text = version,
		probed_at = bridge_provider_probe_time(),
		state = strings.clone("present" if path != "" else "absent"),
		extension_state = strings.clone(extension_state),
		extension_version = extension_version,
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
				extension = provider.extension,
			})
		}
	}
	return targets
}

bridge_provider_paths_save_unlocked :: proc() -> bool {
	path := bridge_provider_paths_path()
	defer delete(path)
	if slash := strings.last_index_byte(path, '/'); slash > 0 do _ = bridge_make_directory_all(path[:slash])
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
		if bridge_provider_catalog_name_supported(item.provider) && (item.state == "present" || item.state == "absent" || item.state == "disabled" || item.state == "error") {
			append(&bridge_provider_paths, item)
		}
	}
}

bridge_provider_paths_upsert_unlocked :: proc(value: Bridge_Provider_Path) {
	for i in 0..<len(bridge_provider_paths) {
		if bridge_provider_paths[i].provider == value.provider && profile_effective_id(value.provider,bridge_provider_paths[i].profile_id) == profile_effective_id(value.provider,value.profile_id) {
			bridge_provider_path_destroy(&bridge_provider_paths[i], runtime.default_allocator())
			bridge_provider_paths[i] = value
			return
		}
	}
	append(&bridge_provider_paths, value)
}

bridge_provider_discovery_key :: proc(filter: []string) -> string {
	if len(filter) == 0 do return strings.clone("*")
	canonical := make([dynamic]string)
	defer { for item in canonical do delete(item); delete(canonical) }
	for item in filter do append(&canonical, strings.clone(strings.trim_space(item)))
	slice.sort_by(canonical[:], proc(a, b: string) -> bool { return strings.compare(a, b) < 0 })
	b := strings.builder_make()
	for item, i in canonical {
		if i > 0 do strings.write_byte(&b, 0x1f)
		strings.write_string(&b, item)
	}
	return strings.to_string(b)
}

bridge_provider_discovery_results_clone :: proc(results: []Bridge_Provider_Path, allocator := context.allocator) -> [dynamic]Bridge_Provider_Path {
	out := make([dynamic]Bridge_Provider_Path, 0, len(results), allocator)
	for result in results do append(&out, bridge_provider_path_clone(result, allocator))
	return out
}

bridge_provider_discovery_group_destroy :: proc(group: ^Bridge_Provider_Discovery_Group) {
	if group == nil do return
	alloc := runtime.default_allocator()
	delete(group.key, alloc)
	for &result in group.results do bridge_provider_path_destroy(&result, alloc)
	delete(group.results)
	free(group, alloc)
}

// Time kept back from the extension probe for each provider still to be probed.
BRIDGE_PROVIDER_VERSION_PROBE_RESERVE :: 1 * time.Second

// Upper bound for one discovery scan, so it answers inside the Hub's 10s wait.
BRIDGE_PROVIDER_DISCOVERY_BUDGET :: 8 * time.Second
// Kept back from the Hub's deadline so the report is sent before the Hub gives up.
BRIDGE_PROVIDER_DISCOVERY_REPLY_MARGIN :: 500 * time.Millisecond

bridge_provider_discover_execute :: proc(filter: []string) -> [dynamic]Bridge_Provider_Path {
	return bridge_provider_discover_execute_profile(filter,"")
}
// deadline, when set, caps the whole scan (the caller's remaining Hub budget);
// the scan never runs longer than BRIDGE_PROVIDER_DISCOVERY_BUDGET either way.
bridge_provider_discover_execute_profile :: proc(filter: []string, profile_id: string, deadline: time.Time = {}) -> [dynamic]Bridge_Provider_Path {
	bridge_provider_paths_init()
	if bridge_provider_discovery_test_delay > 0 do time.sleep(bridge_provider_discovery_test_delay)
	targets := bridge_provider_probe_targets(filter)
	defer {
		for target in targets do delete(target.provider)
		delete(targets)
	}
	results := make([dynamic]Bridge_Provider_Path)
	discovery_deadline := time.time_add(time.now(), BRIDGE_PROVIDER_DISCOVERY_BUDGET)
	if deadline != {} && time.diff(deadline, discovery_deadline) > 0 do discovery_deadline = deadline
	for target, i in targets {
		remaining := time.diff(time.now(), discovery_deadline)
		probe_timeout := min(2 * time.Second, remaining)
		if probe_timeout < 0 do probe_timeout = 0
		// The extension probe runs after --version and shares the same deadline, so a
		// whole discovery still answers inside the Hub's 10s wait. It stops short of
		// that deadline by a reserve per later target, so a slow detector cannot
		// starve the --version probes still to come.
		later := len(targets) - i - 1
		extension_deadline := time.time_add(discovery_deadline, -time.Duration(later) * BRIDGE_PROVIDER_VERSION_PROBE_RESERVE)
		p, err := profile_lookup(target.provider,profile_id)
		if err != .None {
			append(&results, Bridge_Provider_Path{provider = strings.clone(target.provider), profile_id = strings.clone(profile_effective_id(target.provider,profile_id)),
				state = strings.clone("disabled" if err == .Disabled else "error"), extension_state = strings.clone("disabled" if err == .Disabled else "error"), probed_at = bridge_provider_probe_time()})
			continue
		}
		env, env_ok := profile_child_env(&p)
		if !env_ok {
			append(&results,Bridge_Provider_Path{provider = strings.clone(target.provider),profile_id = strings.clone(p.profile_id),state = strings.clone("error"),extension_state = strings.clone("error"),probed_at = bridge_provider_probe_time()})
			continue
		}
		path, _ := bridge_provider_resolve_binary(bridge_provider_descriptor(target.provider), &p, env)
		result := bridge_provider_probe_one_with_timeout(target.provider, path, probe_timeout, target.extension, extension_deadline, env,p.profile_id)
		redacted := profile_redact_text(result.version_text,&p)
		if redacted != result.version_text {
			replacement := strings.clone(redacted); delete(result.version_text); result.version_text = replacement
		}
		redacted = profile_redact_text(result.extension_version,&p)
		if redacted != result.extension_version {
			replacement := strings.clone(redacted); delete(result.extension_version); result.extension_version = replacement
		}
		append(&results,result)
	}

	sync.rw_mutex_lock(&bridge_provider_paths_mutex)
	for result in results do bridge_provider_paths_upsert_unlocked(bridge_provider_path_clone(result, runtime.default_allocator()))
	_ = bridge_provider_paths_save_unlocked()
	sync.rw_mutex_unlock(&bridge_provider_paths_mutex)
	return results
}

bridge_provider_discover :: proc(filter: []string, profile_id: string = "", deadline: time.Time = {}) -> [dynamic]Bridge_Provider_Path {
	filter := filter
	if profile_id != "" && len(filter) == 0 {
		provider := profile_provider_name(profile_id)
		if provider == "" do return make([dynamic]Bridge_Provider_Path)
		filter = make([]string,1,context.temp_allocator)
		filter[0] = provider
	}
	filter_key := bridge_provider_discovery_key(filter)
	defer delete(filter_key)
	key := strings.clone(filter_key) if profile_id == "" else strings.concatenate({profile_id,"|",filter_key})
	defer delete(key)
	for {
		sync.mutex_lock(&bridge_provider_discovery_mutex)
		group := bridge_provider_discovery_current
		if group == nil {
			alloc := runtime.default_allocator()
			group = new(Bridge_Provider_Discovery_Group, alloc)
			group.key = strings.clone(key, alloc)
			group.refs = 1
			group.results = make([dynamic]Bridge_Provider_Path, alloc)
			bridge_provider_discovery_current = group
			bridge_provider_discovery_scan_count += 1
			if bridge_provider_discovery_test_key != "" && group.key == bridge_provider_discovery_test_key do bridge_provider_discovery_test_key_scans += 1
			sync.mutex_unlock(&bridge_provider_discovery_mutex)

			results := bridge_provider_discover_execute_profile(filter,profile_id,deadline)
			sync.mutex_lock(&bridge_provider_discovery_mutex)
			group.results = bridge_provider_discovery_results_clone(results[:], alloc)
			group.done = true
			if bridge_provider_discovery_current == group do bridge_provider_discovery_current = nil
			sync.cond_broadcast(&bridge_provider_discovery_cond)
			group.refs -= 1
			free_group := group.refs == 0
			sync.mutex_unlock(&bridge_provider_discovery_mutex)
			if free_group do bridge_provider_discovery_group_destroy(group)
			return results
		}

		if group.key != key {
			sync.cond_wait(&bridge_provider_discovery_cond, &bridge_provider_discovery_mutex)
			sync.mutex_unlock(&bridge_provider_discovery_mutex)
			continue
		}

		group.refs += 1
		for !group.done do sync.cond_wait(&bridge_provider_discovery_cond, &bridge_provider_discovery_mutex)
		results := bridge_provider_discovery_results_clone(group.results[:])
		group.refs -= 1
		free_group := group.refs == 0
		sync.mutex_unlock(&bridge_provider_discovery_mutex)
		if free_group do bridge_provider_discovery_group_destroy(group)
		return results
	}
}

bridge_provider_discovery_report_json :: proc(request_id: string, results: []Bridge_Provider_Path, acp_state_override := "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"provider_discovery_report\",\"request_id\":\"")
	bridge_runtime_write_json_string(&b, request_id)
	strings.write_string(&b, "\",\"command_id\":\"")
	bridge_runtime_write_json_string(&b, request_id)
	strings.write_string(&b, "\",\"providers\":[")
	for result, i in results {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"profile_id\":\""); bridge_runtime_write_json_string(&b,profile_effective_id(result.provider,result.profile_id))
		strings.write_string(&b, "\",\"provider\":\""); bridge_runtime_write_json_string(&b, result.provider)
		strings.write_string(&b, "\",\"binary_path\":\""); bridge_runtime_write_json_string(&b, result.resolved_path)
		strings.write_string(&b, "\",\"version_text\":\""); bridge_runtime_write_json_string(&b, result.version_text)
		strings.write_string(&b, "\",\"state\":\""); bridge_runtime_write_json_string(&b, result.state)
		strings.write_string(&b, "\",\"checked_at\":\""); bridge_runtime_write_json_string(&b, result.probed_at)
		strings.write_string(&b, "\",\"extension_state\":\""); bridge_runtime_write_json_string(&b, result.extension_state)
		strings.write_string(&b, "\",\"extension_version\":\""); bridge_runtime_write_json_string(&b, result.extension_version)
		// The extension is measured in the same pass as the binary.
		strings.write_string(&b, "\",\"extension_checked_at\":\""); bridge_runtime_write_json_string(&b, result.probed_at)
		strings.write_string(&b, "\",\"acp_adapter\":")
		adapter := acp_adapter_status_json(result.provider, acp_state_override, result.profile_id)
		strings.write_string(&b, adapter); delete(adapter)
		strings.write_byte(&b, '}')
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
	profile_id := extract_json_string(text,"profile_id",""); defer delete(profile_id)
	wait_until, probe_deadline := bridge_provider_discover_deadlines(time.now(), bridge_command_worker_deadline_ns(conn))
	// Never report from an empty catalog: that reads as "no CLI installed" and the
	// Hub would record every provider absent (a fresh profile hits this while its
	// first catalog sync is still in flight).
	if !bridge_provider_catalog_wait_ready(wait_until) {
		bridge_provider_discover_refuse_not_ready(conn, request_id)
		return true
	}
	// REQ-ACP-1: a provider scan is the user's "try again" for ACP too. Probed before
	// the report so a flipped acp_runtime_v1 is re-advertised (hub loop drain, ahead of
	// command results) before the hub answers the scan with acp_runtime_supported.
	// Skipped while supported: launches re-check support themselves.
	if !sync.atomic_load(&bridge_acp_runtime_supported) do _, _ = bridge_acp_runtime_probe(.Provider_Scan)
	results := bridge_provider_discover(filter,profile_id,probe_deadline)
	defer {
		for &result in results do bridge_provider_path_destroy(&result)
		delete(results)
	}
	report := bridge_provider_discovery_report_json(request_id, results[:])
	defer delete(report)
	_ = bridge_hub_send(conn, report)
	return true
}

// bridge_provider_discover_deadlines splits the Hub's budget for one discovery
// request (hub_deadline_ns is 0 when the caller has none): how long to wait for
// the catalog, and the deadline for the probes that follow.
bridge_provider_discover_deadlines :: proc(now: time.Time, hub_deadline_ns: i64) -> (wait_until: time.Time, probe_deadline: time.Time) {
	wait_until = time.time_add(now, BRIDGE_PROVIDER_CATALOG_READY_WAIT)
	if hub_deadline_ns <= 0 do return
	probe_deadline = time.time_add(time.Time{_nsec = hub_deadline_ns}, -BRIDGE_PROVIDER_DISCOVERY_REPLY_MARGIN)
	// Leave at least one second of probing after the wait; with less than that left
	// the wait shrinks rather than the probes.
	latest_wait := time.time_add(probe_deadline, -time.Second)
	if time.diff(latest_wait, wait_until) > 0 do wait_until = latest_wait
	return
}

// bridge_provider_discover_refuse_not_ready answers a discovery that found no
// catalog with a retriable typed failure (bridge_busy / provider_catalog_not_ready)
// and asks the Hub for the catalog again, rate-limited, in case the first request
// or its reply was lost. The catalog request goes first so the command result is
// this command's last frame.
bridge_provider_discover_refuse_not_ready :: proc(conn: ^ws.Connection, request_id: string) {
	fmt.println("bridge provider discovery deferred: provider catalog not received yet")
	catalog_request, failed := bridge_provider_discover_not_ready_frames(request_id, time.now())
	defer delete(catalog_request)
	defer delete(failed)
	if catalog_request != "" && bridge_hub_send(conn, catalog_request) do fmt.println("bridge provider catalog requested (recovery)")
	_ = bridge_hub_send(conn, failed)
}

// bridge_provider_discover_not_ready_frames builds the frames for a not-ready
// refusal: the recovery catalog request ("" when one was sent too recently) and
// the failed command_result. The caller owns both.
bridge_provider_discover_not_ready_frames :: proc(request_id: string, now: time.Time) -> (catalog_request: string, failed: string) {
	if bridge_provider_catalog_recovery_due(now) do catalog_request = bridge_provider_catalog_request_json()
	err := bridge_cause_wire_error(BRIDGE_PROVIDER_CATALOG_NOT_READY_CAUSE, "the bridge has not received its provider catalog yet; retry shortly", BRIDGE_PROVIDER_CATALOG_RETRY_AFTER_MS)
	failed = bridge_command_failed_json(request_id, err)
	return
}

bridge_provider_resolve_path :: proc(provider: string) -> (string, bool) {
	bridge_provider_paths_init()
	sync.rw_mutex_shared_lock(&bridge_provider_paths_mutex)
	for item in bridge_provider_paths {
		if item.provider == provider && profile_effective_id(provider,item.profile_id) == provider && item.state == "present" && bridge_provider_path_executable(item.resolved_path) {
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
