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

// {N} is replaced with the descriptor's node_min_major (G7: never hardcoded).
// node/npm are commands that yield Node.js {N}+ (or npm for it) on PATH; ""
// when the packaged Node.js can be older than {N}, so the user is pointed at
// nodejs.org instead of a command that leaves them stuck. note adds context.
ACP_Host_Installer :: struct {
    os: string,     // lowercased ODIN_OS this row applies to
    // Each of detect and also (when set) is an absolute or ~/ marker path, or
    // an executable looked up on PATH; both must be present.
    detect, also: string,
    node, npm, note: string,
}

// First match with a command wins: distribution markers before generic package
// managers. A matching row without a command keeps looking (e.g. nix on a
// Debian host) and contributes its note to the nodejs.org fallback.
ACP_HOST_INSTALLERS := [?]ACP_Host_Installer{
    // nix-env -iA needs a channel; flake-only installs (no channels) use nix profile.
    {os = "linux", detect = "/etc/NIXOS", also = "/nix/var/nix/profiles/per-user/root/channels/nixos", node = "nix-env -iA nixos.nodejs_{N}", npm = "nix-env -iA nixos.nodejs_{N}",
        note = "or add nodejs_{N} to environment.systemPackages and run nixos-rebuild switch"},
    {os = "linux", detect = "/etc/NIXOS", node = "nix profile install nixpkgs#nodejs_{N}", npm = "nix profile install nixpkgs#nodejs_{N}",
        note = "or add nodejs_{N} to environment.systemPackages and run nixos-rebuild switch"},
    {os = "linux", detect = "pacman", node = "sudo pacman -S --needed nodejs npm", npm = "sudo pacman -S --needed npm"},
    {os = "linux", detect = "apk", node = "sudo apk add nodejs-current npm", npm = "sudo apk add npm"},
    {os = "linux", detect = "nix", also = "~/.nix-defexpr/channels/nixpkgs", node = "nix-env -iA nixpkgs.nodejs_{N}", npm = "nix-env -iA nixpkgs.nodejs_{N}"},
    {os = "linux", detect = "nix", node = "nix profile install nixpkgs#nodejs_{N}", npm = "nix profile install nixpkgs#nodejs_{N}"},
    {os = "linux", detect = "apt-get", note = "the apt nodejs package can be older than Node.js {N}; use the NodeSource or official packages"},
    {os = "linux", detect = "dnf", note = "the dnf nodejs package can be older than Node.js {N}; use the official packages"},
    {os = "linux", detect = "zypper", note = "the zypper nodejs package can be older than Node.js {N}; use the official packages"},
    {os = "darwin", detect = "brew", node = "brew install node", npm = "brew install node"},
    {os = "darwin", detect = "port", node = "sudo port install nodejs{N} npm10", npm = "sudo port install npm10"},
    {os = "windows", detect = "winget", node = "winget install OpenJS.NodeJS.LTS", npm = "winget install OpenJS.NodeJS.LTS"},
}

ACP_NODE_DOWNLOAD_URL :: "https://nodejs.org/en/download"

// Test seam: whether a marker path exists or an executable resolves on PATH.
acp_host_has_hook: proc(detect: string) -> bool = acp_host_has

acp_host_has :: proc(detect: string) -> bool {
    if strings.has_prefix(detect, "~/") {
        home := os.get_env("HOME", context.temp_allocator)
        return home != "" && os.exists(strings.concatenate({home, detect[1:]}, context.temp_allocator))
    }
    if strings.has_prefix(detect, "/") do return os.exists(detect)
    env, _ := os.environ(context.temp_allocator)
    path := profile_resolve_binary(detect, env)
    defer delete(path)
    return path != ""
}

// A prerequisite that resolves but cannot be started right now (process
// budget, spawn failure, timeout): transient, so it never reads as missing.
ACP_PREREQUISITE_CHECK_FAILED_NODE :: "acp_adapter_prerequisite_check_failed: node --version could not be run right now; check again"
ACP_PREREQUISITE_CHECK_FAILED_NPM :: "acp_adapter_prerequisite_check_failed: npm --version could not be run right now; check again"

// Test seam: the absolute path of a host tool on the bridge's PATH, "" when
// absent. On Windows `npm` resolves to npm.cmd through PATHEXT.
acp_host_tool_resolve_hook: proc(name: string) -> string = acp_host_tool_resolve

acp_host_tool_resolve :: proc(name: string) -> string {
    env, _ := os.environ(context.temp_allocator)
    path := profile_resolve_binary(name, env)
    defer delete(path)
    return strings.clone(path, context.temp_allocator)
}

acp_host_tool_is_script :: proc(path: string) -> bool {
    lower := strings.to_lower(path, context.temp_allocator)
    return strings.has_suffix(lower, ".cmd") || strings.has_suffix(lower, ".bat")
}

// acp_host_install_command is the command that installs tool (for Node.js
// node_min_major or newer) on this bridge host, or "" when no package manager
// that ships a recent enough Node.js was detected; note is the matching rows'
// extra guidance.
acp_host_install_command :: proc(tool: ACP_Host_Tool, node_min_major: int, host_os: string = "") -> (command, note: string) {
    context.allocator = context.temp_allocator
    host_os := host_os
    if host_os == "" do host_os = strings.to_lower(fmt.tprintf("%v", ODIN_OS))
    major := fmt.tprintf("%d", node_min_major)
    for row in ACP_HOST_INSTALLERS {
        if row.os != host_os || !acp_host_has_hook(row.detect) || row.also != "" && !acp_host_has_hook(row.also) do continue
        if note == "" do note, _ = strings.replace_all(row.note, "{N}", major)
        template := row.node if tool == .Node else row.npm
        if template == "" do continue
        command, _ = strings.replace_all(template, "{N}", major)
        return
    }
    return
}

// acp_host_tool_requirement is the status message and install command for a
// missing (found == "") or too old tool. Messages carry no environment values.
acp_host_tool_requirement :: proc(tool: ACP_Host_Tool, display_name: string, node_min_major: int, found: string = "") -> (message, command: string) {
    context.allocator = context.temp_allocator
    note: string
    command, note = acp_host_install_command(tool, node_min_major)
    what := fmt.tprintf("Node.js %d or newer is required on the bridge host to run the %s ACP adapter", node_min_major, display_name)
    if tool == .Npm do what = fmt.tprintf("npm is required on the bridge host to install the %s ACP adapter", display_name)
    if found != "" do what = fmt.tprintf("%s (found %s)", what, found)
    verb := "upgrade" if found != "" else "install"
    suffix := fmt.tprintf(" (%s)", note) if note != "" else ""
    if command != "" do return fmt.tprintf("%s%s; %s it with: %s", what, suffix, verb, command), command
    return fmt.tprintf("%s%s; %s it from %s", what, suffix, verb, ACP_NODE_DOWNLOAD_URL), ""
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

acp_adapter_npm_diagnostic :: proc(stderr: string, stdout: string = "", homes: []string = nil) -> string {
    context.allocator = context.temp_allocator
    // The bridge user's home directory is shown as ~ (no account name): HOME,
    // and on Windows USERPROFILE, also as JSON-escaped backslashes.
    homes := homes
    if homes == nil do homes = {os.get_env("HOME", context.temp_allocator), os.get_env("USERPROFILE", context.temp_allocator)}
    masks := make([dynamic]string)
    for home in homes {
        trimmed := strings.trim_right(home, "/\\")
        if len(trimmed) <= 3 do continue // never "/" or "C:\\"
        append(&masks, trimmed)
        if strings.contains(trimmed, "\\") {
            escaped, _ := strings.replace_all(trimmed, "\\", "\\\\")
            append(&masks, escaped)
        }
    }
    // Longest first, so an escaped form is replaced before its plain prefix.
    for i in 1..<len(masks) do for j := i; j > 0 && len(masks[j]) > len(masks[j-1]); j -= 1 do masks[j], masks[j-1] = masks[j-1], masks[j]
    source := stderr if strings.trim_space(stderr) != "" else stdout
    lines := make([dynamic]string)
    for raw in strings.split_lines(source) {
        line := strings.trim_space(raw)
        if line == "" do continue
        for mask in masks do line, _ = strings.replace_all(line, mask, "~")
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
    // URL user info (https://user:pass@registry) and query strings are replaced.
    for {
        scheme := strings.index(rest, "://")
        if scheme < 0 do break
        host := rest[scheme + 3:]
        end := strings.index_any(host, "/ \t")
        if end < 0 do end = len(host)
        at := strings.last_index_byte(host[:end], '@')
        strings.write_string(&b, rest[:scheme + 3])
        if at >= 0 { strings.write_string(&b, "***@"); rest = host[at + 1:] } else do rest = host
        token_end := strings.index_any(rest, " \t")
        if token_end < 0 do token_end = len(rest)
        if q := strings.index_byte(rest[:token_end], '?'); q >= 0 {
            strings.write_string(&b, rest[:q]); strings.write_string(&b, "?***")
            rest = rest[token_end:]
        }
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
