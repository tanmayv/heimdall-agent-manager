package main

import "core:encoding/json"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"

// Shared by probe receipts and the encrypted runtime journal. No environment
// values or credentials enter this binding. A launch freezes the selected
// profile revision and resolved CLI version, independently of installation.
ACP_Runtime_Binding :: struct {
    provider, descriptor_id: string,
    descriptor_revision: int,
    package_name, package_version, package_integrity: string,
    cli_version, profile, platform, bootstrap_filename: string,
    profile_revision: i64,
}

acp_provider_binding :: proc(d: contracts.ACP_Provider_Descriptor, profile, cli_version, bootstrap: string, revision: i64 = 0) -> ACP_Runtime_Binding {
    return {provider = d.provider, descriptor_id = d.id, descriptor_revision = d.revision,
        package_name = d.pkg.name, package_version = d.pkg.version, package_integrity = d.pkg.integrity,
        cli_version = cli_version, profile = profile_effective_id(d.provider, profile),
        platform = fmt.tprintf("%v/%v", ODIN_OS, ODIN_ARCH), bootstrap_filename = bootstrap, profile_revision = revision}
}

acp_provider_binding_valid :: proc(b: ACP_Runtime_Binding) -> bool {
    d, known := contracts.acp_provider_descriptor(b.provider)
    if !known || b.descriptor_id != d.id || b.descriptor_revision != d.revision ||
       b.package_name != d.pkg.name || b.package_version != d.pkg.version || b.package_integrity != d.pkg.integrity ||
       b.platform != fmt.tprintf("%v/%v", ODIN_OS, ODIN_ARCH) || !profile_id_valid(b.profile) ||
       !bridge_bootstrap_is_safe_bootstrap_name(b.bootstrap_filename) || b.bootstrap_filename == "" { return false }
    return contracts.acp_descriptor_cli_version_accepted(d, b.cli_version)
}

acp_provider_binding_equal :: proc(a, b: ACP_Runtime_Binding) -> bool {
    return a.provider == b.provider && a.descriptor_id == b.descriptor_id && a.descriptor_revision == b.descriptor_revision &&
        a.package_name == b.package_name && a.package_version == b.package_version && a.package_integrity == b.package_integrity &&
        a.cli_version == b.cli_version && a.profile == b.profile && a.platform == b.platform &&
        a.bootstrap_filename == b.bootstrap_filename && a.profile_revision == b.profile_revision
}

acp_provider_binding_copy :: proc(b: ACP_Runtime_Binding) -> ACP_Runtime_Binding {
    result := b
    result.provider = strings.clone(b.provider); result.descriptor_id = strings.clone(b.descriptor_id)
    result.package_name = strings.clone(b.package_name); result.package_version = strings.clone(b.package_version)
    result.package_integrity = strings.clone(b.package_integrity); result.cli_version = strings.clone(b.cli_version)
    result.profile = strings.clone(b.profile); result.platform = strings.clone(b.platform)
    result.bootstrap_filename = strings.clone(b.bootstrap_filename)
    return result
}

acp_provider_binding_delete :: proc(b: ^ACP_Runtime_Binding) {
    delete(b.provider); delete(b.descriptor_id); delete(b.package_name); delete(b.package_version); delete(b.package_integrity)
    delete(b.cli_version); delete(b.profile); delete(b.platform); delete(b.bootstrap_filename)
    b^ = {}
}

acp_provider_marker_valid :: proc(raw: string, expected: ACP_Runtime_Binding) -> bool {
    // The legacy integrity-only marker deliberately cannot certify this
    // contract, another profile, or another provider's runtime.
    actual: ACP_Runtime_Binding
    if json.unmarshal_string(raw, &actual, allocator = context.temp_allocator) != nil do return false
    return acp_provider_binding_valid(actual) && acp_provider_binding_equal(actual, expected)
}

acp_provider_profile_binding :: proc(pp: ^Provider_Profile) -> (ACP_Runtime_Binding, bool) {
    d, known := contracts.acp_provider_descriptor(pp.provider)
    if !known do return {}, false
    version, reason, _ := acp_provider_cli_version(pp)
    if reason != "" do return {}, false
    binding := acp_provider_binding(d, pp.profile_id, version, bridge_bootstrap_agents_md_name(pp.provider), pp.updated_at)
    return binding, acp_provider_binding_valid(binding)
}

acp_adapter_profile_binding :: proc(provider, profile: string) -> (ACP_Runtime_Binding, bool) {
    context.allocator = context.temp_allocator
    pp, err := profile_lookup(provider, profile)
    if err != .None do return {}, false
    return acp_provider_profile_binding(&pp)
}

acp_adapter_upgrade_legacy_marker :: proc(root: string, binding: ACP_Runtime_Binding) -> bool {
    d, known := contracts.acp_provider_descriptor(binding.provider)
    // Compatibility never lets a legacy path/receipt certify a future revision.
    if !known || !contracts.acp_descriptor_legacy_runtime(d) do return false
    old, err := os.read_entire_file(strings.concatenate({root, "/heimdall-probe-v1.json"}, context.temp_allocator), context.temp_allocator)
    if err != nil || string(old) != d.pkg.integrity do return false
    pp, perr := profile_lookup(binding.provider, binding.profile)
    if perr != .None do return false
    return acp_adapter_ensure_profile(&pp, binding)
}

acp_legacy_bootstrap_filename :: proc(run_dir, instance: string) -> (string, bool) {
    raw, err := os.read_entire_file(strings.concatenate({run_dir, "/heimdall-bootstrap-manifest.json"}, context.temp_allocator), context.temp_allocator)
    if err != nil do return "", false
    manifest: struct { agent_instance_id: string, managed_files: []struct { relative_path, kind: string } }
    if json.unmarshal(raw, &manifest, allocator = context.temp_allocator) != nil || manifest.agent_instance_id != instance do return "", false
    name := ""
    for file in manifest.managed_files {
        if file.kind != "AGENTS_MD" do continue
        if name != "" || file.relative_path == "" || !bridge_bootstrap_is_safe_bootstrap_name(file.relative_path) do return "", false
        name = file.relative_path
    }
    if name == "" || !os.exists(strings.concatenate({run_dir, "/", name}, context.temp_allocator)) do return "", false
    return name, true
}

// Coordinator-approved compatibility boundary: the old journal never stored
// CLI version/profile revision. Bind current values only after its saved
// provider/profile matches the authoritative launch intent. No RPC is sent.
acp_runtime_upgrade_legacy_state :: proc(s: ^ACP_State, intent: ACP_Hub_Intent, path: string, rec: Bridge_Local_Agent_Token_Record) -> (bool, string) {
    context.allocator = runtime.heap_allocator()
    d, known := contracts.acp_provider_descriptor(s.provider)
    if !known || !contracts.acp_descriptor_legacy_runtime(d) || s.schema_version != 1 || s.runtime_binding_version != 0 ||
       !acp_provider_binding_equal(s.binding, {}) ||
       s.adapter_version != d.pkg.version || s.profile == "" || s.profile != profile_effective_id(intent.provider, intent.profile) ||
       s.provider != intent.provider || !acp_rpc_restore_checkpoint_valid(s, true) { return false, "acp_restart_required" }
    pp, perr := profile_lookup(s.provider, s.profile)
    if perr != .None do return false, "acp_restart_required"
    binding, bound := acp_provider_profile_binding(&pp)
    filename, managed := acp_legacy_bootstrap_filename(s.run_dir, s.instance)
    if !bound || !managed do return false, "acp_restart_required"
    binding.bootstrap_filename = filename
    acp_provider_binding_delete(&s.binding); s.binding = acp_provider_binding_copy(binding)
    s.schema_version = 3
    s.runtime_binding_version = 1
    r, valid := acp_runtime_from_state(s, rec)
    if !valid do return false, "acp_restart_required"
    corrupted := r.d.error == "acp_protocol_error"
    acp_runtime_destroy(r)
    if corrupted do return false, "acp_restart_required"
    if !acp_state_write(path, s) do return false, "acp_state_write_failed"
    fmt.printf("ACP_LEGACY_BIND instance=%q provider=%q profile=%q revision=%d cli_version=%q\n", s.instance, s.provider, s.profile, binding.profile_revision, binding.cli_version)
    return true, ""
}

// Shared by installation probes and managed spawns. System argv is the
// resolved CLI plus fixed ACP flags; adapter argv is the managed package bin.
acp_provider_launch_argv :: proc(d: contracts.ACP_Provider_Descriptor, root, resolved_cli: string) -> ([]string, bool) {
    argv := make([dynamic]string, allocator = context.temp_allocator)
    switch d.launch {
    case .System:
        if resolved_cli == "" do return nil, false
        append(&argv, resolved_cli)
    case .Adapter:
        if root == "" do return nil, false
        append(&argv, strings.concatenate({root, "/node_modules/.bin/", d.command}, context.temp_allocator))
    case: return nil, false
    }
    append(&argv, ..d.args)
    // Protocol-owned per-child overrides (e.g. disabling native hooks that
    // the driver replaces).
    if driver := acp_protocol_driver(d.protocol); driver != nil && driver.launch_args != nil do driver.launch_args(&argv)
    return argv[:], true
}

acp_adapter_marker_path :: proc(root, profile: string) -> string {
    if root == "" || !profile_id_valid(profile) do return ""
    return strings.concatenate({root, "/heimdall-probes/", profile, ".json"}, context.temp_allocator)
}

acp_adapter_marker_matches :: proc(root: string, binding: ACP_Runtime_Binding) -> bool {
    path := acp_adapter_marker_path(root, binding.profile)
    if path == "" do return false
    raw, err := os.read_entire_file(path, context.temp_allocator)
    return err == nil && acp_provider_marker_valid(string(raw), binding)
}

acp_adapter_marker_write :: proc(root: string, binding: ACP_Runtime_Binding) -> bool {
    if !acp_provider_binding_valid(binding) do return false
    path := acp_adapter_marker_path(root, binding.profile)
    if path == "" || bridge_make_directory_all(filepath.dir(path)) != nil do return false
    raw, err := json.marshal(binding, allocator = context.temp_allocator)
    return err == nil && bridge_retry_atomic_write(path, raw)
}

// A shared installation never certifies another profile. Probe under the same
// stable advisory lock as installation, without agent credentials/project files.
acp_adapter_ensure_profile :: proc(pp: ^Provider_Profile, binding: ACP_Runtime_Binding) -> bool {
    context.allocator = context.temp_allocator
    if !acp_provider_binding_valid(binding) || pp.provider != binding.provider ||
       profile_effective_id(pp.provider, pp.profile_id) != binding.profile { return false }
    root := acp_adapter_root(pp.provider); defer delete(root)
    lock, state := acp_adapter_lock_acquire(strings.concatenate({root, ".lock"}, context.temp_allocator))
    if state != .Acquired do return false
    defer acp_adapter_lock_release(lock)
    if !acp_adapter_files_valid(root, pp.provider) do return false
    if acp_adapter_marker_matches(root, binding) do return true
    scratch := strings.concatenate({root, fmt.tprintf(".stage-profile-%d", time.tick_now()._nsec)}, context.temp_allocator)
    if bridge_make_directory_all(scratch) != nil do return false
    defer os.remove_all(scratch)
    probed, _ := acp_adapter_profile_probe_hook(pp, root, scratch)
    latest, bound := acp_adapter_binding_hook(pp.provider, pp.profile_id)
    return probed && bound && acp_provider_binding_equal(binding, latest) && acp_adapter_marker_write(root, binding)
}
