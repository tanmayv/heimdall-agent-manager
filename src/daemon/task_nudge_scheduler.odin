package main

import "core:fmt"
import "core:strings"
import "core:thread"
import "core:time"
import cfg_lib "odin_test:lib/config"

task_nudge_cfg:               cfg_lib.Daemon_Config
task_nudge_scheduler_started: bool

task_nudge_scheduler_start :: proc(cfg: cfg_lib.Daemon_Config) {
	task_nudge_cfg = cfg
	if !cfg.nudge_enabled do return
	if task_nudge_scheduler_started do return
	task_nudge_scheduler_started = true
	thread.run(task_nudge_scheduler_worker)
}

task_nudge_scheduler_worker :: proc() {
	grace := task_nudge_cfg.nudge_restart_grace_seconds
	if grace < 0 do grace = 0
	if grace > 0 do time.sleep(time.Duration(grace) * time.Second)
	for {
		task_nudge_scheduler_tick()
		interval := task_nudge_cfg.nudge_interval_seconds
		if interval <= 0 do interval = 60
		time.sleep(time.Duration(interval) * time.Second)
	}
}

task_nudge_scheduler_tick :: proc() -> int {
	if !task_nudge_cfg.nudge_enabled do return 0
	now     := router_now_unix_ms()
	changed := 0
	for state in store_all_tasks() {
		if !task_chain_allows_execution(state.chain_id) do continue
		threshold := task_nudge_threshold_seconds(state.status)
		if threshold <= 0 do continue
		if state.updated_at_unix_ms == 0 do continue
		if now - state.updated_at_unix_ms < i64(threshold) * 1000 do continue
		target := task_nudge_target_for_status(state, state.status)
		if state.status == .Review_Ready && target != "" && task_reviewer_active_slot_blocker(target, state.task_id) != "" do continue
		last   := task_last_nudge_unix_ms(state.task_id, target)
		cooldown := task_nudge_cfg.nudge_cooldown_seconds
		if cooldown <= 0 do cooldown = 300
		if last > 0 && now - last < i64(cooldown) * 1000 do continue
		body := task_scheduled_nudge_body(state, target)
		kind := Task_Event_Kind.Task_Nudged
		if target == "" {
			kind = .Task_Nudge_Failed
			body = strings.concatenate({body, " reason=no_target"})
		} else if !registry_agent_live(target) {
			if task_runtime_reconcile_task(state.task_id, "scheduled_nudge", "high") {
				body = strings.concatenate({body, " action=agent_start_requested"})
			} else if !registry_agent_live(target) {
				body = strings.concatenate({body, " action=agent_start_already_pending_or_throttled"})
			}
		}
		event := Task_Event{
			kind                     = kind,
			task_id                  = state.task_id,
			chain_id                 = state.chain_id,
			status                   = task_status_to_string(state.status),
			body                     = body,
			agent_instance_id        = target,
			author_agent_instance_id = "task-nudge-scheduler",
			interrupt                = task_nudge_cfg.nudge_send_escape_prefix,
		}
		if task_store_append_event(event) {
			if kind == .Task_Nudged do task_notify_event(event)
			changed += 1
		}
	}
	changed += task_autoscaler_tick(now)
	changed += chat_approval_sweep_expired()
	return changed
}

task_nudge_threshold_seconds :: proc(status: Task_Status) -> int {
	#partial switch status {
	case .Queued:
		return task_nudge_cfg.nudge_ready_after_seconds
	case .Review_Ready:
		return task_nudge_cfg.nudge_review_after_seconds
	case .In_Progress:
		return task_nudge_cfg.nudge_working_stale_after_seconds
	case:
		return 0
	}
}

task_last_nudge_unix_ms :: proc(task_id, target: string) -> i64 {
	last: i64
	for event in store_all_events() {
		if event.task_id != task_id do continue
		if event.kind != .Task_Nudged && event.kind != .Task_Nudge_Failed do continue
		if target != "" && event.agent_instance_id != target do continue
		if event.created_unix_ms > last do last = event.created_unix_ms
	}
	return last
}

task_scheduled_nudge_body :: proc(state: Task_State, target: string) -> string {
	delivery := "ws_fallback"
	if task_nudge_cfg.nudge_send_escape_prefix do delivery = "escape_prefixed_pane_or_ws"
	action := "please continue work or move to blocked"
	#partial switch state.status {
	case .Queued:
		action = "task is queued and ready to be worked on"
	case .Review_Ready:
		action = "waiting on your review"
	case .In_Progress:
		action = "please continue work or move to blocked"
	case:
		break
	}
	unresolved := task_unresolved_comments(state.task_id)
	defer delete(unresolved)
	b := strings.builder_make()
	strings.write_string(&b, fmt.tprintf("Task %s: %s. status=%s delivery=%s target=%s", state.task_id, action, task_status_to_string(state.status), delivery, target))
	if len(unresolved) > 0 {
		strings.write_string(&b, fmt.tprintf(" unresolved_comments=%d", len(unresolved)))
		limit := len(unresolved)
		if limit > 3 do limit = 3
		for i in 0..<limit {
			c := unresolved[i]
			snippet := c.body
			if len(snippet) > 80 do snippet = snippet[:80]
			strings.write_string(&b, fmt.tprintf(" [%s: %s]", c.author_agent_instance_id, snippet))
		}
	}
	return strings.to_string(b)
}

task_nudge_delivery_method :: proc(body: string) -> string {
	if strings.index(body, "delivery=escape_prefixed_pane_or_ws") >= 0 do return "escape_prefixed_pane_or_ws"
	if strings.index(body, "delivery=ws_fallback") >= 0 do return "ws_fallback"
	return "ws"
}

CHAIN_BOOT_LEASE_MAX :: 128
Chain_Boot_Lease :: struct { chain_id: string, holder_agent_instance_id: string, priority: string, acquired_at_unix_ms: i64, last_boot_at_unix_ms: i64 }
chain_boot_leases: [CHAIN_BOOT_LEASE_MAX]Chain_Boot_Lease
chain_boot_lease_count: int

task_autoscaler_tick :: proc(now: i64) -> int {
	changed := task_runtime_reconcile_all_active("periodic_fallback", "normal")
	// Idle auto-close disabled (phase 1): the idle-shutdown sweep also stopped
	// non-chain agents on its own. Chain-terminal cleanup via
	// task_autoscaler_stop_chain_agents is unaffected.
	// TODO: fully remove idle-shutdown dead code and config after restart
	// policy is replaced by task/chain-scoped lifecycle rules.
	// changed += task_autoscaler_idle_shutdown(now)
	_ = now
	return changed
}

task_runtime_reconcile_all_active :: proc(reason, priority: string) -> int {
	changed := 0
	changed += task_runtime_reconcile_all_active_chain_coordinators(reason, priority)
	for state in store_all_tasks() {
		if task_runtime_reconcile_task(state.task_id, reason, priority) do changed += 1
	}
	return changed
}

task_runtime_reconcile_all_active_chain_coordinators :: proc(reason, priority: string) -> int {
	changed := 0
	for chain in store_all_chains() {
		if chain.status != "in_progress" do continue
		coordinator := task_runtime_agent_target(chain.coordinator_agent_instance_id)
		if coordinator == "" do continue
		if registry_agent_live(coordinator) do continue
		if task_autoscaler_ensure_chain_coordinator(chain.chain_id, reason, priority) do changed += 1
	}
	return changed
}

task_runtime_reconcile_task :: proc(task_id, reason, priority: string) -> bool {
	state, found := store_get_task_in_chain(task_id, "")
	if !found do return false
	if state.status != .Queued && state.status != .Review_Ready && state.status != .In_Progress do return false
	chain, chain_found := store_get_chain(state.chain_id)
	if !chain_found do return false
	if chain.status != "in_progress" do return false
	target := state.assignee_agent_instance_id
	boot_priority := priority
	if boot_priority == "" do boot_priority = "normal"
	if state.status == .Review_Ready {
		target = task_concrete_reviewer_agent_instance_id(state)
		boot_priority = "high"
	}
	if target == "" do return false
	if state.status == .Queued {
		if blocker := task_active_slot_blocker(target, state.task_id); blocker != "" do return false
	}
	if state.status == .Review_Ready {
		if task_reviewer_has_voted(state.task_id, target) do return false
		if task_reviewer_active_slot_blocker(target, state.task_id) != "" do return false
	}
	fmt.printfln("RUNTIME_RECONCILE: task=%s chain=%s status=%s target=%s reason=%s priority=%s", state.task_id, state.chain_id, task_status_to_string(state.status), target, reason, boot_priority)
	started := task_autoscaler_ensure_agent(chain, target, state.task_id, boot_priority, router_now_unix_ms(), reason)
	fmt.printfln("RUNTIME_RECONCILE_RESULT: task=%s target=%s reason=%s started=%t", state.task_id, target, reason, started)
	return started
}

task_runtime_reconcile_chain_coordinator :: proc(chain_id, reason, priority: string) -> bool {
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=chain_coordinator_reconcile_requested source=%s chain=%s priority=%s", router_now_unix_ms(), reason, chain_id, priority)
	return task_autoscaler_ensure_chain_coordinator(chain_id, reason, priority)
}

task_autoscaler_ensure_chain_coordinator :: proc(chain_id, reason, priority: string) -> bool {
	chain, found := store_get_chain(chain_id)
	if !found {
		fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=chain_coordinator_reconcile_skip source=%s chain=%s skip_reason=chain_not_found", router_now_unix_ms(), reason, chain_id)
		return false
	}
	if chain.status == "archived" {
		fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=chain_coordinator_reconcile_skip source=%s chain=%s skip_reason=chain_archived", router_now_unix_ms(), reason, chain_id)
		return false
	}
	coordinator := task_runtime_agent_target(chain.coordinator_agent_instance_id)
	if coordinator == "" {
		fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=chain_coordinator_reconcile_skip source=%s chain=%s skip_reason=no_runtime_coordinator coordinator=%s", router_now_unix_ms(), reason, chain_id, chain.coordinator_agent_instance_id)
		return false
	}
	boot_priority := priority
	if boot_priority == "" do boot_priority = "high"
	return task_autoscaler_ensure_agent(chain, coordinator, "", boot_priority, router_now_unix_ms(), reason)
}

// Coalescing window for remote start-forwards so periodic reconcile ticks don't
// spam the owning peer while a remote agent is already booting.
Remote_Wake_Record :: struct {
	proxy_agent_instance_id: string,
	last_forward_unix_ms:    i64,
}
remote_wake_records: [dynamic]Remote_Wake_Record
REMOTE_WAKE_COALESCE_MS :: i64(30_000)

task_autoscaler_remote_wake_should_forward :: proc(proxy_agent_instance_id: string, now: i64) -> bool {
	for &r in remote_wake_records {
		if r.proxy_agent_instance_id == proxy_agent_instance_id {
			if now - r.last_forward_unix_ms < REMOTE_WAKE_COALESCE_MS do return false
			r.last_forward_unix_ms = now
			return true
		}
	}
	append(&remote_wake_records, Remote_Wake_Record{proxy_agent_instance_id = strings.clone(proxy_agent_instance_id), last_forward_unix_ms = now})
	return true
}

// task_autoscaler_ensure_remote_agent wakes the REAL agent behind a remote proxy
// on its owning peer. Applies to assignee, coordinator, and reviewer targets
// alike (all route through task_autoscaler_ensure_agent). Returns true when the
// remote agent is already live or a start was forwarded successfully; false when
// it could not be forwarded (peer unreachable / coalesced). Either way the
// durable task notification outbox still carries the event and replays on peer
// reconnect, so an unreachable-peer target is never silently dropped.
task_autoscaler_ensure_remote_agent :: proc(proxy_agent_instance_id, reason: string, now: i64) -> bool {
	peer_id, remote_agent_instance_id, ok := agent_remote_proxy_lookup(proxy_agent_instance_id)
	if !ok || peer_id == "" || remote_agent_instance_id == "" do return false
	if !federation_peer_reachable(peer_id) {
		fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=remote_wake_skip source=%s target=%s skip_reason=peer_unreachable peer=%s", now, reason, proxy_agent_instance_id, peer_id)
		return false
	}
	// Already live on the origin (Part B status propagation): nothing to do.
	if remote, found := remote_proxy_status_get(proxy_agent_instance_id); found && federation_agent_status_is_live(remote.status) {
		return true
	}
	if !task_autoscaler_remote_wake_should_forward(proxy_agent_instance_id, now) {
		fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=remote_wake_skip source=%s target=%s skip_reason=coalesced peer=%s", now, reason, proxy_agent_instance_id, peer_id)
		return false
	}
	// Do not forward local proxy provider/tier defaults. The remote daemon owns
	// provider/model selection for its real instance; explicit UI starts may still
	// pass overrides through /agents/start, where the remote daemon validates them.
	start_ok, status_code, _ := federation_forward_start(peer_id, remote_agent_instance_id, "", "", proxy_agent_instance_id)
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=remote_wake_forward source=%s target=%s peer=%s remote=%s ok=%t status=%d", router_now_unix_ms(), reason, proxy_agent_instance_id, peer_id, remote_agent_instance_id, start_ok, status_code)
	return start_ok
}

task_autoscaler_ensure_agent :: proc(chain: Task_Chain_State, agent_instance_id, task_id, priority: string, now: i64, reason: string = "") -> bool {
	if agent_instance_id == "" do return false
	// Remote-proxy targets (assignee/coordinator/reviewer alike) can't be launched
	// locally; wake the real agent on the owning peer instead. Short-circuits
	// before the local lease/tracker/launch machinery, which is local-only.
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 && agent_record_is_remote_proxy(agent_instance_records[idx]) {
		return task_autoscaler_ensure_remote_agent(agent_instance_id, reason, now)
	}
	boot_priority := priority
	if boot_priority == "" do boot_priority = "normal"
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=ensure_agent_requested source=%s chain=%s task=%s target=%s priority=%s", now, reason, chain.chain_id, task_id, agent_instance_id, boot_priority)
	if boot_priority == "low" && task_autoscaler_chain_has_high_priority_boot(chain.chain_id) {
		fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=ensure_agent_skip source=%s chain=%s task=%s target=%s skip_reason=chain_has_high_priority_boot", router_now_unix_ms(), reason, chain.chain_id, task_id, agent_instance_id)
		return false
	}
	incoming_rank := task_autoscaler_boot_priority_rank(boot_priority)
	lease_idx := task_autoscaler_lease_index(chain.chain_id)
	bypass_lease := task_autoscaler_reason_bypasses_lease(reason)
	if lease_idx >= 0 {
		lease := &chain_boot_leases[lease_idx]
		existing_rank := task_autoscaler_boot_priority_rank(lease.priority)
		if !bypass_lease && now - lease.acquired_at_unix_ms < 90_000 && lease.holder_agent_instance_id != agent_instance_id && incoming_rank <= existing_rank {
			fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=ensure_agent_skip source=%s chain=%s task=%s target=%s skip_reason=chain_boot_lease lease_holder=%s lease_priority=%s lease_age_ms=%d", router_now_unix_ms(), reason, chain.chain_id, task_id, agent_instance_id, lease.holder_agent_instance_id, lease.priority, now - lease.acquired_at_unix_ms)
			fmt.printfln("RUNTIME_RECONCILE_SKIP: target=%s reason=%s lease_holder=%s lease_priority=%s", agent_instance_id, reason, lease.holder_agent_instance_id, lease.priority)
			return false
		}
		if !bypass_lease && now - lease.last_boot_at_unix_ms < 30_000 && incoming_rank <= existing_rank {
			fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=ensure_agent_skip source=%s chain=%s task=%s target=%s skip_reason=recent_chain_boot lease_holder=%s lease_priority=%s recent_boot_age_ms=%d", router_now_unix_ms(), reason, chain.chain_id, task_id, agent_instance_id, lease.holder_agent_instance_id, lease.priority, now - lease.last_boot_at_unix_ms)
			fmt.printfln("RUNTIME_RECONCILE_SKIP: target=%s reason=%s lease_recent_boot_holder=%s lease_priority=%s", agent_instance_id, reason, lease.holder_agent_instance_id, lease.priority)
			return false
		}
	} else {
		if chain_boot_lease_count >= CHAIN_BOOT_LEASE_MAX {
			fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=ensure_agent_skip source=%s chain=%s task=%s target=%s skip_reason=boot_lease_table_full", router_now_unix_ms(), reason, chain.chain_id, task_id, agent_instance_id)
			return false
		}
		lease_idx = chain_boot_lease_count; chain_boot_lease_count += 1
		chain_boot_leases[lease_idx].chain_id = strings.clone(chain.chain_id)
	}
	agent_token := auth_db_get_token("agent", agent_instance_id)
	if agent_token == "" do agent_token = generate_agent_token()
	if !agent_runtime_tracker_try_begin_launch(agent_instance_id, agent_token, reason, task_id, now) {
		_ = agent_store_touch_needed(agent_instance_id)
		lifecycle_status := agent_runtime_tracker_lifecycle_status(agent_instance_id)
		has_ws := agent_runtime_tracker_has_ws(agent_instance_id)
		fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=ensure_agent_skip source=%s chain=%s task=%s target=%s skip_reason=agent_tracker lifecycle_status=%s has_ws=%t", router_now_unix_ms(), reason, chain.chain_id, task_id, agent_instance_id, lifecycle_status, has_ws)
		fmt.printfln("RUNTIME_RECONCILE_SKIP: target=%s reason=%s tracker_coalesced=true lifecycle_status=%s has_ws=%t", agent_instance_id, reason, lifecycle_status, has_ws)
		return false
	}

	lease := &chain_boot_leases[lease_idx]
	lease.holder_agent_instance_id = strings.clone(agent_instance_id)
	lease.priority = strings.clone(boot_priority)
	lease.acquired_at_unix_ms = now
	lease.last_boot_at_unix_ms = now
	_ = agent_store_touch_needed(agent_instance_id)
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=launch_agent_call source=%s chain=%s task=%s target=%s priority=%s bypass_lease=%t", router_now_unix_ms(), reason, chain.chain_id, task_id, agent_instance_id, boot_priority, bypass_lease)
	if task_autoscaler_launch_agent(chain, agent_instance_id, reason, task_id, agent_token) {
		fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=launch_agent_success source=%s chain=%s task=%s target=%s priority=%s", router_now_unix_ms(), reason, chain.chain_id, task_id, agent_instance_id, boot_priority)
		fmt.printfln("RUNTIME_RECONCILE_LAUNCH: target=%s task=%s reason=%s priority=%s", agent_instance_id, task_id, reason, boot_priority)
		return true
	}
	agent_runtime_tracker_launch_failed(agent_instance_id, agent_token, reason)
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=launch_agent_failed source=%s chain=%s task=%s target=%s priority=%s", router_now_unix_ms(), reason, chain.chain_id, task_id, agent_instance_id, boot_priority)
	fmt.printfln("RUNTIME_RECONCILE_LAUNCH_FAILED: target=%s task=%s reason=%s priority=%s", agent_instance_id, task_id, reason, boot_priority)
	return false
}

task_autoscaler_boot_priority_rank :: proc(priority: string) -> int {
	if priority == "high" do return 3
	if priority == "low" do return 1
	return 2
}

task_autoscaler_reason_bypasses_lease :: proc(reason: string) -> bool {
	return reason == "chain_created" || reason == "auto_claim" || reason == "status_change" || reason == "manual_nudge" || reason == "scheduled_nudge" || reason == "review_ready" || reason == "review_rotation"
}

task_autoscaler_chain_has_high_priority_boot :: proc(chain_id: string) -> bool {
	for state in store_all_tasks() {
		if state.status != .Review_Ready || state.chain_id != chain_id do continue
		chain, found := store_get_chain(state.chain_id)
		if !found || chain.status != "in_progress" do continue
		target := task_concrete_reviewer_agent_instance_id(state)
		if target == "" do continue
		if agent_runtime_tracker_running(target) do continue
		if agent_runtime_tracker_is_launching(target) do continue
		return true
	}
	return false
}

task_autoscaler_launch_agent :: proc(chain: Task_Chain_State, agent_instance_id: string, launch_source: string = "", launch_task_id: string = "", launch_token: string = "") -> bool {
	launch_start_ms := router_now_unix_ms()
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=resolve_config_begin source=%s chain=%s task=%s target=%s", launch_start_ms, launch_source, chain.chain_id, launch_task_id, agent_instance_id)
	// Resolve identity/config from the durable agent_id + template first,
	// then let the instance record refine below.
	resolved_agent_id := agent_id_from_instance_id(agent_instance_id)
	template_id := agent_id_template_id(resolved_agent_id)
	display_name := agent_instance_id
	provider_profile := agent_resolve_provider_profile("")
	model_tier := agent_resolve_model_tier("")
	if provider_profile == "" do provider_profile = "pi"
	if model_tier == "" do model_tier = "normal"
	// The instance's HOME project is authoritative for restart.
	// Default the launch project to the chain's project, but if the durable
	// instance record already has a home project, that wins (the agent relaunches
	// into its own home, not the chain's).
	launch_project_id := chain.project_id
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 {
		rec := agent_instance_records[idx]
		if agent_record_is_remote_proxy(rec) {
			fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d stage=remote_proxy_skip source=%s chain=%s task=%s target=%s", router_now_unix_ms(), launch_source, chain.chain_id, launch_task_id, agent_instance_id)
			return false
		}
		if rec.template_id != "" do template_id = rec.template_id
		if rec.display_name != "" do display_name = rec.display_name
		if rec.provider_profile != "" do provider_profile = rec.provider_profile
		if rec.model_tier != "" do model_tier = rec.model_tier
		if rec.project_id != "" do launch_project_id = rec.project_id
	}
	now := router_now_unix_ms()
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=resolve_config_done source=%s chain=%s task=%s target=%s template=%s provider=%s tier=%s project=%s", now, now - launch_start_ms, launch_source, chain.chain_id, launch_task_id, agent_instance_id, template_id, provider_profile, model_tier, launch_project_id)
	fmt.printfln("RUNTIME_RECONCILE_AGENT_CONFIG: target=%s chain=%s template=%s provider=%s tier=%s project=%s", agent_instance_id, chain.chain_id, template_id, provider_profile, model_tier, launch_project_id)
	rec_id, final_tier, upsert_ok := agent_record_upsert(agent_instance_id, display_name, template_id, provider_profile, launch_project_id, "", model_tier)
	if !upsert_ok || rec_id == "" {
		now = router_now_unix_ms()
		fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=record_upsert_failed source=%s chain=%s task=%s target=%s", now, now - launch_start_ms, launch_source, chain.chain_id, launch_task_id, agent_instance_id)
		return false
	}
	now = router_now_unix_ms()
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=record_upsert_done source=%s chain=%s task=%s target=%s record=%s final_tier=%s", now, now - launch_start_ms, launch_source, chain.chain_id, launch_task_id, agent_instance_id, rec_id, final_tier)
	agent_token := launch_token
	if agent_token == "" do agent_token = auth_db_get_token("agent", agent_instance_id)
	if agent_token == "" do agent_token = generate_agent_token()
	registry_add_pending_agent_token(agent_instance_id, agent_token)
	log_path := wrapper_log_path(agent_instance_id)
	now = router_now_unix_ms()
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=wrapper_spawn_request source=%s chain=%s task=%s target=%s provider=%s tier=%s project=%s log=%s", now, now - launch_start_ms, launch_source, chain.chain_id, launch_task_id, agent_instance_id, provider_profile, final_tier, launch_project_id, log_path)
	ok := launch_wrapper_detached(agent_instance_id, provider_profile, server_config_path, log_path, agent_token, display_name, final_tier, launch_project_id, launch_source, chain.chain_id, launch_task_id)
	now = router_now_unix_ms()
	fmt.printfln("DAEMON_LAUNCH ts_unix_ms=%d elapsed_ms=%d stage=wrapper_spawn_result source=%s chain=%s task=%s target=%s ok=%t", now, now - launch_start_ms, launch_source, chain.chain_id, launch_task_id, agent_instance_id, ok)
	return ok
}

// TODO(phase 2): remove idle auto-close. Disabled in phase 1 (no longer called
// from task_autoscaler_tick) because it also stopped non-chain agents on its own.
task_autoscaler_idle_shutdown :: proc(now: i64) -> int {
	changed := 0
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if rec.agent_instance_id == "" || rec.current_task_id != "" do continue
		if agent_system_id_configured(rec.agent_instance_id) do continue
		if task_autoscaler_agent_is_active_chain_coordinator(rec.agent_instance_id) do continue
		if !agent_runtime_tracker_has_ws(rec.agent_instance_id) do continue
		idx := registry_find_agent(rec.agent_instance_id)
		if idx < 0 do continue
		if task_autoscaler_has_unread_mentions(rec.agent_instance_id, rec.last_needed_at_unix_ms) do continue
		last := rec.last_needed_at_unix_ms
		if last == 0 do last = agents[idx].startup_updated_unix_ms
		if last == 0 do last = agents[idx].last_seen_unix_ms
		grace := task_autoscaler_idle_shutdown_seconds(rec.agent_instance_id)
		if last == 0 || now - last < i64(grace) * 1000 do continue
		if ok, _, _ := agent_runtime_tracker_request_stop(rec.agent_instance_id, 30, "idle_shutdown"); ok { changed += 1 }
	}
	return changed
}

task_autoscaler_agent_is_active_chain_coordinator :: proc(agent_instance_id: string) -> bool {
	for chain in store_all_chains() {
		if chain.coordinator_agent_instance_id == agent_instance_id && !task_autoscaler_chain_terminal(chain.status) do return true
	}
	return false
}

task_autoscaler_chain_terminal :: proc(status: string) -> bool {
	return status == "completed" || status == "archived" || status == "cancelled" || status == "abandoned"
}

task_autoscaler_stop_chain_agents :: proc(chain_id, reason: string) -> int {
	chain, found := store_get_chain(chain_id)
	if !found do return 0
	if !task_autoscaler_chain_terminal(chain.status) do return 0
	candidates := make([dynamic]string)
	defer delete(candidates)
	if chain.coordinator_agent_instance_id != "" do append(&candidates, chain.coordinator_agent_instance_id)
	if chain.default_reviewer_agent_instance_id != "" do append(&candidates, chain.default_reviewer_agent_instance_id)
	changed := 0
	for candidate_id in candidates {
		agent_id := task_runtime_agent_target(candidate_id)
		if agent_id == "" do continue
		if agent_system_id_configured(agent_id) do continue
		if task_autoscaler_agent_has_active_work_outside_chain(agent_id, chain_id) do continue
		if rec_idx := agent_record_index_by_instance(agent_id); rec_idx >= 0 {
			rec := agent_instance_records[rec_idx]
			if rec.current_task_id != "" && task_autoscaler_task_belongs_to_chain(rec.current_task_id, chain_id) {
				_ = agent_store_clear_current_task(agent_id)
			}
		}
		if agent_runtime_tracker_is_stopping(agent_id) do continue
		if agent_runtime_tracker_has_ws(agent_id) {
			if ok, _, _ := agent_runtime_tracker_request_stop(agent_id, 30, reason); ok {
				changed += 1
				fmt.printfln("RUNTIME_RECONCILE_STOP ts_unix_ms=%d reason=%s chain=%s target=%s", router_now_unix_ms(), reason, chain_id, agent_id)
			}
		}
	}
	return changed
}

task_autoscaler_task_belongs_to_chain :: proc(task_id, chain_id: string) -> bool {
	state, found := store_get_task(task_id)
	if !found do return false
	return state.chain_id == chain_id
}

task_autoscaler_agent_has_active_work_outside_chain :: proc(agent_id, excluded_chain_id: string) -> bool {
	for chain in store_all_chains() {
		if chain.chain_id == excluded_chain_id || task_autoscaler_chain_terminal(chain.status) do continue
		if chain.coordinator_agent_instance_id == agent_id do return true
		if chain.default_reviewer_agent_instance_id == agent_id do return true
	}
	for state in store_all_tasks() {
		if state.chain_id == excluded_chain_id || task_status_terminal(state.status) do continue
		if state.assignee_agent_instance_id == agent_id || task_actor_has_role(state, agent_id, "lgtm_required") || task_actor_has_role(state, agent_id, "lgtm_optional") || task_actor_has_role(state, agent_id, "coordinator") do return true
	}
	return false
}

task_autoscaler_idle_shutdown_seconds :: proc(agent_instance_id: string) -> int {
	_ = agent_instance_id
	grace := task_nudge_cfg.agent_idle_shutdown_seconds
	if grace <= 0 do grace = 1800
	return grace
}

task_autoscaler_has_unread_mentions :: proc(agent_instance_id: string, since_unix_ms: i64) -> bool {
	if chat_has_unread_direction(HUMAN_RECIPIENT_ID, agent_instance_id, "user_to_agent") do return true
	out, ok := task_db_query_pending_notification_count(agent_instance_id)
	if ok && out > 0 do return true
	mention := fmt.tprintf("@%s", agent_instance_id)
	for c in store_all_comments() {
		if c.resolved do continue
		if since_unix_ms > 0 && c.created_unix_ms <= since_unix_ms do continue
		if strings.contains(c.body, agent_instance_id) || strings.contains(c.body, mention) do return true
	}
	for e in store_all_events() {
		if e.agent_instance_id != agent_instance_id do continue
		if since_unix_ms > 0 && e.created_unix_ms <= since_unix_ms do continue
		if e.kind == .Task_Nudged || e.kind == .Task_Nudge_Failed do return true
	}
	return false
}

task_autoscaler_lease_index :: proc(chain_id: string) -> int {
	for i in 0..<chain_boot_lease_count { if chain_boot_leases[i].chain_id == chain_id do return i }
	return -1
}
