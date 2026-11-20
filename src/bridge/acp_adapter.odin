package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import ws "odin_test:lib/ws"
import contracts "odin_test:contracts"

ACP_INITIALIZE_PARAMS :: `{"protocolVersion":1,"clientInfo":{"name":"heimdall","version":"`+contracts.APP_VERSION+`"},"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false}}`
ACP_COPILOT_PACKAGE_JSON :: #load("acp_pins/copilot/package.json", string)
ACP_COPILOT_LOCK_JSON :: #load("acp_pins/copilot/package-lock.json", string)
acp_adapter_runner: Bridge_Extension_Install_Runner = bridge_process_run_capture_status
acp_adapter_probe_hook: proc(provider, root, scratch: string) -> (bool, string) = acp_adapter_probe
acp_adapter_cli_probe_hook: proc(provider: string) -> (string, string) = acp_adapter_cli_probe
acp_adapter_binding_hook: proc(provider, profile: string) -> (ACP_Runtime_Binding, bool) = acp_adapter_profile_binding
acp_adapter_profile_probe_hook: proc(pp: ^Provider_Profile, root, scratch: string) -> (bool, string) = acp_adapter_probe_profile

ACP_Adapter_Status :: struct {
    installed: bool,
    version, node_version, state, error, checked_at: string,
}

ACP_Adapter_Lock_State :: enum { Acquired, Busy, Error }

acp_adapter_platform_supported :: proc(d: contracts.ACP_Provider_Descriptor) -> bool {
    if d.launch != .Native do return true
    _, supported := contracts.acp_descriptor_platform_package(d, strings.to_lower(fmt.tprintf("%v", ODIN_OS), context.temp_allocator), fmt.tprintf("%v", ODIN_ARCH))
    return supported
}

acp_adapter_cleanup_stages :: proc(root: string) -> bool {
    dir, err := os.open(filepath.dir(root)); if err != nil do return false
    defer os.close(dir)
    entries, read_err := os.read_dir(dir, -1, context.temp_allocator); if read_err != nil do return false
    prefix := strings.concatenate({filepath.base(root), ".stage-"}, context.temp_allocator)
    // Caller owns the install lock: every older stage is now an orphan.
    for entry in entries {
        if entry.type == .Directory && strings.has_prefix(entry.name, prefix) {
            path := strings.concatenate({filepath.dir(root), "/", entry.name}, context.temp_allocator)
            if os.remove_all(path) != nil do return false
        }
    }
    return true
}

acp_adapter_recipe :: proc(provider: string) -> (Bridge_Catalog_Provider, bool) {
    bridge_provider_catalog_init()
    sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
    defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
    if bridge_provider_catalog_snapshot == nil do return {}, false
    for p in bridge_provider_catalog_snapshot.providers {
        d, known := contracts.acp_provider_descriptor(provider)
        if known && p.provider == provider && p.state == "active" && contracts.acp_descriptor_recipe_matches(d, p.acp_recipe) { return p, true }
    }
    return {}, false
}

acp_adapter_root :: proc(provider: string) -> string {
    d, known := contracts.acp_provider_descriptor(provider)
    if !known do return ""
    base := bridge_shell_data_dir(); defer delete(base)
    cli := strings.concatenate({"-cli-", d.cli_version}, context.temp_allocator) if d.cli_version != "" else ""
    root := strings.concatenate({base, "/bridge/acp-runtimes/", d.provider, "/", d.id, fmt.tprintf("-r%d/", d.revision), d.pkg.version, cli})
    if acp_provider_legacy_claude(d) && !os.is_dir(root) {
        old := strings.concatenate({base, "/bridge/acp-adapters/claude/0.108.0"})
        // Keep the old path and lock inode intact beneath surviving children.
        if os.is_dir(old) { delete(root); return old }
        delete(old)
    }
    return root
}

acp_adapter_bin :: proc(root: string, provider: string) -> string {
    d, known := contracts.acp_provider_descriptor(provider)
    if !known do return ""
    return strings.concatenate({root, "/node_modules/.bin/", d.command})
}

acp_adapter_files_valid :: proc(root: string, provider: string) -> bool {
    return acp_adapter_files_valid_for_platform(root, provider, strings.to_lower(fmt.tprintf("%v", ODIN_OS), context.temp_allocator), fmt.tprintf("%v", ODIN_ARCH))
}

// Keep package-layout validation independent of the host so every supported
// native layout can be checked without executing a foreign binary.
acp_adapter_files_valid_for_platform :: proc(root, provider, platform_os, platform_arch: string) -> bool {
    d, known := contracts.acp_provider_descriptor(provider)
    if !known do return false
    context.allocator = context.temp_allocator
    manifest, me := os.read_entire_file(strings.concatenate({root, "/node_modules/", d.pkg.name, "/package.json"}), context.temp_allocator)
    lock, le := os.read_entire_file(strings.concatenate({root, "/package-lock.json"}), context.temp_allocator)
    if me != nil || le != nil do return false
    if d.provider == "copilot" && string(lock) != ACP_COPILOT_LOCK_JSON do return false
    m, err := json.parse(string(manifest)); if err != nil do return false
    l, lerr := json.parse(string(lock)); if lerr != nil do return false
    mo, mok := m.(json.Object); lo, lok := l.(json.Object)
    if !mok || !lok do return false
    name, _ := mo["name"].(json.String); version, _ := mo["version"].(json.String)
    bins, _ := mo["bin"].(json.Object); bin, _ := bins[d.command].(json.String)
    packages, _ := lo["packages"].(json.Object)
    entry, _ := packages[strings.concatenate({"node_modules/", d.pkg.name})].(json.Object)
    lv, _ := entry["version"].(json.String); integrity, _ := entry["integrity"].(json.String)
    if string(name) != d.pkg.name || string(version) != d.pkg.version || string(lv) != d.pkg.version ||
       string(integrity) != d.pkg.integrity || bin == "" || filepath.is_abs(string(bin)) || strings.contains(string(bin), "..") { return false }
    if d.launch == .Native {
        pin, supported := contracts.acp_descriptor_platform_package(d, platform_os, platform_arch)
        if !supported do return false
        native, present := packages[strings.concatenate({"node_modules/", pin.name}, context.temp_allocator)].(json.Object)
        nv, _ := native["version"].(json.String); ni, _ := native["integrity"].(json.String)
        if !present || string(nv) != pin.version || string(ni) != pin.integrity do return false
        native_manifest, ne := os.read_entire_file(strings.concatenate({root, "/node_modules/", pin.name, "/package.json"}, context.temp_allocator), context.temp_allocator)
        if ne != nil do return false
        nm, pe := json.parse(string(native_manifest)); if pe != nil do return false
        no, _ := nm.(json.Object)
        nn, _ := no["name"].(json.String); nversion, _ := no["version"].(json.String)
        if string(nn) != pin.name || string(nversion) != pin.version do return false
        native_bins, _ := no["bin"].(json.Object)
        native_entry, _ := native_bins[strings.trim_prefix(pin.name, "@github/")].(json.String)
        if string(native_entry) != "copilot" do return false
        native_dir := strings.concatenate({root, "/node_modules/", pin.name}, context.temp_allocator)
        native_binary := strings.concatenate({native_dir, "/copilot"}, context.temp_allocator)
        if !bridge_provider_path_executable(native_binary) ||
           filepath.dir(bridge_fs_canonicalize_existing(native_binary)) != bridge_fs_canonicalize_existing(native_dir) { return false }
    }
    executable := acp_adapter_bin(root, provider)
    expected, _ := filepath.join({root, "node_modules", d.pkg.name, string(bin)}, context.temp_allocator)
    if bridge_fs_canonicalize_existing(executable) != bridge_fs_canonicalize_existing(expected) do return false
    return bridge_provider_path_executable(executable)
}

acp_adapter_node_compatible :: proc(version: string, minimum: int = 22) -> bool {
    if len(version) > 64 do return false
    parts := strings.split(strings.trim_prefix(strings.trim_space(version), "v"), ".", context.temp_allocator)
    if len(parts) != 3 do return false
    major, ok := strconv.parse_int(parts[0])
    minor, minor_ok := strconv.parse_int(parts[1]); patch, patch_ok := strconv.parse_int(parts[2])
    return ok && minor_ok && patch_ok && major >= minimum && minor >= 0 && patch >= 0
}

acp_adapter_status :: proc(provider: string, profile: string = "") -> ACP_Adapter_Status {
    context.allocator = context.temp_allocator
    s := ACP_Adapter_Status{state = "missing", checked_at = bridge_provider_probe_time()}
    d, known := contracts.acp_provider_descriptor(provider)
    if _, ok := acp_adapter_recipe(provider); !known || !ok { s.state = "not_checked"; return s }
    if !acp_adapter_platform_supported(d) {
        s.state = "error"; s.error = "acp_adapter_unsupported_platform"; return s
    }
    out, diagnostic, _, ran, _ := acp_adapter_runner({"node", "--version"}, 2*time.Second)
    defer { delete(out); delete(diagnostic) }
    if !ran || !acp_adapter_node_compatible(out, d.node_min_major) { s.state = "missing_node"; s.error = "Node 22 or newer is required"; return s }
    s.node_version = strings.clone(strings.trim_space(out), context.temp_allocator)
    root := acp_adapter_root(provider); defer delete(root)
    s.installed = acp_adapter_files_valid(root, provider)
    lock_path := strings.concatenate({root, ".lock"}, context.temp_allocator)
    if os.exists(lock_path) {
        lock, state := acp_adapter_lock_acquire(lock_path)
        if state == .Busy { s.state = "installing"; return s }
        if state == .Error { s.state = "error"; s.error = "acp_adapter_lock_failed"; return s }
        acp_adapter_lock_release(lock)
    }
    if s.installed do s.version = d.pkg.version
    if !s.installed && os.is_dir(root) { s.state = "outdated"; s.error = "Pinned adapter files failed verification" }
    raw, status_err := os.read_entire_file(strings.concatenate({root, ".status.json"}), context.temp_allocator)
    if status_err == nil {
        record: struct{state, error, diagnostic: string}
        if json.unmarshal(raw, &record) == nil && record.state == "error" {
            provider_error := record.error == strings.concatenate({"acp_", d.provider, "_not_found"}, context.temp_allocator) ||
                record.error == strings.concatenate({"acp_", d.provider, "_not_runnable"}, context.temp_allocator)
            // A failed recheck must override an older successful install marker.
            if !s.installed || provider_error && profile_effective_id(provider, profile) == provider {
                s.state = "error"
                // Persisted status is local input: allowlist codes and messages.
                s.error = "acp_adapter_install_failed"
                if provider_error do s.error = record.error
                switch record.error {
                case "acp_adapter_directory_failed", "acp_adapter_install_failed", "acp_adapter_integrity_failed", "acp_adapter_probe_failed", "acp_adapter_host_unavailable", "acp_adapter_in_use", "acp_adapter_promote_failed": s.error = record.error
                }
                if record.error == "acp_adapter_probe_failed" || provider_error {
                    if message := acp_adapter_probe_message(record.diagnostic, provider); message != "" {
                        s.error = strings.concatenate({record.error, ": ", message}, context.temp_allocator)
                    }
                }
                return s
            }
        }
    }
    if !s.installed do return s
    binding, bound := acp_adapter_binding_hook(provider, profile)
    if bound && (acp_adapter_marker_matches(root, binding) || acp_adapter_upgrade_legacy_marker(root, binding)) {
        s.state = "ready"
    } else { s.state = "error"; s.error = "ACP initialize probe is required for the selected profile" }
    return s
}

acp_adapter_status_json :: proc(provider: string, override: string = "", profile: string = "") -> string {
    if _, ok := acp_adapter_recipe(provider); !ok do return strings.clone("null")
    d, _ := contracts.acp_provider_descriptor(provider)
    s := acp_adapter_status(provider, profile)
    if override != "" do s.state = override
    nullable :: proc(value: string) -> json.Value { if value == "" do return json.Null(nil); return json.String(value) }
    raw, _ := json.marshal(struct {
        installed: bool,
        version, node_version: json.Value,
        state: string,
        error, checked_at: json.Value,
        provider, runtime_kind, profile: string,
    }{s.installed, nullable(s.version), nullable(s.node_version), s.state, nullable(s.error), nullable(s.checked_at),
        provider, "adapter" if d.launch == .Adapter else "native", profile_effective_id(provider, profile)})
    return string(raw)
}

ACP_Adapter_Probe :: struct {
    done, ok: bool,
    mu: sync.Mutex,
    cond: sync.Cond,
    diagnostic: [1024]byte,
    diagnostic_len: int,
}
acp_adapter_probe_diagnostic :: proc(data: rawptr, bytes: string) {
    p := cast(^ACP_Adapter_Probe)data
    sync.mutex_lock(&p.mu); defer sync.mutex_unlock(&p.mu)
    p.diagnostic_len += copy(p.diagnostic[p.diagnostic_len:], transmute([]byte)bytes)
}

acp_adapter_probe_checkpoint :: proc(_: rawptr, _: ^ACP_State) -> bool { return true }
acp_adapter_probe_result :: proc(data: rawptr, result: ACP_RPC_Result) {
    defer acp_rpc_result_delete(result)
    p := cast(^ACP_Adapter_Probe)data
    value, err := json.parse(result.result_json, parse_integers = true)
    valid := false
    if err == nil {
        if obj, ok := value.(json.Object); ok { v, _ := obj["protocolVersion"].(json.Integer); valid = v == 1 }
        json.destroy_value(value)
    }
    sync.mutex_lock(&p.mu); p.ok = result.ok && valid; p.done = true; sync.cond_broadcast(&p.cond); sync.mutex_unlock(&p.mu)
}

// Child stderr is untrusted and can contain credentials. Only fixed diagnostic
// reasons leave the bridge; retain at most 1 KiB locally while classifying it.
acp_adapter_probe_reason :: proc(diagnostic: string, fallback: string) -> string {
    if strings.contains(diagnostic, "ERR_MODULE_NOT_FOUND") || strings.contains(diagnostic, "MODULE_NOT_FOUND") do return "node_module_missing"
    if strings.contains(diagnostic, "ENOENT") do return "executable_or_file_missing"
    if strings.contains(diagnostic, "EACCES") do return "executable_permission_denied"
    if strings.contains(diagnostic, "dynamically linked executable") || strings.contains(diagnostic, "ld-linux") do return "unsupported_dynamic_executable"
    if strings.contains(diagnostic, "EPIPE") do return "pipe_closed"
    return fallback
}

acp_adapter_probe_message :: proc(reason: string, provider: string = "claude") -> string {
    d, known := contracts.acp_provider_descriptor(provider)
    if !known do return ""
    if reason == "profile_unavailable" do return fmt.tprintf("The canonical %s provider profile is unavailable", d.display_name)
    if reason == strings.concatenate({provider, "_missing"}, context.temp_allocator) do return fmt.tprintf("No %s executable resolves in the canonical provider profile", d.display_name)
    if reason == strings.concatenate({provider, "_version_timeout"}, context.temp_allocator) do return fmt.tprintf("%s --version did not finish before the deadline", d.display_name)
    if reason == strings.concatenate({provider, "_version_spawn_failed"}, context.temp_allocator) do return fmt.tprintf("%s --version could not be executed", d.display_name)
    if reason == strings.concatenate({provider, "_version_failed"}, context.temp_allocator) do return fmt.tprintf("%s --version exited with a non-zero status", d.display_name)
    if reason == "cli_version_mismatch" do return fmt.tprintf("The selected %s executable does not report the pinned CLI version %s", d.display_name, d.cli_version)
    switch reason {
    case "host_unavailable": return "The pipe daemon is unavailable"
    case "spawn_failed": return "The adapter process could not be spawned"
    case "generation_missing": return "The spawned adapter generation could not be resolved"
    case "pipe_unavailable": return "The adapter pipe could not be attached"
    case "initialize_failed": return "The adapter rejected initialize or protocol version 1"
    case "initialize_timeout": return "The adapter did not answer initialize before the deadline"
    case "adapter_exited": return "The adapter exited before completing initialize"
    case "node_module_missing": return "Node could not load an adapter module"
    case "executable_or_file_missing": return "The adapter could not find a required executable or file"
    case "executable_permission_denied": return "The adapter could not execute a required file"
    case "unsupported_dynamic_executable": return fmt.tprintf("Could not start dynamically linked executable; configure the %s provider binary for this host", d.display_name)
    case "pipe_closed": return "The adapter pipe closed during initialize"
    }
    return ""
}

acp_adapter_probe_env :: proc(pp: ^Provider_Profile) -> ([][2]string, bool) {
    context.allocator = context.temp_allocator
    env, ok := acp_profile_child_env(pp); if !ok do return nil, false
    clean := make([dynamic]string)
    for entry in env {
        eq := strings.index_byte(entry, '=')
        if eq < 0 || strings.has_prefix(strings.to_upper(entry[:eq]), "HEIMDALL_") do continue
        append(&clean, entry)
    }
    return bridge_pty_host_env_pairs(clean[:]), true
}

acp_provider_parse_cli_version :: proc(d: contracts.ACP_Provider_Descriptor, output: string) -> (string, bool) {
    text := strings.trim_space(output)
    if d.launch == .Native {
        // Copilot prints a product label and a trailing full stop, followed by
        // an update hint. Never accept a different semver found in diagnostics.
        if d.provider != "copilot" || !strings.has_prefix(text, "GitHub Copilot CLI ") do return "", false
        text = strings.trim_prefix(text, "GitHub Copilot CLI ")
        if end := strings.index_byte(text, '\n'); end >= 0 do text = strings.trim_space(text[:end])
        text = strings.trim_suffix(text, ".")
        if text != d.cli_version || !contracts.exact_adapter_version(text) do return "", false
        return text, true
    }
    // Preserve Claude's numeric prefix (the rest is a product label).
    for c, i in text {
        if (c < '0' || c > '9') && c != '.' { text = text[:i]; break }
    }
    return text, len(text) <= 64 && contracts.exact_adapter_version(text)
}

// Use the same resolution and environment as managed ACP launches, with no
// Heimdall credentials. Only allowlisted excerpts of the bounded output escape.
acp_provider_cli_version :: proc(pp: ^Provider_Profile, timeout: time.Duration = 3*time.Second) -> (version, reason, diagnostic: string) {
    context.allocator = context.temp_allocator
    d, known := contracts.acp_provider_descriptor(pp.provider)
    if !known do return "", "unsupported_acp_adapter", "profile_unavailable"
    pairs, env_ok := acp_adapter_probe_env(pp)
    if !env_ok do return "", strings.concatenate({"acp_", d.provider, "_not_found"}), strings.concatenate({d.provider, "_missing"})
    env := make([dynamic]string)
    binary := ""
    for pair in pairs {
        append(&env, strings.concatenate({pair[0], "=", pair[1]}))
        if pair[0] == d.executable_env do binary = pair[1]
    }
    if d.launch == .Native {
        command := pp.config.binary_path if pp.config.binary_path != "" else d.cli_command
        binary = profile_resolve_binary(command, env[:])
    }
    out, stderr, exit_code, ran, timed_out := bridge_process_run_capture_status_env({binary, "--version"}, min(timeout, 3*time.Second), env[:])
    defer { delete(out); delete(stderr) }
    if !ran || timed_out || exit_code != 0 {
        fallback := strings.concatenate({d.provider, "_version_failed"})
        if exit_code < 0 do fallback = strings.concatenate({d.provider, "_version_spawn_failed"})
        if timed_out do fallback = strings.concatenate({d.provider, "_version_timeout"})
        excerpt := strings.concatenate({stderr[:min(len(stderr), 512)], out[:min(len(out), 512)]})
        return "", strings.concatenate({"acp_", d.provider, "_not_runnable"}), acp_adapter_probe_reason(excerpt, fallback)
    }
    // Only a validated numeric version can leave this boundary.
    text, valid := acp_provider_parse_cli_version(d, out)
    if !valid do return "", strings.concatenate({"acp_", d.provider, "_not_runnable"}), "cli_version_mismatch"
    return strings.clone(text), "", ""
}

acp_adapter_cli_probe :: proc(provider: string) -> (reason, diagnostic: string) {
    context.allocator = context.temp_allocator
    pp, perr := profile_lookup(provider, "")
    if perr != .None do return strings.concatenate({"acp_", provider, "_not_found"}), "profile_unavailable"
    version: string
    version, reason, diagnostic = acp_provider_cli_version(&pp)
    // Adapter version fields describe the pinned npm package, not Claude.
    if reason == "" && version != "" do fmt.println("ACP probe CLI version:", provider, version)
    return
}

// Probe in a scratch cwd with the canonical provider profile, without an agent
// token or project files. Auth metadata is not an initialize failure.
acp_adapter_probe :: proc(provider, root, scratch: string) -> (bool, string) {
    context.allocator = context.temp_allocator
    pp, perr := profile_lookup(provider, "")
    if perr != .None do return false, "profile_unavailable"
    return acp_adapter_profile_probe_hook(&pp, root, scratch)
}

acp_adapter_probe_profile :: proc(pp: ^Provider_Profile, root, scratch: string) -> (bool, string) {
    context.allocator = context.temp_allocator
    d, known := contracts.acp_provider_descriptor(pp.provider)
    if !known do return false, "profile_unavailable"
    env, env_ok := acp_adapter_probe_env(pp)
    if !env_ok do return false, strings.concatenate({d.provider, "_missing"})
    resolved := ""
    if d.launch == .Native {
        child_env := make([dynamic]string)
        for pair in env do append(&child_env, strings.concatenate({pair[0], "=", pair[1]}, context.temp_allocator))
        command := pp.config.binary_path if pp.config.binary_path != "" else d.cli_command
        resolved = profile_resolve_binary(command, child_env[:])
    }
    argv, built := acp_provider_launch_argv(d, root, resolved)
    if !built do return false, "spawn_failed"
    socket, ok := bridge_pty_host_ensure_daemon(); if !ok do return false, "host_unavailable"
    id := fmt.tprintf("acp_probe_%d", time.tick_now()._nsec)
    reply, received := pty_host_spawn_pipe(socket, {instance = id, argv = argv, cwd = scratch, has_cwd = true, env = env})
    defer pty_host_reply_delete(reply)
    if !received || reply.kind != .Spawned do return false, "spawn_failed"
    // Close every spawned probe, including failures before the RPC client opens.
    defer bridge_pty_host_close(socket, id)
    if reply.generation == "" do return false, "generation_missing"
    io, opened := acp_pipe_io_open(socket, id, reply.generation, "probe", "", 0); if !opened do return false, "pipe_unavailable"
    p: ACP_Adapter_Probe
    pipe := cast(^ACP_Pipe_IO)io.data
    pipe.diagnostic = acp_adapter_probe_diagnostic; pipe.diagnostic_data = &p
    c, client_ok := acp_rpc_open(io, {checkpoint = acp_adapter_probe_checkpoint})
    if !client_ok { io.close(io.data); io.destroy(io.data); return false, "pipe_unavailable" }
    rpc_id, sent := acp_rpc_request(c, "initialize", ACP_INITIALIZE_PARAMS, 15000, {acp_adapter_probe_result, &p})
    delete(string(rpc_id))
    fallback := "initialize_failed"
    if sent {
        deadline := time.time_add(time.now(), 16*time.Second)
        fallback = "initialize_timeout"
        for time.diff(time.now(), deadline) > 0 {
            sync.mutex_lock(&p.mu)
            if !p.done do sync.cond_wait_with_timeout(&p.cond, &p.mu, 100*time.Millisecond)
            done := p.done
            sync.mutex_unlock(&p.mu)
            if done { fallback = "initialize_failed"; break }
            frame := pty_host_encode_pipe_request({kind = .List})
            roster, listed := pty_host_request_deadline(socket, frame, 500)
            delete(frame)
            exited := false
            if listed && roster.kind == .Pipe_List {
                for row in roster.pipes {
                    if row.instance == id && row.generation == reply.generation && !row.alive do exited = true
                }
            }
            pty_host_reply_delete(roster)
            if exited {
                // The daemon retains stderr independently of the control ACK.
                // Let the attachment reader consume the final diagnostic.
                time.sleep(100*time.Millisecond)
                fallback = "adapter_exited"
                break
            }
        }
    }
    acp_rpc_close(c) // joins the diagnostic reader before inspecting its buffer
    if p.done && p.ok do return true, ""
    return false, acp_adapter_probe_reason(string(p.diagnostic[:p.diagnostic_len]), fallback)
}

acp_adapter_prepare_install :: proc(d: contracts.ACP_Provider_Descriptor, stage: string) -> ([]string, bool) {
    argv := make([dynamic]string, allocator = context.temp_allocator)
    if d.provider == "copilot" {
        if !bridge_retry_atomic_write(strings.concatenate({stage, "/package.json"}, context.temp_allocator), transmute([]byte)ACP_COPILOT_PACKAGE_JSON) ||
           !bridge_retry_atomic_write(strings.concatenate({stage, "/package-lock.json"}, context.temp_allocator), transmute([]byte)ACP_COPILOT_LOCK_JSON) { return nil, false }
        append(&argv, "npm", "ci", "--prefix", stage, "--ignore-scripts", "--no-audit", "--no-fund")
        return argv[:], true
    }
    append(&argv, "npm", "install", "--prefix", stage, "--save-exact", "--ignore-scripts", "--no-audit", "--no-fund", strings.concatenate({d.pkg.name, "@", d.pkg.version}, context.temp_allocator))
    return argv[:], true
}

acp_adapter_install :: proc(provider, etag, version: string) -> (ok: bool, reason: string) {
    d, known := contracts.acp_provider_descriptor(provider)
    if _, valid := acp_adapter_recipe(provider); !known || !valid || version != d.pkg.version do return false, "unsupported_acp_adapter"
    if !acp_adapter_platform_supported(d) do return false, "acp_adapter_unsupported_platform"
    current := bridge_provider_catalog_current_etag(); defer delete(current)
    if etag != current do return false, "provider_catalog_stale"
    root := acp_adapter_root(provider); defer delete(root)
    before := acp_adapter_status(provider)
    if before.state == "missing_node" do return false, "acp_adapter_missing_node"
    parent := filepath.dir(root)
    if bridge_make_directory_all(parent) != nil do return false, "acp_adapter_directory_failed"
    lock_path := strings.concatenate({root, ".lock"}); defer delete(lock_path)
    lock, lock_state := acp_adapter_lock_acquire(lock_path)
    if lock_state == .Busy do return false, "acp_adapter_install_in_progress"
    if lock_state == .Error do return false, "acp_adapter_lock_failed"
    defer acp_adapter_lock_release(lock)
    diagnostic := ""
    defer {
        raw, _ := json.marshal(struct{state, error, diagnostic, checked_at: string}{"ready" if ok else "error", reason, diagnostic, bridge_provider_probe_time()}, allocator = context.temp_allocator)
        bridge_retry_atomic_write(strings.concatenate({root, ".status.json"}, context.temp_allocator), raw)
    }
    if !acp_adapter_cleanup_stages(root) do return false, "acp_adapter_directory_failed"
    reason, diagnostic = acp_adapter_cli_probe_hook(provider)
    if reason != "" do return false, reason
    binding, bound := acp_adapter_binding_hook(provider, provider)
    if !bound do return false, "acp_adapter_probe_failed"
    if before.installed {
        if acp_adapter_marker_matches(root, binding) do return true, ""
        scratch := strings.concatenate({root, fmt.tprintf(".stage-probe-%d", time.tick_now()._nsec)}, context.temp_allocator)
        if bridge_make_directory_all(scratch) != nil do return false, "acp_adapter_directory_failed"
        defer os.remove_all(scratch)
        probed: bool
        probed, diagnostic = acp_adapter_probe_hook(provider, root, scratch)
        latest, current := acp_adapter_binding_hook(provider, provider)
        if !probed || !current || !acp_provider_binding_equal(binding, latest) do return false, "acp_adapter_probe_failed"
        if !acp_adapter_marker_write(root, binding) do return false, "acp_adapter_directory_failed"
        return true, ""
    }
    stage := strings.concatenate({root, fmt.tprintf(".stage-%d", time.tick_now()._nsec)}); defer delete(stage)
    if bridge_make_directory_all(stage) != nil do return false, "acp_adapter_directory_failed"
    defer os.remove_all(stage)
    install_argv, prepared := acp_adapter_prepare_install(d, stage)
    if !prepared do return false, "acp_adapter_directory_failed"
    out, npm_diagnostic, npm_exit, installed, npm_timeout := acp_adapter_runner(install_argv, 100*time.Second)
    delete(out); delete(npm_diagnostic) // Never expose npm diagnostics/environment.
    if !installed || npm_exit != 0 || npm_timeout do return false, "acp_adapter_install_failed"
    if !acp_adapter_files_valid(stage, provider) do return false, "acp_adapter_integrity_failed"
    scratch := strings.concatenate({stage, "/probe"}, context.temp_allocator)
    if bridge_make_directory_all(scratch) != nil do return false, "acp_adapter_directory_failed"
    probed: bool
    probed, diagnostic = acp_adapter_probe_hook(provider, stage, scratch)
    if !probed do return false, "acp_adapter_probe_failed"
    latest, still_bound := acp_adapter_binding_hook(provider, provider)
    if !still_bound || !acp_provider_binding_equal(binding, latest) do return false, "acp_adapter_probe_failed"
    if !acp_adapter_marker_write(stage, binding) do return false, "acp_adapter_directory_failed"
    // An outdated/corrupt tree can be repaired, but never moved beneath a live
    // child. All supported ACP children currently use this single pinned tree.
    backup := strings.concatenate({stage, ".previous"}, context.temp_allocator)
    moved_old := false
    if os.is_dir(root) {
        socket, daemon := bridge_pty_host_ensure_daemon(); if !daemon do return false, "acp_adapter_host_unavailable"
        frame := pty_host_encode_pipe_request({kind = .List}); defer delete(frame)
        pipes, listed := pty_host_request_deadline(socket, frame, 2000); defer pty_host_reply_delete(pipes)
        if !listed || pipes.kind != .Pipe_List do return false, "acp_adapter_host_unavailable"
        for pipe in pipes.pipes do if pipe.alive do return false, "acp_adapter_in_use"
        if os.rename(root, backup) != nil do return false, "acp_adapter_promote_failed"
        moved_old = true
    }
    if os.rename(stage, root) != nil {
        if moved_old do os.rename(backup, root)
        return false, "acp_adapter_promote_failed"
    }
    if moved_old do os.remove_all(backup)
    when ODIN_OS != .Windows {
        directory, open_err := os.open(parent, {.Read})
        if open_err != nil do return false, "acp_adapter_promote_failed"
        synced := os.sync(directory) == nil; os.close(directory)
        if !synced do return false, "acp_adapter_promote_failed"
    }
    return true, ""
}

acp_adapter_handle_install :: proc(conn: ^ws.Connection, text: string) {
    command := extract_json_string(text, "command_id", ""); defer delete(command)
    provider := extract_json_string(text, "provider", ""); defer delete(provider)
    etag := extract_json_string(text, "catalog_etag", ""); defer delete(etag)
    version := extract_json_string(text, "adapter_version", ""); defer delete(version)
    results := bridge_provider_discover({provider})
    defer { for &entry in results do bridge_provider_path_destroy(&entry); delete(results) }
    progress := bridge_provider_discovery_report_json(command, results[:], "installing"); defer delete(progress)
    bridge_hub_send(conn, progress)
    ok, reason := acp_adapter_install(provider, etag, version)
    report := bridge_provider_discovery_report_json(command, results[:]); defer delete(report)
    bridge_hub_send(conn, report)
    frame := acp_adapter_install_result_json(command, ok, reason)
    defer delete(frame)
    bridge_hub_send(conn, frame)
}

acp_adapter_install_result_json :: proc(command: string, ok: bool, reason: string) -> string {
    if ok do return bridge_command_result_json(command, "succeeded", "")
    return bridge_command_failed_json(command, bridge_cause_wire_error(reason, "ACP adapter installation failed"))
}
