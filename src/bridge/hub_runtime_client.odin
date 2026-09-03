package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import tmux "odin_test:lib/tmux"
import ws "odin_test:lib/ws"

BRIDGE_WRAPPER_STALE_MS :: 10_000
BRIDGE_START_SUCCESS_TIMEOUT_MS :: 120_000
BRIDGE_START_SUCCESS_PROMPT_AFTER_MS :: 30_000
BRIDGE_START_SUCCESS_PROMPT_INTERVAL_MS :: 60_000
BRIDGE_ACTIVITY_ACTIVE_SOURCE_TTL_MS :: 12_000
BRIDGE_ACTIVITY_IDLE_SOURCE_TTL_MS :: 30_000
BRIDGE_STATE_SEQ_FLOOR_OFFSET_MS :: 3_600_000
// How long an operator stop suppresses wrapper-signal resurrection. Long enough
// to cover a slow wrapper teardown + one or two liveness ticks, short enough that
// a genuine relaunch of the SAME instance id is never blocked (launch clears it).
BRIDGE_STOP_INTENT_TTL_MS :: 15_000

Bridge_Runtime_Instance :: struct {
	agent_instance_id: string,
	state_seq: int,
	runtime_status: string,
	activity_status: string,
	activity_source: string,
	activity_updated_unix_ms: i64,
	last_seen_unix_ms: i64,
	start_deadline_unix_ms: i64,
	start_success_seen: bool,
	last_start_prompt_unix_ms: i64,
	// stopped_intent_unix_ms is set when an operator-requested stop begins. While it
	// is recent (< BRIDGE_STOP_INTENT_TTL_MS) a late wrapper liveness/subscribe
	// signal is IGNORED for status purposes so it cannot resurrect an intentionally
	// stopped instance back to running/starting. A fresh launch clears it.
	stopped_intent_unix_ms: i64,
}

Bridge_Runtime_Command_Result :: struct {
	command_id: string,
	result_json: string,
}

Bridge_Runtime_Launch :: struct {
	agent_instance_id: string,
	command_id: string,
	run_dir: string,
	tmux_session: string,
	tmux_window: string,
	pane_id: string,
	wrapper_token: string,
	agent_token: string,
}

Bridge_Provider_Test :: struct {
	test_id: string,
	provider: string,
	tier: string,
	agent_instance_id: string,
	status: string,
	message: string,
	pane_id: string,
	tmux_session: string,
	tmux_window: string,
	frame_seq: int,
}

Bridge_Pane_Capture_Pending :: struct {
	command_id: string,
	pane_capture_request_id: string,
	conversation_id: string,
	message_id: string,
	agent_instance_id: string,
	width: int,
	line_limit: int,
	deadline_unix_ms: i64,
}

Bridge_Pane_Capture_Outgoing :: struct {
	command_id: string,
	result_json: string,
}

bridge_runtime_mutex: sync.Mutex
bridge_runtime_instances: [dynamic]Bridge_Runtime_Instance
bridge_runtime_results: [dynamic]Bridge_Runtime_Command_Result
bridge_runtime_launches: [dynamic]Bridge_Runtime_Launch
bridge_provider_tests: [dynamic]Bridge_Provider_Test
bridge_pane_capture_pending: [dynamic]Bridge_Pane_Capture_Pending
bridge_pane_capture_outgoing: [dynamic]Bridge_Pane_Capture_Outgoing
bridge_runtime_local_endpoint_started: bool
bridge_runtime_local_endpoint_unix_started: bool
bridge_runtime_local_endpoint_loopback_started: bool
bridge_runtime_local_endpoint_descriptor: string

bridge_hub_runtime_init :: proc() {
	bridge_runtime_mutex = sync.Mutex{}
	bridge_runtime_instances = make([dynamic]Bridge_Runtime_Instance)
	bridge_runtime_results = make([dynamic]Bridge_Runtime_Command_Result)
	bridge_runtime_launches = make([dynamic]Bridge_Runtime_Launch)
	bridge_provider_tests = make([dynamic]Bridge_Provider_Test)
	bridge_pane_capture_pending = make([dynamic]Bridge_Pane_Capture_Pending)
	bridge_pane_capture_outgoing = make([dynamic]Bridge_Pane_Capture_Outgoing)
}

bridge_hub_runtime_worker :: proc() {
	if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(bridge_config.bridge_token) == "" {
		fmt.println("bridge hub runtime disabled: missing daemon_url or bridge_token (has the bridge enrolled? check the bridge_token/--bridge-token-file)")
		return
	}
	// Only log each distinct failure the FIRST time (and periodically) so a down
	// proxy/tunnel doesn't spam the log every 500ms, but the operator still sees
	// exactly which step is failing.
	last_failure := ""
	attempts := 0
	log_failure :: proc(last: ^string, count: ^int, msg: string) {
		count^ += 1
		if msg != last^ || count^ % 20 == 1 {
			fmt.printfln("bridge hub runtime: %s (attempt %d)", msg, count^)
			last^ = msg
		}
	}
	for {
		ws_url := bridge_hub_ws_url(bridge_config.daemon_url)
		if ws_url == "" {
			fmt.println("bridge hub runtime disabled: daemon_url must be an http:// or https:// base URL")
			return
		}
		conn, ok := ws.connect_with_bearer(ws_url, bridge_config.bridge_token)
		if !ok {
			log_failure(&last_failure, &attempts, fmt.tprintf("cannot connect WS %s — proxy/tunnel down, hub unreachable, or TLS failed", ws_url))
			time.sleep(500 * time.Millisecond)
			continue
		}
		hello := bridge_hub_hello_json()
		if !ws.send_text(&conn, hello) {
			log_failure(&last_failure, &attempts, "WS connected but sending hello failed (connection dropped immediately)")
			ws.close(&conn)
			time.sleep(500 * time.Millisecond)
			continue
		}
		ready_deadline := time.to_unix_nanoseconds(time.now()) + i64(5 * time.Second)
		ready := false
		got_error := false
		for time.to_unix_nanoseconds(time.now()) < ready_deadline {
			if text, got := ws.poll_text(&conn); got {
				if extract_json_string(text, "type", "") == "bridge_ready" { ready = true; break }
				if extract_json_string(text, "type", "") == "bridge_error" { got_error = true; break }
			}
			time.sleep(25 * time.Millisecond)
		}
		if ready {
			fmt.println("bridge hub runtime ready")
			last_failure = ""; attempts = 0
			bridge_hub_runtime_loop(&conn)
			fmt.println("bridge hub runtime: connection closed, reconnecting…")
		} else if got_error {
			log_failure(&last_failure, &attempts, "hub sent bridge_error after hello — token rejected or bridge not recognized (re-enroll?)")
		} else {
			log_failure(&last_failure, &attempts, "no bridge_ready within 5s after hello — hub didn't accept the session (slow link over the tunnel, or hub-side rejection)")
		}
		ws.close(&conn)
		time.sleep(500 * time.Millisecond)
	}
}

bridge_hub_runtime_loop :: proc(conn: ^ws.Connection) {
	last_heartbeat := time.to_unix_nanoseconds(time.now())
	for conn.connected {
		if text, got := ws.poll_text(conn); got do bridge_hub_handle_command(conn, text)
		bridge_pane_capture_expire_pending()
		bridge_pane_capture_drain_outgoing(conn)
		now := time.to_unix_nanoseconds(time.now())
		if now - last_heartbeat >= i64(2 * time.Second) {
			_ = ws.send_text(conn, bridge_hub_heartbeat_json())
			last_heartbeat = now
		}
		time.sleep(25 * time.Millisecond)
	}
}

Bridge_Nudge_Record :: struct {
	key: string,
	timestamp_ms: i64,
}
bridge_recent_nudges: [dynamic]Bridge_Nudge_Record
bridge_recent_nudges_mutex: sync.Mutex

bridge_should_debounce_nudge :: proc(instance_id, task_id: string) -> bool {
	if instance_id == "" || task_id == "" do return false
	key := strings.concatenate({instance_id, ":", task_id})
	defer delete(key)
	now := time.now()
	now_ms := time.to_unix_nanoseconds(now) / 1_000_000

	sync.mutex_lock(&bridge_recent_nudges_mutex)
	defer sync.mutex_unlock(&bridge_recent_nudges_mutex)

	i := 0
	for i < len(bridge_recent_nudges) {
		if now_ms - bridge_recent_nudges[i].timestamp_ms > 3000 {
			delete(bridge_recent_nudges[i].key)
			unordered_remove(&bridge_recent_nudges, i)
		} else {
			i += 1
		}
	}

	for rec in bridge_recent_nudges {
		if rec.key == key && (now_ms - rec.timestamp_ms < 1500) {
			return true
		}
	}

	append(&bridge_recent_nudges, Bridge_Nudge_Record{key = strings.clone(key), timestamp_ms = now_ms})
	return false
}

bridge_hub_handle_command :: proc(conn: ^ws.Connection, text: string) {
	type := extract_json_string(text, "type", "")
	if type == "bridge_heartbeat_ack" {
		// H7 cross-bridge reap: the hub tells us which of the instances we reported
		// active have actually been relaunched on ANOTHER bridge. We hold a stale old
		// runtime for each, so invalidate its local tokens: the old ham-wrapper then
		// fails its next wrapper.liveness.ping and self-terminates. Transport/host
		// independent — no tmux/PID reaping needed.
		superseded, _ := bridge_provider_json_extract_string_array(text, "superseded_instance_ids")
		for id in superseded {
			if strings.trim_space(id) == "" do continue
			n := bridge_agent_token_invalidate_instance(id)
			if n > 0 {
				fmt.println("bridge reap: instance relaunched on another bridge; invalidated local tokens", id, "count", n)
				bridge_runtime_set_status(id, "stopped", "idle")
				bridge_runtime_remove_launch(id)
			}
		}
		schedules_version := extract_json_int(text, "schedules_version", 0)
		bridge_action_scheduler_notify_version(schedules_version)
		return
	}
	if type == "launch_agent" {
		fmt.println("bridge hub runtime command launch_agent")
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return }
		accepted := bridge_command_result_json(command_id, "accepted", "")
		bridge_runtime_cache_command(command_id, accepted)
		_ = ws.send_text(conn, accepted)
		ok, detail := bridge_runtime_launch_agent(command_id, text)
		instance_id := extract_json_string(text, "agent_instance_id", "")
		_ = ws.send_text(conn, bridge_instance_status_json(instance_id))
		final_status := "succeeded" if ok else "failed"
		final_runtime := "starting" if ok else "failed"
		final := bridge_command_result_json(command_id, final_status, final_runtime)
		if !ok do fmt.println("bridge launch_agent failed", detail)
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, final)
		return
	}
	if type == "stop_agent" {
		fmt.println("bridge hub runtime command stop_agent")
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return }
		accepted := bridge_command_result_json(command_id, "accepted", "")
		bridge_runtime_cache_command(command_id, accepted)
		_ = ws.send_text(conn, accepted)
		instance_id := extract_json_string(text, "agent_instance_id", "")
		ok := bridge_runtime_stop_agent(instance_id)
		_ = ws.send_text(conn, bridge_instance_status_json(instance_id))
		final := bridge_command_result_json(command_id, "succeeded" if ok else "failed", "stopped" if ok else "failed")
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, final)
		return
	}
	if type == "notify_agent_message" {
		command_id := extract_json_string(text, "command_id", "")
		instance_id := extract_json_string(text, "agent_instance_id", "")
		ok := bridge_wrapper_push(instance_id, text)
		if !ok do fmt.println("bridge notification pending/no-wrapper-subscription", instance_id, command_id)
		if command_id != "" do _ = ws.send_text(conn, bridge_command_result_json(command_id, "succeeded" if ok else "accepted", ""))
		return
	}
	if type == "notify_task_nudge" {
		command_id := extract_json_string(text, "command_id", "")
		instance_id := extract_json_string(text, "agent_instance_id", "")
		task_id := extract_json_string(text, "task_id", "")
		if bridge_should_debounce_nudge(instance_id, task_id) {
			if command_id != "" do _ = ws.send_text(conn, bridge_command_result_json(command_id, "succeeded", ""))
			return
		}
		ok := bridge_wrapper_push_task_nudge(instance_id, text)
		if !ok {
			// Wrapper not connected: wake the local agent (coalesced) so it picks up
			// the task/comment on boot, matching the status-change notify behavior.
			// This is what makes a comment actually reach an idle/stopped assignee.
			if bridge_task_status_notify_wake_local(instance_id) {
				ok = true
			} else {
				fmt.println("bridge notify_task_nudge pending/no-wrapper-subscription", instance_id, command_id)
			}
		}
		if command_id != "" do _ = ws.send_text(conn, bridge_command_result_json(command_id, "succeeded" if ok else "accepted", ""))
		return
	}
	if type == "notify_title_nudge" {
		// Activity-gated title-nudge (REQ-4,5,6). Delivered over the SAME gated
		// path as notify_task_nudge: push to a live wrapper, else wake the local
		// agent so it picks up the nudge on boot. Never a new notifier.
		command_id := extract_json_string(text, "command_id", "")
		instance_id := extract_json_string(text, "agent_instance_id", "")
		ok := bridge_wrapper_push_title_nudge(instance_id, text)
		if !ok {
			if bridge_task_status_notify_wake_local(instance_id) {
				ok = true
			} else {
				fmt.println("bridge notify_title_nudge pending/no-wrapper-subscription", instance_id, command_id)
			}
		}
		if command_id != "" do _ = ws.send_text(conn, bridge_command_result_json(command_id, "succeeded" if ok else "accepted", ""))
		return
	}
	if type == "task_status_changed_notify" {
		command_id := extract_json_string(text, "command_id", "")
		task_id := extract_json_string(text, "task_id", "")
		new_status := extract_json_string(text, "new_status", "")
		actor_agent_instance_id := extract_json_string(text, "actor_agent_instance_id", "")
		mutation_id := extract_json_string(text, "mutation_id", "")

		assignees_arr, _ := bridge_provider_json_extract_array(text, "assignee_instance_ids")
		assignees := bridge_provider_json_parse_string_array(assignees_arr)
		defer delete(assignees)
		
		reviewers_arr, _ := bridge_provider_json_extract_array(text, "reviewer_instance_ids")
		reviewers := bridge_provider_json_parse_string_array(reviewers_arr)
		defer delete(reviewers)
		
		def_reviewers_arr, _ := bridge_provider_json_extract_array(text, "default_reviewer_instance_ids")
		def_reviewers := bridge_provider_json_parse_string_array(def_reviewers_arr)
		defer delete(def_reviewers)
		
		targets := make([dynamic]string)
		defer delete(targets)

		if new_status == "in_progress" {
			for inst in assignees {
				if inst != actor_agent_instance_id do append(&targets, inst)
			}
		} else if new_status == "in_validation" {
			if len(reviewers) == 0 {
				for inst in def_reviewers {
					if inst != actor_agent_instance_id do append(&targets, inst)
				}
			} else {
				for inst in reviewers {
					if inst != actor_agent_instance_id do append(&targets, inst)
				}
			}
		} else if new_status == "validated_not_good" {
			is_reviewer := false
			for inst in reviewers {
				if inst == actor_agent_instance_id { is_reviewer = true; break }
			}
			if !is_reviewer && len(reviewers) == 0 {
				for inst in def_reviewers {
					if inst == actor_agent_instance_id { is_reviewer = true; break }
				}
			}
			if is_reviewer {
				for inst in assignees do append(&targets, inst)
			}
		}

		delivered := 0
		failed := 0
		if len(targets) > 0 {
			message := strings.concatenate({"Task ", task_id, " is now ", new_status})
			defer delete(message)
			payload_b := strings.builder_make()
			defer strings.builder_destroy(&payload_b)
			strings.write_string(&payload_b, "{\"type\":\"notify_task_nudge\",\"command_id\":\"")
			bridge_runtime_write_json_string(&payload_b, command_id)
			strings.write_string(&payload_b, "\",\"mutation_id\":\"")
			bridge_runtime_write_json_string(&payload_b, mutation_id)
			strings.write_string(&payload_b, "\",\"task_id\":\"")
			bridge_runtime_write_json_string(&payload_b, task_id)
			strings.write_string(&payload_b, "\",\"new_status\":\"")
			bridge_runtime_write_json_string(&payload_b, new_status)
			strings.write_string(&payload_b, "\",\"message\":\"")
			bridge_runtime_write_json_string(&payload_b, message)
			strings.write_string(&payload_b, "\"}")
			
			payload_str := strings.to_string(payload_b)
			
			for inst in targets {
				// Cross-bridge cascade: a status change on another bridge (e.g. an
				// upstream task completing) can promote a downstream task whose target
				// lives here. Push to the live wrapper if connected; otherwise wake the
				// local agent (coalesced) so it can pick up the work on boot. Targets
				// that are not local to this bridge are ignored (another bridge owns them).
				if bridge_wrapper_push_task_nudge(inst, payload_str) {
					delivered += 1
					continue
				}
				if bridge_task_status_notify_wake_local(inst) {
					delivered += 1
					fmt.println("bridge task_status_changed_notify woke local target", inst, command_id)
				} else {
					failed += 1
					fmt.println("bridge task_status_changed_notify target not local or wake failed", inst, command_id)
				}
			}
		}
		
		if command_id != "" {
			if delivered > 0 || len(targets) == 0 {
				_ = ws.send_text(conn, bridge_command_result_json(command_id, "succeeded", ""))
			} else if failed > 0 {
				_ = ws.send_text(conn, bridge_command_result_json(command_id, "failed", ""))
			} else {
				_ = ws.send_text(conn, bridge_command_result_json(command_id, "accepted", ""))
			}
		}
		return
	}
	if type == "capture_agent_pane" {
		bridge_hub_handle_pane_capture_command(conn, text)
		return
	}
	if bridge_fs_handle_command(conn, type, text) do return
	if bridge_hub_handle_provider_command(conn, type, text) do return
}

bridge_hub_handle_pane_capture_command :: proc(conn: ^ws.Connection, text: string) {
	command_id := extract_json_string(text, "command_id", "")
	if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return }
	if extract_json_int(text, "protocol_version", 0) != 1 {
		failed := bridge_command_result_payload_json(command_id, "failed", "{\"error_code\":\"unsupported_capture_agent_pane\"}")
		bridge_runtime_cache_command(command_id, failed)
		_ = ws.send_text(conn, failed)
		return
	}
	instance_id := extract_json_string(text, "agent_instance_id", "")
	pending := Bridge_Pane_Capture_Pending{command_id=strings.clone(command_id),pane_capture_request_id=strings.clone(extract_json_string(text,"pane_capture_request_id","")),conversation_id=strings.clone(extract_json_string(text,"conversation_id","")),message_id=strings.clone(extract_json_string(text,"message_id","")),agent_instance_id=strings.clone(instance_id),width=bridge_runtime_provider_test_int(text,"width",80,40,200),line_limit=bridge_runtime_provider_test_int(text,"line_limit",120,20,300),deadline_unix_ms=bridge_runtime_now_ms()+i64(bridge_runtime_provider_test_int(text,"settle_ms",3000,500,10000)+30000)}
	bridge_pane_capture_register_pending(pending)
	accepted := bridge_command_result_json(command_id, "accepted", "")
	bridge_runtime_cache_command(command_id, accepted)
	_ = ws.send_text(conn, accepted)
	push := bridge_pane_capture_push_json(pending, bridge_runtime_provider_test_int(text,"settle_ms",3000,500,10000))
	if !bridge_wrapper_push_line(instance_id, push) {
		bridge_pane_capture_remove_pending(command_id, pending.pane_capture_request_id)
		result := bridge_pane_capture_result_json(pending,false,"wrapper_unavailable","The agent wrapper is not connected.","",0,false)
		bridge_runtime_cache_command(command_id, bridge_command_result_payload_json(command_id,"failed","{\"error_code\":\"wrapper_unavailable\"}"))
		_ = ws.send_text(conn, result)
	}
}

bridge_hub_handle_provider_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	switch type {
	case "list_providers":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		result := bridge_provider_profiles_report_json(bridge_config.daemon_id)
		report := bridge_providers_report_json(command_id, result)
		bridge_runtime_cache_command(command_id, report)
		_ = ws.send_text(conn, report)
		_ = ws.send_text(conn, bridge_command_result_payload_json(command_id, "succeeded", "{}"))
		return true
	case "upsert_provider":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		payload := bridge_provider_payload_object(text)
		name := bridge_provider_json_extract_string(payload, "name", "")
		profile_json, profile_ok := bridge_provider_json_extract_object(payload, "profile")
		if !profile_ok do profile_json = "{}"
		profile, ok, message := bridge_provider_upsert_override_json(name, profile_json)
		result_b := strings.builder_make()
		if ok { strings.write_string(&result_b, "{\"provider\":"); bridge_provider_write_profile_json(&result_b, profile); strings.write_byte(&result_b, '}') } else { strings.write_string(&result_b, "{\"error\":\""); bridge_runtime_write_json_string(&result_b, message); strings.write_string(&result_b, "\"}") }
		final := bridge_command_result_payload_json(command_id, "succeeded" if ok else "failed", strings.to_string(result_b))
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, final)
		return true
	case "delete_provider":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		payload := bridge_provider_payload_object(text)
		name := bridge_provider_json_extract_string(payload, "name", "")
		deleted, message := bridge_provider_delete_override(name)
		result := "{\"deleted\":true}" if deleted else strings.concatenate({"{\"deleted\":false,\"error\":\"", bridge_runtime_json_escaped(message), "\"}"})
		final := bridge_command_result_payload_json(command_id, "succeeded" if deleted else "failed", result)
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, final)
		return true
	case "set_provider_defaults":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		payload := bridge_provider_payload_object(text)
		provider := bridge_provider_json_extract_string(payload, "provider", "")
		tier := bridge_provider_json_extract_string(payload, "tier", "")
		ok, message := bridge_provider_set_defaults(provider, tier)
		result := strings.concatenate({"{\"default_provider\":\"", bridge_runtime_json_escaped(bridge_default_provider_name()), "\",\"default_tier\":\"", bridge_runtime_json_escaped(tier), "\"}"})
		if !ok do result = strings.concatenate({"{\"error\":\"", bridge_runtime_json_escaped(message), "\"}"})
		final := bridge_command_result_payload_json(command_id, "succeeded" if ok else "failed", result)
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, strings.concatenate({"{\"type\":\"capability_report\",\"protocol_version\":1,\"capabilities\":", bridge_provider_capabilities_json(), "}"}))
		_ = ws.send_text(conn, final)
		return true
	case "test_provider":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		result := bridge_runtime_run_provider_test(conn, command_id, text)
		final := bridge_command_result_payload_json(command_id, "succeeded", result)
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, final)
		return true
	case "refresh_capabilities":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		result := strings.concatenate({"{\"capabilities\":", bridge_provider_capabilities_json(), "}"})
		final := bridge_command_result_payload_json(command_id, "succeeded", result)
		bridge_runtime_cache_command(command_id, final)
		_ = ws.send_text(conn, strings.concatenate({"{\"type\":\"capability_report\",\"protocol_version\":1,\"capabilities\":", bridge_provider_capabilities_json(), "}"}))
		_ = ws.send_text(conn, final)
		return true
	}
	return false
}

bridge_runtime_launch_agent :: proc(command_id, command_json: string) -> (bool, string) {
	instance_id := extract_json_string(command_json, "agent_instance_id", "")
	if strings.trim_space(instance_id) == "" do return false, "missing agent_instance_id"
	// A genuine (re)launch supersedes any prior stop intent for this instance id.
	bridge_runtime_clear_stop_intent(instance_id)
	if existing, ok := bridge_runtime_get_launch(instance_id); ok {
		_ = tmux.kill_window(existing.tmux_session, existing.tmux_window)
	}
	// The bridge runtime registry is in-memory and can be empty after bridge restart.
	// Kill any exact stale tmux windows before creating the new ham-wrapper pane.
	stale_session := bridge_runtime_tmux_session()
	stale_window := bridge_runtime_tmux_window(instance_id)
	for tmux.kill_window(stale_session, stale_window) {}
	// Agents always run in their own managed run dir (never the project path).
	// The project path/description is provided to the agent via AGENTS.md instead,
	// so the agent decides when/how to work against the project checkout.
	run_dir := bridge_runtime_default_run_dir(instance_id)
	// The bridge creates the EMPTY run dir (tmux `cd`s into it to launch the
	// wrapper) but writes NO bootstrap files there — the wrapper is the sole writer
	// of run_dir contents (WRP-1). This keeps the e2e test honest.
	_ = os.make_directory_all(run_dir)
	endpoint, endpoint_ok := bridge_runtime_ensure_local_endpoint()
	if !endpoint_ok do return false, "local endpoint unavailable"
	bridge_runtime_set_status(instance_id, "starting", "active")
	// H7 restart-reap: invalidate ANY prior local tokens for this instance BEFORE
	// issuing fresh ones. A superseded old ham-wrapper will then fail its next
	// wrapper.liveness.ping (its token is no longer valid) and self-terminate,
	// regardless of tmux window/host/bridge. The freshly issued wrapper+agent
	// tokens below are non-deterministic (hlat_<nanos>_<seq>), so the new runtime
	// is cryptographically distinct from the old one.
	invalidated := bridge_agent_token_invalidate_instance(instance_id)
	if invalidated > 0 do fmt.println("bridge launch: invalidated prior local tokens for instance", instance_id, "count", invalidated)
	instance_token := strings.concatenate({"hit_", instance_id})
	wrapper_issue := bridge_agent_token_issue(instance_id, instance_token, .Wrapper)
	agent_issue := bridge_agent_token_issue(instance_id, instance_token, .Agent)
	provider, tier := bridge_runtime_provider_tier(command_json)
	// Conditional, per-hash bootstrap (BRG-1..BRG-4): build the per-instance
	// descriptor from the enriched launch payload, run one conditional manifest GET
	// + per-hash blob fetches (only what is missing from disk), then ASSEMBLE +
	// PUBLISH the finished file set for the wrapper RPCs. The bridge does NOT write
	// the run_dir — the wrapper materializes it via bootstrap.list/.file (WRP-1).
	// A staged failure surfaces the stage + HTTP status instead of a generic string.
	descriptor := bridge_bootstrap_descriptor_from_launch(command_json)
	if strings.trim_space(descriptor.provider) == "" do descriptor.provider = provider
	boot_res := bridge_bootstrap_launch_materialize(bridge_config.daemon_url, bridge_config.bridge_token, run_dir, endpoint, agent_issue.plaintext_token, descriptor, &bootstrap_global_cache)
	if !boot_res.ok {
		bridge_runtime_set_status(instance_id, "failed", "idle")
		detail := fmt.tprintf("bootstrap failed at stage=%s http_status=%d: %s", boot_res.stage, boot_res.http_status, boot_res.detail)
		fmt.println("bridge launch_agent bootstrap failed", "instance=", instance_id, "stage=", boot_res.stage, "http_status=", boot_res.http_status, "detail=", boot_res.detail)
		return false, detail
	}
	session := bridge_runtime_tmux_session()
	window := bridge_runtime_tmux_window(instance_id)
	wrapper_args, wrapper_args_ok := bridge_runtime_ham_wrapper_argv(endpoint, wrapper_issue.plaintext_token, agent_issue.plaintext_token, instance_id, run_dir, provider, tier)
	if !wrapper_args_ok {
		bridge_runtime_set_status(instance_id, "failed", "idle")
		return false, "provider has no runnable command"
	}
	launch, launch_ok := tmux.ensure_agent_window(session, window, run_dir, wrapper_args)
	if !launch_ok || strings.trim_space(launch.pane_id) == "" {
		bridge_runtime_set_status(instance_id, "failed", "idle")
		return false, "ham-wrapper tmux launch failed"
	}
	bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_instance_id = strings.clone(instance_id), command_id = strings.clone(command_id), run_dir = strings.clone(run_dir), tmux_session = strings.clone(session), tmux_window = strings.clone(window), pane_id = strings.clone(launch.pane_id), wrapper_token = strings.clone(wrapper_issue.plaintext_token), agent_token = strings.clone(agent_issue.plaintext_token)})
	return true, ""
}

// bridge_runtime_stop_agent stops a running agent by INVALIDATING its local token
// only — ZERO tmux involvement. The bridge never runs kill/pane commands. Instead
// it relies on the wrapper's H7 self-reap: the ham-wrapper pings the bridge every
// ~1s (wrapper.liveness.ping); once the token is invalid the bridge answers with
// an auth failure, and the wrapper kills its own child agent and exits within ~1s
// (src/wrapper/bridge_runtime.odin). Because the local-token store is persisted to
// disk on invalidate (agent_token_store.odin -> local-tokens.jsonl), this survives
// a bridge restart: after relaunch the reissued/invalid token still makes the
// superseded wrapper self-terminate, with no in-memory launch record needed. A
// stopped agent then sends no further heartbeats, so heartbeat presence is the
// source of truth for runtime_status.
bridge_runtime_stop_agent :: proc(instance_id: string) -> bool {
	if strings.trim_space(instance_id) == "" do return false
	// Record the operator's intent to stop, so a late/duplicate wrapper signal that
	// races the ~1s self-reap window cannot resurrect the instance back to
	// running/starting (see bridge_runtime_note_activity_signal).
	bridge_runtime_mark_stop_intent(instance_id)
	bridge_runtime_set_status(instance_id, "stopping", "idle")
	// Invalidate every local token for this instance (persisted to disk). The
	// wrapper self-reaps on its next liveness ping; the bridge does nothing else.
	invalidated := bridge_agent_token_invalidate_instance(instance_id)
	if invalidated > 0 do fmt.println("bridge stop: invalidated local tokens for instance", instance_id, "count", invalidated, "(wrapper will self-reap)")
	// Drop any in-memory launch record so we don't hold stale pane/token data.
	bridge_runtime_remove_launch(instance_id)
	bridge_runtime_set_status(instance_id, "stopped", "idle")
	return true
}

bridge_runtime_run_provider_test :: proc(conn: ^ws.Connection, command_id, command_json: string) -> string {
	payload := bridge_provider_payload_object(command_json)
	provider := bridge_provider_json_extract_string(payload, "name", "")
	requested_tier := bridge_provider_json_extract_string(payload, "tier", "")
	if strings.trim_space(requested_tier) != "" do return bridge_runtime_run_provider_test_single(conn, command_id, command_json)
	profile, profile_ok := bridge_provider_by_name_or_default(provider)
	if !profile_ok || !profile.enabled || len(profile.command) == 0 {
		msg := "provider has no runnable command"
		return bridge_provider_test_result_json("", provider, "failed", msg, "")
	}
	tiers := bridge_provider_configured_test_tiers(profile)
	if len(tiers) == 0 {
		msg := "provider has no configured model tiers"
		return bridge_provider_test_result_json("", provider, "failed", msg, "")
	}
	base_test_id := bridge_provider_json_extract_string(payload, "test_id", "")
	if base_test_id == "" do base_test_id = fmt.tprintf("ptest_%d", time.to_unix_nanoseconds(time.now()))
	b := strings.builder_make()
	strings.write_string(&b, "{\"test_id\":\""); bridge_runtime_write_json_string(&b, base_test_id)
	strings.write_string(&b, "\",\"name\":\""); bridge_runtime_write_json_string(&b, provider)
	strings.write_string(&b, "\",\"provider\":\""); bridge_runtime_write_json_string(&b, provider)
	strings.write_string(&b, "\",\"status\":\"")
	all_passed := true
	results := make([dynamic]string)
	for tier, idx in tiers {
		tier_command := bridge_provider_test_command_with_tier(command_json, base_test_id, tier, idx)
		result := bridge_runtime_run_provider_test_single(conn, command_id, tier_command)
		append(&results, result)
		status := bridge_provider_json_extract_string(result, "status", "failed")
		if status != "passed" && status != "ok" do all_passed = false
	}
	strings.write_string(&b, "passed" if all_passed else "failed")
	strings.write_string(&b, "\",\"tested_at\":\""); strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now())))
	strings.write_string(&b, "\",\"message\":\""); bridge_runtime_write_json_string(&b, "tested every configured tier" if all_passed else "one or more configured tiers failed")
	strings.write_string(&b, "\",\"tiers\":[")
	for result, idx in results {
		if idx > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, result)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

bridge_provider_configured_test_tiers :: proc(profile: Bridge_Provider_Profile) -> []string {
	out := make([dynamic]string)
	if strings.trim_space(profile.models.cheap) != "" do append(&out, "cheap")
	if strings.trim_space(profile.models.normal) != "" do append(&out, "normal")
	if strings.trim_space(profile.models.smart) != "" do append(&out, "smart")
	return out[:]
}

bridge_provider_test_command_with_tier :: proc(command_json, base_test_id, tier: string, index: int) -> string {
	payload := bridge_provider_payload_object(command_json)
	provider := bridge_provider_json_extract_string(payload, "name", "")
	capture_frames := strings.contains(payload, "\"capture_frames\":true")
	launch_deadline_ms := bridge_runtime_provider_test_int(payload, "launch_deadline_ms", 20000, 1000, 300000)
	start_success_deadline_ms := bridge_runtime_provider_test_int(payload, "start_success_deadline_ms", 60000, 1000, 300000)
	hard_deadline_ms := bridge_runtime_provider_test_int(payload, "hard_deadline_ms", 90000, start_success_deadline_ms, 300000)
	frame_interval_ms := bridge_runtime_provider_test_int(payload, "frame_interval_ms", 500, 200, 5000)
	test_id := strings.concatenate({base_test_id, "_", tier})
	instance_id := strings.concatenate({"inst_", test_id})
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"test_provider\",\"protocol_version\":1,\"command_id\":\""); bridge_runtime_write_json_string(&b, strings.concatenate({base_test_id, "_", fmt.tprintf("%d", index)}))
	strings.write_string(&b, "\",\"payload\":{\"name\":\""); bridge_runtime_write_json_string(&b, provider)
	strings.write_string(&b, "\",\"tier\":\""); bridge_runtime_write_json_string(&b, tier)
	strings.write_string(&b, "\",\"test_id\":\""); bridge_runtime_write_json_string(&b, test_id)
	strings.write_string(&b, "\",\"test_instance_id\":\""); bridge_runtime_write_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"capture_frames\":"); strings.write_string(&b, "true" if capture_frames else "false")
	strings.write_string(&b, ",\"launch_deadline_ms\":"); strings.write_string(&b, fmt.tprintf("%d", launch_deadline_ms))
	strings.write_string(&b, ",\"start_success_deadline_ms\":"); strings.write_string(&b, fmt.tprintf("%d", start_success_deadline_ms))
	strings.write_string(&b, ",\"hard_deadline_ms\":"); strings.write_string(&b, fmt.tprintf("%d", hard_deadline_ms))
	strings.write_string(&b, ",\"frame_interval_ms\":"); strings.write_string(&b, fmt.tprintf("%d", frame_interval_ms))
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

bridge_runtime_run_provider_test_single :: proc(conn: ^ws.Connection, command_id, command_json: string) -> string {
	payload := bridge_provider_payload_object(command_json)
	provider := bridge_provider_json_extract_string(payload, "name", "")
	tier := bridge_provider_json_extract_string(payload, "tier", "")
	test_id := bridge_provider_json_extract_string(payload, "test_id", "")
	if test_id == "" do test_id = fmt.tprintf("ptest_%d", time.to_unix_nanoseconds(time.now()))
	instance_id := bridge_provider_json_extract_string(payload, "test_instance_id", "")
	if instance_id == "" do instance_id = strings.concatenate({"inst_", test_id})
	capture_frames := strings.contains(payload, "\"capture_frames\":true")
	launch_deadline_ms := bridge_runtime_provider_test_int(payload, "launch_deadline_ms", 20000, 1000, 300000)
	start_deadline_ms := bridge_runtime_provider_test_int(payload, "start_success_deadline_ms", 60000, 1000, 300000)
	hard_deadline_ms := bridge_runtime_provider_test_int(payload, "hard_deadline_ms", 90000, start_deadline_ms, 300000)
	frame_interval_ms := bridge_runtime_provider_test_int(payload, "frame_interval_ms", 500, 200, 5000)
	if profile, profile_ok := bridge_provider_by_name_or_default(provider); !profile_ok || !profile.enabled || len(profile.command) == 0 {
		msg := "provider has no runnable command"
		_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "failed", "done", msg, ""))
		return bridge_provider_test_result_json_with_tier(test_id, provider, tier, "failed", msg, "")
	}
	endpoint, endpoint_ok := bridge_runtime_ensure_local_endpoint()
	if !endpoint_ok {
		msg := "local endpoint unavailable"
		_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "failed", "done", msg, ""))
		return bridge_provider_test_result_json_with_tier(test_id, provider, tier, "failed", msg, "")
	}
	_ = bridge_provider_test_cancel_provider(provider)
	run_dir := bridge_runtime_default_run_dir(instance_id)
	_ = os.make_directory_all(run_dir)
	instance_token := strings.concatenate({"hit_", instance_id})
	wrapper_issue := bridge_agent_token_issue(instance_id, instance_token, .Wrapper)
	agent_issue := bridge_agent_token_issue(instance_id, instance_token, .Agent)
	if !bridge_bootstrap_materialize_local_provider_test(run_dir, endpoint, agent_issue.plaintext_token, instance_id, provider) {
		msg := "provider test bootstrap materialization failed"
		_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "failed", "done", msg, ""))
		bridge_runtime_set_status(instance_id, "stopped", "idle")
		return bridge_provider_test_result_json_with_tier(test_id, provider, tier, "failed", msg, "")
	}
	session := "heimdall-bridge-test"
	window := strings.concatenate({"ptest-", bridge_runtime_safe_part(test_id)})
	_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "launching", "launching", "launching provider test", ""))
	test_start_ns := time.to_unix_nanoseconds(time.now())
	hard_deadline_abs_ns := test_start_ns + i64(time.Duration(hard_deadline_ms) * time.Millisecond)
	launch_deadline_ns := test_start_ns + i64(time.Duration(launch_deadline_ms) * time.Millisecond)
	if launch_deadline_ns > hard_deadline_abs_ns do launch_deadline_ns = hard_deadline_abs_ns
	wrapper_args, wrapper_args_ok := bridge_runtime_ham_wrapper_argv(endpoint, wrapper_issue.plaintext_token, agent_issue.plaintext_token, instance_id, run_dir, provider, tier)
	if !wrapper_args_ok {
		msg := "provider has no runnable command"
		_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "failed", "done", msg, ""))
		bridge_runtime_set_status(instance_id, "stopped", "idle")
		return bridge_provider_test_result_json_with_tier(test_id, provider, tier, "failed", msg, "")
	}
	launch, launch_ok := tmux.ensure_agent_window(session, window, run_dir, wrapper_args)
	if !launch_ok || strings.trim_space(launch.pane_id) == "" {
		msg := "ham-wrapper tmux launch failed"
		_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "failed", "done", msg, ""))
		_ = tmux.kill_window(session, window)
		bridge_runtime_set_status(instance_id, "stopped", "idle")
		return bridge_provider_test_result_json_with_tier(test_id, provider, tier, "failed", msg, "")
	}
	bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_instance_id = strings.clone(instance_id), command_id = strings.clone(command_id), run_dir = strings.clone(run_dir), tmux_session = strings.clone(session), tmux_window = strings.clone(window), pane_id = strings.clone(launch.pane_id), wrapper_token = strings.clone(wrapper_issue.plaintext_token), agent_token = strings.clone(agent_issue.plaintext_token)})
	startup_seen := false
	startup_failed := false
	startup_message := ""
	pane_id := ""
	last_launch_status_ns := test_start_ns
	for time.to_unix_nanoseconds(time.now()) < launch_deadline_ns {
		now_launch := time.to_unix_nanoseconds(time.now())
		if launch, launch_ok := bridge_runtime_get_launch(instance_id); launch_ok && strings.trim_space(launch.pane_id) != "" do pane_id = launch.pane_id
		if inst, inst_ok := bridge_runtime_instance_snapshot(instance_id); inst_ok {
			if inst.runtime_status == "failed" || inst.runtime_status == "stopped" { startup_failed = true; startup_message = strings.concatenate({"provider process ", inst.runtime_status}); break }
			if pane_id != "" { startup_seen = true; break }
		}
		if now_launch - last_launch_status_ns >= i64(15 * time.Second) {
			_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "launching", "launching", "launching provider test", ""))
			last_launch_status_ns = now_launch
		}
		time.sleep(100 * time.Millisecond)
	}
	if startup_failed || !startup_seen || pane_id == "" {
		msg := startup_message
		if msg == "" do msg = "provider launch deadline exceeded"
		_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "failed", "done", msg, ""))
		_ = tmux.kill_window(session, window)
		bridge_runtime_remove_launch(instance_id)
		bridge_runtime_set_status(instance_id, "stopped", "idle")
		return bridge_provider_test_result_json_with_tier(test_id, provider, tier, "failed", msg, "")
	}
	bridge_provider_test_record(Bridge_Provider_Test{test_id = strings.clone(test_id), provider = strings.clone(provider), tier = strings.clone(tier), agent_instance_id = strings.clone(instance_id), status = "in_progress", message = "awaiting start-success", pane_id = strings.clone(pane_id), tmux_session = strings.clone(session), tmux_window = strings.clone(window)})
	_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "in_progress", "awaiting_start_success", "awaiting start-success", ""))
	start_ns := time.to_unix_nanoseconds(time.now())
	deadline_ns := start_ns + i64(time.Duration(start_deadline_ms) * time.Millisecond)
	if deadline_ns > hard_deadline_abs_ns do deadline_ns = hard_deadline_abs_ns
	hard_deadline_ns := hard_deadline_abs_ns
	last_frame_ns := i64(0)
	last_status_ns := start_ns
	last_frame := ""
	status := "timeout"
	message := "provider did not report start-success before deadline"
	for time.to_unix_nanoseconds(time.now()) < hard_deadline_ns {
		now := time.to_unix_nanoseconds(time.now())
		if test, ok := bridge_provider_test_get(test_id); ok {
			if test.status == "passed" { status = "passed"; message = test.message; break }
			if test.status == "failed" { status = "failed"; message = test.message; break }
		}
		if inst, inst_ok := bridge_runtime_instance_snapshot(instance_id); inst_ok {
			if inst.runtime_status == "failed" || inst.runtime_status == "stopped" { status = "failed"; message = strings.concatenate({"provider process ", inst.runtime_status}); break }
		}
		if now >= deadline_ns { status = "timeout"; break }
		if now - last_status_ns >= i64(15 * time.Second) {
			_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, "in_progress", "awaiting_start_success", "awaiting start-success", ""))
			last_status_ns = now
		}
		if capture_frames && now - last_frame_ns >= i64(time.Duration(frame_interval_ms) * time.Millisecond) {
			if frame, frame_ok := tmux.capture_pane_text(pane_id, 80); frame_ok && frame != last_frame {
				last_frame = frame
				last_frame_ns = now
				_ = ws.send_text(conn, bridge_provider_test_frame_json(test_id, frame))
			}
		}
		time.sleep(100 * time.Millisecond)
	}
	diagnostics, _ := tmux.capture_pane_text(pane_id, 30)
	if status == "passed" do message = "agent booted and reported start-success"
	_ = ws.send_text(conn, bridge_provider_test_status_json(test_id, status, "done", message, diagnostics))
	_ = tmux.kill_window(session, window)
	bridge_runtime_remove_launch(instance_id)
	bridge_runtime_set_status(instance_id, "stopped", "idle")
	bridge_provider_test_remove(test_id)
	return bridge_provider_test_result_json_with_tier(test_id, provider, tier, status, message, diagnostics)
}

bridge_runtime_ensure_local_endpoint :: proc() -> (string, bool) {
	if bridge_config.local_endpoint_port == 0 do bridge_config.local_endpoint_port = 49324
	local_config := bridge_local_endpoint_config_default(bridge_config.local_endpoint_run_dir, bridge_config.local_endpoint_port)
	if !bridge_runtime_local_endpoint_started {
		bridge_runtime_local_endpoint_unix_started = bridge_local_endpoint_start_unix(local_config)
		bridge_runtime_local_endpoint_loopback_started = bridge_local_endpoint_start_loopback(local_config)
		bridge_runtime_local_endpoint_started = bridge_runtime_local_endpoint_unix_started || bridge_runtime_local_endpoint_loopback_started
		if bridge_runtime_local_endpoint_started {
			bridge_runtime_local_endpoint_descriptor = bridge_runtime_select_endpoint(local_config)
		}
	}
	if !bridge_runtime_local_endpoint_started do return "", false
	if bridge_runtime_local_endpoint_descriptor == "" do bridge_runtime_local_endpoint_descriptor = bridge_runtime_select_endpoint(local_config)
	return bridge_runtime_local_endpoint_descriptor, bridge_runtime_local_endpoint_descriptor != ""
}

bridge_runtime_select_endpoint :: proc(local_config: Bridge_Local_Endpoint_Config) -> string {
	// §12.0.2 contract: Unix-domain socket 0600 is primary; loopback TCP is fallback.
	// Only return a descriptor for a transport that actually started listening.
	if bridge_runtime_local_endpoint_unix_started do return bridge_local_endpoint_env_value(local_config, true)
	if bridge_runtime_local_endpoint_loopback_started do return bridge_local_endpoint_env_value(local_config, false)
	return ""
}

bridge_runtime_provider_tier :: proc(command_json: string) -> (string, string) {
	provider := extract_json_string(command_json, "provider", "")
	tier := extract_json_string(command_json, "tier", "")
	if provider == "" || tier == "" {
		payload := bridge_provider_payload_object(command_json)
		if provider == "" do provider = bridge_provider_json_extract_string(payload, "name", "")
		if tier == "" do tier = bridge_provider_json_extract_string(payload, "tier", "")
	}
	return provider, tier
}

bridge_runtime_agent_command :: proc(command_json, agent_token, agent_instance_id: string) -> string {
	if cmd := os.get_env_alloc("HEIMDALL_BRIDGE_AGENT_COMMAND", context.allocator); strings.trim_space(cmd) != "" do return cmd
	provider, tier := bridge_runtime_provider_tier(command_json)
	if profile, ok := bridge_provider_by_name_or_default(provider); ok && profile.enabled && len(profile.command) > 0 {
		return bridge_runtime_shell_command_for_profile(profile, tier, agent_token, agent_instance_id)
	}
	if strings.trim_space(bridge_config.agent_command) != "" do return bridge_config.agent_command
	return "sleep 3600"
}

bridge_runtime_ham_wrapper_argv :: proc(endpoint, wrapper_token, agent_token, instance_id, run_dir, provider, tier: string) -> ([]string, bool) {
	profile, profile_ok := bridge_provider_by_name_or_default(provider)
	if !profile_ok || !profile.enabled || len(profile.command) == 0 do return nil, false
	agent_argv := bridge_runtime_agent_argv_for_profile(profile, tier, agent_token, instance_id)
	out := make([dynamic]string)
	append(&out, bridge_runtime_ham_wrapper_bin(), "bridge-runtime", "--bridge-endpoint", endpoint, "--agent-token", wrapper_token, "--child-agent-token", agent_token, "--agent-instance-id", instance_id, "--run-dir", run_dir)
	if provider != "" do append(&out, "--provider", provider)
	if tier != "" do append(&out, "--tier", tier)
	append(&out, "--")
	append(&out, ..agent_argv)
	return out[:], true
}

bridge_runtime_ham_wrapper_bin :: proc() -> string {
	if v := os.get_env_alloc("HEIMDALL_HAM_WRAPPER_BIN", context.allocator); strings.trim_space(v) != "" do return v
	if found := bridge_runtime_find_on_path("ham-wrapper"); found != "" do return found
	return "ham-wrapper"
}

bridge_runtime_find_on_path :: proc(name: string) -> string {
	path := os.get_env_alloc("PATH", context.allocator)
	start := 0
	for start <= len(path) {
		end_rel := strings.index_byte(path[start:], ':')
		end := len(path)
		if end_rel >= 0 do end = start + end_rel
		dir := path[start:end]
		if strings.trim_space(dir) != "" {
			candidate := strings.concatenate({strings.trim_right(dir, "/"), "/", name})
			if _, err := os.stat(candidate, context.allocator); err == nil {
				if absolute, abs_err := os.get_absolute_path(candidate, context.allocator); abs_err == nil && strings.trim_space(absolute) != "" do return absolute
				return candidate
			}
		}
		if end_rel < 0 do break
		start = end + 1
	}
	return ""
}

bridge_runtime_default_run_dir :: proc(instance_id: string) -> string {
	base := strings.trim_right(bridge_config.local_endpoint_run_dir, "/")
	if base == "" do base = "/tmp/heimdall-bridge-local"
	return strings.concatenate({base, "/instances/", bridge_runtime_safe_part(instance_id)})
}

// bridge_runtime_tmux_session scopes the tmux server per bridge so multiple
// bridges on one host do not share a single tmux daemon. A shared session caused
// two problems: (1) all bridges' agent windows piled into one server, and (2)
// the tmux daemon inherited a bridge's listening sockets, so killing that bridge
// left the daemon holding its ports -> restart failed with Address_In_Use. The
// local_endpoint_port is a reliable per-host discriminator (two bridges cannot
// bind the same port), so we key the session on it.
bridge_runtime_tmux_session :: proc() -> string {
	if bridge_config.local_endpoint_port != 0 {
		return fmt.tprintf("heimdall-bridge-%d", bridge_config.local_endpoint_port)
	}
	return "heimdall-bridge"
}
bridge_runtime_tmux_window :: proc(instance_id: string) -> string { return strings.concatenate({"agent-", bridge_runtime_safe_part(instance_id)}) }

bridge_runtime_safe_part :: proc(value: string) -> string {
	b := strings.builder_make()
	for ch in value {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '@', '.': strings.write_rune(&b, ch)
		case: strings.write_string(&b, "_")
		}
	}
	return strings.to_string(b)
}

bridge_runtime_get_launch :: proc(instance_id: string) -> (Bridge_Runtime_Launch, bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for launch in bridge_runtime_launches { if launch.agent_instance_id == instance_id do return launch, true }
	return {}, false
}

bridge_runtime_record_launch :: proc(launch: Bridge_Runtime_Launch) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_launches) {
		if bridge_runtime_launches[i].agent_instance_id == launch.agent_instance_id { bridge_runtime_launches[i] = launch; return }
	}
	append(&bridge_runtime_launches, launch)
}

bridge_runtime_remove_launch :: proc(instance_id: string) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_launches) {
		if bridge_runtime_launches[i].agent_instance_id == instance_id { unordered_remove(&bridge_runtime_launches, i); return }
	}
}

bridge_runtime_update_launch_pane :: proc(instance_id, pane_id: string) {
	if strings.trim_space(instance_id) == "" || strings.trim_space(pane_id) == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_launches) {
		if bridge_runtime_launches[i].agent_instance_id == instance_id {
			bridge_runtime_launches[i].pane_id = strings.clone(pane_id)
			break
		}
	}
	for i in 0..<len(bridge_provider_tests) {
		if bridge_provider_tests[i].agent_instance_id == instance_id {
			bridge_provider_tests[i].pane_id = strings.clone(pane_id)
		}
	}
}

bridge_provider_test_record :: proc(test: Bridge_Provider_Test) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_provider_tests) {
		if bridge_provider_tests[i].test_id == test.test_id { bridge_provider_tests[i] = test; return }
	}
	append(&bridge_provider_tests, test)
}

bridge_provider_test_get :: proc(test_id: string) -> (Bridge_Provider_Test, bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for test in bridge_provider_tests { if test.test_id == test_id do return test, true }
	return {}, false
}

bridge_provider_test_remove :: proc(test_id: string) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_provider_tests) { if bridge_provider_tests[i].test_id == test_id { unordered_remove(&bridge_provider_tests, i); return } }
}

bridge_provider_test_mark_start_success :: proc(instance_id: string) -> bool {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_provider_tests) {
		if bridge_provider_tests[i].agent_instance_id == instance_id {
			bridge_provider_tests[i].status = "passed"
			bridge_provider_tests[i].message = "agent reported start-success"
			return true
		}
	}
	return false
}

bridge_provider_test_cancel_provider :: proc(provider: string) -> bool {
	sync.mutex_lock(&bridge_runtime_mutex)
	to_kill_session := ""
	to_kill_window := ""
	to_remove_test := ""
	to_remove_instance := ""
	for i in 0..<len(bridge_provider_tests) {
		if bridge_provider_tests[i].provider == provider {
			to_kill_session = bridge_provider_tests[i].tmux_session
			to_kill_window = bridge_provider_tests[i].tmux_window
			to_remove_test = bridge_provider_tests[i].test_id
			to_remove_instance = bridge_provider_tests[i].agent_instance_id
			break
		}
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	if to_kill_session != "" && to_kill_window != "" do _ = tmux.kill_window(to_kill_session, to_kill_window)
	if to_remove_instance != "" do bridge_runtime_remove_launch(to_remove_instance)
	if to_remove_test != "" do bridge_provider_test_remove(to_remove_test)
	return to_remove_test != ""
}

bridge_runtime_now_ms :: proc() -> i64 {
	return bridge_now_unix_ms()
}

bridge_runtime_set_status :: proc(instance_id, runtime_status, activity_status: string) {
	if strings.trim_space(instance_id) == "" do return
	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_runtime_set_status_locked(instance_id, runtime_status, activity_status, now, true)
}

bridge_runtime_note_wrapper_signal :: proc(instance_id, activity_status: string) {
	bridge_runtime_note_activity_signal(instance_id, activity_status, "wrapper")
}

bridge_runtime_note_agent_activity :: proc(instance_id, activity_status, activity_source: string) {
	source := strings.trim_space(activity_source)
	if source == "" do source = "agent_extension"
	bridge_runtime_note_activity_signal(instance_id, bridge_runtime_normalize_activity_status(activity_status), source)
}

bridge_runtime_note_activity_signal :: proc(instance_id, activity_status, activity_source: string) {
	if strings.trim_space(instance_id) == "" do return
	now := bridge_runtime_now_ms()
	activity := bridge_runtime_normalize_activity_status(activity_status)
	should_prompt := false
	sync.mutex_lock(&bridge_runtime_mutex)
	// Stop-intent guard: if an operator stop is in flight for this instance, drop
	// the signal so a late/racing wrapper liveness or subscribe cannot resurrect a
	// deliberately stopped instance back to running/starting. The intent is
	// time-boxed (BRIDGE_STOP_INTENT_TTL_MS) and cleared by a genuine relaunch.
	if bridge_runtime_stop_intent_active_locked(instance_id, now) {
		sync.mutex_unlock(&bridge_runtime_mutex)
		return
	}
	if inst, ok := bridge_runtime_instance_snapshot_locked(instance_id); ok {
		// A wrapper or extension activity signal proves the local process is alive,
		// but it is NOT equivalent to agent start-success. Any pre-success state
		// remains "starting" until the agent explicitly calls start-success.
		if !inst.start_success_seen {
			if inst.runtime_status == "failed" {
				bridge_runtime_set_status_with_source_locked(instance_id, "failed", activity, activity_source, now, true, false)
				should_prompt = bridge_runtime_maybe_mark_start_prompt_locked(instance_id, now, true)
			} else {
				bridge_runtime_set_status_with_source_locked(instance_id, "starting", activity, activity_source, now, true, false)
				should_prompt = bridge_runtime_maybe_mark_start_prompt_locked(instance_id, now, inst.runtime_status == "unreachable" || inst.runtime_status == "stopped")
			}
			sync.mutex_unlock(&bridge_runtime_mutex)
			if should_prompt do bridge_wrapper_push_startup_prompt(instance_id)
			return
		}
		bridge_runtime_set_status_with_source_locked(instance_id, "running", activity, activity_source, now, true, false)
		sync.mutex_unlock(&bridge_runtime_mutex)
		return
	}
	// No in-memory record usually means bridge restart while the tmux wrapper kept
	// running. Rediscover it as "starting" rather than "running"; Hub will keep a
	// durable already-ready instance running if appropriate, and otherwise the pane
	// receives an explicit start-success prompt.
	bridge_runtime_set_status_with_source_locked(instance_id, "starting", activity, activity_source, now, true, false)
	should_prompt = bridge_runtime_maybe_mark_start_prompt_locked(instance_id, now, true)
	sync.mutex_unlock(&bridge_runtime_mutex)
	if should_prompt do bridge_wrapper_push_startup_prompt(instance_id)
}

// bridge_runtime_mark_stop_intent records that an operator-requested stop has
// begun for this instance. It creates the in-memory record if missing (e.g. after
// a bridge restart where the registry is empty) so the tombstone survives the
// subsequent set_status calls and blocks resurrection by a late wrapper signal.
bridge_runtime_mark_stop_intent :: proc(instance_id: string) {
	if strings.trim_space(instance_id) == "" do return
	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == instance_id {
			bridge_runtime_instances[i].stopped_intent_unix_ms = now
			return
		}
	}
	append(&bridge_runtime_instances, Bridge_Runtime_Instance{agent_instance_id = strings.clone(instance_id), state_seq = bridge_runtime_next_state_seq(0, now), runtime_status = "stopping", activity_status = "idle", last_seen_unix_ms = now, stopped_intent_unix_ms = now})
}

// bridge_runtime_clear_stop_intent removes the stop tombstone (called when a
// genuine launch/relaunch of the same instance begins).
bridge_runtime_clear_stop_intent :: proc(instance_id: string) {
	if strings.trim_space(instance_id) == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == instance_id {
			bridge_runtime_instances[i].stopped_intent_unix_ms = 0
			return
		}
	}
}

// bridge_runtime_stop_intent_active_locked reports whether a recent stop intent is
// still in effect. Caller must hold bridge_runtime_mutex.
bridge_runtime_stop_intent_active_locked :: proc(instance_id: string, now: i64) -> bool {
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == instance_id {
			ts := bridge_runtime_instances[i].stopped_intent_unix_ms
			return ts > 0 && now - ts < i64(BRIDGE_STOP_INTENT_TTL_MS)
		}
	}
	return false
}

bridge_runtime_mark_start_success :: proc(instance_id: string) {
	if strings.trim_space(instance_id) == "" do return
	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_runtime_set_status_locked(instance_id, "running", "idle", now, true)
}

bridge_runtime_set_status_locked :: proc(instance_id, runtime_status, activity_status: string, now: i64, touch_seen: bool) {
	bridge_runtime_set_status_with_source_locked(instance_id, runtime_status, activity_status, "bridge", now, touch_seen, true)
}

bridge_runtime_set_status_with_source_locked :: proc(instance_id, runtime_status, activity_status, activity_source: string, now: i64, touch_seen: bool, force_activity: bool) {
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == instance_id {
			inst := &bridge_runtime_instances[i]
			old_runtime := inst.runtime_status
			accept_activity := activity_status != "" && (force_activity || bridge_runtime_accept_activity_update(inst, activity_source, now))
			runtime_changed := inst.runtime_status != runtime_status
			activity_changed := accept_activity && inst.activity_status != activity_status
			if runtime_changed || activity_changed {
				inst.state_seq = bridge_runtime_next_state_seq(inst.state_seq, now)
				inst.runtime_status = runtime_status
				if accept_activity do inst.activity_status = activity_status
			}
			if accept_activity {
				inst.activity_source = strings.clone(activity_source)
				inst.activity_updated_unix_ms = now
			}
			if touch_seen || inst.last_seen_unix_ms == 0 do inst.last_seen_unix_ms = now
			if runtime_status == "starting" {
				inst.start_success_seen = false
				if old_runtime != "starting" || inst.start_deadline_unix_ms == 0 do inst.start_deadline_unix_ms = now + BRIDGE_START_SUCCESS_TIMEOUT_MS
			} else if runtime_status == "running" {
				inst.start_success_seen = true
				inst.start_deadline_unix_ms = 0
				inst.last_start_prompt_unix_ms = 0
			} else if !bridge_runtime_status_active(runtime_status) {
				inst.start_deadline_unix_ms = 0
			}
			return
		}
	}
	deadline: i64 = 0
	seen := runtime_status == "running"
	if runtime_status == "starting" do deadline = now + BRIDGE_START_SUCCESS_TIMEOUT_MS
	// Bridge-local state is memory-only and resets on bridge relaunch while Hub
	// keeps the durable last_applied_seq. Seed new local records from wall-clock ms
	// plus a safety offset so post-relaunch reports remain newer than prior Hub seqs
	// even if direct agent-actions (like repeated start-success) advanced the DB.
	append(&bridge_runtime_instances, Bridge_Runtime_Instance{agent_instance_id = strings.clone(instance_id), state_seq = bridge_runtime_next_state_seq(0, now), runtime_status = strings.clone(runtime_status), activity_status = strings.clone(activity_status), activity_source = strings.clone(activity_source), activity_updated_unix_ms = now, last_seen_unix_ms = now, start_deadline_unix_ms = deadline, start_success_seen = seen})
}

bridge_runtime_next_state_seq :: proc(current: int, now: i64) -> int {
	floor := int(now + i64(BRIDGE_STATE_SEQ_FLOOR_OFFSET_MS))
	if current + 1 > floor do return current + 1
	return floor
}

bridge_runtime_accept_activity_update :: proc(inst: ^Bridge_Runtime_Instance, source: string, now: i64) -> bool {
	if inst == nil do return true
	current_rank := bridge_runtime_activity_source_rank(inst.activity_source)
	new_rank := bridge_runtime_activity_source_rank(source)
	if current_rank <= 0 || new_rank >= current_rank do return true
	if inst.activity_updated_unix_ms <= 0 do return true
	ttl := i64(BRIDGE_ACTIVITY_IDLE_SOURCE_TTL_MS)
	if inst.activity_status == "active" do ttl = i64(BRIDGE_ACTIVITY_ACTIVE_SOURCE_TTL_MS)
	return now - inst.activity_updated_unix_ms > ttl
}

bridge_runtime_activity_source_rank :: proc(source: string) -> int {
	s := strings.to_lower(strings.trim_space(source))
	// NOTE: the pi_extension==100 fast-path was REMOVED with the pi activity
	// extension (task_18d129291c6a455d). It was the high-priority source that
	// suppressed a correct pane_diff 'idle' (the stuck 'working · settling' bug).
	// A native harness extension (e.g. antigravity) still ranks via the generic
	// contains("extension")=>80 branch below.
	if strings.contains(s, "extension") do return 80
	// Harness-agnostic tmux pane-capture detector: now the primary activity source
	// for every provider.
	if s == "pane_diff" do return 40
	// Permission gate (waiting_user while a blocking approval is outstanding, then
	// active on resolve). Ranked EQUAL to pane_diff on purpose: equal ranks always
	// accept (new_rank >= current_rank), so the gate's waiting_user shows
	// immediately AND the next pane_diff cycle can override it right after the gate
	// resolves — a higher rank would recreate a mini stuck-suppression until TTL.
	if s == "permission_gate" do return 40
	if s == "wrapper" do return 10
	if s == "bridge" do return 5
	return 1
}

bridge_runtime_normalize_activity_status :: proc(status: string) -> string {
	s := strings.to_lower(strings.trim_space(status))
	if s == "active" || s == "working" || s == "busy" do return "active"
	// waiting_user / waiting / waiting_approval: the agent has finished its turn and
	// is BLOCKED on a human (an empty prompt, a y/n approval, "press enter", …). It
	// is NOT doing work, so it must NOT surface as "active"/"working" in the hub —
	// otherwise an idle agent sitting on the user reads as busy forever. We collapse
	// these to the idle-equivalent projection; the finer-grained "waiting_user"
	// signal is still available on the wrapper sample for callers that want it.
	if s == "waiting_user" || s == "waiting" || s == "waiting_approval" do return "idle"
	if s == "idle" || s == "inactive" do return "idle"
	if s == "unknown" do return "unknown"
	if s == "" do return "unknown"
	return s
}

bridge_runtime_maybe_mark_start_prompt_locked :: proc(instance_id: string, now: i64, force: bool) -> bool {
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id != instance_id do continue
		inst := &bridge_runtime_instances[i]
		if inst.start_success_seen do return false
		if !force {
			started_at := inst.start_deadline_unix_ms - BRIDGE_START_SUCCESS_TIMEOUT_MS
			if inst.start_deadline_unix_ms == 0 || now - started_at < BRIDGE_START_SUCCESS_PROMPT_AFTER_MS do return false
		}
		if inst.last_start_prompt_unix_ms > 0 && now - inst.last_start_prompt_unix_ms < BRIDGE_START_SUCCESS_PROMPT_INTERVAL_MS do return false
		inst.last_start_prompt_unix_ms = now
		return true
	}
	return false
}

bridge_runtime_instance_snapshot :: proc(instance_id: string) -> (Bridge_Runtime_Instance, bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	return bridge_runtime_instance_snapshot_locked(instance_id)
}

bridge_runtime_instance_snapshot_locked :: proc(instance_id: string) -> (Bridge_Runtime_Instance, bool) {
	for inst in bridge_runtime_instances { if inst.agent_instance_id == instance_id do return inst, true }
	return {}, false
}

bridge_instance_status_json :: proc(instance_id: string) -> string {
	inst, ok := bridge_runtime_instance_snapshot(instance_id)
	if !ok do return "{}"
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"agent_instance_status\",\"protocol_version\":1,\"agent_instance_id\":\"")
	bridge_runtime_write_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, "\",\"state_seq\":")
	strings.write_string(&b, fmt.tprintf("%d", inst.state_seq))
	strings.write_string(&b, ",\"runtime_status\":\"")
	bridge_runtime_write_json_string(&b, inst.runtime_status)
	strings.write_string(&b, "\",\"activity_status\":\"")
	bridge_runtime_write_json_string(&b, inst.activity_status)
	strings.write_string(&b, "\",\"activity_source\":\"")
	bridge_runtime_write_json_string(&b, inst.activity_source)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_hub_heartbeat_json :: proc() -> string {
	caps := bridge_provider_capabilities_json()
	features := bridge_runtime_features_json()
	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_runtime_expire_stale_locked(now)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_heartbeat\",\"protocol_version\":1,\"capabilities\":")
	strings.write_string(&b, caps)
	strings.write_string(&b, ",\"features\":")
	strings.write_string(&b, features)
	strings.write_string(&b, ",\"active_instance_ids\":[")
	first_active := true
	for inst in bridge_runtime_instances {
		if !bridge_runtime_status_active(inst.runtime_status) do continue
		if !first_active do strings.write_byte(&b, ',')
		first_active = false
		strings.write_byte(&b, '"')
		bridge_runtime_write_json_string(&b, inst.agent_instance_id)
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, "],\"instances\":[")
	first := true
	for inst in bridge_runtime_instances {
		if strings.trim_space(inst.runtime_status) == "" do continue
		if !first do strings.write_byte(&b, ',')
		first = false
		strings.write_string(&b, "{\"agent_instance_id\":\"")
		bridge_runtime_write_json_string(&b, inst.agent_instance_id)
		strings.write_string(&b, "\",\"state_seq\":")
		strings.write_string(&b, fmt.tprintf("%d", inst.state_seq))
		strings.write_string(&b, ",\"runtime_status\":\"")
		bridge_runtime_write_json_string(&b, inst.runtime_status)
		strings.write_string(&b, "\",\"activity_status\":\"")
		bridge_runtime_write_json_string(&b, inst.activity_status)
		strings.write_string(&b, "\",\"activity_source\":\"")
		bridge_runtime_write_json_string(&b, inst.activity_source)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

bridge_runtime_expire_stale_locked :: proc(now: i64) {
	for i in 0..<len(bridge_runtime_instances) {
		inst := &bridge_runtime_instances[i]
		if !bridge_runtime_status_active(inst.runtime_status) do continue
		if inst.last_seen_unix_ms > 0 && now - inst.last_seen_unix_ms > BRIDGE_WRAPPER_STALE_MS {
			inst.state_seq = bridge_runtime_next_state_seq(inst.state_seq, now)
			inst.runtime_status = "unreachable"
			inst.activity_status = "idle"
			inst.activity_source = "bridge"
			inst.activity_updated_unix_ms = now
			inst.start_deadline_unix_ms = 0
			continue
		}
		if inst.runtime_status == "starting" && !inst.start_success_seen && inst.start_deadline_unix_ms > 0 && now >= inst.start_deadline_unix_ms {
			inst.state_seq = bridge_runtime_next_state_seq(inst.state_seq, now)
			inst.runtime_status = "failed"
			inst.activity_status = "idle"
			inst.activity_source = "bridge"
			inst.activity_updated_unix_ms = now
			inst.start_deadline_unix_ms = 0
		}
	}
}

bridge_runtime_status_active :: proc(runtime_status: string) -> bool {
	return runtime_status == "launching" || runtime_status == "starting" || runtime_status == "running" || runtime_status == "idle" || runtime_status == "busy" || runtime_status == "stopping"
}

bridge_runtime_cached_command :: proc(command_id: string) -> (string, bool) {
	if command_id == "" do return "", false
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for result in bridge_runtime_results { if result.command_id == command_id do return result.result_json, true }
	return "", false
}

bridge_runtime_cache_command :: proc(command_id, result_json: string) {
	if command_id == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_results) { if bridge_runtime_results[i].command_id == command_id { bridge_runtime_results[i].result_json = strings.clone(result_json); return } }
	append(&bridge_runtime_results, Bridge_Runtime_Command_Result{command_id = strings.clone(command_id), result_json = strings.clone(result_json)})
}

bridge_pane_capture_register_pending :: proc(pending: Bridge_Pane_Capture_Pending) {
	if pending.command_id == "" && pending.pane_capture_request_id == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_pane_capture_pending) { if bridge_pane_capture_pending[i].command_id == pending.command_id || bridge_pane_capture_pending[i].pane_capture_request_id == pending.pane_capture_request_id { bridge_pane_capture_pending[i] = pending; return } }
	append(&bridge_pane_capture_pending, pending)
}

bridge_pane_capture_remove_pending :: proc(command_id, request_id: string) -> (Bridge_Pane_Capture_Pending, bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_pane_capture_pending) {
		if (command_id != "" && bridge_pane_capture_pending[i].command_id == command_id) || (request_id != "" && bridge_pane_capture_pending[i].pane_capture_request_id == request_id) {
			pending := bridge_pane_capture_pending[i]
			unordered_remove(&bridge_pane_capture_pending, i)
			return pending, true
		}
	}
	return {}, false
}

bridge_pane_capture_enqueue_result :: proc(result_json, command_id: string) {
	if strings.trim_space(result_json) == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	append(&bridge_pane_capture_outgoing, Bridge_Pane_Capture_Outgoing{command_id=strings.clone(command_id),result_json=strings.clone(result_json)})
}

bridge_pane_capture_drain_outgoing :: proc(conn: ^ws.Connection) {
	for {
		item: Bridge_Pane_Capture_Outgoing
		have := false
		sync.mutex_lock(&bridge_runtime_mutex)
		if len(bridge_pane_capture_outgoing) > 0 { item = bridge_pane_capture_outgoing[0]; ordered_remove(&bridge_pane_capture_outgoing, 0); have = true }
		sync.mutex_unlock(&bridge_runtime_mutex)
		if !have do return
		if !ws.send_text(conn, item.result_json) {
			sync.mutex_lock(&bridge_runtime_mutex)
			append(&bridge_pane_capture_outgoing, item)
			sync.mutex_unlock(&bridge_runtime_mutex)
			conn.connected = false
			return
		}
		if item.command_id != "" do bridge_runtime_cache_command(item.command_id, bridge_command_result_payload_json(item.command_id,"succeeded","{}"))
	}
}

bridge_pane_capture_expire_pending :: proc() {
	now := bridge_runtime_now_ms()
	expired := make([dynamic]Bridge_Pane_Capture_Pending)
	sync.mutex_lock(&bridge_runtime_mutex)
	for i:=0; i<len(bridge_pane_capture_pending); {
		if bridge_pane_capture_pending[i].deadline_unix_ms > 0 && now >= bridge_pane_capture_pending[i].deadline_unix_ms { append(&expired, bridge_pane_capture_pending[i]); unordered_remove(&bridge_pane_capture_pending, i); continue }
		i += 1
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	for pending in expired { bridge_pane_capture_enqueue_result(bridge_pane_capture_result_json(pending,false,"capture_timeout","The pane capture request timed out.","",0,false), pending.command_id) }
}

bridge_pane_capture_push_json :: proc(pending: Bridge_Pane_Capture_Pending, settle_ms:int)->string{ b:=strings.builder_make(); strings.write_string(&b,"{\"push\":\"pane_capture_request\",\"payload\":{\"protocol_version\":1,\"command_id\":\""); bridge_runtime_write_json_string(&b,pending.command_id); strings.write_string(&b,"\",\"pane_capture_request_id\":\""); bridge_runtime_write_json_string(&b,pending.pane_capture_request_id); strings.write_string(&b,"\",\"message_id\":\""); bridge_runtime_write_json_string(&b,pending.message_id); strings.write_string(&b,"\",\"width\":"); strings.write_string(&b,fmt.tprintf("%d",pending.width)); strings.write_string(&b,",\"settle_ms\":"); strings.write_string(&b,fmt.tprintf("%d",settle_ms)); strings.write_string(&b,",\"line_limit\":"); strings.write_string(&b,fmt.tprintf("%d",pending.line_limit)); strings.write_string(&b,"}}\n"); return strings.to_string(b) }

bridge_pane_capture_result_json :: proc(pending: Bridge_Pane_Capture_Pending, ok:bool, error_code,message,output:string,line_count:int,truncated:bool)->string{ b:=strings.builder_make(); strings.write_string(&b,"{\"type\":\"pane_capture_result\",\"protocol_version\":1,\"command_id\":\""); bridge_runtime_write_json_string(&b,pending.command_id); strings.write_string(&b,"\",\"pane_capture_request_id\":\""); bridge_runtime_write_json_string(&b,pending.pane_capture_request_id); strings.write_string(&b,"\",\"conversation_id\":\""); bridge_runtime_write_json_string(&b,pending.conversation_id); strings.write_string(&b,"\",\"message_id\":\""); bridge_runtime_write_json_string(&b,pending.message_id); strings.write_string(&b,"\",\"agent_instance_id\":\""); bridge_runtime_write_json_string(&b,pending.agent_instance_id); strings.write_string(&b,"\",\"ok\":"); strings.write_string(&b,"true" if ok else "false"); strings.write_string(&b,",\"width\":"); strings.write_string(&b,fmt.tprintf("%d",pending.width)); strings.write_string(&b,",\"line_count\":"); strings.write_string(&b,fmt.tprintf("%d",line_count)); strings.write_string(&b,",\"truncated\":"); strings.write_string(&b,"true" if truncated else "false"); if ok { strings.write_string(&b,",\"output\":\""); bridge_runtime_write_json_string(&b,output); strings.write_string(&b,"\"") } else { strings.write_string(&b,",\"error_code\":\""); bridge_runtime_write_json_string(&b,error_code); strings.write_string(&b,"\",\"message\":\""); bridge_runtime_write_json_string(&b,message); strings.write_string(&b,"\"") }; strings.write_string(&b,"}"); return strings.to_string(b) }

bridge_command_result_json :: proc(command_id, status, runtime_status: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{\"status\":\"")
	bridge_runtime_write_json_string(&b, status)
	strings.write_string(&b, "\"")
	if runtime_status != "" {
		strings.write_string(&b, ",\"result\":{\"runtime_status\":\"")
		bridge_runtime_write_json_string(&b, runtime_status)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

bridge_command_result_payload_json :: proc(command_id, status, result_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{\"status\":\"")
	bridge_runtime_write_json_string(&b, status)
	strings.write_string(&b, "\",\"result\":")
	if strings.trim_space(result_json) == "" { strings.write_string(&b, "{}") } else { strings.write_string(&b, result_json) }
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

bridge_providers_report_json :: proc(command_id, payload_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"providers_report\",\"protocol_version\":1,\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":")
	if strings.trim_space(payload_json) == "" { strings.write_string(&b, "{}") } else { strings.write_string(&b, payload_json) }
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

bridge_provider_test_status_json :: proc(test_id, status, phase, message, diagnostics: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"provider_test_status\",\"protocol_version\":1,\"payload\":{\"test_id\":\"")
	bridge_runtime_write_json_string(&b, test_id)
	strings.write_string(&b, "\",\"status\":\""); bridge_runtime_write_json_string(&b, status)
	strings.write_string(&b, "\",\"phase\":\""); bridge_runtime_write_json_string(&b, phase)
	strings.write_string(&b, "\",\"message\":\""); bridge_runtime_write_json_string(&b, message)
	if diagnostics != "" { strings.write_string(&b, "\",\"diagnostics\":\""); bridge_runtime_write_json_string(&b, bridge_provider_test_sanitize_diagnostics(diagnostics)) }
	strings.write_string(&b, "\",\"at\":\""); strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now())))
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_provider_test_frame_json :: proc(test_id, content: string) -> string {
	b := strings.builder_make()
	seq := 0
	if test, ok := bridge_provider_test_get(test_id); ok {
		seq = test.frame_seq + 1
		test.frame_seq = seq
		bridge_provider_test_record(test)
	}
	strings.write_string(&b, "{\"type\":\"provider_test_frame\",\"protocol_version\":1,\"payload\":{\"test_id\":\"")
	bridge_runtime_write_json_string(&b, test_id)
	strings.write_string(&b, "\",\"seq\":"); strings.write_string(&b, fmt.tprintf("%d", seq))
	strings.write_string(&b, ",\"at\":\""); strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now())))
	strings.write_string(&b, "\",\"rows\":80,\"cols\":0,\"format\":\"text\",\"content\":\"")
	bridge_runtime_write_json_string(&b, bridge_provider_test_truncate(content, 12000))
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_provider_test_result_json :: proc(test_id, provider, status, message, diagnostics: string) -> string {
	return bridge_provider_test_result_json_with_tier(test_id, provider, "", status, message, diagnostics)
}

bridge_provider_test_result_json_with_tier :: proc(test_id, provider, tier, status, message, diagnostics: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"test_id\":\""); bridge_runtime_write_json_string(&b, test_id)
	strings.write_string(&b, "\",\"name\":\""); bridge_runtime_write_json_string(&b, provider)
	strings.write_string(&b, "\",\"provider\":\""); bridge_runtime_write_json_string(&b, provider)
	if tier != "" { strings.write_string(&b, "\",\"tier\":\""); bridge_runtime_write_json_string(&b, tier) }
	strings.write_string(&b, "\",\"status\":\""); bridge_runtime_write_json_string(&b, status)
	strings.write_string(&b, "\",\"tested_at\":\""); strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now())))
	strings.write_string(&b, "\",\"message\":\""); bridge_runtime_write_json_string(&b, message)
	if diagnostics != "" { strings.write_string(&b, "\",\"diagnostics\":\""); bridge_runtime_write_json_string(&b, bridge_provider_test_sanitize_diagnostics(diagnostics)) }
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_provider_payload_object :: proc(text: string) -> string {
	if payload, ok := bridge_provider_json_extract_object(text, "payload"); ok do return payload
	return "{}"
}

bridge_runtime_json_escaped :: proc(value: string) -> string {
	b := strings.builder_make()
	bridge_runtime_write_json_string(&b, value)
	return strings.to_string(b)
}

bridge_runtime_provider_test_int :: proc(json, key: string, fallback, min, max: int) -> int {
	value := extract_json_int(json, key, fallback)
	if value < min do return min
	if value > max do return max
	return value
}

bridge_provider_test_truncate :: proc(value: string, max_len: int) -> string {
	if max_len <= 0 || len(value) <= max_len do return value
	return value[len(value) - max_len:]
}

bridge_provider_test_sanitize_diagnostics :: proc(value: string) -> string {
	out := bridge_provider_test_truncate(value, 4000)
	out, _ = strings.replace_all(out, bridge_config.bridge_token, "[redacted]")
	return out
}

bridge_hub_hello_json :: proc() -> string {
	caps := bridge_provider_capabilities_json()
	features := bridge_runtime_features_json()
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_hello\",\"protocol_version\":1,\"bootstrap_fragment_cache\":true,\"hostname\":\"")
	bridge_runtime_write_json_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, "\",\"capabilities\":")
	strings.write_string(&b, caps)
	strings.write_string(&b, ",\"features\":")
	strings.write_string(&b, features)
	strings.write_string(&b, ",\"active_instance_ids\":[")
	sync.mutex_lock(&bridge_runtime_mutex)
	first := true
	for launch in bridge_runtime_launches {
		if !first do strings.write_byte(&b, ',')
		first = false
		strings.write_byte(&b, '"')
		bridge_runtime_write_json_string(&b, launch.agent_instance_id)
		strings.write_byte(&b, '"')
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

bridge_runtime_features_json :: proc() -> string { return "[\"capture_agent_pane\"]" }

bridge_runtime_write_json_string :: proc(b: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(b, "\\\\")
		case '"': strings.write_string(b, "\\\"")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case: strings.write_rune(b, ch)
		}
	}
}

bridge_hub_ws_url :: proc(base_url: string) -> string {
	trimmed := bridge_hub_base_url_for_runtime(base_url)
	if strings.has_prefix(trimmed, "http://") do return strings.concatenate({"ws://", trimmed[len("http://"):], "/api/v1/bridge-ws"})
	if strings.has_prefix(trimmed, "https://") do return strings.concatenate({"wss://", trimmed[len("https://"):], "/api/v1/bridge-ws"})
	return ""
}

bridge_hub_base_url_for_runtime :: proc(base_url: string) -> string {
	return strings.trim_right(strings.trim_space(base_url), "/")
}

bridge_hub_runtime_start :: proc() {
	bridge_hub_runtime_init()
	if strings.trim_space(bridge_config.bridge_token) != "" && strings.trim_space(bridge_config.daemon_url) != "" {
		thread.run(bridge_hub_runtime_worker)
	}
}
