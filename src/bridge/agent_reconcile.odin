package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "base:runtime"
import httpc "odin_test:lib/httpc"

@(private = "file")
_bridge_agent_reconcile_running: bool
@(private = "file")
_bridge_agent_reconcile_mu: sync.Mutex

// bridge_agent_instance_extract_hub_instances parses the JSON response from Hub GET /api/v1/agent-instances
// and returns a map of instance_id -> runtime_status for all instances on this bridge.
// Caller owns the returned map and its cloned keys and values (use bridge_agent_instance_delete_hub_instances).
bridge_agent_instance_extract_hub_instances :: proc(
	body: string,
	allocator := context.allocator,
) -> (map[string]string, bool) {
	parsed, err := json.parse_string(body, json.DEFAULT_SPECIFICATION, false, allocator)
	if err != .None do return nil, false
	defer json.destroy_value(parsed, allocator)

	data_arr: json.Array
	if root_arr, is_arr := parsed.(json.Array); is_arr {
		data_arr = root_arr
	} else if root_obj, is_obj := parsed.(json.Object); is_obj {
		data_val, has_data := root_obj["data"]
		if !has_data do return nil, false
		arr, arr_ok := data_val.(json.Array)
		if !arr_ok do return nil, false
		data_arr = arr
	} else {
		return nil, false
	}

	hub_instances := make(map[string]string, 0, allocator)
	for item in data_arr {
		item_obj, is_obj := item.(json.Object)
		if !is_obj do continue

		id_val, has_id := item_obj["agent_instance_id"]
		if !has_id do continue
		id_str, id_is_str := id_val.(json.String)
		if !id_is_str do continue

		stop_val, _ := item_obj["stop_reason"].(json.String)
		id := string(id_str)
		status := "stopped" if strings.has_prefix(string(stop_val), "user") else "preserve"
		if !(id in hub_instances) {
			hub_instances[strings.clone(id, allocator)] = strings.clone(status, allocator)
		}
	}
	return hub_instances, true
}

// bridge_agent_instance_delete_hub_instances frees the keys, values, and map returned by bridge_agent_instance_extract_hub_instances.
bridge_agent_instance_delete_hub_instances :: proc(hub_instances: ^map[string]string, allocator := context.allocator) {
	if hub_instances == nil do return
	for k, v in hub_instances {
		delete(k, allocator)
		delete(v, allocator)
	}
	delete(hub_instances^)
}

Bridge_Agent_Reconcile_Plan :: struct {
	to_preserve:      [dynamic]string,
	to_reap:          [dynamic]string,
	to_push_terminal: [dynamic]string,
}

// bridge_agent_instance_compute_reconcile_plan computes the bidirectional reconciliation actions (REQ-RECON-FIX-1):
// - Instances alive on pty-host where Hub status is NOT 'stopped' are preserved and reported running.
// - Instances alive on pty-host where Hub status IS 'stopped' (user stopped while disconnected) are reaped.
// - Instances that are reaped or unknown/dead on pty-host have terminal status pushed to Hub.
bridge_agent_instance_compute_reconcile_plan :: proc(
	pty_agents: []Pty_Host_Agent_Info,
	hub_instances: map[string]string,
	allocator := context.allocator,
) -> Bridge_Agent_Reconcile_Plan {
	plan := Bridge_Agent_Reconcile_Plan{
		to_preserve      = make([dynamic]string, allocator),
		to_reap          = make([dynamic]string, allocator),
		to_push_terminal = make([dynamic]string, allocator),
	}

	// 1. Evaluate physical reality (sessions on pty-host)
	for a in pty_agents {
		if !a.alive do continue
		if !strings.has_prefix(a.instance_id, "inst_") do continue

		hub_status, in_hub := hub_instances[a.instance_id]
		if in_hub && hub_status == "stopped" {
			// User explicitly stopped on Hub while disconnected -> reap on pty-host and push terminal status
			append(&plan.to_reap, strings.clone(a.instance_id, allocator))
			append(&plan.to_push_terminal, strings.clone(a.instance_id, allocator))
		} else {
			// Hub status is not 'stopped' (e.g. running, unreachable, starting, launching, or new)
			// Keep alive, register in runtime, report running
			append(&plan.to_preserve, strings.clone(a.instance_id, allocator))
		}
	}

	// 2. Evaluate Hub instances that are lingering in active statuses but not alive on pty-host
	for hub_id, hub_status in hub_instances {
		if !strings.has_prefix(hub_id, "inst_") do continue
		if hub_status == "stopped" do continue

		// Check if it is alive on pty-host
		is_alive_on_pty := false
		for a in pty_agents {
			if a.alive && a.instance_id == hub_id {
				is_alive_on_pty = true
				break
			}
		}

		if !is_alive_on_pty {
			// Not alive on pty-host (reaped or unknown). Check if already in to_push_terminal
			already_in := false
			for id in plan.to_push_terminal {
				if id == hub_id {
					already_in = true
					break
				}
			}
			if !already_in {
				append(&plan.to_push_terminal, strings.clone(hub_id, allocator))
			}
		}
	}

	return plan
}

bridge_agent_instance_plan_delete :: proc(plan: ^Bridge_Agent_Reconcile_Plan, allocator := context.allocator) {
	if plan == nil do return
	for id in plan.to_preserve do delete(id, allocator)
	delete(plan.to_preserve)
	for id in plan.to_reap do delete(id, allocator)
	delete(plan.to_reap)
	for id in plan.to_push_terminal do delete(id, allocator)
	delete(plan.to_push_terminal)
}

// bridge_agent_instance_reconcile_now reconciles surviving agent instances on ham-pty-host against
// the Hub's active instance list upon bridge connection / restart (REQ-REAP-STARTUP-1..5, REQ-RECON-FIX-1).
// Single-flight execution guarded by sync.Mutex.
bridge_agent_instance_reconcile_now :: proc() {
	sync.mutex_lock(&_bridge_agent_reconcile_mu)
	if _bridge_agent_reconcile_running {
		sync.mutex_unlock(&_bridge_agent_reconcile_mu)
		return
	}
	_bridge_agent_reconcile_running = true
	sync.mutex_unlock(&_bridge_agent_reconcile_mu)
	defer {
		sync.mutex_lock(&_bridge_agent_reconcile_mu)
		_bridge_agent_reconcile_running = false
		sync.mutex_unlock(&_bridge_agent_reconcile_mu)
	}

	credential_snapshot_168 := bridge_credential_snapshot()
	defer delete(credential_snapshot_168)
	if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(credential_snapshot_168) == "" {
		return
	}

	socket, sock_ok := bridge_pty_host_ensure_daemon()
	if !sock_ok do return

	reply, list_ok := bridge_pty_host_list(socket)
	if !list_ok do return
	defer pty_host_reply_delete(reply)

	credential_snapshot_181 := bridge_credential_snapshot()
	defer delete(credential_snapshot_181)
	headers := [?]httpc.Header{httpc.bearer(credential_snapshot_181)}

	body, complete := bridge_agent_reconcile_fetch(headers[:])
	if !complete do return
	defer delete(body)
	hub_instances, parse_ok := bridge_agent_instance_extract_hub_instances(body)
	if !parse_ok do return
	defer bridge_agent_instance_delete_hub_instances(&hub_instances)
	intents := bridge_agent_reconcile_acp_intents(body)
	handled := make(map[string]bool, allocator = context.temp_allocator)
	has_acp := false
	for _, intent in intents do if intent.transport == "acp" do has_acp = true
	if has_acp {
		pipe_frame := pty_host_encode_pipe_request({kind = .List}); defer delete(pipe_frame)
		pipes, pipes_ok := pty_host_request_deadline(socket, pipe_frame, 2000)
		defer pty_host_reply_delete(pipes)
		if pipes_ok && pipes.kind == .Pipe_List {
			handled = acp_runtime_reconcile(socket, pipes.pipes, intents)
		} else {
			// An adopted daemon may not implement ListPipes. Do not infer
			// anything about ACP from that refusal, but still reconcile the
			// independently verified legacy PTY roster.
			for id, intent in intents do if intent.transport == "acp" do handled[id] = true
			fmt.eprintln("bridge agent reconcile: ACP inventory unavailable; reconciling PTY only")
		}
	}

	plan := bridge_agent_instance_compute_reconcile_plan(reply.agents, hub_instances)
	defer bridge_agent_instance_plan_delete(&plan)

	// 1. Preserve surviving pty-host instances and report running to Hub
	for id in plan.to_preserve {
		if handled[id] do continue
		now := bridge_runtime_now_ms()
		sync.mutex_lock(&bridge_runtime_mutex)
		snap, known := bridge_runtime_instance_snapshot_locked(id)
		if bridge_runtime_stop_intent_active_locked(id, now) {
			sync.mutex_unlock(&bridge_runtime_mutex)
			continue
		}
		// A roster sighting repairs lost/terminal state, but cannot promote a
		// newly launched, not-yet-ready child or overwrite current activity.
		restored := !known || !bridge_runtime_status_active(snap.runtime_status)
		if restored do bridge_runtime_set_status_locked(id, "running", "idle", now, true, .pty_reconcile_live_child)
		bridge_runtime_set_pty_process_alive_locked(id, true)
		// A surviving pty-host agent is a PTY runtime; record it so inputs
		// route to it after a bridge restart (there is no default transport).
		for &inst in bridge_runtime_instances do if inst.agent_instance_id == id && inst.runtime_transport == "" do inst.runtime_transport = pty_agent_runtime.transport
		sync.mutex_unlock(&bridge_runtime_mutex)
		if restored do fmt.println("bridge agent reconcile: preserved live instance", id)
	}

	// 2. Reap instances on pty-host marked stopped by user
	for id in plan.to_reap {
		if handled[id] do continue
		if bridge_pty_host_close(socket, id) {
			fmt.println("bridge agent reconcile: reaped stopped instance", id)
		} else {
			// A failed close cannot authorize terminal publication below.
			handled[id] = true
			continue
		}
		bridge_agent_token_invalidate_instance(id)
	}

	// Missing rows are not unsolicited process-exit events. The Hub resolves
	// them with a generation-bound point probe when deciding a lease or wake.
}

// Collect every page before doing any destructive reconciliation. Malformed,
// repeated or absent cursors abort the whole snapshot rather than reap unseen
// instances. The API currently uses created_at cursors.
bridge_agent_reconcile_fetch :: proc(headers: []httpc.Header) -> (string, bool) {
    context.allocator = context.temp_allocator
    b := strings.builder_make(); strings.write_byte(&b, '[')
    cursor := ""; count := 0
    seen := make(map[string]bool)
    for _ in 0..<10000 {
        resp, err := bridge_http_request_retry({method = .GET, url = bridge_hub_url(), path = {"api", "v1", "agent-instances"},
            query = {{"bridge_id", bridge_config.daemon_id}, {"limit", "200"}, {"cursor", cursor}}, headers = headers})
        defer httpc.response_destroy(&resp)
        if err != .None || resp.status != 200 do return "", false
        value, perr := json.parse(httpc.text(resp)); if perr != nil do return "", false
        obj, ok := value.(json.Object); if !ok do return "", false
        data, valid := obj["data"].(json.Array); if !valid do return "", false
        for item in data {
            if count > 0 do strings.write_byte(&b, ',')
            raw, _ := json.marshal(item); strings.write_string(&b, string(raw)); count += 1
        }
        page, page_ok := obj["page"].(json.Object)
        if !page_ok do return "", false
        more, more_ok := page["has_more"].(json.Boolean)
        if !more_ok do return "", false
        if !bool(more) { strings.write_byte(&b, ']'); return strings.clone(strings.to_string(b), runtime.heap_allocator()), true }
        next, next_ok := page["next_cursor"].(json.String)
        if !next_ok || next == "" || seen[string(next)] do return "", false
        cursor = string(next); seen[cursor] = true
    }
    return "", false
}

bridge_agent_reconcile_acp_intents :: proc(raw: string) -> map[string]ACP_Hub_Intent {
    out := make(map[string]ACP_Hub_Intent, allocator = context.temp_allocator)
    value, err := json.parse(raw, allocator = context.temp_allocator, parse_integers = true)
    if err != nil do return out
    rows, _ := value.(json.Array)
    for row in rows {
        obj, valid := row.(json.Object); if !valid do continue
        id, _ := obj["agent_instance_id"].(json.String)
        epoch, _ := obj["launch_epoch"].(json.String)
        stop, _ := obj["stop_reason"].(json.String)
        transport, _ := obj["runtime_transport"].(json.String)
        generation, _ := obj["run_count"].(json.Integer)
        provider, _ := obj["provider"].(json.String)
        profile, _ := obj["provider_profile"].(json.String)
        out[string(id)] = {status = "stopped" if strings.has_prefix(string(stop), "user") else "", epoch = string(epoch), transport = string(transport), run_count = int(generation),
            provider = string(provider), profile = profile_effective_id(string(provider), string(profile))}
    }
    return out
}
