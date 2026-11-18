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

ACP_CLAUDE_VERSION :: "0.108.0"
ACP_CLAUDE_PACKAGE :: "@agentclientprotocol/claude-agent-acp"
ACP_CLAUDE_INTEGRITY :: "sha512-Y0HI3CB0DfhpWItCn2RE3xgpen001V2U/bHm3G6ZVKXsElF5N4uYyjYlmgNzZBKcBtZK0JqiE96NMaeVXtgJjw=="
ACP_INITIALIZE_PARAMS :: `{"protocolVersion":1,"clientInfo":{"name":"heimdall","version":"`+contracts.APP_VERSION+`"},"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false}}`
acp_adapter_runner: Bridge_Extension_Install_Runner = bridge_process_run_capture_status
acp_adapter_probe_hook: proc(root, scratch: string) -> bool = acp_adapter_probe

ACP_Adapter_Status :: struct {
    installed: bool,
    version, node_version, state, error, checked_at: string,
}

acp_adapter_recipe :: proc(provider: string) -> (Bridge_Catalog_Provider, bool) {
    bridge_provider_catalog_init()
    sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
    defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
    if bridge_provider_catalog_snapshot == nil do return {}, false
    for p in bridge_provider_catalog_snapshot.providers {
        if p.provider == provider && p.state == "active" && provider == "claude" &&
           p.acp_recipe.adapter_package == ACP_CLAUDE_PACKAGE && p.acp_recipe.adapter_version == ACP_CLAUDE_VERSION &&
           p.acp_recipe.command == "claude-agent-acp" && p.acp_recipe.protocol_version == 1 &&
           len(p.acp_recipe.args) == 0 && p.acp_recipe.env["CLAUDE_AGENT_ACP_PROTOCOL"] == "v1" { return p, true }
    }
    return {}, false
}

acp_adapter_root :: proc() -> string {
    base := bridge_shell_data_dir(); defer delete(base)
    return strings.concatenate({base, "/bridge/acp-adapters/claude/", ACP_CLAUDE_VERSION})
}

acp_adapter_bin :: proc(root: string) -> string {
    return strings.concatenate({root, "/node_modules/.bin/claude-agent-acp"})
}

acp_adapter_files_valid :: proc(root: string) -> bool {
    context.allocator = context.temp_allocator
    manifest, me := os.read_entire_file(strings.concatenate({root, "/node_modules/", ACP_CLAUDE_PACKAGE, "/package.json"}), context.temp_allocator)
    lock, le := os.read_entire_file(strings.concatenate({root, "/package-lock.json"}), context.temp_allocator)
    if me != nil || le != nil do return false
    m, err := json.parse(string(manifest)); if err != nil do return false
    l, lerr := json.parse(string(lock)); if lerr != nil do return false
    mo, mok := m.(json.Object); lo, lok := l.(json.Object)
    if !mok || !lok do return false
    name, _ := mo["name"].(json.String); version, _ := mo["version"].(json.String)
    bins, _ := mo["bin"].(json.Object); bin, _ := bins["claude-agent-acp"].(json.String)
    packages, _ := lo["packages"].(json.Object)
    entry, _ := packages[strings.concatenate({"node_modules/", ACP_CLAUDE_PACKAGE})].(json.Object)
    lv, _ := entry["version"].(json.String); integrity, _ := entry["integrity"].(json.String)
    if string(name) != ACP_CLAUDE_PACKAGE || string(version) != ACP_CLAUDE_VERSION || string(lv) != ACP_CLAUDE_VERSION ||
       string(integrity) != ACP_CLAUDE_INTEGRITY || bin == "" || filepath.is_abs(string(bin)) || strings.contains(string(bin), "..") { return false }
    executable := acp_adapter_bin(root)
    expected, _ := filepath.join({root, "node_modules", ACP_CLAUDE_PACKAGE, string(bin)}, context.temp_allocator)
    if bridge_fs_canonicalize_existing(executable) != bridge_fs_canonicalize_existing(expected) do return false
    return bridge_provider_path_executable(executable)
}

acp_adapter_node_compatible :: proc(version: string) -> bool {
    if len(version) > 64 do return false
    parts := strings.split(strings.trim_prefix(strings.trim_space(version), "v"), ".", context.temp_allocator)
    if len(parts) != 3 do return false
    major, ok := strconv.parse_int(parts[0])
    minor, minor_ok := strconv.parse_int(parts[1]); patch, patch_ok := strconv.parse_int(parts[2])
    return ok && minor_ok && patch_ok && major >= 22 && minor >= 0 && patch >= 0
}

acp_adapter_status :: proc(provider: string) -> ACP_Adapter_Status {
    context.allocator = context.temp_allocator
    s := ACP_Adapter_Status{state = "missing", checked_at = bridge_provider_probe_time()}
    if _, ok := acp_adapter_recipe(provider); !ok { s.state = "not_checked"; return s }
    out, diagnostic, _, ran, _ := acp_adapter_runner({"node", "--version"}, 2*time.Second)
    defer { delete(out); delete(diagnostic) }
    if !ran || !acp_adapter_node_compatible(out) { s.state = "missing_node"; s.error = "Node 22 or newer is required"; return s }
    s.node_version = strings.clone(strings.trim_space(out), context.temp_allocator)
    root := acp_adapter_root(); defer delete(root)
    s.installed = acp_adapter_files_valid(root)
    if os.exists(strings.concatenate({root, ".lock"}, context.temp_allocator)) { s.state = "installing"; return s }
    if !s.installed {
        if os.is_dir(root) { s.state = "outdated"; s.error = "Pinned adapter files failed verification" }
        raw, err := os.read_entire_file(strings.concatenate({root, ".status.json"}), context.temp_allocator)
        if err == nil {
            record: struct{state, error: string}
            if json.unmarshal(raw, &record) == nil && record.state == "error" {
                s.state = "error"
                // Persisted status is local input, never a source of arbitrary
                // diagnostics or credentials in discovery reports.
                s.error = "acp_adapter_install_failed"
                switch record.error {
                case "acp_adapter_directory_failed", "acp_adapter_install_failed", "acp_adapter_integrity_failed", "acp_adapter_probe_failed", "acp_adapter_host_unavailable", "acp_adapter_in_use", "acp_adapter_promote_failed": s.error = record.error
                }
            }
        }
        return s
    }
    s.version = ACP_CLAUDE_VERSION
    marker, err := os.read_entire_file(strings.concatenate({root, "/heimdall-probe-v1.json"}, context.temp_allocator), context.temp_allocator)
    if err == nil && string(marker) == ACP_CLAUDE_INTEGRITY { s.state = "ready" } else { s.state = "error"; s.error = "ACP initialize probe is required" }
    return s
}

acp_adapter_status_json :: proc(provider: string, override: string = "") -> string {
    if _, ok := acp_adapter_recipe(provider); !ok do return strings.clone("null")
    s := acp_adapter_status(provider)
    if override != "" do s.state = override
    nullable :: proc(value: string) -> json.Value { if value == "" do return json.Null(nil); return json.String(value) }
    raw, _ := json.marshal(struct {
        installed: bool,
        version, node_version: json.Value,
        state: string,
        error, checked_at: json.Value,
    }{s.installed, nullable(s.version), nullable(s.node_version), s.state, nullable(s.error), nullable(s.checked_at)})
    return string(raw)
}

ACP_Adapter_Probe :: struct { done, ok: bool, mu: sync.Mutex, cond: sync.Cond }
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

// Probe in a scratch cwd with no agent token or project files. Auth metadata is
// not a failure; only the initialize response and negotiated version matter.
acp_adapter_probe :: proc(root, scratch: string) -> bool {
    socket, ok := bridge_pty_host_ensure_daemon(); if !ok do return false
    id := fmt.tprintf("acp_probe_%d", time.tick_now()._nsec)
    env := [][2]string{{"CLAUDE_AGENT_ACP_PROTOCOL", "v1"}}
    reply, received := pty_host_spawn_pipe(socket, {instance = id, argv = {acp_adapter_bin(root)}, cwd = scratch, has_cwd = true, env = env})
    defer pty_host_reply_delete(reply)
    if !received || reply.kind != .Spawned || reply.generation == "" do return false
    defer bridge_pty_host_close(socket, id)
    io, opened := acp_pipe_io_open(socket, id, reply.generation, "probe", "", 0); if !opened do return false
    p: ACP_Adapter_Probe
    c, client_ok := acp_rpc_open(io, {checkpoint = acp_adapter_probe_checkpoint})
    if !client_ok { io.close(io.data); io.destroy(io.data); return false }
    defer acp_rpc_close(c)
    rpc_id, sent := acp_rpc_request(c, "initialize", ACP_INITIALIZE_PARAMS, 15000, {acp_adapter_probe_result, &p})
    delete(string(rpc_id))
    if !sent do return false
    deadline := time.time_add(time.now(), 16*time.Second)
    sync.mutex_lock(&p.mu)
    for !p.done && time.diff(time.now(), deadline) > 0 { sync.cond_wait_with_timeout(&p.cond, &p.mu, 100*time.Millisecond) }
    result := p.done && p.ok; sync.mutex_unlock(&p.mu)
    return result
}

acp_adapter_install :: proc(provider, etag, version: string) -> (ok: bool, reason: string) {
    if _, valid := acp_adapter_recipe(provider); !valid || version != ACP_CLAUDE_VERSION do return false, "unsupported_acp_adapter"
    current := bridge_provider_catalog_current_etag(); defer delete(current)
    if etag != current do return false, "provider_catalog_stale"
    root := acp_adapter_root(); defer delete(root)
    before := acp_adapter_status(provider)
    if before.state == "missing_node" do return false, "acp_adapter_missing_node"
    if before.state == "ready" do return true, ""
    parent := filepath.dir(root)
    if bridge_make_directory_all(parent) != nil do return false, "acp_adapter_directory_failed"
    lock_path := strings.concatenate({root, ".lock"}); defer delete(lock_path)
    lock, err := os.open(lock_path, {.Write, .Create, .Excl}, {.Read_User, .Write_User})
    if err != nil do return false, "acp_adapter_install_in_progress"
    defer { os.close(lock); os.remove(lock_path) }
    defer {
        raw, _ := json.marshal(struct{state, error, checked_at: string}{"ready" if ok else "error", reason, bridge_provider_probe_time()}, allocator = context.temp_allocator)
        bridge_retry_atomic_write(strings.concatenate({root, ".status.json"}, context.temp_allocator), raw)
    }
    if s := acp_adapter_status(provider); s.state == "ready" do return true, ""
    stage := strings.concatenate({root, fmt.tprintf(".stage-%d", time.tick_now()._nsec)}); defer delete(stage)
    if bridge_make_directory_all(stage) != nil do return false, "acp_adapter_directory_failed"
    defer os.remove_all(stage)
    out, diagnostic, _, installed, _ := acp_adapter_runner({"npm", "install", "--prefix", stage, "--save-exact", "--no-audit", "--no-fund", ACP_CLAUDE_PACKAGE+"@"+ACP_CLAUDE_VERSION}, 100*time.Second)
    delete(out); delete(diagnostic) // Never expose npm diagnostics/environment.
    if !installed do return false, "acp_adapter_install_failed"
    if !acp_adapter_files_valid(stage) do return false, "acp_adapter_integrity_failed"
    scratch := strings.concatenate({stage, "/probe"}, context.temp_allocator)
    if bridge_make_directory_all(scratch) != nil || !acp_adapter_probe_hook(stage, scratch) do return false, "acp_adapter_probe_failed"
    if !bridge_retry_atomic_write(strings.concatenate({stage, "/heimdall-probe-v1.json"}, context.temp_allocator), transmute([]byte)string(ACP_CLAUDE_INTEGRITY)) do return false, "acp_adapter_directory_failed"
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
    frame := bridge_command_result_json(command, "succeeded" if ok else "failed", reason)
    defer delete(frame)
    bridge_hub_send(conn, frame)
}
