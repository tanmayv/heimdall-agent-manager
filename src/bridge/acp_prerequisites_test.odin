#+build !windows
package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file") r2_host: []string
@(private = "file") r2_node: string // "" = node does not run
@(private = "file") r2_npm: bool
@(private = "file") r2_npm_install_fails: bool
@(private = "file") r2_npm_installs: int
@(private = "file") r2_runner_calls: int

@(private = "file")
r2_host_has :: proc(detect: string) -> bool {
    for name in r2_host do if name == detect do return true
    return false
}

@(private = "file")
r2_runner :: proc(argv: []string, timeout: time.Duration) -> (string, string, int, bool, bool) {
    r2_runner_calls += 1
    if len(argv) == 2 && argv[0] == "node" && argv[1] == "--version" {
        if r2_node == "" do return "", "", -1, false, false
        return strings.clone(r2_node), "", 0, true, false
    }
    if len(argv) == 2 && argv[0] == "npm" && argv[1] == "--version" {
        if !r2_npm do return "", "", -1, false, false
        return strings.clone("10.8.2\n"), "", 0, true, false
    }
    if len(argv) > 1 && argv[0] == "npm" && argv[1] == "install" do r2_npm_installs += 1
    if r2_npm_install_fails {
        stderr := "npm error code E404\n" +
            "npm error 404 Not Found - GET https://deploy:hunter2@registry.npmjs.org/@agentclientprotocol%2fclaude-agent-acp\n" +
            "//registry.npmjs.org/:_authToken=npm_SYNTHETIC_TOKEN\n" +
            "NPM_CONFIG_REGISTRY=https://private.example\n" +
            "npm error A complete log of this run can be found in: /tmp/npm-debug.log\n"
        return strings.clone("stdout must not be preferred"), strings.clone(stderr), 1, true, false
    }
    return t4_adapter_fake_runner(argv, timeout)
}

// G4/G5: Node.js and npm are detected separately on every status read, each
// missing or too old tool names the exact install command for the host, and
// installing them flips the state on the next detection without a restart.
@(test)
r2_acp_adapter_node_npm_detected_live_with_install_commands :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    old_runner, old_probe, old_cli, old_binding, old_host := acp_adapter_runner, acp_adapter_probe_hook, acp_adapter_cli_probe_hook, acp_adapter_binding_hook, acp_host_has_hook
    defer { acp_adapter_runner = old_runner; acp_adapter_probe_hook = old_probe; acp_adapter_cli_probe_hook = old_cli; acp_adapter_binding_hook = old_binding; acp_host_has_hook = old_host }
    acp_adapter_runner = r2_runner; acp_adapter_probe_hook = t4_adapter_fake_probe
    acp_adapter_cli_probe_hook = t4_adapter_fake_claude_probe; acp_adapter_binding_hook = t4_adapter_fake_binding
    acp_host_has_hook = r2_host_has
    r2_host = {"dnf"}; r2_node = ""; r2_npm = false; r2_npm_install_fails = false; r2_npm_installs = 0
    snapshot := bridge_provider_catalog_snapshot
    snapshot.etag = "sha256:r2"
    snapshot.providers[0].acp_recipe = {command = "claude-agent-acp", protocol_version = 1,
        adapter_package = ACP_CLAUDE_PACKAGE, adapter_version = ACP_CLAUDE_VERSION, env = make(map[string]string)}
    snapshot.providers[0].acp_recipe.env["CLAUDE_AGENT_ACP_PROTOCOL"] = "v1"
    defer delete(snapshot.providers[0].acp_recipe.env)

    // Missing Node.js.
    status := acp_adapter_status("claude")
    testing.expect_value(t, status.state, "missing_node")
    testing.expect_value(t, status.install_command, "sudo dnf install -y nodejs npm")
    testing.expect_value(t, status.error, "Node.js 22 or newer is required on the bridge host to run the Claude ACP adapter; install it with: sudo dnf install -y nodejs npm")
    status_json := acp_adapter_status_json("claude")
    testing.expect(t, strings.contains(status_json, `"install_command":"sudo dnf install -y nodejs npm"`) && strings.contains(status_json, `"diagnostic":null`), status_json)
    ok, reason := acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, !ok && reason == "acp_adapter_missing_node" && r2_npm_installs == 0)
    frame := acp_adapter_install_result_json("cmd_r2", ok, reason, acp_adapter_status("claude").error)
    testing.expect(t, strings.contains(frame, "sudo dnf install -y nodejs npm"), frame)

    // Too old Node.js reports what was found.
    r2_node = "v18.19.1\n"
    status = acp_adapter_status("claude")
    testing.expect(t, status.state == "missing_node" && status.node_version == "v18.19.1")
    testing.expect_value(t, status.error, "Node.js 22 or newer is required on the bridge host to run the Claude ACP adapter (found v18.19.1); upgrade it with: sudo dnf install -y nodejs npm")

    // Node.js installed without npm: a separate state with its own command.
    r2_node = "v22.3.0\n"
    status = acp_adapter_status("claude")
    testing.expect(t, status.state == "missing_npm" && status.node_version == "v22.3.0")
    testing.expect_value(t, status.install_command, "sudo dnf install -y npm")
    testing.expect_value(t, status.error, "npm is required on the bridge host to install the Claude ACP adapter; install it with: sudo dnf install -y npm")
    ok, reason = acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, !ok && reason == "acp_adapter_missing_npm" && r2_npm_installs == 0)

    // npm installed: the adapter is merely missing and installable.
    r2_npm = true
    status = acp_adapter_status("claude")
    testing.expect(t, status.state == "missing" && status.install_command == "" && status.error == "")

    // A failed install surfaces npm's own diagnostics, bounded and redacted,
    // beside the unchanged fixed error code.
    r2_npm_install_fails = true
    ok, reason = acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, !ok && reason == "acp_adapter_install_failed" && r2_npm_installs == 1)
    status = acp_adapter_status("claude")
    testing.expect_value(t, status.state, "error")
    testing.expect_value(t, status.error, "acp_adapter_install_failed")
    testing.expect_value(t, status.diagnostic, "npm error code E404\nnpm error 404 Not Found - GET https://***@registry.npmjs.org/@agentclientprotocol%2fclaude-agent-acp\n[redacted]\n[redacted]\nnpm error A complete log of this run can be found in: /tmp/npm-debug.log")
    status_json = acp_adapter_status_json("claude")
    for leaked in ([]string{"hunter2", "deploy:", "SYNTHETIC", "private.example", "stdout must not"}) do testing.expectf(t, !strings.contains(status_json, leaked), "%s leaked: %s", leaked, status_json)
    parsed, perr := json.parse(transmute([]u8)status_json, allocator = context.temp_allocator)
    testing.expect(t, perr == nil)
    object, _ := parsed.(json.Object)
    diagnostic, _ := object["diagnostic"].(json.String)
    testing.expect_value(t, string(diagnostic), status.diagnostic)
    frame = acp_adapter_install_result_json("cmd_r2", false, reason, strings.concatenate({"npm install failed:\n", status.diagnostic}))
    testing.expect(t, strings.contains(frame, "E404") && !strings.contains(frame, "hunter2"), frame)

    // Installing succeeds without a restart; a verified tree no longer needs npm.
    r2_npm_install_fails = false
    ok, reason = acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, ok, reason)
    status = acp_adapter_status("claude")
    testing.expect(t, status.state == "ready" && status.diagnostic == "" && status.version == ACP_CLAUDE_VERSION)
    r2_npm = false
    testing.expect_value(t, acp_adapter_status("claude").state, "ready")
    // Removing Node.js is detected on the next read too.
    r2_node = ""
    testing.expect_value(t, acp_adapter_status("claude").state, "missing_node")
}

// G2/G5: Copilot is user-installed. Heimdall checks the minimum version, never
// runs node or npm for it, and picks up an install or upgrade on the next
// detection without a restart.
@(test)
r2_acp_copilot_user_installed_minimum_detected_without_restart :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    old_runner, old_profile_probe := acp_adapter_runner, acp_adapter_profile_probe_hook
    defer { acp_adapter_runner = old_runner; acp_adapter_profile_probe_hook = old_profile_probe }
    acp_adapter_runner = r2_runner; acp_adapter_profile_probe_hook = r2_profile_probe_ok
    r2_runner_calls = 0; r2_node = "v22.3.0"; r2_npm = true
    snapshot := bridge_provider_catalog_snapshot
    snapshot.etag = "sha256:r2-copilot"
    snapshot.providers[1] = {provider = "copilot", binary = "copilot", state = "active", transports = {"pty", "acp"}, default_transport = "pty",
        acp_recipe = {command = "copilot", args = {"--acp", "--stdio"}, protocol_version = 1,
            adapter_package = "@github/copilot", adapter_version = "1.0.114", env = make(map[string]string)}}
    snapshot.providers[1].acp_recipe.env["COPILOT_AUTO_UPDATE"] = "false"
    defer delete(snapshot.providers[1].acp_recipe.env)
    testing.expect(t, bridge_catalog_transport_valid(snapshot.providers[1]))
    binary := profile_join(st.dir, "copilot")
    pp := Provider_Profile{profile_id = "copilot", provider = "copilot", enabled = true, config = {binary_path = binary}}
    raw, _ := json.marshal(Provider_Profile_Store_Wire{version = PROFILE_STORE_VERSION, profiles = {pp}})
    p1c_put(t, g_profile_test_store_path, string(raw))
    root := acp_adapter_root("copilot")
    testing.expect(t, !strings.contains(root, "-cli-"), "no pinned CLI tree")

    status := acp_adapter_status("copilot")
    testing.expect(t, status.state == "missing" && strings.has_prefix(status.error, "acp_copilot_not_found"), status.error)
    ok, reason := acp_adapter_install("copilot", snapshot.etag, "1.0.114")
    testing.expect(t, !ok && reason == "acp_copilot_not_found")

    // Older than the minimum: outdated, with the detected version and a message.
    p1c_put(t, binary, "#!/bin/sh\nprintf 'GitHub Copilot CLI 1.0.100.\\n'\n", true)
    status = acp_adapter_status("copilot")
    testing.expect(t, status.state == "outdated" && status.version == "1.0.100")
    testing.expect_value(t, status.error, "acp_copilot_outdated: The selected Copilot executable is older than the minimum supported version 1.0.114; upgrade it on the bridge host")
    ok, reason = acp_adapter_install("copilot", snapshot.etag, "1.0.114")
    testing.expect(t, !ok && reason == "acp_copilot_outdated")

    // The user upgrades: detected on the next read, certified by Re-check.
    p1c_put(t, binary, "#!/bin/sh\nprintf 'GitHub Copilot CLI 1.0.120.\\n'\n", true)
    status = acp_adapter_status("copilot")
    testing.expect(t, status.installed && status.version == "1.0.120" && status.state == "error" && status.node_version == "")
    ok, reason = acp_adapter_install("copilot", snapshot.etag, "1.0.114")
    testing.expect(t, ok, reason)
    testing.expect_value(t, acp_adapter_status("copilot").state, "ready")
    status_json := acp_adapter_status_json("copilot")
    testing.expect(t, strings.contains(status_json, `"runtime_kind":"system"`) && strings.contains(status_json, `"version":"1.0.120"`) && strings.contains(status_json, `"install_command":null`), status_json)
    testing.expect_value(t, r2_runner_calls, 0) // never node, npm or an install
}

@(private = "file")
r2_profile_probe_ok :: proc(pp: ^Provider_Profile, root, scratch: string) -> (bool, string) {
    return root != scratch, ""
}

@(test)
r2_acp_host_install_command_per_os_and_package_manager :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = context.temp_allocator
    old_host := acp_host_has_hook; defer acp_host_has_hook = old_host
    acp_host_has_hook = r2_host_has
    Case :: struct { os: string, host: []string, node, npm: string }
    cases := []Case{
        {"linux", {"/etc/NIXOS", "nix", "apt-get"}, "nix profile install nixpkgs#nodejs_22", "nix profile install nixpkgs#nodejs_22"},
        {"linux", {"apt-get"}, "sudo apt-get install -y nodejs npm", "sudo apt-get install -y npm"},
        {"linux", {"pacman"}, "sudo pacman -S --needed nodejs npm", "sudo pacman -S --needed npm"},
        {"linux", {"apk"}, "sudo apk add nodejs npm", "sudo apk add npm"},
        {"linux", {"nix"}, "nix profile install nixpkgs#nodejs_22", "nix profile install nixpkgs#nodejs_22"},
        {"darwin", {"brew", "apt-get"}, "brew install node@22", "brew install node@22"},
        {"windows", {"winget"}, "winget install OpenJS.NodeJS.LTS", "winget install OpenJS.NodeJS.LTS"},
        {"linux", {"brew"}, "", ""},
        {"freebsd", {"pkg"}, "", ""},
    }
    for c in cases {
        r2_host = c.host
        testing.expectf(t, acp_host_install_command(.Node, c.os) == c.node, "%v node", c)
        testing.expectf(t, acp_host_install_command(.Npm, c.os) == c.npm, "%v npm", c)
    }
    // No detected package manager: point at the official download page.
    r2_host = {}
    message, command := acp_host_tool_requirement(.Node, "Claude", 22)
    testing.expect(t, command == "" && strings.has_suffix(message, "install it from https://nodejs.org/en/download"), message)
}

@(test)
r2_acp_npm_diagnostic_is_bounded_and_redacted :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    b := strings.builder_make()
    for i in 0..<40 do fmt.sbprintf(&b, "npm error line %d %s\n", i, strings.repeat("x", 400))
    out := acp_adapter_npm_diagnostic(strings.to_string(b))
    lines := strings.split(out, "\n")
    testing.expect(t, len(out) <= ACP_NPM_DIAGNOSTIC_MAX_BYTES && len(lines) <= ACP_NPM_DIAGNOSTIC_MAX_LINES, out)
    testing.expect(t, strings.has_prefix(lines[len(lines) - 1], "npm error line 39 "), "keeps the last lines")
    for line in lines do testing.expect(t, len(line) <= ACP_NPM_DIAGNOSTIC_LINE_BYTES + len("…"))
    for secret in ([]string{
        "npm error Incorrect or missing password.",
        "npm notice Authorization: Bearer abc",
        "HOME=/home/someone",
        "  GITHUB_TOKEN=ghp_x",
        "npm error code E401 auth token expired",
    }) {
        testing.expectf(t, acp_adapter_npm_diagnostic(secret) == "[redacted]", "%q", secret)
    }
    testing.expect_value(t, acp_adapter_npm_diagnostic("npm error code ETIMEDOUT\x1b[31m"), "npm error code ETIMEDOUT?[31m")
    testing.expect_value(t, acp_adapter_npm_diagnostic("", "npm error from stdout"), "npm error from stdout")
    testing.expect_value(t, acp_adapter_npm_diagnostic("  \n"), "")
}
