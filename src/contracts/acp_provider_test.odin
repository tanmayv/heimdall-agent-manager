package contracts

import "core:testing"

@(test)
acp_descriptor_once_only_policy_is_independent_of_session_modes :: proc(t: ^testing.T) {
    d := ACP_Provider_Descriptor{permission_policy = .Once_Only}
    for policy in ([]string{"ask", "yolo"}) {
        effective, valid := acp_descriptor_permission_mode(d, policy)
        testing.expect(t, valid && effective == policy && acp_descriptor_effective_mode_valid(d, effective))
    }
    effective, valid := acp_descriptor_permission_mode(d, "")
    testing.expect(t, valid && effective == "yolo")
    for invalid in ([]string{"default", "bypassPermissions", "autopilot", "allow_always"}) {
        _, valid := acp_descriptor_permission_mode(d, invalid)
        testing.expect(t, !valid && !acp_descriptor_effective_mode_valid(d, invalid))
    }
    testing.expect(t, !acp_descriptor_effective_mode_valid(d, ""))
    testing.expect(t, !acp_descriptor_effective_mode_valid(ACP_CLAUDE_DESCRIPTOR, "ask"))
    testing.expect(t, acp_descriptor_effective_mode_valid(ACP_CLAUDE_DESCRIPTOR, "default"))
}

@(test)
acp_descriptor_closed_registry_and_launch_shapes :: proc(t: ^testing.T) {
    d, ok := acp_provider_descriptor("claude")
    testing.expect(t, ok && acp_descriptor_shape_valid(d) && d.launch == .Adapter)
    for provider in ([]string{"", "pi", "unknown", "CLAUDE"}) {
        _, enabled := acp_provider_descriptor(provider)
        testing.expect(t, !enabled)
    }
    copilot, enabled := acp_provider_descriptor("copilot")
    testing.expect(t, enabled && acp_descriptor_shape_valid(copilot) && copilot.launch == .Native)
    // Additional platforms still require a reviewed registry change.
    native := ACP_Provider_Descriptor{
        provider = "copilot", id = "copilot-acp", revision = 1, launch = .Native,
        pkg = {"@github/copilot", "1.0.114", "sha512-qhiUzWGAu3v9jRMU62YFpoI/x9/sQJbylUU2rNrKpTgJSw+jRX7eee0RKf/ZC/FfOPtuACpXWNBQrf08WhVEEw=="},
        platforms = {{"linux", "amd64", {"@github/copilot-linux-x64", "1.0.114", "sha512-gHnINm9ffFqz+G19cQUqRe3lsTAQO3Tbdj7r7Bx1ktZvC5X6iXd/nfo1DRTj9magb52aGRiuwB3yvD1lkW68xQ=="}}},
        command = "copilot", args = {"--acp", "--stdio"}, env = {{"COPILOT_AUTO_UPDATE", "false"}},
        cli_command = "copilot", cli_package = "@github/copilot", cli_version = "1.0.114",
        protocol_version = 1, node_min_major = 22, bootstrap_filename = "AGENTS.md",
        auth_guidance = "Run copilot login with the selected profile.", model_category = "model", permission_policy = .Once_Only,
    }
    testing.expect(t, acp_descriptor_shape_valid(native))
    platform, supported := acp_descriptor_platform_package(native, "linux", "amd64")
    testing.expect(t, supported && platform.name == "@github/copilot-linux-x64")
    _, supported = acp_descriptor_platform_package(native, "linux", "arm64")
    testing.expect(t, !supported)
    native.platforms = nil
    testing.expect(t, !acp_descriptor_shape_valid(native))
    native = d; native.launch = .Native
    testing.expect(t, !acp_descriptor_shape_valid(native))
    mode, mode_supported := acp_descriptor_permission_mode(d, "ask")
    testing.expect(t, mode_supported && mode == "default")
}

@(test)
acp_descriptor_recipe_rejects_substitution_and_unknown_fields :: proc(t: ^testing.T) {
    raw :: `{"command":"claude-agent-acp","args":[],"env":{"CLAUDE_AGENT_ACP_PROTOCOL":"v1"},"protocol_version":1,"adapter_package":"@agentclientprotocol/claude-agent-acp","adapter_version":"0.108.0"}`
    testing.expect(t, acp_provider_recipe_valid("claude", raw))
    testing.expect(t, !acp_provider_recipe_valid("copilot", raw))
    testing.expect(t, !acp_recipe_valid(`{"command":"claude-agent-acp","args":["--unsafe"],"env":{"CLAUDE_AGENT_ACP_PROTOCOL":"v1"},"protocol_version":1,"adapter_package":"@agentclientprotocol/claude-agent-acp","adapter_version":"0.108.0"}`))
    testing.expect(t, !acp_recipe_valid(`{"command":"claude-agent-acp","args":[],"env":{"CLAUDE_AGENT_ACP_PROTOCOL":"v1","EXTRA":"value"},"protocol_version":1,"adapter_package":"@agentclientprotocol/claude-agent-acp","adapter_version":"0.108.0"}`))
    testing.expect(t, !acp_recipe_valid(`{"command":"claude-agent-acp","args":[],"env":{"CLAUDE_AGENT_ACP_PROTOCOL":"v1"},"protocol_version":1,"adapter_package":"@agentclientprotocol/claude-agent-acp","adapter_version":"0.108.0","unknown":true}`))
}

@(test)
acp_copilot_platforms_pin_only_linux_amd64_and_darwin_arm64 :: proc(t: ^testing.T) {
    d, known := acp_provider_descriptor("copilot")
    testing.expect(t, known && len(d.platforms) == 2)
    linux, supported := acp_descriptor_platform_package(d, "linux", "amd64")
    testing.expect(t, supported && linux.name == "@github/copilot-linux-x64" && linux.version == "1.0.114")
    darwin, darwin_supported := acp_descriptor_platform_package(d, "darwin", "arm64")
    testing.expect(t, darwin_supported && darwin.name == "@github/copilot-darwin-arm64" && darwin.version == "1.0.114")
    testing.expect_value(t, darwin.integrity, "sha512-Mw47DTwMNDG0bb4t1rVu7S+ekdThIGGitpG28/wGpACZ0lFhYnpNEoSJ7hHBM3oix4b/w6+ZcmxE9J9MngsR9Q==")
    for target in ([][2]string{{"linux", "arm64"}, {"darwin", "amd64"}, {"windows", "amd64"}, {"windows", "arm64"}, {"freebsd", "amd64"}, {"", ""}}) {
        _, supported := acp_descriptor_platform_package(d, target[0], target[1])
        testing.expect(t, !supported)
    }
}

@(test)
acp_kiro_system_descriptor_is_detect_only :: proc(t: ^testing.T) {
    d, known := acp_provider_descriptor("kiro")
    testing.expect(t, known && d.launch == .System && acp_descriptor_shape_valid(d))
    testing.expect(t, d.pkg.integrity == "" && d.node_min_major == 0 && len(d.platforms) == 0)
    // v2-only flags would silently switch kiro-cli to its v2 engine.
    testing.expect_value(t, len(d.args), 3)
    for arg in d.args do testing.expect(t, arg != "--model" && arg != "--agent" && arg != "-a" && arg != "--trust-all-tools")
    testing.expect(t, d.permission_policy == .Once_Only && d.model_category == "model")
    testing.expect(t, acp_descriptor_system_os_supported(d, "linux") && acp_descriptor_system_os_supported(d, "darwin"))
    testing.expect(t, !acp_descriptor_system_os_supported(d, "windows"))

    // A system shape cannot carry download pins, and adapters cannot borrow it.
    invalid := d; invalid.pkg.integrity = "sha512-x"
    testing.expect(t, !acp_descriptor_shape_valid(invalid))
    invalid = d; invalid.node_min_major = 22
    testing.expect(t, !acp_descriptor_shape_valid(invalid))
    invalid = d; invalid.system_os = nil
    testing.expect(t, !acp_descriptor_shape_valid(invalid))
    invalid = d; invalid.system_os = {"linux", "linux"}
    testing.expect(t, !acp_descriptor_shape_valid(invalid))
    invalid = d; invalid.cli_version_prefix = ""
    testing.expect(t, !acp_descriptor_shape_valid(invalid))
    invalid = d; invalid.pkg.name = "other"
    testing.expect(t, !acp_descriptor_shape_valid(invalid))
    invalid = d; invalid.cli_version = "3.5.0"
    testing.expect(t, !acp_descriptor_shape_valid(invalid))
    claude, _ := acp_provider_descriptor("claude")
    invalid = claude; invalid.cli_version_prefix = "claude "
    testing.expect(t, !acp_descriptor_shape_valid(invalid))
}

@(test)
acp_cli_version_minimum_and_pins :: proc(t: ^testing.T) {
    kiro, _ := acp_provider_descriptor("kiro")
    for accepted in ([]string{"3.5.0", "3.5.1", "3.10.0", "4.0.0", "10.0.0"}) {
        testing.expectf(t, acp_descriptor_cli_version_accepted(kiro, accepted), "%s accepted", accepted)
    }
    for rejected in ([]string{"3.4.9", "2.21.4", "3.5", "v3.5.0", "3.5.0-beta", "03.5.0", ""}) {
        testing.expectf(t, !acp_descriptor_cli_version_accepted(kiro, rejected), "%s rejected", rejected)
    }
    copilot, _ := acp_provider_descriptor("copilot")
    testing.expect(t, acp_descriptor_cli_version_accepted(copilot, "1.0.114"))
    testing.expect(t, !acp_descriptor_cli_version_accepted(copilot, "1.0.115"))
    claude, _ := acp_provider_descriptor("claude")
    testing.expect(t, acp_descriptor_cli_version_accepted(claude, "2.9.1"))
    testing.expect_value(t, acp_semver_compare("3.10.0", "3.9.9"), 1)
    testing.expect_value(t, acp_semver_compare("3.5.0", "3.5.0"), 0)
    testing.expect_value(t, acp_semver_compare("2.21.4", "3.5.0"), -1)
}

@(test)
acp_kiro_recipe_binds_only_kiro :: proc(t: ^testing.T) {
    raw :: `{"command":"kiro-cli","args":["acp","--agent-engine","v3"],"env":{},"protocol_version":1,"adapter_package":"kiro-cli","adapter_version":"3.5.0"}`
    testing.expect(t, acp_provider_recipe_valid("kiro", raw))
    testing.expect(t, !acp_provider_recipe_valid("claude", raw))
    testing.expect(t, !acp_provider_recipe_valid("copilot", raw))
    testing.expect(t, !acp_recipe_valid(`{"command":"kiro-cli","args":["acp","--agent-engine","v2"],"env":{},"protocol_version":1,"adapter_package":"kiro-cli","adapter_version":"3.5.0"}`))
    testing.expect(t, !acp_recipe_valid(`{"command":"kiro-cli","args":["acp","--agent-engine","v3","--trust-all-tools"],"env":{},"protocol_version":1,"adapter_package":"kiro-cli","adapter_version":"3.5.0"}`))
    testing.expect(t, !acp_recipe_valid(`{"command":"kiro-cli","args":["acp","--agent-engine","v3"],"env":{},"protocol_version":1,"adapter_package":"kiro-cli","adapter_version":"3.4.0"}`))
}

@(test)
acp_bootstrap_link_and_default_model_are_system_only :: proc(t: ^testing.T) {
    kiro, _ := acp_provider_descriptor("kiro")
    testing.expect(t, kiro.bootstrap_resource_link && kiro.agent_default_model == "default")
    for provider in ([]string{"claude", "copilot"}) {
        d, _ := acp_provider_descriptor(provider)
        testing.expect(t, !d.bootstrap_resource_link && d.agent_default_model == "")
        d.bootstrap_resource_link = true
        testing.expect(t, !acp_descriptor_shape_valid(d))
        d.bootstrap_resource_link = false; d.agent_default_model = "default"
        testing.expect(t, !acp_descriptor_shape_valid(d))
    }
}

@(test)
acp_descriptor_protocol_registry_is_explicit :: proc(t: ^testing.T) {
    for provider in ([]string{"claude", "copilot", "kiro"}) {
        d, known := acp_provider_descriptor(provider)
        testing.expect(t, known && d.protocol == .ACP)
    }
    d := ACP_CLAUDE_DESCRIPTOR
    d.protocol = ACP_Protocol(99)
    testing.expect(t, !acp_descriptor_shape_valid(d))
}

@(test)
acp_codex_system_descriptor_recipe_and_version_floor :: proc(t: ^testing.T) {
    d, known := acp_provider_descriptor("codex")
    testing.expect(t, known && acp_descriptor_shape_valid(d) && d.launch == .System && d.protocol == .Codex_App_Server)
    testing.expect(t, d.permission_policy == .Once_Only && d.pkg.integrity == "" && d.node_min_major == 0 && len(d.platforms) == 0)
    testing.expect(t, d.bootstrap_filename == "AGENTS.md" && len(d.args) == 1 && d.args[0] == "app-server")
    for version in ([]string{"0.162.0", "0.166.0", "1.0.0"}) do testing.expect(t, acp_descriptor_cli_version_accepted(d, version))
    for version in ([]string{"0.161.9", "0.99.0", "0.162", "0.162.0-beta", "v0.162.0", ""}) do testing.expect(t, !acp_descriptor_cli_version_accepted(d, version))
    for name in ([]string{"linux", "darwin", "windows"}) do testing.expect(t, acp_descriptor_system_os_supported(d, name))
    testing.expect(t, !acp_descriptor_system_os_supported(d, "freebsd"))
    raw :: `{"command":"codex","args":["app-server"],"env":{},"protocol_version":1,"adapter_package":"codex","adapter_version":"0.162.0"}`
    testing.expect(t, acp_provider_recipe_valid("codex", raw))
    for provider in ([]string{"claude", "copilot", "kiro"}) do testing.expect(t, !acp_provider_recipe_valid(provider, raw))
    testing.expect(t, !acp_recipe_valid(`{"command":"codex","args":["exec"],"env":{},"protocol_version":1,"adapter_package":"codex","adapter_version":"0.162.0"}`))
    testing.expect(t, !acp_recipe_valid(`{"command":"codex","args":["app-server"],"env":{},"protocol_version":1,"adapter_package":"codex","adapter_version":"0.161.0"}`))
}

@(test)
acp_opencode_recipe_is_stdio_only_on_all_supported_os :: proc(t: ^testing.T) {
    d, known := acp_provider_descriptor("opencode")
    testing.expect(t, known && d.launch == .System && d.protocol == .ACP && acp_descriptor_shape_valid(d))
    for os in ([]string{"linux", "darwin", "windows"}) do testing.expect(t, acp_descriptor_system_os_supported(d, os))
    testing.expect(t, !acp_descriptor_system_os_supported(d, "freebsd"))
    testing.expect(t, d.agent_default_model == "default")
    testing.expect(t, !acp_descriptor_cli_version_accepted(d, "1.19.5"))
    testing.expect(t, acp_descriptor_cli_version_accepted(d, "1.19.6"))
    raw :: `{"command":"opencode","args":["acp"],"env":{},"protocol_version":1,"adapter_package":"opencode","adapter_version":"1.19.6"}`
    testing.expect(t, acp_provider_recipe_valid("opencode", raw))
    testing.expect(t, !acp_provider_recipe_valid("kiro", raw))
}

@(test)
acp_descriptor_cli_command_matches_provider_registry_binary :: proc(t: ^testing.T) {
    for d in acp_provider_descriptors {
        p, ok := provider_descriptor(d.provider)
        testing.expectf(t, ok, "%s: ACP descriptor without a provider registry entry", d.provider)
        testing.expectf(t, d.cli_command == p.binary, "%s: cli_command %q != registry binary %q", d.provider, d.cli_command, p.binary)
        testing.expectf(t, d.auth_guidance == p.auth_guidance, "%s: auth_guidance drifted from the registry", d.provider)
        version_label := "" if d.cli_version_bare else d.cli_version_prefix
        if d.launch == .System {
            testing.expectf(t, p.version_label == version_label, "%s: version label drifted from the registry", d.provider)
        }
    }
}
