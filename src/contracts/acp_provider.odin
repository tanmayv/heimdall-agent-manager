package contracts

import "core:strings"

// This is executable policy compiled into Heimdall, not a catalog-supplied
// shell recipe. Adding a provider requires an explicit reviewed registry entry.
// Heimdall never installs a provider CLI (claude, codex, copilot, kiro, ...):
// System runtimes are user-installed CLIs detected on the bridge host (PATH or
// the profile binary_path) and checked against a minimum version. Only Adapter
// runtimes are installed, and only as a pinned, published npm package.
ACP_Protocol :: enum { ACP, Codex_App_Server }
ACP_Launch_Kind :: enum { Adapter, System }
ACP_Permission_Policy :: enum { Session_Mode, Once_Only }
ACP_Package_Pin :: struct {
    name, version, integrity: string,
}
ACP_Provider_Descriptor :: struct {
    provider, id, display_name: string,
    revision: int,
    launch: ACP_Launch_Kind,
    protocol: ACP_Protocol,
    // Adapter: the exact published npm package to install. System: the
    // package/product the user installs and its minimum accepted version.
    pkg: ACP_Package_Pin,
    // System only: the operating systems the CLI ships for. The CLI binary,
    // its `--version` format and auth guidance live in the provider registry
    // (provider_descriptor(provider)).
    system_os: []string,
    discover_models_via_acp: bool, // opt in after a metadata-only session probe is verified
    // System only. agent_default_model is the catalog model id that keeps the
    // agent's own default model (no session/set_config_option). With
    // bootstrap_resource_link, an agent that does not advertise embeddedContext
    // gets the bootstrap file as a baseline ACP resource_link instead.
    agent_default_model: string,
    bootstrap_resource_link: bool,
    command: string,
    args: []string,
    env: [][2]string,
    protocol_version, node_min_major: int,
    executable_env: string,
    bootstrap_filename: string,
    permission_policy: ACP_Permission_Policy,
    model_category, permission_category, ask_mode, yolo_mode: string,
}

ACP_CLAUDE_DESCRIPTOR :: ACP_Provider_Descriptor{
    protocol = .ACP, provider = "claude", id = "claude-acp", display_name = "Claude", revision = 1, launch = .Adapter,
    pkg = {"@agentclientprotocol/claude-agent-acp", "0.108.0", "sha512-Y0HI3CB0DfhpWItCn2RE3xgpen001V2U/bHm3G6ZVKXsElF5N4uYyjYlmgNzZBKcBtZK0JqiE96NMaeVXtgJjw=="},
    command = "claude-agent-acp", env = {{"CLAUDE_AGENT_ACP_PROTOCOL", "v1"}},
    protocol_version = 1, node_min_major = 22,
    executable_env = "CLAUDE_CODE_EXECUTABLE",
    bootstrap_filename = "CLAUDE.md",
    permission_policy = .Session_Mode, model_category = "model", permission_category = "mode",
    ask_mode = "default", yolo_mode = "bypassPermissions",
}

// Copilot is detect-only: the user installs the GitHub Copilot CLI (npm
// package @github/copilot, Homebrew or WinGet) and pkg.version is the minimum
// accepted version. The catalog recipe names the npm package, so pkg.name is
// that package rather than the `copilot` binary.
ACP_COPILOT_DESCRIPTOR :: ACP_Provider_Descriptor{
    protocol = .ACP, provider = "copilot", id = "copilot-acp", display_name = "Copilot", revision = 1, launch = .System,
    pkg = {"@github/copilot", "1.0.114", ""}, system_os = {"linux", "darwin", "windows"},
    command = "copilot", args = {"--acp", "--stdio"}, env = {{"COPILOT_AUTO_UPDATE", "false"}},
    protocol_version = 1,
    bootstrap_filename = "AGENTS.md",
    permission_policy = .Once_Only, model_category = "model",
}

// Kiro is detect-only: pkg names the user-installed CLI and pkg.version is the
// minimum accepted version, not a pin. Pass no v2-only flags (--model, --agent,
// --trust-all-tools): any of them silently switches `kiro-cli acp` to the v2
// engine. Credentials live under XDG_DATA_HOME, settings under KIRO_HOME.
ACP_KIRO_DESCRIPTOR :: ACP_Provider_Descriptor{
    protocol = .ACP, provider = "kiro", id = "kiro-acp", display_name = "Kiro", revision = 1, launch = .System,
    pkg = {"kiro-cli", "3.5.0", ""}, system_os = {"linux", "darwin"},
    discover_models_via_acp = true, command = "kiro-cli", args = {"acp", "--agent-engine", "v3"},
    protocol_version = 1,
    agent_default_model = "default", bootstrap_resource_link = true,
    bootstrap_filename = "AGENTS.md",
    permission_policy = .Once_Only, model_category = "model",
}

// Codex is detect-only. Its app-server uses its own NDJSON protocol rather
// than ACP; the protocol driver presents the shared runtime to the bridge.
// Verified with the generated schema and initialize on codex-cli 0.162.0.
ACP_CODEX_DESCRIPTOR :: ACP_Provider_Descriptor{
    protocol = .Codex_App_Server, provider = "codex", id = "codex-app-server", display_name = "Codex", revision = 1, launch = .System,
    pkg = {"codex", "0.162.0", ""}, system_os = {"linux", "darwin", "windows"},
    command = "codex", args = {"app-server"},
    protocol_version = 1,
    bootstrap_filename = "AGENTS.md",
    permission_policy = .Once_Only, model_category = "model",
}

// OpenCode is an operator-installed stdio ACP agent. Its internal providers
// and credentials belong to OpenCode, not the Heimdall catalog.
ACP_OPENCODE_DESCRIPTOR :: ACP_Provider_Descriptor{
    protocol = .ACP, provider = "opencode", id = "opencode-acp", display_name = "OpenCode", revision = 1, launch = .System,
    pkg = {"opencode", "1.19.6", ""}, system_os = {"linux", "darwin", "windows"},
    command = "opencode", args = {"acp"}, protocol_version = 1,
    discover_models_via_acp = true,
    agent_default_model = "default", bootstrap_filename = "AGENTS.md",
    permission_policy = .Once_Only, model_category = "model",
}

// Persistent backing storage is required: returning a descriptor copied from
// a constant slice literal leaves its nested env/argv slices on the caller's
// stack in Odin. Descriptors returned by lookup retain these immutable arrays.
@(private)
acp_provider_descriptors := [?]ACP_Provider_Descriptor{ACP_CLAUDE_DESCRIPTOR, ACP_COPILOT_DESCRIPTOR, ACP_KIRO_DESCRIPTOR, ACP_CODEX_DESCRIPTOR, ACP_OPENCODE_DESCRIPTOR}

acp_provider_descriptor :: proc(provider: string) -> (ACP_Provider_Descriptor, bool) {
    for d in acp_provider_descriptors do if d.provider == provider do return d, true
    return {}, false
}

// Shape validation is separate from registry membership. Adapters bind an exact
// published package and the resolved underlying executable; system CLIs launch
// the registered provider binary and bind a minimum version and the operating
// systems they ship for. No shape enables a provider.
acp_descriptor_shape_valid :: proc(d: ACP_Provider_Descriptor) -> bool {
    // Every ACP runtime belongs to a registered provider, which supplies its CLI
    // binary, version format and auth guidance.
    provider, registered := provider_descriptor(d.provider)
    if !registered || provider.provider != d.provider do return false
    if d.provider == "" || d.id == "" || d.revision < 1 || d.protocol_version != 1 ||
       d.command == "" || !exact_adapter_version(d.pkg.version) ||
       d.pkg.name == "" || d.bootstrap_filename == "" ||
       strings.contains_any(d.bootstrap_filename, "/\\") || strings.contains(d.bootstrap_filename, "..") ||
       d.model_category == "" { return false }
    if d.protocol != .ACP && d.protocol != .Codex_App_Server do return false
    if d.discover_models_via_acp && (d.protocol != .ACP || d.launch != .System) do return false
    switch d.launch {
    case .Adapter:
        if !strings.has_prefix(d.pkg.integrity, "sha512-") || len(d.pkg.integrity) != 95 || d.node_min_major < 22 ||
           len(d.system_os) != 0 || d.agent_default_model != "" || d.bootstrap_resource_link || d.executable_env == "" { return false }
    case .System:
        // Nothing is downloaded, so there is no integrity or Node pin. The
        // launched command is the registered provider binary.
        if d.pkg.integrity != "" || d.node_min_major != 0 || d.executable_env != "" ||
           d.command != provider.binary || len(d.system_os) == 0 { return false }
        // The minimum version is checked, so the CLI's version must be parseable.
        if provider.version_format == .Raw do return false
        for name, i in d.system_os {
            if name == "" do return false
            for previous in d.system_os[:i] do if previous == name do return false
        }
    case: return false
    }
    switch d.permission_policy {
    case .Session_Mode: return d.permission_category != "" && d.ask_mode != "" && d.yolo_mode != ""
    case .Once_Only: return d.permission_category == "" && d.ask_mode == "" && d.yolo_mode == ""
    }
    return false
}

// A detected CLI version is acceptable when it is an exact numeric version and,
// for system CLIs, at least the minimum. An adapter's underlying CLI (e.g.
// Claude Code beneath claude-agent-acp) sets no minimum here.
acp_descriptor_cli_version_accepted :: proc(d: ACP_Provider_Descriptor, version: string) -> bool {
    if !exact_adapter_version(version) do return false
    if d.launch == .System {
        provider, registered := provider_descriptor(d.provider)
        return registered && provider_version_status(provider, version) == .Ok
    }
    return true
}

// Both inputs must already be exact numeric versions.
acp_semver_compare :: proc(a, b: string) -> int {
    pa := strings.split(a, ".", context.temp_allocator)
    pb := strings.split(b, ".", context.temp_allocator)
    for i in 0..<min(len(pa), len(pb)) {
        // Equal-length digit strings without leading zeros compare lexically.
        if len(pa[i]) != len(pb[i]) do return -1 if len(pa[i]) < len(pb[i]) else 1
        if pa[i] != pb[i] do return -1 if pa[i] < pb[i] else 1
    }
    return len(pa) - len(pb)
}

acp_descriptor_recipe_matches :: proc(d: ACP_Provider_Descriptor, r: ACP_Recipe) -> bool {
    if r.command != d.command || r.adapter_package != d.pkg.name || r.adapter_version != d.pkg.version ||
       r.protocol_version != d.protocol_version || len(r.args) != len(d.args) || len(r.env) != len(d.env) { return false }
    for arg, i in r.args do if arg != d.args[i] do return false
    for pair in d.env do if value, exists := r.env[pair[0]]; !exists || value != pair[1] do return false
    return true
}

acp_descriptor_permission_mode :: proc(d: ACP_Provider_Descriptor, mode: string) -> (string, bool) {
    if d.permission_policy == .Once_Only {
        switch mode {
        case "", "yolo": return "yolo", true
        case "ask": return "ask", true
        }
        return "", false
    }
    if d.permission_policy != .Session_Mode do return "", false
    switch mode {
    case "", "yolo": return d.yolo_mode, true
    case "ask": return d.ask_mode, true
    }
    return "", false
}

// Journals store the effective policy, rather than the user-facing alias.
acp_descriptor_effective_mode_valid :: proc(d: ACP_Provider_Descriptor, mode: string) -> bool {
    switch d.permission_policy {
    case .Session_Mode: return mode != "" && (mode == d.ask_mode || mode == d.yolo_mode)
    case .Once_Only: return mode == "ask" || mode == "yolo"
    }
    return false
}

acp_descriptor_system_os_supported :: proc(d: ACP_Provider_Descriptor, os: string) -> bool {
    for supported in d.system_os do if supported == os do return true
    return false
}

