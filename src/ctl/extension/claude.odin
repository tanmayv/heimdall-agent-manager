package extension

// Claude Code adapter (REQ-EXT-CLAUDE-1): native hook JSON on stdin → ham.ext.v1.
//
//   SessionStart        → hello (capabilities) + session {phase:start}
//   SessionEnd          → session {phase:end}
//   UserPromptSubmit    → activity {state:active}
//   PreToolUse          → tool.start
//   PostToolUse         → tool.end (+ file.edit for Edit / MultiEdit / Write)
//   PostToolUseFailure  → tool.end {status:error}
//                         (every tool.end carries pre-clip metrics; tool.end and
//                         Stop carry transcript usage when readable)
//   SubagentStart/Stop  → subagent.start / subagent.stop
//   Stop                → activity {state:idle}
//   Notification        → notification
//   PermissionRequest   → permission.request (sent with agent.extension.permission)
//   PreCompact          → compaction {phase:pre, trigger}
//
// Payload facts come from the T1 spike against Claude Code 2.1.295: every hook
// fired inside a subagent carries top-level agent_id/agent_type; SubagentStart
// has no tool_use_id, so PreToolUse(Agent) and PostToolUse(Agent) expose the
// description and the authoritative tool_response.agentId for pairing;
// PermissionRequest has no tool_use_id. This file is the only place in the
// product that knows Claude's hook vocabulary.

import json "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"

CLAUDE_PROVIDER :: "claude"
CLAUDE_EXT_VERSION :: "0.1.0"
CLAUDE_CAPABILITIES :: contracts.Ext_Capabilities{.Activity, .Subagents, .Permissions, .File_Edits, .Session_Id, .Usage}

// Strings inside tool input / response are clipped so one event stays well
// under contracts.EXT_EVENT_MAX_BYTES (256KB) even with a 64KB diff.
CLAUDE_TOOL_STRING_MAX :: 4 * 1024
CLAUDE_MESSAGE_MAX :: 2 * 1024
// Hook stdin larger than this is ignored (Write payloads carry whole files).
CLAUDE_HOOK_INPUT_MAX :: HOOK_INPUT_MAX

Claude_Hook :: enum {
	Unknown,
	Session_Start,
	Session_End,
	User_Prompt_Submit,
	Pre_Tool_Use,
	Post_Tool_Use,
	Post_Tool_Use_Failure,
	Subagent_Start,
	Subagent_Stop,
	Stop,
	Notification,
	Permission_Request,
	Pre_Compact,
}

claude_hook_from_name :: proc(name: string) -> Claude_Hook {
	switch name {
	case "SessionStart":       return .Session_Start
	case "SessionEnd":         return .Session_End
	case "UserPromptSubmit":   return .User_Prompt_Submit
	case "PreToolUse":         return .Pre_Tool_Use
	case "PostToolUse":        return .Post_Tool_Use
	case "PostToolUseFailure": return .Post_Tool_Use_Failure
	case "SubagentStart":      return .Subagent_Start
	case "SubagentStop":       return .Subagent_Stop
	case "Stop":               return .Stop
	case "Notification":       return .Notification
	case "PermissionRequest":  return .Permission_Request
	case "PreCompact":         return .Pre_Compact
	}
	return .Unknown
}

// claude_map_hook maps one Claude hook payload (a Map_Hook_Proc). An unknown
// hook maps to no events.
claude_map_hook :: proc(raw, ts: string, permission_timeout_ms := 0, permission_blocker_id := "") -> (out: Hook_Mapped, err: Hook_Error) {
	if len(raw) > CLAUDE_HOOK_INPUT_MAX do return out, .Too_Large
	value, perr := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true)
	if perr != .None do return out, .Malformed_Json
	root, is_obj := value.(json.Object)
	if !is_obj do return out, .Malformed_Json

	switch claude_hook_from_name(json_get_string(root, "hook_event_name")) {
	case .Unknown:
	case .Session_Start:
		append(&out.events, ext_hello_event(ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION, CLAUDE_CAPABILITIES))

		s := pb_make()
		pb_str(&s, "phase", "start")
		pb_str_nonempty(&s, "source", json_get_string(root, "source"))
		pb_str_nonempty(&s, "cwd", json_get_string(root, "cwd"))
		pb_str_nonempty(&s, "model", json_get_string(root, "model"))
		eb2 := ext_event_begin(.Session, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
		append(&out.events, ext_event_end(&eb2, pb_done(&s)))

	case .Session_End:
		p := pb_make()
		pb_str(&p, "phase", "end")
		pb_str_nonempty(&p, "reason", json_get_string(root, "reason"))
		eb := ext_event_begin(.Session, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
		append(&out.events, ext_event_end(&eb, pb_done(&p)))

	case .User_Prompt_Submit:
		p := pb_make()
		pb_str(&p, "state", "active")
		pb_str(&p, "reason", "user_prompt")
		pb_str_nonempty(&p, "prompt_id", json_get_string(root, "prompt_id"))
		eb := ext_event_begin(.Activity, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
		append(&out.events, ext_event_end(&eb, pb_done(&p)))

	case .Stop:
		p := pb_make()
		pb_str(&p, "state", "idle")
		pb_str(&p, "reason", "stop")
		// Stop can fire while background subagents still run; they stay
		// active until their own subagent.stop.
		running := 0
		for t in json_get_array(root, "background_tasks") {
			if obj, ok := t.(json.Object); ok && json_get_string(obj, "status") == "running" do running += 1
		}
		pb_int(&p, "background_running", running)
		eb := ext_event_begin(.Activity, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
		ext_event_finish_usage(&eb, CLAUDE_PROVIDER, root, true)
		append(&out.events, ext_event_end(&eb, pb_done(&p)))

	case .Pre_Tool_Use:
		input := json_clip(root["tool_input"], CLAUDE_TOOL_STRING_MAX)
		p := pb_make()
		pb_str_nonempty(&p, "permission_mode", json_get_string(root, "permission_mode"))
		if json_get_string(root, "tool_name") == "Agent" || json_get_string(root, "tool_name") == "Task" {
			ti := json_get_object(root, "tool_input")
			pb_str_nonempty(&p, "description", json_get_string(ti, "description"))
			pb_str_nonempty(&p, "subagent_type", json_get_string(ti, "subagent_type"))
			pb_bool(&p, "run_in_background", json_get_bool(ti, "run_in_background"))
		}
		eb := ext_event_begin(.Tool_Start, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
		ext_event_tool(&eb, root, input, nil)
		append(&out.events, ext_event_end(&eb, pb_done(&p)))

	case .Post_Tool_Use:
		tool := json_get_string(root, "tool_name")
		// Measured on the native values, before clipping and dropped keys.
		metrics := tool_metrics(root["tool_input"], root["tool_response"])
		input := json_clip(root["tool_input"], CLAUDE_TOOL_STRING_MAX)
		// Whole-file fields duplicate the diff; drop them from tool.response.
		response := json_clip(root["tool_response"], CLAUDE_TOOL_STRING_MAX,
			{"originalFile", "content", "structuredPatch", "prompt", "usage"})
		p := pb_make()
		pb_str(&p, "status", "ok")
		if d, ok := json_get_int(root, "duration_ms"); ok do pb_int(&p, "duration_ms", d)
		if tool == "Agent" || tool == "Task" {
			tr := json_get_object(root, "tool_response")
			pb_str_nonempty(&p, "subagent_id", json_get_string(tr, "agentId"))
			pb_str_nonempty(&p, "subagent_status", json_get_string(tr, "status"))
			pb_str_nonempty(&p, "description", json_get_string(json_get_object(root, "tool_input"), "description"))
		}
		eb := ext_event_begin(.Tool_End, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
		ext_event_tool(&eb, root, input, response)
		ext_event_metrics(&eb, metrics)
		ext_event_finish_usage(&eb, CLAUDE_PROVIDER, root, true)
		append(&out.events, ext_event_end(&eb, pb_done(&p)))
		if ev, ok := claude_file_edit_event(root, ts); ok do append(&out.events, ev)

	case .Post_Tool_Use_Failure:
		// A failed call has no tool_response; the error text is what the
		// model receives instead.
		metrics := tool_metrics(root["tool_input"], root["error"])
		input := json_clip(root["tool_input"], CLAUDE_TOOL_STRING_MAX)
		p := pb_make()
		pb_str(&p, "status", "error")
		pb_str_nonempty(&p, "error", clip_string(json_get_string(root, "error"), CLAUDE_MESSAGE_MAX))
		if json_get_bool(root, "is_interrupt") do pb_bool(&p, "is_interrupt", true)
		eb := ext_event_begin(.Tool_End, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
		ext_event_tool(&eb, root, input, nil)
		ext_event_metrics(&eb, metrics)
		ext_event_finish_usage(&eb, CLAUDE_PROVIDER, root, true)
		append(&out.events, ext_event_end(&eb, pb_done(&p)))

	case .Pre_Compact:
		append(&out.events, ext_compaction_event(ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION, "pre"))

	case .Subagent_Start:
		eb := ext_event_begin(.Subagent_Start, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
		append(&out.events, ext_event_end(&eb, "{}"))

	case .Subagent_Stop:
		p := pb_make()
		pb_str_nonempty(&p, "agent_transcript_path", json_get_string(root, "agent_transcript_path"))
		pb_str_nonempty(&p, "last_assistant_message", clip_string(json_get_string(root, "last_assistant_message"), CLAUDE_MESSAGE_MAX))
		eb := ext_event_begin(.Subagent_Stop, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
		append(&out.events, ext_event_end(&eb, pb_done(&p)))

	case .Notification:
		ntype := json_get_string(root, "notification_type")
		p := pb_make()
		pb_str_nonempty(&p, "type", ntype)
		pb_str_nonempty(&p, "notification_type", ntype)
		pb_str_nonempty(&p, "title", clip_string(json_get_string(root, "title"), CLAUDE_MESSAGE_MAX))
		pb_str_nonempty(&p, "message", clip_string(json_get_string(root, "message"), CLAUDE_MESSAGE_MAX))
		eb := ext_event_begin(.Notification, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
		append(&out.events, ext_event_end(&eb, pb_done(&p)))

	case .Permission_Request:
		input := json_clip(root["tool_input"], CLAUDE_TOOL_STRING_MAX)
		p := pb_make()
		pb_str_nonempty(&p, "permission_mode", json_get_string(root, "permission_mode"))
		pb_permission_relay(&p, permission_timeout_ms, permission_blocker_id)
		if sugg := json_get_array(root, "permission_suggestions"); sugg != nil {
			pb_value(&p, "permission_suggestions", json_clip(sugg, CLAUDE_TOOL_STRING_MAX))
		}
		eb := ext_event_begin(.Permission_Request, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
		if input == nil do input = json.Object{}
		ext_event_tool(&eb, root, input, nil)
		append(&out.events, ext_event_end(&eb, pb_done(&p)))
		out.is_permission = true
		if json_get_string(root, "tool_name") == "Bash" {
			out.shell_command = json_get_string(json_get_object(root, "tool_input"), "command")
			out.shell_cwd = json_get_string(root, "cwd")
		}
	}
	return hook_mapped_bounded(out)
}

// claude_file_edit_event builds file.edit for Edit / MultiEdit / Write.
@(private = "file")
claude_file_edit_event :: proc(root: json.Object, ts: string) -> (string, bool) {
	tool := json_get_string(root, "tool_name")
	if tool != "Edit" && tool != "MultiEdit" && tool != "Write" do return "", false
	input := json_get_object(root, "tool_input")
	resp := json_get_object(root, "tool_response")
	path := json_get_string(input, "file_path")
	if path == "" do path = json_get_string(resp, "filePath")
	if path == "" do return "", false
	cwd := json_get_string(root, "cwd")

	operation := "edit"
	if tool == "MultiEdit" do operation = "multi_edit"
	original := json_get_string(resp, "originalFile")
	has_original := false
	if resp != nil {
		_, has_original = resp["originalFile"].(json.String)
	}
	if tool == "Write" {
		t := json_get_string(resp, "type")
		operation = "create" if t == "create" || (t == "" && !has_original) else "update"
	}

	res: Diff_Result
	source := ""
	hunks := claude_structured_patch(json_get_array(resp, "structuredPatch"))
	switch {
	case len(hunks) > 0:
		res = diff_structured(path, cwd, hunks)
		source = "structured_patch"
	case operation == "create":
		content := json_get_string(input, "content")
		if content == "" do content = json_get_string(resp, "content")
		res = diff_create(path, cwd, content)
		source = "content"
	case tool == "Write":
		content := json_get_string(input, "content")
		if content == "" do content = json_get_string(resp, "content")
		res = diff_replace_whole(path, cwd, original, content)
		source = "original_file"
	case:
		edits := make([dynamic]Diff_String_Edit)
		if tool == "MultiEdit" {
			for e in json_get_array(input, "edits") {
				if eo, ok := e.(json.Object); ok {
					append(&edits, Diff_String_Edit{json_get_string(eo, "old_string"), json_get_string(eo, "new_string")})
				}
			}
		} else {
			append(&edits, Diff_String_Edit{json_get_string(input, "old_string"), json_get_string(input, "new_string")})
		}
		res = diff_string_edits(path, cwd, original, edits[:])
		source = "strings"
	}

	p := pb_make()
	pb_str(&p, "file_path", path)
	pb_str(&p, "operation", operation)
	pb_str(&p, "diff", res.diff)
	pb_str(&p, "diff_source", source)
	pb_int(&p, "additions", res.additions)
	pb_int(&p, "deletions", res.deletions)
	if res.truncated do pb_bool(&p, "diff_truncated", true)
	if res.binary do pb_bool(&p, "binary", true)
	if json_get_bool(resp, "userModified") do pb_bool(&p, "user_modified", true)
	eb := ext_event_begin(.File_Edit, ts, root, CLAUDE_PROVIDER, CLAUDE_EXT_VERSION)
	ext_event_tool(&eb, root, nil, nil)
	return ext_event_end(&eb, pb_done(&p)), true
}

// claude_structured_patch converts tool_response.structuredPatch to hunks.
claude_structured_patch :: proc(arr: json.Array) -> []Diff_Hunk {
	if len(arr) == 0 do return nil
	hunks := make([dynamic]Diff_Hunk)
	for item in arr {
		obj, ok := item.(json.Object)
		if !ok do continue
		h: Diff_Hunk
		h.old_start, _ = json_get_int(obj, "oldStart")
		h.old_lines, _ = json_get_int(obj, "oldLines")
		h.new_start, _ = json_get_int(obj, "newStart")
		h.new_lines, _ = json_get_int(obj, "newLines")
		lines := make([dynamic]string)
		for l in json_get_array(obj, "lines") {
			if s, is := l.(json.String); is do append(&lines, string(s))
		}
		h.lines = lines[:]
		append(&hunks, h)
	}
	return hunks[:]
}
