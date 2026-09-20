package main

import "core:fmt"
import "core:strings"

// ── shell verb group (REQ-SH-CONTRACT §5) ────────────────────────────────────
// Provides 8 subcommands that manage PTY/shell sessions via the hub REST API.
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
	case "list":
		ctl_shell_list(endpoint, token, tokens, args)
	case "log":
		ctl_shell_log(endpoint, token, tokens, args)
	case "capture":
		ctl_shell_capture(endpoint, token, tokens, args)
	case "preview":
		ctl_shell_preview(endpoint, token, tokens, args)
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

// list — GET /api/v1/bridges/{bridge_id}/shells or /api/v1/shells with filters
// Flags: --bridge, --project, --chain, --status
// Prints table: session_id, kind, label, status, pid, server_port, uptime
ctl_shell_list :: proc(endpoint, token: string, tokens, args: []string) {
	bridge_id := option_value(args, "--bridge", "")
	project_id := option_value(args, "--project", "")
	chain_id := option_value(args, "--chain", "")
	status := option_value(args, "--status", "")

	if bridge_id != "" {
		// Bridge-scoped listing via /api/v1/bridges/{id}/shells
		qparts := make([dynamic]string)
		defer delete(qparts)
		if project_id != "" do append(&qparts, strings.concatenate({"project_id=", project_id}))
		if chain_id != ""   do append(&qparts, strings.concatenate({"chain_id=", chain_id}))
		if status != ""     do append(&qparts, strings.concatenate({"status=", status}))
		qs := ""
		if len(qparts) > 0 do qs = strings.concatenate({"?", strings.join(qparts[:], "&")})
		ctl_shell_rest(endpoint, token, "GET",
			strings.concatenate({fmt.tprintf("/api/v1/bridges/%s/shells", safe_path_part(bridge_id)), qs}), "")
		return
	}

	// Global listing via /api/v1/shells
	qparts := make([dynamic]string)
	defer delete(qparts)
	if project_id != "" do append(&qparts, strings.concatenate({"project_id=", project_id}))
	if chain_id != ""   do append(&qparts, strings.concatenate({"chain_id=", chain_id}))
	if status != ""     do append(&qparts, strings.concatenate({"status=", status}))
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

// preview — POST /api/v1/shells/{session_id}/preview-token
// Prints: {preview_url, token}
ctl_shell_preview :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell preview requires <session_id>"}`)
		return
	}
	ctl_shell_rest(endpoint, token, "POST",
		fmt.tprintf("/api/v1/shells/%s/preview-token", safe_path_part(sid)), "{}")
}

print_help_shell :: proc() {
	fmt.println("ham-ctl shell — manage PTY/shell sessions on the Bridge host")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  start --bridge <id> [--kind interactive|server|command]   Launch a new session.")
	fmt.println("        [--cmd <cmd>] [--cwd <dir>] [--label <lbl>]")
	fmt.println("        [--port <n>] [--project <id>] [--chain <id>]")
	fmt.println("        Prints: {session_id, status, pid}")
	fmt.println("  kill    <session_id>                 Terminate a session (DELETE).")
	fmt.println("  signal  <session_id> --signal <int>  Send a POSIX signal to the session process.")
	fmt.println("  restart <session_id>                 Stop then restart a session.")
	fmt.println("        Prints: {session_id, pid, status}")
	fmt.println("  list  [--bridge <id>] [--project <id>] [--chain <id>] [--status <s>]")
	fmt.println("        Prints table: session_id, kind, label, status, pid, server_port, uptime")
	fmt.println("  log     <session_id> [--offset N] [--limit N] [--grep <pattern>]")
	fmt.println("        Stream log lines; response: {lines, truncated, total_lines}")
	fmt.println("  capture <session_id>                 Snapshot current terminal screen content.")
	fmt.println("  preview <session_id>                 Get a one-time preview URL and token.")
	fmt.println("        Prints: {preview_url, token}")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl shell start --bridge brg_abc --kind interactive --cmd bash --label 'my shell'")
	fmt.println("  ham-ctl shell list --bridge brg_abc --status running")
	fmt.println("  ham-ctl shell log  sess_123 --limit 50 --grep error")
	fmt.println("  ham-ctl shell capture sess_123")
	fmt.println("  ham-ctl shell preview sess_123")
	fmt.println("  ham-ctl shell signal sess_123 --signal 2")
	fmt.println("  ham-ctl shell restart sess_123")
	fmt.println("  ham-ctl shell kill sess_123")
}
