package content

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// Activity-gated title-nudge engine (REQ-4,5,6).
//
// A freshly-launched run gets a DEFAULT title "<agent-name> #<n>" (T1). Once the
// user and the owning/coordinator agent have actually exchanged messages, we ask
// that agent ONCE to set a human-meaningful conversation + chain title. We do NOT
// build a new notifier: the nudge is delivered over the SAME bridge runtime
// command path used by notify_agent_message (the gated-notification path), so it
// reuses existing wake/delivery/coalescing on the bridge.
//
// Re-nudge is heavily gated so we never spam:
//   - title_source must still be "default" (agent- or user-set titles stop us);
//   - there must be NEW activity since the last nudge (last_activity_at moved);
//   - at least `cooldown` seconds must have elapsed since last_title_nudge_at.
// A user-set title wins forever (title_source "user"); any non-default title
// (agent or user) also stops nudges.

// DEFAULT_TITLE_NUDGE_COOLDOWN_SECONDS is the fallback cooldown (1 hour) between
// re-nudges for the same conversation. Config-tunable via Hub_Config.
DEFAULT_TITLE_NUDGE_COOLDOWN_SECONDS :: 3600

// Title_Nudge_Decision is the pure output of evaluating one conversation.
Title_Nudge_Decision :: struct {
	should_nudge: bool,
	reason:       string, // "" when should_nudge, else why it was skipped
}

// evaluate_title_nudge is pure + clock-injectable so it is trivially testable.
//   - title_source:    "default" | "agent" | "user"
//   - has_exchange:    at least one user->agent AND one agent->user message exist
//   - last_activity_ms: most recent meaningful activity (unix ms; 0 = none)
//   - last_nudge_ms:   time of the previous nudge (unix ms; 0 = never nudged)
//   - now_ms:          current time (unix ms)
//   - cooldown_seconds: minimum gap between re-nudges
evaluate_title_nudge :: proc(title_source: string, has_exchange: bool, last_activity_ms, last_nudge_ms, now_ms: i64, cooldown_seconds: int) -> Title_Nudge_Decision {
	// Guardrail: user-set title wins forever; any non-default title stops nudges.
	if title_source != "default" do return Title_Nudge_Decision{should_nudge = false, reason = "non_default_title"}
	// Gate on the first meaningful user<->agent exchange.
	if !has_exchange do return Title_Nudge_Decision{should_nudge = false, reason = "no_exchange"}
	// First nudge fires as soon as the exchange exists.
	if last_nudge_ms <= 0 do return Title_Nudge_Decision{should_nudge = true, reason = ""}
	// Re-nudge only when there is NEW activity since the last nudge.
	if last_activity_ms <= last_nudge_ms do return Title_Nudge_Decision{should_nudge = false, reason = "no_new_activity"}
	// ...and only after the cooldown has elapsed.
	cooldown := cooldown_seconds
	if cooldown <= 0 do cooldown = DEFAULT_TITLE_NUDGE_COOLDOWN_SECONDS
	if now_ms - last_nudge_ms < i64(cooldown) * 1000 do return Title_Nudge_Decision{should_nudge = false, reason = "cooldown"}
	return Title_Nudge_Decision{should_nudge = true, reason = ""}
}

// conversation_has_user_agent_exchange reports whether the conversation contains
// at least one message in BOTH the user->agent and agent->user directions, i.e.
// a real two-way exchange has happened.
conversation_has_user_agent_exchange :: proc(s: ^Content_Service, c: domain.Chat_Conversation) -> bool {
	if s == nil || s.content == nil do return false
	rows, err := iface.content_list_user_visible_messages(s.content, c.conversation_id, c.owner_user_id, 200, "")
	if err.code != .None do return false
	saw_user := false
	saw_agent := false
	for m in rows {
		switch m.direction {
		case "user_to_agent":
			saw_user = true
		case "agent_to_user":
			saw_agent = true
		}
		if saw_user && saw_agent do return true
	}
	return false
}

// record_activity_and_maybe_nudge stamps last_activity_at on the conversation (and
// its chain), then evaluates the title-nudge gate and, if it fires, delivers a
// single nudge over the bridge runtime command path and stamps last_title_nudge_at
// on both the conversation and the chain. Best-effort: any repo/bridge failure is
// swallowed so it never blocks the caller's primary message flow. `now` is the
// caller's clock timestamp (already stamped onto the message/conversation).
record_activity_and_maybe_nudge :: proc(s: ^Content_Service, conversation_id: string, now: string) {
	if s == nil || s.content == nil do return
	c, ok, _ := iface.content_get_conversation(s.content, conversation_id)
	if !ok do return

	// 1) Track activity: bump last_activity_at on the conversation and its chain.
	c.last_activity_at = now
	c.updated_at = now
	saved, save_ok, _ := iface.content_save_conversation(s.content, c)
	if save_ok do c = saved
	if c.chain_id != "" && s.taskchains != nil {
		if chain, chain_ok, _ := iface.taskchain_get_chain(s.taskchains, domain.Task_Chain_ID(c.chain_id)); chain_ok {
			chain.last_activity_at = now
			chain.updated_at = now
			iface.taskchain_save_chain(s.taskchains, chain)
		}
	}

	// 2) Evaluate the nudge gate.
	has_exchange := conversation_has_user_agent_exchange(s, c)
	now_ms, _ := platform_rfc3339_to_unix_ms(now)
	last_activity_ms, _ := platform_rfc3339_to_unix_ms(c.last_activity_at)
	last_nudge_ms, _ := platform_rfc3339_to_unix_ms(c.last_title_nudge_at)
	decision := evaluate_title_nudge(c.title_source, has_exchange, last_activity_ms, last_nudge_ms, now_ms, s.title_nudge_cooldown_seconds)
	if !decision.should_nudge do return

	// 3) Deliver ONE nudge and stamp last_title_nudge_at on conversation + chain.
	deliver_title_nudge(s, c)
	c.last_title_nudge_at = now
	c.updated_at = now
	iface.content_save_conversation(s.content, c)
	if c.chain_id != "" && s.taskchains != nil {
		if chain, chain_ok, _ := iface.taskchain_get_chain(s.taskchains, domain.Task_Chain_ID(c.chain_id)); chain_ok {
			chain.last_title_nudge_at = now
			chain.updated_at = now
			iface.taskchain_save_chain(s.taskchains, chain)
		}
	}
}

// deliver_title_nudge sends a single title-nudge runtime command to the owning/
// coordinator agent's bridge, reusing the existing gated-notification path (same
// bridge_command_send_runtime used by notify_agent_message). The agent is expected
// to respond by calling the T3 set-title verbs.
deliver_title_nudge :: proc(s: ^Content_Service, c: domain.Chat_Conversation) {
	if s == nil || s.agents == nil || s.bridge_command_sink.send_runtime_command == nil do return
	if c.agent_instance_id == "" do return
	inst, ok, _ := iface.agent_get_instance(s.agents, c.agent_instance_id)
	if !ok || inst.bridge_id == "" do return
	command_id := platform.generate_id(s.ids, "cmd_")
	message := "Please set a short, human-meaningful title for this conversation and its task chain (use 'ham-ctl agent conversation set-title' and 'ham-ctl agent chain set-title')."
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"type\":\"notify_title_nudge\",\"command_id\":\"")
	content_json_write(&b, command_id)
	strings.write_string(&b, "\",\"bridge_id\":\"")
	content_json_write(&b, inst.bridge_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	content_json_write(&b, c.agent_instance_id)
	strings.write_string(&b, "\",\"conversation_id\":\"")
	content_json_write(&b, c.conversation_id)
	strings.write_string(&b, "\",\"chain_id\":\"")
	content_json_write(&b, c.chain_id)
	strings.write_string(&b, "\",\"message\":\"")
	content_json_write(&b, message)
	strings.write_string(&b, "\"}")
	_, _ = project_service.bridge_command_send_runtime(s.bridge_command_sink, project_service.Runtime_Command{bridge_id = inst.bridge_id, command_id = command_id, body_json = strings.to_string(b)})
}

// platform_rfc3339_to_unix_ms parses the hub's canonical "YYYY-MM-DDTHH:MM:SSZ"
// UTC timestamp into unix milliseconds. Mirrors the agent-service parser; kept
// local to the content package to avoid a cross-service dependency. Returns
// ok=false for empty/malformed input so callers treat it as "unknown/never".
platform_rfc3339_to_unix_ms :: proc(s: string) -> (i64, bool) {
	t := strings.trim_space(s)
	if len(t) < 19 do return 0, false
	if t[4] != '-' || t[7] != '-' || t[10] != 'T' || t[13] != ':' || t[16] != ':' do return 0, false
	p2 :: proc(str: string) -> (int, bool) {
		if len(str) < 2 do return 0, false
		a := int(str[0]) - '0'; b := int(str[1]) - '0'
		if a < 0 || a > 9 || b < 0 || b > 9 do return 0, false
		return a*10 + b, true
	}
	p4 :: proc(str: string) -> (int, bool) {
		hi, ok1 := p2(str[0:2]); lo, ok2 := p2(str[2:4])
		if !ok1 || !ok2 do return 0, false
		return hi*100 + lo, true
	}
	year, y_ok := p4(t[0:4])
	month, mo_ok := p2(t[5:7])
	day, d_ok := p2(t[8:10])
	hour, h_ok := p2(t[11:13])
	minute, mi_ok := p2(t[14:16])
	second, s_ok := p2(t[17:19])
	if !(y_ok && mo_ok && d_ok && h_ok && mi_ok && s_ok) do return 0, false
	if month < 1 || month > 12 do return 0, false
	days := days_from_civil_content(year, month, day)
	total_secs := i64(days) * 86400 + i64(hour) * 3600 + i64(minute) * 60 + i64(second)
	return total_secs * 1000, true
}

days_from_civil_content :: proc(y_in, m, d: int) -> int {
	y := y_in
	if m <= 2 do y -= 1
	era := (y if y >= 0 else y - 399) / 400
	yoe := y - era * 400
	doy := (153 * (m + (-3 if m > 2 else 9)) + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}
