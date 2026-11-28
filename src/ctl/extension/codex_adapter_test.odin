package extension

import "core:fmt"
import json "core:encoding/json"
import "core:slice"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

codex_callbacks :: proc() -> json.Array {
	v, _ := json.parse_string(#load("testdata/codex/callbacks.json", string), json.DEFAULT_SPECIFICATION, true)
	rows, _ := v.(json.Array)
	return rows
}

@(test)
test_codex_actual_release_callbacks_satisfy_contract :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	rows := codex_callbacks()
	testing.expect(t, len(rows) >= 70)
	events := make(map[string]int)
	sources := make(map[string]bool)
	children := make(map[string]bool)
	edits := make(map[string]int)
	compactions := make(map[string]int)
	for row in rows {
		root, _ := row.(json.Object)
		b, _ := json.marshal(row)
		mapped, err := codex_map_hook(string(b), TS, 10_000, "blk_fixture")
		testing.expect_value(t, err, Hook_Error.None)
		name := json_get_string(root, "hook_event_name")
		if name == "PreCompact" || name == "PostCompact" {
			testing.expect_value(t, len(mapped.events), 1)
			if len(mapped.events) != 1 do continue
			ev, e := contracts.ext_parse_event(mapped.events[0])
			testing.expect_value(t, e, contracts.Ext_Error.None)
			testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Compaction)
			testing.expect_value(t, ev.provider, "codex")
			testing.expect_value(t, ev.session_id, json_get_string(root, "session_id"))
			testing.expect_value(t, ev.compaction_phase, "pre" if name == "PreCompact" else "post")
			testing.expect_value(t, ev.compaction_trigger, json_get_string(root, "trigger"))
			testing.expect(t, strings.contains(mapped.events[0], json_get_string(root, "model")))
			events[contracts.ext_event_kind_name(ev.kind)] += 1
			compactions[name] += 1
			continue
		}
		testing.expect(t, len(mapped.events) > 0, name)
		for raw in mapped.events {
			ev, e := contracts.ext_parse_event(raw)
			testing.expect_value(t, e, contracts.Ext_Error.None)
			testing.expect_value(t, ev.provider, "codex")
			testing.expect_value(t, ev.session_id, json_get_string(root, "session_id"))
			testing.expect_value(t, ev.agent_id, json_get_string(root, "agent_id"))
			events[contracts.ext_event_kind_name(ev.kind)] += 1
			v, _ := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true)
			o, _ := v.(json.Object)
			p := json_get_object(o, "payload")
			if ev.kind == .File_Edit {
				edits[json_get_string(p, "operation")] += 1
				testing.expect(t, ev.file_path != "")
				if json_get_string(p, "operation") != "create" do testing.expect(t, json_get_bool(p, "partial"))
			}
			if ev.kind == .Tool_End {
				testing.expect_value(t, json_get_string(p, "status"), "completed")
				testing.expect_value(t, json_get_string(p, "outcome"), "unknown")
			}
		}
		if name == "SessionStart" do sources[json_get_string(root, "source")] = true
		if name == "PermissionRequest" && json_get_string(root, "agent_id") != "" do children[json_get_string(root, "agent_id")] = true
	}
	for name in ([]string{"hello", "session", "activity", "tool.start", "tool.end", "subagent.start", "subagent.stop", "permission.request", "file.edit", "compaction"}) {
		testing.expect(t, events[name] > 0, name)
	}
	for source in ([]string{"startup", "clear", "resume", "fork"}) do testing.expect(t, sources[source], source)
	testing.expect_value(t, len(children), 2)
	for op in ([]string{"create","update","delete","move"}) do testing.expect_value(t, edits[op], 1)
	testing.expect(t, compactions["PreCompact"] > 0 && compactions["PostCompact"] > 0)
}

@(test)
test_codex_unknown_invalid_bounded_and_native_decisions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for raw in ([]string{"[]", "{", `{"hook_event_name":"Stop"}`}) {
		_, err := codex_map_hook(raw, TS)
		testing.expect_value(t, err, Hook_Error.Malformed_Json)
	}
	_, err := codex_map_hook(strings.repeat("x", CODEX_HOOK_INPUT_MAX+1), TS)
	testing.expect_value(t, err, Hook_Error.Too_Large)
	unknown, _ := codex_map_hook(`{"session_id":"s","hook_event_name":"Notification"}`, TS)
	testing.expect_value(t, len(unknown.events), 0)
	testing.expect(t, strings.contains(permission_request_output_from_response(`{"ok":true,"data":{"decision":"allow"}}`), `"behavior":"allow"`))
	testing.expect(t, strings.contains(permission_request_output_from_response(`{"ok":true,"data":{"data":{"decision":"deny","message":"no"}}}`), `"behavior":"deny"`))
	for raw in ([]string{"", "{}", `{"ok":false,"data":{"decision":"allow"}}`, `{"ok":true,"data":{"decision":"none"}}`, `{"ok":true,"data":{"decision":"ask"}}`}) {
		testing.expect_value(t, permission_request_output_from_response(raw), "")
	}
}

@(test)
test_codex_confirmed_callback_markerless_update_and_mixed_native_summary :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	// Reuse a captured release callback envelope, replacing the patch and
	// response with release-grammar regression cases, not new live evidence.
	root: json.Object
	for row in codex_callbacks() {
		o, _ := row.(json.Object)
		if json_get_string(o, "hook_event_name") == "PostToolUse" && json_get_string(o, "tool_name") == "apply_patch" {
			root = o
			break
		}
	}
	testing.expect(t, root != nil)
	if root == nil do return
	input := make(json.Object)
	input["command"] = json.String("*** Begin Patch\n*** Update File: b.txt\n-old\n+new\n*** Delete File: gone.txt\n*** Add File: a.txt\n+created\n*** End Patch")
	root["tool_input"] = input
	root["tool_response"] = json.String("Exit code: 0\nWall time: 0 seconds\nOutput:\nSuccess. Updated the following files:\nA a.txt\nM b.txt\nD gone.txt\n")
	b, _ := json.marshal(root)
	mapped, err := codex_map_hook(string(b), TS)
	testing.expect_value(t, err, Hook_Error.None)
	edits := make(map[string]bool)
	for raw in mapped.events {
		event, e := contracts.ext_parse_event(raw)
		testing.expect_value(t, e, contracts.Ext_Error.None)
		if event.kind != .File_Edit do continue
		edits[event.file_path] = true
		v, _ := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true)
		o, _ := v.(json.Object)
		payload := json_get_object(o, "payload")
		if event.file_path == "b.txt" {
			testing.expect(t, json_get_bool(payload, "partial"))
			testing.expect(t, !json_get_bool(payload, "line_offsets_known"))
			testing.expect(t, strings.contains(json_get_string(payload, "diff"), "-old\n+new\n"))
		}
	}
	testing.expect_value(t, len(edits), 3)
	for path in ([]string{"a.txt", "b.txt", "gone.txt"}) do testing.expect(t, edits[path], path)
}

@(private = "file", thread_local)
codex_fake_calls: int
@(private = "file", thread_local)
codex_fake_params: string

@(private = "file")
codex_fake_send :: proc(endpoint, token, method, params: string, timeout_ms: int) -> (string, bool) {
	codex_fake_calls += 1
	codex_fake_params = params
	return "", false
}

@(test)
test_codex_compaction_hook_prints_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	env := Hook_Env{endpoint = "unix:/tmp/none.sock", token = "hlat_x", ts = TS}
	for name in ([]string{"PreCompact", "PostCompact"}) {
		codex_fake_calls = 0
		raw := fmt.tprintf(`{{"session_id":"s","turn_id":"t","hook_event_name":"%s","model":"m","trigger":"auto"}}`, name)
		testing.expect_value(t, hook_run("codex", raw, env, codex_fake_send), "")
		testing.expect_value(t, codex_fake_calls, 1)
		testing.expect(t, strings.contains(codex_fake_params, `"event":"compaction"`), name)
		testing.expect(t, strings.contains(codex_fake_params, `"trigger":"auto"`), name)
	}
}

@(test)
test_codex_hello_declares_usage_capability :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	mapped, err := codex_map_hook(`{"session_id":"s1","hook_event_name":"SessionStart","source":"startup","cwd":"/w","model":"gpt-5"}`, TS)
	testing.expect_value(t, err, Hook_Error.None)
	testing.expect(t, len(mapped.events) > 0)
	if len(mapped.events) == 0 do return
	ev, perr := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, perr, contracts.Ext_Error.None)
	testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Hello)
	testing.expect(t, slice.contains(ev.capabilities[:], "usage"), "codex declares the usage capability")
}

// P26: Codex self-approves the agent's own ham-ctl traffic with the same rule
// as Claude and Antigravity (is_ham_ctl_command): allowlisted verbs approve
// locally with no bridge call; shell run|serve, connection-overriding flags,
// chained commands, other tools and an unknown HEIMDALL_CTL_BIN still relay.
@(private = "file", thread_local)
codex_perm_calls: int

@(private = "file")
codex_perm_send :: proc(endpoint, token, method, params: string, timeout_ms: int) -> (string, bool) {
	codex_perm_calls += 1
	return `{"ok":true,"data":{"decision":"deny","message":"relayed"}}`, true
}

@(test)
test_codex_permission_self_approves_ham_ctl :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	env := Hook_Env{endpoint = "unix:/tmp/none.sock", token = "hlat_x", ts = TS, ctl_bin = "/run/inst/bin/ham-ctl"}
	ALLOW :: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
	bash :: proc(command: string) -> string {
		b := strings.builder_make()
		strings.write_string(&b, `{"session_id":"s1","turn_id":"t1","cwd":"/run/inst","hook_event_name":"PermissionRequest","permission_mode":"default","tool_name":"Bash","tool_input":{"command":`)
		json_write_string(&b, command)
		strings.write_string(&b, `}}`)
		return strings.to_string(b)
	}
	for cmd in ([]string{
		"./bin/ham-ctl chat read",
		"/run/inst/bin/ham-ctl lease next",
		"\"$HEIMDALL_CTL_BIN\" task comment t1 --body 'working'",
		"./bin/ham-ctl agent start-success",
		"./bin/ham-ctl extension status",
	}) {
		codex_perm_calls = 0
		testing.expectf(t, hook_run("codex", bash(cmd), env, codex_perm_send) == ALLOW, "should self-approve: %s", cmd)
		testing.expectf(t, codex_perm_calls == 0, "no bridge call for %s", cmd)
	}
	for cmd in ([]string{
		"./bin/ham-ctl shell run --cmd 'rm -rf ~'",
		"./bin/ham-ctl shell serve --port 8080",
		"./bin/ham-ctl chat read --agent-token other",
		"./bin/ham-ctl chat read --bridge-endpoint tcp:evil:1",
		"./bin/ham-ctl task list --as alice",
		"./bin/ham-ctl chat read *",
		"./bin/ham-ctl chat read ?-bridge-endpoint tcp:evil:1",
		"./bin/ham-ctl review post t1 --verdict approve --on-behalf-of user",
		"./bin/ham-ctl chat read && rm -rf /",
		"ham-ctl chat read",
		// S2: unquoted and unset, this runs `task` from PATH.
		"$HEIMDALL_CTL_BIN task fetch t1",
		// B1: installing a local plugin runs its hooks; event forges telemetry.
		"./bin/ham-ctl extension install codex --path /tmp/evil-plugin",
		"./bin/ham-ctl extension event --stdin",
		"./bin/ham-ctl extension hook codex",
	}) {
		codex_perm_calls = 0
		out := hook_run("codex", bash(cmd), env, codex_perm_send)
		testing.expectf(t, codex_perm_calls == 1, "must relay: %s", cmd)
		testing.expectf(t, strings.contains(out, `"message":"relayed"`), "relay decision for %s: %s", cmd, out)
	}
	// S1: Codex runs the command in tool_input.workdir when given, so the
	// relative shim resolves there; a relative or foreign workdir relays it, the
	// absolute ctl path and "$HEIMDALL_CTL_BIN" still self-approve.
	in_workdir :: proc(command, workdir: string) -> string {
		b := strings.builder_make()
		strings.write_string(&b, `{"session_id":"s1","cwd":"/run/inst","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":`)
		json_write_string(&b, command)
		strings.write_string(&b, `,"workdir":`)
		json_write_string(&b, workdir)
		strings.write_string(&b, `}}`)
		return strings.to_string(b)
	}
	Workdir_Case :: struct {command, workdir: string, approved: bool}
	for c in ([]Workdir_Case{
		{"./bin/ham-ctl chat read", "/run/inst", true},
		{"./bin/ham-ctl chat read", "/tmp/evil", false},
		{"./bin/ham-ctl chat read", "inst", false},
		{"./bin/ham-ctl chat read", "", false},
		{"/run/inst/bin/ham-ctl chat read", "/tmp/evil", true},
		{"/run/inst/bin/ham-ctl chat read", "relative/dir", true},
	}) {
		codex_perm_calls = 0
		out := hook_run("codex", in_workdir(c.command, c.workdir), env, codex_perm_send)
		testing.expectf(t, (out == ALLOW) == c.approved, "%s in workdir %q: %s", c.command, c.workdir, out)
		testing.expectf(t, codex_perm_calls == (0 if c.approved else 1), "%s in workdir %q: %d bridge calls", c.command, c.workdir, codex_perm_calls)
	}
	// Not the shell tool, or no issued ctl binary: always relay.
	codex_perm_calls = 0
	_ = hook_run("codex", `{"session_id":"s1","cwd":"/run/inst","hook_event_name":"PermissionRequest","tool_name":"apply_patch","tool_input":{"command":"./bin/ham-ctl chat read"}}`, env, codex_perm_send)
	testing.expect_value(t, codex_perm_calls, 1)
	codex_perm_calls = 0
	no_bin := env
	no_bin.ctl_bin = ""
	_ = hook_run("codex", bash("./bin/ham-ctl chat read"), no_bin, codex_perm_send)
	testing.expect_value(t, codex_perm_calls, 1)
}
