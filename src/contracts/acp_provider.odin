package contracts

import "core:strings"

// This is executable policy compiled into Heimdall, not a catalog-supplied
// shell recipe. Adding a provider requires an explicit reviewed registry entry.
ACP_Launch_Kind :: enum { Adapter, Native }
ACP_Permission_Policy :: enum { Session_Mode, Once_Only }
ACP_Package_Pin :: struct {
    name, version, integrity: string,
}
ACP_Platform_Pin :: struct {
    os, arch: string,
    pkg: ACP_Package_Pin,
}
ACP_Provider_Descriptor :: struct {
    provider, id, display_name: string,
    revision: int,
    launch: ACP_Launch_Kind,
    pkg: ACP_Package_Pin,
    platforms: []ACP_Platform_Pin,
    command: string,
    args: []string,
    env: [][2]string,
    protocol_version, node_min_major: int,
    cli_command, cli_package, cli_version, executable_env: string,
    bootstrap_filename, auth_guidance: string,
    permission_policy: ACP_Permission_Policy,
    model_category, permission_category, ask_mode, yolo_mode: string,
}

ACP_CLAUDE_DESCRIPTOR :: ACP_Provider_Descriptor{
    provider = "claude", id = "claude-acp", display_name = "Claude", revision = 1, launch = .Adapter,
    pkg = {"@agentclientprotocol/claude-agent-acp", "0.108.0", "sha512-Y0HI3CB0DfhpWItCn2RE3xgpen001V2U/bHm3G6ZVKXsElF5N4uYyjYlmgNzZBKcBtZK0JqiE96NMaeVXtgJjw=="},
    command = "claude-agent-acp", env = {{"CLAUDE_AGENT_ACP_PROTOCOL", "v1"}},
    protocol_version = 1, node_min_major = 22,
    cli_command = "claude", executable_env = "CLAUDE_CODE_EXECUTABLE",
    bootstrap_filename = "CLAUDE.md",
    auth_guidance = "Run claude /login on the bridge host using the selected provider profile, then restart this instance.",
    permission_policy = .Session_Mode, model_category = "model", permission_category = "mode",
    ask_mode = "default", yolo_mode = "bypassPermissions",
}

// Persistent backing storage is required: returning a descriptor copied from
// a constant slice literal leaves its nested env/argv slices on the caller's
// stack in Odin. Descriptors returned by lookup retain these immutable arrays.
@(private)
acp_provider_descriptors := [?]ACP_Provider_Descriptor{ACP_CLAUDE_DESCRIPTOR}

acp_provider_descriptor :: proc(provider: string) -> (ACP_Provider_Descriptor, bool) {
    for d in acp_provider_descriptors do if d.provider == provider do return d, true
    return {}, false
}

// Shape validation is separate from registry membership. Native providers must
// bind their CLI pin and every supported native platform package; adapters bind
// the resolved underlying executable. Neither shape enables a provider.
acp_descriptor_shape_valid :: proc(d: ACP_Provider_Descriptor) -> bool {
    if d.provider == "" || d.id == "" || d.revision < 1 || d.protocol_version != 1 ||
       d.command == "" || d.cli_command == "" || !exact_adapter_version(d.pkg.version) ||
       !strings.has_prefix(d.pkg.integrity, "sha512-") || len(d.pkg.integrity) != 95 ||
       d.pkg.name == "" || d.node_min_major < 22 || d.bootstrap_filename == "" ||
       strings.contains_any(d.bootstrap_filename, "/\\") || strings.contains(d.bootstrap_filename, "..") ||
       d.auth_guidance == "" || d.model_category == "" { return false }
    switch d.launch {
    case .Adapter: if d.executable_env == "" do return false
    case .Native:
        if d.executable_env != "" || d.cli_package != d.pkg.name || d.cli_version != d.pkg.version || len(d.platforms) == 0 do return false
    case: return false
    }
    for pin, i in d.platforms {
        if pin.os == "" || pin.arch == "" || pin.pkg.name == "" || pin.pkg.version != d.pkg.version ||
           !strings.has_prefix(pin.pkg.integrity, "sha512-") || len(pin.pkg.integrity) != 95 { return false }
        for previous in d.platforms[:i] do if previous.os == pin.os && previous.arch == pin.arch do return false
    }
    switch d.permission_policy {
    case .Session_Mode: return d.permission_category != "" && d.ask_mode != "" && d.yolo_mode != ""
    case .Once_Only: return d.permission_category == "" && d.ask_mode == "" && d.yolo_mode == ""
    }
    return false
}

acp_descriptor_recipe_matches :: proc(d: ACP_Provider_Descriptor, r: ACP_Recipe) -> bool {
    if r.command != d.command || r.adapter_package != d.pkg.name || r.adapter_version != d.pkg.version ||
       r.protocol_version != d.protocol_version || len(r.args) != len(d.args) || len(r.env) != len(d.env) { return false }
    for arg, i in r.args do if arg != d.args[i] do return false
    for pair in d.env do if value, exists := r.env[pair[0]]; !exists || value != pair[1] do return false
    return true
}

acp_descriptor_permission_mode :: proc(d: ACP_Provider_Descriptor, mode: string) -> (string, bool) {
    if d.permission_policy != .Session_Mode do return "", false
    switch mode {
    case "", "yolo": return d.yolo_mode, true
    case "ask": return d.ask_mode, true
    }
    return "", false
}

acp_descriptor_platform_package :: proc(d: ACP_Provider_Descriptor, os, arch: string) -> (ACP_Package_Pin, bool) {
    for pin in d.platforms do if pin.os == os && pin.arch == arch do return pin.pkg, true
    return {}, false
}
