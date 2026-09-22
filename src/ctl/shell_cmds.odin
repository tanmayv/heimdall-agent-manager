package main

import "core:fmt"
import "core:strings"

// ── shell verb group (REQ-SH-CONTRACT §5) ────────────────────────────────────
// Provides 7 subcommands that manage PTY/shell sessions via the hub REST API.
// All calls route through the local Bridge via agent.rest.request (same auth
// token as task/chat commands). shell-cmd exec/read remain as-is in
// agent_mode.odin for backward compatibility.

ctl_agentmode_shell :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "start":
		ctl_shell_start(endpoint, token, tokens, args)
	case "kill":
		ctl_shell_kill(endpoint, token, tokens, args)
	case "signal":
		ctl_shell_signal(endpoint, token, tokens, args)
	case "restart":
		ctl_shell_restart(endpoint, token, tokens, args)
	case "set-port":
		ctl_shell_set_port(endpoint, token, tokens, args)
	case "list":
		ctl_shell_list(endpoint, token, tokens, args)
	case "log":
		ctl_shell_log(endpoint, token, tokens, args)
	case "capture":
		ctl_shell_capture(endpoint, token, tokens, args)
	case "", "--help", "-h", "help":
		print_help_shell()
	case:
		print_help_shell()
	}
}

// ctl_shell_rest calls a REST endpoint via the Bridge agent.rest.request RPC.
ctl_shell_rest :: proc(endpoint, token, method, path, body: string) {
	ctl_agent_call(endpoint, token, "agent.rest.request", json_object(
		json_kv("http_method", method),
		json_kv("path", path),
		json_kv("body", body),
	))
}

// start — POST /api/v1/bridges/{bridge_id}/shells
// Flags: --kind, --cmd, --cwd, --label, --port, --project, --chain
// Prints: {session_id, status, pid}
ctl_shell_start :: proc(endpoint, token: string, tokens, args: []string) {
	bridge_id := option_value(args, "--bridge", "")
	if bridge_id == "" {
		fmt.println(`{"ok":false,"message":"shell start requires --bridge <bridge_id>"}`)
		return
	}
	kind := option_value(args, "--kind", "interactive")
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("kind", kind))
	if v := option_value(args, "--cmd", ""); v != "" do append(&fields, json_kv("cmd", v))
	if v := option_value(args, "--cwd", ""); v != "" do append(&fields, json_kv("cwd", v))
	if v := option_value(args, "--label", ""); v != "" do append(&fields, json_kv("label", v))
	if v := ctl_shell_uint_flag(args, "--port", ""); v != "" do append(&fields, json_kv_raw("server_port", v))
	if v := option_value(args, "--project", ""); v != "" do append(&fields, json_kv("project_id", v))
	if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
	ctl_shell_rest(endpoint, token, "POST",
		fmt.tprintf("/api/v1/bridges/%s/shells", safe_path_part(bridge_id)),
		json_object_from_slice(fields[:]))
}

// kill — DELETE /api/v1/shells/{session_id}
ctl_shell_kill :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell kill requires <session_id>"}`)
		return
	}
	ctl_shell_rest(endpoint, token, "DELETE",
		fmt.tprintf("/api/v1/shells/%s", safe_path_part(sid)), "")
}

// signal — POST /api/v1/shells/{session_id}/signal
// Flags: --signal <int>
ctl_shell_signal :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	sig := ctl_shell_uint_flag(args, "--signal", "")
	if sid == "" || sig == "" {
		fmt.println(`{"ok":false,"message":"shell signal requires <session_id> --signal <int>"}`)
		return
	}
	ctl_shell_rest(endpoint, token, "POST",
		fmt.tprintf("/api/v1/shells/%s/signal", safe_path_part(sid)),
		json_object(json_kv_raw("signal", sig)))
}

// restart — POST /api/v1/shells/{session_id}/restart
// Prints: {session_id, pid, status}
ctl_shell_restart :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell restart requires <session_id>"}`)
		return
	}
	ctl_shell_rest(endpoint, token, "POST",
		fmt.tprintf("/api/v1/shells/%s/restart", safe_path_part(sid)), "{}")
}

// set-port — POST /api/v1/shells/{session_id}/port
// Flags: --port <n> | --clear
// Declares the port of a session that is ALREADY running, for the common case of
// opening a terminal and only then starting a server in it. Prints the updated
// session.
//
// --clear and --port 0 are the same request. 0 is the value the session record
// already uses for "no port", so it has to work; --clear is the spelling a
// reader finds without knowing that.
ctl_shell_set_port :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell set-port requires <session_id> --port <n> (or --clear)"}`)
		return
	}

	// option_value rather than ctl_shell_uint_flag: that helper folds an invalid
	// value into its fallback, which would make a typo indistinguishable from an
	// omitted flag — and here the difference decides whether we clear the port.
	raw := strings.trim_space(option_value(args, "--port", ""))
	clearing := has_flag(args, "--clear")

	if clearing && raw != "" && raw != "0" {
		fmt.println(`{"ok":false,"message":"shell set-port: --clear and --port <n> conflict; pass one"}`)
		return
	}
	if !clearing && raw == "" {
		fmt.println(`{"ok":false,"message":"shell set-port requires --port <n> (1-65535) or --clear"}`)
		return
	}

	port := "0"
	if !clearing {
		for ch in raw {
			if ch < '0' || ch > '9' {
				fmt.println(`{"ok":false,"message":"shell set-port: --port must be a number between 1 and 65535, or use --clear"}`)
				return
			}
		}
		port = raw
	}

	ctl_shell_rest(endpoint, token, "POST",
		fmt.tprintf("/api/v1/shells/%s/port", safe_path_part(sid)),
		json_object(json_kv_raw("server_port", port)))
}

// list — GET /api/v1/shells with optional filters
// Flags: --bridge, --project, --chain, --status, --limit, --cursor
// With no flags: every shell the caller owns, across every bridge.
//
// All flags go to the one owner-wide route. Previously --bridge switched to
// /api/v1/bridges/{id}/shells, which reads only `status` — so
// `shell list --bridge X --project Y` silently ignored --project and listed the
// whole bridge. /api/v1/shells ANDs every filter, so each flag now narrows.
// The bridge-scoped route is untouched and keeps its other callers.
ctl_shell_list :: proc(endpoint, token: string, tokens, args: []string) {
	bridge_id := option_value(args, "--bridge", "")
	project_id := option_value(args, "--project", "")
	chain_id := option_value(args, "--chain", "")
	status := option_value(args, "--status", "")

	qparts := make([dynamic]string)
	defer delete(qparts)
	if bridge_id != ""  do append(&qparts, strings.concatenate({"bridge_id=", bridge_id}))
	if project_id != "" do append(&qparts, strings.concatenate({"project_id=", project_id}))
	if chain_id != ""   do append(&qparts, strings.concatenate({"chain_id=", chain_id}))
	if status != ""     do append(&qparts, strings.concatenate({"status=", status}))
	if v := ctl_shell_uint_flag(args, "--limit", ""); v != "" do append(&qparts, strings.concatenate({"limit=", v}))
	if v := option_value(args, "--cursor", ""); v != "" do append(&qparts, strings.concatenate({"cursor=", v}))
	qs := ""
	if len(qparts) > 0 do qs = strings.concatenate({"?", strings.join(qparts[:], "&")})
	ctl_shell_rest(endpoint, token, "GET", strings.concatenate({"/api/v1/shells", qs}), "")
}

// log — GET /api/v1/shells/{session_id}/log?offset=&limit=&grep=
// Flags: --offset, --limit, --grep
// Streams lines to stdout; response: {lines:[], truncated:bool, total_lines:int}
ctl_shell_log :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell log requires <session_id>"}`)
		return
	}
	qparts := make([dynamic]string)
	defer delete(qparts)
	if v := ctl_shell_uint_flag(args, "--offset", ""); v != "" do append(&qparts, strings.concatenate({"offset=", v}))
	if v := ctl_shell_uint_flag(args, "--limit", "");  v != "" do append(&qparts, strings.concatenate({"limit=", v}))
	if v := option_value(args, "--grep", ""); v != "" do append(&qparts, strings.concatenate({"grep=", v}))
	qs := ""
	if len(qparts) > 0 do qs = strings.concatenate({"?", strings.join(qparts[:], "&")})
	ctl_shell_rest(endpoint, token, "GET",
		strings.concatenate({fmt.tprintf("/api/v1/shells/%s/log", safe_path_part(sid)), qs}), "")
}

// capture — GET /api/v1/shells/{session_id}/capture
// Prints current screen/terminal content snapshot.
ctl_shell_capture :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell capture requires <session_id>"}`)
		return
	}
	ctl_shell_rest(endpoint, token, "GET",
		fmt.tprintf("/api/v1/shells/%s/capture", safe_path_part(sid)), "")
}

print_help_shell :: proc() {
	fmt.println("ham-ctl shell — manage PTY/shell sessions on the Bridge host")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  start --bridge <id> [--kind interactive|server|command]   Launch a new session.")
	fmt.println("        [--cmd <cmd>] [--cwd <dir>] [--label <lbl>]")
	fmt.println("        [--port <n>] [--project <id>] [--chain <id>]")
	fmt.println("        --port declares the port the process binds; it is what makes the")
	fmt.println("        session reachable over HTTP, whatever its kind (see REACHING A")
	fmt.println("        SERVER below). It can also be declared later with set-port.")
	fmt.println("        Prints: {session_id, status, pid}")
	fmt.println("  kill    <session_id>                 Terminate a session (DELETE).")
	fmt.println("  signal  <session_id> --signal <int>  Send a POSIX signal to the session process.")
	fmt.println("  restart <session_id>                 Stop then restart a session.")
	fmt.println("        Prints: {session_id, pid, status}")
	fmt.println("  set-port <session_id> --port <n> | --clear")
	fmt.println("        Declare (or clear) the port of a session that is ALREADY running —")
	fmt.println("        for when you open a terminal and only then start a server in it.")
	fmt.println("        Takes effect immediately, on both access paths, with no restart.")
	fmt.println("        --port 0 and --clear are the same request. Refused on a session")
	fmt.println("        that has exited, and on a session you do not own.")
	fmt.println("        Prints the updated session.")
	fmt.println("  list  [--bridge <id>] [--project <id>] [--chain <id>] [--status <s>]")
	fmt.println("        [--limit N] [--cursor <c>]")
	fmt.println("        With NO flags: every shell you own, across every bridge, paginated.")
	fmt.println("        Filters are AND-ed, so --bridge X --status running means both.")
	fmt.println("        Prints table: session_id, kind, label, status, pid, server_port, uptime")
	fmt.println("  log     <session_id> [--offset N] [--limit N] [--grep <pattern>]")
	fmt.println("        Stream log lines; response: {lines, truncated, total_lines}")
	fmt.println("  capture <session_id>                 Snapshot current terminal screen content.")
	fmt.println("")
	fmt.println("AUTH")
	fmt.println("  ham-ctl shell authenticates with HEIMDALL_AGENT_TOKEN (or --agent-token),")
	fmt.println("  exactly like ham-ctl shell-cmd. No user token is needed: the call goes to")
	fmt.println("  the local Bridge endpoint, which relays it to the Hub on your behalf.")
	fmt.println("")
	fmt.println("REACHING A SERVER SESSION OVER HTTP")
	fmt.println("  A session started with --kind server --port N is reachable from this host")
	fmt.println("  through the Bridge's local endpoint. No inbound port is opened on either")
	fmt.println("  machine and no user token or browser session is involved:")
	fmt.println("")
	fmt.println("      http://127.0.0.1:<local_endpoint_port>/proxy/<session_id>/<path>")
	fmt.println("")
	fmt.println("  The Bridge relays over the WebSocket it already holds to the Hub, the Hub")
	fmt.println("  splices it to the Bridge owning <session_id>, and that Bridge dials")
	fmt.println("  127.0.0.1:<declared port>. Method, path, query and body are forwarded.")
	fmt.println("")
	fmt.println("  The local endpoint is the same one ham-ctl itself uses — a unix socket in")
	fmt.println("  HEIMDALL_BRIDGE_ENDPOINT, with a TCP fallback (default port 49324). Find it:")
	fmt.println("      ham-ctl bridge list --scope configured    -> {local_endpoint_port: 49324}")
	fmt.println("")
	fmt.println("  The target session must be status=running with a declared port, and be")
	fmt.println("  owned by you; cross-owner targets are refused. Its kind does not matter —")
	fmt.println("  an interactive shell you started a server inside is reachable too, and")
	fmt.println("  set-port is how you declare that port after the fact.")
	fmt.println("")
	fmt.println("  EXAMPLE (both transports; each line below has been run end to end)")
	fmt.println("      ham-ctl shell start --bridge brg_abc --kind server --port 8000 \\")
	fmt.println("        --cwd /srv/site --cmd 'python3 -m http.server 8000 --bind 127.0.0.1'")
	fmt.println("      # -> {session_id: sh_123, status: running, pid: ...}")
	fmt.println("      curl http://127.0.0.1:49324/proxy/sh_123/index.html")
	fmt.println("      curl --unix-socket \"${HEIMDALL_BRIDGE_ENDPOINT#unix:}\" \\")
	fmt.println("        http://localhost/proxy/sh_123/index.html")
	fmt.println("")
	fmt.println("  REFUSALS (JSON body, {error: <reason>})")
	fmt.println("      404 session_not_found     no such session, or not yours")
	fmt.println("      409 session_not_running   session exited")
	fmt.println("      409 no_server_port        no port declared (see set-port)")
	fmt.println("      403 cross_owner           target belongs to another user")
	fmt.println("      503 unavailable           bridge cannot reach the hub right now")
	fmt.println("")
	fmt.println("  Any process on this host that can reach the local endpoint can use this and")
	fmt.println("  acts with the Bridge owner's authority. Disable with --no-local-proxy or")
	fmt.println("  [bridge] local_proxy_enabled=false.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl shell start --bridge brg_abc --kind interactive --cmd bash --label 'my shell'")
	fmt.println("  ham-ctl shell list")
	fmt.println("  ham-ctl shell list --bridge brg_abc --status running")
	fmt.println("  ham-ctl shell log  sess_123 --limit 50 --grep error")
	fmt.println("  ham-ctl shell capture sess_123")
	fmt.println("  ham-ctl shell signal sess_123 --signal 2")
	fmt.println("  ham-ctl shell restart sess_123")
	fmt.println("  ham-ctl shell set-port sess_123 --port 3000")
	fmt.println("  ham-ctl shell set-port sess_123 --clear")
	fmt.println("  ham-ctl shell kill sess_123")
}
