package extension

// Codex 0.162.0 callbacks, captured by extensions/codex/fixtures.
// Native tool/child/session identifiers are preserved; instance identity is
// always supplied by the issued transport token, never by stdin.
// Bash PostToolUse supplies stdout without an exit code. Completion is therefore
// "completed" (unknown outcome), not inferred success. Only confirmed apply_patch
// responses can produce file edits. Hosted tools and notifications are uncovered.

import json "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"

CODEX_PROVIDER :: "codex"
CODEX_EXT_VERSION :: "0.1.0"
// Native view_image PostToolUse includes a base64 image, often several MiB.
// Match the bounded CLI stdin reader; output remains capped independently below.
CODEX_HOOK_INPUT_MAX :: HOOK_INPUT_MAX
CODEX_CAPABILITIES :: contracts.Ext_Capabilities{.Activity, .Subagents, .Permissions, .File_Edits, .Session_Id, .Usage}

// codex_map_hook maps one Codex hook payload (a Map_Hook_Proc).
codex_map_hook :: proc(raw, ts: string, permission_timeout_ms := 0, permission_blocker_id := "") -> (out: Hook_Mapped, err: Hook_Error) {
	if len(raw) > CODEX_HOOK_INPUT_MAX do return out, .Too_Large
	value, parse_err := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true)
	if parse_err != .None do return out, .Malformed_Json
	root, ok := value.(json.Object)
	if !ok || json_get_string(root, "session_id") == "" do return out, .Malformed_Json
	name := json_get_string(root, "hook_event_name")
	event: contracts.Ext_Event_Kind
	p := pb_make()
	pb_str_nonempty(&p, "turn_id", json_get_string(root, "turn_id"))
	tool_input, tool_response: json.Value
	has_metrics, has_usage := false, false
	metrics: Tool_Metrics
	switch name {
	case "SessionStart":
		append(&out.events, ext_hello_event(ts, root, CODEX_PROVIDER, CODEX_EXT_VERSION, CODEX_CAPABILITIES))
		event = .Session
		pb_str(&p, "phase", "start")
		pb_str_nonempty(&p, "source", json_get_string(root, "source"))
		pb_str_nonempty(&p, "cwd", json_get_string(root, "cwd"))
		pb_str_nonempty(&p, "model", json_get_string(root, "model"))
	case "SessionEnd":
		event = .Session
		pb_str(&p, "phase", "end")
		pb_str_nonempty(&p, "reason", json_get_string(root, "reason"))
	case "UserPromptSubmit":
		event = .Activity
		pb_str(&p, "state", "active")
		pb_str(&p, "reason", "user_prompt")
	case "Stop", "Interrupt":
		event = .Activity
		pb_str(&p, "state", "idle")
		pb_str(&p, "reason", "interrupt" if name == "Interrupt" else "stop")
		has_usage = true
		// No background_running:0: a main turn ending does not end its children.
	case "SubagentStart", "SubagentStop":
		if json_get_string(root, "agent_id") == "" do return out, .Malformed_Json
		event = .Subagent_Start if name == "SubagentStart" else .Subagent_Stop
	case "PreToolUse", "PostToolUse":
		if json_get_string(root, "tool_use_id") == "" || json_get_string(root, "tool_name") == "" do return out, .Malformed_Json
		event = .Tool_Start if name == "PreToolUse" else .Tool_End
		// Never forward prompts or encrypted child instructions.
		tool_input = json_clip(root["tool_input"], 4096, {"message", "prompt"})
		if name == "PostToolUse" {
			// Native sizes, before clipping and before the image is dropped.
			metrics = tool_metrics(root["tool_input"], root["tool_response"])
			has_metrics, has_usage = true, true
			// Image bytes are not activity metadata. Do not clone, clip, or forward
			// the native data URL; the paired tool identity is sufficient.
			if json_get_string(root, "tool_name") != "view_image" {
				tool_response = json_clip(root["tool_response"], 4096)
			}
			pb_str(&p, "status", "completed")
			pb_str(&p, "outcome", "unknown")
		}
	case "PermissionRequest":
		if json_get_string(root, "tool_name") == "" do return out, .Malformed_Json
		event = .Permission_Request
		out.is_permission = true
		tool_input = json_clip(root["tool_input"], 4096, {"message", "prompt"})
		if tool_input == nil do tool_input = json.Object{}
		pb_permission_relay(&p, permission_timeout_ms, permission_blocker_id)
		pb_str_nonempty(&p, "permission_mode", json_get_string(root, "permission_mode"))
		// Codex's shell tool: its command feeds the shared ham-ctl self-approve rule.
		if json_get_string(root, "tool_name") == "Bash" {
			out.shell_command = json_get_string(json_get_object(root, "tool_input"), "command")
			out.shell_cwd = json_get_string(root, "cwd")
		}
	case "PreCompact", "PostCompact":
		// No activity transition; the bridge resets context accounting on it.
		append(&out.events, ext_compaction_event(ts, root, CODEX_PROVIDER, CODEX_EXT_VERSION, "pre" if name == "PreCompact" else "post"))
		return out, .None
	case:
		return out, .None
	}
	eb := ext_event_begin(event, ts, root, CODEX_PROVIDER, CODEX_EXT_VERSION)
	if name == "PreToolUse" || name == "PostToolUse" || name == "PermissionRequest" {
		// Identity must survive even when no input/response metadata is retained.
		ext_event_tool(&eb, root, tool_input, tool_response)
	}
	if has_metrics do ext_event_metrics(&eb, metrics)
	ext_event_finish_usage(&eb, CODEX_PROVIDER, root, has_usage)
	append(&out.events, ext_event_end(&eb, pb_done(&p)))
	if name == "PostToolUse" && json_get_string(root, "tool_name") == "apply_patch" {
		for edit in codex_patch_events(root, ts) do append(&out.events, edit)
	}
	// Bound aggregate-shaped inputs, not just individual strings.
	return hook_mapped_bounded(out)
}
