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
@(private = "file") r2_spawn_fails: bool
@(private = "file") r2_npm_version: string
@(private = "file") r2_npm_spawn_fails: bool

// node resolves on PATH when r2_node is set, npm when r2_npm is.
@(private = "file")
r2_resolve :: proc(name: string) -> string {
    if name == "node" && r2_node != "" || name == "npm" && r2_npm do return name
    return ""
}

@(private = "file")
r2_host_has :: proc(detect: string) -> bool {
    for name in r2_host do if name == detect do return true
    return false
}

@(private = "file")
r2_runner :: proc(argv: []string, timeout: time.Duration) -> (string, string, int, bool, bool) {
    r2_runner_calls += 1
    if len(argv) == 2 && argv[1] == "--version" && r2_spawn_fails do return "", "", -1, false, false
    if len(argv) == 2 && argv[0] == "node" && argv[1] == "--version" {
        if r2_node == "" do return "", "", -1, false, false
        return strings.clone(r2_node), "", 0, true, false
    }
    if len(argv) == 2 && argv[0] == "npm" && argv[1] == "--version" {
        if !r2_npm || r2_npm_spawn_fails do return "", "", -1, false, false
        return strings.clone(r2_npm_version if r2_npm_version != "" else "10.8.2\n"), "", 0, true, false
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
    old_runner, old_probe, old_cli, old_binding, old_host, old_resolve := acp_adapter_runner, acp_adapter_probe_hook, acp_adapter_cli_probe_hook, acp_adapter_binding_hook, acp_host_has_hook, acp_host_tool_resolve_hook
    defer { acp_adapter_runner = old_runner; acp_adapter_probe_hook = old_probe; acp_adapter_cli_probe_hook = old_cli; acp_adapter_binding_hook = old_binding; acp_host_has_hook = old_host; acp_host_tool_resolve_hook = old_resolve }
    acp_host_tool_resolve_hook = r2_resolve; r2_spawn_fails = false; r2_npm_spawn_fails = false; r2_npm_version = ""
    acp_adapter_runner = r2_runner; acp_adapter_probe_hook = t4_adapter_fake_probe
    acp_adapter_cli_probe_hook = t4_adapter_fake_claude_probe; acp_adapter_binding_hook = t4_adapter_fake_binding
    acp_host_has_hook = r2_host_has
    r2_host = {"pacman"}; r2_node = ""; r2_npm = false; r2_npm_install_fails = false; r2_npm_installs = 0
    snapshot := bridge_provider_catalog_snapshot
    snapshot.etag = "sha256:r2"
    snapshot.providers[0].acp_recipe = {command = "claude-agent-acp", protocol_version = 1,
        adapter_package = ACP_CLAUDE_PACKAGE, adapter_version = ACP_CLAUDE_VERSION, env = make(map[string]string)}
    snapshot.providers[0].acp_recipe.env["CLAUDE_AGENT_ACP_PROTOCOL"] = "v1"
    defer delete(snapshot.providers[0].acp_recipe.env)

    // Missing Node.js.
    status := acp_adapter_status("claude")
    testing.expect_value(t, status.state, "missing_node")
    testing.expect_value(t, status.install_command, "sudo pacman -S --needed nodejs npm")
    testing.expect_value(t, status.error, "Node.js 22 or newer is required on the bridge host to run the Claude ACP adapter; install it with: sudo pacman -S --needed nodejs npm")
    status_json := acp_adapter_status_json("claude")
    testing.expect(t, strings.contains(status_json, `"install_command":"sudo pacman -S --needed nodejs npm"`) && strings.contains(status_json, `"diagnostic":null`), status_json)
    ok, reason := acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, !ok && reason == "acp_adapter_missing_node" && r2_npm_installs == 0)
    frame := acp_adapter_install_result_json("cmd_r2", ok, reason, acp_adapter_status("claude").error)
    testing.expect(t, strings.contains(frame, "sudo pacman -S --needed nodejs npm"), frame)

    // Too old Node.js reports what was found.
    r2_node = "v18.19.1\n"
    status = acp_adapter_status("claude")
    testing.expect(t, status.state == "missing_node" && status.node_version == "v18.19.1")
    testing.expect_value(t, status.error, "Node.js 22 or newer is required on the bridge host to run the Claude ACP adapter (found v18.19.1); upgrade it with: sudo pacman -S --needed nodejs npm")

    // A resolved node that cannot be started now is a transient error, not missing.
    r2_node = "v22.3.0\n"; r2_spawn_fails = true
    status = acp_adapter_status("claude")
    testing.expect(t, status.state == "error" && status.install_command == "", status.state)
    testing.expect_value(t, status.error, ACP_PREREQUISITE_CHECK_FAILED_NODE)
    ok, reason = acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, !ok && reason == "acp_adapter_prerequisite_check_failed" && r2_npm_installs == 0)
    r2_spawn_fails = false
    // A prerelease Node.js meets the major.
    r2_node = "v22.0.0-rc.1\n"
    testing.expect_value(t, acp_adapter_status("claude").state, "missing_npm")

    // Node.js installed without npm: a separate state with its own command.
    r2_node = "v22.3.0\n"
    status = acp_adapter_status("claude")
    testing.expect(t, status.state == "missing_npm" && status.node_version == "v22.3.0")
    testing.expect_value(t, status.install_command, "sudo pacman -S --needed npm")
    testing.expect_value(t, status.error, "npm is required on the bridge host to install the Claude ACP adapter; install it with: sudo pacman -S --needed npm")
    ok, reason = acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, !ok && reason == "acp_adapter_missing_npm" && r2_npm_installs == 0)

    // npm on PATH but not startable now: transient, not missing.
    r2_npm = true; r2_npm_spawn_fails = true
    status = acp_adapter_status("claude")
    testing.expect(t, status.state == "error" && status.error == ACP_PREREQUISITE_CHECK_FAILED_NPM, status.error)
    r2_npm_spawn_fails = false
    // npm installed (a prerelease version is accepted): merely missing and installable.
    r2_npm_version = "11.0.0-pre.1\n"
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

    // A later attempt that stops at a missing prerequisite replaces that
    // result: the old npm diagnostic does not come back once npm is installed.
    r2_npm = false
    ok, reason = acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, !ok && reason == "acp_adapter_missing_npm")
    r2_npm = true
    status = acp_adapter_status("claude")
    testing.expect(t, status.state == "missing" && status.diagnostic == "" && status.error == "", status.state)

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
    testing.expect(t, strings.contains(status_json, `"runtime_kind":"system"`) && strings.contains(status_json, `"version":"1.0.120"`) && strings.contains(status_json, `"install_command":null`) &&
        strings.contains(status_json, `"adapter_package":"@github/copilot","adapter_version":"1.0.114"`), status_json)
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
        {"linux", {"/etc/NIXOS", "nix", "apt-get"}, "nix-env -iA nixos.nodejs_22", "nix-env -iA nixos.nodejs_22"},
        {"linux", {"pacman"}, "sudo pacman -S --needed nodejs npm", "sudo pacman -S --needed npm"},
        {"linux", {"apk"}, "sudo apk add nodejs-current npm", "sudo apk add npm"},
        {"linux", {"nix"}, "nix-env -iA nixpkgs.nodejs_22", "nix-env -iA nixpkgs.nodejs_22"},
        // Debian/Ubuntu/Fedora/openSUSE packages can be older than 22: no command.
        {"linux", {"apt-get"}, "", ""},
        {"linux", {"dnf"}, "", ""},
        {"linux", {"zypper"}, "", ""},
        {"linux", {"apt-get", "nix"}, "nix-env -iA nixpkgs.nodejs_22", "nix-env -iA nixpkgs.nodejs_22"},
        // node@22 is keg-only (not on PATH); `node` is current and links.
        {"darwin", {"brew", "apt-get"}, "brew install node", "brew install node"},
        {"darwin", {"port"}, "sudo port install nodejs22 npm10", "sudo port install npm10"},
        {"windows", {"winget"}, "winget install OpenJS.NodeJS.LTS", "winget install OpenJS.NodeJS.LTS"},
        {"linux", {"brew"}, "", ""},
        {"freebsd", {"pkg"}, "", ""},
    }
    for c in cases {
        r2_host = c.host
        node, _ := acp_host_install_command(.Node, 22, c.os)
        npm, _ := acp_host_install_command(.Npm, 22, c.os)
        testing.expectf(t, node == c.node, "%v node: %s", c, node)
        testing.expectf(t, npm == c.npm, "%v npm: %s", c, npm)
    }
    // The major version comes from the descriptor, never a constant.
    r2_host = {"/etc/NIXOS"}
    command, note := acp_host_install_command(.Node, 24, "linux")
    testing.expect(t, command == "nix-env -iA nixos.nodejs_24" && note == "or add nodejs_24 to environment.systemPackages and run nixos-rebuild switch", note)
    when ODIN_OS == .Linux {
        // A too-old distribution package points at nodejs.org with the reason.
        r2_host = {"apt-get"}
        message, cmd := acp_host_tool_requirement(.Node, "Claude", 22)
        testing.expect_value(t, cmd, "")
        testing.expect_value(t, message, "Node.js 22 or newer is required on the bridge host to run the Claude ACP adapter (the apt nodejs package can be older than Node.js 22; use the NodeSource or official packages); install it from https://nodejs.org/en/download")
    }
    // No detected package manager: point at the official download page.
    r2_host = {}
    fallback, fallback_command := acp_host_tool_requirement(.Node, "Claude", 22)
    testing.expect(t, fallback_command == "" && strings.has_suffix(fallback, "install it from https://nodejs.org/en/download"), fallback)
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
    // Query strings are masked; the home directory reads as ~.
    testing.expect_value(t, acp_adapter_npm_diagnostic("npm error GET https://registry.example/pkg?sig=abc&x=1 failed", home = ""), "npm error GET https://registry.example/pkg?*** failed")
    testing.expect_value(t, acp_adapter_npm_diagnostic("npm error path /home/alice/.npm/_cacache\nnpm error see /home/alice/", home = "/home/alice/"), "npm error path ~/.npm/_cacache\nnpm error see ~/")
    testing.expect_value(t, acp_adapter_npm_diagnostic("  \n"), "")
}
