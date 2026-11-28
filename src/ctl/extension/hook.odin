package extension

// `ham-ctl extension hook <provider>` core, independent of the socket transport
// so it can be tested with a fake.
//
// Contract with the harness (REQ-EXT-CLAUDE-1, REQ-EXT-PERM-1):
//   - no bridge endpoint or agent token  → return "" without sending anything;
//   - non-permission events              → fire-and-forget with a short socket
//                                          timeout; stdout stays EMPTY (Claude
//                                          feeds SessionStart / UserPromptSubmit
//                                          stdout to the model);
//   - permission.request                 → block on agent.extension.permission
//                                          and return the provider's decision
//                                          JSON, or "" for no decision.
// Every failure fails open: "" and exit 0, never a block.
//
// Restart safety (REQ-EXT-BLK-1): the blocked hook process is the source of truth
// for its permission blocker. It picks a stable blocker_id up front and, when the
// bridge socket drops or the call fails with a transport error before the
// deadline (bridge restart), reconnects with backoff (250ms → 2s) and
// re-registers the SAME id with the remaining timeout until the deadline, so the
// bridge's in-memory blocker list rebuilds itself.
//
// Shared rules (P26-P28): before this core each adapter re-implemented its own
// copy of the hello capabilities serializer, event-name strings, the permission
// relay timeout (claude/codex passed it raw, antigravity clamped it twice and
// defaulted it in map_hook), the bridge decision parser, the event-size bounds
// (codex and antigravity only) and the ham-ctl self-approval (claude and
// antigravity only, so Codex never self-approved). They now live in one place:
//   - hook_adapter_run            one delivery path (event / permission relay);
//   - hook_permission_self_approved + is_ham_ctl_command  one self-approve rule;
//   - permission_timeout_clamp    one relay timeout rule;
//   - permission_decision_from_response  one bridge-reply parser;
//   - ext_hello_event, ext_event_begin(contracts.Ext_Event_Kind),
//     pb_permission_relay, hook_mapped_bounded  one event schema (event_json.odin).
// An adapter (claude.odin, codex.odin, antigravity.odin) only maps provider
// fields into Hook_Mapped and renders a decision in its provider's stdout format.

import "core:fmt"
import "core:encoding/json"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import agent_runtime "odin_test:lib/agent_runtime"

HOOK_INPUT_MAX :: 16 * 1024 * 1024

// EVENT_SOCKET_TIMEOUT_MS bounds a non-permission round trip to the bridge.
EVENT_SOCKET_TIMEOUT_MS :: 500
// PERMISSION_RELAY_TIMEOUT_MS is how long the bridge waits for a UI decision.
// Every provider's permission hook timeout (extensions/*/hooks/hooks.json, 330s)
// must stay above it plus PERMISSION_SOCKET_MARGIN_MS (checked by
// test_hooks_json_commands_use_the_shared_env_guard).
PERMISSION_RELAY_TIMEOUT_MS :: 300_000
PERMISSION_RELAY_TIMEOUT_MIN_MS :: 1_000
PERMISSION_SOCKET_MARGIN_MS :: 15_000
// PERMISSION_TIMEOUT_ENV lowers the relay wait (it is clamped to at most
// PERMISSION_RELAY_TIMEOUT_MS so the hook budget always covers it).
PERMISSION_TIMEOUT_ENV :: "HEIMDALL_EXT_PERMISSION_TIMEOUT_MS"
// Re-registration backoff after a transport failure.
PERMISSION_RETRY_BACKOFF_MIN_MS :: 250
PERMISSION_RETRY_BACKOFF_MAX_MS :: 2_000

// HOOK_COMMAND_GUARD is the one env guard every provider's hooks.json uses
// (extensions/*/hooks/hooks.json, kept identical by
// test_hooks_json_commands_use_the_shared_env_guard): outside a Heimdall-launched
// agent HEIMDALL_CTL_BIN is unset or not executable, so the hook exits 0 at once
// with no output and never blocks the provider; inside one it execs ham-ctl.
HOOK_COMMAND_GUARD :: `[ -x "${HEIMDALL_CTL_BIN:-}" ] || exit 0; exec "$HEIMDALL_CTL_BIN" extension hook `

// hook_command is the hooks.json command for a provider's hook id.
hook_command :: proc(provider: string, allocator := context.allocator) -> string {
	return strings.concatenate({HOOK_COMMAND_GUARD, provider}, allocator)
}

// Send_Proc sends one bridge RPC and returns the raw response line.
Send_Proc :: proc(endpoint, token, method, params: string, timeout_ms: int) -> (response: string, ok: bool)

Hook_Env :: struct {
	endpoint: string,
	token:    string,
	ts:       string, // RFC 3339 event time
	permission_timeout_ms: int, // 0 = PERMISSION_RELAY_TIMEOUT_MS
	// Seams for tests; nil/"" = real clock, real sleep, a fresh random id.
	now_ms:     proc() -> i64,
	sleep_ms:   proc(ms: int),
	blocker_id: string,
	ctl_bin:    string, // HEIMDALL_CTL_BIN: its absolute path also counts as ham-ctl
}

new_blocker_id :: proc() -> string {
	return fmt.aprintf("blk_%016x%08x", rand.uint64(), u32(rand.uint32()))
}

@(private = "file")
real_now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

@(private = "file")
real_sleep_ms :: proc(ms: int) {
	time.sleep(time.Duration(ms) * time.Millisecond)
}

// Permission_Reply classifies an agent.extension.permission response.
Permission_Reply :: enum {
	Final, // the bridge answered (a decision, "none", or a request error)
	Retry, // transport failure or a bridge that is not ready: re-register
}

// permission_reply_kind: ok:true and bad_request are final; anything that is not
// a parseable bridge reply (socket closed mid-wait, empty read) or a transient
// error code is retried.
permission_reply_kind :: proc(response: string, ok: bool) -> Permission_Reply {
	if !ok do return .Retry
	value, err := json.parse_string(strings.trim_space(response), json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != .None do return .Retry
	root, is_obj := value.(json.Object)
	if !is_obj do return .Retry
	if json_get_bool(root, "ok") do return .Final
	code := json_get_string(root, "code")
	if code == "" do code = json_get_string(json_get_object(root, "error"), "code")
	if code == "bad_request" || code == "forbidden" || code == "method_not_allowed" do return .Final
	return .Retry
}

// relay_permission blocks on agent.extension.permission for one blocker_id,
// re-registering it after transport failures until the deadline. The adapter
// re-maps the hook for the remaining timeout on every attempt. It returns the
// bridge's decision and message, or decision "none" when no decision arrived.
relay_permission :: proc(env: Hook_Env, send: Send_Proc, timeout_ms: int, adapter: Hook_Adapter, raw: string) -> (decision, message: string) {
	now := env.now_ms if env.now_ms != nil else real_now_ms
	sleep := env.sleep_ms if env.sleep_ms != nil else real_sleep_ms
	blocker_id := env.blocker_id if env.blocker_id != "" else new_blocker_id()
	deadline := now() + i64(timeout_ms)
	backoff := PERMISSION_RETRY_BACKOFF_MIN_MS
	for {
		remaining := int(deadline - now())
		if remaining < PERMISSION_RELAY_TIMEOUT_MIN_MS do return "none", ""
		mapped, err := adapter.map_hook(raw, env.ts, remaining, blocker_id)
		if err != .None || !mapped.is_permission || len(mapped.events) != 1 do return "none", ""
		response, sent := send(env.endpoint, env.token, "agent.extension.permission", mapped.events[0], remaining + PERMISSION_SOCKET_MARGIN_MS)
		if permission_reply_kind(response, sent) == .Final do return permission_decision_from_response(response)
		if int(deadline - now()) < backoff + PERMISSION_RELAY_TIMEOUT_MIN_MS do return "none", ""
		sleep(backoff)
		backoff = min(backoff * 2, PERMISSION_RETRY_BACKOFF_MAX_MS)
	}
}

env_ready :: proc(env: Hook_Env) -> bool {
	return strings.trim_space(env.endpoint) != "" && strings.trim_space(env.token) != ""
}

// permission_timeout_clamp is the one relay-timeout rule: unset (<= 0) means
// PERMISSION_RELAY_TIMEOUT_MS, anything else is clamped to
// [PERMISSION_RELAY_TIMEOUT_MIN_MS, PERMISSION_RELAY_TIMEOUT_MS] so every
// provider's permission hook budget (330s in the hooks.json files) covers it.
permission_timeout_clamp :: proc(ms: int) -> int {
	if ms <= 0 do return PERMISSION_RELAY_TIMEOUT_MS
	return clamp(ms, PERMISSION_RELAY_TIMEOUT_MIN_MS, PERMISSION_RELAY_TIMEOUT_MS)
}

// permission_timeout_from_env reads PERMISSION_TIMEOUT_ENV, clamped.
permission_timeout_from_env :: proc() -> int {
	raw := os.get_env(PERMISSION_TIMEOUT_ENV, context.temp_allocator)
	v, ok := strconv.parse_int(strings.trim_space(raw))
	if !ok do return PERMISSION_RELAY_TIMEOUT_MS
	return permission_timeout_clamp(v)
}

// permission_decision_from_response reads an agent.extension.permission bridge
// response ({ok, data:{decision, message}}, tolerating one extra data envelope).
// Errors, unreachable bridges and unparseable replies yield decision "none".
// The strings live in context.temp_allocator: render them before freeing it.
permission_decision_from_response :: proc(response: string) -> (decision, message: string) {
	value, err := json.parse_string(strings.trim_space(response), json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != .None do return "none", ""
	root, ok := value.(json.Object)
	if !ok || !json_get_bool(root, "ok") do return "none", ""
	data := json_get_object(root, "data")
	if inner := json_get_object(data, "data"); inner != nil && !json_has(data, "decision") do data = inner
	decision = json_get_string(data, "decision")
	if decision == "" do decision = "none"
	return decision, json_get_string(data, "message")
}

PERMISSION_DENY_DEFAULT_MESSAGE :: "Denied in Ninjy"
PERMISSION_MESSAGE_MAX :: 2 * 1024

// permission_request_output renders the PermissionRequest hookSpecificOutput
// decision that Claude Code defined and Codex adopted. "none" (or anything
// else) yields "" — print nothing so the native prompt stays.
permission_request_output :: proc(decision, message: string) -> string {
	switch decision {
	case "allow":
		return `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
	case "deny":
		b := strings.builder_make()
		msg := message if strings.trim_space(message) != "" else PERMISSION_DENY_DEFAULT_MESSAGE
		strings.write_string(&b, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":`)
		json_write_string(&b, clip_string(msg, PERMISSION_MESSAGE_MAX))
		strings.write_string(&b, `}}}`)
		return strings.to_string(b)
	}
	return ""
}

// Hook_Error is why a native hook payload produced no events.
Hook_Error :: enum {
	None,
	Too_Large,
	Malformed_Json,
}

// Hook_Mapped is one native hook invocation mapped to ham.ext.v1. events are
// complete event documents in send order. A permission request maps to exactly
// one permission.request event, which goes to agent.extension.permission;
// everything else goes to agent.extension.event (event_params).
Hook_Mapped :: struct {
	events:        [dynamic]string,
	is_permission: bool,
	// Set by the adapter when the permission request is for the provider's
	// shell tool: the command line and its working directory, which the shared
	// self-approve rule (hook_permission_self_approved) inspects.
	shell_command: string,
	shell_cwd:     string,
}

// Map_Hook_Proc maps one native hook payload. ts is the RFC 3339 event time;
// permission_timeout_ms > 0 and a non-empty permission_blocker_id become the
// permission.request relay fields (pb_permission_relay).
Map_Hook_Proc :: proc(raw, ts: string, permission_timeout_ms: int, permission_blocker_id: string) -> (Hook_Mapped, Hook_Error)

// Render_Decision_Proc renders a permission decision ("allow", "deny",
// "none", ...) as the provider's hook stdout; "" prints nothing.
Render_Decision_Proc :: proc(decision, message: string) -> string

// Hook_Adapter is one Heimdall extension mechanism. Adapters only map provider
// fields; the delivery rules (self-approval of ham-ctl, the relay timeout clamp,
// blocker re-registration, event bounds and the hello schema) are shared and
// live here and in event_json.odin. HOOK_ADAPTERS is keyed by the provider
// registry's extension kind, so a provider reaches an adapter only through its
// descriptor (G7, G9).
Hook_Adapter :: struct {
	map_hook:        Map_Hook_Proc,
	render_decision: Render_Decision_Proc,
	usage:           Usage_Reader, // nil: the provider reports no context usage
}

@(private = "file")
HOOK_ADAPTERS := [contracts.Provider_Extension_Kind]Hook_Adapter{
	.None               = {},
	.Claude_Plugin      = {map_hook = claude_map_hook, render_decision = permission_request_output, usage = claude_usage_reader},
	.Codex_Plugin       = {map_hook = codex_map_hook, render_decision = permission_request_output, usage = codex_usage_reader},
	.Antigravity_Plugin = {map_hook = antigravity_map_hook, render_decision = antigravity_permission_output},
}

// hook_adapter_for resolves a provider id (or alias) to its extension adapter;
// ok is false for an unknown provider or one without a Heimdall extension.
hook_adapter_for :: proc(provider: string) -> (Hook_Adapter, bool) {
	d, ok := contracts.provider_descriptor(provider)
	if !ok || d.extension == .None do return {}, false
	adapter := HOOK_ADAPTERS[d.extension]
	return adapter, adapter.map_hook != nil
}

// hook_provider_supported reports whether `ham-ctl extension hook <provider>`
// handles provider.
hook_provider_supported :: proc(provider: string) -> bool {
	_, ok := hook_adapter_for(provider)
	return ok
}

// hook_run maps provider's native hook JSON and delivers it. The returned string
// is exactly what ham-ctl prints to stdout ("" = print nothing). Providers
// without an extension adapter are ignored.
hook_run :: proc(provider, raw: string, env: Hook_Env, send: Send_Proc) -> string {
	if !env_ready(env) do return ""
	adapter, ok := hook_adapter_for(provider)
	if !ok do return ""
	return hook_adapter_run(adapter, raw, env, send)
}

// hook_adapter_run is the one delivery path for every adapter.
hook_adapter_run :: proc(adapter: Hook_Adapter, raw: string, env: Hook_Env, send: Send_Proc) -> string {
	timeout := permission_timeout_clamp(env.permission_timeout_ms)
	mapped, err := adapter.map_hook(raw, env.ts, timeout, "")
	if err != .None || len(mapped.events) == 0 do return ""
	if !mapped.is_permission {
		_, _ = send(env.endpoint, env.token, "agent.extension.event", event_params(mapped.events[:]), EVENT_SOCKET_TIMEOUT_MS)
		return ""
	}
	// A lone allowlisted ham-ctl invocation is the agent talking to Heimdall
	// itself: approve it locally, with no blocker and no event.
	if hook_permission_self_approved(mapped, env.ctl_bin) do return adapter.render_decision("allow", "")
	decision, message := relay_permission(env, send, timeout, adapter, raw)
	return adapter.render_decision(decision, message)
}

// hook_permission_self_approved is the one self-approve rule: the request is
// for the provider's shell tool and its command is one allowlisted ham-ctl
// invocation (is_ham_ctl_command).
hook_permission_self_approved :: proc(mapped: Hook_Mapped, ctl_bin: string) -> bool {
	return mapped.is_permission && mapped.shell_command != "" && is_ham_ctl_command(mapped.shell_command, ctl_bin, mapped.shell_cwd)
}

// hook_mapped_bounded drops a mapping whose events would exceed the bridge's
// limits (ext_events_within_bounds); map_hook procs end with it.
hook_mapped_bounded :: proc(out: Hook_Mapped) -> (Hook_Mapped, Hook_Error) {
	if !ext_events_within_bounds(out.events[:]) do return {}, .Too_Large
	return out, .None
}

// is_ham_ctl_command reports whether a shell command is exactly one ham-ctl
// invocation of an allowlisted, side-effect-bounded verb, so it can be approved
// without asking the user.
//   - Program: only the bridge-issued ctl_bin (HEIMDALL_CTL_BIN), written as its
//     absolute path, as $HEIMDALL_CTL_BIN, or as ./bin/ham-ctl (the run-dir shim) when that
//     resolves (against the hook's cwd) to ctl_bin. A bare `ham-ctl` goes through
//     PATH and never matches; nothing matches when ctl_bin is unknown.
//   - Shape: no chaining, pipe, background, subshell, substitution, redirect,
//     brace or newline, and no `$` after the program, so `ham-ctl x && rm -rf ~`
//     never matches.
//   - Verb: HAM_CTL_AUTO_APPROVE_VERBS only. `shell run|serve` (arbitrary command
//     execution through the hub) and anything that reconfigures agents, bridges or
//     fleets (hub, agents, bridge, task-chain, ...) always ask.
is_ham_ctl_command :: proc(command, ctl_bin, cwd: string) -> bool {
	cmd := strings.trim_space(command)
	if cmd == "" || strings.trim_space(ctl_bin) == "" do return false
	for ch in cmd {
		switch ch {
		case ';', '&', '|', '`', '<', '>', '\n', '\r', '(', ')', '{', '}':
			return false
		}
	}
	fields := strings.fields(cmd, context.temp_allocator)
	if len(fields) < 2 do return false
	head := fields[0]
	for f in fields[1:] {
		if strings.contains_rune(f, '$') do return false
	}
	if !ham_ctl_head_is_ctl_bin(head, ctl_bin, cwd) do return false
	if ham_ctl_args_override_connection(fields[1:]) do return false
	group := fields[1]
	verb := fields[2] if len(fields) > 2 else ""
	for allowed in HAM_CTL_AUTO_APPROVE_VERBS {
		if allowed.group != group do continue
		if allowed.verb != "*" && allowed.verb != verb do continue
		return true
	}
	return false
}

Ham_Ctl_Verb :: struct {
	group, verb: string, // verb "*" = every verb of the group
}

// HAM_CTL_AUTO_APPROVE_VERBS: the agent's own coordination traffic with Heimdall.
// Nothing here may write something that later acts on the agent's behalf, so
// only task read/comment verbs are listed (create/update/publish change what
// other agents are asked to do). `review` always asks:
// `review post --on-behalf-of user` records a verdict as the user, and shell
// quoting makes a flag deny-list unreliable. Only `extension status` (a read) is
// listed: `extension install --path <dir>` adds a local plugin marketplace whose
// hooks run arbitrary code, and `extension event` forges telemetry. The
// providers' hooks.json run `extension hook` directly, never through the shell
// tool, so it never needs approval here.
HAM_CTL_AUTO_APPROVE_VERBS :: [?]Ham_Ctl_Verb{
	{"chat", "read"}, {"chat", "send"},
	{"lease", "*"},
	{"task", "show"}, {"task", "fetch"}, {"task", "list"}, {"task", "comments"}, {"task", "comment"},
	{"extension", "status"}, {"search", "*"},
	{"memory", "propose"}, {"memory", "list"}, {"memory", "show"}, {"memory", "content"},
	{"agent", "start-success"},
	{"issue", "list"}, {"issue", "show"}, {"issue", "create"}, {"issue", "vote"},
}

@(private = "file")
ham_ctl_head_is_ctl_bin :: proc(head, ctl_bin, cwd: string) -> bool {
	switch head {
	case "$HEIMDALL_CTL_BIN", "\"$HEIMDALL_CTL_BIN\"":
		return true
	case agent_runtime.CTL_SHIM_INVOCATION, agent_runtime.CTL_SHIM_PATH:
		if strings.trim_space(cwd) == "" do return false
		joined, _ := filepath.join({cwd, head}, context.temp_allocator)
		clean_bin, _ := filepath.clean(ctl_bin, context.temp_allocator)
		return joined == clean_bin
	}
	clean_head, _ := filepath.clean(head, context.temp_allocator)
	clean_bin, _ := filepath.clean(ctl_bin, context.temp_allocator)
	return filepath.is_abs(head) && clean_head == clean_bin
}

// HAM_CTL_CONNECTION_FLAGS redirect where ham-ctl connects or whose identity it
// uses (e.g. `--bridge-endpoint tcp:evil:1` would send the agent token away,
// `--agent-token` would act as another agent). Never auto-approved.
HAM_CTL_CONNECTION_FLAGS :: [?]string{
	"--bridge-endpoint", "--agent-token", "--token", "--user-token",
	"--hub", "--hub-url", "--daemon-url", "--config", "--agent-mode", "--wrapper-bin",
}

// ham_ctl_args_override_connection: bash strips quotes and backslashes before
// ham-ctl sees argv, so each word is unquoted before comparing; a glob in a
// flag-like word could expand to one of the flags, so it fails safe too.
@(private = "file")
ham_ctl_args_override_connection :: proc(args: []string) -> bool {
	for f in args {
		word, _ := strings.remove_all(f, "'", context.temp_allocator)
		word, _ = strings.remove_all(word, "\"", context.temp_allocator)
		word, _ = strings.remove_all(word, "\\", context.temp_allocator)
		if !strings.has_prefix(word, "--") do continue
		if strings.contains_any(word, "*?[") do return true
		name := word
		if eq := strings.index_byte(word, '='); eq >= 0 do name = word[:eq]
		for flag in HAM_CTL_CONNECTION_FLAGS do if name == flag do return true
	}
	return false
}
