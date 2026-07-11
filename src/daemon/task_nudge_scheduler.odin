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
	for i in 0..<task_state_count {
		state     := task_states[i]
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
		if target == "" || !registry_agent_live(target) {
			kind = .Task_Nudge_Failed
			if target == "" {
				body = strings.concatenate({body, " reason=no_target"})
			} else {
				body = strings.concatenate({body, " reason=target_not_live"})
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
	for i in 0..<task_event_count {
		event := task_events[i]
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

TEAM_BOOT_LEASE_MAX :: 128
Team_Boot_Lease :: struct { team_id: string, holder_agent_instance_id: string, priority: string, acquired_at_unix_ms: i64, last_boot_at_unix_ms: i64 }
team_boot_leases: [TEAM_BOOT_LEASE_MAX]Team_Boot_Lease
team_boot_lease_count: int

task_autoscaler_tick :: proc(now: i64) -> int {
	changed := 0
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.status != .Queued && state.status != .Review_Ready && state.status != .In_Progress do continue
		chain_idx, found := task_existing_chain_index(state.chain_id)
		if !found do continue
		chain := task_chains[chain_idx]
		if chain.status != "in_progress" do continue
		target := state.assignee_agent_instance_id
		priority := "normal"
		if state.status == .Review_Ready { target = task_reviewer_agent_instance_id(state); priority = "high" }
		if target == "" || target == "user_proxy" do continue
		if target == chain.coordinator_agent_instance_id do continue
		if task_autoscaler_ensure_agent(chain, target, state.task_id, priority, now) do changed += 1
	}
	changed += task_autoscaler_idle_shutdown(now)
	return changed
}

task_autoscaler_ensure_chain_coordinator :: proc(chain_id, reason, priority: string) -> bool {
	chain_idx, found := task_existing_chain_index(chain_id)
	if !found do return false
	chain := task_chains[chain_idx]
	if chain.status == "archived" do return false
	coordinator := chain.coordinator_agent_instance_id
	if coordinator == "" || coordinator == "user_proxy" do return false
	boot_priority := priority
	if boot_priority == "" do boot_priority = "high"
	return task_autoscaler_ensure_agent(chain, coordinator, reason, boot_priority, router_now_unix_ms())
}

task_autoscaler_ensure_agent :: proc(chain: Task_Chain_State, agent_instance_id, task_id, priority: string, now: i64) -> bool {
	if agent_instance_id == "" do return false
	boot_priority := priority
	if boot_priority == "" do boot_priority = "normal"
	if boot_priority == "low" && task_autoscaler_team_has_high_priority_boot(chain.team_id) do return false
	if idx := registry_find_agent(agent_instance_id); idx >= 0 {
		if agents[idx].connected || agents[idx].has_ws || agents[idx].startup_status == "starting" || agents[idx].startup_status == "ready" {
			_ = agent_store_touch_needed(agent_instance_id)
			return false
		}
	}
	incoming_rank := task_autoscaler_boot_priority_rank(boot_priority)
	lease_idx := task_autoscaler_lease_index(chain.team_id)
	if lease_idx >= 0 {
		lease := &team_boot_leases[lease_idx]
		existing_rank := task_autoscaler_boot_priority_rank(lease.priority)
		if now - lease.acquired_at_unix_ms < 90_000 && lease.holder_agent_instance_id != agent_instance_id && incoming_rank <= existing_rank do return false
		if now - lease.last_boot_at_unix_ms < 30_000 && incoming_rank <= existing_rank do return false
	} else {
		if team_boot_lease_count >= TEAM_BOOT_LEASE_MAX do return false
		lease_idx = team_boot_lease_count; team_boot_lease_count += 1
		team_boot_leases[lease_idx].team_id = strings.clone(chain.team_id)
	}
	lease := &team_boot_leases[lease_idx]
	lease.holder_agent_instance_id = strings.clone(agent_instance_id)
	lease.priority = strings.clone(boot_priority)
	lease.acquired_at_unix_ms = now
	lease.last_boot_at_unix_ms = now
	_ = agent_store_touch_needed(agent_instance_id)
	if task_autoscaler_launch_agent(chain, agent_instance_id) {
		_ = team_db_update_team_status(team_service_db, chain.team_id, "warming")
		return true
	}
	return false
}

task_autoscaler_boot_priority_rank :: proc(priority: string) -> int {
	if priority == "high" do return 3
	if priority == "low" do return 1
	return 2
}

task_autoscaler_team_has_high_priority_boot :: proc(team_id: string) -> bool {
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.status != .Review_Ready do continue
		chain_idx, found := task_existing_chain_index(state.chain_id)
		if !found do continue
		chain := task_chains[chain_idx]
		if chain.team_id != team_id || chain.status != "in_progress" do continue
		target := task_reviewer_agent_instance_id(state)
		if target == "" || target == "user_proxy" do continue
		if idx := registry_find_agent(target); idx >= 0 {
			if agents[idx].connected || agents[idx].has_ws || agents[idx].startup_status == "starting" || agents[idx].startup_status == "ready" do continue
		}
		return true
	}
	return false
}

task_autoscaler_launch_agent :: proc(chain: Task_Chain_State, agent_instance_id: string) -> bool {
	template_id := derive_agent_class(agent_instance_id)
	display_name := agent_instance_id
	provider_profile := "pi"
	model_tier := "normal"
	if idx := agent_record_index_by_instance(agent_instance_id); idx >= 0 {
		rec := agent_instance_records[idx]
		if rec.template_id != "" do template_id = rec.template_id
		if rec.display_name != "" do display_name = rec.display_name
		if rec.provider_profile != "" do provider_profile = rec.provider_profile
		if rec.model_tier != "" do model_tier = rec.model_tier
	}
	rec_id, final_tier, upsert_ok := agent_record_upsert(agent_instance_id, display_name, template_id, provider_profile, chain.project_id, "", model_tier)
	if !upsert_ok || rec_id == "" do return false
	agent_token := generate_agent_token()
	registry_add_pending_agent_token(agent_instance_id, agent_token)
	return launch_wrapper_detached(agent_instance_id, provider_profile, server_config_path, wrapper_log_path(agent_instance_id), agent_token, display_name, final_tier, chain.project_id)
}

task_autoscaler_idle_shutdown :: proc(now: i64) -> int {
	changed := 0
	for i in 0..<agent_instance_record_count {
		rec := agent_instance_records[i]
		if rec.agent_instance_id == "" || rec.current_task_id != "" do continue
		if task_autoscaler_agent_is_active_chain_coordinator(rec.agent_instance_id) do continue
		idx := registry_find_agent(rec.agent_instance_id)
		if idx < 0 || !agents[idx].has_ws do continue
		if task_autoscaler_has_unread_mentions(rec.agent_instance_id, rec.last_needed_at_unix_ms) do continue
		last := rec.last_needed_at_unix_ms
		if last == 0 do last = agents[idx].startup_updated_unix_ms
		if last == 0 do last = agents[idx].last_seen_unix_ms
		grace := task_autoscaler_idle_shutdown_seconds(rec.agent_instance_id)
		if last == 0 || now - last < i64(grace) * 1000 do continue
		if ok, _, _ := agents_stop_request(rec.agent_instance_id, 30); ok { changed += 1 }
	}
	return changed
}

task_autoscaler_agent_is_active_chain_coordinator :: proc(agent_instance_id: string) -> bool {
	for i in 0..<task_chain_count {
		chain := task_chains[i]
		if chain.coordinator_agent_instance_id == agent_instance_id && chain.status != "archived" do return true
	}
	return false
}

task_autoscaler_idle_shutdown_seconds :: proc(agent_instance_id: string) -> int {
	grace := task_nudge_cfg.team_idle_shutdown_seconds
	if grace <= 0 do grace = 1800
	for i in 0..<task_state_count {
		state := task_states[i]
		if state.chain_id == "" || task_status_terminal(state.status) do continue
		if state.assignee_agent_instance_id != agent_instance_id && !task_actor_has_role(state, agent_instance_id, "lgtm_required") && !task_actor_has_role(state, agent_instance_id, "lgtm_optional") && !task_actor_has_role(state, agent_instance_id, "coordinator") do continue
		team, ok := team_db_get_team_by_chain_id(team_service_db, state.chain_id)
		if !ok do continue
		kind := team_kind_get(team.kind)
		if kind != nil && kind.idle_shutdown_ms > 0 do return kind.idle_shutdown_ms / 1000
	}
	return grace
}

task_autoscaler_has_unread_mentions :: proc(agent_instance_id: string, since_unix_ms: i64) -> bool {
	if chat_has_unread_direction("operator@local", agent_instance_id, "user_to_agent") do return true
	out, ok := task_db_query_pending_notification_count(agent_instance_id)
	if ok && out > 0 do return true
	mention := fmt.tprintf("@%s", agent_instance_id)
	for i in 0..<task_comment_count {
		c := task_comments[i]
		if c.resolved do continue
		if since_unix_ms > 0 && c.created_unix_ms <= since_unix_ms do continue
		if strings.contains(c.body, agent_instance_id) || strings.contains(c.body, mention) do return true
	}
	for i in 0..<task_event_count {
		e := task_events[i]
		if e.agent_instance_id != agent_instance_id do continue
		if since_unix_ms > 0 && e.created_unix_ms <= since_unix_ms do continue
		if e.kind == .Task_Nudged || e.kind == .Task_Nudge_Failed do return true
	}
	return false
}

task_autoscaler_lease_index :: proc(team_id: string) -> int {
	for i in 0..<team_boot_lease_count { if team_boot_leases[i].team_id == team_id do return i }
	return -1
}
