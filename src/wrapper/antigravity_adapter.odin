package main

// Antigravity (agy) interactive adapter.
//
// Task: task_18c70887a31ffba4. Micro-spike RESOLVED: agy PreTool hooks CAN return a
// blocking allow/deny via stdout — the shipped jetski_pre_tool.py prints
// {"allowTool": true} and the agy binary carries a typed exa.hooks_pb.PreToolHookResult
// proto (allow_tool / denyReason / toolAction). So we take the synchronous-relay path
// (no Python SDK fallback needed).
//
// Design (observe + mirror + gate):
//   - Activity: BeforeTool/BeforeModel = active, AfterTool/AfterModel/AfterAgent/Stop =
//     idle, Notification (approval matcher) = waiting_user. Each hook posts
//     agent.activity.report to the bridge local endpoint (HEIMDALL_BRIDGE_ENDPOINT),
//     replacing the reference impl's agent-tracker socket target.
//   - Permission gate: the BeforeTool hook classifies risk; safe tools auto-allow
//     ({"allowTool": true}); risky tools call agent.permission.request (blocking) and
//     map allow -> {"allowTool": true} / deny -> {"allowTool": false, "denyReason": ...}.
//
// Managed-machine note: ~/.gemini/hooks.json and hook scripts are read-only
// Nix/home-manager symlinks here, so we write our hooks + a hooks.json overlay into a
// writable dir under the run dir and point agy at it (never overwrite the symlinks).

import "core:fmt"
import "core:os"
import "core:strings"

ANTIGRAVITY_OVERLAY_REL_DIR :: ".heimdall/antigravity"
ANTIGRAVITY_HOOKS_JSON_REL_PATH :: ".heimdall/antigravity/hooks.json"
ANTIGRAVITY_HOOK_SCRIPT_REL_PATH :: ".heimdall/antigravity/heimdall_hook.py"

wrapper_bridge_should_load_antigravity :: proc(cfg: Bridge_Runtime_Config) -> bool {
	if strings.trim_space(cfg.provider) == "antigravity" do return true
	if strings.trim_space(cfg.provider) == "agy" do return true
	if len(cfg.agent_argv) > 0 && wrapper_bridge_command_looks_like_antigravity(cfg.agent_argv[0]) do return true
	return false
}

wrapper_bridge_command_looks_like_antigravity :: proc(name: string) -> bool {
	trimmed := strings.trim_space(name)
	if trimmed == "agy" do return true
	if strings.has_suffix(trimmed, "/agy") || strings.has_suffix(trimmed, "\\agy") do return true
	if strings.index(trimmed, "antigravity") >= 0 do return true
	return false
}

// Writes the Heimdall hook script + a hooks.json overlay into the run dir. Returns the
// absolute overlay hooks.json path (for HOOKS_CONFIG/env wiring) and ok.
wrapper_bridge_write_antigravity_hooks :: proc(cfg: Bridge_Runtime_Config) -> (string, bool) {
	base := strings.trim_right(cfg.working_dir, "/")
	dir := strings.concatenate({base, "/", ANTIGRAVITY_OVERLAY_REL_DIR})
	_ = os.make_directory_all(dir)
	script_path := strings.concatenate({base, "/", ANTIGRAVITY_HOOK_SCRIPT_REL_PATH})
	hooks_path := strings.concatenate({base, "/", ANTIGRAVITY_HOOKS_JSON_REL_PATH})
	if os.write_entire_file(script_path, wrapper_bridge_build_antigravity_hook_script()) != nil do return "", false
	if os.write_entire_file(hooks_path, wrapper_bridge_build_antigravity_hooks_json(script_path)) != nil do return "", false
	return hooks_path, true
}

// hooks.json overlay wiring every relevant event to the single Heimdall hook script,
// which dispatches on the HEIMDALL_HOOK_EVENT env we set per entry.
wrapper_bridge_build_antigravity_hooks_json :: proc(script_path: string) -> string {
	b := strings.builder_make()
	entry :: proc(b: ^strings.Builder, event, script, hook_event: string, first: bool) {
		if !first do strings.write_string(b, ",")
		strings.write_string(b, "\"")
		json_write_string(b, event)
		strings.write_string(b, "\":[{\"matcher\":\"*\",\"hooks\":[{\"name\":\"heimdall-")
		json_write_string(b, hook_event)
		strings.write_string(b, "\",\"type\":\"command\",\"command\":\"HEIMDALL_HOOK_EVENT=")
		json_write_string(b, hook_event)
		strings.write_string(b, " python3 ")
		json_write_string(b, script)
		strings.write_string(b, "\",\"timeout\":120000}]}]")
	}
	strings.write_string(&b, "{\"hooks\":{")
	entry(&b, "BeforeTool", script_path, "before_tool", true)
	entry(&b, "AfterTool", script_path, "after_tool", false)
	entry(&b, "BeforeModel", script_path, "before_model", false)
	entry(&b, "AfterModel", script_path, "after_model", false)
	entry(&b, "AfterAgent", script_path, "after_agent", false)
	entry(&b, "Stop", script_path, "stop", false)
	entry(&b, "Notification", script_path, "notification", false)
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

// The Heimdall hook script: one file, dispatches on HEIMDALL_HOOK_EVENT. Posts activity
// to the bridge for every event and, for BeforeTool, performs the blocking permission
// gate and returns an allow/deny decision on stdout.
wrapper_bridge_build_antigravity_hook_script :: proc() -> string {
	return `#!/usr/bin/env python3
# HEIMDALL-MANAGED-ANTIGRAVITY-HOOK v1: safe to overwrite
import json, os, socket, sys, time

EVENT = os.environ.get("HEIMDALL_HOOK_EVENT", "unknown")
ENDPOINT = os.environ.get("HEIMDALL_BRIDGE_ENDPOINT", "")
TOKEN = os.environ.get("HEIMDALL_AGENT_TOKEN", "")

def _read_stdin():
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}

def _connect():
    if not ENDPOINT:
        return None
    try:
        if ENDPOINT.startswith("unix:"):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(125.0)
            s.connect(ENDPOINT[5:])
            return s
        if ENDPOINT.startswith("tcp:"):
            raw = ENDPOINT[4:]
            host, _, port = raw.rpartition(":")
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(125.0)
            s.connect((host, int(port)))
            return s
    except Exception:
        return None
    return None

_seq = 0
def _call(method, params, want_reply=False):
    global _seq
    if not (ENDPOINT and TOKEN):
        return None
    s = _connect()
    if s is None:
        return None
    try:
        _seq += 1
        line = json.dumps({"v": 1, "id": "agy-%d-%d" % (int(time.time()*1000), _seq),
                           "token": TOKEN, "method": method, "params": params}) + "\n"
        s.sendall(line.encode())
        if not want_reply:
            return None
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        first = buf.split(b"\n", 1)[0].decode(errors="replace").strip()
        return json.loads(first) if first else None
    except Exception:
        return None
    finally:
        try: s.close()
        except Exception: pass

def _activity(status, summary=""):
    _call("agent.activity.report", {"status": status, "source": "pi_extension",
                                    "summary": summary, "checked_unix_ms": int(time.time()*1000)})

def _tool_name(data):
    tc = data.get("toolCall") or data.get("tool_call") or {}
    return str(tc.get("name") or data.get("toolName") or data.get("tool") or "tool")

def _tool_input(data):
    tc = data.get("toolCall") or data.get("tool_call") or {}
    return tc.get("args") or tc.get("input") or data.get("input") or {}

SAFE = ("read", "grep", "ls", "list", "find", "glob", "cat", "search", "view", "fetch", "get")
def _risk(name):
    n = name.lower()
    for s in SAFE:
        if n == s or s in n:
            return "safe"
    return "risky"

def main():
    data = _read_stdin()
    # Activity mapping.
    if EVENT in ("before_tool", "before_model"):
        _activity("active", EVENT)
    elif EVENT in ("after_tool", "after_model", "after_agent", "stop"):
        _activity("idle", EVENT)
    elif EVENT == "notification":
        _activity("waiting_user", "approval")

    # Permission gate on before_tool only.
    if EVENT == "before_tool":
        name = _tool_name(data)
        if _risk(name) == "safe":
            print(json.dumps({"allowTool": True})); return
        _activity("waiting_user", "approval: " + name)
        rid = "req-%d" % int(time.time()*1000)
        resp = _call("agent.permission.request",
                     {"request_id": rid, "tool": name, "risk": "risky",
                      "input": _tool_input(data), "timeout_ms": 120000}, want_reply=True)
        decision = "deny"; reason = "no decision from bridge"
        if resp and resp.get("ok") and isinstance(resp.get("data"), dict):
            decision = str(resp["data"].get("decision", "deny"))
            reason = str(resp["data"].get("reason", reason))
        _activity("active", name)
        if decision == "allow":
            print(json.dumps({"allowTool": True}))
        elif decision == "ask":
            # Let agy's native prompt handle it.
            print(json.dumps({}))
        else:
            print(json.dumps({"allowTool": False, "denyReason": reason}))
        return

    # Non-gating events: emit empty result.
    print(json.dumps({}))

if __name__ == "__main__":
    main()
`
}

// Emits a short human summary for logs/debugging.
wrapper_bridge_antigravity_summary :: proc(hooks_path: string) -> string {
	return fmt.tprintf("antigravity hooks overlay written: %s", hooks_path)
}
