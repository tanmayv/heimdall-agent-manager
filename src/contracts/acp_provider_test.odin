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
