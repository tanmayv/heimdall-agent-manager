package extension

import json "core:encoding/json"
import "core:testing"

// One env guard across every provider's hooks.json (P27, P28): each command is
// exactly hook_command(<provider>) (HOOK_COMMAND_GUARD), and each permission
// hook's timeout covers the relay budget plus the socket margin.
@(test)
test_hooks_json_commands_use_the_shared_env_guard :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	Manifest :: struct {
		provider, root_key, permission_hook, text: string,
		hooks: int,
	}
	manifests := []Manifest{
		{"claude", "hooks", "PermissionRequest", #load("../../../extensions/claude-code/hooks/hooks.json", string), 12},
		{"codex", "hooks", "PermissionRequest", #load("../../../extensions/codex/hooks/hooks.json", string), 12},
		{"antigravity", "heimdall", "PreToolUse", #load("../../../extensions/antigravity/hooks/hooks.json", string), 5},
	}
	min_permission_s := (PERMISSION_RELAY_TIMEOUT_MS + PERMISSION_SOCKET_MARGIN_MS) / 1000
	for m in manifests {
		testing.expectf(t, hook_provider_supported(m.provider), "%s has a hook adapter", m.provider)
		v, err := json.parse_string(m.text, json.DEFAULT_SPECIFICATION, true)
		testing.expectf(t, err == .None, "%s hooks.json parses", m.provider)
		events := json_get_object(v.(json.Object), m.root_key)
		testing.expectf(t, len(events) == m.hooks, "%s registers %d hooks, got %d", m.provider, m.hooks, len(events))
		want := hook_command(m.provider)
		count := 0
		for event, groups in events {
			arr, _ := groups.(json.Array)
			for g in arr {
				obj, _ := g.(json.Object)
				// Claude/Codex nest {matcher?, hooks:[...]}; agy lifecycle hooks are flat.
				flat := []json.Value{g}
				entries := json_get_array(obj, "hooks")[:]
				if entries == nil do entries = flat
				for e in entries {
					h, _ := e.(json.Object)
					count += 1
					testing.expectf(t, json_get_string(h, "type") == "command", "%s %s: type command", m.provider, event)
					cmd := json_get_string(h, "command")
					testing.expectf(t, cmd == want, "%s %s: command must be the shared guard\n  got:  %s\n  want: %s", m.provider, event, cmd, want)
					timeout, _ := json_get_int(h, "timeout")
					if event == m.permission_hook {
						testing.expectf(t, timeout > min_permission_s, "%s %s: timeout %ds must exceed %ds", m.provider, event, timeout, min_permission_s)
					}
				}
			}
		}
		testing.expectf(t, count >= m.hooks, "%s: every hook has a command", m.provider)
	}
}
