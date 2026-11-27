package main

import "core:fmt"
import "core:os"
import "core:strings"

// Host prerequisites of ACP Adapter runtimes: Node.js runs the adapter and npm
// installs its published package. Heimdall never installs either (G4): it
// detects them separately and reports the exact command for the bridge host's
// OS and package manager. ACP_HOST_INSTALLERS is the single source of those
// commands; System runtimes (user-installed CLIs) need neither tool.
ACP_Host_Tool :: enum { Node, Npm }

ACP_Host_Installer :: struct {
    os: string,     // lowercased ODIN_OS this row applies to
    detect: string, // an absolute marker path, or an executable looked up on PATH
    node, npm: string,
}

// First match wins: distribution markers before generic package managers.
ACP_HOST_INSTALLERS := [?]ACP_Host_Installer{
    {os = "linux", detect = "/etc/NIXOS", node = "nix profile install nixpkgs#nodejs_22", npm = "nix profile install nixpkgs#nodejs_22"},
    {os = "linux", detect = "apt-get", node = "sudo apt-get install -y nodejs npm", npm = "sudo apt-get install -y npm"},
    {os = "linux", detect = "dnf", node = "sudo dnf install -y nodejs npm", npm = "sudo dnf install -y npm"},
    {os = "linux", detect = "pacman", node = "sudo pacman -S --needed nodejs npm", npm = "sudo pacman -S --needed npm"},
    {os = "linux", detect = "zypper", node = "sudo zypper install -y nodejs22 npm22", npm = "sudo zypper install -y npm22"},
    {os = "linux", detect = "apk", node = "sudo apk add nodejs npm", npm = "sudo apk add npm"},
    {os = "linux", detect = "nix", node = "nix profile install nixpkgs#nodejs_22", npm = "nix profile install nixpkgs#nodejs_22"},
    {os = "darwin", detect = "brew", node = "brew install node@22", npm = "brew install node@22"},
    {os = "darwin", detect = "port", node = "sudo port install nodejs22 npm10", npm = "sudo port install npm10"},
    {os = "windows", detect = "winget", node = "winget install OpenJS.NodeJS.LTS", npm = "winget install OpenJS.NodeJS.LTS"},
}

ACP_NODE_DOWNLOAD_URL :: "https://nodejs.org/en/download"

// Test seam: whether a marker path exists or an executable resolves on PATH.
acp_host_has_hook: proc(detect: string) -> bool = acp_host_has

acp_host_has :: proc(detect: string) -> bool {
    if strings.has_prefix(detect, "/") do return os.exists(detect)
    env, _ := os.environ(context.temp_allocator)
    path := profile_resolve_binary(detect, env)
    defer delete(path)
    return path != ""
}

// acp_host_install_command is the command that installs tool on this bridge
// host, or "" when no supported package manager was detected.
acp_host_install_command :: proc(tool: ACP_Host_Tool, host_os: string = "") -> string {
    host_os := host_os
    if host_os == "" do host_os = strings.to_lower(fmt.tprintf("%v", ODIN_OS), context.temp_allocator)
    for row in ACP_HOST_INSTALLERS {
        if row.os != host_os || !acp_host_has_hook(row.detect) do continue
        return row.node if tool == .Node else row.npm
    }
    return ""
}

// acp_host_tool_requirement is the status message and install command for a
// missing (found == "") or too old tool. Messages carry no environment values.
acp_host_tool_requirement :: proc(tool: ACP_Host_Tool, display_name: string, node_min_major: int, found: string = "") -> (message, command: string) {
    context.allocator = context.temp_allocator
    command = acp_host_install_command(tool)
    what := fmt.tprintf("Node.js %d or newer is required on the bridge host to run the %s ACP adapter", node_min_major, display_name)
    if tool == .Npm do what = fmt.tprintf("npm is required on the bridge host to install the %s ACP adapter", display_name)
    if found != "" do what = fmt.tprintf("%s (found %s)", what, found)
    verb := "upgrade" if found != "" else "install"
    if command != "" do return fmt.tprintf("%s; %s it with: %s", what, verb, command), command
    return fmt.tprintf("%s; %s it from %s", what, verb, ACP_NODE_DOWNLOAD_URL), ""
}

// Install failures surface npm's own diagnostics, bounded and redacted: the
// last lines of stderr (stdout when stderr is empty), each line capped, lines
// that can carry credentials or environment values replaced. Also applied
// when a persisted excerpt is read back, since that file is local input.
ACP_NPM_DIAGNOSTIC_MAX_BYTES :: 2048
ACP_NPM_DIAGNOSTIC_MAX_LINES :: 12
ACP_NPM_DIAGNOSTIC_LINE_BYTES :: 240

@(private = "file")
acp_npm_secret_markers := [?]string{"token", "_auth", "authorization", "password", "passwd", "secret", "credential", "cookie", "bearer", "npm_config_", "api_key", "apikey", "private"}

acp_adapter_npm_diagnostic :: proc(stderr: string, stdout: string = "") -> string {
    context.allocator = context.temp_allocator
    source := stderr if strings.trim_space(stderr) != "" else stdout
    lines := make([dynamic]string)
    for raw in strings.split_lines(source) {
        line := strings.trim_space(raw)
        if line == "" do continue
        append(&lines, acp_npm_diagnostic_line(line))
    }
    first := max(0, len(lines) - ACP_NPM_DIAGNOSTIC_MAX_LINES)
    total := 0
    for i := len(lines) - 1; i >= first; i -= 1 {
        if total + len(lines[i]) + 1 > ACP_NPM_DIAGNOSTIC_MAX_BYTES { first = i + 1; break }
        total += len(lines[i]) + 1
    }
    return strings.join(lines[first:], "\n")
}

@(private = "file")
acp_npm_diagnostic_line :: proc(line: string) -> string {
    lower := strings.to_lower(line, context.temp_allocator)
    for marker in acp_npm_secret_markers do if strings.contains(lower, marker) do return "[redacted]"
    // An environment assignment (NAME=value) is never echoed.
    if eq := strings.index_byte(line, '='); eq > 0 {
        name := line[:eq]
        if i := strings.last_index_any(name, " \t:"); i >= 0 do name = name[i + 1:]
        upper := len(name) > 0
        for c in transmute([]u8)name do if !(c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') { upper = false; break }
        if upper do return "[redacted]"
    }
    b := strings.builder_make(context.temp_allocator)
    rest := line
    // URL user info (https://user:pass@registry) is replaced.
    for {
        scheme := strings.index(rest, "://")
        if scheme < 0 do break
        host := rest[scheme + 3:]
        end := strings.index_any(host, "/ \t")
        if end < 0 do end = len(host)
        at := strings.last_index_byte(host[:end], '@')
        strings.write_string(&b, rest[:scheme + 3])
        if at >= 0 { strings.write_string(&b, "***@"); rest = host[at + 1:] } else do rest = host
    }
    strings.write_string(&b, rest)
    out := strings.to_string(b)
    clean := strings.builder_make(context.temp_allocator)
    for c in transmute([]u8)out do strings.write_byte(&clean, c if c >= 0x20 && c != 0x7f || c == '\t' else '?')
    out = strings.to_string(clean)
    if len(out) <= ACP_NPM_DIAGNOSTIC_LINE_BYTES do return out
    cut := ACP_NPM_DIAGNOSTIC_LINE_BYTES
    for cut > 0 && out[cut] & 0xC0 == 0x80 do cut -= 1 // keep UTF-8 intact
    return strings.concatenate({out[:cut], "…"}, context.temp_allocator)
}
